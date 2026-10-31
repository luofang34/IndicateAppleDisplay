import Foundation
import simd

/// Format version carried in the first byte of every encoded scene.
public let sceneFormatVersion: UInt8 = 1

/// Bounds a conforming backend must accept, and refuse beyond.
public enum SceneBudget {
    public static let maxLayerCommands = 4096
    public static let maxStackDepth = 32
    public static let maxSceneBytes = 64 * 1024
    public static let maxTextBytes = 250
}

/// Straight-alpha sRGB paint.
public struct Rgba8: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Unpacks the wire `u32`, which is little-endian `r | g<<8 | b<<16 | a<<24`.
    public init(packed: UInt32) {
        red = UInt8(packed & 0xff)
        green = UInt8((packed >> 8) & 0xff)
        blue = UInt8((packed >> 16) & 0xff)
        alpha = UInt8((packed >> 24) & 0xff)
    }

    /// Packs the color into the little-endian wire `UInt32` (`0xAABBGGRR`).
    public var packed: UInt32 {
        UInt32(red)
            | UInt32(green) << 8
            | UInt32(blue) << 16
            | UInt32(alpha) << 24
    }
}

/// Shared scene color alias for 2D and 3D scene streams (`0xAABBGGRR` little-endian).
public typealias SceneColor = Rgba8

/// Whether a shape is filled, stroked, or both.
public enum PaintMode: Equatable, Sendable {
    case fill
    case stroke
    case fillStroke

    /// Decodes the wire bits; `nil` when neither bit is set.
    public init?(wire: UInt8) {
        switch wire & 0b11 {
        case 0b01: self = .fill
        case 0b10: self = .stroke
        case 0b11: self = .fillStroke
        default: return nil
        }
    }

    /// Decodes the 3D volume wire byte (`0 = fill`, `1 = stroke`, `2 = fillStroke`).
    public init?(volumeWire: UInt8) {
        switch volumeWire {
        case 0: self = .fill
        case 1: self = .stroke
        case 2: self = .fillStroke
        default: return nil
        }
    }

    /// Encodes the paint mode as the 3D volume wire byte (`0..=2`).
    public var volumeWire: UInt8 {
        switch self {
        case .fill: 0
        case .stroke: 1
        case .fillStroke: 2
        }
    }

    /// The letter the conformance trace uses.
    public var traceLetter: String {
        switch self {
        case .fill: "F"
        case .stroke: "S"
        case .fillStroke: "FS"
        }
    }
}

/// Where a text run sits relative to its anchor point.
public struct Anchor: Equatable, Sendable {
    public enum Horizontal: UInt8, Sendable { case left = 0, center = 1, right = 2 }
    public enum Vertical: UInt8, Sendable { case baseline = 0, middle = 1, top = 2, bottom = 3 }

    public let horizontal: Horizontal
    public let vertical: Vertical

