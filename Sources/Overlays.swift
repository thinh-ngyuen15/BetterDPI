import AppKit
import Metal
import QuartzCore

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }
}

/// A borderless, click-through window covering one screen above everything else
/// (CGShieldingWindowLevel), on every Space, optionally hidden from screen capture.
func makeOverlayWindow(on screen: NSScreen, hiddenFromCapture: Bool) -> NSWindow {
    let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.isReleasedWhenClosed = false
    w.animationBehavior = .none   // the default open animation leaves the frame scaled down
    w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    w.sharingType = hiddenFromCapture ? .none : .readOnly
    w.contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    w.contentView?.wantsLayer = true
    w.setFrame(screen.frame, display: false)
    return w
}

// MARK: - Compositor filter layer

/// Per-display compositor filters: a CABackdropLayer with CAFilters, applied by the window server to
/// everything behind the overlay. Zero added latency, no capture involved.
final class CompositorFilters {
    static let shared = CompositorFilters()

    struct State: Codable, Equatable {
        var enabled = false
        var hideFromCapture = true
        var settings = FilterSettings()
    }

    private struct Overlay {
        let window: NSWindow
        let backdrop: CALayer
        var screenID: CGDirectDisplayID
    }

    private let table = "compositorFilters"
    private var overlays: [String: Overlay] = [:]   // persistentKey -> overlay

    var isAvailable: Bool { BDMakeBackdropLayer() != nil && BDMakeCAFilter("colorInvert") != nil }

    func state(for key: String) -> State { Store.value(in: table, for: key) ?? State() }

    func setState(_ state: State, for display: Display, on screenID: CGDirectDisplayID) {
        Store.setValue(state, in: table, for: display.persistentKey)
        apply(state, key: display.persistentKey, screenID: screenID)
    }

    /// Show `state` without saving it (CLI previews). Never touches the app's settings.
    func preview(_ state: State, on screenID: CGDirectDisplayID) {
        apply(state, key: "preview-\(screenID)", screenID: screenID)
    }

    /// Create, update or remove overlays to match saved state and current screens.
    /// `targets` maps each display's persistentKey to the screen that shows it.
    func sync(targets: [String: CGDirectDisplayID]) {
        for (key, overlay) in overlays where targets[key] == nil {
            overlay.window.orderOut(nil)
            overlays[key] = nil
        }
        for (key, screenID) in targets {
            apply(state(for: key), key: key, screenID: screenID)
        }
    }

    func removeAll() {
        for o in overlays.values { o.window.orderOut(nil) }
        overlays.removeAll()
    }

    private func apply(_ state: State, key: String, screenID: CGDirectDisplayID) {
        let filters = state.settings.caFilters(scale: NSScreen.screen(for: screenID)?.backingScaleFactor ?? 2)
        guard state.enabled, !filters.isEmpty, let screen = NSScreen.screen(for: screenID) else {
            overlays[key]?.window.orderOut(nil)
            overlays[key] = nil
            return
        }
        var overlay: Overlay
        if let existing = overlays[key], existing.screenID == screenID {
            overlay = existing
        } else {
            overlays[key]?.window.orderOut(nil)
            guard let backdrop = BDMakeBackdropLayer() else { return }
            let window = makeOverlayWindow(on: screen, hiddenFromCapture: state.hideFromCapture)
            backdrop.frame = window.contentView!.bounds
            backdrop.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            window.contentView!.layer!.addSublayer(backdrop)
            overlay = Overlay(window: window, backdrop: backdrop, screenID: screenID)
        }
        overlay.window.sharingType = state.hideFromCapture ? .none : .readOnly
        if overlay.window.frame != screen.frame { overlay.window.setFrame(screen.frame, display: true) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.backdrop.filters = filters
        CATransaction.commit()
        overlay.window.orderFrontRegardless()
        overlays[key] = overlay
    }
}

// MARK: - Brightness upscaling

/// Software XDR/HDR brightness upscaling:
/// a full-screen extended-dynamic-range Metal layer composited with a multiply
/// blend. Its colour is a gain above 1.0, so macOS raises the panel's EDR
/// headroom and everything underneath is scaled into it.
final class BrightnessUpscaling {
    static let shared = BrightnessUpscaling()

    struct State: Codable, Equatable {
        var enabled = false
        var gain: Double = 1.5
    }

    private struct Overlay {
        let window: NSWindow
        let layer: CAMetalLayer
        var screenID: CGDirectDisplayID
    }

