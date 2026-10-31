import CoreGraphics
import CoreText
import Foundation
import RealityKit
import simd

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// RealityKit component identifying an interactive 3D handle emitted by ``VolumeSceneCommand/targetHandle(targetId:kind:center:radiusMeters:)``.
public struct IndicateTargetComponent: Component, Equatable, Sendable {
    /// Non-zero target identifier for spatial hit-testing.
    public var targetId: TargetId
    /// Semantic handle category.
    public var kind: HandleKind
    /// Handle center in volume-local coordinates (meters).
    public var centerLocal: SIMD3<Float>
    /// Collision sphere radius in meters.
    public var radiusMeters: Float

    public init(
        targetId: TargetId,
        kind: HandleKind,
        centerLocal: SIMD3<Float>,
        radiusMeters: Float
    ) {
        self.targetId = targetId
        self.kind = kind
        self.centerLocal = centerLocal
        self.radiusMeters = radiusMeters
    }
}

/// RealityKit component marking an anchor entity emitted by ``VolumeSceneCommand/underlayAnchor3D(kind:center:extent:orientation:metersPerUnit:)``.
public struct IndicateUnderlayAnchorComponent: Component, Equatable, Sendable {
    /// Kind of host-managed 3D underlay.
    public var kind: VolumeUnderlayKind
    /// Anchor center in volume-local coordinates (meters).
    public var centerLocal: SIMD3<Float>
    /// Bounding extent in meters.
    public var extentMeters: SIMD3<Float>
    /// Unit quaternion orientation (`x, y, z, w`).
    public var orientation: SIMD4<Float>
    /// Physical scale in meters per underlay coordinate unit.
    public var metersPerUnit: Double

    public init(
        kind: VolumeUnderlayKind,
        centerLocal: SIMD3<Float>,
        extentMeters: SIMD3<Float>,
        orientation: SIMD4<Float>,
        metersPerUnit: Double
    ) {
        self.kind = kind
        self.centerLocal = centerLocal
        self.extentMeters = extentMeters
        self.orientation = orientation
        self.metersPerUnit = metersPerUnit
    }
}

/// RealityKit component recording metadata for a ``VolumeSceneCommand/billboardText(position:sizeMeters:anchor:text:)`` entity.
public struct IndicateBillboardComponent: Component, Equatable, Sendable {
    /// UTF-8 text string displayed by the billboard.
    public var text: String
    /// Nominal cap height in meters.
    public var sizeMeters: Float
    /// Horizontal text alignment anchor.
    public var anchor: TextAnchor
    /// Active fill color when the billboard was emitted.
    public var color: SceneColor
    /// Active provenance group tag, when preceded by ``VolumeSceneCommand/attribute(group:)``.
    public var attributeGroup: UInt8?

    public init(
        text: String,
        sizeMeters: Float,
        anchor: TextAnchor,
        color: SceneColor,
        attributeGroup: UInt8?
    ) {
        self.text = text
        self.sizeMeters = sizeMeters
        self.anchor = anchor
        self.color = color
        self.attributeGroup = attributeGroup
    }
}

/// RealityKit component marking a 3D failure cage built when ``VolumePresentation`` is `.failed`.
public struct IndicateFailureCageComponent: Component, Equatable, Sendable {
    /// Latched diagnostic reason code.
    public var reason: DisplayReason
    /// Operator-visible diagnostic code string (`D-NNN`).
    public var label: String

    public init(reason: DisplayReason) {
        self.reason = reason
        self.label = reason.label
    }
}

/// Deterministic `@MainActor` builder that materializes a ``VolumePresentation`` into a `RealityKit.Entity` hierarchy.
@MainActor
public final class RealityVolumeBuilder {
    private static var didRegisterComponents = false

    private let unitSphere: MeshResource
    private let unitBox: MeshResource
    private let unitCylinder: MeshResource
    private let unitPlane: MeshResource
    private let ringSegments = 20

    /// Creates a reusable volumetric RealityKit entity builder and registers custom components.
    public init() {
        Self.registerComponentsIfNeeded()
        unitSphere = .generateSphere(radius: 1.0)
        unitBox = .generateBox(size: 1.0)
        unitCylinder = Self.makeUnitCylinderMesh(segments: 16)
        unitPlane = .generatePlane(width: 1.0, height: 1.0)
    }

