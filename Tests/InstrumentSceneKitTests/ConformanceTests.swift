import Foundation
import Testing
@testable import InstrumentSceneKit

/// The corpus this backend is verified against.
///
/// Pinning the version and digest is the point: a corpus regeneration that
/// changes expected behavior must fail here rather than silently re-baselining
/// this interpreter against a moved target.
private let expectedSchemaVersion = 2
private let expectedCorpusVersion = 3
private let expectedCorpusSha256 =
    "7130efd29b19c2f0fb4622cefd7357dd4e6c038f70efa27e0adbebc4d03cdc6f"

private struct Corpus: Decodable {
    struct Decode: Decodable {
        let ok: Bool
        let error: String?
    }

    struct Gate: Decodable {
        let verdict: String
        let error: String?
        let unknownOpcodes: Int?
        let layersPresent: Int?
        let layerCommands: [Int]?
    }

    /// Budget cases are too large to inline, so the corpus describes how to
    /// build them instead of carrying their bytes.
    struct Generator: Decodable {
        let kind: String
        let layer: UInt8
        let param: Int
    }

    struct Entry: Decodable {
        let name: String
        let category: String
        let bytesHex: String?
        let generator: Generator?
        let framingValid: Bool
        let decode: Decode
        let gate: Gate?
        let commandTrace: [String]?
    }

    let schemaVersion: Int
    let corpusVersion: Int
    let corpusSha256: String
    let entries: [Entry]
}

private func loadCorpus() throws -> Corpus {
    let url = try #require(Bundle.module.url(
        forResource: "scene-conformance-corpus",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
}

/// Rebuilds a generator-described scene.
///
/// The shapes mirror `pilotage-instrument-scene`'s encoder: a layer marker is
/// always followed by the mandatory envelope save, and closed by the matching
/// restore before the end marker.
private func generated(_ generator: Corpus.Generator) -> [UInt8] {
    let unknownOpcode: UInt8 = 0x7f
    func command(_ opcode: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        let length = UInt16(payload.count)
        return [opcode, UInt8(length & 0xff), UInt8(length >> 8)] + payload
    }
    let save = command(0x01)
    let restore = command(0x02)
    let begin = command(0x50, [generator.layer])
    let end = command(0x51, [generator.layer])

    var scene: [UInt8] = [sceneFormatVersion] + begin + save
    switch generator.kind {
    case "nest_saves":
        scene += Array(repeating: save, count: generator.param).flatMap(\.self)
        // A recognized command at peak depth: the corpus reports no unknown
        // opcodes for this case.
        scene += command(0x10, [0xff, 0xff, 0xff, 0xff])
        scene += Array(repeating: restore, count: generator.param).flatMap(\.self)
    case "repeat_unknown":
        scene += Array(repeating: command(unknownOpcode), count: generator.param).flatMap(\.self)
    case "fill_bytes":
        // Pad one unknown command so the encoded scene is exactly `param` bytes.
        let overhead = scene.count + restore.count + end.count + 3
        scene += command(unknownOpcode, [UInt8](repeating: 0, count: generator.param - overhead))
    default:
        break
    }
    return scene + restore + end
}

private func sceneBytes(_ entry: Corpus.Entry) -> [UInt8] {
    if let hex = entry.bytesHex { return bytes(hex) }
    if let generator = entry.generator { return generated(generator) }
    return []
}

private func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex, hex.index(after: index) < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        if let byte = UInt8(hex[index..<next], radix: 16) { result.append(byte) }
        index = next
    }
    return result
}

@Test
func corpusIsThePinnedRevision() throws {
    let corpus = try loadCorpus()
    #expect(corpus.schemaVersion == expectedSchemaVersion)
    #expect(corpus.corpusVersion == expectedCorpusVersion)
    #expect(corpus.corpusSha256 == expectedCorpusSha256)
    #expect(corpus.entries.count == 42)
}

@Test
func everyCorpusEntryDecodesAsTheCorpusSays() throws {
    let corpus = try loadCorpus()
    for entry in corpus.entries {
        let scene = sceneBytes(entry)
        var decoded: [SceneCommand]?
        do {
            decoded = try SceneDecoder.commands(scene)
        } catch {
            decoded = nil
        }
        #expect(
            (decoded != nil) == entry.decode.ok,
            "\(entry.name): decode ok should be \(entry.decode.ok)"
        )
    }
}

@Test
func everyDecodableEntryProducesTheCanonicalCommandTrace() throws {
    let corpus = try loadCorpus()
    var compared = 0
    for entry in corpus.entries {
        guard entry.decode.ok, let expected = entry.commandTrace else { continue }
        let actual = try SceneTrace.trace(sceneBytes(entry))
        #expect(actual == expected, "\(entry.name): trace mismatch")
        compared += 1
    }
    // A silent drop to zero comparisons would make this test vacuously green.
    #expect(compared >= 30, "expected most entries to carry a trace")
}

@Test
func layerGateAgreesWithTheCorpusVerdict() throws {
    let corpus = try loadCorpus()
    var accepted = 0
    var rejected = 0
    for entry in corpus.entries {
        guard let gate = entry.gate else { continue }
        let scene = sceneBytes(entry)
        do {
            let report = try SceneValidator.validate(scene)
            #expect(gate.verdict == "accept", "\(entry.name): expected \(gate.verdict)")
            if let expected = gate.unknownOpcodes {
                #expect(report.unknownOpcodes == expected, "\(entry.name): unknown opcode count")
            }
            if let expected = gate.layerCommands {
                #expect(report.layerCommands == expected, "\(entry.name): per-layer commands")
            }
            if let expected = gate.layersPresent {
                #expect(report.presentMask == expected, "\(entry.name): present-layer mask")
            }
            accepted += 1
        } catch {
            #expect(gate.verdict == "reject", "\(entry.name): unexpectedly rejected as \(error)")
            if let expected = gate.error {
                #expect(
                    error.conformanceName == expected,
                    "\(entry.name): expected \(expected), got \(error.conformanceName)"
                )
            }
            rejected += 1
        }
    }
    #expect(accepted == 25, "corpus has 25 accepted scenes")
    #expect(rejected == 17, "corpus has 17 rejected scenes")
}

@Test
func unknownOpcodesAreSkippedRatherThanFatal() throws {
    // Version policy: a newer producer's opcode must not break an older backend.
    let scene = bytes("01500100010100007f0200090902000051010001")
    let trace = try SceneTrace.trace(scene)
    #expect(trace == ["50:1", "01", "unknown:127", "02", "51:1"])
    let report = try SceneValidator.validate(scene)
    #expect(report.unknownOpcodes == 1)
}

@Test
func anUnknownLayerIdFailsTheWholeFrame() {
    // Content whose criticality cannot be placed must never be painted, so an
    // unknown layer id is fatal where an unknown opcode is not.
    let scene = bytes("0150010009")
    #expect(throws: (any Error).self) { try SceneValidator.validate(scene) }
}
