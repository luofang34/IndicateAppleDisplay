import CoreGraphics
import Foundation

/// A scene and the generation that identifies it.
public struct SceneFrame: Equatable, Sendable {
    /// Encoded scene bytes.
    public let bytes: [UInt8]
    /// Advances when, and only when, the content actually changed.
    ///
    /// The watchdog gives freshness credit for advancement, not for arrival, so
    /// a producer that hands back the same frame forever is caught rather than
    /// mistaken for a healthy display.
    public let generation: UInt32

    public init(bytes: [UInt8], generation: UInt32) {
        self.bytes = bytes
        self.generation = generation
    }
}

/// A producer failure that already knows its diagnostic code.
public struct ProducerFault: Error, Equatable, Sendable {
    public let reason: DisplayReason

    public init(reason: DisplayReason) {
        self.reason = reason
    }
}

/// Supplies the scene to show now.
///
/// Deliberately pull-shaped. A display asks for a frame on its own cadence; it
/// is never handed one by whatever delivered the data. Repainting per arriving
/// packet couples the display to the link and is the named anti-pattern.
/// The render worker can call the producer from a background thread.
public protocol SceneProducing: AnyObject, Sendable {
    /// The scene to show now, emitted into `designFrame`.
    ///
    /// The frame is an input because a panel emits geometry for the frame it
    /// is asked for rather than a fixed picture a backend rescales. Producing
    /// at one frame and mapping at another silently misplaces every coordinate,
    /// so the host passes the same frame to both.
    func frame(designFrame: CGRect) throws -> SceneFrame
}

/// A producer backed by a closure.
public final class ClosureSceneProducer: SceneProducing {
    private let body: @Sendable (CGRect) throws -> SceneFrame

    public init(_ body: @escaping @Sendable (CGRect) throws -> SceneFrame) {
        self.body = body
    }

    public func frame(designFrame: CGRect) throws -> SceneFrame {
        try body(designFrame)
    }
}

/// What one frame attempt produced.
public struct PanelFrameOutcome: Sendable {
    /// What to show. `nil` only when even the failure page could not be built.
    public let image: CGImage?
    /// Whether `image` is the failure page rather than the panel.
    public let showingFailure: Bool
    /// The diagnostic code, `.ok` when the panel is showing normally.
    public let reason: DisplayReason
    /// The generation this attempt read, when one was produced.
    public let generation: UInt32?
    /// What the scene contained, when it validated.
    public let report: SceneLayerReport?
    /// The failure latch state after this frame attempt.
    public let health: PanelHealthSnapshot
    /// Pixel-buffer metrics after this frame attempt.
    public let pixelBuffers: PanelPixelBufferMetrics
    let presentationEpoch: UInt64

    /// Everything about this frame except the frame itself.
    ///
    /// A host that mirrors frame results into observable state must publish on
    /// change, not on arrival: a display link delivers a healthy panel sixty or
    /// a hundred and twenty times a second, and republishing each one rebuilds
    /// the surrounding interface at that rate until it stops responding. That
    /// is the same coupling the pull-shaped pipeline exists to break, one layer
    /// up. Comparing summaries is how a host tells the two apart, which is why
    /// the generation — the one field guaranteed to differ every frame — is
    /// deliberately not part of it.
    public var summary: PanelFrameSummary {
        PanelFrameSummary(
            showingFailure: showingFailure,
            reason: reason,
            layersPresent: report?.layersPresent ?? [],
            layerCommands: report?.layerCommands ?? [],
            unknownOpcodes: report?.unknownOpcodes ?? 0
        )
    }
}

/// What a host would show about a frame, stable across identical frames.
public struct PanelFrameSummary: Equatable, Sendable {
    public let showingFailure: Bool
    public let reason: DisplayReason
    public let layersPresent: [SceneLayer]
    public let layerCommands: [Int]
    public let unknownOpcodes: Int
}

enum PanelFramePreparation: Sendable {
    case failed(reason: DisplayReason, pixelBuffers: PanelPixelBufferMetrics)
    case ready(
        frame: SceneFrame,
        report: SceneLayerReport,
        image: CGImage,
        pixelBuffers: PanelPixelBufferMetrics
    )
}

struct PanelFrameCommit: Sendable {
    let image: CGImage?
    let showingFailure: Bool
    let reason: DisplayReason
    let generation: UInt32?
    let report: SceneLayerReport?
    let health: PanelHealthSnapshot
    let presentationEpoch: UInt64
}

/// One panel's transactional frame pipeline: produce, validate, paint, commit.
///
/// Nothing partial and nothing stale ever becomes visible. A frame is painted
/// offscreen and returned only after it has passed the layer contract *and*
/// the panel's own critical-layer requirement; any failure latches and the
/// caller receives the failure page instead of the previous good image.
///
/// This is deliberately not a view. A tester, an EFB, a simulator-side
/// instrument window, and a headless capture all need the same discipline, and
/// only the last step — where the image goes — differs.
public final class PanelDisplay: @unchecked Sendable {
    /// What this panel needs before a frame may be committed.
    public let requirements: PanelRequirements
    /// The failure latch and liveness watchdog.
    public var health: PanelHealth { healthStore.value() }

    private let renderer: SceneRenderer
    private let producer: any SceneProducing
    private let background: CGColor?
    private let renderLock = NSLock()
    private let healthStore: PanelHealthStore
    private var pixelBuffers = PixelBufferPool()

    public init(
        requirements: PanelRequirements,
        producer: any SceneProducing,
        atlas: (any GlyphAtlas)? = nil,
        policy: PanelHealthPolicy = PanelHealthPolicy(),
        background: CGColor? = CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        nowMs: Double = 0
    ) {
        self.requirements = requirements
        self.producer = producer
        self.background = background
        // One renderer for the display's lifetime, so the glyph outline cache
        // survives across frames. Building a renderer per frame would rebuild
        // every glyph every frame.
        renderer = SceneRenderer(atlas: atlas)
        healthStore = PanelHealthStore(PanelHealth(policy: policy, nowMs: nowMs))
    }

