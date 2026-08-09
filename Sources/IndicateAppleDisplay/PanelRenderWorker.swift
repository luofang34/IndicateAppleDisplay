import CoreGraphics
import Foundation

/// Counts work submitted to one panel render worker.
public struct PanelRenderWorkerCounters: Equatable, Sendable {
    /// The number of submitted frame requests.
    public internal(set) var submitted: UInt64 = 0
    /// The number of pending requests replaced by a newer request.
    public internal(set) var coalesced: UInt64 = 0
    /// The number of frame requests that started rendering.
    public internal(set) var started: UInt64 = 0
    /// The number of frame requests that finished rendering.
    public internal(set) var completed: UInt64 = 0
    /// The number of completed frames rejected before delivery.
    public internal(set) var staleCompletions: UInt64 = 0
    /// The number of main-actor delivery tasks that the worker scheduled.
    public internal(set) var deliveryTasksScheduled: UInt64 = 0
}

/// A consistent worker-state sample for diagnostics.
public struct PanelRenderWorkerSnapshot: Equatable, Sendable {
    /// Worker scheduling counters.
    public let counters: PanelRenderWorkerCounters
    /// Whether one frame is rendering now.
    public let isRendering: Bool
    /// Whether the latest-value slot contains a request.
    public let hasPendingFrame: Bool
    /// Whether the bounded delivery slot contains a completed frame.
    public let hasCompletedFrame: Bool
    /// Whether one main-actor delivery task is pending or active.
    public let isDeliveryScheduled: Bool
    /// Pixel-buffer use from the last completed frame.
    public let pixelBuffers: PanelPixelBufferMetrics
}

/// Runs one panel pipeline on a serial queue outside the main actor.
public final class PanelRenderWorker: @unchecked Sendable {
    /// A completed frame callback. The worker always calls it on the main actor.
    public typealias Completion = @MainActor @Sendable (PanelFrameOutcome) -> Void

    private struct Request: Sendable {
        let sequence: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
        let nowMs: Double
        let completion: Completion
    }

    private struct CompletedFrame: Sendable {
        let request: Request
        let outcome: PanelFrameOutcome
    }

    private struct State {
        var latestSequence: UInt64 = 0
        var pending: Request?
        var completedFrame: CompletedFrame?
        var isRendering = false
        var isDeliveryScheduled = false
        var isInvalid = false
        var counters = PanelRenderWorkerCounters()
        var pixelBuffers = PanelPixelBufferMetrics(
            capacity: PixelBufferPool.defaultCapacity,
            resident: 0,
            allocations: 0
        )
    }

    private let display: PanelDisplay
    private let queue: DispatchQueue
    private let lock = NSRecursiveLock()
    private var state = State()

    /// Creates a single-owner worker for `display`.
    public init(display: PanelDisplay) {
        self.display = display
        queue = DispatchQueue(
            label: "IndicateAppleDisplay.PanelRenderWorker.\(display.requirements.id)",
            qos: .userInteractive,
            autoreleaseFrequency: .workItem
        )
    }

    /// Replaces pending work with this frame request.
    ///
    /// The function returns after it updates the bounded latest-value slot.
    /// Scene production and painting occur on the worker queue.
    @discardableResult
    public func submit(
        pixelWidth: Int,
        pixelHeight: Int,
        nowMs: Double,
        completion: @escaping Completion
    ) -> UInt64? {
        lock.lock()
        guard !state.isInvalid else {
            lock.unlock()
            return nil
        }
        state.latestSequence &+= 1
        let request = Request(
            sequence: state.latestSequence,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            nowMs: nowMs,
            completion: completion
        )
        state.counters.submitted &+= 1
        replacePending(with: request)
        rejectCompletedFrame()
        let mustStart = !state.isRendering
        state.isRendering = true
        lock.unlock()

        if mustStart {
            queue.async { [weak self] in self?.renderPendingFramesBlocking() }
        }
        return request.sequence
    }

    /// Rejects pending and completed work that predates this call.
    public func discardOutstanding() {
        lock.lock()
        state.latestSequence &+= 1
        discardPending()
        rejectCompletedFrame()
        lock.unlock()
    }

