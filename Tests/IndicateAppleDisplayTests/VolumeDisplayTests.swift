import Foundation
import Testing
import simd
@testable import IndicateAppleDisplay

private func makeRequirements(
    requiredBands: Set<VolumeBand> = [.volumes3D, .symbols3D],
    unknownOpcodes: UnknownOpcodePolicy = .failFrame
) -> VolumeRequirements {
    let canonical = Extent3D(widthMeters: 0.60, heightMeters: 0.45, depthMeters: 0.60)
    return VolumeRequirements(
        id: "terrain-volume",
        title: "3D Terrain Volume",
        requiredBands: requiredBands,
        extentMin: Extent3D(widthMeters: 0.30, heightMeters: 0.30, depthMeters: 0.30),
        extentMax: Extent3D(widthMeters: 1.50, heightMeters: 1.50, depthMeters: 1.50),
        canonicalExtent: canonical,
        viewLimits: .volumetricDefault,
        underlay: .volumetricTerrain3D,
        unknownOpcodes: unknownOpcodes,
        preferredFramesPerSecond: 90
    )
}

private func validVolumeSceneBytes(includeGrid: Bool = true) throws -> [UInt8] {
    var cmds: [VolumeSceneCommand] = []
    if includeGrid {
        cmds += [
            .beginBand(.referenceGrid),
            .save,
            .line3D(a: SIMD3(-0.2, 0, 0), b: SIMD3(0.2, 0, 0)),
            .restore,
            .endBand(.referenceGrid),
        ]
    }
    cmds += [
        .beginBand(.volumes3D),
        .save,
        .fillColor(SceneColor(red: 0, green: 200, blue: 120, alpha: 255)),
        .sphere(mode: .fill, center: .zero, radiusMeters: 0.05),
        .restore,
        .endBand(.volumes3D),
        .beginBand(.symbols3D),
        .save,
        .ring3D(center: .zero, normal: SIMD3(0, 1, 0), radiusMeters: 0.1),
        .restore,
        .endBand(.symbols3D),
    ]
    return try VolumeSceneEncoder.encode(cmds)
}

@Test
func volumeRequirementsRejectUnknownBandBitsAndMissingRequiredBands() throws {
    let ext = Extent3D(widthMeters: 0.6, heightMeters: 0.45, depthMeters: 0.6)
    // Bit 9 is outside 0...8 and must be rejected.
    #expect(VolumeRequirements(
        id: "bad",
        title: "Bad",
        requiredBandMask: 1 << 9,
        extentMin: ext,
        extentMax: ext,
        canonicalExtent: ext
    ) == nil)

    let validReq = try #require(VolumeRequirements(
        id: "good",
        title: "Good",
        requiredBandMask: (1 << 2) | (1 << 4),
        extentMin: ext,
        extentMax: ext,
        canonicalExtent: ext
    ))
    #expect(validReq.requiredBands == [.volumes3D, .symbols3D])

    // Scene omitting required .symbols3D band fails with .sceneCriticalLayersMissing.
    let incompleteBytes = try VolumeSceneEncoder.encode([
        .beginBand(.volumes3D), .save, .restore, .endBand(.volumes3D),
    ])
    let display = VolumeDisplay(
        requirements: validReq,
        producer: ClosureVolumeProducer { _, _ in
            VolumeFrame(bytes: incompleteBytes, generation: 1)
        }
    )
    let outcome = display.render(nowMs: 10)
    #expect(outcome.showingFailure)
    #expect(outcome.reason == .sceneCriticalLayersMissing)
    #expect(outcome.presentation == .failed(.sceneCriticalLayersMissing))
}

