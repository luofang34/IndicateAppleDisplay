import CoreGraphics
import Foundation
import Testing
@testable import IndicateAppleDisplay

private let workerScene: [UInt8] = [
    0x01,
    0x50, 0x01, 0x00, 0x01,
    0x01, 0x00, 0x00,
    0x10, 0x04, 0x00, 0xff, 0xff, 0xff, 0xff,
    0x23, 0x11, 0x00, 0x01,
    0x00, 0x00, 0x00, 0x40,
    0x00, 0x00, 0x00, 0x40,
    0x00, 0x00, 0xa0, 0x41,
    0x00, 0x00, 0xa0, 0x41,
    0x02, 0x00, 0x00,
    0x51, 0x01, 0x00, 0x01,
]

private func workerRequirements(rate: Int = 60) -> PanelRequirements {
    let size = CGSize(width: 480, height: 360)
    return PanelRequirements(
        id: "worker-test",
        title: "Worker Test",
        criticalLayers: [.attitude],
        frameMin: size,
        frameMax: size,
        canonicalFrame: size,
        preferredFramesPerSecond: rate
    )
}

private final class GateProducer: SceneProducing, @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private var mustBlock = true
    private var generation: UInt32 = 0
    private var receivedProceed = false
    private var usedMainThread = false
    private let firstFault: DisplayReason?

    init(firstFault: DisplayReason? = nil) {
        self.firstFault = firstFault
    }

    func frame(designFrame _: CGRect) throws -> SceneFrame {
        lock.lock()
        generation &+= 1
        let value = generation
        let block = mustBlock
        mustBlock = false
        usedMainThread = usedMainThread || Thread.isMainThread
        lock.unlock()

        if block {
            started.signal()
            let signalled = proceed.wait(timeout: .now() + .seconds(1)) == .success
            lock.lock()
            receivedProceed = signalled
            lock.unlock()
        }
        if block, let firstFault {
            throw ProducerFault(reason: firstFault)
        }
        return SceneFrame(bytes: workerScene, generation: value)
    }

    func waitUntilStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: self.started.wait(timeout: .now() + .seconds(5)) == .success
                )
            }
        }
    }

    func release() {
        proceed.signal()
    }

    var observations: (receivedProceed: Bool, usedMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (receivedProceed, usedMainThread)
    }
}

private final class BooleanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    func store(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

@MainActor
private final class DeliveryLog {
    private(set) var names: [String] = []

    func append(_ name: String) {
        names.append(name)
    }
}

private func outcomeStream() -> (
    AsyncStream<PanelFrameOutcome>,
    AsyncStream<PanelFrameOutcome>.Continuation
) {
    AsyncStream.makeStream(of: PanelFrameOutcome.self)
}

@Test @MainActor
func aSlowProducerDoesNotBlockTheMainActor() async throws {
    let producer = GateProducer()
    let display = PanelDisplay(requirements: workerRequirements(), producer: producer)
    let worker = PanelRenderWorker(display: display)
    let (stream, continuation) = outcomeStream()

    let sequence = worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 0) { outcome in
        continuation.yield(outcome)
        continuation.finish()
    }
    producer.release()

    var iterator = stream.makeAsyncIterator()
    let outcome = try #require(await iterator.next())
    let observations = producer.observations
    #expect(sequence != nil)
    #expect(observations.receivedProceed)
    #expect(!observations.usedMainThread)
    #expect(!outcome.showingFailure)
}

@Test @MainActor
func theLatestValueSlotCoalescesAndRejectsStaleCompletion() async throws {
    let producer = GateProducer()
    let display = PanelDisplay(requirements: workerRequirements(), producer: producer)
    let worker = PanelRenderWorker(display: display)
    let log = DeliveryLog()

    worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 0) { _ in
        log.append("first")
    }
    #expect(await producer.waitUntilStarted())

    worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 1) { _ in
        log.append("superseded")
    }
    let (stream, continuation) = outcomeStream()
    worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 2) { outcome in
        log.append("latest")
        continuation.yield(outcome)
        continuation.finish()
    }
    producer.release()

    var iterator = stream.makeAsyncIterator()
    let outcome = try #require(await iterator.next())
    let snapshot = worker.snapshot
    #expect(outcome.generation == 2)
    #expect(log.names == ["latest"])
    #expect(snapshot.counters.submitted == 3)
    #expect(snapshot.counters.coalesced == 1)
    #expect(snapshot.counters.started == 2)
    #expect(snapshot.counters.completed == 2)
    #expect(snapshot.counters.staleCompletions == 1)
    #expect(snapshot.pixelBuffers.resident == 2)
    #expect(snapshot.pixelBuffers.allocations == 2)
}

@Test @MainActor
func aStaleFailureCannotLatchPanelHealth() async throws {
    let producer = GateProducer(firstFault: .renderTrap)
    let display = PanelDisplay(requirements: workerRequirements(), producer: producer)
    let worker = PanelRenderWorker(display: display)

    worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 0) { _ in
        Issue.record("The stale frame became visible.")
    }
    #expect(await producer.waitUntilStarted())

    let (stream, continuation) = outcomeStream()
    worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 1) { outcome in
        continuation.yield(outcome)
        continuation.finish()
    }
    producer.release()

    var iterator = stream.makeAsyncIterator()
    let outcome = try #require(await iterator.next())
    #expect(!outcome.showingFailure)
    #expect(outcome.health.counters.failures == 0)
    #expect(display.health.snapshot.counters.failures == 0)
    #expect(worker.snapshot.counters.staleCompletions == 1)
}

