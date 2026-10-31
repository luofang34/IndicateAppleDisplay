import Foundation
import Testing
import simd
@testable import IndicateAppleDisplay

@Test
func everyVolumeSceneOpcodeRoundTripsThroughBinaryCodec() throws {
    let commands: [VolumeSceneCommand] = [
        .beginBand(.referenceGrid),
        .save,
        .stroke3D(color: SceneColor(red: 80, green: 90, blue: 100, alpha: 255), radiusMeters: 0.002),
        .line3D(a: SIMD3(-0.3, 0, 0), b: SIMD3(0.3, 0, 0)),
        .polyline3D([SIMD3(0, 0, -0.3), SIMD3(0, 0.1, 0), SIMD3(0, 0, 0.3)]),
        .restore,
        .endBand(.referenceGrid),

        .beginBand(.surfaceUnderlay),
        .save,
        .fillColor(SceneColor(red: 40, green: 140, blue: 60, alpha: 255)),
        .heightfieldGrid(
            cols: 2,
            rows: 3,
            origin: SIMD3(-0.2, -0.1, -0.2),
            stepX: 0.2,
            stepZ: 0.1,
            heights: [0.0, 0.02, 0.04, 0.05, 0.01, 0.03]
        ),
        .underlayAnchor3D(
            kind: .terrainPatch,
            center: SIMD3(0, -0.1, 0),
            extent: SIMD3(0.6, 0.2, 0.6),
            orientation: SIMD4(0, 0, 0, 1),
            metersPerUnit: 1000.0
        ),
        .restore,
        .endBand(.surfaceUnderlay),

        .beginBand(.volumes3D),
        .save,
        .translate3D(dx: 0.05, dy: 0.02, dz: -0.04),
        .rotateQuat(qx: 0, qy: 0.70710677, qz: 0, qw: 0.70710677),
        .clipBox3D(min: SIMD3(-0.5, -0.5, -0.5), max: SIMD3(0.5, 0.5, 0.5)),
        .sphere(mode: .fill, center: SIMD3(0, 0.1, 0), radiusMeters: 0.08),
        .box3D(mode: .stroke, min: SIMD3(-0.1, -0.1, -0.1), max: SIMD3(0.1, 0.1, 0.1)),
        .cylinder3D(
            mode: .fillStroke,
            base: SIMD3(0, -0.15, 0),
            top: SIMD3(0, 0.15, 0),
            radiusMeters: 0.04
        ),
        .restore,
        .endBand(.volumes3D),

        .beginBand(.symbols3D),
        .save,
        .ring3D(center: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0), radiusMeters: 0.12),
        .restore,
        .endBand(.symbols3D),

        .beginBand(.billboards),
        .save,
        .attribute(group: 3),
        .billboardText(
            position: SIMD3(0, 0.2, 0),
            sizeMeters: 0.025,
            anchor: .center,
            text: "FL180"
        ),
        .restore,
        .endBand(.billboards),

        .beginBand(.handles),
        .save,
        .targetHandle(
            targetId: 42,
            kind: .waypoint,
            center: SIMD3(0.1, 0.05, -0.1),
            radiusMeters: 0.03
        ),
        .restore,
        .endBand(.handles),
    ]

    let encoded = try VolumeSceneEncoder.encode(commands)
    #expect(encoded.first == VolumeSceneBackend.formatVersion)

    let decoded = try VolumeSceneDecoder.commands(encoded)
    #expect(decoded == commands)

    let report = try VolumeSceneValidator.validate(encoded)
    #expect(report.bandsPresent == [
        .referenceGrid,
        .surfaceUnderlay,
        .volumes3D,
        .symbols3D,
        .billboards,
        .handles,
    ])
    #expect(report.unknownOpcodes == 0)
    #expect(report.presentMask == 0b0111_0111)
}

