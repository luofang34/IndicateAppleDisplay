import Foundation

/// Physical 3D bounding extent of a volumetric instrument in meters.
public struct Extent3D: Equatable, Sendable {
    /// Width along the local X axis in meters.
    public let widthMeters: Float
    /// Height along the local Y axis in meters.
    public let heightMeters: Float
    /// Depth along the local Z axis in meters.
    public let depthMeters: Float

    public init(widthMeters: Float, heightMeters: Float, depthMeters: Float) {
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.depthMeters = depthMeters
    }

    /// Indicates whether all three dimensions are finite and strictly positive.
    public var isValid: Bool {
        widthMeters.isFinite && widthMeters > 0
            && heightMeters.isFinite && heightMeters > 0
            && depthMeters.isFinite && depthMeters > 0
    }
}

/// Host-rendered surface contract declared by an instrument descriptor.
public enum UnderlayContract: UInt8, CaseIterable, Equatable, Sendable {
    case none = 0
    case opaque = 1
    case map2D = 2
    case conformalSvs3D = 3
    case calibratedVideo = 4
    case combinedXvs = 5
    case volumetricTerrain3D = 6
    case planetaryGlobe3D = 7
    case celestialSystem3D = 8
}

/// Acceptance contract that a 3D volumetric instrument frame must satisfy before commit.
public struct VolumeRequirements: Equatable, Sendable {
    /// Stable instrument identifier.
    public let id: String
    /// Human-readable instrument title.
    public let title: String
    /// Bands whose absence rejects the frame with ``DisplayReason/sceneCriticalLayersMissing``.
    public let requiredBands: Set<VolumeBand>
    /// Minimum accepted 3D volume extent in meters.
    public let extentMin: Extent3D
    /// Maximum accepted 3D volume extent in meters.
    public let extentMax: Extent3D
    /// Canonical 3D volume extent in meters pinned by conformance evidence.
    public let canonicalExtent: Extent3D
    /// Bounds for local pan, orbit, zoom, and time-scrub gestures.
    public let viewLimits: ViewLimits
    /// Declared host underlay contract.
    public let underlay: UnderlayContract
    /// Policy applied when the scene carries an unrecognized opcode.
    public let unknownOpcodes: UnknownOpcodePolicy
    /// Target refresh rate in frames per second.
    public let preferredFramesPerSecond: Int

    public init(
        id: String,
        title: String,
        requiredBands: Set<VolumeBand>,
        extentMin: Extent3D,
        extentMax: Extent3D,
        canonicalExtent: Extent3D,
        viewLimits: ViewLimits = .volumetricDefault,
        underlay: UnderlayContract = .none,
        unknownOpcodes: UnknownOpcodePolicy = .failFrame,
        preferredFramesPerSecond: Int = 90
    ) {
        self.id = id
        self.title = title
        self.requiredBands = requiredBands
        self.extentMin = extentMin
        self.extentMax = extentMax
        self.canonicalExtent = canonicalExtent
        self.viewLimits = viewLimits
        self.underlay = underlay
        self.unknownOpcodes = unknownOpcodes
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }

    /// Initializes requirements from the producer's 16-bit required-band wire mask.
    ///
    /// Returns `nil` if `requiredBandMask` sets an unrecognized band bit, if any
    /// extent is non-positive or outside `extentMin...extentMax`, if `viewLimits`
    /// are invalid, or if `preferredFramesPerSecond <= 0`.
    public init?(
        id: String,
        title: String,
        requiredBandMask: UInt16,
        extentMin: Extent3D,
        extentMax: Extent3D,
        canonicalExtent: Extent3D,
        viewLimits: ViewLimits = .volumetricDefault,
        underlay: UnderlayContract = .none,
        unknownOpcodes: UnknownOpcodePolicy = .failFrame,
        preferredFramesPerSecond: Int = 90
    ) {
        var bands: Set<VolumeBand> = []
        for bit in 0..<16 where (requiredBandMask & (1 << bit)) != 0 {
            guard bit <= Int(UInt8.max),
                  let band = VolumeBand(rawValue: UInt8(bit)) else {
                return nil
            }
            bands.insert(band)
        }
        guard extentMin.isValid, extentMax.isValid, canonicalExtent.isValid,
              canonicalExtent.widthMeters >= extentMin.widthMeters,
              canonicalExtent.heightMeters >= extentMin.heightMeters,
              canonicalExtent.depthMeters >= extentMin.depthMeters,
              canonicalExtent.widthMeters <= extentMax.widthMeters,
              canonicalExtent.heightMeters <= extentMax.heightMeters,
              canonicalExtent.depthMeters <= extentMax.depthMeters,
              viewLimits.isValid,
              preferredFramesPerSecond > 0 else {
            return nil
        }
        self.init(
            id: id,
            title: title,
            requiredBands: bands,
            extentMin: extentMin,
            extentMax: extentMax,
            canonicalExtent: canonicalExtent,
            viewLimits: viewLimits,
            underlay: underlay,
            unknownOpcodes: unknownOpcodes,
            preferredFramesPerSecond: preferredFramesPerSecond
        )
    }

    /// Wire bitmask of ``requiredBands``, with bit `N` set for band `N`.
    public var requiredBandMask: UInt16 {
        requiredBands.reduce(0) { $0 | (1 << UInt16($1.rawValue)) }
    }
}

public extension VolumeBandReport {
    /// Required bands from `requirements` that are missing in this report.
    func missingRequiredBands(_ requirements: VolumeRequirements) -> Set<VolumeBand> {
        requirements.requiredBands.subtracting(bandsPresent)
    }

    /// Indicates whether this report satisfies `requirements` for visible commit.
    func satisfies(_ requirements: VolumeRequirements) -> Bool {
        rejection(requirements) == nil
    }

    /// Diagnostic reason preventing commit under `requirements`, or `nil` when valid.
    func rejection(_ requirements: VolumeRequirements) -> DisplayReason? {
        if !missingRequiredBands(requirements).isEmpty {
            return .sceneCriticalLayersMissing
        }
        if unknownOpcodes > 0, requirements.unknownOpcodes == .failFrame {
            return .unknownOpcode
        }
        return nil
    }
}
