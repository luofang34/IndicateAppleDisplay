import Foundation

/// Failures the gallery can hit before or while it renders.
enum GalleryError: Error {
    /// A named entry is absent from the corpus, or carries no inline bytes.
    case missingCorpusEntry(String)
    /// The vendored corpus is not the revision this backend was verified against.
    case corpusPinMismatch
    /// A frame attempt produced no image at all, not even a failure page.
    case noImage(String)
    /// The liveness watchdog did not trip when the case required it.
    case noLivenessTrip
    /// A watchdog tick latched before the deadline the case drives to.
    case earlyLatch(Double)
    /// PNG encoding failed for an exported image.
    case pngFailed(String)
}

/// The slice of the vendored conformance corpus the gallery reads.
///
/// The corpus is the same file the conformance tests pin; the gallery selects
/// entries by name and renders their inline bytes. Generator-described budget
/// entries are not used.
struct CorpusFile: Decodable {
    struct Entry: Decodable {
        struct Gate: Decodable {
            let verdict: String
            let layersPresent: Int?
            let unknownOpcodes: Int?
        }

        let name: String
        let bytesHex: String?
        let gate: Gate?
    }

    let schemaVersion: Int
    let corpusVersion: Int
    let corpusSha256: String
    let entries: [Entry]

    /// The encoded scene bytes of a named entry.
    func bytes(for name: String) throws -> [UInt8] {
        guard let entry = entries.first(where: { $0.name == name }),
              let hex = entry.bytesHex
        else { throw GalleryError.missingCorpusEntry(name) }
        return CorpusFile.decodeHex(hex)
    }

    static func decodeHex(_ text: String) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex, text.index(after: index) < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            if let byte = UInt8(text[index..<next], radix: 16) { result.append(byte) }
            index = next
        }
        return result
    }
}
