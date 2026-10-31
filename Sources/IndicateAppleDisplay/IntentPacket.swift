import Foundation

/// Wire format version for encoded ``IntentRequest`` packets.
public let intentWireVersion: UInt8 = 1

/// Maximum byte length of an encoded ``IntentRequest`` packet (`30` header + `64` payload + `2` margin).
public let maxIntentWireBytes = 96

/// Maximum payload length for a custom-namespace ``IntentPayload``.
public let maxExtensionPayloadBytes = 64

/// Wire format version for encoded ``EchoSummary`` packets.
public let echoSummaryVersion: UInt8 = 1

/// Fixed byte length of an encoded ``EchoSummary`` packet.
public let echoSummaryBytes = 12

/// 64-bit intent namespace identifier (`0` reserved for ``core``).
public struct IntentNamespace: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Reserved core avionics namespace (`0`).
    public static let core = IntentNamespace(rawValue: 0)

    /// Computes the deterministic 64-bit FNV-1a hash of `name` UTF-8 bytes, mapping `0` to `1`.
    public static func domain(_ name: String) -> IntentNamespace {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        if hash == 0 {
            hash = 1
        }
        return IntentNamespace(rawValue: hash)
    }
}

/// Core intent opcodes under ``IntentNamespace/core``.
public enum IntentCoreOpcode {
    public static let selectBaro: UInt16 = 0x0001
    public static let setHeadingBug: UInt16 = 0x0002
    public static let selectAltitude: UInt16 = 0x0003
    public static let selectNavSource: UInt16 = 0x0004
    public static let acknowledgeAlert: UInt16 = 0x0005
    public static let acknowledgeAllAlerts: UInt16 = 0x0006
    public static let selectPage: UInt16 = 0x0007
    public static let declutter: UInt16 = 0x0008
    public static let pressSoftkey: UInt16 = 0x0009
}

/// Device stamp attached to each audited ``IntentRequest``.
public struct IntentStamp: Equatable, Sendable {
    /// Input device identifier.
    public var deviceId: UInt32
    /// Wrapping per-device sequence number.
    public var sequence: UInt32
    /// Device timestamp in milliseconds when the request was issued.
    public var issuedAtMs: UInt64

    public init(deviceId: UInt32, sequence: UInt32, issuedAtMs: UInt64) {
        self.deviceId = deviceId
        self.sequence = sequence
        self.issuedAtMs = issuedAtMs
    }
}

/// Heading reference carried by ``IntentPayload/setHeadingBug(radians:reference:)``.
public enum IntentHeadingReference: UInt8, CaseIterable, Equatable, Sendable {
    case magnetic = 0
    case trueNorth = 1
    case simLocalTrue = 2
}

/// Altitude datum class carried by ``IntentPayload/selectAltitude(meters:datumClass:origin:geoidModel:)``.
public enum IntentAltitudeClass: UInt8, CaseIterable, Equatable, Sendable {
    case localRelative = 0
    case baroIndicated = 1
    case pressure = 2
    case geometricMsl = 3
    case agl = 4
}

/// Lateral navigation source carried by ``IntentPayload/selectNavSource(_:)``.
public enum IntentNavSource: UInt8, CaseIterable, Equatable, Sendable {
    case nav1 = 0
    case nav2 = 1
    case gps = 2
    case none = 3
}

/// Typed core avionics request or extension-namespace TLV payload.
public enum IntentPayload: Equatable, Sendable {
    /// Sets the barometric reference in hectopascals (`opcode = 0x0001`).
    case selectBaro(hpa: Float)
    /// Sets the heading bug in radians clockwise from `reference` (`opcode = 0x0002`).
    case setHeadingBug(radians: Float, reference: IntentHeadingReference)
    /// Selects a target altitude in meters against an explicit datum (`opcode = 0x0003`).
    case selectAltitude(
        meters: Float,
        datumClass: IntentAltitudeClass,
        origin: UInt8,
        geoidModel: UInt8
    )
    /// Selects the active lateral navigation source (`opcode = 0x0004`).
    case selectNavSource(IntentNavSource)
    /// Acknowledges a single alert identifier (`opcode = 0x0005`).
    case acknowledgeAlert(alertId: UInt16)
    /// Acknowledges all active alerts (`opcode = 0x0006`).
    case acknowledgeAllAlerts
    /// Selects a display page (`opcode = 0x0007`).
    case selectPage(pageId: UInt8)
    /// Toggles display declutter (`opcode = 0x0008`).
    case declutter(enabled: Bool)
    /// Presses a bezel or virtual softkey (`opcode = 0x0009`).
    case pressSoftkey(keyId: UInt16)
    /// Sends a domain-namespaced extension intent (`namespace != .core`, `<= 64` bytes).
    case custom(namespace: IntentNamespace, opcode: UInt16, bytes: [UInt8])
}

