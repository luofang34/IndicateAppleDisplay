import Foundation

/// Z-ordered criticality bands.
///
/// The raw value is both the wire encoding and the z-order: greater values
/// paint later and carry higher display criticality. The contract exists so
/// optional background imagery can never cover primary flight information,
/// warnings, or failure indications.
public enum SceneLayer: UInt8, CaseIterable, Comparable, Sendable {
    /// Optional imagery only — the single band a compositor may drop.
    case background = 0
    /// Primary attitude symbology.
    case attitude = 1
    /// Tapes and readouts.
    case tapes = 2
    /// Navigation guidance.
    case guidance = 3
    /// Flags, miscompares, and failure annunciations.
    case annunciation = 4
    /// Display-level failure content; nothing may cover it.
    case failure = 5

    public static func < (lhs: SceneLayer, rhs: SceneLayer) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What a validated scene turned out to contain.
public struct SceneLayerReport: Equatable, Sendable {
    /// Layers present, in ascending order.
    public let layersPresent: [SceneLayer]
    /// Command count per layer, indexed by raw layer value.
    public let layerCommands: [Int]
    /// Unknown opcodes counted and skipped.
    public let unknownOpcodes: Int

    /// Present layers as the wire bitmask, one bit per layer id.
    public var presentMask: Int {
        layersPresent.reduce(0) { $0 | (1 << Int($1.rawValue)) }
    }
}

/// Why a scene failed the layer contract. Any of these fails the whole frame
/// before anything becomes visible.
public enum SceneLayerError: Error, Equatable, Sendable {
    case decode(SceneDecodeError)
    case duplicateLayer(SceneLayer)
    case outOfOrder(SceneLayer)
    case nestedLayer(SceneLayer)
    case endWithoutBegin(SceneLayer)
    case endMismatch(open: SceneLayer, end: SceneLayer)
    case unclosedLayer(SceneLayer)
    case unisolatedState(SceneLayer)
    case unbalancedState(SceneLayer)
    case commandOutsideLayer
    case stackOverCapacity(layer: SceneLayer, depth: Int)
    case overCapacity(SceneLayer)
    case sceneTooLarge(bytes: Int)

    /// Stable identifier matching the conformance corpus vocabulary.
    public var conformanceName: String {
        switch self {
        case let .decode(error): "Decode:\(error.conformanceName)"
        case .duplicateLayer: "DuplicateLayer"
        case .outOfOrder: "OutOfOrder"
        case .nestedLayer: "NestedLayer"
        case .endWithoutBegin: "EndWithoutBegin"
        case .endMismatch: "EndMismatch"
        case .unclosedLayer: "UnclosedLayer"
        case .unisolatedState: "UnisolatedState"
        case .unbalancedState: "UnbalancedState"
        case .commandOutsideLayer: "CommandOutsideLayer"
        case .stackOverCapacity: "StackOverCapacity"
        case .overCapacity: "OverCapacity"
        case .sceneTooLarge: "SceneTooLarge"
        }
    }
}
