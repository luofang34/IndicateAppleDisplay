#if canImport(SwiftUI)
import Foundation
import QuartzCore
import RealityKit
import SwiftUI
import simd

/// SwiftUI view that hosts a ``VolumeDisplay`` and drives zero-latency ``SpatialEvent`` gestures.
///
/// On `visionOS`, ``InstrumentVolume`` renders inside a `RealityView` and attaches
/// `SpatialTapGesture`, `DragGesture`, `MagnifyGesture`, and `RotateGesture3D`
/// directly to the volumetric entity tree. On `macOS` and `iOS`, ``InstrumentVolume``
/// provides a cross-platform SwiftUI viewport and gesture adapter over the same
/// ``VolumeDisplay`` and ``RealityVolumeBuilder`` pipeline.
public struct InstrumentVolume: View {
    private let display: VolumeDisplay
    private let deviceId: UInt32
    private let onOutcome: ((VolumeFrameOutcome) -> Void)?
    private let onInteraction: ((InteractionFrame) -> Void)?
    private let onTargetActivated: ((TargetId, SIMD3<Float>) -> Void)?

    @State private var coordinator = InstrumentVolumeCoordinator()
    @State private var revision: UInt64 = 0

    public init(
        display: VolumeDisplay,
        deviceId: UInt32 = 1,
        onOutcome: ((VolumeFrameOutcome) -> Void)? = nil,
        onInteraction: ((InteractionFrame) -> Void)? = nil,
        onTargetActivated: ((TargetId, SIMD3<Float>) -> Void)? = nil
    ) {
        self.display = display
        self.deviceId = deviceId
        self.onOutcome = onOutcome
        self.onInteraction = onInteraction
        self.onTargetActivated = onTargetActivated
    }

