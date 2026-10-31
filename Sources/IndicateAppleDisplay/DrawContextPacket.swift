import Foundation

/// Wire format version for encoded ``DrawContextPacket`` buffers.
public let drawContextWireVersion: UInt8 = 1

/// Fixed byte length of the ``DrawContextPacket`` header before variable sections.
public let drawContextHeaderBytes = 72

/// Maximum auxiliary channel entries allowed in one ``DrawContextPacket``.
public let maxDrawContextAuxEntries = 16

/// Availability, calibration, and quality report for a host-supplied underlay.
public struct UnderlayStatus: Equatable, Sendable {
    /// Indicates whether the underlay surface or feed is available.
    public var available: Bool
    /// Indicates whether spatial or optical calibration is valid.
    public var calibrated: Bool
    /// Quality percentage in `0...100`.
    public var qualityPercent: UInt8

    public init(available: Bool, calibrated: Bool, qualityPercent: UInt8) {
        self.available = available
        self.calibrated = calibrated
        self.qualityPercent = qualityPercent
    }

    /// Fail-closed default when no underlay is active.
    public static let unavailable = UnderlayStatus(
        available: false,
        calibrated: false,
        qualityPercent: 0
    )
}

/// Identifier of an auxiliary read-only data channel inside ``DrawContextPacket``.
public struct AuxChannelId: RawRepresentable, Equatable, Hashable, Comparable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let hwdDisplay = AuxChannelId(rawValue: 0x0001)
    public static let hudContext = AuxChannelId(rawValue: 0x0002)
    public static let terrainPatch3D = AuxChannelId(rawValue: 0x0010)
    public static let globeNavigation3D = AuxChannelId(rawValue: 0x0011)
    public static let celestialEphemeris3D = AuxChannelId(rawValue: 0x0012)
    public static let flightbagNav = AuxChannelId(rawValue: 0x0020)
    public static let worldAirmass = AuxChannelId(rawValue: 0x0021)
    public static let worldSurveillance = AuxChannelId(rawValue: 0x0022)
    public static let worldNotices = AuxChannelId(rawValue: 0x0023)

    /// Derives a deterministic custom auxiliary channel identifier in `0x8000_0000...0xFFFF_FFFF`.
    public static func custom(_ domain: String) -> AuxChannelId {
        var hash: UInt32 = 0x811c_9dc5
        let prime: UInt32 = 0x0100_0193
        for byte in domain.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* prime
        }
        return AuxChannelId(rawValue: hash | 0x8000_0000)
    }

    public static func < (lhs: AuxChannelId, rhs: AuxChannelId) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One auxiliary read-only byte slice carried in ``DrawContextPacket``.
public struct AuxPacketEntry: Equatable, Sendable {
    public var id: AuxChannelId
    public var payload: [UInt8]

    public init(id: AuxChannelId, payload: [UInt8]) {
        self.id = id
        self.payload = payload
    }
}

/// Errors raised when encoding or decoding a ``DrawContextPacket``.
public enum DrawContextCodecError: Error, Equatable, Sendable {
    case badVersion(UInt8)
    case truncated
    case trailingBytes(Int)
    case invalidUnderlayFlags(UInt8)
    case invalidUnderlayQuality(UInt8)
    case invalidAlertPresence(UInt8)
    case sectionTooLarge(section: String, bytes: Int)
    case tooManyAuxEntries(Int)
    case duplicateOrUnsortedAuxId(UInt32)
    case echo(IntentCodecError)
    case viewPose(SpatialInteractionError)
}

/// Versioned byte-buffer packet carrying all inputs to a Rust FFI or WASM `.indpack` draw call.
///
/// Header (`72` bytes):
/// - `[0]`: `version = 1`
/// - `[1]`: `underlayFlags` (`bit 0 = available`, `bit 1 = calibrated`)
/// - `[2]`: `underlayQualityPct` (`0...100`)
/// - `[3]`: `hasAlerts` (`0` or `1`)
/// - `[4..6]`: `stateLen` (`UInt16 LE`)
/// - `[6..8]`: `configLen` (`UInt16 LE`)
/// - `[8..10]`: `alertsLen` (`UInt16 LE`)
/// - `[10..12]`: `auxCount` (`UInt16 LE`, `<= 16`)
/// - `[12..24]`: `echoSummary` (`12` bytes)
/// - `[24..72]`: `viewPose` (`48` bytes)
///
/// Variable sections follow immediately: `state`, `config`, `alerts`, and `auxCount`
/// entries of `[auxId: UInt32 LE][payloadLen: UInt32 LE][payload]` sorted by ascending `auxId`.
public struct DrawContextPacket: Equatable, Sendable {
    public var stateBytes: [UInt8]
    public var configBytes: [UInt8]
    public var alertsBytes: [UInt8]?
    public var echoSummary: EchoSummary
    public var viewPose: ViewPose3D
    public var underlay: UnderlayStatus
    public var auxEntries: [AuxPacketEntry]

