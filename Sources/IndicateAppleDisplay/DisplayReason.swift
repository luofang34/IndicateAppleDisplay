import Foundation

/// Why a display pipeline is showing failure instead of a panel.
///
/// The numbers are a vocabulary shared with every other backend of this scene
/// IR, not a private enumeration: 1–99 mirror the instrument runtime's own
/// render status, 100+ are failures a display backend observes for itself. An
/// operator reads `D-105` off a covered panel and looks it up, so codes are
/// append-only — never reused, never renumbered.
///
/// Every failure this backend can raise maps onto a code that already exists.
/// No Core Graphics-specific number was minted, which is what keeps a fault
/// diagnosed on one backend meaningful on another.
public enum DisplayReason: UInt16, Sendable, CaseIterable {
    /// Not a failure.
    case ok = 0

    // Producer-reported. This package never raises these; a host that drives a
    // scene producer reports them through ``PanelDisplay/reportProducerFailure(_:nowMs:)``.

    /// The scene producer was used before it was initialized.
    case notInitialized = 1
    /// A drawing context could not be created.
    case contextUnavailable = 2
    /// The producer was handed a state block shorter than its ABI.
    case stateTruncated = 3
    /// The state block's version is not one the producer reads.
    case stateBadVersion = 4
    /// No panel is registered under the requested identity.
    case invalidPanel = 5
    /// The scene did not fit the producer's buffer.
    case sceneBufferFull = 6
    /// The producer refused a command that exceeds a per-command limit.
    case sceneCommandLimit = 7
    /// The scene is structurally undecodable.
    case sceneStructure = 8
    /// The scene violates the layer contract.
    case sceneLayerContract = 9
    /// The scene omits a layer this panel declares critical.
    case sceneCriticalLayersMissing = 10

    // Backend-observed.

    /// The producer module could not be loaded.
    case producerLoad = 100
    /// The producer's state ABI version is not the one this host writes.
    case abiMismatch = 101
    /// Producer initialization failed.
    case initFailed = 102
    /// The producer trapped or threw while producing a frame.
    case renderTrap = 103
    /// The scene's framing — version byte, command headers — is malformed.
    case sceneFraming = 104
    /// Painting failed partway. The frame is discarded, never committed.
    case paintFailed = 105
    /// Frame advancement stalled past the liveness deadline.
    case liveness = 106
    /// State could not be written to the producer.
    case stateWriteFailed = 107
    /// The glyph pack is absent, or a run needs a glyph it does not cover.
    case glyphAsset = 108
    /// The scene carries an opcode this backend does not know.
    ///
    /// Painting anyway would silently drop draw commands — a dropped clip or
    /// tape backdrop bleeds layers that must never show through — so the
    /// default policy fails the frame visibly instead. See
    /// ``UnknownOpcodePolicy``.
    case unknownOpcode = 109

    /// The code as an operator reads it off the failure page.
    public var label: String { "D-\(rawValue)" }
}

public extension SceneRenderError {
    /// The shared display code for this paint failure.
    ///
    /// Painting is where an atlas gap surfaces, so a missing glyph is a glyph
    /// asset fault rather than a generic paint failure: the two have different
    /// remedies and an operator should not have to guess which occurred.
    var displayReason: DisplayReason {
        switch self {
        case let .layer(error): error.displayReason
        case .textWithoutAtlas, .missingGlyph: .glyphAsset
        case .nonFiniteValue: .paintFailed
        case .contextUnavailable: .contextUnavailable
        }
    }
}

public extension SceneLayerError {
    /// The shared display code for this contract failure.
    ///
    /// A decode failure is framing; everything else is the layer contract. The
    /// split matters because framing points at a corrupt or truncated
    /// transfer, while a contract failure points at the producer.
    var displayReason: DisplayReason {
        if case .decode = self { return .sceneFraming }
        return .sceneLayerContract
    }
}
