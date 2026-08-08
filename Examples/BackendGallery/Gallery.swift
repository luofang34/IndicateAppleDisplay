import CoreGraphics
import Foundation
import IndicateAppleDisplay

/// One rendered gallery row: the image, what it shows, and what it must show.
///
/// `expectedFailure` and `expectedReason` are the typed outcome the headless
/// export verifies; the window only displays the actuals.
struct GalleryItem {
    let name: String
    let detail: String
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let showingFailure: Bool
    let reason: DisplayReason
    /// Present-layer mask of the frame's validation report, when it validated.
    let layersPresentMask: Int?
    /// Unknown-opcode count of the frame's validation report, when it validated.
    let unknownOpcodes: Int?
    let expectedFailure: Bool
    let expectedReason: DisplayReason
}

/// The frame the corpus scenes are authored in.
private let designSize = CGSize(width: 480, height: 360)

/// A producer over fixed scene bytes, advancing one generation per frame.
private final class StubProducer: SceneProducing {
    var bytes: [UInt8]
    var generation: UInt32 = 0
    var fault: DisplayReason?

    init(bytes: [UInt8]) { self.bytes = bytes }

    func frame(designFrame _: CGRect) throws -> SceneFrame {
        if let fault { throw ProducerFault(reason: fault) }
        generation += 1
        return SceneFrame(bytes: bytes, generation: generation)
    }
}

private func requirements(
    critical: Set<SceneLayer>,
    unknown: UnknownOpcodePolicy = .failFrame
) -> PanelRequirements {
    PanelRequirements(
        id: "gallery", title: "Gallery",
        criticalLayers: critical,
        frameMin: designSize, frameMax: designSize, canonicalFrame: designSize,
        unknownOpcodes: unknown
    )
}

private func item(
    name: String,
    detail: String,
    outcome: PanelFrameOutcome,
    width: Int,
    height: Int,
    expectedFailure: Bool,
    expectedReason: DisplayReason
) throws -> GalleryItem {
    guard let image = outcome.image else { throw GalleryError.noImage(name) }
    return GalleryItem(
        name: name, detail: detail,
        image: image, pixelWidth: width, pixelHeight: height,
        showingFailure: outcome.showingFailure, reason: outcome.reason,
        layersPresentMask: outcome.report?.presentMask,
        unknownOpcodes: outcome.report?.unknownOpcodes,
        expectedFailure: expectedFailure, expectedReason: expectedReason
    )
}

private func display(
    scene: [UInt8],
    critical: Set<SceneLayer>,
    unknown: UnknownOpcodePolicy = .failFrame,
    atlas: (any GlyphAtlas)? = GalleryAtlas(),
    policy: PanelHealthPolicy = PanelHealthPolicy()
) -> PanelDisplay {
    PanelDisplay(
        requirements: requirements(critical: critical, unknown: unknown),
        producer: StubProducer(bytes: scene),
        atlas: atlas,
        policy: policy
    )
}