    /// Decodes the wire byte; `nil` for a reserved horizontal value.
    public init?(wire: UInt8) {
        guard let horizontal = Horizontal(rawValue: wire & 0b11) else { return nil }
        guard let vertical = Vertical(rawValue: (wire >> 2) & 0b11) else { return nil }
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

/// A view of a point list that borrows the encoded bytes.
///
/// Points stay in the scene buffer rather than being copied into an array, so
/// decoding a frame allocates nothing per command.
public struct PointsRef: Equatable, Sendable {
    private let bytes: [UInt8]
    private let start: Int

    public let count: Int

    init(bytes: [UInt8], start: Int, count: Int) {
        self.bytes = bytes
        self.start = start
        self.count = count
    }

    /// The point at `index` as an (x, y) pair.
    public subscript(index: Int) -> (x: Float, y: Float) {
        let at = start + index * 8
        return (bytes.float32(at: at), bytes.float32(at: at + 4))
    }
}

/// One decoded drawing command.
public enum SceneCommand: Equatable, Sendable {
    case save
    case restore
    case translate(x: Float, y: Float)
    case rotate(radians: Float)
    case fillColor(Rgba8)
    case stroke(color: Rgba8, width: Float)
    case line(x1: Float, y1: Float, x2: Float, y2: Float)
    case polyline(points: PointsRef)
    case polygon(mode: PaintMode, points: PointsRef)
    case rect(mode: PaintMode, x: Float, y: Float, width: Float, height: Float)
    case circle(mode: PaintMode, centerX: Float, centerY: Float, radius: Float)
    case arc(centerX: Float, centerY: Float, radius: Float, start: Float, sweep: Float)
    case text(x: Float, y: Float, size: Float, anchor: Anchor, bytes: [UInt8])
    /// Claims the source of the run that follows. Draws nothing.
    ///
    /// A numeric readout carries the state group it derives from, so a value
    /// on screen can be traced to the data that produced it rather than being
    /// taken on trust. A backend paints nothing for this, but it must decode
    /// it: counting it as unknown would hide that the producer is making
    /// provenance claims this backend cannot check.
    case attribute(group: UInt8)
    case clipRect(x: Float, y: Float, width: Float, height: Float)
    case beginLayer(SceneLayer)
    case endLayer(SceneLayer)
    /// An opcode this revision does not know. Counted and skipped, never fatal.
    case unknown(opcode: UInt8)
}

extension [UInt8] {
    /// Reads a little-endian `f32` that may sit at any alignment.
    func float32(at index: Int) -> Float {
        Float(bitPattern: unsigned32(at: index))
    }

    func unsigned32(at index: Int) -> UInt32 {
        UInt32(self[index])
            | UInt32(self[index + 1]) << 8
            | UInt32(self[index + 2]) << 16
            | UInt32(self[index + 3]) << 24
    }

    func unsigned16(at index: Int) -> UInt16 {
        UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }

    func unsigned64(at index: Int) -> UInt64 {
        let low = UInt64(unsigned32(at: index))
        let high = UInt64(unsigned32(at: index + 4))
        return low | (high << 32)
    }

    func float64(at index: Int) -> Double {
        Double(bitPattern: unsigned64(at: index))
    }

    func simd3(at index: Int) -> SIMD3<Float> {
        SIMD3(
            float32(at: index),
            float32(at: index + 4),
            float32(at: index + 8)
        )
    }

    func simd4(at index: Int) -> SIMD4<Float> {
        SIMD4(
            float32(at: index),
            float32(at: index + 4),
            float32(at: index + 8),
            float32(at: index + 12)
        )
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        appendUInt32LE(UInt32(truncatingIfNeeded: value))
        appendUInt32LE(UInt32(truncatingIfNeeded: value >> 32))
    }

    mutating func appendFloat32LE(_ value: Float) {
        appendUInt32LE(value.bitPattern)
    }

    mutating func appendFloat64LE(_ value: Double) {
        appendUInt64LE(value.bitPattern)
    }

    mutating func appendSIMD3LE(_ value: SIMD3<Float>) {
        appendFloat32LE(value.x)
        appendFloat32LE(value.y)
        appendFloat32LE(value.z)
    }

    mutating func appendSIMD4LE(_ value: SIMD4<Float>) {
        appendFloat32LE(value.x)
        appendFloat32LE(value.y)
        appendFloat32LE(value.z)
        appendFloat32LE(value.w)
    }
}

func isFiniteSIMD3(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
}

func isFiniteSIMD4(_ value: SIMD4<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
}

func isUnitSIMD3(_ value: SIMD3<Float>, tolerance: Float = 1e-3) -> Bool {
    guard isFiniteSIMD3(value) else { return false }
    let normSq = value.x * value.x + value.y * value.y + value.z * value.z
    guard normSq.isFinite else { return false }
    let norm = normSq.squareRoot()
    return norm.isFinite && abs(norm - 1.0) <= tolerance
}

func isUnitSIMD4(_ value: SIMD4<Float>, tolerance: Float = 1e-3) -> Bool {
    guard isFiniteSIMD4(value) else { return false }
    let normSq = value.x * value.x + value.y * value.y + value.z * value.z + value.w * value.w
    guard normSq.isFinite else { return false }
    let norm = normSq.squareRoot()
    return norm.isFinite && abs(norm - 1.0) <= tolerance
}