/// Errors raised when encoding or decoding ``IntentRequest`` and ``EchoSummary`` wire buffers.
public enum IntentCodecError: Error, Equatable, Sendable {
    case badVersion(UInt8)
    case truncated
    case trailingBytes(Int)
    case reservedBytesNonZero
    case payloadTooLarge(bytes: Int)
    case customUsesCoreNamespace
    case unknownCoreOpcode(UInt16)
    case badPayload(opcode: UInt16)
    case invalidEchoStatus(UInt8)
}

/// Audited operator request packet (`INTENT_WIRE_VERSION = 1`, `30 + payloadLen` bytes).
public struct IntentRequest: Equatable, Sendable {
    /// Device origin and sequence stamp.
    public var stamp: IntentStamp
    /// Requested action payload.
    public var payload: IntentPayload

    public init(stamp: IntentStamp, payload: IntentPayload) {
        self.stamp = stamp
        self.payload = payload
    }

    /// Encodes this request into its `30 + N` byte little-endian wire representation.
    public func encode() throws(IntentCodecError) -> [UInt8] {
        let (namespace, opcode, body) = try encodePayload(payload)
        guard body.count <= maxExtensionPayloadBytes else {
            throw IntentCodecError.payloadTooLarge(bytes: body.count)
        }
        var out: [UInt8] = []
        out.reserveCapacity(30 + body.count)
        out.append(intentWireVersion)
        out.append(0)
        out.appendUInt32LE(stamp.deviceId)
        out.appendUInt32LE(stamp.sequence)
        out.appendUInt64LE(stamp.issuedAtMs)
        out.appendUInt64LE(namespace.rawValue)
        out.appendUInt16LE(opcode)
        out.appendUInt16LE(UInt16(body.count))
        out.append(contentsOf: body)
        return out
    }

    /// Decodes an ``IntentRequest`` from its little-endian wire buffer.
    public static func decode(_ bytes: [UInt8]) throws(IntentCodecError) -> IntentRequest {
        guard let version = bytes.first else {
            throw IntentCodecError.truncated
        }
        guard version == intentWireVersion else {
            throw IntentCodecError.badVersion(version)
        }
        guard bytes.count >= 30 else {
            throw IntentCodecError.truncated
        }
        guard bytes[1] == 0 else {
            throw IntentCodecError.reservedBytesNonZero
        }
        let stamp = IntentStamp(
            deviceId: bytes.unsigned32(at: 2),
            sequence: bytes.unsigned32(at: 6),
            issuedAtMs: bytes.unsigned64(at: 10)
        )
        let namespace = IntentNamespace(rawValue: bytes.unsigned64(at: 18))
        let opcode = bytes.unsigned16(at: 26)
        let payloadLen = Int(bytes.unsigned16(at: 28))
        guard payloadLen <= maxExtensionPayloadBytes else {
            throw IntentCodecError.payloadTooLarge(bytes: payloadLen)
        }
        let expectedTotal = 30 + payloadLen
        guard bytes.count >= expectedTotal else {
            throw IntentCodecError.truncated
        }
        guard bytes.count == expectedTotal else {
            throw IntentCodecError.trailingBytes(bytes.count - expectedTotal)
        }
        let payload = try decodePayload(
            namespace: namespace,
            opcode: opcode,
            bytes: bytes,
            at: 30,
            length: payloadLen
        )
        return IntentRequest(stamp: stamp, payload: payload)
    }