    /// Produces, validates, and paints one frame.
    ///
    /// This function blocks until the complete frame pipeline finishes. Use
    /// ``PanelRenderWorker`` in an interactive display host.
    public func renderBlocking(
        pixelWidth: Int,
        pixelHeight: Int,
        nowMs: Double
    ) -> PanelFrameOutcome {
        let preparation = prepareFrameForWorkerBlocking(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        let commit = commitHealth(preparation, nowMs: nowMs)
        return materializeForWorker(
            commit,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    func prepareFrameForWorkerBlocking(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> PanelFramePreparation {
        renderLock.lock()
        defer { renderLock.unlock() }
        return prepareFrameBlocking(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    func commitHealthForWorker(
        _ preparation: PanelFramePreparation,
        nowMs: Double
    ) -> PanelFrameCommit {
        commitHealth(preparation, nowMs: nowMs)
    }

    func materializeForWorker(
        _ commit: PanelFrameCommit,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> PanelFrameOutcome {
        renderLock.lock()
        defer { renderLock.unlock() }
        return materialize(commit, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    private func prepareFrameBlocking(
        pixelWidth: Int,
        pixelHeight: Int
    ) -> PanelFramePreparation {
        let designFrame = requirements.frame(fittingPixelSize: CGSize(
            width: CGFloat(pixelWidth),
            height: CGFloat(pixelHeight)
        ))
        let frame: SceneFrame
        do {
            frame = try producer.frame(designFrame: designFrame)
        } catch let fault as ProducerFault {
            return .failed(reason: fault.reason, pixelBuffers: pixelBuffers.metrics)
        } catch {
            return .failed(reason: .renderTrap, pixelBuffers: pixelBuffers.metrics)
        }

        let report: SceneLayerReport
        do {
            report = try SceneValidator.validate(frame.bytes)
        } catch {
            return .failed(reason: error.displayReason, pixelBuffers: pixelBuffers.metrics)
        }
        if let rejection = report.rejection(requirements) {
            return .failed(reason: rejection, pixelBuffers: pixelBuffers.metrics)
        }

        do {
            let image = try renderer.paintedImage(
                frame.bytes,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                logicalFrame: designFrame,
                background: background,
                buffers: &pixelBuffers
            )
            return .ready(
                frame: frame,
                report: report,
                image: image,
                pixelBuffers: pixelBuffers.metrics
            )
        } catch {
            return .failed(reason: error.displayReason, pixelBuffers: pixelBuffers.metrics)
        }
    }

    private func commitHealth(
        _ preparation: PanelFramePreparation,
        nowMs: Double
    ) -> PanelFrameCommit {
        switch preparation {
        case let .failed(reason, _):
            let update = healthStore.reportFailure(nowMs: nowMs, reason: reason)
            return PanelFrameCommit(
                image: nil,
                showingFailure: true,
                reason: update.display.reason,
                generation: nil,
                report: nil,
                health: update.snapshot,
                presentationEpoch: update.presentationEpoch
            )
        case let .ready(frame, report, image, _):
            let update = healthStore.reportSuccess(
                nowMs: nowMs,
                generation: frame.generation
            )
            return PanelFrameCommit(
                image: update.display.showFailure ? nil : image,
                showingFailure: update.display.showFailure,
                reason: update.display.reason,
                generation: frame.generation,
                report: report,
                health: update.snapshot,
                presentationEpoch: update.presentationEpoch
            )
        }
    }

    private func materialize(
        _ commit: PanelFrameCommit,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> PanelFrameOutcome {
        let image = commit.showingFailure
            ? pixelBuffers.makeFailureImage(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                reason: commit.reason
            )
            : commit.image
        return PanelFrameOutcome(
            image: image,
            showingFailure: commit.showingFailure,
            reason: commit.reason,
            generation: commit.generation,
            report: commit.report,
            health: commit.health,
            pixelBuffers: pixelBuffers.metrics,
            presentationEpoch: commit.presentationEpoch
        )
    }

    func presentIfCurrent(_ outcome: PanelFrameOutcome, body: () -> Void) -> Bool {
        healthStore.presentIfCurrent(
            epoch: outcome.presentationEpoch,
            display: PanelHealthDisplay(
                showFailure: outcome.showingFailure,
                reason: outcome.reason
            ),
            body: body
        )
    }

    func presentFailureIfCurrent(
        epoch: UInt64,
        reason: DisplayReason,
        body: () -> Void
    ) -> Bool {
        healthStore.presentIfCurrent(
            epoch: epoch,
            display: PanelHealthDisplay(showFailure: true, reason: reason),
            body: body
        )
    }

    /// Watchdog tick, scheduled independently of the render loop.
    @discardableResult
    public func tick(nowMs: Double) -> PanelHealthDisplay {
        healthStore.tick(nowMs: nowMs)
    }

    func tickForPresentation(nowMs: Double) -> PanelHealthUpdate {
        healthStore.tickForPresentation(nowMs: nowMs)
    }

    /// Latches a failure the host observed outside this pipeline — a producer
    /// that could not be loaded, or a state block the producer refused.
    @discardableResult
    public func reportProducerFailure(
        _ reason: DisplayReason,
        nowMs: Double
    ) -> PanelHealthDisplay {
        healthStore.reportFailure(nowMs: nowMs, reason: reason).display
    }

    /// Clears the latch after an explicit producer reinitialization.
    public func reset(nowMs: Double) {
        healthStore.reset(nowMs: nowMs)
    }

}
