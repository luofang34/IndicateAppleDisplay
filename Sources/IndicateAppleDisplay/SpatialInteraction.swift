import Foundation
import simd

/// Wire format version for encoded ``InteractionFrame`` packets.
public let interactionFormatVersion: UInt8 = 1

/// Wire format version for encoded ``ViewPose3D`` packets.
public let viewPoseVersion: UInt8 = 1

/// Fixed byte length of an encoded ``ViewPose3D`` packet.
public let viewPoseBytes = 48

/// Maximum byte length of an encoded ``InteractionFrame`` packet.
public let maxInteractionBytes = 72

/// Non-zero scene-target identifier for spatial hit-testing, or ``none`` when unattached.
public struct TargetId: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Sentinel identifier representing no target handle.
    public static let none = TargetId(rawValue: 0)
}

/// Lifecycle phase of a continuous 3D drag or two-hand transform gesture.
public enum GesturePhase: UInt8, CaseIterable, Equatable, Sendable {
    case began = 1
    case changed = 2
    case ended = 3
    case cancelled = 4
}

/// Transition state of a discrete hardware or bezel key input.
public enum KeyState: UInt8, CaseIterable, Equatable, Sendable {
    case pressed = 1
    case released = 2
    case repeatPress = 3
}

/// Device origin, monotonic sequence, and microsecond timestamp of an interaction event.
public struct InteractionStamp: Equatable, Sendable {
    /// Identifier of the input device that emitted the event.
    public var deviceId: UInt32
    /// Wrapping per-device sequence number.
    public var sequence: UInt32
    /// Device clock timestamp in microseconds.
    public var timestampUs: UInt64

    public init(deviceId: UInt32, sequence: UInt32, timestampUs: UInt64) {
        self.deviceId = deviceId
        self.sequence = sequence
        self.timestampUs = timestampUs
    }
}

/// Canonical spatial interaction event in instrument-local coordinates.
public enum SpatialEvent: Equatable, Sendable {
    /// Primary tap or pinch-select activation (`opcode = 0x01`, `16` payload bytes).
    case activate(target: TargetId, pointLocal: SIMD3<Float>)
    /// Single-hand 3D drag translation (`opcode = 0x02`, `29` payload bytes).
    case drag3D(
        phase: GesturePhase,
        target: TargetId,
        originLocal: SIMD3<Float>,
        deltaLocal: SIMD3<Float>
    )
    /// Two-hand 3D pan, orbit rotation, and pinch zoom (`opcode = 0x03`, `45` payload bytes).
    case transform3D(
        phase: GesturePhase,
        pivotLocal: SIMD3<Float>,
        translationLocal: SIMD3<Float>,
        rotation: SIMD4<Float>,
        scale: Float
    )
    /// Eye or pointer ray hover update (`opcode = 0x04`, `28` payload bytes).
    case rayHover(
        target: TargetId,
        originLocal: SIMD3<Float>,
        directionLocal: SIMD3<Float>
    )
    /// Discrete bezel or controller key transition (`opcode = 0x05`, `3` payload bytes).
    case discreteKey(keyId: UInt16, state: KeyState)
    /// Temporal scrub offset in seconds (`opcode = 0x06`, `8` payload bytes).
    case scrubTime(offsetSeconds: Double)
    /// Resets the local view pose to its canonical home state (`opcode = 0x07`, `0` payload bytes).
    case resetView
    /// Forward-compatible unrecognized event opcode.
    case unknown(UInt8)
}

/// Errors raised when encoding, decoding, or applying spatial interaction packets.
public enum SpatialInteractionError: Error, Equatable, Sendable {
    case badVersion(UInt8)
    case truncated
    case frameTooLarge(bytes: Int)
    case trailingBytes(Int)
    case badPayload(opcode: UInt8)
    case cannotEncodeUnknownOpcode(UInt8)
    case reservedFlags(UInt8)
    case reservedBytesNonZero
    case invalidViewPose
    case invalidViewLimits
}