    private func encodePayload(
        _ payload: IntentPayload
    ) throws(IntentCodecError) -> (namespace: IntentNamespace, opcode: UInt16, body: [UInt8]) {
        var body: [UInt8] = []
        switch payload {
        case let .selectBaro(hpa):
            guard hpa.isFinite else {
                throw IntentCodecError.badPayload(opcode: IntentCoreOpcode.selectBaro)
            }
            body.appendFloat32LE(hpa)
            return (.core, IntentCoreOpcode.selectBaro, body)
        case let .setHeadingBug(radians, reference):
            guard radians.isFinite else {
                throw IntentCodecError.badPayload(opcode: IntentCoreOpcode.setHeadingBug)
            }
            body.appendFloat32LE(radians)
            body.append(reference.rawValue)
            return (.core, IntentCoreOpcode.setHeadingBug, body)
        case let .selectAltitude(meters, datumClass, origin, geoidModel):
            guard meters.isFinite else {
                throw IntentCodecError.badPayload(opcode: IntentCoreOpcode.selectAltitude)
            }
            body.appendFloat32LE(meters)
            body.append(datumClass.rawValue)
            body.append(origin)
            body.append(geoidModel)
            return (.core, IntentCoreOpcode.selectAltitude, body)
        case let .selectNavSource(source):
            body.append(source.rawValue)
            return (.core, IntentCoreOpcode.selectNavSource, body)
        case let .acknowledgeAlert(alertId):
            body.appendUInt16LE(alertId)
            return (.core, IntentCoreOpcode.acknowledgeAlert, body)
        case .acknowledgeAllAlerts:
            return (.core, IntentCoreOpcode.acknowledgeAllAlerts, [])
        case let .selectPage(pageId):
            body.append(pageId)
            return (.core, IntentCoreOpcode.selectPage, body)
        case let .declutter(enabled):
            body.append(enabled ? 1 : 0)
            return (.core, IntentCoreOpcode.declutter, body)
        case let .pressSoftkey(keyId):
            body.appendUInt16LE(keyId)
            return (.core, IntentCoreOpcode.pressSoftkey, body)
        case let .custom(namespace, opcode, bytes):
            guard namespace != .core else {
                throw IntentCodecError.customUsesCoreNamespace
            }
            guard bytes.count <= maxExtensionPayloadBytes else {
                throw IntentCodecError.payloadTooLarge(bytes: bytes.count)
            }
            return (namespace, opcode, bytes)
        }
    }

    private static func decodePayload(
        namespace: IntentNamespace,
        opcode: UInt16,
        bytes: [UInt8],
        at start: Int,
        length: Int
    ) throws(IntentCodecError) -> IntentPayload {
        if namespace != .core {
            return .custom(
                namespace: namespace,
                opcode: opcode,
                bytes: Array(bytes[start..<(start + length)])
            )
        }
        switch opcode {
        case IntentCoreOpcode.selectBaro:
            guard length == 4 else { throw IntentCodecError.badPayload(opcode: opcode) }
            let hpa = bytes.float32(at: start)
            guard hpa.isFinite else { throw IntentCodecError.badPayload(opcode: opcode) }
            return .selectBaro(hpa: hpa)
        case IntentCoreOpcode.setHeadingBug:
            guard length == 5,
                  let ref = IntentHeadingReference(rawValue: bytes[start + 4]) else {
                throw IntentCodecError.badPayload(opcode: opcode)
            }
            let radians = bytes.float32(at: start)
            guard radians.isFinite else { throw IntentCodecError.badPayload(opcode: opcode) }
            return .setHeadingBug(radians: radians, reference: ref)
        case IntentCoreOpcode.selectAltitude:
            guard length == 7,
                  let datumClass = IntentAltitudeClass(rawValue: bytes[start + 4]) else {
                throw IntentCodecError.badPayload(opcode: opcode)
            }
            let meters = bytes.float32(at: start)
            guard meters.isFinite else { throw IntentCodecError.badPayload(opcode: opcode) }
            return .selectAltitude(
                meters: meters,
                datumClass: datumClass,
                origin: bytes[start + 5],
                geoidModel: bytes[start + 6]
            )
        case IntentCoreOpcode.selectNavSource:
            guard length == 1,
                  let source = IntentNavSource(rawValue: bytes[start]) else {
                throw IntentCodecError.badPayload(opcode: opcode)
            }
            return .selectNavSource(source)
        case IntentCoreOpcode.acknowledgeAlert:
            guard length == 2 else { throw IntentCodecError.badPayload(opcode: opcode) }
            return .acknowledgeAlert(alertId: bytes.unsigned16(at: start))
        case IntentCoreOpcode.acknowledgeAllAlerts:
            guard length == 0 else { throw IntentCodecError.badPayload(opcode: opcode) }
            return .acknowledgeAllAlerts
        case IntentCoreOpcode.selectPage:
            guard length == 1 else { throw IntentCodecError.badPayload(opcode: opcode) }
            return .selectPage(pageId: bytes[start])
        case IntentCoreOpcode.declutter:
            guard length == 1, bytes[start] <= 1 else {
                throw IntentCodecError.badPayload(opcode: opcode)
            }
            return .declutter(enabled: bytes[start] == 1)
        case IntentCoreOpcode.pressSoftkey:
            guard length == 2 else { throw IntentCodecError.badPayload(opcode: opcode) }
            return .pressSoftkey(keyId: bytes.unsigned16(at: start))
        default:
            throw IntentCodecError.unknownCoreOpcode(opcode)
        }
    }
}

