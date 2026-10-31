import Foundation
import simd

/// Format version byte at offset `0` of every encoded 3D volumetric scene.
public let volumeSceneFormatVersion: UInt8 = 1

/// Wire limits and protocol constants for the 3D volumetric scene backend.
public enum VolumeSceneBackend {
    /// Wire format version read by ``VolumeSceneDecoder``.
    public static let formatVersion: UInt8 = volumeSceneFormatVersion
    /// Maximum encoded byte length of one 3D volumetric scene.
    public static let maxSceneBytes = 65_536
    /// Maximum command count inside one ``VolumeBand``.
    public static let maxBandCommands = 4_096
    /// Maximum nested `save` depth inside one ``VolumeBand``.
    public static let maxStackDepth = 32
    /// Maximum UTF-8 byte length of one ``VolumeSceneCommand/billboardText(position:sizeMeters:anchor:text:)``.
    public static let maxTextBytes = 250
    /// Minimum vertex count in one ``VolumeSceneCommand/polyline3D(_:)``.
    public static let minPolylineVertices = 2
    /// Maximum vertex count in one ``VolumeSceneCommand/polyline3D(_:)``.
    public static let maxPolylineVertices = 512
    /// Maximum height sample count (`cols * rows`) in one ``VolumeSceneCommand/heightfieldGrid(cols:rows:origin:stepX:stepZ:heights:)``.
    public static let maxHeightfieldSamples = 1_024
}

/// Semantic category of an interactive 3D target handle.
public enum HandleKind: UInt8, CaseIterable, Equatable, Sendable {
    /// Generic 3D reference point.
    case point = 1
    /// Lateral or 3D navigation waypoint.
    case waypoint = 2
    /// Vertical altitude selection bug.
    case altitudeBug = 3
    /// Trajectory or orbital manoeuvre node.
    case manoeuvreNode = 4
    /// Airspace or volume boundary control handle.
    case volumeBoundary = 5
}

/// Kind of host-supplied 3D underlay anchored inside a volumetric instrument.
public enum VolumeUnderlayKind: UInt8, CaseIterable, Equatable, Sendable {
    /// Local 3D terrain patch.
    case terrainPatch = 1
    /// 3D planetary or lunar globe.
    case planetaryGlobe = 2
    /// Multi-body solar-system or cislunar ephemeris frame.
    case celestialSystem = 3
}

/// Horizontal alignment of a 3D billboard text run relative to its anchor point.
public enum TextAnchor: UInt8, CaseIterable, Equatable, Sendable {
    /// The anchor point marks the left edge of the text run.
    case left = 0
    /// The anchor point marks the horizontal center of the text run.
    case center = 1
    /// The anchor point marks the right edge of the text run.
    case right = 2
}

/// One decoded command from a `VOLUME_SCENE_VERSION = 1` byte stream.
public enum VolumeSceneCommand: Equatable, Sendable {
    /// Pushes the active 3D transform, clip box, paint state, and provenance state.
    case save
    /// Restores the most recently saved 3D state.
    case restore
    /// Translates the active local coordinate frame in meters.
    case translate3D(dx: Float, dy: Float, dz: Float)
    /// Rotates the active local coordinate frame by a unit quaternion (`x, y, z, w`).
    case rotateQuat(qx: Float, qy: Float, qz: Float, qw: Float)
    /// Intersects the active clip region with an axis-aligned 3D bounding box.
    case clipBox3D(min: SIMD3<Float>, max: SIMD3<Float>)
    /// Sets the active fill color (`0xAABBGGRR` little-endian).
    case fillColor(SceneColor)
    /// Sets the active 3D stroke color and tube radius in meters.
    case stroke3D(color: SceneColor, radiusMeters: Float)
    /// Records the state-group provenance tag for subsequent numeric text.
    case attribute(group: UInt8)
    /// Declares an interactive 3D hit-test handle with a non-zero target identifier.
    case targetHandle(
        targetId: UInt32,
        kind: HandleKind,
        center: SIMD3<Float>,
        radiusMeters: Float
    )
    /// Draws a 3D line segment between `a` and `b`.
    case line3D(a: SIMD3<Float>, b: SIMD3<Float>)
    /// Draws a connected 3D polyline through `2...512` vertices.
    case polyline3D([SIMD3<Float>])
    /// Draws a 3D sphere centered at `center`.
    case sphere(mode: PaintMode, center: SIMD3<Float>, radiusMeters: Float)
    /// Draws an axis-aligned 3D box between `min` and `max`.
    case box3D(mode: PaintMode, min: SIMD3<Float>, max: SIMD3<Float>)
    /// Draws a 3D cylinder spanning from `base` to `top`.
    case cylinder3D(
        mode: PaintMode,
        base: SIMD3<Float>,
        top: SIMD3<Float>,
        radiusMeters: Float
    )
    /// Draws a 3D ring centered at `center` perpendicular to unit vector `normal`.
    case ring3D(center: SIMD3<Float>, normal: SIMD3<Float>, radiusMeters: Float)
    /// Draws a regular 3D heightfield surface grid.
    case heightfieldGrid(
        cols: UInt8,
        rows: UInt8,
        origin: SIMD3<Float>,
        stepX: Float,
        stepZ: Float,
        heights: [Float]
    )
    /// Places a host-managed 3D underlay anchor inside the volume.
    case underlayAnchor3D(
        kind: VolumeUnderlayKind,
        center: SIMD3<Float>,
        extent: SIMD3<Float>,
        orientation: SIMD4<Float>,
        metersPerUnit: Double
    )
    /// Draws a camera-facing text run in meters.
    case billboardText(
        position: SIMD3<Float>,
        sizeMeters: Float,
        anchor: TextAnchor,
        text: String
    )
    /// Opens a criticality band (`0...8`).
    case beginBand(VolumeBand)
    /// Closes the active criticality band (`0...8`).
    case endBand(VolumeBand)
    /// Carries an unrecognized opcode outside the reserved `0x50...0x5F` range.
    case unknown(opcode: UInt8)
}

