import CoreGraphics
import Foundation

struct FailurePageRenderResult: Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let reason: DisplayReason
}

struct FailurePageRenderWorkerSnapshot: Sendable {
    let pixelBuffers: PanelPixelBufferMetrics
}

/// Renders and caches failure pages outside the main actor.
final class FailurePageRenderWorker: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (FailurePageRenderResult) -> Void

    private struct Request: Sendable {
        let sequence: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
        let reason: DisplayReason
        let completion: Completion
    }

    private struct Cache {
        let pixelWidth: Int
        let pixelHeight: Int
        let reason: DisplayReason
        let image: CGImage

        func matches(_ request: Request) -> Bool {
            pixelWidth == request.pixelWidth
                && pixelHeight == request.pixelHeight
                && reason == request.reason
        }
    }

    private struct State {
        var latestSequence: UInt64 = 0
        var pending: Request?
        var isRendering = false
        var isInvalid = false
        var pixelBuffers = PanelPixelBufferMetrics(capacity: 1, resident: 0, allocations: 0)
    }

    private let queue = DispatchQueue(
        label: "IndicateAppleDisplay.FailurePageRenderWorker",
        qos: .userInteractive,
        autoreleaseFrequency: .workItem
    )
    private let lock = NSLock()
    private var state = State()
    private var cache: Cache?
    private var pixelBuffers = PixelBufferPool(capacity: 1)

    func submit(
        pixelWidth: Int,
        pixelHeight: Int,
        reason: DisplayReason,
        completion: @escaping Completion
    ) {
        lock.lock()
        guard !state.isInvalid else {
            lock.unlock()
            return
        }
        state.latestSequence &+= 1
        state.pending = Request(
            sequence: state.latestSequence,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            reason: reason,
            completion: completion
        )
        let mustStart = !state.isRendering
        state.isRendering = true
        lock.unlock()

        if mustStart {
            queue.async { [weak self] in self?.renderPendingPagesBlocking() }
        }
    }

    func discardOutstanding() {
        lock.lock()
        state.latestSequence &+= 1
        state.pending = nil
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        state.isInvalid = true
        state.latestSequence &+= 1
        state.pending = nil
        lock.unlock()
    }

    var snapshot: FailurePageRenderWorkerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return FailurePageRenderWorkerSnapshot(pixelBuffers: state.pixelBuffers)
    }

    private func renderPendingPagesBlocking() {
        while let request = takePending() {
            guard let image = image(for: request) else { continue }
            let result = FailurePageRenderResult(
                image: image,
                pixelWidth: request.pixelWidth,
                pixelHeight: request.pixelHeight,
                reason: request.reason
            )
            guard accept(request) else { continue }
            Task { @MainActor [weak self] in self?.deliver(request, result: result) }
        }
    }

    private func image(for request: Request) -> CGImage? {
        if let cache, cache.matches(request) {
            return cache.image
        }
        guard let image = pixelBuffers.makeFailureImage(
            pixelWidth: request.pixelWidth,
            pixelHeight: request.pixelHeight,
            reason: request.reason
        ) else { return nil }
        cache = Cache(
            pixelWidth: request.pixelWidth,
            pixelHeight: request.pixelHeight,
            reason: request.reason,
            image: image
        )
        return image
    }

    private func takePending() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = state.pending else {
            state.isRendering = false
            return nil
        }
        state.pending = nil
        return request
    }

    private func accept(_ request: Request) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        state.pixelBuffers = pixelBuffers.metrics
        return !state.isInvalid && request.sequence == state.latestSequence
    }

    @MainActor
    private func deliver(_ request: Request, result: FailurePageRenderResult) {
        lock.lock()
        guard !state.isInvalid, request.sequence == state.latestSequence else {
            lock.unlock()
            return
        }
        lock.unlock()
        request.completion(result)
    }
}
