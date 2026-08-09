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
    ///     Pass the producer's design frame — ``PanelRequirements/designFrame``
    ///     — or a union with ``contentBounds(_:)`` to guarantee nothing is
    ///     clipped.
    func image(
        _ bytes: [UInt8],
        pixelWidth: Int,
        pixelHeight: Int,
        logicalFrame: CGRect,
        background: CGColor? = nil
    ) throws(SceneRenderError) -> CGImage {
        do {
            _ = try SceneValidator.validate(bytes)
        } catch {
            throw SceneRenderError.layer(error)
        }
        return try paintedImage(
            bytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            logicalFrame: logicalFrame,
            background: background
        )
    }
}

extension SceneRenderer {
    /// Paints an already-validated scene into an offscreen image.
    ///
    /// Split out so a display host that has validated a frame — and decided,
    /// from the report, whether it may be committed at all — does not pay for
    /// a second decode pass.
    func paintedImage(
        _ bytes: [UInt8],
        pixelWidth: Int,
        pixelHeight: Int,
        logicalFrame: CGRect,
        background: CGColor?
    ) throws(SceneRenderError) -> CGImage {
        var buffers = PixelBufferPool()
        return try paintedImage(
            bytes,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            logicalFrame: logicalFrame,
            background: background,
            buffers: &buffers
        )
    }

    /// Paints into a reusable offscreen pixel buffer.
    func paintedImage(
        _ bytes: [UInt8],
        pixelWidth: Int,
        pixelHeight: Int,
        logicalFrame: CGRect,
        background: CGColor?,
        buffers: inout PixelBufferPool
    ) throws(SceneRenderError) -> CGImage {
        try buffers.makeImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
            (context: CGContext) throws(SceneRenderError) in
            try Self.prepare(
                context,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                logicalFrame: logicalFrame,
                background: background
            )
            try paintValidated(bytes, into: context)
        }
    }

    /// Sets the scene coordinate system on a reusable bitmap context.
    private static func prepare(
        _ context: CGContext,
        pixelWidth: Int,
        pixelHeight: Int,
        logicalFrame: CGRect,
        background: CGColor?
    ) throws(SceneRenderError) {
        guard logicalFrame.width > 0, logicalFrame.height > 0 else {
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
    }
}
