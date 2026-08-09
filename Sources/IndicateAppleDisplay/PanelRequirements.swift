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
    /// The smallest scene-unit frame the panel will emit into.
    public let frameMin: CGSize
    /// The largest scene-unit frame the panel will emit into.
    public let frameMax: CGSize
    /// The frame the panel's own evidence is pinned at.
    ///
    /// A producer emits at a frame the host asks for, so the host has to ask
    /// for one. Asking for a canonical frame is what makes a painted frame
    /// comparable with the recorded baselines; anything else is a frame no
    /// artefact describes.
    public let canonicalFrame: CGSize
    /// What to do with an opcode this revision does not know.
    public let unknownOpcodes: UnknownOpcodePolicy
    /// The display refresh rate that this panel requires.
    public let preferredFramesPerSecond: Int

    public init(
        id: String,
        title: String,
        criticalLayers: Set<SceneLayer>,
        frameMin: CGSize,
        frameMax: CGSize,
        canonicalFrame: CGSize,
        unknownOpcodes: UnknownOpcodePolicy = .failFrame,
        preferredFramesPerSecond: Int = 60
    ) {
        self.id = id
        self.title = title
        self.criticalLayers = criticalLayers
        self.frameMin = frameMin
        self.frameMax = frameMax
        self.canonicalFrame = canonicalFrame
        self.unknownOpcodes = unknownOpcodes
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }

    /// The frame to ask the producer for, given the pixels available.
    ///
    /// Returns the canonical frame. Every shipped panel declares
    /// `frameMin == frameMax`, so the range is a single frame and there is
    /// nothing to choose; when a panel offers a real range, the policy that
    /// picks within it belongs here and wants evidence behind it rather than
    /// a guess made now.
    public func frame(fittingPixelSize _: CGSize) -> CGRect {
        CGRect(origin: .zero, size: canonicalFrame)
    }

    /// Builds requirements from the wire mask a producer reports, one bit per
    /// layer id. An unknown bit is rejected: a criticality this backend cannot
    /// place must not be silently treated as satisfied.
    public init?(
        id: String,
        title: String,
        criticalLayerMask: UInt8,
        frameMin: CGSize,
        frameMax: CGSize,
        canonicalFrame: CGSize,
        unknownOpcodes: UnknownOpcodePolicy = .failFrame,
        preferredFramesPerSecond: Int = 60
    ) {
        var layers: Set<SceneLayer> = []
        for bit in 0..<8 where criticalLayerMask & (1 << bit) != 0 {
            guard let layer = SceneLayer(rawValue: UInt8(bit)) else { return nil }
            layers.insert(layer)
        }
        for size in [frameMin, frameMax, canonicalFrame] {
            guard size.width > 0, size.height > 0,
                  size.width.isFinite, size.height.isFinite else { return nil }
        }
        // A canonical frame outside the panel's own accepted range could never
        // be rendered at the frame its evidence describes.
        guard canonicalFrame.width >= frameMin.width,
              canonicalFrame.height >= frameMin.height,
              canonicalFrame.width <= frameMax.width,
              canonicalFrame.height <= frameMax.height,
              preferredFramesPerSecond > 0 else { return nil }
        self.init(
            id: id,
            title: title,
            criticalLayers: layers,
            frameMin: frameMin,
            frameMax: frameMax,
            canonicalFrame: canonicalFrame,
            unknownOpcodes: unknownOpcodes,
            preferredFramesPerSecond: preferredFramesPerSecond
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