    public init(
        stateBytes: [UInt8],
        configBytes: [UInt8] = [],
        alertsBytes: [UInt8]? = nil,
        echoSummary: EchoSummary = .idle,
        viewPose: ViewPose3D = ViewPose3D(),
        underlay: UnderlayStatus = .unavailable,
        auxEntries: [AuxPacketEntry] = []
    ) {
        self.stateBytes = stateBytes
        self.configBytes = configBytes
        self.alertsBytes = alertsBytes
        self.echoSummary = echoSummary
        self.viewPose = viewPose
        self.underlay = underlay
        self.auxEntries = auxEntries
    }

    /// Returns a copy with `configBytes` replaced.
    public func withConfig(_ bytes: [UInt8]) -> DrawContextPacket {
        var copy = self
        copy.configBytes = bytes
        return copy
    }

    /// Returns a copy with `alertsBytes` replaced.
    public func withAlerts(_ bytes: [UInt8]?) -> DrawContextPacket {
        var copy = self
        copy.alertsBytes = bytes
        return copy
    }

    /// Returns a copy with `echoSummary` replaced.
    public func withEcho(_ summary: EchoSummary) -> DrawContextPacket {
        var copy = self
        copy.echoSummary = summary
        return copy
    }

    /// Returns a copy with `viewPose` replaced.
    public func withViewPose(_ pose: ViewPose3D) -> DrawContextPacket {
        var copy = self
        copy.viewPose = pose
        return copy
    }

    /// Returns a copy with `underlay` replaced.
    public func withUnderlay(_ status: UnderlayStatus) -> DrawContextPacket {
        var copy = self
        copy.underlay = status
        return copy
    }

    /// Returns a copy with one auxiliary entry appended.
    public func addingAux(id: AuxChannelId, payload: [UInt8]) -> DrawContextPacket {
        var copy = self
        copy.auxEntries.append(AuxPacketEntry(id: id, payload: payload))
        return copy
    }

    /// Looks up the payload for auxiliary channel `id`, or returns `nil` when absent.
    public func aux(_ id: AuxChannelId) -> [UInt8]? {
        auxEntries.first(where: { $0.id == id })?.payload
    }

    /// Encodes this draw context into a canonical `DRAW_CONTEXT_WIRE_VERSION = 1` byte buffer.
    public func encode() throws(DrawContextCodecError) -> [UInt8] {
        guard underlay.qualityPercent <= 100 else {
            throw DrawContextCodecError.invalidUnderlayQuality(underlay.qualityPercent)
        }
        guard stateBytes.count <= Int(UInt16.max) else {
            throw DrawContextCodecError.sectionTooLarge(section: "state", bytes: stateBytes.count)
        }
        guard configBytes.count <= Int(UInt16.max) else {
            throw DrawContextCodecError.sectionTooLarge(section: "config", bytes: configBytes.count)
        }
        let alertSlice = alertsBytes ?? []
        guard alertSlice.count <= Int(UInt16.max) else {
            throw DrawContextCodecError.sectionTooLarge(section: "alerts", bytes: alertSlice.count)
        }
        guard auxEntries.count <= maxDrawContextAuxEntries else {
            throw DrawContextCodecError.tooManyAuxEntries(auxEntries.count)
        }
        let sortedAux = auxEntries.sorted { $0.id < $1.id }
        for index in 1..<sortedAux.count where sortedAux[index].id <= sortedAux[index - 1].id {
            throw DrawContextCodecError.duplicateOrUnsortedAuxId(sortedAux[index].id.rawValue)
        }
        let encodedPose: [UInt8]
        do {
            encodedPose = try viewPose.encode()
        } catch {
            throw DrawContextCodecError.viewPose(error)
        }
        let encodedEcho = echoSummary.encode()
        var flags: UInt8 = 0
        if underlay.available { flags |= 0x01 }
        if underlay.calibrated { flags |= 0x02 }

        let auxTotalBytes = sortedAux.reduce(0) { $0 + 8 + $1.payload.count }
        var out: [UInt8] = []
        out.reserveCapacity(
            drawContextHeaderBytes + stateBytes.count + configBytes.count
                + alertSlice.count + auxTotalBytes
        )
        out.append(drawContextWireVersion)
        out.append(flags)
        out.append(underlay.qualityPercent)
        out.append(alertsBytes == nil ? 0 : 1)
        out.appendUInt16LE(UInt16(stateBytes.count))
        out.appendUInt16LE(UInt16(configBytes.count))
        out.appendUInt16LE(UInt16(alertSlice.count))
        out.appendUInt16LE(UInt16(sortedAux.count))
        out.append(contentsOf: encodedEcho)
        out.append(contentsOf: encodedPose)
        out.append(contentsOf: stateBytes)
        out.append(contentsOf: configBytes)
        out.append(contentsOf: alertSlice)
        for entry in sortedAux {
            guard entry.payload.count <= Int(UInt32.max) else {
                throw DrawContextCodecError.sectionTooLarge(
                    section: "aux",
                    bytes: entry.payload.count
                )
            }
            out.appendUInt32LE(entry.id.rawValue)
            out.appendUInt32LE(UInt32(entry.payload.count))
            out.append(contentsOf: entry.payload)
        }
        return out
    }

