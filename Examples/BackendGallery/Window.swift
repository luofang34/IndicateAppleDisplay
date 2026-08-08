#if os(macOS)
import AppKit
import Foundation
import IndicateAppleDisplay

/// Quits when the gallery window closes; the executable has no other purpose.
private final class GalleryDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}

/// Shows one row per case in a scrollable window.
///
/// The window is a viewer only: every image arrives already rendered by the
/// gallery cases, so a covered panel here is the same failure page an
/// operational host would show.
@MainActor
func showGalleryWindow(_ items: [GalleryItem], corpus: CorpusFile) {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = GalleryDelegate()
    application.delegate = delegate

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 20
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

    let header = NSTextField(wrappingLabelWithString:
        "IndicateAppleDisplay backend gallery\n"
            + "IR v\(SceneBackend.formatVersion), corpus v\(corpus.corpusVersion)\n"
            + "digest \(corpus.corpusSha256)"
    )
    header.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    stack.addArrangedSubview(header)

    for item in items {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 16
        row.alignment = .top

        let imageView = NSImageView()
        imageView.image = NSImage(cgImage: item.image, size: .zero)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 480),
            imageView.heightAnchor.constraint(equalToConstant: 360),
        ])
        row.addArrangedSubview(imageView)

        let reason = item.reason == .ok ? "ok" : item.reason.label
        let text = NSTextField(wrappingLabelWithString:
            "\(item.name) — \(reason)\n\(item.detail)\n\(metadata(item))"
        )
        text.font = .systemFont(ofSize: 13)
        text.maximumNumberOfLines = 0
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        row.addArrangedSubview(text)

        stack.addArrangedSubview(row)
    }

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = stack
    // The clip view is the AppKit layout anchor: pin the document to its
    // leading, top, and width, and the document scrolls vertically.
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "IndicateAppleDisplay backend gallery"
    window.contentView = scroll
    window.center()
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)
    application.run()
}
#endif