    /// Registers custom RealityKit components once per process.
    public static func registerComponentsIfNeeded() {
        guard !didRegisterComponents else { return }
        IndicateTargetComponent.registerComponent()
        IndicateUnderlayAnchorComponent.registerComponent()
        IndicateBillboardComponent.registerComponent()
        IndicateFailureCageComponent.registerComponent()
        didRegisterComponents = true
    }

    /// Builds a fresh root `Entity` for `presentation`, using `fallbackExtent` for the failure cage.
    public func buildEntity(
        from presentation: VolumePresentation,
        fallbackExtent: Extent3D
    ) -> Entity {
        switch presentation {
        case let .valid(snapshot):
            return buildSnapshotEntity(snapshot)
        case let .failed(reason):
            return buildFailureEntity(reason: reason, extent: fallbackExtent)
        }
    }

    /// Replaces the children and components of `root` to match `presentation`.
    public func updateEntity(
        _ root: Entity,
        with presentation: VolumePresentation,
        fallbackExtent: Extent3D
    ) {
        for child in Array(root.children) {
            child.removeFromParent()
        }
        root.components.remove(IndicateFailureCageComponent.self)
        switch presentation {
        case let .valid(snapshot):
            root.name = "indicate.volume.root"
            root.transform = Self.poseTransform(snapshot.viewPose)
            populateBands(of: snapshot, into: root)
        case let .failed(reason):
            root.name = "indicate.volume.failure"
            root.transform = .identity
            root.components.set(IndicateFailureCageComponent(reason: reason))
            populateFailureCage(reason: reason, extent: fallbackExtent, into: root)
        }
    }

    /// Builds a root `Entity` hierarchy from a validated ``VolumeSnapshot``.
    public func buildSnapshotEntity(_ snapshot: VolumeSnapshot) -> Entity {
        let root = Entity()
        root.name = "indicate.volume.root"
        root.transform = Self.poseTransform(snapshot.viewPose)
        populateBands(of: snapshot, into: root)
        return root
    }

    /// Builds a standalone 3D red-X failure cage `Entity` with a `D-NNN` plaque.
    public func buildFailureEntity(reason: DisplayReason, extent: Extent3D) -> Entity {
        let root = Entity()
        root.name = "indicate.volume.failure"
        root.components.set(IndicateFailureCageComponent(reason: reason))
        populateFailureCage(reason: reason, extent: extent, into: root)
        return root
    }

    /// Collects all descendant entities carrying ``IndicateTargetComponent``.
    public static func findTargetHandles(in root: Entity) -> [Entity] {
        var found: [Entity] = []
        collectEntities(in: root, into: &found) { $0.components.has(IndicateTargetComponent.self) }
        return found
    }

    /// Collects all descendant entities carrying ``IndicateUnderlayAnchorComponent``.
    public static func findUnderlayAnchors(in root: Entity) -> [Entity] {
        var found: [Entity] = []
        collectEntities(in: root, into: &found) {
            $0.components.has(IndicateUnderlayAnchorComponent.self)
        }
        return found
    }

    /// Walks `entity` and its ancestors to find the nearest ``IndicateTargetComponent``.
    public static func resolveTarget(from entity: Entity) -> IndicateTargetComponent? {
        var cursor: Entity? = entity
        while let current = cursor {
            if let component = current.components[IndicateTargetComponent.self] {
                return component
            }
            cursor = current.parent
        }
        return nil
    }

    static func poseTransform(_ pose: ViewPose3D) -> Transform {
        let quat = simd_quatf(vector: pose.orientation)
        let scale = SIMD3<Float>(repeating: pose.zoomScale)
        return Transform(scale: scale, rotation: quat, translation: -pose.focusLocal)
    }

    private static func collectEntities(
        in entity: Entity,
        into results: inout [Entity],
        matching predicate: (Entity) -> Bool
    ) {
        if predicate(entity) {
            results.append(entity)
        }
        for child in entity.children {
            collectEntities(in: child, into: &results, matching: predicate)
        }
    }

    private func populateBands(of snapshot: VolumeSnapshot, into root: Entity) {
        for slice in snapshot.bands {
            let bandEntity = Entity()
            bandEntity.name = "indicate.band.\(slice.band.rawValue)"
            var state = BandDrawState()
            for command in slice.commands {
                apply(command, state: &state, into: bandEntity)
            }
            root.addChild(bandEntity)
        }
    }

