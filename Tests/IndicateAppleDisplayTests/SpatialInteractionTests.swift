import Foundation
import Testing
import simd
@testable import IndicateAppleDisplay

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

@Test
func interactionFrameEncodesExactWireLayoutAcrossAllEventVariants() throws {
    let stamp = InteractionStamp(
        deviceId: 0x0102_0304,
        sequence: 7,
        timestampUs: 1_000_000
    )

    let activate = InteractionFrame(
        stamp: stamp,
        event: .activate(target: TargetId(rawValue: 9), pointLocal: SIMD3(0.25, -0.5, 1.0))
    )
    let activateBytes = try activate.encode()
    #expect(activateBytes.count == 36)
    #expect(
        hex(activateBytes)
            == "01011000"
            + "04030201"
            + "07000000"
            + "40420f0000000000"
            + "09000000"
            + "0000803e000000bf0000803f"
    )
    #expect(try InteractionFrame.decode(activateBytes) == activate)

    let samples: [SpatialEvent] = [
        .drag3D(
            phase: .changed,
            target: TargetId(rawValue: 3),
            originLocal: SIMD3(0, 0.1, 0),
            deltaLocal: SIMD3(0.02, -0.01, 0.03)
        ),
        .transform3D(
            phase: .changed,
            pivotLocal: .zero,
            translationLocal: SIMD3(0.1, 0, -0.1),
            rotation: SIMD4(0, 0.70710677, 0, 0.70710677),
            scale: 1.25
        ),
        .rayHover(
            target: TargetId(rawValue: 12),
            originLocal: SIMD3(0, 0.2, 0.5),
            directionLocal: SIMD3(0, 0, -1)
        ),
        .discreteKey(keyId: 0x002a, state: .pressed),
        .scrubTime(offsetSeconds: -120.5),
        .resetView,
    ]
    for event in samples {
        let frame = InteractionFrame(stamp: stamp, event: event)
        let wire = try frame.encode()
        #expect(wire.count <= maxInteractionBytes)
        #expect(try InteractionFrame.decode(wire) == frame)
    }

    // Forward-compatible unknown opcode skips payload cleanly.
    var futureWire: [UInt8] = [1, 0x7e]
    futureWire.appendUInt16LE(4)
    futureWire.appendUInt32LE(stamp.deviceId)
    futureWire.appendUInt32LE(stamp.sequence)
    futureWire.appendUInt64LE(stamp.timestampUs)
    futureWire.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])
    let decodedFuture = try InteractionFrame.decode(futureWire)
    #expect(decodedFuture.stamp == stamp)
    #expect(decodedFuture.event == .unknown(0x7e))
}

@Test
func viewPose3DEncodesExact48ByteLayoutAndRejectsMalformedBytes() throws {
    let defaultPose = ViewPose3D()
    let defaultBytes = try defaultPose.encode()
    #expect(defaultBytes.count == 48)
    #expect(
        hex(defaultBytes)
            == "01000000"
            + "000000000000000000000000"
            + "0000000000000000000000000000803f"
            + "0000803f"
            + "00000000"
            + "0000000000000000"
    )
    #expect(try ViewPose3D.decode(defaultBytes) == defaultPose)

    let customPose = ViewPose3D(
        focusLocal: SIMD3(0.25, -0.5, 0.75),
        orientation: SIMD4(0, 0, 0, 1),
        zoomScale: 2.0,
        activeTarget: TargetId(rawValue: 17),
        timeOffsetSeconds: 45.0,
        decluttered: true
    )
    let customBytes = try customPose.encode()
    #expect(customBytes.count == viewPoseBytes)
    #expect(customBytes[1] == 0x01)
    #expect(try ViewPose3D.decode(customBytes) == customPose)

    // Reserved flag bit must fail closed.
    var badFlags = customBytes
    badFlags[1] = 0x02
    #expect(throws: SpatialInteractionError.reservedFlags(0x02)) {
        _ = try ViewPose3D.decode(badFlags)
    }

    // Non-zero reserved byte [2] must fail closed.
    var badReserved = customBytes
    badReserved[2] = 1
    #expect(throws: SpatialInteractionError.reservedBytesNonZero) {
        _ = try ViewPose3D.decode(badReserved)
    }
}

