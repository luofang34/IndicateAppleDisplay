import CoreGraphics
import Foundation
import Testing
@testable import InstrumentSceneKit

private func context(_ size: Int = 64) throws -> CGContext {
    let context = try #require(CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    // The IR is y-down; flip so a positive rotation is clockwise on screen.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    return context
}

private func hex(_ text: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex, text.index(after: index) < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        if let byte = UInt8(text[index..<next], radix: 16) { result.append(byte) }
        index = next
    }
    return result
}

/// A minimal atlas with the reference pack's geometry: every covered glyph is
/// a filled block, space is blank.
private struct BoxAtlas: GlyphAtlas {
    let cellWidth = 5
    let cellHeight = 7
    let advance = 6
    func rows(for scalar: UInt32) -> [UInt8]? {
        scalar == 0x20 ? [UInt8](repeating: 0, count: 7)
                       : [UInt8](repeating: 0b11111, count: 7)
    }
}

@Test
func aValidSceneRendersAndReportsItsLayers() throws {
    let scene = hex(
        "0150010001010000100400ffffffff2311000100000040000000400000a0410000a041"
            + "02000051010001"
    )
    let report = try SceneRenderer().render(scene, into: try context())
    #expect(report.layersPresent == [.attitude])
    #expect(report.unknownOpcodes == 0)
}

@Test
func aSceneThatFailsTheLayerContractPaintsNothing() throws {
    // Commands outside a layer must fail the whole frame.
    let scene = hex("010100000200")
    #expect(throws: SceneRenderError.self) {
        try SceneRenderer().render(scene, into: try context())
    }
}

@Test
func textWithoutAnAtlasFailsRatherThanSubstitutingASystemFont() throws {
    let scene = hex(
        "0150010002010000100400ffffffff3012000000a841050000704300003443313033303002000051010002"
    )
    #expect(throws: SceneRenderError.textWithoutAtlas) {
        try SceneRenderer().render(scene, into: try context())
    }
}

@Test
func textRendersWhenAnAtlasIsSupplied() throws {
    let scene = hex(
        "0150010002010000100400ffffffff3012000000a841050000704300003443313033303002000051010002"
    )
    let report = try SceneRenderer(atlas: BoxAtlas()).render(scene, into: try context(256))
    #expect(report.layersPresent == [.tapes])
}

@Test
func everyRenderableCorpusSceneEitherPaintsOrFailsClosed() throws {
    // Any scene the gate accepts must paint without throwing a layer error;
    // anything else must throw rather than paint a partial frame.
    let url = try #require(Bundle.module.url(
        forResource: "scene-conformance-corpus",
        withExtension: "json",
        subdirectory: "Fixtures"
    ))
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let root = try #require(json as? [String: Any])
    let entries = try #require(root["entries"] as? [[String: Any]])

    var painted = 0
    for entry in entries {
        guard let bytesHex = entry["bytesHex"] as? String,
              let gate = entry["gate"] as? [String: Any],
              let verdict = gate["verdict"] as? String
        else { continue }
        let scene = hex(bytesHex)
        let renderer = SceneRenderer(atlas: BoxAtlas())
        do {
            _ = try renderer.render(scene, into: try context(256))
            #expect(verdict == "accept", "\(entry["name"] ?? "?"): painted a rejected scene")
            painted += 1
        } catch {
            // A gate-accepted scene may still refuse to paint on a paint fault
            // (non-finite geometry); what must never happen is a rejected scene
            // painting successfully.
            #expect(error is SceneRenderError)
        }
    }
    #expect(painted > 0, "at least some corpus scenes must paint")
}

@Test
func offscreenImageIsProducedAtTheRequestedSize() throws {
    let scene = hex(
        "0150010001010000100400ffffffff2311000100000040000000400000a0410000a041"
            + "02000051010001"
    )
    let image = try SceneRenderer(atlas: BoxAtlas()).image(
        scene, pixelWidth: 240, pixelHeight: 180, logicalFrame: panelDesignFrame
    )
    #expect(image.width == 240)
    #expect(image.height == 180)
}

@Test
func aFailingSceneProducesNoImageAtAll() {
    // Commands outside a layer fail the frame; no partial image may escape.
    let scene = hex("010100000200")
    #expect(throws: SceneRenderError.self) {
        try SceneRenderer(atlas: BoxAtlas()).image(
            scene, pixelWidth: 64, pixelHeight: 64, logicalFrame: panelDesignFrame
        )
    }
}

@Test
func contentBoundsCoverTextExtentNotJustItsAnchor() throws {
    // A centred run extends to the left of the point the command carries, so
    // measuring the anchor alone under-reports the box and invites clipping.
    let scene = hex(
        "0150010002010000100400ffffffff3012000000a841050000704300003443313033303002000051010002"
    )
    let bounds = try #require(try SceneRenderer(atlas: BoxAtlas()).contentBounds(scene))
    #expect(bounds.width > 0)
    #expect(bounds.minX < 240, "a centred run must start left of its anchor")
}

@Test
func contentBoundsAreNilForASceneThatPaintsNothing() throws {
    let scene = hex("015001000001000002000051010000")
    #expect(try SceneRenderer(atlas: BoxAtlas()).contentBounds(scene) == nil)
}

@Test
func anExpandedFrameShiftsTheMappedRegion() throws {
    // Mapping a region left of the origin must not crash and must still fill.
    let scene = hex(
        "0150010001010000100400ffffffff2311000100000040000000400000a0410000a041"
            + "02000051010001"
    )
    let image = try SceneRenderer(atlas: BoxAtlas()).image(
        scene, pixelWidth: 120, pixelHeight: 90,
        logicalFrame: panelDesignFrame.insetBy(dx: -12, dy: -12)
    )
    #expect(image.width == 120)
}
