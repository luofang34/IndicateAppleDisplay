import CoreGraphics
import Foundation

public extension SceneRenderer {
    /// Renders a scene into an offscreen image sized `pixelWidth` × `pixelHeight`.
    ///
    /// Painting offscreen and returning the finished image is what makes a frame
    /// all-or-nothing: a scene that fails partway through throws and no partial
    /// image is produced, so a broken frame can never reach a display that was
    /// showing a good one.
    ///
    /// This also owns the coordinate convention. The IR is y-down while a
    /// Core Graphics bitmap is y-up, so the flip belongs here rather than in
    /// every caller — a host drawing context may already be y-down, and getting
    /// that wrong silently mirrors the whole panel.
    ///
    /// - Parameters:
    ///   - logicalFrame: the scene-unit region mapped into the image. Content
    ///     is scaled uniformly to fit and centred, so a panel never stretches.
    ///     Pass ``panelDesignFrame`` for the authored framing, or a union with
    ///     ``contentBounds(_:)`` to guarantee nothing is clipped.
    func image(
        _ bytes: [UInt8],
        pixelWidth: Int,
        pixelHeight: Int,
        logicalFrame: CGRect,
        background: CGColor? = nil
    ) throws(SceneRenderError) -> CGImage {
        guard pixelWidth > 0, pixelHeight > 0,
              logicalFrame.width > 0, logicalFrame.height > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: pixelWidth * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw SceneRenderError.contextUnavailable
        }

        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)

        let scale = min(
            CGFloat(pixelWidth) / logicalFrame.width,
            CGFloat(pixelHeight) / logicalFrame.height
        )
        context.translateBy(
            x: (CGFloat(pixelWidth) - logicalFrame.width * scale) / 2,
            y: (CGFloat(pixelHeight) - logicalFrame.height * scale) / 2
        )
        context.scaleBy(x: scale, y: scale)
        // Map the requested region, not just a box at the origin, so a caller
        // can show content a panel paints outside its design frame.
        context.translateBy(x: -logicalFrame.minX, y: -logicalFrame.minY)

        _ = try render(bytes, into: context)
        guard let image = context.makeImage() else {
            throw SceneRenderError.contextUnavailable
        }
        return image
    }
}
