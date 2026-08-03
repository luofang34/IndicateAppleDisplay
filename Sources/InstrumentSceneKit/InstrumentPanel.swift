#if canImport(SwiftUI)
import SwiftUI

/// SwiftUI presentation of a ``PanelDisplay``.
///
/// The display object is owned by the caller and is not recreated when SwiftUI
/// re-evaluates the body. That is deliberate: the pipeline holds the failure
/// latch, the recovery streak, and the glyph outline cache, and rebuilding it
/// on a state change would silently dismiss a latched fault and rebuild every
/// glyph.
public struct InstrumentPanel {
    private let display: PanelDisplay
    private let onOutcome: ((PanelFrameOutcome) -> Void)?

    public init(
        display: PanelDisplay,
        onOutcome: ((PanelFrameOutcome) -> Void)? = nil
    ) {
        self.display = display
        self.onOutcome = onOutcome
    }

    @MainActor
    private func makeView() -> InstrumentPanelView {
        let view = InstrumentPanelView(display: display)
        view.onOutcome = onOutcome
        return view
    }
}

#if canImport(UIKit)
extension InstrumentPanel: UIViewRepresentable {
    public func makeUIView(context: Context) -> InstrumentPanelView { makeView() }

    public func updateUIView(_ view: InstrumentPanelView, context: Context) {
        view.onOutcome = onOutcome
    }
}
#elseif canImport(AppKit)
extension InstrumentPanel: NSViewRepresentable {
    public func makeNSView(context: Context) -> InstrumentPanelView { makeView() }

    public func updateNSView(_ view: InstrumentPanelView, context: Context) {
        view.onOutcome = onOutcome
    }
}
#endif

#endif
