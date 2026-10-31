import Foundation

/// Thresholds governing the 3D volumetric failure latch and liveness watchdog.
public struct VolumeHealthPolicy: Equatable, Sendable {
    /// Maximum allowed time in milliseconds without an advancing generation before liveness latches.
    public var livenessDeadlineMs: Double
    /// Consecutive validated advancing generations required to clear a latched failure.
    public var recoveryFrames: Int
    /// Expected interval in milliseconds between independent ``VolumeHealth/tick(nowMs:)`` calls.
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

/// Immediate failure-cover directive from ``VolumeHealth``.
public struct VolumeHealthDisplay: Equatable, Sendable {
    /// Indicates whether the host must show the 3D failure cage instead of the volume.
    public let showFailure: Bool
    /// Diagnostic reason code to show when `showFailure` is `true`.
    public let reason: DisplayReason

    public init(showFailure: Bool, reason: DisplayReason) {
        self.showFailure = showFailure
        self.reason = reason
    }
}

/// Cumulative health counters for diagnostics and external monitors.
public struct VolumeHealthCounters: Equatable, Sendable {
    public internal(set) var failures = 0
    public internal(set) var duplicates = 0
    public internal(set) var recoveries = 0
    public internal(set) var livenessTrips = 0
    public internal(set) var starvedTicks = 0

    public init(
        failures: Int = 0,
        duplicates: Int = 0,
        recoveries: Int = 0,
        livenessTrips: Int = 0,
        starvedTicks: Int = 0
    ) {
        self.failures = failures
        self.duplicates = duplicates
        self.recoveries = recoveries
        self.livenessTrips = livenessTrips
        self.starvedTicks = starvedTicks
    }
}

/// Immutable snapshot of ``VolumeHealth`` for monitors outside the render loop.
public struct VolumeHealthSnapshot: Equatable, Sendable {
    public let latched: Bool
    public let reason: DisplayReason
    public let goodStreak: Int
    public let lastGeneration: UInt32?
    public let lastAdvanceMs: Double
    public let counters: VolumeHealthCounters
}

/// Failure latch, 30-frame recovery gate, and liveness watchdog for one 3D volume.
///
/// Any produce, decode, band-contract, or liveness fault latches immediately so a
/// stale 3D scene never remains visible. Clearing a latched fault requires
/// ``VolumeHealthPolicy/recoveryFrames`` consecutive advancing generations.
public struct VolumeHealth: Equatable, Sendable {
    public let policy: VolumeHealthPolicy

    private var latched = false
    private var reason = DisplayReason.ok
    private var goodStreak = 0
    private var lastGeneration: UInt32?
    private var lastAdvanceMs: Double
    private var lastTickMs: Double
    private var counters = VolumeHealthCounters()

    public init(policy: VolumeHealthPolicy = VolumeHealthPolicy(), nowMs: Double = 0) {
        self.policy = policy
        lastAdvanceMs = nowMs
        lastTickMs = nowMs
    }

    /// Resets the failure latch and restarts the liveness clock after an explicit reload.
    public mutating func reset(nowMs: Double) {
        latched = false
        reason = .ok
        goodStreak = 0
        lastGeneration = nil
        lastAdvanceMs = nowMs
        lastTickMs = nowMs
        counters = VolumeHealthCounters()
    }

    /// Records a validated volumetric scene frame.
    ///
    /// Repeated generations earn no freshness or recovery credit.
    @discardableResult
    public mutating func reportSuccess(
        nowMs: Double,
        generation: UInt32
    ) -> VolumeHealthDisplay {
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

    /// Latches immediately on any produce, decode, or band-contract failure.
    @discardableResult
    public mutating func reportFailure(
        nowMs: Double,
        reason: DisplayReason
    ) -> VolumeHealthDisplay {
        latched = true
        self.reason = reason
        goodStreak = 0
        counters.failures &+= 1
        return display
    }

    /// Evaluates the liveness deadline from an independent timer tick.
    ///
    /// If the tick itself arrives more than `2 * tickIntervalMs` late because the
    /// host was suspended, the watchdog records starvation and re-arms the deadline.
    @discardableResult
    public mutating func tick(nowMs: Double) -> VolumeHealthDisplay {
        let starved = nowMs - lastTickMs > 2 * policy.tickIntervalMs
        lastTickMs = nowMs
        if starved {
            lastAdvanceMs = nowMs
            counters.starvedTicks &+= 1
            return display
        }
        if nowMs - lastAdvanceMs > policy.livenessDeadlineMs, !latched {
            latched = true
            reason = .liveness
            goodStreak = 0
            counters.livenessTrips &+= 1
        }
        return display
    }

    /// Current presentation directive.
    public var display: VolumeHealthDisplay {
        latched
            ? VolumeHealthDisplay(showFailure: true, reason: reason)
            : VolumeHealthDisplay(showFailure: false, reason: .ok)
    }

    /// Current diagnostic snapshot.
    public var snapshot: VolumeHealthSnapshot {
        VolumeHealthSnapshot(
            latched: latched,
            reason: reason,
            goodStreak: goodStreak,
            lastGeneration: lastGeneration,
            lastAdvanceMs: lastAdvanceMs,
            counters: counters
        )
    }
}