@Test
func volumeSceneDecoderRejectsMalformedPayloadsAndReservedBandOpcodes() {
    // Empty and unsupported version byte.
    #expect(throws: VolumeSceneDecodeError.truncated) {
        _ = try VolumeSceneDecoder.commands([])
    }
    #expect(throws: VolumeSceneDecodeError.badVersion(2)) {
        _ = try VolumeSceneDecoder.commands([0x02])
    }

    // Non-unit quaternion in rotateQuat (0x04).
    var nonUnitQuat: [UInt8] = [0x01, 0x04, 16, 0]
    nonUnitQuat.appendSIMD4LE(SIMD4(0, 0, 0, 2.0))
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x04)) {
        _ = try VolumeSceneDecoder.commands(nonUnitQuat)
    }

    // Non-finite float in translate3D (0x03).
    var nanTranslate: [UInt8] = [0x01, 0x03, 12, 0]
    nanTranslate.appendSIMD3LE(SIMD3(.nan, 0, 0))
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x03)) {
        _ = try VolumeSceneDecoder.commands(nanTranslate)
    }

    // Inverted clipBox3D min > max (0x05).
    var invertedClip: [UInt8] = [0x01, 0x05, 24, 0]
    invertedClip.appendSIMD3LE(SIMD3(1, 0, 0))
    invertedClip.appendSIMD3LE(SIMD3(-1, 0, 0))
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x05)) {
        _ = try VolumeSceneDecoder.commands(invertedClip)
    }

    // targetHandle with targetId == 0 (0x13).
    var zeroTarget: [UInt8] = [0x01, 0x13, 21, 0]
    zeroTarget.appendUInt32LE(0)
    zeroTarget.append(HandleKind.point.rawValue)
    zeroTarget.appendSIMD3LE(.zero)
    zeroTarget.appendFloat32LE(0.05)
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x13)) {
        _ = try VolumeSceneDecoder.commands(zeroTarget)
    }

    // Unknown band id >= 9 in beginBand (0x50).
    let badBand: [UInt8] = [0x01, 0x50, 1, 0, 9]
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x50)) {
        _ = try VolumeSceneDecoder.commands(badBand)
    }

    // Reserved band-vocabulary opcode 0x52 is a hard decode error.
    let reservedBandOp: [UInt8] = [0x01, 0x52, 0, 0]
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x52)) {
        _ = try VolumeSceneDecoder.commands(reservedBandOp)
    }
}

@Test
func heightfieldAndBillboardBoundsAreEnforcedDuringDecode() {
    // cols < 2 in heightfieldGrid (0x27).
    var badGrid: [UInt8] = [0x01, 0x27]
    let sampleCount = 1 * 2
    badGrid.appendUInt16LE(UInt16(22 + 4 * sampleCount))
    badGrid.append(1)
    badGrid.append(2)
    badGrid.appendSIMD3LE(.zero)
    badGrid.appendFloat32LE(0.1)
    badGrid.appendFloat32LE(0.1)
    badGrid.appendFloat32LE(0.0)
    badGrid.appendFloat32LE(0.0)
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x27)) {
        _ = try VolumeSceneDecoder.commands(badGrid)
    }

    // cols * rows > 1024 (33 * 33 = 1089) in heightfieldGrid (0x27).
    var overGrid: [UInt8] = [0x01, 0x27]
    overGrid.appendUInt16LE(UInt16(22 + 4 * 1089))
    overGrid.append(33)
    overGrid.append(33)
    overGrid.appendSIMD3LE(.zero)
    overGrid.appendFloat32LE(0.1)
    overGrid.appendFloat32LE(0.1)
    for _ in 0..<1089 { overGrid.appendFloat32LE(0) }
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x27)) {
        _ = try VolumeSceneDecoder.commands(overGrid)
    }

    // Invalid UTF-8 in billboardText (0x30).
    var badText: [UInt8] = [0x01, 0x30, 18, 0]
    badText.appendSIMD3LE(.zero)
    badText.appendFloat32LE(0.02)
    badText.append(TextAnchor.left.rawValue)
    badText.append(0xff)
    #expect(throws: VolumeSceneDecodeError.badPayload(opcode: 0x30)) {
        _ = try VolumeSceneDecoder.commands(badText)
    }
}