    /// Decodes a ``DrawContextPacket`` from its little-endian wire buffer.
    public static func decode(_ bytes: [UInt8]) throws(DrawContextCodecError) -> DrawContextPacket {
        guard let version = bytes.first else {
            throw DrawContextCodecError.truncated
        }
        guard version == drawContextWireVersion else {
            throw DrawContextCodecError.badVersion(version)
        }
        guard bytes.count >= drawContextHeaderBytes else {
            throw DrawContextCodecError.truncated
        }
        let flags = bytes[1]
        guard (flags & ~0x03) == 0 else {
            throw DrawContextCodecError.invalidUnderlayFlags(flags)
        }
        let quality = bytes[2]
        guard quality <= 100 else {
            throw DrawContextCodecError.invalidUnderlayQuality(quality)
        }
        let hasAlerts = bytes[3]
        guard hasAlerts <= 1 else {
            throw DrawContextCodecError.invalidAlertPresence(hasAlerts)
        }
        let stateLen = Int(bytes.unsigned16(at: 4))
        let configLen = Int(bytes.unsigned16(at: 6))
        let alertsLen = Int(bytes.unsigned16(at: 8))
        if hasAlerts == 0, alertsLen != 0 {
            throw DrawContextCodecError.invalidAlertPresence(hasAlerts)
        }
        let auxCount = Int(bytes.unsigned16(at: 10))
        guard auxCount <= maxDrawContextAuxEntries else {
            throw DrawContextCodecError.tooManyAuxEntries(auxCount)
        }
        let echo: EchoSummary
        do {
            echo = try EchoSummary.decode(Array(bytes[12..<24]))
        } catch {
            throw DrawContextCodecError.echo(error)
        }
        let pose: ViewPose3D
        do {
            pose = try ViewPose3D.decode(Array(bytes[24..<72]))
        } catch {
            throw DrawContextCodecError.viewPose(error)
        }
        var cursor = drawContextHeaderBytes
        guard cursor + stateLen + configLen + alertsLen <= bytes.count else {
            throw DrawContextCodecError.truncated
        }
        let state = Array(bytes[cursor..<(cursor + stateLen)])
        cursor += stateLen
        let config = Array(bytes[cursor..<(cursor + configLen)])
        cursor += configLen
        let alerts: [UInt8]? = if hasAlerts == 1 {
            Array(bytes[cursor..<(cursor + alertsLen)])
        } else {
            nil
        }
        cursor += alertsLen

        var auxEntries: [AuxPacketEntry] = []
        auxEntries.reserveCapacity(auxCount)
        var previousAuxId: UInt32?
        for _ in 0..<auxCount {
            guard cursor + 8 <= bytes.count else {
                throw DrawContextCodecError.truncated
            }
            let rawId = bytes.unsigned32(at: cursor)
            if let prev = previousAuxId, rawId <= prev {
                throw DrawContextCodecError.duplicateOrUnsortedAuxId(rawId)
            }
            previousAuxId = rawId
            let payloadLen = Int(bytes.unsigned32(at: cursor + 4))
            cursor += 8
            guard cursor + payloadLen <= bytes.count else {
                throw DrawContextCodecError.truncated
            }
            let payload = Array(bytes[cursor..<(cursor + payloadLen)])
            cursor += payloadLen
            auxEntries.append(AuxPacketEntry(id: AuxChannelId(rawValue: rawId), payload: payload))
        }
        guard cursor == bytes.count else {
            throw DrawContextCodecError.trailingBytes(bytes.count - cursor)
        }
        return DrawContextPacket(
            stateBytes: state,
            configBytes: config,
            alertsBytes: alerts,
            echoSummary: echo,
            viewPose: pose,
            underlay: UnderlayStatus(
                available: (flags & 0x01) != 0,
                calibrated: (flags & 0x02) != 0,
                qualityPercent: quality
            ),
            auxEntries: auxEntries
        )
    }
}
