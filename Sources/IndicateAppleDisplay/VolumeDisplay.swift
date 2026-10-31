import Foundation

/// Encoded 3D volumetric scene bytes and their producer generation counter.
public struct VolumeFrame: Equatable, Sendable {
    /// Encoded `VOLUME_SCENE_VERSION = 1` bytes.
    public let bytes: [UInt8]
    /// Producer generation that advances only when scene inputs advance.
    public let generation: UInt32

    public init(bytes: [UInt8], generation: UInt32) {
        self.bytes = bytes
        self.generation = generation
    }
}

/// Pull-paced producer of 3D volumetric scene frames.
public protocol VolumeProducing: AnyObject, Sendable {
    /// Produces the 3D scene for `extent` and `viewPose`.
    func volumeFrame(extent: Extent3D, viewPose: ViewPose3D) throws -> VolumeFrame
}

/// Closure-backed ``VolumeProducing`` adapter.
public final class ClosureVolumeProducer: VolumeProducing {
    private let body: @Sendable (Extent3D, ViewPose3D) throws -> VolumeFrame

    public init(_ body: @escaping @Sendable (Extent3D, ViewPose3D) throws -> VolumeFrame) {
        self.body = body
    }

    public func volumeFrame(extent: Extent3D, viewPose: ViewPose3D) throws -> VolumeFrame {
        try body(extent, viewPose)
    }
}

/// Validated, decoded 3D volumetric scene ready for RealityKit materialization.
public struct VolumeSnapshot: Equatable, Sendable {
    /// Physical volume extent in meters.
    public let extent: Extent3D
    /// Producer generation counter.
    public let generation: UInt32
    /// Local ``ViewPose3D`` active when this snapshot was produced.
    public let viewPose: ViewPose3D
    /// Band validation summary.
    public let report: VolumeBandReport
    /// Validated per-band command slices in ascending ``VolumeBand`` order.
    public let bands: [VolumeBandSlice]

    public init(
        extent: Extent3D,
        generation: UInt32,
        viewPose: ViewPose3D,
        report: VolumeBandReport,
        bands: [VolumeBandSlice]
    ) {
        self.extent = extent
        self.generation = generation
        self.viewPose = viewPose
        self.report = report
        self.bands = bands
    }
}

/// Transactional presentation state produced by ``VolumeDisplay``.
public enum VolumePresentation: Equatable, Sendable {
    /// Validated 3D snapshot cleared for display.
    case valid(VolumeSnapshot)
    /// Latched failure state requiring the 3D failure cage.
    case failed(DisplayReason)
}

/// Complete outcome of one ``VolumeDisplay/render(nowMs:)`` evaluation.
public struct VolumeFrameOutcome: Equatable, Sendable {
    /// Transactional presentation to materialize.
    public let presentation: VolumePresentation
    /// Indicates whether the presentation is the failure cage.
    public let showingFailure: Bool
    /// Diagnostic reason code (`.ok` when showing a valid volume).
    public let reason: DisplayReason
    /// Producer generation observed during this attempt, when available.
    public let generation: UInt32?
    /// Band validation report, when validation succeeded.
    public let report: VolumeBandReport?
    /// Health snapshot after committing this attempt.
    public let health: VolumeHealthSnapshot
}

/// Pull-paced transactional 3D volumetric display pipeline.
///
/// ``VolumeDisplay`` decouples incoming state rates from headset refresh rates,
/// updates ``viewPose`` locally at 90–120 Hz via ``ViewPoseController``, validates
/// every `VOLUME_SCENE_VERSION = 1` frame before commit, latches immediately on any
/// fault, and requires 30 consecutive good generations to recover.
public final class VolumeDisplay: @unchecked Sendable {
    /// Acceptance contract for this volumetric instrument.
    public let requirements: VolumeRequirements

    private let producer: any VolumeProducing
    private let lock = NSRecursiveLock()
    private var healthState: VolumeHealth
    private var poseState: ViewPose3D
    private var interactionSequence: UInt32 = 0

    public init(
        requirements: VolumeRequirements,
        producer: any VolumeProducing,
        initialPose: ViewPose3D = ViewPose3D(),
        policy: VolumeHealthPolicy = VolumeHealthPolicy(),
        nowMs: Double = 0
    ) {
        self.requirements = requirements
        self.producer = producer
        self.healthState = VolumeHealth(policy: policy, nowMs: nowMs)
        self.poseState = initialPose
    }

    /// Current health state snapshot.
    public var health: VolumeHealth {
        lock.lock()
        defer { lock.unlock() }
        return healthState
    }

