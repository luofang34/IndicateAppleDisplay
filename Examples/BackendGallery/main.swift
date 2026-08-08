import Foundation
import IndicateAppleDisplay

// The backend gallery: selected conformance-corpus scenes and the display
// host's failure behaviour, rendered by the same policy path a host runs.
//
//   swift run BackendGallery                          show the window
//   swift run BackendGallery --export <directory>     write PNGs + manifest,
//                                                     verify outcomes
//   swift run BackendGallery --corpus <path> ...      read another corpus
//
// Run from the repository root: the default corpus path is relative.

let defaultCorpusPath = "Tests/IndicateAppleDisplayTests/Fixtures/scene-conformance-corpus.json"

func usage() -> Never {
    print("""
    usage: BackendGallery [--corpus <path>] [--export <directory>]
      --corpus <path>        conformance corpus JSON (default: \(defaultCorpusPath))
      --export <directory>   headless mode: write PNGs and a manifest, verify
                             every typed outcome, exit non-zero on a mismatch
      with no arguments:     show the gallery in a window (macOS)
    """)
    exit(2)
}

var corpusPath = defaultCorpusPath
var exportDirectory: String?

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--corpus":
        guard let value = arguments.first else { usage() }
        corpusPath = value
        arguments.removeFirst()
    case "--export":
        guard let value = arguments.first else { usage() }
        exportDirectory = value
        arguments.removeFirst()
    default:
        usage()
    }
}

guard FileManager.default.fileExists(atPath: corpusPath) else {
    print("no corpus at \(corpusPath)")
    print("run from the repository root, or pass --corpus <path>")
    exit(2)
}

do {
    let corpus = try JSONDecoder().decode(
        CorpusFile.self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath))
    )
    // The gallery shows what the backend claims to be verified against, so a
    // corpus that is not that revision is a stop, not a display.
    guard corpus.schemaVersion == SceneBackend.conformanceSchemaVersion,
          corpus.corpusVersion == SceneBackend.conformanceCorpusVersion,
          corpus.corpusSha256 == SceneBackend.conformanceCorpusDigest
    else { throw GalleryError.corpusPinMismatch }

    let items = try galleryItems(corpus: corpus)
    if let exportDirectory {
        exit(try exportGallery(items, corpus: corpus, to: exportDirectory))
    }
    #if os(macOS)
    showGalleryWindow(items, corpus: corpus)
    #else
    print("the window needs macOS; use --export <directory> for the headless path")
    exit(2)
    #endif
} catch {
    print("gallery failed: \(error)")
    exit(1)
}
