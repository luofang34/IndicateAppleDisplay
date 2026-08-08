import Foundation
import IndicateAppleDisplay

/// A demonstration atlas with the reference pack's cell geometry.
///
/// Every covered glyph is a bordered cell whose interior bits come from the
/// scalar, so distinct characters read as distinct marks. Space is blank. A
/// real consumer injects the producer's verified pack instead; this one exists
/// so the gallery can show glyph-backed text without any external asset.
struct GalleryAtlas: GlyphAtlas {
    let cellWidth = 5
    let cellHeight = 7
    let advance = 6

    func rows(for scalar: UInt32) -> [UInt8]? {
        guard scalar != 0x20 else { return [UInt8](repeating: 0, count: cellHeight) }
        var rows: [UInt8] = [0b11111]
        for row in 1..<(cellHeight - 1) {
            let bit = UInt8((scalar >> UInt32(row - 1)) & 1)
            rows.append(0b10001 | (bit << 1) | (bit << 3))
        }
        rows.append(0b11111)
        return rows
    }
}
