import CoreGraphics
import Foundation

/// Cell-space outlines for atlas glyphs, built once and reused every frame.
///
/// A glyph is a bitmap, and the obvious painter fills one rectangle per lit
/// pixel. At instrument density that is tens of thousands of fills a frame,
/// and it is also visibly wrong: separately anti-aliased pixel rectangles seam
/// against each other at fractional scales. Accumulating a run into one path
/// and filling it once removes both problems, and the outline for a glyph
/// never changes, so it is built on first use and kept.
///
/// A cache instance belongs to one renderer on one thread. Sharing one across
/// concurrently rendering displays is not supported.
final class GlyphPathCache {
    private enum Entry {
        case covered(CGPath)
        case uncovered
    }

    private let atlas: any GlyphAtlas
    private var entries: [UInt32: Entry] = [:]

    init(atlas: any GlyphAtlas) {
        self.atlas = atlas
    }

    /// The glyph's outline in cell coordinates — one unit per pixel, y down,
    /// origin at the cell's top left — or `nil` when the atlas does not cover
    /// the scalar.
    func path(for scalar: UInt32) -> CGPath? {
        if let entry = entries[scalar] {
            if case let .covered(path) = entry { return path }
            return nil
        }
        guard let rows = atlas.rows(for: scalar) else {
            entries[scalar] = .uncovered
            return nil
        }
        let path = build(rows: rows)
        entries[scalar] = .covered(path)
        return path
    }

    /// Emits one rectangle per horizontal run of lit pixels rather than one
    /// per pixel. The filled region is identical — runs are merged only along
    /// a row, and a non-zero fill unions them — while the path stays small
    /// enough to re-add cheaply every frame.
    private func build(rows: [UInt8]) -> CGPath {
        let path = CGMutablePath()
        let width = atlas.cellWidth
        for (row, bits) in rows.enumerated() {
            var column = 0
            while column < width {
                guard lit(bits, column) else {
                    column += 1
                    continue
                }
                var end = column + 1
                while end < width, lit(bits, end) { end += 1 }
                path.addRect(CGRect(
                    x: CGFloat(column), y: CGFloat(row),
                    width: CGFloat(end - column), height: 1
                ))
                column = end
            }
        }
        return path
    }

    /// Within a row the leftmost column is the highest used bit.
    private func lit(_ bits: UInt8, _ column: Int) -> Bool {
        (bits >> (atlas.cellWidth - 1 - column)) & 1 == 1
    }
}
