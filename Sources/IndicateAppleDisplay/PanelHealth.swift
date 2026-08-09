import Foundation

/// Thresholds governing the failure latch and the liveness watchdog.
public struct PanelHealthPolicy: Equatable, Sendable {
    /// Frame advancement stalling for strictly longer than this is a failure.
    public var livenessDeadlineMs: Double
    /// Consecutive validated frames required to clear a latched failure. One
    /// arbitrary good frame never clears it.
    public var recoveryFrames: Int
    /// The cadence the host schedules ``PanelHealth/tick(nowMs:)`` at.
    public var tickIntervalMs: Double

    public init(
        livenessDeadlineMs: Double = 1000,
        recoveryFrames: Int = 30,
        tickIntervalMs: Double = 250
    ) {
        self.livenessDeadlineMs = livenessDeadlineMs
        self.recoveryFrames = recoveryFrames
        self.tickIntervalMs = tickIntervalMs
    }
}

/// What the compositor must show right now.
public struct PanelHealthDisplay: Equatable, Sendable {
    /// Whether the panel must be covered by the failure page.
    public let showFailure: Bool
    /// The code to show when covering.
    public let reason: DisplayReason
}

/// Why a panel latched, and how often, for a separately scheduled monitor.
public struct PanelHealthCounters: Equatable, Sendable {
    public internal(set) var failures = 0
    public internal(set) var duplicates = 0
    public internal(set) var recoveries = 0
    public internal(set) var livenessTrips = 0
    public internal(set) var starvedTicks = 0
}

/// The health contract a monitor outside the render loop can consume.
public struct PanelHealthSnapshot: Equatable, Sendable {
    public let latched: Bool
    public let reason: DisplayReason
    public let goodStreak: Int
    public let lastGeneration: UInt32?
    public let lastAdvanceMs: Double
    public let counters: PanelHealthCounters
}

/// Failure latch, recovery streak, and liveness watchdog for one panel.
///
/// A renderer or display-pipeline failure must never leave a valid-looking
/// last successful image visible, and a single lucky frame must not clear a
/// latched fault. Both rules live here rather than in the view, so a host that
/// paints into a layer, a texture, or a file obeys the same contract.
public struct PanelHealth: Equatable, Sendable {
    public let policy: PanelHealthPolicy

    private var latched = false
    private var reason = DisplayReason.ok
    private var goodStreak = 0
    private var lastGeneration: UInt32?
    private var lastAdvanceMs: Double
    private var lastTickMs: Double
    private var counters = PanelHealthCounters()

    public init(policy: PanelHealthPolicy = PanelHealthPolicy(), nowMs: Double = 0) {
        self.policy = policy
        lastAdvanceMs = nowMs
        // Seeding the tick clock here gives the *first* tick a cadence
        // baseline. Without it a first tick that is already late — the host
        // was suspended before the watchdog ever ran — reads as a dead
        // renderer instead of as starvation.
        lastTickMs = nowMs
    }

    /// Clears the latch and restarts the liveness deadline.
    ///
    /// This is an explicit reinitialization transition. Only a producer reload
    /// should call it; using it to dismiss a fault would defeat the latch.
    public mutating func reset(nowMs: Double) {
        latched = false
        reason = .ok
        goodStreak = 0
        lastGeneration = nil
        lastAdvanceMs = nowMs
        lastTickMs = nowMs
        counters = PanelHealthCounters()
    }

    /// Records a validated frame.
    ///
    /// Freshness credit requires `generation` to actually advance. A repeated
    /// generation is a duplicate and earns nothing — it can neither feed the
    /// recovery streak nor reset the liveness deadline — because a producer
    /// stuck on one frame is exactly the failure the watchdog exists to catch.
    @discardableResult
    public mutating func reportSuccess(
        nowMs: Double,
        generation: UInt32
    ) -> PanelHealthDisplay {
        let advanced = lastGeneration == nil || generation != lastGeneration
        lastGeneration = generation
        guard advanced else {
            counters.duplicates &+= 1
            return display
        }
        lastAdvanceMs = nowMs
        if latched {
            goodStreak &+= 1
            if goodStreak >= policy.recoveryFrames {
                latched = false
                reason = .ok
                goodStreak = 0
                counters.recoveries &+= 1
            }
        }
        return display
    }

    /// Latches immediately on any produce, validate, or paint failure.
    @discardableResult
    public mutating func reportFailure(
        nowMs: Double,
        reason: DisplayReason
    ) -> PanelHealthDisplay {
        latched = true
        self.reason = reason
        goodStreak = 0
        counters.failures &+= 1
        return display
    }

    /// Watchdog tick from a scheduling domain independent of the render loop.
    ///
    /// A tick whose own arrival is late against `tickIntervalMs` proves the
    /// watchdog's scheduling domain was starved — a backgrounded app suspends
    /// the display link and clamps timers together — so it re-arms the
    /// deadline instead of judging with a clock that itself stopped. A
    /// genuinely dead render loop on a normally scheduled host still trips
    /// within one deadline of ticks running on cadence.
    @discardableResult
    public mutating func tick(nowMs: Double) -> PanelHealthDisplay {
        let starved = nowMs - lastTickMs > 2 * policy.tickIntervalMs
        lastTickMs = nowMs
        if starved {
            lastAdvanceMs = nowMs
            counters.starvedTicks &+= 1
            return display
        }
        // Strictly greater: an advance exactly at the deadline is still on time.
        if nowMs - lastAdvanceMs > policy.livenessDeadlineMs, !latched {
            latched = true
            reason = .liveness
            goodStreak = 0
            counters.livenessTrips &+= 1
        }
        return display
    }

    /// What the compositor must show right now.
    public var display: PanelHealthDisplay {
        latched
            ? PanelHealthDisplay(showFailure: true, reason: reason)
            : PanelHealthDisplay(showFailure: false, reason: .ok)
    }

    /// The health contract for a separately scheduled monitor.
    public var snapshot: PanelHealthSnapshot {
        PanelHealthSnapshot(
            latched: latched,
            reason: reason,
            goodStreak: goodStreak,
            lastGeneration: lastGeneration,
            lastAdvanceMs: lastAdvanceMs,
            counters: counters
        )
    }
}