private enum InteractionOpcode {
    static let activate: UInt8 = 0x01
    static let drag3D: UInt8 = 0x02
    static let transform3D: UInt8 = 0x03
    static let rayHover: UInt8 = 0x04
    static let discreteKey: UInt8 = 0x05
    static let scrubTime: UInt8 = 0x06
    static let resetView: UInt8 = 0x07
}

/// Stamped spatial interaction packet (`INTERACTION_FORMAT_VERSION = 1`).
///
/// Wire layout (`20 + payloadLen` bytes):
/// `[version=1: u8][opcode: u8][payloadLen: u16 LE][deviceId: u32 LE][sequence: u32 LE][timestampUs: u64 LE][payload]`.
public struct InteractionFrame: Equatable, Sendable {
    /// Device stamp for ordering and audit logs.
    public var stamp: InteractionStamp
    /// Spatial event payload.
    public var event: SpatialEvent

    public init(stamp: InteractionStamp, event: SpatialEvent) {
        self.stamp = stamp
        self.event = event
    }

    /// Encodes this interaction frame into its little-endian wire bytes.
    public func encode() throws(SpatialInteractionError) -> [UInt8] {
        let (opcode, payload) = try encodeEvent(event)
        let totalBytes = 20 + payload.count
        guard totalBytes <= maxInteractionBytes else {
            throw SpatialInteractionError.frameTooLarge(bytes: totalBytes)
        }
        var out: [UInt8] = []
        out.reserveCapacity(totalBytes)
        out.append(interactionFormatVersion)
        out.append(opcode)
        out.appendUInt16LE(UInt16(payload.count))
        out.appendUInt32LE(stamp.deviceId)
        out.appendUInt32LE(stamp.sequence)
        out.appendUInt64LE(stamp.timestampUs)
        out.append(contentsOf: payload)
        return out
    }

    /// Decodes an ``InteractionFrame`` from its little-endian wire bytes.
    public static func decode(
        _ bytes: [UInt8]
    ) throws(SpatialInteractionError) -> InteractionFrame {
        guard let version = bytes.first else {
            throw SpatialInteractionError.truncated
        }
        guard version == interactionFormatVersion else {
            throw SpatialInteractionError.badVersion(version)
        }
        guard bytes.count >= 20 else {
            throw SpatialInteractionError.truncated
        }
        let opcode = bytes[1]
        let payloadLen = Int(bytes.unsigned16(at: 2))
        let expectedTotal = 20 + payloadLen
        guard expectedTotal <= maxInteractionBytes else {
            throw SpatialInteractionError.frameTooLarge(bytes: expectedTotal)
        }
        guard bytes.count >= expectedTotal else {
            throw SpatialInteractionError.truncated
        }
        guard bytes.count == expectedTotal else {
            throw SpatialInteractionError.trailingBytes(bytes.count - expectedTotal)
        }
        let stamp = InteractionStamp(
            deviceId: bytes.unsigned32(at: 4),
            sequence: bytes.unsigned32(at: 8),
            timestampUs: bytes.unsigned64(at: 12)
        )
        let event = try decodeEvent(opcode: opcode, bytes: bytes, at: 20, length: payloadLen)
        return InteractionFrame(stamp: stamp, event: event)
    }

