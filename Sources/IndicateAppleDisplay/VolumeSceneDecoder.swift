import Foundation
import simd

/// Errors raised when decoding a `VOLUME_SCENE_VERSION = 1` byte stream.
public enum VolumeSceneDecodeError: Error, Equatable, Sendable {
    /// The leading version byte does not equal ``VolumeSceneBackend/formatVersion``.
    case badVersion(UInt8)
    /// The byte stream ends inside the version byte, a command header, or a payload.
    case truncated
    /// A known opcode carries a malformed, out-of-range, or non-finite payload.
    case badPayload(opcode: UInt8)
}

private enum VolumeOpcode {
    static let save: UInt8 = 0x01
    static let restore: UInt8 = 0x02
    static let translate3D: UInt8 = 0x03
    static let rotateQuat: UInt8 = 0x04
    static let clipBox3D: UInt8 = 0x05
    static let fillColor: UInt8 = 0x10
    static let stroke3D: UInt8 = 0x11
    static let attribute: UInt8 = 0x12
    static let targetHandle: UInt8 = 0x13
    static let line3D: UInt8 = 0x20
    static let polyline3D: UInt8 = 0x21
    static let sphere: UInt8 = 0x23
    static let box3D: UInt8 = 0x24
    static let cylinder3D: UInt8 = 0x25
    static let ring3D: UInt8 = 0x26
    static let heightfieldGrid: UInt8 = 0x27
    static let underlayAnchor3D: UInt8 = 0x28
    static let billboardText: UInt8 = 0x30
    static let beginBand: UInt8 = 0x50
    static let endBand: UInt8 = 0x51
    static let reservedBandFirst: UInt8 = 0x52
    static let reservedBandLast: UInt8 = 0x5f
}

/// Streaming decoder for `VOLUME_SCENE_VERSION = 1` command buffers.
///
/// Each command uses the framing `[opcode: UInt8][payloadLen: UInt16 LE][payload]`.
/// Unrecognized opcodes outside `0x50...0x5F` decode as ``VolumeSceneCommand/unknown(opcode:)``
/// so the validator can apply ``UnknownOpcodePolicy``.
public struct VolumeSceneDecoder: Sendable {
    private let bytes: [UInt8]
    private var cursor: Int

    /// Initializes a decoder and verifies the leading format version byte.
    public init(_ bytes: [UInt8]) throws(VolumeSceneDecodeError) {
        guard let version = bytes.first else {
            throw VolumeSceneDecodeError.truncated
        }
        guard version == VolumeSceneBackend.formatVersion else {
            throw VolumeSceneDecodeError.badVersion(version)
        }
        self.bytes = bytes
        cursor = 1
    }

    /// Decodes the next command, or returns `nil` at the end of the buffer.
    public mutating func next() throws(VolumeSceneDecodeError) -> VolumeSceneCommand? {
        if cursor == bytes.count { return nil }
        guard cursor + 3 <= bytes.count else {
            throw VolumeSceneDecodeError.truncated
        }
        let opcode = bytes[cursor]
        let length = Int(bytes.unsigned16(at: cursor + 1))
        let payload = cursor + 3
        guard payload + length <= bytes.count else {
            throw VolumeSceneDecodeError.truncated
        }
        cursor = payload + length
        return try decode(opcode: opcode, at: payload, length: length)
    }

    /// Decodes an entire `VOLUME_SCENE_VERSION = 1` buffer into an array of commands.
    public static func commands(
        _ bytes: [UInt8]
    ) throws(VolumeSceneDecodeError) -> [VolumeSceneCommand] {
        var decoder = try VolumeSceneDecoder(bytes)
        var result: [VolumeSceneCommand] = []
        while let command = try decoder.next() {
            result.append(command)
        }
        return result
    }