    /// Stops future submissions and rejects all outstanding results.
    public func invalidate() {
        lock.lock()
        state.isInvalid = true
        state.latestSequence &+= 1
        discardPending()
        rejectCompletedFrame()
        lock.unlock()
    }

    /// Returns a consistent diagnostics sample without waiting for rendering.
    public var snapshot: PanelRenderWorkerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PanelRenderWorkerSnapshot(
            counters: state.counters,
            isRendering: state.isRendering,
            hasPendingFrame: state.pending != nil,
            hasCompletedFrame: state.completedFrame != nil,
            isDeliveryScheduled: state.isDeliveryScheduled,
            pixelBuffers: state.pixelBuffers
        )
    }

    func waitUntilIdleBlocking() {
        queue.sync {}
    }

    private func renderPendingFramesBlocking() {
        while let request = takePending() {
            let start = ContinuousClock.now
            let preparation = display.prepareFrameForWorkerBlocking(
                pixelWidth: request.pixelWidth,
                pixelHeight: request.pixelHeight
            )
            guard let commit = commitIfCurrent(request, preparation, start: start) else {
                continue
            }
            let outcome = display.materializeForWorker(
                commit,
                pixelWidth: request.pixelWidth,
                pixelHeight: request.pixelHeight
            )
            enqueueForDelivery(request, outcome: outcome)
        }
    }

    private func commitIfCurrent(
        _ request: Request,
        _ preparation: PanelFramePreparation,
        start: ContinuousClock.Instant
    ) -> PanelFrameCommit? {
        lock.lock()
        defer { lock.unlock() }
        state.counters.completed &+= 1
        state.pixelBuffers = preparation.pixelBuffers
        guard !state.isInvalid, request.sequence == state.latestSequence else {
            state.counters.staleCompletions &+= 1
            return nil
        }
        let nowMs = request.nowMs + Self.milliseconds(start.duration(to: .now))
        return display.commitHealthForWorker(preparation, nowMs: nowMs)
    }

    private func enqueueForDelivery(_ request: Request, outcome: PanelFrameOutcome) {
        lock.lock()
        state.pixelBuffers = outcome.pixelBuffers
        guard !state.isInvalid, request.sequence == state.latestSequence else {
            state.counters.staleCompletions &+= 1
            lock.unlock()
            return
        }
        rejectCompletedFrame()
        state.completedFrame = CompletedFrame(request: request, outcome: outcome)
        let mustSchedule = !state.isDeliveryScheduled
        state.isDeliveryScheduled = true
        if mustSchedule {
            state.counters.deliveryTasksScheduled &+= 1
        }
        lock.unlock()

        if mustSchedule {
            scheduleDelivery()
        }
    }

    private func scheduleDelivery() {
        Task { @MainActor [weak self] in
            self?.deliverCompletedFrame()
        }
    }

    @MainActor
    private func deliverCompletedFrame() {
        lock.lock()
        guard let frame = state.completedFrame else {
            state.isDeliveryScheduled = false
            lock.unlock()
            return
        }
        state.completedFrame = nil
        guard !state.isInvalid, frame.request.sequence == state.latestSequence else {
            state.counters.staleCompletions &+= 1
            state.isDeliveryScheduled = false
            lock.unlock()
            return
        }
        let didPresent = display.presentIfCurrent(frame.outcome) {
            frame.request.completion(frame.outcome)
        }
        if !didPresent {
            state.counters.staleCompletions &+= 1
        }
        state.isDeliveryScheduled = false
        lock.unlock()
    }

    private func takePending() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = state.pending else {
            state.isRendering = false
            return nil
        }
        state.pending = nil
        state.counters.started &+= 1
        return request
    }

    private func replacePending(with request: Request) {
        if state.pending != nil {
            state.counters.coalesced &+= 1
        }
        state.pending = request
    }

    private func discardPending() {
        if state.pending != nil {
            state.counters.coalesced &+= 1
        }
        state.pending = nil
    }

    private func rejectCompletedFrame() {
        if state.completedFrame != nil {
            state.counters.staleCompletions &+= 1
        }
        state.completedFrame = nil
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private extension PanelFramePreparation {
    var pixelBuffers: PanelPixelBufferMetrics {
        switch self {
        case let .failed(_, pixelBuffers), let .ready(_, _, _, pixelBuffers):
            pixelBuffers
        }
    }
}