    private func encodeEvent(
        _ event: SpatialEvent
    ) throws(SpatialInteractionError) -> (opcode: UInt8, payload: [UInt8]) {
        var payload: [UInt8] = []
        switch event {
        case let .activate(target, pointLocal):
            guard isFiniteSIMD3(pointLocal) else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.activate)
            }
            payload.reserveCapacity(16)
            payload.appendUInt32LE(target.rawValue)
            payload.appendSIMD3LE(pointLocal)
            return (InteractionOpcode.activate, payload)
        case let .drag3D(phase, target, originLocal, deltaLocal):
            guard isFiniteSIMD3(originLocal), isFiniteSIMD3(deltaLocal) else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.drag3D)
            }
            payload.reserveCapacity(29)
            payload.append(phase.rawValue)
            payload.appendUInt32LE(target.rawValue)
            payload.appendSIMD3LE(originLocal)
            payload.appendSIMD3LE(deltaLocal)
            return (InteractionOpcode.drag3D, payload)
        case let .transform3D(phase, pivotLocal, translationLocal, rotation, scale):
            guard isFiniteSIMD3(pivotLocal), isFiniteSIMD3(translationLocal),
                  isUnitSIMD4(rotation), scale.isFinite, scale > 0 else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.transform3D)
            }
            payload.reserveCapacity(45)
            payload.append(phase.rawValue)
            payload.appendSIMD3LE(pivotLocal)
            payload.appendSIMD3LE(translationLocal)
            payload.appendSIMD4LE(rotation)
            payload.appendFloat32LE(scale)
            return (InteractionOpcode.transform3D, payload)
        case let .rayHover(target, originLocal, directionLocal):
            guard isFiniteSIMD3(originLocal), isUnitSIMD3(directionLocal) else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.rayHover)
            }
            payload.reserveCapacity(28)
            payload.appendUInt32LE(target.rawValue)
            payload.appendSIMD3LE(originLocal)
            payload.appendSIMD3LE(directionLocal)
            return (InteractionOpcode.rayHover, payload)
        case let .discreteKey(keyId, state):
            payload.reserveCapacity(3)
            payload.appendUInt16LE(keyId)
            payload.append(state.rawValue)
            return (InteractionOpcode.discreteKey, payload)
        case let .scrubTime(offsetSeconds):
            guard offsetSeconds.isFinite else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.scrubTime)
            }
            payload.reserveCapacity(8)
            payload.appendFloat64LE(offsetSeconds)
            return (InteractionOpcode.scrubTime, payload)
        case .resetView:
            return (InteractionOpcode.resetView, [])
        case let .unknown(opcode):
            throw SpatialInteractionError.cannotEncodeUnknownOpcode(opcode)
        }
    }

    private static func decodeEvent(
        opcode: UInt8,
        bytes: [UInt8],
        at payload: Int,
        length: Int
    ) throws(SpatialInteractionError) -> SpatialEvent {
        switch opcode {
        case InteractionOpcode.activate:
            guard length == 16 else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            let target = TargetId(rawValue: bytes.unsigned32(at: payload))
            let point = bytes.simd3(at: payload + 4)
            guard isFiniteSIMD3(point) else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            return .activate(target: target, pointLocal: point)
        case InteractionOpcode.drag3D:
            guard length == 29,
                  let phase = GesturePhase(rawValue: bytes[payload]) else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            let target = TargetId(rawValue: bytes.unsigned32(at: payload + 1))
            let origin = bytes.simd3(at: payload + 5)
            let delta = bytes.simd3(at: payload + 17)
            guard isFiniteSIMD3(origin), isFiniteSIMD3(delta) else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            return .drag3D(
                phase: phase,
                target: target,
                originLocal: origin,
                deltaLocal: delta
            )
        case InteractionOpcode.transform3D:
            guard length == 45,
                  let phase = GesturePhase(rawValue: bytes[payload]) else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            let pivot = bytes.simd3(at: payload + 1)
            let translation = bytes.simd3(at: payload + 13)
            let rotation = bytes.simd4(at: payload + 25)
            let scale = bytes.float32(at: payload + 41)
            guard isFiniteSIMD3(pivot), isFiniteSIMD3(translation),
                  isUnitSIMD4(rotation), scale.isFinite, scale > 0 else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            return .transform3D(
                phase: phase,
                pivotLocal: pivot,
                translationLocal: translation,
                rotation: rotation,
                scale: scale
            )
        case InteractionOpcode.rayHover:
            guard length == 28 else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            let target = TargetId(rawValue: bytes.unsigned32(at: payload))
            let origin = bytes.simd3(at: payload + 4)
            let direction = bytes.simd3(at: payload + 16)
            guard isFiniteSIMD3(origin), isUnitSIMD3(direction) else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            return .rayHover(
                target: target,
                originLocal: origin,
                directionLocal: direction
            )
        case InteractionOpcode.discreteKey:
            guard length == 3,
                  let state = KeyState(rawValue: bytes[payload + 2]) else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            return .discreteKey(keyId: bytes.unsigned16(at: payload), state: state)
        case InteractionOpcode.scrubTime:
            guard length == 8 else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            let offset = bytes.float64(at: payload)
            guard offset.isFinite else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            return .scrubTime(offsetSeconds: offset)
        case InteractionOpcode.resetView:
            guard length == 0 else {
                throw SpatialInteractionError.badPayload(opcode: opcode)
            }
            return .resetView
        default:
            return .unknown(opcode)
        }
    }
}