    /// Current local 3D view pose.
    public var viewPose: ViewPose3D {
        get {
            lock.lock()
            defer { lock.unlock() }
            return poseState
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            poseState = newValue
        }
    }

    /// Applies `event` locally to ``viewPose`` under ``VolumeRequirements/viewLimits``.
    @discardableResult
    public func applyInteraction(
        _ event: SpatialEvent
    ) throws(SpatialInteractionError) -> InteractionOutcome {
        lock.lock()
        defer { lock.unlock() }
        return try ViewPoseController.apply(
            event,
            to: &poseState,
            limits: requirements.viewLimits
        )
    }

    /// Stamps `event`, applies it locally to ``viewPose``, and returns the wire ``InteractionFrame``.
    public func recordInteraction(
        deviceId: UInt32,
        timestampUs: UInt64,
        event: SpatialEvent
    ) throws(SpatialInteractionError) -> (frame: InteractionFrame, outcome: InteractionOutcome) {
        lock.lock()
        defer { lock.unlock() }
        let outcome = try ViewPoseController.apply(
            event,
            to: &poseState,
            limits: requirements.viewLimits
        )
        let seq = interactionSequence
        interactionSequence &+= 1
        let frame = InteractionFrame(
            stamp: InteractionStamp(
                deviceId: deviceId,
                sequence: seq,
                timestampUs: timestampUs
            ),
            event: event
        )
        return (frame, outcome)
    }

    /// Produces, validates, and commits one volumetric frame at `nowMs`.
    public func render(nowMs: Double) -> VolumeFrameOutcome {
        let currentPose = viewPose
        let extent = requirements.canonicalExtent
        let frame: VolumeFrame
        do {
            frame = try producer.volumeFrame(extent: extent, viewPose: currentPose)
        } catch let fault as ProducerFault {
            return commitFailure(reason: fault.reason, nowMs: nowMs)
        } catch {
            return commitFailure(reason: .renderTrap, nowMs: nowMs)
        }

        let validated: (report: VolumeBandReport, bands: [VolumeBandSlice])
        do {
            validated = try VolumeSceneValidator.validateAndGroup(
                frame.bytes,
                unknownOpcodes: requirements.unknownOpcodes
            )
        } catch {
            return commitFailure(reason: error.displayReason, nowMs: nowMs)
        }

        if let rejection = validated.report.rejection(requirements) {
            return commitFailure(reason: rejection, nowMs: nowMs)
        }

        let visibleBands: [VolumeBandSlice] = if currentPose.decluttered {
            validated.bands.filter { !$0.band.isDroppable }
        } else {
            validated.bands
        }

        lock.lock()
        let display = healthState.reportSuccess(nowMs: nowMs, generation: frame.generation)
        let snapshotHealth = healthState.snapshot
        lock.unlock()

        if display.showFailure {
            return VolumeFrameOutcome(
                presentation: .failed(display.reason),
                showingFailure: true,
                reason: display.reason,
                generation: frame.generation,
                report: validated.report,
                health: snapshotHealth
            )
        }

        let snapshot = VolumeSnapshot(
            extent: extent,
            generation: frame.generation,
            viewPose: currentPose,
            report: validated.report,
            bands: visibleBands
        )
        return VolumeFrameOutcome(
            presentation: .valid(snapshot),
            showingFailure: false,
            reason: .ok,
            generation: frame.generation,
            report: validated.report,
            health: snapshotHealth
        )
    }

    /// Evaluates the independent liveness watchdog at `nowMs`.
    @discardableResult
    public func tick(nowMs: Double) -> VolumeHealthDisplay {
        lock.lock()
        defer { lock.unlock() }
        return healthState.tick(nowMs: nowMs)
    }

    /// Latches an external producer or FFI failure immediately.
    @discardableResult
    public func reportProducerFailure(
        _ reason: DisplayReason,
        nowMs: Double
    ) -> VolumeHealthDisplay {
        lock.lock()
        defer { lock.unlock() }
        return healthState.reportFailure(nowMs: nowMs, reason: reason)
    }

    /// Clears the failure latch after an explicit producer reload.
    public func reset(nowMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        healthState.reset(nowMs: nowMs)
    }

    private func commitFailure(reason: DisplayReason, nowMs: Double) -> VolumeFrameOutcome {
        lock.lock()
        let display = healthState.reportFailure(nowMs: nowMs, reason: reason)
        let snapshotHealth = healthState.snapshot
        lock.unlock()
        return VolumeFrameOutcome(
            presentation: .failed(display.reason),
            showingFailure: true,
            reason: display.reason,
            generation: nil,
            report: nil,
            health: snapshotHealth
        )
    }
}
