import Foundation

/// Ordered criticality bands for a 3D volumetric scene (`VOLUME_SCENE_VERSION = 1`).
///
/// The raw value defines both the wire identifier and the criticality order.
/// Higher values carry higher operational criticality. Only ``referenceGrid``
/// is droppable during display declutter.
public enum VolumeBand: UInt8, CaseIterable, Sendable, Comparable {
    /// Optional 3D reference grid. A host may drop this band during declutter.
    case referenceGrid = 0
    /// Terrain, planetary, or celestial surface underlay geometry.
    case surfaceUnderlay = 1
    /// Bounded 3D airspace, weather, or hazard volumes.
    case volumes3D = 2
    /// Planned, active, or predicted 3D trajectories.
    case trajectories3D = 3
    /// Discrete 3D vehicle, waypoint, or fix symbols.
    case symbols3D = 4
    /// Camera-facing text billboards drawn from verified glyph vocabulary.
    case billboards = 5
    /// Interactive 3D target handles for spatial selection and manipulation.
    case handles = 6
    /// Source flags, miscompares, and alert annunciations.
    case annunciation = 7
    /// Display-level failure content. No lower band may obscure this band.
    case failure = 8

    /// Indicates whether a host may omit this band when declutter is active.
    public var isDroppable: Bool {
        self == .referenceGrid
    }

    public static func < (lhs: VolumeBand, rhs: VolumeBand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Summary of a validated 3D volumetric scene.
public struct VolumeBandReport: Equatable, Sendable {
    /// Bands present in the scene, in strictly ascending order.
    public let bandsPresent: [VolumeBand]
    /// Command count per band, indexed by ``VolumeBand/rawValue``.
    public let bandCommands: [Int]
    /// Count of unrecognized opcodes outside the reserved `0x50...0x5F` range.
    public let unknownOpcodes: Int

    public init(
        bandsPresent: [VolumeBand],
        bandCommands: [Int],
        unknownOpcodes: Int
    ) {
        self.bandsPresent = bandsPresent
        self.bandCommands = bandCommands
        self.unknownOpcodes = unknownOpcodes
    }

    /// Wire bitmask of present bands, with bit `N` set for band `N`.
    public var presentMask: UInt16 {
        bandsPresent.reduce(0) { $0 | (1 << UInt16($1.rawValue)) }
    }
}

/// Structural or budget errors raised during 3D volumetric band validation.
public enum VolumeSceneLayerError: Error, Equatable, Sendable {
    case decode(VolumeSceneDecodeError)
    case duplicateBand(VolumeBand)
    case outOfOrder(VolumeBand)
    case nestedBand(VolumeBand)
    case endWithoutBegin(VolumeBand)
    case endMismatch(open: VolumeBand, end: VolumeBand)
    case unclosedBand(VolumeBand)
    case unisolatedState(VolumeBand)
    case unbalancedState(VolumeBand)
    case commandOutsideBand
    case stackOverCapacity(band: VolumeBand, depth: Int)
    case overCapacity(VolumeBand)
    case sceneTooLarge(bytes: Int)
    case unknownOpcodeRejected(count: Int)

    /// Shared diagnostic reason code for display failure reporting.
    public var displayReason: DisplayReason {
        switch self {
        case .decode:
            return .sceneFraming
        case .unknownOpcodeRejected:
            return .unknownOpcode
        default:
            return .sceneLayerContract
        }
    }
}
