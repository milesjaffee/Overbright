import AppKit
import Metal
import MetalKit
import QuartzCore

// MARK: - Flat EDR colour renderer

/// Draws a single flat colour into a CAMetalLayer using nothing but the render pass
/// clear value. No shaders, no vertex buffers, no draw calls — a clear is enough and
/// it keeps the GPU cost per redraw close to zero.
final class FlatEDRLayer {

    let layer = CAMetalLayer()
    private let queue: MTLCommandQueue?
    private var lastColor: Double = .nan

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        layer.device = device
        // Half-float is required to carry component values above 1.0.
        layer.pixelFormat = .rgba16Float
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.displaySyncEnabled = true
        layer.needsDisplayOnBoundsChange = true
        layer.allowsNextDrawableTimeout = true

    }

    /// - Parameter value: linear light multiplier. 1.0 is a no-op, >1.0 asks the panel
    ///   for EDR headroom, <1.0 dims below whatever the hardware floor is.
    func render(value: Double, force: Bool = false) {
        guard let queue else { return }
        // Redrawing on every display refresh would cost battery for no reason. Only
        // touch the GPU when the number actually moved.
        if !force, abs(value - lastColor) < 0.0015 { return }

        autoreleasepool {
            guard layer.drawableSize.width > 0,
                  let drawable = layer.nextDrawable(),
                  let buffer = queue.makeCommandBuffer() else { return }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor =
                MTLClearColor(red: value, green: value, blue: value, alpha: 1.0)

            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.endEncoding()

            // Let CAMetalLayer schedule presentation normally instead of coupling this
            // screen-sized surface to unrelated AppKit damage transactions, such as
            // pointer updates.
            buffer.present(drawable)
            buffer.commit()
            lastColor = value
        }
    }

    func invalidate() { lastColor = .nan }

    func resize(to size: CGSize, scale: CGFloat) {
        layer.contentsScale = scale
        layer.frame = CGRect(origin: .zero, size: size)
        layer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        invalidate()
    }
}

// MARK: - Full-screen gain view

/// The surface that multiplies everything behind it.
///
/// This exact setup is the one that works: an MTKView whose CAMetalLayer has a white
/// background and Core Animation's `"multiply"` compositing filter. These alternatives
/// were all tested side by side and failed to multiply the windows *behind* the overlay:
/// `CIMultiplyBlendMode` and `"multiplyBlendMode"` (white boxes or a white screen, since a
/// blend mode returns the source wherever its backdrop is transparent),
/// `CIMultiplyCompositing` (no effect), and `"multiply"` on a bare layer-hosting
/// CAMetalLayer (no effect).
final class GainView: MTKView {

    private let queue: MTLCommandQueue
    private var lastValue: Double = .nan

    init?(frame: NSRect, device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        super.init(frame: frame, device: device)

        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        autoresizingMask = [.width, .height]
        framebufferOnly = true

        // Draw only when the gain moves, not on a display-link timer.
        isPaused = true
        enableSetNeedsDisplay = false

        guard let layer = layer as? CAMetalLayer else { return nil }
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        // White is the multiply identity, so anything not yet covered by a drawable
        // leaves the screen unchanged instead of blacking it out.
        layer.backgroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        layer.compositingFilter = "multiply"
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameter value: linear light multiplier. 1.0 is a no-op, >1.0 asks the panel
    ///   for EDR headroom, <1.0 dims below whatever the hardware floor is.
    func render(value: Double, force: Bool = false) {
        // Redrawing on every display refresh would cost battery for no reason. Only
        // touch the GPU when the number actually moved.
        if !force, abs(value - lastValue) < 0.0015 { return }
        clearColor = MTLClearColor(red: value, green: value, blue: value, alpha: 1.0)
        draw()
        lastValue = value
    }

    func invalidate() { lastValue = .nan }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            guard let pass = currentRenderPassDescriptor,
                  let drawable = currentDrawable,
                  let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            // The clear is the whole image; see FlatEDRLayer.
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

// MARK: - Window

/// Borderless, click-through, capture-excluded window that never takes focus.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    convenience init(frame: NSRect, level: NSWindow.Level) {
        self.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        self.level = level
        alphaValue = 1.0

        // Excluding the window from capture is what stops screenshots, QuickTime
        // recordings, Mission Control thumbnails and screen-sharing sessions from
        // coming out washed out or with a white sheet over them.
        sharingType = .none

        collectionBehavior = [
            .canJoinAllSpaces,   // survives a Space switch instead of being torn down
            .stationary,         // does not slide around during Mission Control
            .ignoresCycle,       // stays out of Cmd-Tab and window cycling
            .fullScreenNone,     // never becomes a full-screen tile of its own
            .transient           // hidden from Exposé and app switching
        ]

        // Nothing here should ever keep the machine awake or grab the cursor.
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
    }
}