    public var body: some View {
        let interval = 1.0 / Double(max(display.requirements.preferredFramesPerSecond, 1))
        TimelineView(.animation(minimumInterval: interval)) { timeline in
            volumeBody(at: timeline.date)
        }
        .task(id: ObjectIdentifier(display)) {
            let sleepNs = UInt64(max(display.health.policy.tickIntervalMs, 20.0) * 1_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sleepNs)
                guard !Task.isCancelled else { break }
                let nowMs = CACurrentMediaTime() * 1000.0
                let status = display.tick(nowMs: nowMs)
                if status.showFailure {
                    coordinator.presentWatchdogFailure(
                        reason: status.reason,
                        extent: display.requirements.canonicalExtent
                    )
                    revision &+= 1
                }
            }
        }
    }

    #if os(visionOS)
    @MainActor
    @ViewBuilder
    private func volumeBody(at date: Date) -> some View {
        let _ = date
        let _ = revision
        RealityView { content in
            coordinator.refreshIfNeeded(
                display: display,
                nowMs: CACurrentMediaTime() * 1000.0,
                onOutcome: onOutcome
            )
            content.add(coordinator.containerEntity)
        } update: { _ in
            coordinator.refreshIfNeeded(
                display: display,
                nowMs: CACurrentMediaTime() * 1000.0,
                onOutcome: onOutcome
            )
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    let point = value.convert(
                        value.location3D,
                        from: .local,
                        to: coordinator.sceneEntity
                    )
                    let target = RealityVolumeBuilder.resolveTarget(from: value.entity)?.targetId
                        ?? .none
                    dispatch(event: .activate(target: target, pointLocal: point))
                }
        )
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    let start = value.convert(
                        value.startLocation3D,
                        from: .local,
                        to: coordinator.containerEntity
                    )
                    let current = value.convert(
                        value.location3D,
                        from: .local,
                        to: coordinator.containerEntity
                    )
                    let totalDelta = current - start
                    let (phase, stepDelta) = coordinator.consumeDragSample(totalDelta: totalDelta)
                    let target = RealityVolumeBuilder.resolveTarget(from: value.entity)?.targetId
                        ?? .none
                    dispatch(event: .drag3D(
                        phase: phase,
                        target: target,
                        originLocal: start,
                        deltaLocal: stepDelta
                    ))
                }
                .onEnded { value in
                    let start = value.convert(
                        value.startLocation3D,
                        from: .local,
                        to: coordinator.containerEntity
                    )
                    let current = value.convert(
                        value.location3D,
                        from: .local,
                        to: coordinator.containerEntity
                    )
                    let stepDelta = coordinator.finishDrag(totalDelta: current - start)
                    let target = RealityVolumeBuilder.resolveTarget(from: value.entity)?.targetId
                        ?? .none
                    dispatch(event: .drag3D(
                        phase: .ended,
                        target: target,
                        originLocal: start,
                        deltaLocal: stepDelta
                    ))
                }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let (phase, stepScale) = coordinator.consumeMagnifySample(
                        magnification: Float(value.magnification)
                    )
                    dispatch(event: .transform3D(
                        phase: phase,
                        pivotLocal: .zero,
                        translationLocal: .zero,
                        rotation: SIMD4(0, 0, 0, 1),
                        scale: stepScale
                    ))
                }
                .onEnded { value in
                    let stepScale = coordinator.finishMagnify(
                        magnification: Float(value.magnification)
                    )
                    dispatch(event: .transform3D(
                        phase: .ended,
                        pivotLocal: .zero,
                        translationLocal: .zero,
                        rotation: SIMD4(0, 0, 0, 1),
                        scale: stepScale
                    ))
                }
        )
        .gesture(
            RotateGesture3D()
                .onChanged { value in
                    let q = value.rotation.quaternion
                    let current = SIMD4<Float>(
                        Float(q.imag.x),
                        Float(q.imag.y),
                        Float(q.imag.z),
                        Float(q.real)
                    )
                    let (phase, deltaQuat) = coordinator.consumeRotateSample(current: current)
                    dispatch(event: .transform3D(
                        phase: phase,
                        pivotLocal: .zero,
                        translationLocal: .zero,
                        rotation: deltaQuat,
                        scale: 1.0
                    ))
                }
                .onEnded { value in
                    let q = value.rotation.quaternion
                    let current = SIMD4<Float>(
                        Float(q.imag.x),
                        Float(q.imag.y),
                        Float(q.imag.z),
                        Float(q.real)
                    )
                    let deltaQuat = coordinator.finishRotate(current: current)
                    dispatch(event: .transform3D(
                        phase: .ended,
                        pivotLocal: .zero,
                        translationLocal: .zero,
                        rotation: deltaQuat,
                        scale: 1.0
                    ))
                }
        )
    }
    #else
    @MainActor
    @ViewBuilder
    private func volumeBody(at date: Date) -> some View {
        let _ = date
        let _ = revision
        GeometryReader { proxy in
            ZStack {
                Color.black
                if coordinator.showingFailure {
                    VStack(spacing: 8) {
                        Text("DISPLAY FAIL")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                        Text(coordinator.failureReason.label)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        Rectangle()
                            .strokeBorder(.red, lineWidth: 3)
                    )
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.requirements.title)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text("ZOOM \(String(format: "%.2fx", display.viewPose.zoomScale))")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.gray)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .contentShape(Rectangle())
            .onAppear {
                coordinator.refreshIfNeeded(
                    display: display,
                    nowMs: CACurrentMediaTime() * 1000.0,
                    onOutcome: onOutcome
                )
            }
            .onChange(of: date) { _, _ in
                coordinator.refreshIfNeeded(
                    display: display,
                    nowMs: CACurrentMediaTime() * 1000.0,
                    onOutcome: onOutcome
                )
            }
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let width = max(Float(proxy.size.width), 1)
                        let height = max(Float(proxy.size.height), 1)
                        let nx = (Float(value.location.x) / width - 0.5)
                            * display.requirements.canonicalExtent.widthMeters
                        let ny = (0.5 - Float(value.location.y) / height)
                            * display.requirements.canonicalExtent.heightMeters
                        let point = SIMD3<Float>(nx, ny, 0)
                        let hitTarget = coordinator.hitTestPlanarHandle(at: point)
                        dispatch(event: .activate(target: hitTarget, pointLocal: point))
                    }
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let scale = display.requirements.canonicalExtent.widthMeters
                            / max(Float(proxy.size.width), 1)
                        let total = SIMD3<Float>(
                            Float(value.translation.width) * scale,
                            -Float(value.translation.height) * scale,
                            0
                        )
                        let (phase, step) = coordinator.consumeDragSample(totalDelta: total)
                        dispatch(event: .drag3D(
                            phase: phase,
                            target: .none,
                            originLocal: .zero,
                            deltaLocal: step
                        ))
                    }
                    .onEnded { value in
                        let scale = display.requirements.canonicalExtent.widthMeters
                            / max(Float(proxy.size.width), 1)
                        let total = SIMD3<Float>(
                            Float(value.translation.width) * scale,
                            -Float(value.translation.height) * scale,
                            0
                        )
                        let step = coordinator.finishDrag(totalDelta: total)
                        dispatch(event: .drag3D(
                            phase: .ended,
                            target: .none,
                            originLocal: .zero,
                            deltaLocal: step
                        ))
                    }
            )
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let (phase, stepScale) = coordinator.consumeMagnifySample(
                            magnification: Float(value.magnification)
                        )
                        dispatch(event: .transform3D(
                            phase: phase,
                            pivotLocal: .zero,
                            translationLocal: .zero,
                            rotation: SIMD4(0, 0, 0, 1),
                            scale: stepScale
                        ))
                    }
                    .onEnded { value in
                        let stepScale = coordinator.finishMagnify(
                            magnification: Float(value.magnification)
                        )
                        dispatch(event: .transform3D(
                            phase: .ended,
                            pivotLocal: .zero,
                            translationLocal: .zero,
                            rotation: SIMD4(0, 0, 0, 1),
                            scale: stepScale
                        ))
                    }
            )
        }
    }
    #endif

    @MainActor
    private func dispatch(event: SpatialEvent) {
        let nowUs = UInt64(max(CACurrentMediaTime(), 0) * 1_000_000.0)
        guard let recorded = try? display.recordInteraction(
            deviceId: deviceId,
            timestampUs: nowUs,
            event: event
        ) else {
            return
        }
        coordinator.applyLocalPose(display.viewPose)
        revision &+= 1
        onInteraction?(recorded.frame)
        if case let .targetActivated(target, point) = recorded.outcome, target != .none {
            onTargetActivated?(target, point)
        }
    }
}