    private func apply(
        _ command: VolumeSceneCommand,
        state: inout BandDrawState,
        into bandEntity: Entity
    ) {
        switch command {
        case .save:
            state.push()
        case .restore:
            state.pop()
        case let .translate3D(dx, dy, dz):
            state.translate(SIMD3(dx, dy, dz))
        case let .rotateQuat(qx, qy, qz, qw):
            state.rotate(simd_quatf(ix: qx, iy: qy, iz: qz, r: qw))
        case let .clipBox3D(minBox, maxBox):
            state.intersectClip(localMin: minBox, localMax: maxBox)
        case let .fillColor(color):
            state.fillColor = color
        case let .stroke3D(color, radiusMeters):
            state.strokeColor = color
            state.strokeRadius = max(radiusMeters, 0.0005)
        case let .attribute(group):
            state.attributeGroup = group
        case let .targetHandle(targetId, kind, center, radiusMeters):
            let worldCenter = state.apply(point: center)
            guard state.allows(worldPoint: worldCenter) else { return }
            bandEntity.addChild(makeHandleEntity(
                targetId: targetId,
                kind: kind,
                worldCenter: worldCenter,
                rotation: state.rotation,
                radiusMeters: radiusMeters
            ))
        case let .line3D(a, b):
            let wa = state.apply(point: a)
            let wb = state.apply(point: b)
            guard state.allowsSegment(wa, wb) else { return }
            if let segment = makeSegmentEntity(
                from: wa,
                to: wb,
                radius: state.strokeRadius,
                color: state.strokeColor,
                name: "indicate.line"
            ) {
                bandEntity.addChild(segment)
            }
        case let .polyline3D(points):
            let container = Entity()
            container.name = "indicate.polyline"
            for index in 1..<points.count {
                let wa = state.apply(point: points[index - 1])
                let wb = state.apply(point: points[index])
                guard state.allowsSegment(wa, wb) else { continue }
                if let seg = makeSegmentEntity(
                    from: wa,
                    to: wb,
                    radius: state.strokeRadius,
                    color: state.strokeColor,
                    name: "indicate.polyline.segment"
                ) {
                    container.addChild(seg)
                }
            }
            if !container.children.isEmpty {
                bandEntity.addChild(container)
            }
        case let .sphere(mode, center, radiusMeters):
            let worldCenter = state.apply(point: center)
            guard state.allows(worldPoint: worldCenter) else { return }
            bandEntity.addChild(makeSphereEntity(
                mode: mode,
                worldCenter: worldCenter,
                rotation: state.rotation,
                radius: radiusMeters,
                state: state
            ))
        case let .box3D(mode, minBox, maxBox):
            let localCenter = 0.5 * (minBox + maxBox)
            let worldCenter = state.apply(point: localCenter)
            guard state.allows(worldPoint: worldCenter) else { return }
            bandEntity.addChild(makeBoxEntity(
                mode: mode,
                minBox: minBox,
                maxBox: maxBox,
                state: state
            ))
        case let .cylinder3D(mode, base, top, radiusMeters):
            let worldBase = state.apply(point: base)
            let worldTop = state.apply(point: top)
            guard state.allowsSegment(worldBase, worldTop) else { return }
            bandEntity.addChild(makeCylinderEntity(
                mode: mode,
                worldBase: worldBase,
                worldTop: worldTop,
                radius: radiusMeters,
                state: state
            ))
        case let .ring3D(center, normal, radiusMeters):
            let worldCenter = state.apply(point: center)
            guard state.allows(worldPoint: worldCenter) else { return }
            let worldNormal = simd_normalize(state.rotation.act(normal))
            bandEntity.addChild(makeRingEntity(
                worldCenter: worldCenter,
                worldNormal: worldNormal,
                radius: radiusMeters,
                tubeRadius: state.strokeRadius,
                color: state.strokeColor
            ))
        case let .heightfieldGrid(cols, rows, origin, stepX, stepZ, heights):
            if let grid = makeHeightfieldEntity(
                cols: cols,
                rows: rows,
                origin: origin,
                stepX: stepX,
                stepZ: stepZ,
                heights: heights,
                state: state
            ) {
                bandEntity.addChild(grid)
            }
        case let .underlayAnchor3D(kind, center, extent, orientation, metersPerUnit):
            let worldCenter = state.apply(point: center)
            let worldRot = simd_normalize(state.rotation * simd_quatf(vector: orientation))
            let anchor = Entity()
            anchor.name = "indicate.underlay.\(kind.rawValue)"
            anchor.transform = Transform(
                scale: .one,
                rotation: worldRot,
                translation: worldCenter
            )
            anchor.components.set(IndicateUnderlayAnchorComponent(
                kind: kind,
                centerLocal: worldCenter,
                extentMeters: extent,
                orientation: worldRot.vector,
                metersPerUnit: metersPerUnit
            ))
            bandEntity.addChild(anchor)
        case let .billboardText(position, sizeMeters, anchor, text):
            let worldPos = state.apply(point: position)
            guard state.allows(worldPoint: worldPos) else { return }
            bandEntity.addChild(makeBillboardEntity(
                worldPosition: worldPos,
                rotation: state.rotation,
                sizeMeters: sizeMeters,
                anchor: anchor,
                text: text,
                color: state.fillColor,
                attributeGroup: state.attributeGroup
            ))
        case .beginBand, .endBand, .unknown:
            break
        }
    }
}

