import Foundation

/// What this painter is, and what it has been checked against.
///
/// A backend that can only report a version number leaves the question an
/// operator actually has — is this painter the one that passed conformance? —
/// unanswerable from the device. These constants are the claim, and the
/// conformance tests assert against them rather than against private copies,
/// so the claim cannot drift from what was verified.
public enum SceneBackend {
    /// Scene IR format version this backend reads.
    public static let formatVersion = sceneFormatVersion

    /// Schema version of the corpus format.
    public static let conformanceSchemaVersion = 2

    /// Version of the reviewed corpus this backend is verified against.
    public static let conformanceCorpusVersion = 4

    /// Digest over the corpus' case bytes, as the corpus records it.
    ///
    /// Pinning this is the point: an upstream regeneration that changes
    /// expected behaviour must fail the conformance tests rather than silently
    /// re-baseline this interpreter against a moved target.
    public static let conformanceCorpusDigest =
        "1fb8e6de2734ff7506843b05869f39d501f0926599636c6110a7e3b0c6e1625e"

    /// A short form for a diagnostics line: format version and corpus pin.
    public static var summary: String {
        "IR v\(formatVersion), corpus v\(conformanceCorpusVersion) "
            + conformanceCorpusDigest.prefix(12)
    }
}
