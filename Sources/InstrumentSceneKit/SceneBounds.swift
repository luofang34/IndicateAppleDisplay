import CoreGraphics
import Foundation

/// The frame instrument panels are authored in.
public let panelDesignFrame = CGRect(x: 0, y: 0, width: 480, height: 360)

public extension SceneRenderer {
    /// The bounding box of everything a scene paints, in scene units.
    ///
    /// Coordinates are transformed by the current save/translate/rotate state
    /// before being measured. A rotating compass rose draws in local
    /// coordinates, so measuring the raw arguments would under-report its
    /// extent by exactly the transform that places it.
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
        var transform = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []

        func note(_ x: CGFloat, _ y: CGFloat) {
            guard x.isFinite, y.isFinite else { return }
            let point = CGPoint(x: x, y: y).applying(transform)
            guard point.x.isFinite, point.y.isFinite else { return }
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
            seen = true
        }
        func note(_ x: Float, _ y: Float) { note(CGFloat(x), CGFloat(y)) }
        /// A rotated box is measured by its corners; its axis-aligned bounds
        /// are not preserved by rotation.
        func noteBox(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            note(x, y)
            note(x + width, y)
            note(x, y + height)
            note(x + width, y + height)
        }

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
                noteBox(CGFloat(x), CGFloat(y), CGFloat(width), CGFloat(height))
            case let .circle(_, centreX, centreY, radius),
                 let .arc(centreX, centreY, radius, _, _):
                noteBox(
                    CGFloat(centreX - radius), CGFloat(centreY - radius),
                    CGFloat(radius) * 2, CGFloat(radius) * 2
                )
            case let .clipRect(x, y, width, height):
                noteBox(CGFloat(x), CGFloat(y), CGFloat(width), CGFloat(height))
            case let .text(x, y, size, anchor, bytes):
                let box = textBounds(bytes, x: x, y: y, size: size, anchor: anchor)
                noteBox(box.minX, box.minY, box.width, box.height)
            case .save, .beginLayer:
                stack.append(transform)
            case .restore, .endLayer:
                transform = stack.popLast() ?? .identity
            case let .translate(x, y):
                guard x.isFinite, y.isFinite else { break }
                transform = CGAffineTransform(translationX: CGFloat(x), y: CGFloat(y))
                    .concatenating(transform)
            case let .rotate(radians):
                guard radians.isFinite else { break }
                transform = CGAffineTransform(rotationAngle: CGFloat(radians))
                    .concatenating(transform)
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
