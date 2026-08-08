import CoreGraphics
import Foundation
import Testing
@testable import InstrumentSceneKit

private func hex(_ text: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex, text.index(after: index) < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        if let byte = UInt8(text[index..<next], radix: 16) { result.append(byte) }
        index = next
    }
    return result
}

/// A filled rect inside the Attitude layer.
private let attitudeScene = hex(
    "0150010001010000100400ffffffff2311000100000040000000400000a0410000a04102000051010001"
)

/// The same shape with one opcode this revision does not know.
private let unknownOpcodeScene = hex("01500100010100007f0200090902000051010001")

private let frame = CGRect(x: 0, y: 0, width: 480, height: 360)

private func requirements(
    critical: Set<SceneLayer> = [.attitude],
    unknown: UnknownOpcodePolicy = .failFrame
) -> PanelRequirements {
    PanelRequirements(
        id: "test", title: "Test",
        criticalLayers: critical,
        frameMin: frame.size, frameMax: frame.size, canonicalFrame: frame.size,
        unknownOpcodes: unknown
    )
}

private final class StubProducer: SceneProducing {
    var bytes: [UInt8]
    var generation: UInt32 = 1
    var fault: DisplayReason?

    init(bytes: [UInt8]) { self.bytes = bytes }

    func frame(designFrame _: CGRect) throws -> SceneFrame {
        if let fault { throw ProducerFault(reason: fault) }
        return SceneFrame(bytes: bytes, generation: generation)
    }
}

private final class CountingAtlas: GlyphAtlas, @unchecked Sendable {
    let cellWidth = 5
    let cellHeight = 7
    let advance = 6
    private(set) var lookups = 0

    func rows(for scalar: UInt32) -> [UInt8]? {
        lookups += 1
        return [UInt8](repeating: 0b10101, count: 7)
    }
}

// MARK: - Commit discipline

@Test
func aHealthyFrameCommitsAtTheRequestedSize() {
    let display = PanelDisplay(requirements: requirements(), producer: StubProducer(bytes: attitudeScene))
    let outcome = display.render(pixelWidth: 240, pixelHeight: 180, nowMs: 0)
    #expect(!outcome.showingFailure)
    #expect(outcome.reason == .ok)
    #expect(outcome.image?.width == 240)
    #expect(outcome.report?.layersPresent == [.attitude])
}

@Test
func aProducerFaultCoversInsteadOfLeavingTheLastGoodFrameVisible() {
    let producer = StubProducer(bytes: attitudeScene)
    let display = PanelDisplay(requirements: requirements(), producer: producer)
    #expect(!display.render(pixelWidth: 64, pixelHeight: 64, nowMs: 0).showingFailure)

    producer.fault = .stateWriteFailed
    let outcome = display.render(pixelWidth: 64, pixelHeight: 64, nowMs: 16)
    #expect(outcome.showingFailure)
    #expect(outcome.reason == .stateWriteFailed)
    // A covered frame still yields an image: the caller must have something to
    // present, or the previous good frame stays on screen by default.
    #expect(outcome.image != nil)
}

@Test
func aSceneMissingACriticalLayerIsNotCommitted() {
    // The layer gate accepts an attitude-only scene. Whether that is *enough*
    // is the panel's question, and a guidance panel without guidance is broken
    // rather than sparse.
    let display = PanelDisplay(
        requirements: requirements(critical: [.attitude, .guidance]),
        producer: StubProducer(bytes: attitudeScene)
    )
    let outcome = display.render(pixelWidth: 64, pixelHeight: 64, nowMs: 0)
    #expect(outcome.showingFailure)
    #expect(outcome.reason == .sceneCriticalLayersMissing)
}

@Test
func anUnknownOpcodeFailsTheFrameByDefaultAndSkipsWhenAsked() {
    let failing = PanelDisplay(
        requirements: requirements(), producer: StubProducer(bytes: unknownOpcodeScene)
    )
    let covered = failing.render(pixelWidth: 64, pixelHeight: 64, nowMs: 0)
    #expect(covered.showingFailure)
    #expect(covered.reason == .unknownOpcode)

    let skipping = PanelDisplay(
        requirements: requirements(unknown: .countAndSkip),
        producer: StubProducer(bytes: unknownOpcodeScene)
    )
    let painted = skipping.render(pixelWidth: 64, pixelHeight: 64, nowMs: 0)
    #expect(!painted.showingFailure)
    #expect(painted.report?.unknownOpcodes == 1)
}