@MainActor
private final class InstrumentVolumeCoordinator {
    let containerEntity = Entity()
    let sceneEntity = Entity()
    private let builder = RealityVolumeBuilder()

    private(set) var showingFailure = false
    private(set) var failureReason: DisplayReason = .ok
    private var lastRenderedGeneration: UInt32?
    private var lastRenderedPose: ViewPose3D?

    private var dragActive = false
    private var lastDragTotal = SIMD3<Float>.zero
    private var magnifyActive = false
    private var lastMagnification: Float = 1.0
    private var rotateActive = false
    private var lastRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    init() {
        containerEntity.name = "indicate.volume.container"
        sceneEntity.name = "indicate.volume.root"
        containerEntity.addChild(sceneEntity)
    }

    func refreshIfNeeded(
        display: VolumeDisplay,
        nowMs: Double,
        onOutcome: ((VolumeFrameOutcome) -> Void)?
    ) {
        let outcome = display.render(nowMs: nowMs)
        onOutcome?(outcome)
        switch outcome.presentation {
        case let .valid(snapshot):
            let needsRebuild = showingFailure
                || lastRenderedGeneration != snapshot.generation
                || lastRenderedPose?.decluttered != snapshot.viewPose.decluttered
            showingFailure = false
            failureReason = .ok
            lastRenderedGeneration = snapshot.generation
            lastRenderedPose = snapshot.viewPose
            if needsRebuild {
                builder.updateEntity(
                    sceneEntity,
                    with: .valid(snapshot),
                    fallbackExtent: display.requirements.canonicalExtent
                )
            } else {
                sceneEntity.transform = RealityVolumeBuilder.poseTransform(snapshot.viewPose)
            }
        case let .failed(reason):
            let needsFailureBuild = !showingFailure || failureReason != reason
            showingFailure = true
            failureReason = reason
            lastRenderedGeneration = nil
            if needsFailureBuild {
                builder.updateEntity(
                    sceneEntity,
                    with: .failed(reason),
                    fallbackExtent: display.requirements.canonicalExtent
                )
            }
        }
    }

