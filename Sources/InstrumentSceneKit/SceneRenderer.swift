import CoreGraphics
import Foundation

/// Supplies glyph geometry for text runs.
///
/// Text paints exclusively from a verified atlas. There is deliberately no
/// system-font fallback: a panel layout is designed against known glyph
/// metrics, and substituting a platform font would silently change what a
/// reading says while still looking plausible.
public protocol GlyphAtlas: Sendable {
    /// Cell width in columns.
    var cellWidth: Int { get }
    /// Cell height in rows. A text command's `size` is this height in scene
    /// units, which is what sets the pixel scale.
    var cellHeight: Int { get }
    /// Horizontal advance in cell columns.
    var advance: Int { get }
    /// Row bitmaps for `scalar`, top to bottom, or `nil` when uncovered.
    ///
    /// Within a row the leftmost column is the highest used bit.
    func rows(for scalar: UInt32) -> [UInt8]?
}

/// Why a frame could not be painted.
public enum SceneRenderError: Error, Equatable, Sendable {
    /// The scene failed the layer contract.
    case layer(SceneLayerError)
    /// The scene carries text but no glyph atlas was supplied.
    case textWithoutAtlas
    /// A glyph in a text run is not in the atlas.
    case missingGlyph(Unicode.Scalar)
    /// A coordinate or paint value is not finite.
    case nonFiniteValue
    /// An offscreen drawing context could not be created.
    case contextUnavailable
}

/// Interprets scene commands onto a Core Graphics context.
///
/// The context must use a y-down coordinate system, matching the IR: a
/// positive rotation is clockwise on screen. Rendering is all-or-nothing —
/// validate, then paint — so a partially painted frame never becomes visible.
public struct SceneRenderer {
    private let atlas: (any GlyphAtlas)?
    private let glyphs: GlyphPathCache?

    public init(atlas: (any GlyphAtlas)? = nil) {
        self.atlas = atlas
        glyphs = atlas.map(GlyphPathCache.init(atlas:))
    }

    /// Glyph advance as a fraction of the text size, when an atlas is set.
    var atlasAdvanceRatio: CGFloat? {
        guard let atlas, atlas.cellHeight > 0 else { return nil }
        return CGFloat(atlas.advance) / CGFloat(atlas.cellHeight)
    }

    /// Validates and paints one scene.
    ///
    /// Paint into an offscreen context and commit only on success; a thrown
    /// error means nothing about the frame is trustworthy.
    @discardableResult
    public func render(
        _ bytes: [UInt8],
        into context: CGContext
    ) throws(SceneRenderError) -> SceneLayerReport {
        let report: SceneLayerReport
        do {
            report = try SceneValidator.validate(bytes)
        } catch {
            throw SceneRenderError.layer(error)
        }
        try paintValidated(bytes, into: context)
        return report
    }

    /// Paints a scene that has already passed ``SceneValidator/validate(_:)``.
    ///
    /// A display host validates once, decides whether the frame may be
    /// committed at all, and only then paints. Re-validating inside the
    /// painter would decode every frame twice for nothing.
    func paintValidated(
        _ bytes: [UInt8],
        into context: CGContext
    ) throws(SceneRenderError) {
        var state = PaintState()
        var decoder: SceneDecoder
        do {
            decoder = try SceneDecoder(bytes)
            while let command = try decoder.next() {
                try paint(command, into: context, state: &state)
            }
        } catch let error as SceneRenderError {
            throw error
        } catch {
            throw SceneRenderError.layer(.decode(.truncated))
        }
    }

    private struct PaintState {
        var fill = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        var stroke = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        var strokeWidth: CGFloat = 1
        var stack: [(fill: CGColor, stroke: CGColor, width: CGFloat)] = []
    }