/// Builds every gallery case from the vendored corpus and local policy.
///
/// Every covered frame comes out of `PanelDisplay` or `PanelHealth` — the same
/// policy path an operational host runs — never from a hand-drawn overlay.
func galleryItems(corpus: CorpusFile) throws -> [GalleryItem] {
    var items: [GalleryItem] = []

    // A valid multi-layer scene at two output sizes.
    let pfd = try corpus.bytes(for: "multi-layer-pfd")
    for (suffix, width, height) in [("1x", 480, 360), ("2x", 960, 720)] {
        let outcome = display(scene: pfd, critical: [.attitude, .tapes, .annunciation])
            .render(pixelWidth: width, pixelHeight: height, nowMs: 0)
        items.append(try item(
            name: "valid-pfd-\(suffix)",
            detail: "Corpus multi-layer-pfd, accepted, rendered at \(width)x\(height) pixels",
            outcome: outcome, width: width, height: height,
            expectedFailure: false, expectedReason: .ok
        ))
    }

    // One corpus scene with an opcode this revision does not know, both policies.
    let unknownScene = try corpus.bytes(for: "unknown-opcode-counted")
    let covered = display(scene: unknownScene, critical: [.attitude])
        .render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    items.append(try item(
        name: "unknown-opcode-fail-frame",
        detail: "Corpus unknown-opcode-counted under the default policy: the frame fails visibly",
        outcome: covered, width: 480, height: 360,
        expectedFailure: true, expectedReason: .unknownOpcode
    ))
    let skipped = display(scene: unknownScene, critical: [.attitude], unknown: .countAndSkip)
        .render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    items.append(try item(
        name: "unknown-opcode-count-and-skip",
        detail: "The same scene under countAndSkip: painted, with the unknown opcode counted",
        outcome: skipped, width: 480, height: 360,
        expectedFailure: false, expectedReason: .ok
    ))

    // An accepted scene that does not carry a layer the panel declares critical.
    let attitude = try corpus.bytes(for: "attitude-every-drawing-opcode")
    let missing = display(scene: attitude, critical: [.attitude, .guidance])
        .render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    items.append(try item(
        name: "missing-critical-layer",
        detail: "Corpus attitude-every-drawing-opcode shown as a guidance panel: not sparse, broken",
        outcome: missing, width: 480, height: 360,
        expectedFailure: true, expectedReason: .sceneCriticalLayersMissing
    ))

    // A producer that faults after a healthy frame.
    let producer = StubProducer(bytes: pfd)
    let host = PanelDisplay(
        requirements: requirements(critical: [.attitude, .tapes, .annunciation]),
        producer: producer,
        atlas: GalleryAtlas()
    )
    _ = host.render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    producer.fault = .stateWriteFailed
    let faulted = host.render(pixelWidth: 480, pixelHeight: 360, nowMs: 16)
    items.append(try item(
        name: "producer-fault",
        detail: "The producer threw after a healthy frame: the panel covers instead of going stale",
        outcome: faulted, width: 480, height: 360,
        expectedFailure: true, expectedReason: .stateWriteFailed
    ))

    // A producer whose generation stops advancing: the watchdog latches LIVENESS.
    let watched = display(
        scene: pfd,
        critical: [.attitude, .tapes, .annunciation],
        policy: PanelHealthPolicy(livenessDeadlineMs: 1000, recoveryFrames: 30, tickIntervalMs: 250)
    )
    let healthy = watched.render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    for now in stride(from: 250.0, through: 1000.0, by: 250.0) {
        guard !watched.tick(nowMs: now).showFailure else {
            throw GalleryError.earlyLatch(now)
        }
    }
    let tripped = watched.tick(nowMs: 1250)
    guard tripped.showFailure, tripped.reason == .liveness else {
        throw GalleryError.noLivenessTrip
    }
    // The view's cover path: a liveness trip paints the failure page directly,
    // because no frame arrives to carry it.
    guard let livenessPage = FailurePage.image(
        pixelWidth: 480, pixelHeight: 360, reason: tripped.reason
    ) else { throw GalleryError.noImage("liveness") }
    items.append(GalleryItem(
        name: "liveness",
        detail: "One healthy frame, then silence: ticks on cadence trip the watchdog",
        image: livenessPage, pixelWidth: 480, pixelHeight: 360,
        showingFailure: true, reason: tripped.reason,
        layersPresentMask: healthy.report?.presentMask,
        unknownOpcodes: healthy.report?.unknownOpcodes,
        expectedFailure: true, expectedReason: .liveness
    ))

    // A latched fault, then a recovery streak: one good frame never clears it.
    let recovering = StubProducer(bytes: pfd)
    recovering.fault = .renderTrap
    let recoveringHost = PanelDisplay(
        requirements: requirements(critical: [.attitude, .tapes, .annunciation]),
        producer: recovering,
        atlas: GalleryAtlas(),
        policy: PanelHealthPolicy(
            livenessDeadlineMs: 60_000, recoveryFrames: 3, tickIntervalMs: 250
        )
    )
    _ = recoveringHost.render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    recovering.fault = nil
    for frame in 1...3 {
        let outcome = recoveringHost.render(
            pixelWidth: 480, pixelHeight: 360, nowMs: Double(frame) * 16
        )
        let cleared = frame == 3
        items.append(try item(
            name: cleared ? "recovery-cleared" : "recovery-frame-\(frame)",
            detail: cleared
                ? "The third consecutive good frame completes the streak and clears the latch"
                : "Good frame \(frame) of 3 after the fault: still covered, the streak is short",
            outcome: outcome, width: 480, height: 360,
            expectedFailure: !cleared, expectedReason: cleared ? .ok : .renderTrap
        ))
    }

    // Glyph-backed text, and the refusal to guess when no atlas is injected.
    let text = try corpus.bytes(for: "text-covered")
    let withAtlas = display(scene: text, critical: [.attitude])
        .render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    items.append(try item(
        name: "glyph-text",
        detail: "Corpus text-covered with an injected atlas: glyphs paint from the pack",
        outcome: withAtlas, width: 480, height: 360,
        expectedFailure: false, expectedReason: .ok
    ))
    let noAtlas = display(scene: text, critical: [.attitude], atlas: nil)
        .render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    items.append(try item(
        name: "glyph-text-no-atlas",
        detail: "The same scene without an atlas: no system-font fallback, the frame fails visibly",
        outcome: noAtlas, width: 480, height: 360,
        expectedFailure: true, expectedReason: .glyphAsset
    ))

    // A corpus-rejected scene: the layer gate fails the frame before any paint.
    let rejected = try corpus.bytes(for: "duplicate-layer")
    let gated = display(scene: rejected, critical: [.attitude])
        .render(pixelWidth: 480, pixelHeight: 360, nowMs: 0)
    items.append(try item(
        name: "rejected-duplicate-layer",
        detail: "Corpus duplicate-layer, rejected by the layer gate: nothing partial is visible",
        outcome: gated, width: 480, height: 360,
        expectedFailure: true, expectedReason: .sceneLayerContract
    ))

    return items
}