@Test
func identicalFramesSummariseIdenticallySoAHostCanPublishOnChange() {
    // A display link delivers a healthy panel up to 120 times a second. A host
    // that mirrors every outcome into observable state rebuilds its interface
    // at that rate until it stops responding, so the summary must be equal
    // across frames that show the same thing — which means excluding the
    // generation, the one field that always differs.
    let producer = StubProducer(bytes: attitudeScene)
    let display = PanelDisplay(requirements: requirements(), producer: producer)
    let first = display.render(pixelWidth: 64, pixelHeight: 64, nowMs: 0)
    // A real producer advances per render, which is exactly what must not
    // reach a host as a change worth republishing.
    producer.generation &+= 1
    let second = display.render(pixelWidth: 64, pixelHeight: 64, nowMs: 8)
    #expect(first.generation != second.generation)
    #expect(first.summary == second.summary)
}

@Test
func aFrameWorthShowingDifferentlySummarisesDifferently() {
    // The other half of the claim: publishing on change must not mean missing
    // a change. A covered frame has to compare unequal to a shown one.
    let producer = StubProducer(bytes: attitudeScene)
    let display = PanelDisplay(requirements: requirements(), producer: producer)
    let healthy = display.render(pixelWidth: 64, pixelHeight: 64, nowMs: 0)

    producer.fault = .renderTrap
    let covered = display.render(pixelWidth: 64, pixelHeight: 64, nowMs: 16)
    #expect(healthy.summary != covered.summary)
    #expect(covered.summary.showingFailure)
    #expect(covered.summary.reason == .renderTrap)
}

// MARK: - Latch and recovery

@Test
func oneGoodFrameDoesNotClearALatchedFailure() {
    var health = PanelHealth(policy: PanelHealthPolicy(recoveryFrames: 30))
    health.reportFailure(nowMs: 0, reason: .paintFailed)

    for index in 1..<30 {
        let display = health.reportSuccess(nowMs: Double(index), generation: UInt32(index))
        #expect(display.showFailure, "cleared after \(index) frames, needs 30")
    }
    let cleared = health.reportSuccess(nowMs: 30, generation: 30)
    #expect(!cleared.showFailure)
    #expect(health.snapshot.counters.recoveries == 1)
}

@Test
func aRepeatedGenerationEarnsNoFreshnessCredit() {
    var health = PanelHealth(policy: PanelHealthPolicy(recoveryFrames: 2))
    health.reportFailure(nowMs: 0, reason: .renderTrap)
    health.reportSuccess(nowMs: 1, generation: 7)
    // The same generation again is the producer standing still, which is the
    // failure the watchdog exists to catch — not a second good frame.
    let stillCovered = health.reportSuccess(nowMs: 2, generation: 7)
    #expect(stillCovered.showFailure)
    #expect(health.snapshot.counters.duplicates == 1)
    #expect(health.snapshot.goodStreak == 1)
}

@Test
func aStalledProducerTripsLivenessOnTicksThatArriveOnCadence() {
    var health = PanelHealth(policy: PanelHealthPolicy(livenessDeadlineMs: 1000, tickIntervalMs: 250))
    health.reportSuccess(nowMs: 0, generation: 1)
    for now in stride(from: 250.0, through: 1000.0, by: 250.0) {
        #expect(!health.tick(nowMs: now).showFailure, "latched early at \(now)")
    }
    let tripped = health.tick(nowMs: 1250)
    #expect(tripped.showFailure)
    #expect(tripped.reason == .liveness)
    #expect(health.snapshot.counters.livenessTrips == 1)
}

@Test
func aStarvedTickReArmsTheDeadlineRatherThanJudgingWithAStoppedClock() {
    // A watchdog whose own scheduling was suspended cannot distinguish a dead
    // renderer from its own absence, so it must not latch.
    var health = PanelHealth(policy: PanelHealthPolicy(livenessDeadlineMs: 1000, tickIntervalMs: 250))
    health.reportSuccess(nowMs: 0, generation: 1)
    let starved = health.tick(nowMs: 60_000)
    #expect(!starved.showFailure)
    #expect(health.snapshot.counters.starvedTicks == 1)
    // Having re-armed, ticks back on cadence still catch a genuinely dead
    // loop — within one deadline of scheduling resuming, which is exactly when
    // someone is looking at the display again.
    for now in stride(from: 60_250.0, through: 61_000.0, by: 250.0) {
        #expect(!health.tick(nowMs: now).showFailure, "latched early at \(now)")
    }
    #expect(health.tick(nowMs: 61_250).reason == .liveness)
}

