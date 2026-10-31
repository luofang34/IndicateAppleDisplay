import Foundation

/// Commands decoded inside one validated ``VolumeBand``.
public struct VolumeBandSlice: Equatable, Sendable {
    /// Band identity.
    public let band: VolumeBand
    /// Commands enclosed between `beginBand` and `endBand`, including the outer `save` and `restore`.
    public let commands: [VolumeSceneCommand]

    public init(band: VolumeBand, commands: [VolumeSceneCommand]) {
        self.band = band
        self.commands = commands
    }
}

/// Validates the 3D volumetric band, envelope, stack, and capacity contract.
///
/// A volumetric scene must fit within ``VolumeSceneBackend/maxSceneBytes``, open
/// ``VolumeBand`` blocks in strictly ascending non-duplicate order without nesting,
/// enclose every band in an outer `save`/`restore` state-isolation envelope, keep
/// stack depth at or below ``VolumeSceneBackend/maxStackDepth``, and emit zero
/// commands outside bands.
public enum VolumeSceneValidator {
    /// Validates `bytes` and returns a ``VolumeBandReport``.
    ///
    /// By default (`unknownOpcodes == .failFrame`), any unrecognized opcode fails
    /// the frame with ``VolumeSceneLayerError/unknownOpcodeRejected(count:)``.
    public static func validate(
        _ bytes: [UInt8],
        unknownOpcodes: UnknownOpcodePolicy = .failFrame
    ) throws(VolumeSceneLayerError) -> VolumeBandReport {
        try validateAndGroup(bytes, unknownOpcodes: unknownOpcodes).report
    }

    /// Validates `bytes` and returns both the report and the per-band command slices.
    public static func validateAndGroup(
        _ bytes: [UInt8],
        unknownOpcodes: UnknownOpcodePolicy = .failFrame
    ) throws(VolumeSceneLayerError) -> (report: VolumeBandReport, bands: [VolumeBandSlice]) {
        guard bytes.count <= VolumeSceneBackend.maxSceneBytes else {
            throw VolumeSceneLayerError.sceneTooLarge(bytes: bytes.count)
        }
        var walk = VolumeWalk()
        var decoder: VolumeSceneDecoder
        do {
            decoder = try VolumeSceneDecoder(bytes)
        } catch {
            throw VolumeSceneLayerError.decode(error)
        }
        while true {
            let command: VolumeSceneCommand?
            do {
                command = try decoder.next()
            } catch {
                throw VolumeSceneLayerError.decode(error)
            }
            guard let command else { break }
            try walk.accept(command)
        }
        return try walk.finish(unknownOpcodes: unknownOpcodes)
    }
}

private struct VolumeWalk {
    private enum Isolation {
        case awaitingSave
        case active
        case closed
    }

    private struct OpenBand {
        let id: VolumeBand
        var depth = 0
        var isolation = Isolation.awaitingSave
        var commands: [VolumeSceneCommand] = []
    }

    private var open: OpenBand?
    private var lastOpened: VolumeBand?
    private var present: [VolumeBand] = []
    private var slices: [VolumeBandSlice] = []
    private var commandCounts = [Int](repeating: 0, count: VolumeBand.allCases.count)
    private var unknownCount = 0

    mutating func accept(_ command: VolumeSceneCommand) throws(VolumeSceneLayerError) {
        switch command {
        case let .beginBand(band):
            try openBand(band)
        case let .endBand(band):
            try closeBand(band)
        default:
            guard open != nil else {
                throw VolumeSceneLayerError.commandOutsideBand
            }
            try record(command)
        }
    }

    mutating func finish(
        unknownOpcodes: UnknownOpcodePolicy
    ) throws(VolumeSceneLayerError) -> (report: VolumeBandReport, bands: [VolumeBandSlice]) {
        if let open {
            throw VolumeSceneLayerError.unclosedBand(open.id)
        }
        if unknownCount > 0, unknownOpcodes == .failFrame {
            throw VolumeSceneLayerError.unknownOpcodeRejected(count: unknownCount)
        }
        let report = VolumeBandReport(
            bandsPresent: present,
            bandCommands: commandCounts,
            unknownOpcodes: unknownCount
        )
        return (report, slices)
    }

    private mutating func openBand(_ band: VolumeBand) throws(VolumeSceneLayerError) {
        if open != nil {
            throw VolumeSceneLayerError.nestedBand(band)
        }
        if present.contains(band) {
            throw VolumeSceneLayerError.duplicateBand(band)
        }
        if let lastOpened, band <= lastOpened {
            throw VolumeSceneLayerError.outOfOrder(band)
        }
        lastOpened = band
        open = OpenBand(id: band)
    }

    private mutating func closeBand(_ band: VolumeBand) throws(VolumeSceneLayerError) {
        guard let inside = open else {
            throw VolumeSceneLayerError.endWithoutBegin(band)
        }
        guard inside.id == band else {
            throw VolumeSceneLayerError.endMismatch(open: inside.id, end: band)
        }
        guard inside.isolation == .closed, inside.depth == 0 else {
            throw VolumeSceneLayerError.unbalancedState(inside.id)
        }
        open = nil
        present.append(band)
        slices.append(VolumeBandSlice(band: band, commands: inside.commands))
    }

    private mutating func record(_ command: VolumeSceneCommand) throws(VolumeSceneLayerError) {
        guard var inside = open else {
            throw VolumeSceneLayerError.commandOutsideBand
        }
        switch command {
        case .save:
            if inside.isolation == .closed {
                throw VolumeSceneLayerError.unisolatedState(inside.id)
            }
            let depth = inside.depth + 1
            guard depth <= VolumeSceneBackend.maxStackDepth else {
                throw VolumeSceneLayerError.stackOverCapacity(band: inside.id, depth: depth)
            }
            inside.depth = depth
            inside.isolation = .active
        case .restore:
            guard inside.isolation == .active, inside.depth > 0 else {
                throw VolumeSceneLayerError.unbalancedState(inside.id)
            }
            inside.depth -= 1
            if inside.depth == 0 {
                inside.isolation = .closed
            }
        default:
            guard inside.isolation == .active else {
                throw VolumeSceneLayerError.unisolatedState(inside.id)
            }
        }
        let bandIndex = Int(inside.id.rawValue)
        guard commandCounts[bandIndex] < VolumeSceneBackend.maxBandCommands else {
            throw VolumeSceneLayerError.overCapacity(inside.id)
        }
        commandCounts[bandIndex] &+= 1
        inside.commands.append(command)
        open = inside
        if case .unknown = command {
            unknownCount &+= 1
        }
    }
}
