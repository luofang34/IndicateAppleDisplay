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
public protocol SceneProducing: AnyObject {
    func frame() throws -> SceneFrame
}

/// A producer backed by a closure.
public final class ClosureSceneProducer: SceneProducing {
    private let body: () throws -> SceneFrame

    public init(_ body: @escaping () throws -> SceneFrame) {
        self.body = body
    }

    public func frame() throws -> SceneFrame { try body() }
}

/// What one frame attempt produced.
public struct PanelFrameOutcome {
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
public final class PanelDisplay {
    /// What this panel needs before a frame may be committed.
    public let requirements: PanelRequirements
    /// The failure latch and liveness watchdog.
    public private(set) var health: PanelHealth

    private let renderer: SceneRenderer
    private let producer: any SceneProducing
    private let background: CGColor?

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
        health = PanelHealth(policy: policy, nowMs: nowMs)
    }

    /// Produces, validates, and paints one frame.
    public func render(
        pixelWidth: Int,
        pixelHeight: Int,
        nowMs: Double
    ) -> PanelFrameOutcome {
        let frame: SceneFrame
        do {
            frame = try producer.frame()
        } catch let fault as ProducerFault {
            return fail(fault.reason, nowMs: nowMs, width: pixelWidth, height: pixelHeight)
        } catch {
            return fail(.renderTrap, nowMs: nowMs, width: pixelWidth, height: pixelHeight)
        }

        let report: SceneLayerReport
        do {
            report = try SceneValidator.validate(frame.bytes)
        } catch {
            return fail(
                error.displayReason, nowMs: nowMs,
                width: pixelWidth, height: pixelHeight
            )
        }
        if let rejection = report.rejection(requirements) {
            return fail(rejection, nowMs: nowMs, width: pixelWidth, height: pixelHeight)
        }

        let painted: CGImage
        do {
            painted = try renderer.paintedImage(
                frame.bytes,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                logicalFrame: requirements.designFrame,
                background: background
            )
        } catch {
            return fail(
                error.displayReason, nowMs: nowMs,
                width: pixelWidth, height: pixelHeight
            )
        }

        let display = health.reportSuccess(nowMs: nowMs, generation: frame.generation)
        // A validated frame does not clear a latch on its own: the recovery
        // streak must complete first, so the page stays covered until the
        // pipeline has proved itself.
        guard !display.showFailure else {
            return PanelFrameOutcome(
                image: FailurePage.image(
                    pixelWidth: pixelWidth, pixelHeight: pixelHeight, reason: display.reason
                ),
                showingFailure: true,
                reason: display.reason,
                generation: frame.generation,
                report: report
            )
        }
        return PanelFrameOutcome(
            image: painted,
            showingFailure: false,
            reason: .ok,
            generation: frame.generation,
            report: report
        )
    }

    /// Watchdog tick, scheduled independently of the render loop.
    @discardableResult
    public func tick(nowMs: Double) -> PanelHealthDisplay {
        health.tick(nowMs: nowMs)
    }

    /// Latches a failure the host observed outside this pipeline — a producer
    /// that could not be loaded, or a state block the producer refused.
    @discardableResult
    public func reportProducerFailure(
        _ reason: DisplayReason,
        nowMs: Double
    ) -> PanelHealthDisplay {
        health.reportFailure(nowMs: nowMs, reason: reason)
    }

    /// Clears the latch after an explicit producer reinitialization.
    public func reset(nowMs: Double) {
        health.reset(nowMs: nowMs)
    }

    private func fail(
        _ reason: DisplayReason,
        nowMs: Double,
        width: Int,
        height: Int
    ) -> PanelFrameOutcome {
        let display = health.reportFailure(nowMs: nowMs, reason: reason)
        return PanelFrameOutcome(
            image: FailurePage.image(
                pixelWidth: width, pixelHeight: height, reason: display.reason
            ),
            showingFailure: true,
            reason: display.reason,
            generation: nil,
            report: nil
        )
    }
}
