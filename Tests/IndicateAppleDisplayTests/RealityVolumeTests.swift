import Foundation
import RealityKit
import Testing
import simd
@testable import IndicateAppleDisplay

@Test
@MainActor
func realityVolumeBuilderMaterializesTransformsHandlesUnderlaysAndClips() throws {
    let commands: [VolumeSceneCommand] = [
        .beginBand(.surfaceUnderlay),
        .save,
        .heightfieldGrid(
            cols: 3,
            rows: 3,
            origin: SIMD3(-0.2, -0.1, -0.2),
            stepX: 0.2,
            stepZ: 0.2,
            heights: [0, 0.01, 0.02, 0.01, 0.04, 0.02, 0, 0.01, 0]
        ),
        .underlayAnchor3D(
            kind: .planetaryGlobe,
            center: SIMD3(0, -0.05, 0),
            extent: SIMD3(0.5, 0.5, 0.5),
            orientation: SIMD4(0, 0, 0, 1),
            metersPerUnit: 1_000_000.0
        ),
        .restore,
        .endBand(.surfaceUnderlay),

        .beginBand(.volumes3D),
        .save,
        .translate3D(dx: 0.1, dy: 0.2, dz: -0.05),
        .sphere(mode: .fillStroke, center: .zero, radiusMeters: 0.04),
        .box3D(mode: .fill, min: SIMD3(-0.02, -0.02, -0.02), max: SIMD3(0.02, 0.02, 0.02)),
        .cylinder3D(
            mode: .fill,
            base: SIMD3(0, -0.1, 0),
            top: SIMD3(0, 0.1, 0),
            radiusMeters: 0.015
        ),
        .save,
        .clipBox3D(min: SIMD3(-0.05, -0.05, -0.05), max: SIMD3(0.05, 0.05, 0.05)),
        // Clipped sphere sits far outside the active clipBox3D and must be omitted.
        .sphere(mode: .fill, center: SIMD3(1.0, 1.0, 1.0), radiusMeters: 0.02),
        .restore,
        .restore,
        .endBand(.volumes3D),

        .beginBand(.billboards),
        .save,
        .attribute(group: 5),
        .billboardText(
            position: SIMD3(0, 0.25, 0),
            sizeMeters: 0.03,
            anchor: .center,
            text: "250KT"
        ),
        .restore,
        .endBand(.billboards),

        .beginBand(.handles),
        .save,
        .translate3D(dx: 0.15, dy: -0.05, dz: 0.20),
        .targetHandle(
            targetId: 77,
            kind: .manoeuvreNode,
            center: SIMD3(0.05, 0, 0),
            radiusMeters: 0.04
        ),
        .restore,
        .endBand(.handles),
    ]

    let bytes = try VolumeSceneEncoder.encode(commands)
    let validated = try VolumeSceneValidator.validateAndGroup(bytes)
    let snapshot = VolumeSnapshot(
        extent: Extent3D(widthMeters: 0.6, heightMeters: 0.45, depthMeters: 0.6),
        generation: 1,
        viewPose: ViewPose3D(focusLocal: SIMD3(0.01, 0, 0), zoomScale: 1.25),
        report: validated.report,
        bands: validated.bands
    )

    let builder = RealityVolumeBuilder()
    let root = builder.buildEntity(
        from: .valid(snapshot),
        fallbackExtent: snapshot.extent
    )
    #expect(root.name == "indicate.volume.root")
    #expect(root.children.count == 4)
    #expect(root.scale == SIMD3<Float>(repeating: 1.25))
    #expect(root.position == SIMD3<Float>(-0.01, 0, 0))

    // Verify band 2 has 3 primitives (clipped out-of-bounds sphere was omitted).
    let volumesBand = try #require(root.children.first { $0.name == "indicate.band.2" })
    #expect(volumesBand.children.count == 3)
    let firstPrimitive = try #require(volumesBand.children.first)
    #expect(simd_distance(firstPrimitive.position, SIMD3(0.1, 0.2, -0.05)) < 1e-5)

    // Verify underlay anchor component.
    let anchors = RealityVolumeBuilder.findUnderlayAnchors(in: root)
    #expect(anchors.count == 1)
    let anchorComp = try #require(anchors[0].components[IndicateUnderlayAnchorComponent.self])
    #expect(anchorComp.kind == .planetaryGlobe)
    #expect(anchorComp.metersPerUnit == 1_000_000.0)

    // Verify target handle collision component + translated center + ancestor lookup.
    let handles = RealityVolumeBuilder.findTargetHandles(in: root)
    #expect(handles.count == 1)
    let handleEntity = handles[0]
    #expect(handleEntity.components.has(CollisionComponent.self))
    let targetComp = try #require(RealityVolumeBuilder.resolveTarget(from: handleEntity))
    #expect(targetComp.targetId == TargetId(rawValue: 77))
    #expect(targetComp.kind == .manoeuvreNode)
    #expect(simd_distance(targetComp.centerLocal, SIMD3(0.20, -0.05, 0.20)) < 1e-5)

    // Verify child lookup walks up to parent handle entity.
    let childProbe = Entity()
    handleEntity.addChild(childProbe)
    #expect(RealityVolumeBuilder.resolveTarget(from: childProbe)?.targetId == TargetId(rawValue: 77))
}

@Test
@MainActor
func realityVolumeBuilderGeneratesFailureCageAndReplacesValidSceneOnFault() throws {
    let extent = Extent3D(widthMeters: 0.6, heightMeters: 0.45, depthMeters: 0.6)
    let builder = RealityVolumeBuilder()

    let cage = builder.buildFailureEntity(reason: .liveness, extent: extent)
    #expect(cage.name == "indicate.volume.failure")
    let cageComp = try #require(cage.components[IndicateFailureCageComponent.self])
    #expect(cageComp.reason == .liveness)
    #expect(cageComp.label == "D-106")
    // 12 wireframe box edges + 2 diagonal 3D red-X bars + 1 failure plaque = 15 children.
    #expect(cage.children.count == 15)
    let plaque = try #require(cage.children.first { $0.name == "indicate.failure.plaque" })
    let billboard = try #require(plaque.components[IndicateBillboardComponent.self])
    #expect(billboard.text == "DISPLAY FAIL D-106")

    // Verify in-place updateEntity removes previous handle entities when latching a fault.
    let sceneBytes = try VolumeSceneEncoder.encode([
        .beginBand(.handles),
        .save,
        .targetHandle(targetId: 5, kind: .point, center: .zero, radiusMeters: 0.03),
        .restore,
        .endBand(.handles),
    ])
    let validated = try VolumeSceneValidator.validateAndGroup(sceneBytes)
    let snapshot = VolumeSnapshot(
        extent: extent,
        generation: 1,
        viewPose: ViewPose3D(),
        report: validated.report,
        bands: validated.bands
    )
    let root = builder.buildEntity(from: .valid(snapshot), fallbackExtent: extent)
    #expect(RealityVolumeBuilder.findTargetHandles(in: root).count == 1)

    builder.updateEntity(root, with: .failed(.sceneLayerContract), fallbackExtent: extent)
    #expect(RealityVolumeBuilder.findTargetHandles(in: root).isEmpty)
    #expect(root.components[IndicateFailureCageComponent.self]?.label == "D-9")
}