@Test
func aHealthTransitionWaitsForAVisibleCommit() {
    let store = PanelHealthStore(PanelHealth())
    let update = store.tickForPresentation(nowMs: 0)
    let probe = BooleanProbe()
    let probeFinished = DispatchSemaphore(value: 0)
    let mutationFinished = DispatchSemaphore(value: 0)

    let didPresent = store.presentIfCurrent(
        epoch: update.presentationEpoch,
        display: update.display
    ) {
        Thread.detachNewThread {
            probe.store(store.presentationLockIsHeldByAnotherThread())
            probeFinished.signal()
            _ = store.reportFailure(nowMs: 1, reason: .renderTrap)
            mutationFinished.signal()
        }
        #expect(probeFinished.wait(timeout: .now() + .seconds(5)) == .success)
    }

    #expect(didPresent)
    #expect(probe.value)
    #expect(mutationFinished.wait(timeout: .now() + .seconds(5)) == .success)
    #expect(store.value().display.reason == .renderTrap)
}

@Test @MainActor
func completedFramesUseOneSlotAndOneDeliveryTask() async throws {
    let display = PanelDisplay(
        requirements: workerRequirements(),
        producer: ClosureSceneProducer { _ in
            SceneFrame(bytes: workerScene, generation: 1)
        }
    )
    let worker = PanelRenderWorker(display: display)

    worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 0) { _ in
        Issue.record("The replaced completed frame became visible.")
    }
    worker.waitUntilIdleBlocking()
    let firstSnapshot = worker.snapshot
    #expect(firstSnapshot.hasCompletedFrame)
    #expect(firstSnapshot.isDeliveryScheduled)
    #expect(firstSnapshot.counters.deliveryTasksScheduled == 1)

    let (stream, continuation) = outcomeStream()
    worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 1) { outcome in
        continuation.yield(outcome)
        continuation.finish()
    }
    worker.waitUntilIdleBlocking()
    let secondSnapshot = worker.snapshot
    #expect(secondSnapshot.hasCompletedFrame)
    #expect(secondSnapshot.isDeliveryScheduled)
    #expect(secondSnapshot.counters.completed == 2)
    #expect(secondSnapshot.counters.staleCompletions == 1)
    #expect(secondSnapshot.counters.deliveryTasksScheduled == 1)

    var iterator = stream.makeAsyncIterator()
    _ = try #require(await iterator.next())
    #expect(!worker.snapshot.hasCompletedFrame)
    #expect(!worker.snapshot.isDeliveryScheduled)
}

@Test @MainActor
func theWatchdogCanLatchWhileTheRenderWorkerIsBusy() async throws {
    let producer = GateProducer()
    let policy = PanelHealthPolicy(
        livenessDeadlineMs: 1000,
        recoveryFrames: 30,
        tickIntervalMs: 250
    )
    let display = PanelDisplay(
        requirements: workerRequirements(),
        producer: producer,
        policy: policy
    )
    let worker = PanelRenderWorker(display: display)
    let (stream, continuation) = outcomeStream()

    worker.submit(pixelWidth: 64, pixelHeight: 64, nowMs: 0) { outcome in
        continuation.yield(outcome)
        continuation.finish()
    }
    #expect(await producer.waitUntilStarted())
    for nowMs in stride(from: 250.0, through: 1000.0, by: 250.0) {
        #expect(!display.tick(nowMs: nowMs).showFailure)
    }
    #expect(display.tick(nowMs: 1250).reason == .liveness)
    producer.release()

    var iterator = stream.makeAsyncIterator()
    let outcome = try #require(await iterator.next())
    #expect(outcome.showingFailure)
    #expect(outcome.reason == .liveness)
    #expect(outcome.health.goodStreak == 1)
}

@Test
func theDisplayReusesTwoPixelBuffers() {
    let display = PanelDisplay(
        requirements: workerRequirements(),
        producer: ClosureSceneProducer { _ in
            SceneFrame(bytes: workerScene, generation: 1)
        }
    )
    var outcome = display.renderBlocking(pixelWidth: 960, pixelHeight: 720, nowMs: 0)
    for nowMs in 1...20 {
        outcome = display.renderBlocking(
            pixelWidth: 960,
            pixelHeight: 720,
            nowMs: Double(nowMs)
        )
    }
    #expect(outcome.pixelBuffers.capacity == 2)
    #expect(outcome.pixelBuffers.resident == 2)
    #expect(outcome.pixelBuffers.allocations == 2)
}

@Test
func aPanelDeclaresItsRequiredDisplayRate() {
    #expect(workerRequirements().preferredFramesPerSecond == 60)
    #expect(workerRequirements(rate: 120).preferredFramesPerSecond == 120)
}

@Test @MainActor
func failurePagesUseASeparateWorkerAndReuseOneBuffer() async throws {
    let worker = FailurePageRenderWorker()
    let (firstStream, firstContinuation) = AsyncStream.makeStream(
        of: FailurePageRenderResult.self
    )
    worker.submit(pixelWidth: 120, pixelHeight: 90, reason: .liveness) { result in
        #expect(Thread.isMainThread)
        firstContinuation.yield(result)
        firstContinuation.finish()
    }
    var firstIterator = firstStream.makeAsyncIterator()
    let first = try #require(await firstIterator.next())

    let (secondStream, secondContinuation) = AsyncStream.makeStream(
        of: FailurePageRenderResult.self
    )
    worker.submit(pixelWidth: 120, pixelHeight: 90, reason: .liveness) { result in
        secondContinuation.yield(result)
        secondContinuation.finish()
    }
    var secondIterator = secondStream.makeAsyncIterator()
    let second = try #require(await secondIterator.next())

    #expect(first.image === second.image)
    #expect(worker.snapshot.pixelBuffers.capacity == 1)
    #expect(worker.snapshot.pixelBuffers.resident == 1)
    #expect(worker.snapshot.pixelBuffers.allocations == 1)
}