    func presentWatchdogFailure(reason: DisplayReason, extent: Extent3D) {
        guard !showingFailure || failureReason != reason else { return }
        showingFailure = true
        failureReason = reason
        lastRenderedGeneration = nil
        builder.updateEntity(
            sceneEntity,
            with: .failed(reason),
            fallbackExtent: extent
        )
    }

    func applyLocalPose(_ pose: ViewPose3D) {
        guard !showingFailure else { return }
        sceneEntity.transform = RealityVolumeBuilder.poseTransform(pose)
    }

    func hitTestPlanarHandle(at point: SIMD3<Float>) -> TargetId {
        let handles = RealityVolumeBuilder.findTargetHandles(in: sceneEntity)
        var best: (id: TargetId, dist: Float)?
        for entity in handles {
            guard let comp = entity.components[IndicateTargetComponent.self] else { continue }
            let d = simd_distance(
                SIMD2(point.x, point.y),
                SIMD2(comp.centerLocal.x, comp.centerLocal.y)
            )
            if d <= comp.radiusMeters, best == nil || d < (best?.dist ?? .infinity) {
                best = (comp.targetId, d)
            }
        }
        return best?.id ?? .none
    }

    func consumeDragSample(totalDelta: SIMD3<Float>) -> (GesturePhase, SIMD3<Float>) {
        if !dragActive {
            dragActive = true
            lastDragTotal = totalDelta
            return (.began, totalDelta)
        }
        let step = totalDelta - lastDragTotal
        lastDragTotal = totalDelta
        return (.changed, step)
    }

    func finishDrag(totalDelta: SIMD3<Float>) -> SIMD3<Float> {
        let step = dragActive ? (totalDelta - lastDragTotal) : totalDelta
        dragActive = false
        lastDragTotal = .zero
        return step
    }

    func consumeMagnifySample(magnification: Float) -> (GesturePhase, Float) {
        let clamped = max(magnification.isFinite ? magnification : 1.0, 0.01)
        if !magnifyActive {
            magnifyActive = true
            lastMagnification = clamped
            return (.began, clamped)
        }
        let ratio = max(clamped / max(lastMagnification, 0.01), 0.01)
        lastMagnification = clamped
        return (.changed, ratio)
    }

    func finishMagnify(magnification: Float) -> Float {
        let clamped = max(magnification.isFinite ? magnification : 1.0, 0.01)
        let ratio = magnifyActive ? max(clamped / max(lastMagnification, 0.01), 0.01) : clamped
        magnifyActive = false
        lastMagnification = 1.0
        return ratio
    }

    func consumeRotateSample(current: SIMD4<Float>) -> (GesturePhase, SIMD4<Float>) {
        let q = Self.safeUnitQuat(current)
        if !rotateActive {
            rotateActive = true
            lastRotation = q
            return (.began, q.vector)
        }
        let delta = simd_normalize(q * lastRotation.inverse)
        lastRotation = q
        return (.changed, delta.vector)
    }

    func finishRotate(current: SIMD4<Float>) -> SIMD4<Float> {
        let q = Self.safeUnitQuat(current)
        let delta = rotateActive ? simd_normalize(q * lastRotation.inverse) : q
        rotateActive = false
        lastRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        return delta.vector
    }

    private static func safeUnitQuat(_ raw: SIMD4<Float>) -> simd_quatf {
        guard isFiniteSIMD4(raw) else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let len = simd_length(raw)
        guard len > 1e-5 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_quatf(vector: raw / len)
    }
}
#endif
