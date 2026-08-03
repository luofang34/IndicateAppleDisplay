import Foundation

/// Renders decoded commands as the canonical conformance trace.
///
/// The trace is the cross-backend equality check: every backend decoding the
/// same bytes must produce the same strings. Coordinates are quantized to Q8.8
/// so a comparison is exact rather than a floating-point tolerance.
public enum SceneTrace {
    /// The trace for one scene, or a decode failure.
    public static func trace(_ bytes: [UInt8]) throws(SceneDecodeError) -> [String] {
        try SceneDecoder.commands(bytes).map(entry)
    }

    /// One command's canonical trace entry.
    public static func entry(_ command: SceneCommand) -> String {
        switch command {
        case .save: "01"
        case .restore: "02"
        case let .translate(x, y): "03:\(q(x)),\(q(y))"
        case let .rotate(radians): "04:\(q(radians))"
        case let .fillColor(color): "10:\(channels(color))"
        case let .stroke(color, width): "11:\(channels(color)),\(q(width))"
        case let .line(x1, y1, x2, y2): "20:\(q(x1)),\(q(y1)),\(q(x2)),\(q(y2))"
        case let .polyline(points): "21:\(coordinates(points))"
        case let .polygon(mode, points): "22:\(mode.traceLetter):\(coordinates(points))"
        case let .rect(mode, x, y, width, height):
            "23:\(mode.traceLetter),\(q(x)),\(q(y)),\(q(width)),\(q(height))"
        case let .circle(mode, centerX, centerY, radius):
            "24:\(mode.traceLetter),\(q(centerX)),\(q(centerY)),\(q(radius))"
        case let .arc(centerX, centerY, radius, start, sweep):
            "25:\(q(centerX)),\(q(centerY)),\(q(radius)),\(q(start)),\(q(sweep))"
        case let .text(x, y, size, anchor, bytes):
            "30:\(q(size)),\(anchorWire(anchor)),\(q(x)),\(q(y)),\(hex(bytes))"
        case let .clipRect(x, y, width, height):
            "40:\(q(x)),\(q(y)),\(q(width)),\(q(height))"
        case let .beginLayer(layer): "50:\(layer.rawValue)"
        case let .endLayer(layer): "51:\(layer.rawValue)"
        case let .unknown(opcode): "unknown:\(opcode)"
        }
    }

    /// Q8.8 quantization: `floor(value * 256)`, with non-finite spelled out.
    private static func q(_ value: Float) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value > 0 ? "inf" : "-inf" }
        return String(Int64((Double(value) * 256).rounded(.down)))
    }

    private static func channels(_ color: Rgba8) -> String {
        "\(color.red),\(color.green),\(color.blue),\(color.alpha)"
    }

    private static func coordinates(_ points: PointsRef) -> String {
        var parts: [String] = []
        parts.reserveCapacity(points.count * 2)
        for index in 0..<points.count {
            let point = points[index]
            parts.append(q(point.x))
            parts.append(q(point.y))
        }
        return parts.joined(separator: ",")
    }

    private static func anchorWire(_ anchor: Anchor) -> String {
        String(anchor.horizontal.rawValue | (anchor.vertical.rawValue << 2))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