/// Local 3D camera, focus, zoom, selection, and time-scrub pose (`VIEW_POSE_BYTES = 48`).
public struct ViewPose3D: Equatable, Sendable {
    /// Local focus offset in meters.
    public var focusLocal: SIMD3<Float>
    /// Unit quaternion orientation (`x, y, z, w`).
    public var orientation: SIMD4<Float>
    /// Positive zoom scale factor (`1.0` = nominal).
    public var zoomScale: Float
    /// Currently hovered or active target handle.
    public var activeTarget: TargetId
    /// Temporal scrub offset in seconds (`0.0` = live).
    public var timeOffsetSeconds: Double
    /// Declutter flag controlling droppable bands.
    public var decluttered: Bool

    public init(
        focusLocal: SIMD3<Float> = .zero,
        orientation: SIMD4<Float> = SIMD4(0, 0, 0, 1),
        zoomScale: Float = 1.0,
        activeTarget: TargetId = .none,
        timeOffsetSeconds: Double = 0.0,
        decluttered: Bool = false
    ) {
        self.focusLocal = focusLocal
        self.orientation = orientation
        self.zoomScale = zoomScale
        self.activeTarget = activeTarget
        self.timeOffsetSeconds = timeOffsetSeconds
        self.decluttered = decluttered
    }

    /// Encodes this pose into its fixed 48-byte little-endian wire layout.
    public func encode() throws(SpatialInteractionError) -> [UInt8] {
        guard isFiniteSIMD3(focusLocal),
              isUnitSIMD4(orientation),
              zoomScale.isFinite, zoomScale > 0,
              timeOffsetSeconds.isFinite else {
            throw SpatialInteractionError.invalidViewPose
        }
        var out: [UInt8] = []
        out.reserveCapacity(viewPoseBytes)
        out.append(viewPoseVersion)
        out.append(decluttered ? 0x01 : 0x00)
        out.append(0)
        out.append(0)
        out.appendSIMD3LE(focusLocal)
        out.appendSIMD4LE(orientation)
        out.appendFloat32LE(zoomScale)
        out.appendUInt32LE(activeTarget.rawValue)
        out.appendFloat64LE(timeOffsetSeconds)
        return out
    }

    /// Decodes a ``ViewPose3D`` from a 48-byte wire buffer.
    public static func decode(
        _ bytes: [UInt8]
    ) throws(SpatialInteractionError) -> ViewPose3D {
        guard let version = bytes.first else {
            throw SpatialInteractionError.truncated
        }
        guard version == viewPoseVersion else {
            throw SpatialInteractionError.badVersion(version)
        }
        guard bytes.count >= viewPoseBytes else {
            throw SpatialInteractionError.truncated
        }
        guard bytes.count == viewPoseBytes else {
            throw SpatialInteractionError.trailingBytes(bytes.count - viewPoseBytes)
        }
        let flags = bytes[1]
        guard (flags & ~0x01) == 0 else {
            throw SpatialInteractionError.reservedFlags(flags)
        }
        guard bytes[2] == 0, bytes[3] == 0 else {
            throw SpatialInteractionError.reservedBytesNonZero
        }
        let focus = bytes.simd3(at: 4)
        let orientation = bytes.simd4(at: 16)
        let zoom = bytes.float32(at: 32)
        let target = TargetId(rawValue: bytes.unsigned32(at: 36))
        let timeOffset = bytes.float64(at: 40)
        guard isFiniteSIMD3(focus),
              isUnitSIMD4(orientation),
              zoom.isFinite, zoom > 0,
              timeOffset.isFinite else {
            throw SpatialInteractionError.invalidViewPose
        }
        return ViewPose3D(
            focusLocal: focus,
            orientation: orientation,
            zoomScale: zoom,
            activeTarget: target,
            timeOffsetSeconds: timeOffset,
            decluttered: (flags & 0x01) != 0
        )
    }
}

