import Foundation

/// Why a scene could not be decoded.
public enum SceneDecodeError: Error, Equatable, Sendable {
    /// The leading version byte is not one this revision reads.
    case badVersion(UInt8)
    /// A command header or payload runs past the end of the buffer.
    case truncated
    /// A payload is the wrong size for its opcode, or carries a value this
    /// revision cannot place — including an unknown layer id.
    case badPayload(opcode: UInt8)

    /// Stable identifier matching the conformance corpus vocabulary.
    public var conformanceName: String {
        switch self {
        case .badVersion: "BadVersion"
        case .truncated: "Truncated"
        case .badPayload: "BadPayload"
        }
    }
}

private enum Opcode {
    static let save: UInt8 = 0x01
    static let restore: UInt8 = 0x02
    static let translate: UInt8 = 0x03
    static let rotate: UInt8 = 0x04
    static let fillColor: UInt8 = 0x10
    static let stroke: UInt8 = 0x11
    static let line: UInt8 = 0x20
    static let polyline: UInt8 = 0x21
    static let polygon: UInt8 = 0x22
    static let rect: UInt8 = 0x23
    static let circle: UInt8 = 0x24
    static let arc: UInt8 = 0x25
    static let text: UInt8 = 0x30
    static let clipRect: UInt8 = 0x40
    static let beginLayer: UInt8 = 0x50
    static let endLayer: UInt8 = 0x51
}

/// Decodes an encoded scene into commands.
///
/// Wire layout is one version byte, then per command
/// `[opcode u8][payload length u16 LE][payload]`. The explicit length is what
/// lets this decoder skip opcodes it does not recognize instead of failing,
/// so an older backend degrades gracefully against a newer producer.
public struct SceneDecoder {
    private let bytes: [UInt8]
    private var cursor: Int

    /// Starts decoding, validating the version byte.
    public init(_ bytes: [UInt8]) throws(SceneDecodeError) {
        guard let version = bytes.first else { throw SceneDecodeError.truncated }
        guard version == sceneFormatVersion else {
            throw SceneDecodeError.badVersion(version)
        }
        self.bytes = bytes
        cursor = 1
    }

    /// Returns the next command, or `nil` at the end of the scene.
    public mutating func next() throws(SceneDecodeError) -> SceneCommand? {
        if cursor == bytes.count { return nil }
        guard cursor + 3 <= bytes.count else { throw SceneDecodeError.truncated }
        let opcode = bytes[cursor]
        let length = Int(bytes.unsigned16(at: cursor + 1))
        let payload = cursor + 3
        guard payload + length <= bytes.count else { throw SceneDecodeError.truncated }
        cursor = payload + length
        return try decode(opcode: opcode, at: payload, length: length)
    }

    /// Decodes the whole scene into an array.
    public static func commands(_ bytes: [UInt8]) throws(SceneDecodeError) -> [SceneCommand] {
        var decoder = try SceneDecoder(bytes)
        var commands: [SceneCommand] = []
        while let command = try decoder.next() {
            commands.append(command)
        }
        return commands
    }

    private func decode(
        opcode: UInt8,
        at payload: Int,
        length: Int
    ) throws(SceneDecodeError) -> SceneCommand {
        switch opcode {
        case Opcode.save:
            try require(length == 0, opcode)
            return .save
        case Opcode.restore:
            try require(length == 0, opcode)
            return .restore
        case Opcode.translate:
            try require(length == 8, opcode)
            return .translate(x: float(payload), y: float(payload + 4))
        case Opcode.rotate:
            try require(length == 4, opcode)
            return .rotate(radians: float(payload))
        case Opcode.fillColor:
            try require(length == 4, opcode)
            return .fillColor(Rgba8(packed: bytes.unsigned32(at: payload)))
        case Opcode.stroke:
            try require(length == 8, opcode)
            return .stroke(
                color: Rgba8(packed: bytes.unsigned32(at: payload)),
                width: float(payload + 4)
            )
        case Opcode.line:
            try require(length == 16, opcode)
            return .line(
                x1: float(payload), y1: float(payload + 4),
                x2: float(payload + 8), y2: float(payload + 12)
            )
        case Opcode.polyline:
            try require(length % 8 == 0, opcode)
            return .polyline(points: points(at: payload, count: length / 8))
        case Opcode.polygon:
            try require(length >= 1 && (length - 1) % 8 == 0, opcode)
            guard let mode = PaintMode(wire: bytes[payload]) else {
                throw SceneDecodeError.badPayload(opcode: opcode)
            }
            return .polygon(mode: mode, points: points(at: payload + 1, count: (length - 1) / 8))
        case Opcode.rect:
            try require(length == 17, opcode)
            guard let mode = PaintMode(wire: bytes[payload]) else {
                throw SceneDecodeError.badPayload(opcode: opcode)
            }
            return .rect(
                mode: mode,
                x: float(payload + 1), y: float(payload + 5),
                width: float(payload + 9), height: float(payload + 13)
            )
        case Opcode.circle:
            try require(length == 13, opcode)
            guard let mode = PaintMode(wire: bytes[payload]) else {
                throw SceneDecodeError.badPayload(opcode: opcode)
            }
            return .circle(
                mode: mode,
                centerX: float(payload + 1), centerY: float(payload + 5),
                radius: float(payload + 9)
            )
        case Opcode.arc:
            try require(length == 20, opcode)
            return .arc(
                centerX: float(payload), centerY: float(payload + 4),
                radius: float(payload + 8),
                start: float(payload + 12), sweep: float(payload + 16)
            )
        case Opcode.text:
            try require(length >= 13, opcode)
            guard let anchor = Anchor(wire: bytes[payload + 4]) else {
                throw SceneDecodeError.badPayload(opcode: opcode)
            }
            let textBytes = Array(bytes[(payload + 13)..<(payload + length)])
            try require(textBytes.count <= SceneBudget.maxTextBytes, opcode)
            return .text(
                x: float(payload + 5), y: float(payload + 9),
                size: float(payload), anchor: anchor, bytes: textBytes
            )
        case Opcode.clipRect:
            try require(length == 16, opcode)
            return .clipRect(
                x: float(payload), y: float(payload + 4),
                width: float(payload + 8), height: float(payload + 12)
            )
        case Opcode.beginLayer, Opcode.endLayer:
            try require(length == 1, opcode)
            // An unknown layer id fails the frame rather than being skipped:
            // content whose criticality cannot be placed must not be painted.
            guard let layer = SceneLayer(rawValue: bytes[payload]) else {
                throw SceneDecodeError.badPayload(opcode: opcode)
            }
            return opcode == Opcode.beginLayer ? .beginLayer(layer) : .endLayer(layer)
        default:
            return .unknown(opcode: opcode)
        }
    }

    private func require(_ condition: Bool, _ opcode: UInt8) throws(SceneDecodeError) {
        guard condition else { throw SceneDecodeError.badPayload(opcode: opcode) }
    }

    private func float(_ index: Int) -> Float {
        bytes.float32(at: index)
    }

    private func points(at index: Int, count: Int) -> PointsRef {
        PointsRef(bytes: bytes, start: index, count: count)
    }
}
