import CoreGraphics
import CoreText
import Foundation

/// The backend's own failure surface, drawn without a scene or a glyph pack.
///
/// This is what covers a panel whose pipeline has failed. It deliberately owes
/// nothing to the instrument path: no scene is produced, no atlas is consulted,
/// and a platform font is used — because the scene producer or the glyph pack
/// may be the failed component, and a failure page that needs them cannot
/// appear exactly when it is needed. Using a system font here is therefore not
/// the substitution ``GlyphAtlas`` forbids: nothing on this page is an
/// instrument reading.
///
/// Distinct from invalid aircraft data, which renders as in-scene red-X and
/// flags through the normal pipeline. This page means the display itself is
/// not to be trusted.
public enum FailurePage {
    /// Nominal design height the reference sizes are quoted against.
    private static let nominalHeight: CGFloat = 360
    private static let titleSize: CGFloat = 28
    private static let codeSize: CGFloat = 16
    private static let borderWidth: CGFloat = 4

    /// Paints the failure page over the whole context.
    ///
    /// The context must be y-up and untransformed — this resets the transform
    /// itself, because the pipeline that set one up is the thing that failed.
    public static func draw(
        into context: CGContext,
        pixelWidth: Int,
        pixelHeight: Int,
        reason: DisplayReason
    ) {
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        context.concatenate(context.ctm.inverted())

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let scale = min(1, min(width, height) / nominalHeight)
        context.setStrokeColor(red)
        context.setLineWidth(borderWidth * scale)
        context.stroke(CGRect(
            x: borderWidth * scale / 2,
            y: borderWidth * scale / 2,
            width: width - borderWidth * scale,
            height: height - borderWidth * scale
        ))

        // A y-up context draws text upright, which is why this page does not
        // reuse the scene path's flip.
        centred(
            "DISPLAY FAIL", size: titleSize * scale, colour: red,
            at: CGPoint(x: width / 2, y: height / 2 + 14 * scale), into: context
        )
        centred(
            reason.label, size: codeSize * scale, colour: red,
            at: CGPoint(x: width / 2, y: height / 2 - 16 * scale), into: context
        )
    }

    /// The failure page as a standalone image, for a host that swaps layer
    /// contents rather than drawing into a live context.
    public static func image(
        pixelWidth: Int,
        pixelHeight: Int,
        reason: DisplayReason
    ) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        draw(into: context, pixelWidth: pixelWidth, pixelHeight: pixelHeight, reason: reason)
        return context.makeImage()
    }

    private static func centred(
        _ text: String,
        size: CGFloat,
        colour: CGColor,
        at point: CGPoint,
        into context: CGContext
    ) {
        guard size > 0 else { return }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: colour,
            ]
        ))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(
            x: point.x - bounds.width / 2,
            y: point.y - bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, context)
    }
}
