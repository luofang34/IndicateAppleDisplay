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

/// A panel view that presents completed frames on the display cadence.
///
/// Ingest rate is decoupled from frame rate by construction: telemetry writers
/// update state, and this view submits the latest frame size once per display
/// refresh. A ``PanelRenderWorker`` produces and paints each accepted request
/// outside the main actor.
///
/// The watchdog runs on a timer rather than on the display link, so a producer
/// that stops advancing is caught even while frames keep being requested. Both
/// schedulers live on the main run loop: this detects a stalled producer, not a
/// blocked main thread. A monitor that survives a wedged UI thread must consume
/// ``PanelDisplay/health``'s snapshot from elsewhere.
@MainActor
public final class InstrumentPanelView: PlatformViewBase {
    /// The pipeline this view presents.
    ///
    /// Assigning a different pipeline switches what the view shows. A host that
    /// swaps panels does so through this rather than by building a second view,
    /// so each panel keeps its own failure latch and recovery streak across the
    /// switch instead of arriving healthy because it is new.
    public var display: PanelDisplay {
        didSet {
            guard display !== oldValue else { return }
            // The watchdog cadence belongs to the pipeline, so it is rearmed
            // rather than carried over.
            guard link != nil else { return }
            stop()
            start()
        }
    }

    /// Called after every frame attempt, for a diagnostics surface.
    public var onOutcome: ((PanelFrameOutcome) -> Void)?

    private var link: CADisplayLink?
    private var watchdog: Timer?
    private var worker: PanelRenderWorker?
    private var failureWorker: FailurePageRenderWorker?
    private var presentedFailure: FailurePresentation?
    private let proxy = DisplayLinkProxy()

    private struct FailurePresentation: Equatable {
        let pixelWidth: Int
        let pixelHeight: Int
        let scale: CGFloat
        let reason: DisplayReason
        let presentationEpoch: UInt64
    }

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
        hostLayer?.contentsGravity = .resizeAspect
        hostLayer?.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private func start() {
        guard link == nil else { return }
        worker = PanelRenderWorker(display: display)
        failureWorker = FailurePageRenderWorker()
        // A display link retains its target, so targeting the view directly
        // would keep it alive for as long as the link runs. The proxy holds
        // the view weakly and tears the link down once the view is gone.
        #if canImport(UIKit)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        #else
        let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        #endif
        let framesPerSecond = Float(max(display.requirements.preferredFramesPerSecond, 1))
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: framesPerSecond,
            maximum: framesPerSecond,
            preferred: framesPerSecond
        )
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
        worker?.invalidate()
        worker = nil
        failureWorker?.invalidate()
        failureWorker = nil
        presentedFailure = nil
    }

    // MARK: - Frames

    fileprivate func frameTick(_ link: CADisplayLink) {
        renderFrame(nowMs: link.timestamp * 1000)
    }

    fileprivate func watchdogTick() {
        let result = display.tickForPresentation(nowMs: CACurrentMediaTime() * 1000)
        // A liveness trip must cover the panel even though no frame arrived to
        // carry the cover — that is the whole point of an independent tick.
        guard result.display.showFailure else { return }
        worker?.discardOutstanding()
        cover(reason: result.display.reason, presentationEpoch: result.presentationEpoch)
    }

    private func renderFrame(nowMs: Double) {
        let scale = backingScale
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return }

        guard let worker else { return }
        worker.submit(pixelWidth: width, pixelHeight: height, nowMs: nowMs) {
            [weak self, weak worker] outcome in
            guard let self, self.worker === worker else { return }
            if let image = outcome.image {
                self.failureWorker?.discardOutstanding()
                self.present(image, scale: scale)
                self.presentedFailure = outcome.showingFailure
                    ? FailurePresentation(
                        pixelWidth: width,
                        pixelHeight: height,
                        scale: scale,
                        reason: outcome.reason,
                        presentationEpoch: outcome.presentationEpoch
                    )
                    : nil
            }
            self.onOutcome?(outcome)
        }
    }

    private func cover(reason: DisplayReason, presentationEpoch: UInt64) {
        let scale = backingScale
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        let presentation = FailurePresentation(
            pixelWidth: width,
            pixelHeight: height,
            scale: scale,
            reason: reason,
            presentationEpoch: presentationEpoch
        )
        guard width > 0,
              height > 0,
              presentation != presentedFailure,
              let failureWorker else { return }
        failureWorker.submit(pixelWidth: width, pixelHeight: height, reason: reason) {
            [weak self, weak failureWorker] result in
            guard let self,
                  self.failureWorker === failureWorker,
                  result.pixelWidth == presentation.pixelWidth,
                  result.pixelHeight == presentation.pixelHeight,
                  result.reason == presentation.reason else { return }
            let didPresent = self.display.presentFailureIfCurrent(
                epoch: presentation.presentationEpoch,
                reason: presentation.reason
            ) {
                self.present(result.image, scale: presentation.scale)
                self.presentedFailure = presentation
            }
            guard didPresent else { return }
        }
    }

    private func present(_ image: CGImage, scale: CGFloat) {
        guard let hostLayer else { return }
        hostLayer.contentsScale = scale
        hostLayer.contents = image
    }

    /// UIKit hands back a layer, AppKit an optional one. Widening to the
    /// optional lets the rest of this view read the same on both.
    private var hostLayer: CALayer? { layer }

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