@Test
func viewPoseControllerClampsPanZoomOrbitAndScrubDeterministically() throws {
    var pose = ViewPose3D()
    let limits = ViewLimits(
        panLimit: 0.5,
        zoomMin: 0.5,
        zoomMax: 4.0,
        timeScrubLimitSeconds: 60.0,
        allowOrbit: true,
        allowTimeScrub: true
    )

    let dragOutcome = try ViewPoseController.apply(
        .drag3D(
            phase: .changed,
            target: TargetId(rawValue: 5),
            originLocal: .zero,
            deltaLocal: SIMD3(2.0, -3.0, 0.25)
        ),
        to: &pose,
        limits: limits
    )
    #expect(dragOutcome == .viewUpdated)
    #expect(pose.focusLocal == SIMD3(0.5, -0.5, 0.25))
    #expect(pose.activeTarget == TargetId(rawValue: 5))

    let rot90Y = SIMD4<Float>(0, 0.70710677, 0, 0.70710677)
    let transformOutcome = try ViewPoseController.apply(
        .transform3D(
            phase: .changed,
            pivotLocal: .zero,
            translationLocal: .zero,
            rotation: rot90Y,
            scale: 10.0
        ),
        to: &pose,
        limits: limits
    )
    #expect(transformOutcome == .viewUpdated)
    #expect(pose.zoomScale == 4.0)
    #expect(abs(pose.orientation.y - 0.70710677) < 1e-4)

    let scrubOutcome = try ViewPoseController.apply(
        .scrubTime(offsetSeconds: -500.0),
        to: &pose,
        limits: limits
    )
    #expect(scrubOutcome == .viewUpdated)
    #expect(pose.timeOffsetSeconds == -60.0)

    let activateOutcome = try ViewPoseController.apply(
        .activate(target: TargetId(rawValue: 88), pointLocal: SIMD3(0.1, 0.2, 0.3)),
        to: &pose,
        limits: limits
    )
    #expect(
        activateOutcome == .targetActivated(
            target: TargetId(rawValue: 88),
            pointLocal: SIMD3(0.1, 0.2, 0.3)
        )
    )

    // Locked limits refuse pan, orbit, zoom, and scrub.
    var lockedPose = ViewPose3D()
    #expect(
        try ViewPoseController.apply(
            .scrubTime(offsetSeconds: 10.0),
            to: &lockedPose,
            limits: .locked
        ) == .ignored
    )
    #expect(lockedPose == ViewPose3D())

    // Reset restores canonical pose.
    _ = try ViewPoseController.apply(.resetView, to: &pose, limits: limits)
    #expect(pose.focusLocal == .zero)
    #expect(pose.zoomScale == 1.0)
    #expect(pose.activeTarget == .none)
    #expect(pose.timeOffsetSeconds == 0.0)
}