@Test
func resetIsTheOnlyWayToDismissALatchWithoutRecovering() {
    var health = PanelHealth()
    health.reportFailure(nowMs: 0, reason: .glyphAsset)
    #expect(health.display.showFailure)
    health.reset(nowMs: 0)
    #expect(!health.display.showFailure)
    #expect(health.snapshot.counters.failures == 0)
}

// MARK: - Failure page

@Test
func theFailurePageNeedsNeitherASceneNorAnAtlas() throws {
    // The producer or the glyph pack may be the failed component, so a failure
    // page that depended on either could not appear when it is needed.
    let image = try #require(FailurePage.image(pixelWidth: 120, pixelHeight: 90, reason: .liveness))
    #expect(image.width == 120)
    #expect(image.height == 90)
    #expect(DisplayReason.liveness.label == "D-106")
}

@Test
func everyDisplayReasonCodeIsDistinct() {
    let codes = DisplayReason.allCases.map(\.rawValue)
    #expect(Set(codes).count == codes.count, "codes are append-only and never reused")
}

@Test
func paintFailuresCarryTheDiagnosticTheirRemedyNeeds() {
    #expect(SceneRenderError.missingGlyph("Z").displayReason == .glyphAsset)
    #expect(SceneRenderError.textWithoutAtlas.displayReason == .glyphAsset)
    #expect(SceneRenderError.nonFiniteValue.displayReason == .paintFailed)
    #expect(SceneLayerError.decode(.truncated).displayReason == .sceneFraming)
    #expect(SceneLayerError.commandOutsideLayer.displayReason == .sceneLayerContract)
}

// MARK: - Descriptors

@Test
func anUnplaceableCriticalityBitIsRejectedRatherThanTreatedAsSatisfied() {
    #expect(PanelRequirements(
        id: "future", title: "Future", criticalLayerMask: 1 << 6,
        frameMin: CGSize(width: 480, height: 360),
        frameMax: CGSize(width: 480, height: 360),
        canonicalFrame: CGSize(width: 480, height: 360)
    ) == nil)

    // A canonical frame the panel's own range excludes is refused too: it
    // names a frame the evidence describes and the panel will not emit.
    #expect(PanelRequirements(
        id: "inconsistent", title: "Inconsistent", criticalLayerMask: 1 << 1,
        frameMin: CGSize(width: 480, height: 360),
        frameMax: CGSize(width: 480, height: 360),
        canonicalFrame: CGSize(width: 960, height: 720)
    ) == nil)

    let known = PanelRequirements(
        id: "pfd", title: "PFD",
        criticalLayerMask: (1 << 1) | (1 << 2) | (1 << 4),
        frameMin: CGSize(width: 480, height: 360),
        frameMax: CGSize(width: 480, height: 360),
        canonicalFrame: CGSize(width: 480, height: 360)
    )
    #expect(known?.criticalLayers == [.attitude, .tapes, .annunciation])
    #expect(known?.canonicalFrame.width == 480)
}

// MARK: - Glyph cache

@Test
func aGlyphOutlineIsBuiltOncePerScalarNotOncePerFrame() throws {
    let scene = hex(
        "0150010002010000100400ffffffff3012000000a841050000704300003443313033303002000051010002"
    )
    let atlas = CountingAtlas()
    let display = PanelDisplay(
        requirements: requirements(critical: [.tapes]),
        producer: StubProducer(bytes: scene),
        atlas: atlas
    )
    _ = display.render(pixelWidth: 256, pixelHeight: 256, nowMs: 0)
    let afterFirst = atlas.lookups
    #expect(afterFirst > 0)

    for index in 1...20 {
        _ = display.render(pixelWidth: 256, pixelHeight: 256, nowMs: Double(index))
    }
    #expect(atlas.lookups == afterFirst, "outlines must survive across frames")
}
