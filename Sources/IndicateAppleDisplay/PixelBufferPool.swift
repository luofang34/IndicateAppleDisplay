import CoreGraphics

/// Metrics for the pixel buffers that one display owns.
public struct PanelPixelBufferMetrics: Equatable, Sendable {
    /// The maximum number of resident buffers.
    public let capacity: Int
    /// The number of buffers that are resident now.
    public let resident: Int
    /// The number of buffer allocations since display initialization.
    public let allocations: UInt64
}

/// A bounded set of bitmap contexts for one serial render pipeline.
struct PixelBufferPool {
    private struct Slot {
        let width: Int
        let height: Int
        let context: CGContext
    }

    static let defaultCapacity = 2

    private let capacity: Int
    private var slots: [Slot?]
    private var nextSlot = 0
    private var allocations: UInt64 = 0

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(capacity, 1)
        slots = Array(repeating: nil, count: self.capacity)
    }

    var metrics: PanelPixelBufferMetrics {
        PanelPixelBufferMetrics(
            capacity: capacity,
            resident: slots.compactMap { $0 }.count,
            allocations: allocations
        )
    }

    mutating func makeImage(
        pixelWidth: Int,
        pixelHeight: Int,
        paint: (CGContext) throws(SceneRenderError) -> Void
    ) throws(SceneRenderError) -> CGImage {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw SceneRenderError.contextUnavailable
        }

        let index = nextSlot
        nextSlot = (nextSlot + 1) % capacity
        let context = try context(at: index, width: pixelWidth, height: pixelHeight)

        context.saveGState()
        do throws(SceneRenderError) {
            context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            try paint(context)
            guard let image = context.makeImage() else {
                throw SceneRenderError.contextUnavailable
            }
            context.restoreGState()
            return image
        } catch {
            // A paint error can leave an unknown graphics-state depth.
            // Replacement gives the next frame a known initial state.
            slots[index] = nil
            throw error
        }
    }

    mutating func makeFailureImage(
        pixelWidth: Int,
        pixelHeight: Int,
        reason: DisplayReason
    ) -> CGImage? {
        try? makeImage(pixelWidth: pixelWidth, pixelHeight: pixelHeight) { context in
            FailurePage.draw(
                into: context,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                reason: reason
            )
        }
    }

    private mutating func context(
        at index: Int,
        width: Int,
        height: Int
    ) throws(SceneRenderError) -> CGContext {
        if let slot = slots[index], slot.width == width, slot.height == height {
            return slot.context
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SceneRenderError.contextUnavailable
        }
        slots[index] = Slot(width: width, height: height, context: context)
        allocations &+= 1
        return context
    }
}