    private func paint(
        _ command: SceneCommand,
        into context: CGContext,
        state: inout PaintState
    ) throws(SceneRenderError) {
        switch command {
        case .save, .beginLayer:
            context.saveGState()
            state.stack.append((state.fill, state.stroke, state.strokeWidth))
        case .restore, .endLayer:
            context.restoreGState()
            if let previous = state.stack.popLast() {
                state.fill = previous.fill
                state.stroke = previous.stroke
                state.strokeWidth = previous.width
            }
        case let .translate(x, y):
            try finite(x, y)
            context.translateBy(x: CGFloat(x), y: CGFloat(y))
        case let .rotate(radians):
            try finite(radians)
            context.rotate(by: CGFloat(radians))
        case let .fillColor(color):
            state.fill = color.cgColor
        case let .stroke(color, width):
            try finite(width)
            state.stroke = color.cgColor
            state.strokeWidth = CGFloat(width)
        case let .line(x1, y1, x2, y2):
            try finite(x1, y1, x2, y2)
            context.beginPath()
            context.move(to: CGPoint(x: CGFloat(x1), y: CGFloat(y1)))
            context.addLine(to: CGPoint(x: CGFloat(x2), y: CGFloat(y2)))
            strokePath(context, state)
        case let .polyline(points):
            try addPoints(points, to: context, close: false)
            strokePath(context, state)
        case let .polygon(mode, points):
            try addPoints(points, to: context, close: true)
            paintPath(context, state, mode: mode)
        case let .rect(mode, x, y, width, height):
            try finite(x, y, width, height)
            context.beginPath()
            context.addRect(CGRect(
                x: CGFloat(x), y: CGFloat(y),
                width: CGFloat(width), height: CGFloat(height)
            ))
            paintPath(context, state, mode: mode)
        case let .circle(mode, centerX, centerY, radius):
            try finite(centerX, centerY, radius)
            context.beginPath()
            context.addArc(
                center: CGPoint(x: CGFloat(centerX), y: CGFloat(centerY)),
                radius: CGFloat(radius),
                startAngle: 0, endAngle: 2 * .pi, clockwise: false
            )
            paintPath(context, state, mode: mode)
        case let .arc(centerX, centerY, radius, start, sweep):
            try finite(centerX, centerY, radius, start, sweep)
            context.beginPath()
            context.addArc(
                center: CGPoint(x: CGFloat(centerX), y: CGFloat(centerY)),
                radius: CGFloat(radius),
                startAngle: CGFloat(start), endAngle: CGFloat(start + sweep),
                clockwise: false
            )
            strokePath(context, state)
        case let .clipRect(x, y, width, height):
            try finite(x, y, width, height)
            context.clip(to: CGRect(
                x: CGFloat(x), y: CGFloat(y),
                width: CGFloat(width), height: CGFloat(height)
            ))
        case let .text(x, y, size, anchor, bytes):
            try finite(x, y, size)
            try drawText(bytes, x: x, y: y, size: size, anchor: anchor, into: context, state: state)
        case .unknown:
            break
        }
    }

    private func addPoints(
        _ points: PointsRef,
        to context: CGContext,
        close: Bool
    ) throws(SceneRenderError) {
        guard points.count > 0 else { return }
        context.beginPath()
        for index in 0..<points.count {
            let point = points[index]
            try finite(point.x, point.y)
            let location = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
            if index == 0 {
                context.move(to: location)
            } else {
                context.addLine(to: location)
            }
        }
        if close { context.closePath() }
    }

    private func strokePath(_ context: CGContext, _ state: PaintState) {
        context.setStrokeColor(state.stroke)
        context.setLineWidth(state.strokeWidth)
        context.strokePath()
    }

    private func paintPath(_ context: CGContext, _ state: PaintState, mode: PaintMode) {
        switch mode {
        case .fill:
            context.setFillColor(state.fill)
            context.fillPath()
        case .stroke:
            strokePath(context, state)
        case .fillStroke:
            context.setFillColor(state.fill)
            context.setStrokeColor(state.stroke)
            context.setLineWidth(state.strokeWidth)
            context.drawPath(using: .fillStroke)
        }
    }

    /// Paints a text run from the atlas.
    ///
    /// The layout mirrors the browser interpreter exactly so the two backends
    /// agree glyph for glyph: `size` is the cell height, the bitmap sits
    /// entirely above the baseline, and an uncovered character fails the frame
    /// rather than being substituted.
    ///
    /// The whole run accumulates into one path and fills once. Filling each
    /// glyph pixel separately would seam under anti-aliasing at fractional
    /// scales, and at instrument density it is the dominant per-frame cost.
    private func drawText(
        _ bytes: [UInt8],
        x: Float,
        y: Float,
        size: Float,
        anchor: Anchor,
        into context: CGContext,
        state: PaintState
    ) throws(SceneRenderError) {
        guard let atlas, let glyphs else { throw SceneRenderError.textWithoutAtlas }
        let scalars = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        guard !scalars.isEmpty, size > 0, atlas.cellHeight > 0 else { return }

        let size = CGFloat(size)
        let scale = size / CGFloat(atlas.cellHeight)
        let advance = CGFloat(atlas.advance) * scale
        let layout = textOrigin(
            x: x, y: y, size: size,
            width: advance * CGFloat(scalars.count),
            anchor: anchor
        )

        let run = CGMutablePath()
        var pen = layout.left
        for scalar in scalars {
            guard let glyph = glyphs.path(for: scalar.value) else {
                throw SceneRenderError.missingGlyph(scalar)
            }
            run.addPath(glyph, transform: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: pen, y: layout.top)))
            pen += advance
        }
        guard !run.isEmpty else { return }
        context.setFillColor(state.fill)
        context.addPath(run)
        context.fillPath()
    }

    /// Where a run's cell grid starts, given its anchor.
    ///
    /// Vertical: top anchors at y; middle backs off half a cell; baseline and
    /// bottom back off a full cell because the pack has zero descent.
    private func textOrigin(
        x: Float,
        y: Float,
        size: CGFloat,
        width: CGFloat,
        anchor: Anchor
    ) -> (left: CGFloat, top: CGFloat) {
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
        return (left, top)
    }

    private func finite(_ values: Float...) throws(SceneRenderError) {
        for value in values where !value.isFinite {
            throw SceneRenderError.nonFiniteValue
        }
    }
}

extension Rgba8 {
    /// Straight-alpha sRGB color.
    var cgColor: CGColor {
        CGColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}
