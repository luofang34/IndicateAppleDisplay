import CoreGraphics
import Foundation

/// The frame instrument panels are authored in.
public let panelDesignFrame = CGRect(x: 0, y: 0, width: 480, height: 360)

public extension SceneRenderer {
    /// The bounding box of everything a scene paints, in scene units.
    ///
    /// Text is measured through the atlas rather than from its anchor, because a
    /// centred or right-anchored run extends to the left of the point the
    /// command carries. Stroke width is not included: this is geometry, and a
    /// caller wanting visual extent should allow for half a stroke.
    ///
    /// Comparing this with ``panelDesignFrame`` is how a backend detects a panel
    /// painting outside the frame it was authored for — content a fixed-frame
    /// backend would silently clip.
    func contentBounds(_ bytes: [UInt8]) throws(SceneDecodeError) -> CGRect? {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var seen = false

        func note(_ x: CGFloat, _ y: CGFloat) {
            guard x.isFinite, y.isFinite else { return }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            seen = true
        }
        func note(_ x: Float, _ y: Float) { note(CGFloat(x), CGFloat(y)) }

        var decoder = try SceneDecoder(bytes)
        while let command = try decoder.next() {
            switch command {
            case let .line(x1, y1, x2, y2):
                note(x1, y1)
                note(x2, y2)
            case let .polyline(points), let .polygon(_, points):
                for index in 0..<points.count {
                    let point = points[index]
                    note(point.x, point.y)
                }
            case let .rect(_, x, y, width, height):
                note(x, y)
                note(x + width, y + height)
            case let .circle(_, centreX, centreY, radius):
                note(centreX - radius, centreY - radius)
                note(centreX + radius, centreY + radius)
            case let .arc(centreX, centreY, radius, _, _):
                note(centreX - radius, centreY - radius)
                note(centreX + radius, centreY + radius)
            case let .clipRect(x, y, width, height):
                note(x, y)
                note(x + width, y + height)
            case let .text(x, y, size, anchor, bytes):
                let box = textBounds(bytes, x: x, y: y, size: size, anchor: anchor)
                note(box.minX, box.minY)
                note(box.maxX, box.maxY)
            default:
                break
            }
        }
        guard seen else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The box a text run occupies, using the atlas metrics the painter uses.
    private func textBounds(
        _ bytes: [UInt8],
        x: Float,
        y: Float,
        size: Float,
        anchor: Anchor
    ) -> CGRect {
        let count = String(decoding: bytes, as: UTF8.self).unicodeScalars.count
        let size = CGFloat(size)
        // Without an atlas the advance is unknown; the reference pack's ratio is
        // the honest estimate and keeps this usable for bounds reporting.
        let advanceRatio = atlasAdvanceRatio ?? (6.0 / 7.0)
        let width = size * advanceRatio * CGFloat(count)
        var left = CGFloat(x)
        switch anchor.horizontal {
        case .left: break
        case .center: left -= width / 2
        case .right: left -= width
        }
        let top: CGFloat = switch anchor.vertical {
        case .top: CGFloat(y)
        case .middle: CGFloat(y) - size / 2
        case .baseline, .bottom: CGFloat(y) - size
        }
        return CGRect(x: left, y: top, width: width, height: size)
    }
}