// MARK: - Primitive & Failure Cage Helpers

@MainActor
private extension RealityVolumeBuilder {
    struct BandDrawState {
        struct Saved {
            let translation: SIMD3<Float>
            let rotation: simd_quatf
            let clipBox: (min: SIMD3<Float>, max: SIMD3<Float>)?
            let fillColor: SceneColor
            let strokeColor: SceneColor
            let strokeRadius: Float
            let attributeGroup: UInt8?
        }

        var translation = SIMD3<Float>.zero
        var rotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var clipBox: (min: SIMD3<Float>, max: SIMD3<Float>)?
        var fillColor = SceneColor(red: 255, green: 255, blue: 255, alpha: 255)
        var strokeColor = SceneColor(red: 255, green: 255, blue: 255, alpha: 255)
        var strokeRadius: Float = 0.002
        var attributeGroup: UInt8?
        private var stack: [Saved] = []

        mutating func push() {
            stack.append(Saved(
                translation: translation,
                rotation: rotation,
                clipBox: clipBox,
                fillColor: fillColor,
                strokeColor: strokeColor,
                strokeRadius: strokeRadius,
                attributeGroup: attributeGroup
            ))
        }

        mutating func pop() {
            guard let prev = stack.popLast() else { return }
            translation = prev.translation
            rotation = prev.rotation
            clipBox = prev.clipBox
            fillColor = prev.fillColor
            strokeColor = prev.strokeColor
            strokeRadius = prev.strokeRadius
            attributeGroup = prev.attributeGroup
        }

        mutating func translate(_ delta: SIMD3<Float>) {
            translation += rotation.act(delta)
        }

        mutating func rotate(_ delta: simd_quatf) {
            rotation = simd_normalize(rotation * delta)
        }

        func apply(point: SIMD3<Float>) -> SIMD3<Float> {
            translation + rotation.act(point)
        }

        mutating func intersectClip(localMin: SIMD3<Float>, localMax: SIMD3<Float>) {
            let corners = [
                SIMD3(localMin.x, localMin.y, localMin.z),
                SIMD3(localMax.x, localMin.y, localMin.z),
                SIMD3(localMin.x, localMax.y, localMin.z),
                SIMD3(localMax.x, localMax.y, localMin.z),
                SIMD3(localMin.x, localMin.y, localMax.z),
                SIMD3(localMax.x, localMin.y, localMax.z),
                SIMD3(localMin.x, localMax.y, localMax.z),
                SIMD3(localMax.x, localMax.y, localMax.z),
            ].map(apply(point:))
            var wMin = corners[0]
            var wMax = corners[0]
            for c in corners.dropFirst() {
                wMin = simd_min(wMin, c)
                wMax = simd_max(wMax, c)
            }
            if let existing = clipBox {
                clipBox = (simd_max(existing.min, wMin), simd_min(existing.max, wMax))
            } else {
                clipBox = (wMin, wMax)
            }
        }

        func allows(worldPoint p: SIMD3<Float>) -> Bool {
            guard let clip = clipBox else { return true }
            return p.x >= clip.min.x && p.x <= clip.max.x
                && p.y >= clip.min.y && p.y <= clip.max.y
                && p.z >= clip.min.z && p.z <= clip.max.z
        }