    private let table = "brightnessUpscaling"
    private var overlays: [String: Overlay] = [:]
    /// Requested state per overlay, so the gain can be re-clamped when headroom changes.
    private var requested: [String: State] = [:]
    private lazy var device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()

    private init() {
        // macOS reports EDR headroom changes (backlight, other EDR content) this way.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.redraw() }
    }

    /// Largest gain the screen can ever show, or nil when it has no EDR headroom.
    static func maxGain(for screenID: CGDirectDisplayID) -> Double? {
        guard let s = NSScreen.screen(for: screenID) else { return nil }
        let potential = Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue)
        return potential > 1.01 ? min(potential, 8) : nil
    }

    /// Headroom available right now. macOS only allocates it while EDR content is
    /// shown, so before the overlay appears this can still be close to 1.
    static func currentHeadroom(for screenID: CGDirectDisplayID) -> Double {
        Double(NSScreen.screen(for: screenID)?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
    }

    /// The gain actually drawn: the request, limited to the current headroom once
    /// macOS has allocated it. Gains above it would only clip highlights.
    static func effectiveGain(_ requested: Double, on screenID: CGDirectDisplayID) -> Double {
        let ceiling = maxGain(for: screenID) ?? 1
        let current = currentHeadroom(for: screenID)
        let limit = current > 1.01 ? min(current, ceiling) : ceiling
        return min(max(requested, 1), limit)
    }

    func preview(_ state: State, on screenID: CGDirectDisplayID) {
        apply(state, key: "preview-\(screenID)", screenID: screenID)
    }

    private func redraw() {
        for (key, overlay) in overlays {
            guard let state = requested[key] else { continue }
            draw(overlay.layer, gain: Self.effectiveGain(state.gain, on: overlay.screenID))
        }
    }

    func state(for key: String) -> State { Store.value(in: table, for: key) ?? State() }

    func setState(_ state: State, for display: Display, on screenID: CGDirectDisplayID) {
        Store.setValue(state, in: table, for: display.persistentKey)
        apply(state, key: display.persistentKey, screenID: screenID)
    }

    func sync(targets: [String: CGDirectDisplayID]) {
        for (key, overlay) in overlays where targets[key] == nil {
            overlay.window.orderOut(nil)
            overlays[key] = nil
        }
        for (key, screenID) in targets { apply(state(for: key), key: key, screenID: screenID) }
    }

    func removeAll() {
        for o in overlays.values { o.window.orderOut(nil) }
        overlays.removeAll()
        requested.removeAll()
    }

    private func apply(_ state: State, key: String, screenID: CGDirectDisplayID) {
        guard state.enabled, Self.maxGain(for: screenID) != nil,
              let screen = NSScreen.screen(for: screenID), let device else {
            overlays[key]?.window.orderOut(nil)
            overlays[key] = nil
            requested[key] = nil
            return
        }
        var overlay: Overlay
        if let existing = overlays[key], existing.screenID == screenID {
            overlay = existing
        } else {
            overlays[key]?.window.orderOut(nil)
            let window = makeOverlayWindow(on: screen, hiddenFromCapture: true)
            let layer = CAMetalLayer()
            layer.device = device
            layer.pixelFormat = .rgba16Float
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            layer.isOpaque = false
            layer.compositingFilter = "multiply"
            layer.frame = window.contentView!.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            window.contentView!.layer!.addSublayer(layer)
            overlay = Overlay(window: window, layer: layer, screenID: screenID)
        }
        if overlay.window.frame != screen.frame { overlay.window.setFrame(screen.frame, display: true) }
        overlay.layer.contentsScale = screen.backingScaleFactor
        // A small drawable is enough: it is a single flat colour scaled to the screen.
        overlay.layer.drawableSize = CGSize(width: 64, height: 64)
        overlay.window.orderFrontRegardless()
        draw(overlay.layer, gain: Self.effectiveGain(state.gain, on: screenID))
        overlays[key] = overlay
        requested[key] = state
    }

    private func draw(_ layer: CAMetalLayer, gain: Double) {
        guard let queue, let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: gain, green: gain, blue: gain, alpha: 1)
        commands.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

extension CompositorFilters.State {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(enabled: c.value(.enabled, or: d.enabled), hideFromCapture: c.value(.hideFromCapture, or: d.hideFromCapture),
                  settings: c.value(.settings, or: d.settings))
    }
}

extension BrightnessUpscaling.State {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        self.init(enabled: c.value(.enabled, or: d.enabled), gain: c.value(.gain, or: d.gain))
    }
}