/// Bounds governing local pan, orbit, zoom, and time-scrub manipulation.
public struct ViewLimits: Equatable, Sendable {
    /// Maximum per-axis focus offset in meters (`0` disables panning).
    public var panLimit: Float
    /// Minimum allowed ``ViewPose3D/zoomScale``.
    public var zoomMin: Float
    /// Maximum allowed ``ViewPose3D/zoomScale``.
    public var zoomMax: Float
    /// Maximum absolute temporal scrub offset in seconds.
    public var timeScrubLimitSeconds: Double
    /// Enables 3D orbit rotation when `true`.
    public var allowOrbit: Bool
    /// Enables temporal scrubbing when `true`.
    public var allowTimeScrub: Bool

    public init(
        panLimit: Float,
        zoomMin: Float,
        zoomMax: Float,
        timeScrubLimitSeconds: Double,
        allowOrbit: Bool,
        allowTimeScrub: Bool
    ) {
        self.panLimit = panLimit
        self.zoomMin = zoomMin
        self.zoomMax = zoomMax
        self.timeScrubLimitSeconds = timeScrubLimitSeconds
        self.allowOrbit = allowOrbit
        self.allowTimeScrub = allowTimeScrub
    }

    /// Fixed pose limits that forbid pan, orbit, zoom, and time scrub.
    public static let locked = ViewLimits(
        panLimit: 0.0,
        zoomMin: 1.0,
        zoomMax: 1.0,
        timeScrubLimitSeconds: 0.0,
        allowOrbit: false,
        allowTimeScrub: false
    )

    /// Standard limits for interactive 3D volumetric instruments.
    public static let volumetricDefault = ViewLimits(
        panLimit: 1.0,
        zoomMin: 0.25,
        zoomMax: 4.0,
        timeScrubLimitSeconds: 3_600.0,
        allowOrbit: true,
        allowTimeScrub: true
    )

    var isValid: Bool {
        panLimit.isFinite && panLimit >= 0
            && zoomMin.isFinite && zoomMin > 0
            && zoomMax.isFinite && zoomMax >= zoomMin
            && timeScrubLimitSeconds.isFinite && timeScrubLimitSeconds >= 0
    }
}

/// Result of applying a ``SpatialEvent`` to a local ``ViewPose3D``.
public enum InteractionOutcome: Equatable, Sendable {
    /// The local ``ViewPose3D`` changed.
    case viewUpdated
    /// The operator activated a spatial target point or handle.
    case targetActivated(target: TargetId, pointLocal: SIMD3<Float>)
    /// A discrete key state changed.
    case keyInput(keyId: UInt16, state: KeyState)
    /// The event left the local pose unchanged under the active ``ViewLimits``.
    case ignored
}