@Test
func volumeDisplayLatchesFaultAndRequiresThirtyAdvancingGenerationsToRecover() throws {
    final class Box: @unchecked Sendable {
        var shouldFail = true
        var generation: UInt32 = 1
        var sceneBytes: [UInt8] = []
    }
    let state = Box()
    state.sceneBytes = try validVolumeSceneBytes()

    let display = VolumeDisplay(
        requirements: makeRequirements(),
        producer: ClosureVolumeProducer { _, _ in
            if state.shouldFail {
                throw ProducerFault(reason: .stateMalformed)
            }
            return VolumeFrame(bytes: state.sceneBytes, generation: state.generation)
        }
    )

    // Fault latches immediately.
    let failed = display.render(nowMs: 100)
    #expect(failed.showingFailure)
    #expect(failed.reason == .stateMalformed)
    #expect(failed.health.latched)

    // Producer recovers, but repeated generation earns zero recovery credit.
    state.shouldFail = false
    state.generation = 10
    let firstGood = display.render(nowMs: 116)
    #expect(firstGood.showingFailure)
    #expect(firstGood.health.goodStreak == 1)

    let duplicateGen = display.render(nowMs: 132)
    #expect(duplicateGen.showingFailure)
    #expect(duplicateGen.health.goodStreak == 1)
    #expect(duplicateGen.health.counters.duplicates == 1)

    // 28 more advancing generations bring goodStreak to 29 (still latched).
    for step in 1...28 {
        state.generation &+= 1
        let mid = display.render(nowMs: 132 + Double(step) * 16)
        #expect(mid.showingFailure)
        #expect(mid.health.goodStreak == 1 + step)
    }

    // 30th consecutive advancing generation clears the latch!
    state.generation &+= 1
    let recovered = display.render(nowMs: 700)
    #expect(!recovered.showingFailure)
    #expect(recovered.reason == .ok)
    #expect(!recovered.health.latched)
    #expect(recovered.health.counters.recoveries == 1)
    if case let .valid(snapshot) = recovered.presentation {
        #expect(snapshot.bands.map(\.band) == [.referenceGrid, .volumes3D, .symbols3D])
    } else {
        Issue.record("Expected .valid presentation on 30th recovery generation")
    }
}

@Test
func volumeWatchdogDistinguishesSchedulerStarvationFromStaleProducer() throws {
    let sceneBytes = try validVolumeSceneBytes()
    let display = VolumeDisplay(
        requirements: makeRequirements(),
        producer: ClosureVolumeProducer { _, _ in
            VolumeFrame(bytes: sceneBytes, generation: 1)
        },
        nowMs: 0
    )

    _ = display.render(nowMs: 0)
    #expect(!display.health.display.showFailure)

    // A starved tick (> 2 * 250ms = 500ms jump) re-arms deadline instead of tripping liveness.
    let afterSuspension = display.tick(nowMs: 2_500)
    #expect(!afterSuspension.showFailure)
    #expect(display.health.snapshot.counters.starvedTicks == 1)

    // Normal 250ms watchdog ticks without advancing generations trip liveness strictly past 1000ms.
    #expect(!display.tick(nowMs: 2_750).showFailure)
    #expect(!display.tick(nowMs: 3_000).showFailure)
    #expect(!display.tick(nowMs: 3_250).showFailure)
    #expect(!display.tick(nowMs: 3_500).showFailure)
    let tripped = display.tick(nowMs: 3_750)
    #expect(tripped.showFailure)
    #expect(tripped.reason == .liveness)
    #expect(display.health.snapshot.counters.livenessTrips == 1)
}

@Test
func declutterDropsReferenceGridWhilePreservingCriticalBands() throws {
    let sceneBytes = try validVolumeSceneBytes(includeGrid: true)
    let display = VolumeDisplay(
        requirements: makeRequirements(),
        producer: ClosureVolumeProducer { _, _ in
            VolumeFrame(bytes: sceneBytes, generation: 1)
        },
        initialPose: ViewPose3D(decluttered: true)
    )
    let outcome = display.render(nowMs: 20)
    #expect(!outcome.showingFailure)
    guard case let .valid(snapshot) = outcome.presentation else {
        Issue.record("Expected valid decluttered snapshot")
        return
    }
    #expect(snapshot.bands.map(\.band) == [.volumes3D, .symbols3D])
}