    private func decode(
        opcode: UInt8,
        at payload: Int,
        length: Int
    ) throws(VolumeSceneDecodeError) -> VolumeSceneCommand {
        switch opcode {
        case VolumeOpcode.save:
            try require(length == 0, opcode)
            return .save
        case VolumeOpcode.restore:
            try require(length == 0, opcode)
            return .restore
        case VolumeOpcode.translate3D:
            try require(length == 12, opcode)
            let v = bytes.simd3(at: payload)
            try require(isFiniteSIMD3(v), opcode)
            return .translate3D(dx: v.x, dy: v.y, dz: v.z)
        case VolumeOpcode.rotateQuat:
            try require(length == 16, opcode)
            let q = bytes.simd4(at: payload)
            try require(isUnitSIMD4(q), opcode)
            return .rotateQuat(qx: q.x, qy: q.y, qz: q.z, qw: q.w)
        case VolumeOpcode.clipBox3D:
            try require(length == 24, opcode)
            let min = bytes.simd3(at: payload)
            let max = bytes.simd3(at: payload + 12)
            try require(
                isFiniteSIMD3(min) && isFiniteSIMD3(max)
                    && min.x <= max.x && min.y <= max.y && min.z <= max.z,
                opcode
            )
            return .clipBox3D(min: min, max: max)
        case VolumeOpcode.fillColor:
            try require(length == 4, opcode)
            return .fillColor(SceneColor(packed: bytes.unsigned32(at: payload)))
        case VolumeOpcode.stroke3D:
            try require(length == 8, opcode)
            let color = SceneColor(packed: bytes.unsigned32(at: payload))
            let radius = bytes.float32(at: payload + 4)
            try require(radius.isFinite && radius >= 0, opcode)
            return .stroke3D(color: color, radiusMeters: radius)
        case VolumeOpcode.attribute:
            try require(length == 1, opcode)
            return .attribute(group: bytes[payload])
        case VolumeOpcode.targetHandle:
            try require(length == 21, opcode)
            let targetId = bytes.unsigned32(at: payload)
            guard targetId != 0,
                  let kind = HandleKind(rawValue: bytes[payload + 4]) else {
                throw VolumeSceneDecodeError.badPayload(opcode: opcode)
            }
            let center = bytes.simd3(at: payload + 5)
            let radius = bytes.float32(at: payload + 17)
            try require(isFiniteSIMD3(center) && radius.isFinite && radius > 0, opcode)
            return .targetHandle(
                targetId: targetId,
                kind: kind,
                center: center,
                radiusMeters: radius
            )
        case VolumeOpcode.line3D:
            try require(length == 24, opcode)
            let a = bytes.simd3(at: payload)
            let b = bytes.simd3(at: payload + 12)
            try require(isFiniteSIMD3(a) && isFiniteSIMD3(b), opcode)
            return .line3D(a: a, b: b)
        case VolumeOpcode.polyline3D:
            try require(length % 12 == 0, opcode)
            let count = length / 12
            try require(
                count >= VolumeSceneBackend.minPolylineVertices
                    && count <= VolumeSceneBackend.maxPolylineVertices,
                opcode
            )
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(count)
            for index in 0..<count {
                let point = bytes.simd3(at: payload + index * 12)
                try require(isFiniteSIMD3(point), opcode)
                points.append(point)
            }
            return .polyline3D(points)
        case VolumeOpcode.sphere:
            try require(length == 17, opcode)
            guard let mode = PaintMode(volumeWire: bytes[payload]) else {
                throw VolumeSceneDecodeError.badPayload(opcode: opcode)
            }
            let center = bytes.simd3(at: payload + 1)
            let radius = bytes.float32(at: payload + 13)
            try require(isFiniteSIMD3(center) && radius.isFinite && radius > 0, opcode)
            return .sphere(mode: mode, center: center, radiusMeters: radius)
        case VolumeOpcode.box3D:
            try require(length == 25, opcode)
            guard let mode = PaintMode(volumeWire: bytes[payload]) else {
                throw VolumeSceneDecodeError.badPayload(opcode: opcode)
            }
            let min = bytes.simd3(at: payload + 1)
            let max = bytes.simd3(at: payload + 13)
            try require(
                isFiniteSIMD3(min) && isFiniteSIMD3(max)
                    && min.x <= max.x && min.y <= max.y && min.z <= max.z,
                opcode
            )
            return .box3D(mode: mode, min: min, max: max)
        case VolumeOpcode.cylinder3D:
            try require(length == 29, opcode)
            guard let mode = PaintMode(volumeWire: bytes[payload]) else {
                throw VolumeSceneDecodeError.badPayload(opcode: opcode)
            }
            let base = bytes.simd3(at: payload + 1)
            let top = bytes.simd3(at: payload + 13)
            let radius = bytes.float32(at: payload + 25)
            try require(
                isFiniteSIMD3(base) && isFiniteSIMD3(top)
                    && radius.isFinite && radius > 0,
                opcode
            )
            return .cylinder3D(mode: mode, base: base, top: top, radiusMeters: radius)
        case VolumeOpcode.ring3D:
            try require(length == 28, opcode)
            let center = bytes.simd3(at: payload)
            let normal = bytes.simd3(at: payload + 12)
            let radius = bytes.float32(at: payload + 24)
            try require(
                isFiniteSIMD3(center) && isUnitSIMD3(normal)
                    && radius.isFinite && radius > 0,
                opcode
            )
            return .ring3D(center: center, normal: normal, radiusMeters: radius)
        case VolumeOpcode.heightfieldGrid:
            return try decodeHeightfield(opcode: opcode, at: payload, length: length)
        case VolumeOpcode.underlayAnchor3D:
            return try decodeUnderlayAnchor(opcode: opcode, at: payload, length: length)
        case VolumeOpcode.billboardText:
            return try decodeBillboardText(opcode: opcode, at: payload, length: length)
        case VolumeOpcode.beginBand, VolumeOpcode.endBand:
            try require(length == 1, opcode)
            guard let band = VolumeBand(rawValue: bytes[payload]) else {
                throw VolumeSceneDecodeError.badPayload(opcode: opcode)
            }
            return opcode == VolumeOpcode.beginBand ? .beginBand(band) : .endBand(band)
        case VolumeOpcode.reservedBandFirst...VolumeOpcode.reservedBandLast:
            throw VolumeSceneDecodeError.badPayload(opcode: opcode)
        default:
            return .unknown(opcode: opcode)
        }
    }