/// Errors raised when encoding a ``VolumeSceneCommand`` sequence.
public enum VolumeSceneEncodeError: Error, Equatable, Sendable {
    case invalidPayload(VolumeSceneCommand)
    case sceneTooLarge(bytes: Int)
}

/// Binary encoder for `VOLUME_SCENE_VERSION = 1` command streams.
public enum VolumeSceneEncoder {
    /// Encodes `commands` into a versioned `VOLUME_SCENE_VERSION = 1` byte buffer.
    public static func encode(
        _ commands: [VolumeSceneCommand]
    ) throws(VolumeSceneEncodeError) -> [UInt8] {
        var out: [UInt8] = [VolumeSceneBackend.formatVersion]
        for command in commands {
            try appendCommand(command, into: &out)
            if out.count > VolumeSceneBackend.maxSceneBytes {
                throw VolumeSceneEncodeError.sceneTooLarge(bytes: out.count)
            }
        }
        return out
    }

    private static func appendCommand(
        _ command: VolumeSceneCommand,
        into out: inout [UInt8]
    ) throws(VolumeSceneEncodeError) {
        var payload: [UInt8] = []
        let opcode: UInt8
        switch command {
        case .save:
            opcode = 0x01
        case .restore:
            opcode = 0x02
        case let .translate3D(dx, dy, dz):
            guard dx.isFinite, dy.isFinite, dz.isFinite else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x03
            payload.appendFloat32LE(dx)
            payload.appendFloat32LE(dy)
            payload.appendFloat32LE(dz)
        case let .rotateQuat(qx, qy, qz, qw):
            let q = SIMD4(qx, qy, qz, qw)
            guard isUnitSIMD4(q) else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x04
            payload.appendSIMD4LE(q)
        case let .clipBox3D(min, max):
            guard isFiniteSIMD3(min), isFiniteSIMD3(max),
                  min.x <= max.x, min.y <= max.y, min.z <= max.z else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x05
            payload.appendSIMD3LE(min)
            payload.appendSIMD3LE(max)
        case let .fillColor(color):
            opcode = 0x10
            payload.appendUInt32LE(color.packed)
        case let .stroke3D(color, radiusMeters):
            guard radiusMeters.isFinite, radiusMeters >= 0 else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x11
            payload.appendUInt32LE(color.packed)
            payload.appendFloat32LE(radiusMeters)
        case let .attribute(group):
            opcode = 0x12
            payload.append(group)
        case let .targetHandle(targetId, kind, center, radiusMeters):
            guard targetId != 0, isFiniteSIMD3(center),
                  radiusMeters.isFinite, radiusMeters > 0 else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x13
            payload.appendUInt32LE(targetId)
            payload.append(kind.rawValue)
            payload.appendSIMD3LE(center)
            payload.appendFloat32LE(radiusMeters)
        case let .line3D(a, b):
            guard isFiniteSIMD3(a), isFiniteSIMD3(b) else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x20
            payload.appendSIMD3LE(a)
            payload.appendSIMD3LE(b)
        case let .polyline3D(points):
            guard points.count >= VolumeSceneBackend.minPolylineVertices,
                  points.count <= VolumeSceneBackend.maxPolylineVertices,
                  points.allSatisfy(isFiniteSIMD3) else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x21
            payload.reserveCapacity(points.count * 12)
            for point in points {
                payload.appendSIMD3LE(point)
            }
        case let .sphere(mode, center, radiusMeters):
            guard isFiniteSIMD3(center), radiusMeters.isFinite, radiusMeters > 0 else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x23
            payload.append(mode.volumeWire)
            payload.appendSIMD3LE(center)
            payload.appendFloat32LE(radiusMeters)
        case let .box3D(mode, min, max):
            guard isFiniteSIMD3(min), isFiniteSIMD3(max),
                  min.x <= max.x, min.y <= max.y, min.z <= max.z else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x24
            payload.append(mode.volumeWire)
            payload.appendSIMD3LE(min)
            payload.appendSIMD3LE(max)
        case let .cylinder3D(mode, base, top, radiusMeters):
            guard isFiniteSIMD3(base), isFiniteSIMD3(top),
                  radiusMeters.isFinite, radiusMeters > 0 else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x25
            payload.append(mode.volumeWire)
            payload.appendSIMD3LE(base)
            payload.appendSIMD3LE(top)
            payload.appendFloat32LE(radiusMeters)
        case let .ring3D(center, normal, radiusMeters):
            guard isFiniteSIMD3(center), isUnitSIMD3(normal),
                  radiusMeters.isFinite, radiusMeters > 0 else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x26
            payload.appendSIMD3LE(center)
            payload.appendSIMD3LE(normal)
            payload.appendFloat32LE(radiusMeters)
        case let .heightfieldGrid(cols, rows, origin, stepX, stepZ, heights):
            let sampleCount = Int(cols) * Int(rows)
            guard cols >= 2, rows >= 2,
                  sampleCount <= VolumeSceneBackend.maxHeightfieldSamples,
                  heights.count == sampleCount,
                  isFiniteSIMD3(origin),
                  stepX.isFinite, stepX > 0,
                  stepZ.isFinite, stepZ > 0,
                  heights.allSatisfy(\.isFinite) else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x27
            payload.reserveCapacity(22 + sampleCount * 4)
            payload.append(cols)
            payload.append(rows)
            payload.appendSIMD3LE(origin)
            payload.appendFloat32LE(stepX)
            payload.appendFloat32LE(stepZ)
            for height in heights {
                payload.appendFloat32LE(height)
            }
        case let .underlayAnchor3D(kind, center, extent, orientation, metersPerUnit):
            guard isFiniteSIMD3(center), isFiniteSIMD3(extent),
                  extent.x > 0, extent.y > 0, extent.z > 0,
                  isUnitSIMD4(orientation),
                  metersPerUnit.isFinite, metersPerUnit > 0 else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x28
            payload.append(kind.rawValue)
            payload.appendSIMD3LE(center)
            payload.appendSIMD3LE(extent)
            payload.appendSIMD4LE(orientation)
            payload.appendFloat64LE(metersPerUnit)
        case let .billboardText(position, sizeMeters, anchor, text):
            let utf8 = Array(text.utf8)
            guard isFiniteSIMD3(position),
                  sizeMeters.isFinite, sizeMeters > 0,
                  !utf8.isEmpty, utf8.count <= VolumeSceneBackend.maxTextBytes else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = 0x30
            payload.reserveCapacity(17 + utf8.count)
            payload.appendSIMD3LE(position)
            payload.appendFloat32LE(sizeMeters)
            payload.append(anchor.rawValue)
            payload.append(contentsOf: utf8)
        case let .beginBand(band):
            opcode = 0x50
            payload.append(band.rawValue)
        case let .endBand(band):
            opcode = 0x51
            payload.append(band.rawValue)
        case let .unknown(rawOpcode):
            guard !(0x50...0x5f).contains(rawOpcode) else {
                throw VolumeSceneEncodeError.invalidPayload(command)
            }
            opcode = rawOpcode
        }
        guard payload.count <= Int(UInt16.max) else {
            throw VolumeSceneEncodeError.invalidPayload(command)
        }
        out.append(opcode)
        out.appendUInt16LE(UInt16(payload.count))
        out.append(contentsOf: payload)
    }
}