/// Wire status of one monitored selection slot in ``EchoSummary``.
public enum EchoWireStatus: UInt8, CaseIterable, Equatable, Sendable {
    case idle = 0
    case pending = 1
    case confirmed = 2
    case overdue = 3
    case unmeasurable = 4
}

/// Compact 12-byte echo-back status summary (`ECHO_SUMMARY_VERSION = 1`).
///
/// Wire layout (`12` bytes):
/// `[version=1: u8][baro: u8][headingBug: u8][altitude: u8][navSource: u8][hasLastSeq: u8 (0|1)][0, 0][lastAdmittedSeq: u32 LE]`.
public struct EchoSummary: Equatable, Sendable {
    public var baro: EchoWireStatus
    public var headingBug: EchoWireStatus
    public var altitude: EchoWireStatus
    public var navSource: EchoWireStatus
    public var lastAdmittedSequence: UInt32?

    public init(
        baro: EchoWireStatus = .idle,
        headingBug: EchoWireStatus = .idle,
        altitude: EchoWireStatus = .idle,
        navSource: EchoWireStatus = .idle,
        lastAdmittedSequence: UInt32? = nil
    ) {
        self.baro = baro
        self.headingBug = headingBug
        self.altitude = altitude
        self.navSource = navSource
        self.lastAdmittedSequence = lastAdmittedSequence
    }

    /// Idle echo summary with no admitted sequence recorded.
    public static let idle = EchoSummary()

    /// Encodes this summary into its fixed 12-byte little-endian wire layout.
    public func encode() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(echoSummaryBytes)
        out.append(echoSummaryVersion)
        out.append(baro.rawValue)
        out.append(headingBug.rawValue)
        out.append(altitude.rawValue)
        out.append(navSource.rawValue)
        if let sequence = lastAdmittedSequence {
            out.append(1)
            out.append(0)
            out.append(0)
            out.appendUInt32LE(sequence)
        } else {
            out.append(0)
            out.append(0)
            out.append(0)
            out.appendUInt32LE(0)
        }
        return out
    }

    /// Decodes an ``EchoSummary`` from a 12-byte wire buffer.
    public static func decode(_ bytes: [UInt8]) throws(IntentCodecError) -> EchoSummary {
        guard let version = bytes.first else {
            throw IntentCodecError.truncated
        }
        guard version == echoSummaryVersion else {
            throw IntentCodecError.badVersion(version)
        }
        guard bytes.count >= echoSummaryBytes else {
            throw IntentCodecError.truncated
        }
        guard bytes.count == echoSummaryBytes else {
            throw IntentCodecError.trailingBytes(bytes.count - echoSummaryBytes)
        }
        guard let baro = EchoWireStatus(rawValue: bytes[1]) else {
            throw IntentCodecError.invalidEchoStatus(bytes[1])
        }
        guard let headingBug = EchoWireStatus(rawValue: bytes[2]) else {
            throw IntentCodecError.invalidEchoStatus(bytes[2])
        }
        guard let altitude = EchoWireStatus(rawValue: bytes[3]) else {
            throw IntentCodecError.invalidEchoStatus(bytes[3])
        }
        guard let navSource = EchoWireStatus(rawValue: bytes[4]) else {
            throw IntentCodecError.invalidEchoStatus(bytes[4])
        }
        let hasSeq = bytes[5]
        guard hasSeq <= 1, bytes[6] == 0, bytes[7] == 0 else {
            throw IntentCodecError.reservedBytesNonZero
        }
        let rawSeq = bytes.unsigned32(at: 8)
        if hasSeq == 0, rawSeq != 0 {
            throw IntentCodecError.reservedBytesNonZero
        }
        return EchoSummary(
            baro: baro,
            headingBug: headingBug,
            altitude: altitude,
            navSource: navSource,
            lastAdmittedSequence: hasSeq == 1 ? rawSeq : nil
        )
    }
}