/// Deterministic zero-latency controller that updates ``ViewPose3D`` from ``SpatialEvent`` inputs.
public enum ViewPoseController {
    /// Applies `event` to `pose` within `limits` and returns the resulting ``InteractionOutcome``.
    public static func apply(
        _ event: SpatialEvent,
        to pose: inout ViewPose3D,
        limits: ViewLimits
    ) throws(SpatialInteractionError) -> InteractionOutcome {
        guard limits.isValid else {
            throw SpatialInteractionError.invalidViewLimits
        }
        guard isFiniteSIMD3(pose.focusLocal),
              isUnitSIMD4(pose.orientation),
              pose.zoomScale.isFinite, pose.zoomScale > 0,
              pose.timeOffsetSeconds.isFinite else {
            throw SpatialInteractionError.invalidViewPose
        }
        switch event {
        case let .activate(target, pointLocal):
            guard isFiniteSIMD3(pointLocal) else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.activate)
            }
            pose.activeTarget = target
            return .targetActivated(target: target, pointLocal: pointLocal)
        case let .drag3D(phase, target, originLocal, deltaLocal):
            guard isFiniteSIMD3(originLocal), isFiniteSIMD3(deltaLocal) else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.drag3D)
            }
            guard phase != .cancelled else {
                return .ignored
            }
            var changed = false
            if target != .none {
                pose.activeTarget = target
                changed = true
            }
            if limits.panLimit > 0 {
                pose.focusLocal = clampFocus(pose.focusLocal + deltaLocal, limit: limits.panLimit)
                changed = true
            }
            return changed ? .viewUpdated : .ignored
        case let .transform3D(phase, pivotLocal, translationLocal, rotation, scale):
            guard isFiniteSIMD3(pivotLocal), isFiniteSIMD3(translationLocal),
                  isUnitSIMD4(rotation), scale.isFinite, scale > 0 else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.transform3D)
            }
            guard phase != .cancelled else {
                return .ignored
            }
            let canZoom = limits.zoomMax > limits.zoomMin
            guard limits.panLimit > 0 || limits.allowOrbit || canZoom else {
                return .ignored
            }
            if limits.panLimit > 0 {
                pose.focusLocal = clampFocus(
                    pose.focusLocal + translationLocal,
                    limit: limits.panLimit
                )
            }
            if limits.allowOrbit {
                pose.orientation = normalizeQuat(hamiltonProduct(rotation, pose.orientation))
            }
            pose.zoomScale = min(max(pose.zoomScale * scale, limits.zoomMin), limits.zoomMax)
            return .viewUpdated
        case let .rayHover(target, originLocal, directionLocal):
            guard isFiniteSIMD3(originLocal), isUnitSIMD3(directionLocal) else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.rayHover)
            }
            pose.activeTarget = target
            return .viewUpdated
        case let .discreteKey(keyId, state):
            return .keyInput(keyId: keyId, state: state)
        case let .scrubTime(offsetSeconds):
            guard offsetSeconds.isFinite else {
                throw SpatialInteractionError.badPayload(opcode: InteractionOpcode.scrubTime)
            }
            guard limits.allowTimeScrub else {
                return .ignored
            }
            let clamped = min(
                max(offsetSeconds, -limits.timeScrubLimitSeconds),
                limits.timeScrubLimitSeconds
            )
            pose.timeOffsetSeconds = clamped
            return .viewUpdated
        case .resetView:
            pose = ViewPose3D(
                zoomScale: min(max(1.0, limits.zoomMin), limits.zoomMax)
            )
            return .viewUpdated
        case .unknown:
            return .ignored
        }
    }

    private static func clampFocus(_ value: SIMD3<Float>, limit: Float) -> SIMD3<Float> {
        SIMD3(
            min(max(value.x, -limit), limit),
            min(max(value.y, -limit), limit),
            min(max(value.z, -limit), limit)
        )
    }

    private static func hamiltonProduct(
        _ lhs: SIMD4<Float>,
        _ rhs: SIMD4<Float>
    ) -> SIMD4<Float> {
        SIMD4(
            lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w,
            lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z
        )
    }

    private static func normalizeQuat(_ q: SIMD4<Float>) -> SIMD4<Float> {
        let normSq = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w
        guard normSq.isFinite, normSq > 0 else {
            return SIMD4(0, 0, 0, 1)
        }
        let inv = 1.0 / normSq.squareRoot()
        return SIMD4(q.x * inv, q.y * inv, q.z * inv, q.w * inv)
    }
}