// MARK: - Per-display overlay pair

/// Owns the two windows we place over one display:
///
/// * `gainWindow` covers the whole screen and multiplies everything under it.
/// * `anchorWindow` is a single pixel of very bright EDR content in a corner.
///
/// The anchor exists to solve the flicker problem at its root. macOS only grants EDR
/// headroom while EDR content is actually on screen, and it grants roughly as much as
/// the content asks for. If the only EDR content is the gain layer itself, then the
/// amount of headroom available is a function of the gain you are currently applying —
/// a feedback loop that oscillates. The anchor keeps its final displayed value at the
/// panel's potential headroom. It is below the full-screen gain window, so its input is
/// inversely compensated as gain changes; otherwise the anchor itself would be
/// multiplied past the panel's limit.
final class DisplayOverlay {

    let displayID: CGDirectDisplayID
    private let device: MTLDevice

    private var gainWindow: OverlayWindow?
    private var anchorWindow: OverlayWindow?
    private var gainView: GainView?
    private var anchorLayer: FlatEDRLayer?

    private(set) var isMounted = false

    init(displayID: CGDirectDisplayID, device: MTLDevice) {
        self.displayID = displayID
        self.device = device
    }

    // Above full-screen apps, the menu bar and system HUDs. Kept one below the
    // shielding level so screen-lock and screen-saver UI still wins.
    private static var gainLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
    }
    private static var anchorLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 2)
    }

    func mount() {
        guard !isMounted, let screen = DisplayInventory.screen(for: displayID) else { return }

        let gainView = GainView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device)
        let anchorLayer = FlatEDRLayer(device: device)
        guard let gainView, let anchorLayer else {
            Log.overlay.error("Metal layer creation failed for display \(self.displayID)")
            return
        }

        let gainWindow = OverlayWindow(frame: screen.frame, level: Self.gainLevel)
        gainWindow.contentView = gainView

        // One point in the bottom-left corner. At 2x backing scale that is a 2x2 block
        // of physical pixels, which mini-LED local dimming keeps confined to a single
        // zone. Corner rather than centre so it hides behind the Dock or a window edge.
        let anchorSize = CGSize(width: 1, height: 1)
        let anchorFrame = NSRect(origin: screen.frame.origin, size: anchorSize)
        let anchorWindow = OverlayWindow(frame: anchorFrame, level: Self.anchorLevel)
        let anchorView = NSView(frame: CGRect(origin: .zero, size: anchorSize))
        anchorView.layer = anchorLayer.layer
        anchorView.wantsLayer = true
        anchorWindow.contentView = anchorView
        anchorLayer.resize(to: anchorSize, scale: screen.backingScaleFactor)

        self.gainWindow = gainWindow
        self.anchorWindow = anchorWindow
        self.gainView = gainView
        self.anchorLayer = anchorLayer

        gainView.render(value: 1.0, force: true)
        anchorLayer.render(value: 1.0, force: true)

        anchorWindow.orderFrontRegardless()
        gainWindow.orderFrontRegardless()
        isMounted = true
        Log.overlay.info("Mounted overlay on display \(self.displayID)")
    }

    func unmount() {
        gainWindow?.orderOut(nil)
        anchorWindow?.orderOut(nil)
        gainWindow = nil
        anchorWindow = nil
        gainView = nil
        anchorLayer = nil
        isMounted = false
        Log.overlay.info("Unmounted overlay on display \(self.displayID)")
    }

    /// - Parameters:
    ///   - gain: linear multiplier to apply to the whole screen.
    ///   - anchorRequest: headroom to hold open. Pass 1.0 when no boost is wanted so
    ///     the panel is not kept in a high-power EDR state for nothing.
    func apply(gain: Double, anchorRequest: Double) {
        guard isMounted else { return }
        gainView?.render(value: gain)
        // The anchor sits below the full-screen multiply layer. Keep its final
        // displayed value fixed instead of letting it exceed requested EDR headroom
        // as the user raises brightness.
        let anchorInput = anchorRequest / max(1.0, gain)
        anchorLayer?.render(value: anchorInput)
    }

    /// Re-asserts window ordering and geometry. Cheap, and the cure for a whole family
    /// of "it stopped working after I did X" reports.
    func reassert() {
        guard isMounted, let screen = DisplayInventory.screen(for: displayID) else { return }

        if gainWindow?.frame != screen.frame {
            gainWindow?.setFrame(screen.frame, display: true)
            gainView?.invalidate()
        }
        anchorWindow?.setFrameOrigin(screen.frame.origin)

        anchorWindow?.orderFrontRegardless()
        gainWindow?.orderFrontRegardless()
    }

    func forceRedraw() {
        gainView?.invalidate()
        anchorLayer?.invalidate()
    }
}