@Test
func volumeSceneValidatorEnforcesOrderingEnvelopeStackAndUnknownOpcodePolicy() throws {
    // Missing outer save/restore isolation envelope.
    let unisolated = try VolumeSceneEncoder.encode([
        .beginBand(.volumes3D),
        .fillColor(SceneColor(red: 255, green: 0, blue: 0, alpha: 255)),
        .endBand(.volumes3D),
    ])
    #expect(throws: VolumeSceneLayerError.unisolatedState(.volumes3D)) {
        _ = try VolumeSceneValidator.validate(unisolated)
    }

    // Out-of-order bands (band 4 followed by band 2).
    let outOfOrder = try VolumeSceneEncoder.encode([
        .beginBand(.symbols3D), .save, .restore, .endBand(.symbols3D),
        .beginBand(.volumes3D), .save, .restore, .endBand(.volumes3D),
    ])
    #expect(throws: VolumeSceneLayerError.outOfOrder(.volumes3D)) {
        _ = try VolumeSceneValidator.validate(outOfOrder)
    }

    // Duplicate band.
    let duplicate = try VolumeSceneEncoder.encode([
        .beginBand(.symbols3D), .save, .restore, .endBand(.symbols3D),
        .beginBand(.symbols3D), .save, .restore, .endBand(.symbols3D),
    ])
    #expect(throws: VolumeSceneLayerError.duplicateBand(.symbols3D)) {
        _ = try VolumeSceneValidator.validate(duplicate)
    }

    // Command outside band.
    let outside = try VolumeSceneEncoder.encode([.save, .restore])
    #expect(throws: VolumeSceneLayerError.commandOutsideBand) {
        _ = try VolumeSceneValidator.validate(outside)
    }

    // Stack depth > 32 fails.
    var deepCommands: [VolumeSceneCommand] = [.beginBand(.volumes3D)]
    deepCommands += Array(repeating: VolumeSceneCommand.save, count: 33)
    deepCommands += Array(repeating: VolumeSceneCommand.restore, count: 33)
    deepCommands.append(.endBand(.volumes3D))
    let tooDeep = try VolumeSceneEncoder.encode(deepCommands)
    #expect(throws: VolumeSceneLayerError.stackOverCapacity(band: .volumes3D, depth: 33)) {
        _ = try VolumeSceneValidator.validate(tooDeep)
    }

    // Unknown opcode outside 0x50..0x5F fails by default, counts and skips when requested.
    let withUnknown = try VolumeSceneEncoder.encode([
        .beginBand(.symbols3D),
        .save,
        .unknown(opcode: 0x7a),
        .restore,
        .endBand(.symbols3D),
    ])
    #expect(throws: VolumeSceneLayerError.unknownOpcodeRejected(count: 1)) {
        _ = try VolumeSceneValidator.validate(withUnknown)
    }
    let skipped = try VolumeSceneValidator.validate(withUnknown, unknownOpcodes: .countAndSkip)
    #expect(skipped.unknownOpcodes == 1)
    #expect(skipped.bandsPresent == [.symbols3D])

    // Canonical single-band wire vector for cross-language verification.
    let canonical = try VolumeSceneEncoder.encode([
        .beginBand(.volumes3D),
        .save,
        .sphere(mode: .fill, center: SIMD3(0, 0.25, -0.5), radiusMeters: 0.125),
        .restore,
        .endBand(.volumes3D),
    ])
    let canonicalHex = canonical.map { String(format: "%02x", $0) }.joined()
    #expect(
        canonicalHex
            == "01"
            + "50010002"
            + "010000"
            + "23110000000000000000803e000000bf0000003e"
            + "020000"
            + "51010002"
    )
}

private func decodeHex(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        if let byte = UInt8(hex[index..<next], radix: 16) {
            out.append(byte)
        }
        index = next
    }
    return out
}

