import Foundation

/// Enforces the layered-scene contract before anything becomes visible.
///
/// Structural corruption, ordering violations, state leaks, and budget
/// violations all fail the whole frame. A backend must run this, or enforce the
/// same rules, so a validated scene cannot paint a lower criticality band over
/// a higher one on any conforming consumer.
public enum SceneValidator {
    /// Validates the contract and reports what the scene contains.
    public static func validate(_ bytes: [UInt8]) throws(SceneLayerError) -> SceneLayerReport {
        guard bytes.count <= SceneBudget.maxSceneBytes else {
            throw SceneLayerError.sceneTooLarge(bytes: bytes.count)
        }
        var walk = Walk()
        var decoder: SceneDecoder
        do {
            decoder = try SceneDecoder(bytes)
        } catch {
            throw SceneLayerError.decode(error)
        }
        while true {
            let command: SceneCommand?
            do {
                command = try decoder.next()
            } catch {
                throw SceneLayerError.decode(error)
            }
            guard let command else { break }
            try walk.accept(command)
        }
        return try walk.finish()
    }
}

/// The layer state machine, kept separate so the rules read in one place.
private struct Walk {
    /// Where a layer is relative to its mandatory outer save/restore envelope.
    private enum Isolation {
        case awaitingSave
        case active
        case closed
    }

    private struct OpenLayer {
        let id: SceneLayer
        var depth = 0
        var isolation = Isolation.awaitingSave
    }

    private var open: OpenLayer?
    private var lastOpened: SceneLayer?
    private var present: [SceneLayer] = []
    private var commands = [Int](repeating: 0, count: SceneLayer.allCases.count)
    private var unknown = 0

    mutating func accept(_ command: SceneCommand) throws(SceneLayerError) {
        switch command {
        case let .beginLayer(layer):
            try openLayer(layer)
        case let .endLayer(layer):
            try closeLayer(layer)
        default:
            guard open != nil else { throw SceneLayerError.commandOutsideLayer }
            try record(command)
        }
    }

    mutating func finish() throws(SceneLayerError) -> SceneLayerReport {
        if let open {
            throw SceneLayerError.unclosedLayer(open.id)
        }
        return SceneLayerReport(
            layersPresent: present,
            layerCommands: commands,
            unknownOpcodes: unknown
        )
    }

    private mutating func openLayer(_ layer: SceneLayer) throws(SceneLayerError) {
        if open != nil { throw SceneLayerError.nestedLayer(layer) }
        if present.contains(layer) { throw SceneLayerError.duplicateLayer(layer) }
        if let lastOpened, layer <= lastOpened { throw SceneLayerError.outOfOrder(layer) }
        lastOpened = layer
        open = OpenLayer(id: layer)
    }

    private mutating func closeLayer(_ layer: SceneLayer) throws(SceneLayerError) {
        guard let inside = open else { throw SceneLayerError.endWithoutBegin(layer) }
        guard inside.id == layer else {
            throw SceneLayerError.endMismatch(open: inside.id, end: layer)
        }
        guard inside.isolation == .closed, inside.depth == 0 else {
            throw SceneLayerError.unbalancedState(inside.id)
        }
        open = nil
        present.append(layer)
    }

    private mutating func record(_ command: SceneCommand) throws(SceneLayerError) {
        guard var inside = open else { throw SceneLayerError.commandOutsideLayer }
        switch command {
        case .save:
            if inside.isolation == .closed {
                throw SceneLayerError.unisolatedState(inside.id)
            }
            let depth = inside.depth + 1
            guard depth <= SceneBudget.maxStackDepth else {
                throw SceneLayerError.stackOverCapacity(layer: inside.id, depth: depth)
            }
            inside.depth = depth
            inside.isolation = .active
        case .restore:
            guard inside.isolation == .active, inside.depth > 0 else {
                throw SceneLayerError.unbalancedState(inside.id)
            }
            inside.depth -= 1
            if inside.depth == 0 { inside.isolation = .closed }
        default:
            // Every drawing command must sit inside the envelope, so a lower
            // band cannot leak transform, clip, or paint state upward.
            guard inside.isolation == .active else {
                throw SceneLayerError.unisolatedState(inside.id)
            }
        }
        open = inside

        let index = Int(inside.id.rawValue)
        guard commands[index] < SceneBudget.maxLayerCommands else {
            throw SceneLayerError.overCapacity(inside.id)
        }
        commands[index] += 1
        if case .unknown = command { unknown += 1 }
    }
}
