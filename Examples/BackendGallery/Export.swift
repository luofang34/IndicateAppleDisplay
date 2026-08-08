import Foundation
import ImageIO
import IndicateAppleDisplay
import UniformTypeIdentifiers

/// The metadata line one gallery row carries, shared by the manifest and the
/// window so both presentations report the same facts.
func metadata(_ item: GalleryItem) -> String {
    let mask = item.layersPresentMask.map { String(format: "0x%02x", $0) } ?? "-"
    let unknown = item.unknownOpcodes.map(String.init) ?? "-"
    let reason = item.reason == .ok ? "ok" : item.reason.label
    return "\(item.pixelWidth)x\(item.pixelHeight) px"
        + "  \(item.showingFailure ? "covered" : "shown")"
        + "  reason \(reason)"
        + "  layers \(mask)"
        + "  unknown \(unknown)"
}

/// Writes one PNG per case plus a manifest, and verifies every typed outcome.
///
/// This is the CI smoke path: it renders at least one valid and one rejected
/// case and exits non-zero when any actual outcome differs from the expected
/// one. It never draws anything itself — the images come from the gallery
/// cases, which come from `PanelDisplay` and `PanelHealth`.
func exportGallery(
    _ items: [GalleryItem],
    corpus: CorpusFile,
    to directory: String
) throws -> Int32 {
    try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true
    )

    var failures = 0
    var lines: [String] = [
        "IndicateAppleDisplay backend gallery",
        "IR v\(SceneBackend.formatVersion), corpus v\(corpus.corpusVersion)",
        "digest \(corpus.corpusSha256)",
        "",
    ]

    for item in items {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(item.name).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw GalleryError.pngFailed(item.name) }
        CGImageDestinationAddImage(destination, item.image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw GalleryError.pngFailed(item.name)
        }

        let matches = item.showingFailure == item.expectedFailure
            && item.reason == item.expectedReason
            && item.image.width == item.pixelWidth
            && item.image.height == item.pixelHeight
        if !matches { failures += 1 }
        let line = "\(item.name).png  \(metadata(item))  \(matches ? "PASS" : "FAIL")"
        lines.append(line)
        print(line)
    }

    lines.append("")
    lines.append(failures == 0 ? "all \(items.count) cases match" : "\(failures) case(s) mismatch")
    try lines.joined(separator: "\n").write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("manifest.txt"),
        atomically: true,
        encoding: .utf8
    )

    return failures == 0 ? 0 : 1
}
