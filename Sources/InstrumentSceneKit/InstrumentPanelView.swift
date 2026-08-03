import CoreGraphics
import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit
/// The platform's view base class.
public typealias PlatformViewBase = UIView
#elseif canImport(AppKit)
import AppKit
/// The platform's view base class.
public typealias PlatformViewBase = NSView
#endif

#if canImport(UIKit) || canImport(AppKit)

/// A panel view that repaints on the display's own cadence.
///
/// Ingest rate is decoupled from frame rate by construction: telemetry writers
/// update state, and this view asks its ``PanelDisplay`` for a frame once per
/// display refresh. Repainting per arriving packet — the pattern this exists
/// to avoid — ties display work to link traffic, so a chatty link burns frames
/// redrawing identical content and a quiet one leaves the display unattended.
///
/// The watchdog runs on a timer rather than on the display link, so a producer
/// that stops advancing is caught even while frames keep being requested. Both
/// schedulers live on the main run loop: this detects a stalled producer, not a
/// blocked main thread. A monitor that survives a wedged UI thread must consume
/// ``PanelDisplay/health``'s snapshot from elsewhere.
@MainActor
public final class InstrumentPanelView: PlatformViewBase {
    /// The pipeline this view presents.
    public let display: PanelDisplay
    /// Called after every frame attempt, for a diagnostics surface.
    public var onOutcome: ((PanelFrameOutcome) -> Void)?

    private var link: CADisplayLink?
    private var watchdog: Timer?
    private let proxy = DisplayLinkProxy()

    public init(display: PanelDisplay) {
        self.display = display
        super.init(frame: .zero)
        proxy.view = self
        configureLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InstrumentPanelView is created in code")
    }

    // MARK: - Lifecycle

    #if canImport(UIKit)
    override public func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
    }
    #else
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : start()
    }
    #endif

    private func configureLayer() {
        #if canImport(AppKit) && !canImport(UIKit)
        wantsLayer = true
        #endif
        // Never stretch an instrument. If a stale image is briefly shown across
        // a resize, letterboxing keeps its geometry truthful.
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private func start() {
        guard link == nil else { return }
        // A display link retains its target, so targeting the view directly
        // would keep it alive for as long as the link runs. The proxy holds
        // the view weakly and tears the link down once the view is gone.
        #if canImport(UIKit)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        #else
        let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link

        let watchdog = Timer(
            timeInterval: display.health.policy.tickIntervalMs / 1000,
            target: proxy,
            selector: #selector(DisplayLinkProxy.watchdogTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    private func stop() {
        link?.invalidate()
        link = nil
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: - Frames

    fileprivate func frameTick(_ link: CADisplayLink) {
        renderFrame(nowMs: link.timestamp * 1000)
    }

    fileprivate func watchdogTick() {
        let result = display.tick(nowMs: CACurrentMediaTime() * 1000)
        // A liveness trip must cover the panel even though no frame arrived to
        // carry the cover — that is the whole point of an independent tick.
        guard result.showFailure else { return }
        cover(reason: result.reason)
    }

    private func renderFrame(nowMs: Double) {
        let scale = backingScale
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return }

        let outcome = display.render(pixelWidth: width, pixelHeight: height, nowMs: nowMs)
        if let image = outcome.image {
            present(image, scale: scale)
        }
        onOutcome?(outcome)
    }

    private func cover(reason: DisplayReason) {
        let scale = backingScale
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let image = FailurePage.image(
                  pixelWidth: width, pixelHeight: height, reason: reason
              )
        else { return }
        present(image, scale: scale)
    }

    private func present(_ image: CGImage, scale: CGFloat) {
        guard let layer else { return }
        layer.contentsScale = scale
        layer.contents = image
    }

    private var backingScale: CGFloat {
        #if canImport(UIKit)
        window?.screen.scale ?? traitCollection.displayScale
        #else
        window?.backingScaleFactor ?? 2
        #endif
    }
}

/// Holds the view weakly so a running display link or timer cannot keep it
/// alive, and tears its own scheduler down once the view is gone.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var view: InstrumentPanelView?

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.frameTick(link)
    }

    @objc func watchdogTick(_ timer: Timer) {
        guard let view else {
            timer.invalidate()
            return
        }
        view.watchdogTick()
    }
}

#endif
