import Foundation

struct PanelHealthUpdate: Sendable {
    let display: PanelHealthDisplay
    let snapshot: PanelHealthSnapshot
    let presentationEpoch: UInt64
}

/// Provides short, independent access to one panel's health state.
final class PanelHealthStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var health: PanelHealth
    private var presentationEpoch: UInt64 = 0

    init(_ health: PanelHealth) {
        self.health = health
    }

    func value() -> PanelHealth {
        lock.lock()
        defer { lock.unlock() }
        return health
    }

    func reportSuccess(nowMs: Double, generation: UInt32) -> PanelHealthUpdate {
        lock.lock()
        defer { lock.unlock() }
        let previous = health.display
        let display = health.reportSuccess(nowMs: nowMs, generation: generation)
        advancePresentationEpoch(ifChangedFrom: previous, to: display)
        return update(display: display)
    }

    func reportFailure(nowMs: Double, reason: DisplayReason) -> PanelHealthUpdate {
        lock.lock()
        defer { lock.unlock() }
        let previous = health.display
        let display = health.reportFailure(nowMs: nowMs, reason: reason)
        advancePresentationEpoch(ifChangedFrom: previous, to: display)
        return update(display: display)
    }

    func tick(nowMs: Double) -> PanelHealthDisplay {
        lock.lock()
        defer { lock.unlock() }
        let previous = health.display
        let display = health.tick(nowMs: nowMs)
        advancePresentationEpoch(ifChangedFrom: previous, to: display)
        return display
    }

    func tickForPresentation(nowMs: Double) -> PanelHealthUpdate {
        lock.lock()
        defer { lock.unlock() }
        let previous = health.display
        let display = health.tick(nowMs: nowMs)
        advancePresentationEpoch(ifChangedFrom: previous, to: display)
        return update(display: display)
    }

    func reset(nowMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        let previous = health.display
        health.reset(nowMs: nowMs)
        advancePresentationEpoch(ifChangedFrom: previous, to: health.display)
    }

    func presentIfCurrent(
        epoch: UInt64,
        display: PanelHealthDisplay,
        body: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard presentationEpoch == epoch, health.display == display else { return false }
        body()
        return true
    }

    func presentationLockIsHeldByAnotherThread() -> Bool {
        guard lock.try() else { return true }
        lock.unlock()
        return false
    }

    private func advancePresentationEpoch(
        ifChangedFrom previous: PanelHealthDisplay,
        to current: PanelHealthDisplay
    ) {
        if previous != current {
            presentationEpoch &+= 1
        }
    }

    private func update(display: PanelHealthDisplay) -> PanelHealthUpdate {
        PanelHealthUpdate(
            display: display,
            snapshot: health.snapshot,
            presentationEpoch: presentationEpoch
        )
    }
}