@Test
func intentNamespaceFnv1aVectorsAndWireCodecsMatchFrozenSpec() throws {
    #expect(IntentNamespace.core.rawValue == 0)
    #expect(IntentNamespace.domain("").rawValue == 0xcbf2_9ce4_8422_2325)
    #expect(IntentNamespace.domain("foobar").rawValue == 0x8594_4171_f739_67e8)
    #expect(IntentNamespace.domain("fms").rawValue == 0xdcab_9118_fed3_e65d)
    #expect(IntentNamespace.domain("xvs").rawValue == 0xbfc8_a319_8001_ad50)
    #expect(IntentNamespace.domain("orbital").rawValue == 0xcbd3_56a9_7121_4ad2)
    #expect(IntentNamespace.domain("indicate.fms.v1").rawValue == 0xed5b_fbe3_fa5a_2bf5)

    let stamp = IntentStamp(deviceId: 1, sequence: 42, issuedAtMs: 250_000)
    let corePayloads: [IntentPayload] = [
        .selectBaro(hpa: 1013.25),
        .setHeadingBug(radians: 1.5, reference: .magnetic),
        .selectAltitude(meters: 3048.0, datumClass: .baroIndicated, origin: 0, geoidModel: 1),
        .selectNavSource(.gps),
        .acknowledgeAlert(alertId: 0x0102),
        .acknowledgeAllAlerts,
        .selectPage(pageId: 3),
        .declutter(enabled: true),
        .pressSoftkey(keyId: 7),
        .custom(
            namespace: .domain("orbital"),
            opcode: 0x0010,
            bytes: [0x01, 0x02, 0x03, 0x04]
        ),
    ]

    for payload in corePayloads {
        let request = IntentRequest(stamp: stamp, payload: payload)
        let bytes = try request.encode()
        #expect(bytes.count >= 30)
        #expect(bytes.count <= maxIntentWireBytes)
        #expect(try IntentRequest.decode(bytes) == request)
    }

    let selectAltWire = try IntentRequest(
        stamp: stamp,
        payload: .selectAltitude(meters: 3048.0, datumClass: .baroIndicated, origin: 0, geoidModel: 1)
    ).encode()
    #expect(
        hex(selectAltWire)
            == "0100"
            + "010000002a00000090d0030000000000"
            + "0000000000000000"
            + "03000700"
            + "00803e45010001"
    )

    let customOrbitalWire = try IntentRequest(
        stamp: stamp,
        payload: .custom(
            namespace: .domain("orbital"),
            opcode: 0x0010,
            bytes: [0x01, 0x02, 0x03, 0x04]
        )
    ).encode()
    #expect(
        hex(customOrbitalWire)
            == "0100"
            + "010000002a00000090d0030000000000"
            + "d24a2171a956d3cb"
            + "10000400"
            + "01020304"
    )

    // EchoSummary 12-byte wire layout.
    let idleBytes = EchoSummary.idle.encode()
    #expect(idleBytes.count == echoSummaryBytes)
    #expect(hex(idleBytes) == "010000000000000000000000")
    #expect(try EchoSummary.decode(idleBytes) == .idle)

    let activeEcho = EchoSummary(
        baro: .pending,
        headingBug: .confirmed,
        altitude: .overdue,
        navSource: .idle,
        lastAdmittedSequence: 0x1234_5678
    )
    let activeEchoBytes = activeEcho.encode()
    #expect(activeEchoBytes.count == 12)
    #expect(hex(activeEchoBytes) == "010102030001000078563412")
    #expect(try EchoSummary.decode(activeEchoBytes) == activeEcho)
}

@Test
func drawContextPacketEncodes72ByteHeaderAndSortedAuxSections() throws {
    let packet = DrawContextPacket(
        stateBytes: [0x08, 0x00],
        configBytes: [0xaa],
        alertsBytes: [0xbb, 0xcc],
        echoSummary: EchoSummary(baro: .confirmed, lastAdmittedSequence: 3),
        viewPose: ViewPose3D(zoomScale: 1.5, decluttered: true),
        underlay: UnderlayStatus(available: true, calibrated: true, qualityPercent: 95),
        auxEntries: [
            AuxPacketEntry(id: .worldSurveillance, payload: [0x10, 0x20]),
            AuxPacketEntry(id: .terrainPatch3D, payload: [0x01, 0x02, 0x03]),
        ]
    )

    let encoded = try packet.encode()
    // 72 header + 2 state + 1 config + 2 alerts + (8 + 3) + (8 + 2) = 98 bytes.
    #expect(encoded.count == 98)
    #expect(
        hex(encoded)
            == "01035f010200010002000200"
            + "010200000001000003000000"
            + "010100000000000000000000000000000000000000000000000000000000803f0000c03f000000000000000000000000"
            + "0800"
            + "aa"
            + "bbcc"
            + "1000000003000000010203"
            + "22000000020000001020"
    )

    let decoded = try DrawContextPacket.decode(encoded)
    #expect(decoded.stateBytes == [0x08, 0x00])
    #expect(decoded.configBytes == [0xaa])
    #expect(decoded.alertsBytes == [0xbb, 0xcc])
    #expect(decoded.underlay == packet.underlay)
    #expect(decoded.echoSummary == packet.echoSummary)
    #expect(decoded.viewPose == packet.viewPose)
    // Aux entries are sorted in ascending AuxChannelId order (0x0010 before 0x0022).
    #expect(decoded.auxEntries.map(\.id) == [.terrainPatch3D, .worldSurveillance])
    #expect(decoded.aux(.terrainPatch3D) == [0x01, 0x02, 0x03])
    #expect(decoded.aux(.worldSurveillance) == [0x10, 0x20])
}
