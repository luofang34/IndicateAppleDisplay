import CoreGraphics
import Foundation

/// What a backend does with an opcode this revision does not know.
public enum UnknownOpcodePolicy: Equatable, Sendable {
    /// Fail the frame. Painting a scene with commands this backend silently
    /// dropped can bleed a layer that must never show through — a dropped clip
    /// or tape backdrop is invisible as a fault but visible as wrong content —
    /// so an operational display fails closed.
    case failFrame
    /// Count and skip, and paint the rest.
    ///
    /// This is the version-policy behaviour the decoder and the layer gate
    /// always implement, exposed here for tools that inspect scenes from a
    /// newer producer. A display showing flight information should not use it.
    case countAndSkip
}

/// What one panel needs before its frame may become visible.
///
/// A panel is described, not enumerated. Adding a panel — a replacement PFD, a
/// moving map, a third-party plugin — is a new descriptor from the producer,
/// not a new case in this package. That is the property that lets one backend
/// serve a panel set it was compiled before.
public struct PanelRequirements: Equatable, Sendable {
    /// Stable identity, as the producer names it.
    public let id: String
    /// Human-readable name for a picker or a report.
    public let title: String
    /// Layers whose absence fails the frame.
    ///
    /// The layer gate accepts any legal ascending subset because different
    /// panel types use different bands. Which subset is *sufficient* is a
    /// property of the panel, so the host must check it before visible commit:
    /// a PFD whose attitude band is missing is not a sparse PFD, it is a
    /// broken one.
    public let criticalLayers: Set<SceneLayer>
    /// The scene-unit region the panel is authored in.
    ///
    /// This comes from the producer rather than being a constant here. A
    /// backend that hard-codes one producer's design size cannot serve a
    /// second panel family without being edited.
    public let designFrame: CGRect
    /// What to do with an opcode this revision does not know.
    public let unknownOpcodes: UnknownOpcodePolicy

    public init(
        id: String,
        title: String,
        criticalLayers: Set<SceneLayer>,
        designFrame: CGRect,
        unknownOpcodes: UnknownOpcodePolicy = .failFrame
    ) {
        self.id = id
        self.title = title
        self.criticalLayers = criticalLayers
        self.designFrame = designFrame
        self.unknownOpcodes = unknownOpcodes
    }

    /// Builds requirements from the wire mask a producer reports, one bit per
    /// layer id. An unknown bit is rejected: a criticality this backend cannot
    /// place must not be silently treated as satisfied.
    public init?(
        id: String,
        title: String,
        criticalLayerMask: UInt8,
        designWidth: Float,
        designHeight: Float,
        unknownOpcodes: UnknownOpcodePolicy = .failFrame
    ) {
        var layers: Set<SceneLayer> = []
        for bit in 0..<8 where criticalLayerMask & (1 << bit) != 0 {
            guard let layer = SceneLayer(rawValue: UInt8(bit)) else { return nil }
            layers.insert(layer)
        }
        guard designWidth > 0, designHeight > 0,
              designWidth.isFinite, designHeight.isFinite else { return nil }
        self.init(
            id: id,
            title: title,
            criticalLayers: layers,
            designFrame: CGRect(
                x: 0, y: 0,
                width: CGFloat(designWidth), height: CGFloat(designHeight)
            ),
            unknownOpcodes: unknownOpcodes
        )
    }
}

public extension SceneLayerReport {
    /// Layers the panel declares critical that this scene does not carry.
    func missingCriticalLayers(_ requirements: PanelRequirements) -> Set<SceneLayer> {
        requirements.criticalLayers.subtracting(layersPresent)
    }

    /// Whether this scene satisfies the panel's contract for visible commit.
    func satisfies(_ requirements: PanelRequirements) -> Bool {
        guard missingCriticalLayers(requirements).isEmpty else { return false }
        return unknownOpcodes == 0 || requirements.unknownOpcodes == .countAndSkip
    }

    /// Why this scene may not be committed, or `nil` when it may.
    func rejection(_ requirements: PanelRequirements) -> DisplayReason? {
        if !missingCriticalLayers(requirements).isEmpty { return .sceneCriticalLayersMissing }
        if unknownOpcodes > 0, requirements.unknownOpcodes == .failFrame { return .unknownOpcode }
        return nil
    }
}