@Test
@MainActor
func rustEmittedVolumeSceneAndWireVectorsDecodeIdentically() throws {
    // 1. Exact 180-byte VolumeScene emitted by Rust indicate-instrument-scene::volume.
    let rustVolumeHex =
        "015001000401000010040000dc78ff2311000000000000cdcc4c3d000000000ad7a33c02000051010004"
        + "5001000501000012010006301900000000008fc2f53d00000000bc74933c01414c54203435303002000051010005"
        + "50010006010000131500010000000200000000cdcc4c3d000000008fc2f53c02000051010006"
        + "5001000701000030250000000000cdcc4c3e000000006f12833c0153494d202f204e4f5420464f5220464c4947485402000051010007"
    let rustVolumeBytes = decodeHex(rustVolumeHex)
    #expect(rustVolumeBytes.count == 180)
    let validated = try VolumeSceneValidator.validateAndGroup(rustVolumeBytes)
    #expect(validated.report.bandsPresent == [.symbols3D, .billboards, .handles, .annunciation])
    let reencoded = try VolumeSceneEncoder.encode(try VolumeSceneDecoder.commands(rustVolumeBytes))
    #expect(reencoded == rustVolumeBytes)

    let snapshot = VolumeSnapshot(
        extent: Extent3D(widthMeters: 0.6, heightMeters: 0.45, depthMeters: 0.6),
        generation: 1,
        viewPose: ViewPose3D(),
        report: validated.report,
        bands: validated.bands
    )
    let root = RealityVolumeBuilder().buildEntity(
        from: .valid(snapshot),
        fallbackExtent: snapshot.extent
    )
    #expect(root.children.count == 4)

    // 2. Exact 65-byte InteractionFrame emitted by Rust indicate-interaction.
    let rustInteractionBytes = decodeHex(
        "01032d00010000000700000040420f0000000000020000000000000000000000000ad7a33c000000000ad723bc0000000000000000000000000000803f0000a03f"
    )
    let interaction = try InteractionFrame.decode(rustInteractionBytes)
    #expect(interaction.stamp.sequence == 7)
    #expect(try interaction.encode() == rustInteractionBytes)

    // 3. Exact 48-byte ViewPose3D emitted by Rust indicate-interaction.
    let rustPoseBytes = decodeHex(
        "010000000ad7a33c000000000ad723bc0000000000000000000000000000803f0000a03f010000000000000000000000"
    )
    let pose = try ViewPose3D.decode(rustPoseBytes)
    #expect(pose.zoomScale == 1.25)
    #expect(pose.activeTarget == TargetId(rawValue: 1))
    #expect(try pose.encode() == rustPoseBytes)

    // 4. Exact 34-byte custom IntentRequest emitted by Rust indicate-intent.
    let rustIntentBytes = decodeHex(
        "01000100000001000000f4010000000000008bc39e63469c0d7c0100040001000000"
    )
    let intent = try IntentRequest.decode(rustIntentBytes)
    #expect(intent.payload == .custom(
        namespace: IntentNamespace.domain("indicate.volumes"),
        opcode: 1,
        bytes: [1, 0, 0, 0]
    ))
    #expect(try intent.encode() == rustIntentBytes)

    // 5. Exact 88-byte DrawContextPacket emitted by Rust indicate-instrument-descriptor.
    let rustContextBytes = decodeHex(
        "010364000200000000000100010200000001000001000000010000000ad7a33c000000000ad723bc0000000000000000000000000000803f0000a03f01000000000000000000000008001000000006000000010002000200"
    )
    let context = try DrawContextPacket.decode(rustContextBytes)
    #expect(context.underlay == UnderlayStatus(available: true, calibrated: true, qualityPercent: 100))
    #expect(context.aux(.terrainPatch3D) == [1, 0, 2, 0, 2, 0])
    #expect(try context.encode() == rustContextBytes)
}