    private func decodeHeightfield(
        opcode: UInt8,
        at payload: Int,
        length: Int
    ) throws(VolumeSceneDecodeError) -> VolumeSceneCommand {
        try require(length >= 22, opcode)
        let cols = bytes[payload]
        let rows = bytes[payload + 1]
        let sampleCount = Int(cols) * Int(rows)
        try require(
            cols >= 2 && rows >= 2
                && sampleCount <= VolumeSceneBackend.maxHeightfieldSamples
                && length == 22 + 4 * sampleCount,
            opcode
        )
        let origin = bytes.simd3(at: payload + 2)
        let stepX = bytes.float32(at: payload + 14)
        let stepZ = bytes.float32(at: payload + 18)
        try require(
            isFiniteSIMD3(origin)
                && stepX.isFinite && stepX > 0
                && stepZ.isFinite && stepZ > 0,
            opcode
        )
        var heights: [Float] = []
        heights.reserveCapacity(sampleCount)
        let heightsStart = payload + 22
        for index in 0..<sampleCount {
            let h = bytes.float32(at: heightsStart + index * 4)
            try require(h.isFinite, opcode)
            heights.append(h)
        }
        return .heightfieldGrid(
            cols: cols,
            rows: rows,
            origin: origin,
            stepX: stepX,
            stepZ: stepZ,
            heights: heights
        )
    }

    private func decodeUnderlayAnchor(
        opcode: UInt8,
        at payload: Int,
        length: Int
    ) throws(VolumeSceneDecodeError) -> VolumeSceneCommand {
        try require(length == 49, opcode)
        guard let kind = VolumeUnderlayKind(rawValue: bytes[payload]) else {
            throw VolumeSceneDecodeError.badPayload(opcode: opcode)
        }
        let center = bytes.simd3(at: payload + 1)
        let extent = bytes.simd3(at: payload + 13)
        let orientation = bytes.simd4(at: payload + 25)
        let metersPerUnit = bytes.float64(at: payload + 41)
        try require(
            isFiniteSIMD3(center)
                && isFiniteSIMD3(extent)
                && extent.x > 0 && extent.y > 0 && extent.z > 0
                && isUnitSIMD4(orientation)
                && metersPerUnit.isFinite && metersPerUnit > 0,
            opcode
        )
        return .underlayAnchor3D(
            kind: kind,
            center: center,
            extent: extent,
            orientation: orientation,
            metersPerUnit: metersPerUnit
        )
    }

    private func decodeBillboardText(
        opcode: UInt8,
        at payload: Int,
        length: Int
    ) throws(VolumeSceneDecodeError) -> VolumeSceneCommand {
        try require(length >= 18, opcode)
        let utf8Length = length - 17
        try require(utf8Length >= 1 && utf8Length <= VolumeSceneBackend.maxTextBytes, opcode)
        let position = bytes.simd3(at: payload)
        let sizeMeters = bytes.float32(at: payload + 12)
        guard isFiniteSIMD3(position), sizeMeters.isFinite, sizeMeters > 0,
              let anchor = TextAnchor(rawValue: bytes[payload + 16]) else {
            throw VolumeSceneDecodeError.badPayload(opcode: opcode)
        }
        let slice = bytes[(payload + 17)..<(payload + length)]
        guard let text = String(bytes: slice, encoding: .utf8) else {
            throw VolumeSceneDecodeError.badPayload(opcode: opcode)
        }
        return .billboardText(
            position: position,
            sizeMeters: sizeMeters,
            anchor: anchor,
            text: text
        )
    }

    private func require(_ condition: Bool, _ opcode: UInt8) throws(VolumeSceneDecodeError) {
        guard condition else {
            throw VolumeSceneDecodeError.badPayload(opcode: opcode)
        }
    }
}