        func allowsSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            guard let clip = clipBox else { return true }
            let segMin = simd_min(a, b)
            let segMax = simd_max(a, b)
            return segMax.x >= clip.min.x && segMin.x <= clip.max.x
                && segMax.y >= clip.min.y && segMin.y <= clip.max.y
                && segMax.z >= clip.min.z && segMin.z <= clip.max.z
        }
    }

    func makeHandleEntity(
        targetId: UInt32,
        kind: HandleKind,
        worldCenter: SIMD3<Float>,
        rotation: simd_quatf,
        radiusMeters: Float
    ) -> Entity {
        let entity = Entity()
        entity.name = "indicate.handle.\(targetId)"
        entity.transform = Transform(scale: .one, rotation: rotation, translation: worldCenter)
        let shape = ShapeResource.generateSphere(radius: radiusMeters)
        entity.components.set(CollisionComponent(shapes: [shape]))
        #if os(visionOS)
        entity.components.set(InputTargetComponent())
        #endif
        entity.components.set(IndicateTargetComponent(
            targetId: TargetId(rawValue: targetId),
            kind: kind,
            centerLocal: worldCenter,
            radiusMeters: radiusMeters
        ))
        return entity
    }

    func makeSegmentEntity(
        from a: SIMD3<Float>,
        to b: SIMD3<Float>,
        radius: Float,
        color: SceneColor,
        name: String
    ) -> Entity? {
        let delta = b - a
        let length = simd_length(delta)
        guard length.isFinite, length > 1e-6 else { return nil }
        let midpoint = 0.5 * (a + b)
        let orientation = Self.quatFromYAxis(to: delta / length)
        let entity = ModelEntity(mesh: unitCylinder, materials: [makeMaterial(color)])
        entity.name = name
        entity.transform = Transform(
            scale: SIMD3(radius, length, radius),
            rotation: orientation,
            translation: midpoint
        )
        return entity
    }

    func makeSphereEntity(
        mode: PaintMode,
        worldCenter: SIMD3<Float>,
        rotation: simd_quatf,
        radius: Float,
        state: BandDrawState
    ) -> Entity {
        let root = Entity()
        root.name = "indicate.sphere"
        root.transform = Transform(scale: .one, rotation: rotation, translation: worldCenter)
        if mode == .fill || mode == .fillStroke {
            let fill = ModelEntity(mesh: unitSphere, materials: [makeMaterial(state.fillColor)])
            fill.scale = SIMD3(repeating: radius)
            root.addChild(fill)
        }
        if mode == .stroke || mode == .fillStroke {
            let axes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
            for axis in axes {
                root.addChild(makeRingEntity(
                    worldCenter: .zero,
                    worldNormal: axis,
                    radius: radius,
                    tubeRadius: state.strokeRadius,
                    color: state.strokeColor
                ))
            }
        }
        return root
    }

    func makeBoxEntity(
        mode: PaintMode,
        minBox: SIMD3<Float>,
        maxBox: SIMD3<Float>,
        state: BandDrawState
    ) -> Entity {
        let localCenter = 0.5 * (minBox + maxBox)
        let rawSize = maxBox - minBox
        let safeSize = SIMD3(
            max(rawSize.x, 1e-4),
            max(rawSize.y, 1e-4),
            max(rawSize.z, 1e-4)
        )
        let root = Entity()
        root.name = "indicate.box"
        root.transform = Transform(
            scale: .one,
            rotation: state.rotation,
            translation: state.apply(point: localCenter)
        )
        if mode == .fill || mode == .fillStroke {
            let fill = ModelEntity(mesh: unitBox, materials: [makeMaterial(state.fillColor)])
            fill.scale = safeSize
            root.addChild(fill)
        }
        if mode == .stroke || mode == .fillStroke {
            let half = 0.5 * safeSize
            addWireframeBoxEdges(
                halfExtent: half,
                radius: state.strokeRadius,
                color: state.strokeColor,
                into: root
            )
        }
        return root
    }

    func makeCylinderEntity(
        mode: PaintMode,
        worldBase: SIMD3<Float>,
        worldTop: SIMD3<Float>,
        radius: Float,
        state: BandDrawState
    ) -> Entity {
        let delta = worldTop - worldBase
        let rawLength = simd_length(delta)
        let height = max(rawLength, 1e-4)
        let dir = rawLength > 1e-6 ? (delta / rawLength) : SIMD3<Float>(0, 1, 0)
        let midpoint = 0.5 * (worldBase + worldTop)
        let orientation = Self.quatFromYAxis(to: dir)

        let root = Entity()
        root.name = "indicate.cylinder"
        root.transform = Transform(scale: .one, rotation: orientation, translation: midpoint)
        if mode == .fill || mode == .fillStroke {
            let fill = ModelEntity(
                mesh: unitCylinder,
                materials: [makeMaterial(state.fillColor)]
            )
            fill.scale = SIMD3(radius, height, radius)
            root.addChild(fill)
        }
        if mode == .stroke || mode == .fillStroke {
            let halfH = 0.5 * height
            root.addChild(makeRingEntity(
                worldCenter: SIMD3(0, -halfH, 0),
                worldNormal: SIMD3(0, 1, 0),
                radius: radius,
                tubeRadius: state.strokeRadius,
                color: state.strokeColor
            ))
            root.addChild(makeRingEntity(
                worldCenter: SIMD3(0, halfH, 0),
                worldNormal: SIMD3(0, 1, 0),
                radius: radius,
                tubeRadius: state.strokeRadius,
                color: state.strokeColor
            ))
        }
        return root
    }

    func makeRingEntity(
        worldCenter: SIMD3<Float>,
        worldNormal: SIMD3<Float>,
        radius: Float,
        tubeRadius: Float,
        color: SceneColor
    ) -> Entity {
        let ring = Entity()
        ring.name = "indicate.ring"
        ring.transform = Transform(
            scale: .one,
            rotation: Self.quatFromYAxis(to: worldNormal),
            translation: worldCenter
        )
        let step = (2.0 * Float.pi) / Float(ringSegments)
        for index in 0..<ringSegments {
            let a0 = Float(index) * step
            let a1 = Float(index + 1) * step
            let p0 = SIMD3(cos(a0) * radius, 0, sin(a0) * radius)
            let p1 = SIMD3(cos(a1) * radius, 0, sin(a1) * radius)
            if let seg = makeSegmentEntity(
                from: p0,
                to: p1,
                radius: tubeRadius,
                color: color,
                name: "indicate.ring.segment"
            ) {
                ring.addChild(seg)
            }
        }
        return ring
    }

    func makeHeightfieldEntity(
        cols: UInt8,
        rows: UInt8,
        origin: SIMD3<Float>,
        stepX: Float,
        stepZ: Float,
        heights: [Float],
        state: BandDrawState
    ) -> Entity? {
        let colCount = Int(cols)
        let rowCount = Int(rows)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(colCount * rowCount)
        for row in 0..<rowCount {
            for col in 0..<colCount {
                let y = heights[row * colCount + col]
                positions.append(SIMD3(
                    origin.x + Float(col) * stepX,
                    origin.y + y,
                    origin.z + Float(row) * stepZ
                ))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((colCount - 1) * (rowCount - 1) * 12)
        for row in 0..<(rowCount - 1) {
            for col in 0..<(colCount - 1) {
                let i00 = UInt32(row * colCount + col)
                let i10 = i00 + 1
                let i01 = UInt32((row + 1) * colCount + col)
                let i11 = i01 + 1
                // Front and back winding keep the surface visible from all angles.
                indices.append(contentsOf: [i00, i01, i10, i10, i01, i11])
                indices.append(contentsOf: [i00, i10, i01, i10, i11, i01])
            }
        }
        var descriptor = MeshDescriptor(name: "indicate.heightfield")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else {
            return nil
        }
        let entity = ModelEntity(mesh: mesh, materials: [makeMaterial(state.fillColor)])
        entity.name = "indicate.heightfield"
        entity.transform = Transform(
            scale: .one,
            rotation: state.rotation,
            translation: state.translation
        )
        return entity
    }

    func makeBillboardEntity(
        worldPosition: SIMD3<Float>,
        rotation: simd_quatf,
        sizeMeters: Float,
        anchor: TextAnchor,
        text: String,
        color: SceneColor,
        attributeGroup: UInt8?
    ) -> Entity {
        let root = Entity()
        root.name = "indicate.billboard"
        root.transform = Transform(scale: .one, rotation: rotation, translation: worldPosition)
        root.components.set(IndicateBillboardComponent(
            text: text,
            sizeMeters: sizeMeters,
            anchor: anchor,
            color: color,
            attributeGroup: attributeGroup
        ))

        let glyphCount = max(text.unicodeScalars.count, 1)
        let aspect = Float(glyphCount) * 0.65
        let widthMeters = max(sizeMeters * aspect, sizeMeters)
        let offsetX: Float = switch anchor {
        case .left: 0.5 * widthMeters
        case .center: 0.0
        case .right: -0.5 * widthMeters
        }

        let card = ModelEntity(
            mesh: unitPlane,
            materials: [makeBillboardMaterial(text: text, color: color)]
        )
        // Rotate unitPlane (XZ by default in RealityKit) by +90 deg around X to face +Z.
        let upright = simd_quatf(angle: 0.5 * .pi, axis: SIMD3(1, 0, 0))
        card.transform = Transform(
            scale: SIMD3(widthMeters, 1.0, sizeMeters),
            rotation: upright,
            translation: SIMD3(offsetX, 0.5 * sizeMeters, 0)
        )
        root.addChild(card)
        return root
    }

    func populateFailureCage(
        reason: DisplayReason,
        extent: Extent3D,
        into root: Entity
    ) {
        let safeW = max(extent.widthMeters.isFinite ? extent.widthMeters : 0.5, 0.2)
        let safeH = max(extent.heightMeters.isFinite ? extent.heightMeters : 0.4, 0.2)
        let safeD = max(extent.depthMeters.isFinite ? extent.depthMeters : 0.5, 0.2)
        let half = 0.5 * SIMD3(safeW, safeH, safeD)
        let red = SceneColor(red: 255, green: 32, blue: 32, alpha: 255)
        let barRadius = max(min(safeW, min(safeH, safeD)) * 0.012, 0.003)

        addWireframeBoxEdges(halfExtent: half, radius: barRadius, color: red, into: root)

        let diagA0 = SIMD3(-half.x, -half.y, half.z)
        let diagA1 = SIMD3(half.x, half.y, -half.z)
        let diagB0 = SIMD3(-half.x, half.y, half.z)
        let diagB1 = SIMD3(half.x, -half.y, -half.z)
        if let barA = makeSegmentEntity(
            from: diagA0,
            to: diagA1,
            radius: barRadius * 1.4,
            color: red,
            name: "indicate.failure.crossA"
        ) {
            root.addChild(barA)
        }
        if let barB = makeSegmentEntity(
            from: diagB0,
            to: diagB1,
            radius: barRadius * 1.4,
            color: red,
            name: "indicate.failure.crossB"
        ) {
            root.addChild(barB)
        }

        let plaqueHeight = max(safeH * 0.10, 0.028)
        let plaque = makeBillboardEntity(
            worldPosition: SIMD3(0, 0, half.z),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            sizeMeters: plaqueHeight,
            anchor: .center,
            text: "DISPLAY FAIL \(reason.label)",
            color: red,
            attributeGroup: nil
        )
        plaque.name = "indicate.failure.plaque"
        root.addChild(plaque)
    }

    func addWireframeBoxEdges(
        halfExtent h: SIMD3<Float>,
        radius: Float,
        color: SceneColor,
        into parent: Entity
    ) {
        let c000 = SIMD3(-h.x, -h.y, -h.z)
        let c100 = SIMD3(h.x, -h.y, -h.z)
        let c010 = SIMD3(-h.x, h.y, -h.z)
        let c110 = SIMD3(h.x, h.y, -h.z)
        let c001 = SIMD3(-h.x, -h.y, h.z)
        let c101 = SIMD3(h.x, -h.y, h.z)
        let c011 = SIMD3(-h.x, h.y, h.z)
        let c111 = SIMD3(h.x, h.y, h.z)
        let edges: [(SIMD3<Float>, SIMD3<Float>)] = [
            (c000, c100), (c100, c110), (c110, c010), (c010, c000),
            (c001, c101), (c101, c111), (c111, c011), (c011, c001),
            (c000, c001), (c100, c101), (c110, c111), (c010, c011),
        ]
        for (a, b) in edges {
            if let edge = makeSegmentEntity(
                from: a,
                to: b,
                radius: radius,
                color: color,
                name: "indicate.box.edge"
            ) {
                parent.addChild(edge)
            }
        }
    }

    func makeMaterial(_ color: SceneColor) -> UnlitMaterial {
        let r = CGFloat(color.red) / 255.0
        let g = CGFloat(color.green) / 255.0
        let b = CGFloat(color.blue) / 255.0
        #if canImport(UIKit)
        let platformColor = UIColor(red: r, green: g, blue: b, alpha: 1.0)
        #elseif canImport(AppKit)
        let platformColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        #endif
        var material = UnlitMaterial(color: platformColor)
        if color.alpha < 255 {
            let opacity = Float(color.alpha) / 255.0
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        }
        return material
    }

    func makeBillboardMaterial(text: String, color: SceneColor) -> UnlitMaterial {
        guard let cgImage = Self.renderTextBitmap(text: text, color: color),
              let texture = try? TextureResource.generate(
                  from: cgImage,
                  options: .init(semantic: .color)
              ) else {
            return makeMaterial(color)
        }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1.0))
        return material
    }

    static func renderTextBitmap(text: String, color: SceneColor) -> CGImage? {
        let fontSize: CGFloat = 48
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let fg = CGColor(
            srgbRed: CGFloat(color.red) / 255.0,
            green: CGFloat(color.green) / 255.0,
            blue: CGFloat(color.blue) / 255.0,
            alpha: CGFloat(color.alpha) / 255.0
        )
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: fg]
        ))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let width = max(Int(ceil(bounds.width)) + 16, 32)
        let height = max(Int(ceil(bounds.height)) + 16, 32)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.textPosition = CGPoint(
            x: (CGFloat(width) - bounds.width) * 0.5 - bounds.minX,
            y: (CGFloat(height) - bounds.height) * 0.5 - bounds.minY
        )
        CTLineDraw(line, context)
        return context.makeImage()
    }

    static func quatFromYAxis(to target: SIMD3<Float>) -> simd_quatf {
        let len = simd_length(target)
        guard len.isFinite, len > 1e-6 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        let dir = target / len
        let yAxis = SIMD3<Float>(0, 1, 0)
        let dotProduct = simd_dot(yAxis, dir)
        if dotProduct > 0.9999 {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        if dotProduct < -0.9999 {
            return simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
        }
        return simd_quatf(from: yAxis, to: dir)
    }

    static func makeUnitCylinderMesh(segments: Int) -> MeshResource {
        let n = max(segments, 6)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let step = (2.0 * Float.pi) / Float(n)

        for i in 0...n {
            let angle = Float(i) * step
            let c = cos(angle)
            let s = sin(angle)
            positions.append(SIMD3(c, -0.5, s))
            normals.append(SIMD3(c, 0, s))
            positions.append(SIMD3(c, 0.5, s))
            normals.append(SIMD3(c, 0, s))
        }
        for i in 0..<n {
            let b0 = UInt32(i * 2)
            let t0 = b0 + 1
            let b1 = b0 + 2
            let t1 = b0 + 3
            indices.append(contentsOf: [b0, t0, b1, b1, t0, t1])
        }

        let bottomCenter = UInt32(positions.count)
        positions.append(SIMD3(0, -0.5, 0))
        normals.append(SIMD3(0, -1, 0))
        for i in 0...n {
            let angle = Float(i) * step
            positions.append(SIMD3(cos(angle), -0.5, sin(angle)))
            normals.append(SIMD3(0, -1, 0))
        }
        for i in 0..<n {
            let p0 = bottomCenter + 1 + UInt32(i)
            let p1 = p0 + 1
            indices.append(contentsOf: [bottomCenter, p0, p1])
        }

        let topCenter = UInt32(positions.count)
        positions.append(SIMD3(0, 0.5, 0))
        normals.append(SIMD3(0, 1, 0))
        for i in 0...n {
            let angle = Float(i) * step
            positions.append(SIMD3(cos(angle), 0.5, sin(angle)))
            normals.append(SIMD3(0, 1, 0))
        }
        for i in 0..<n {
            let p0 = topCenter + 1 + UInt32(i)
            let p1 = p0 + 1
            indices.append(contentsOf: [topCenter, p1, p0])
        }

        var descriptor = MeshDescriptor(name: "indicate.unit.cylinder")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        if let mesh = try? MeshResource.generate(from: [descriptor]) {
            return mesh
        }
        return .generateBox(size: 1.0)
    }
}
