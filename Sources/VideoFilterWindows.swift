import AppKit
import CoreImage
import MetalKit
import ScreenCaptureKit

/// Video Filter Windows:
/// capture a display with ScreenCaptureKit, run each frame through the Core Image
/// filter chain and show it in a window. "Self-stream" covers the source display
/// itself with a click-through, full-screen filtered copy.
final class VideoFilterWindows: ObservableObject {
    static let shared = VideoFilterWindows()

    struct Config: Codable, Identifiable, Equatable {
        var id: Int
        var sourceKey: String           // Display.persistentKey
        var targetKey: String
        var selfStream = false
        var x: Double = 5, y: Double = 5, width: Double = 45, height: Double = 45   // % of target
        var alpha: Double = 100
        var clickThrough = false
        var titlebar = true
        var shadow = true
        var fps = 30                    // 0 = unlimited
        var autostart = false
        var hdr = false
        var filters = FilterSettings()
    }

    @Published private(set) var configs: [Config] = []
    @Published private(set) var running: Set<Int> = []
    @Published var lastError: String?

    /// Maps a persistentKey to the online display that shows it (set by DisplayStore).
    var resolve: (String) -> CGDirectDisplayID? = { _ in nil }

    /// False for the CLI: its windows are previews and must not touch the app's list.
    var persists = true

    private var sessions: [Int: FilterSession] = [:]
    private let defaultsKey = "videoFilterWindows"

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([Lenient<Config>].self, from: data) {
            // One unreadable entry must not drop the whole list.
            configs = saved.compactMap(\.value)
        }
        NotificationCenter.default.addObserver(forName: LUTStore.didRemoveLUT, object: nil, queue: .main) { [weak self] note in
            guard let id = note.object as? UUID else { return }
            self?.clearLUT(id)
        }
    }

    /// Stop using a LUT that was deleted from the library.
    private func clearLUT(_ id: UUID) {
        for var c in configs where c.filters.lutID == id {
            c.filters.lutID = nil
            update(c)
        }
    }

    /// Stop and remove every window that shows or captures `key` (used by "Forget").
    func removeAll(usingDisplay key: String) {
        for c in configs where c.sourceKey == key || c.targetKey == key { remove(c.id) }
    }

    @discardableResult
    func add(source: String, target: String, selfStream: Bool) -> Config {
        let id = (1...).first { n in !configs.contains { $0.id == n } }!
        var c = Config(id: id, sourceKey: source, targetKey: selfStream ? source : target)
        if selfStream {
            c.selfStream = true
            c.clickThrough = true
            c.titlebar = false
            c.shadow = false
        }
        configs.append(c)
        save()
        return c
    }

    func remove(_ id: Int) {
        stop(id)
        configs.removeAll { $0.id == id }
        save()
    }

    /// Save a changed configuration. Filter-only changes apply live; anything
    /// else restarts a running window.
    func update(_ config: Config) {
        guard let i = configs.firstIndex(where: { $0.id == config.id }) else { return }
        let old = configs[i]
        configs[i] = config
        save()
        guard let session = sessions[config.id] else { return }
        var comparable = old
        comparable.filters = config.filters
        comparable.autostart = config.autostart
        if comparable == config {
            session.filters = config.filters
        } else {
            stop(config.id)
            start(config.id)
        }
    }

    func start(_ id: Int) {
        guard sessions[id] == nil, let config = configs.first(where: { $0.id == id }) else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            lastError = "Video Filter Windows need Screen Recording permission (System Settings > Privacy & Security). Relaunch BetterDPI after granting it."
            return
        }
        guard let source = resolve(config.sourceKey), let target = resolve(config.targetKey),
              let screen = NSScreen.screen(for: target) else {
            lastError = "The source or target display of Video Filter Window \(id) is not connected."
            return
        }
        let session = FilterSession(config: config, sourceID: source, screen: screen)
        session.onStop = { [weak self, weak session] error, byUser in
            guard let self, let session, self.sessions[id] === session else { return }
            self.sessionStopped(id, error: error, byUser: byUser)
        }
        session.onFrameChange = { [weak self] rect in self?.windowMoved(id, rect: rect) }
        sessions[id] = session
        running.insert(id)
        lastError = nil
        Task { @MainActor in
            do {
                try await session.start(excludingWindowNumbers: self.windowNumbers)
                // Windows started earlier must leave this one out of their capture too.
                for other in self.sessions.values where other !== session {
                    try? await other.updateExclusions(self.windowNumbers)
                }
            } catch {
                // A newer session may already own this id (restart while starting).
                guard self.sessions[id] === session else { return }
                self.lastError = "Video Filter Window \(id): \(error.localizedDescription)"
                session.stop()
                self.sessions[id] = nil
                self.running.remove(id)
            }
        }
    }

    private var windowNumbers: Set<Int> { Set(sessions.values.compactMap(\.windowNumber)) }

    func framesRendered(_ id: Int) -> Int { sessions[id]?.framesRendered ?? 0 }

    func stop(_ id: Int) {
        sessions[id]?.stop()
        sessions[id] = nil
        running.remove(id)
    }

    func stopAll() {
        for id in Array(sessions.keys) { stop(id) }
    }

    /// Start windows marked to start automatically whose displays are online.
    func startAutostart() {
        for c in configs where c.autostart && sessions[c.id] == nil
            && resolve(c.sourceKey) != nil && resolve(c.targetKey) != nil {
            start(c.id)
        }
    }

    /// Stop windows whose displays went away.
    func sync() {
        for c in configs where sessions[c.id] != nil && (resolve(c.sourceKey) == nil || resolve(c.targetKey) == nil) {
            stop(c.id)
        }
    }

    private func sessionStopped(_ id: Int, error: Error?, byUser: Bool) {
        sessions[id] = nil
        running.remove(id)
        if let error, !byUser { lastError = "Video Filter Window \(id) stopped: \(error.localizedDescription)" }
        // Restart after an unintentional stop when the window has autostart.
        if !byUser, configs.first(where: { $0.id == id })?.autostart == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start(id) }
        }
    }

    /// Remember where the user moved or resized a window (as % of the target).
    private func windowMoved(_ id: Int, rect: NSRect) {
        guard let i = configs.firstIndex(where: { $0.id == id }), !configs[i].selfStream,
              let target = resolve(configs[i].targetKey), let screen = NSScreen.screen(for: target) else { return }
        let f = screen.frame
        configs[i].x = (rect.minX - f.minX) / f.width * 100
        configs[i].y = (rect.minY - f.minY) / f.height * 100
        configs[i].width = rect.width / f.width * 100
        configs[i].height = rect.height / f.height * 100
        save()
    }

    private func save() {
        guard persists, let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// One running Video Filter Window.
private final class FilterSession: NSObject, SCStreamOutput, SCStreamDelegate, MTKViewDelegate, NSWindowDelegate {
    var onStop: ((Error?, Bool) -> Void)?
    var onFrameChange: ((NSRect) -> Void)?

    var filters: FilterSettings {
        get { lock.withLock { _filters } }
        set { lock.withLock { _filters = newValue } }
    }

    var windowNumber: Int? { window.windowNumber > 0 ? window.windowNumber : nil }
    private(set) var framesRendered = 0

    private let config: VideoFilterWindows.Config
    private let sourceID: CGDirectDisplayID
    private let window: NSWindow
    private let view: MTKView
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext?
    private let outputColorSpace: CGColorSpace
    private let captureQueue = DispatchQueue(label: "betterdpi.videofilter.capture")
    private let lock = NSLock()
    private var _filters: FilterSettings
    private var latest: CIImage?
    private var drawPending = false
    private var stream: SCStream?
    private var display: SCDisplay?
    private var stoppedByUser = false
    private var finished = false

    init(config: VideoFilterWindows.Config, sourceID: CGDirectDisplayID, screen: NSScreen) {
        self.config = config
        self.sourceID = sourceID
        _filters = config.filters
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        ciContext = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
        let hdr = config.hdr
        outputColorSpace = CGColorSpace(name: hdr ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.sRGB)!

        let f = screen.frame
        let frame = config.selfStream ? f : NSRect(
            x: f.minX + f.width * config.x / 100, y: f.minY + f.height * config.y / 100,
            width: max(160, f.width * config.width / 100), height: max(90, f.height * config.height / 100))
        let style: NSWindow.StyleMask = config.titlebar && !config.selfStream
            ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless]
        window = NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        super.init()

        window.title = config.selfStream ? "Self-Stream + Video Filters" : "Video Filter Window \(config.id)"
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none   // keep the exact configured frame
        window.backgroundColor = .black
        window.alphaValue = CGFloat(min(max(config.alpha, 5), 100) / 100)
        window.ignoresMouseEvents = config.clickThrough || config.selfStream
        window.hasShadow = config.shadow && !config.selfStream
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = config.selfStream ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1) : .floating
        window.delegate = self
        if !config.selfStream { window.setFrame(frame, display: false) }

        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.colorPixelFormat = hdr ? .rgba16Float : .bgra8Unorm
        if hdr, let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = outputColorSpace
        }
        view.delegate = self
        window.contentView = view
    }

    @MainActor
    func start(excludingWindowNumbers others: Set<Int>) async throws {
        window.orderFrontRegardless()
        // Leave out every Video Filter Window so no window captures its own output.
        // The window server may list a new window a moment later, so retry briefly.
        var excluded = others
        if let n = windowNumber { excluded.insert(n) }
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for _ in 0..<10 where !finished && !content.windows.contains(where: { Int($0.windowID) == windowNumber }) {
            try await Task.sleep(nanoseconds: 100_000_000)
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        // Stopped while waiting: do not start capturing.
        guard !finished else { return }
        guard !content.displays.isEmpty else {
            throw DisplayError.message("macOS did not list any capturable display. Allow BetterDPI under System Settings > Privacy & Security > Screen Recording, then relaunch it.")
        }
        guard let display = content.displays.first(where: { $0.displayID == sourceID }) else {
            throw DisplayError.message("The source display is not available for capture.")
        }
        let excludedWindows = content.windows.filter { excluded.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let cfg: SCStreamConfiguration
        if config.hdr, #available(macOS 15.0, *) {
            cfg = SCStreamConfiguration(preset: .captureHDRStreamLocalDisplay)
        } else {
            cfg = SCStreamConfiguration()
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
        }
        // Capture at no more than the pixels the window shows (full size for self-stream).
        let scale = NSScreen.screen(for: sourceID)?.backingScaleFactor ?? 2
        let full = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
        let shown = window.frame.size.applying(.init(scaleX: window.backingScaleFactor, y: window.backingScaleFactor))
        let factor = min(1, max(shown.width / full.width, shown.height / full.height, 0.25))
        cfg.width = Int(full.width * factor)
        cfg.height = Int(full.height * factor)
        cfg.minimumFrameInterval = config.fps > 0 ? CMTime(value: 1, timescale: CMTimeScale(min(config.fps, 200))) : .zero
        cfg.showsCursor = !config.selfStream
        cfg.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        // Stopped while capture was starting: finish() could not see this stream.
        guard !finished else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        self.display = display
    }

    /// Re-exclude every Video Filter Window, e.g. after another one started.
    @MainActor
    func updateExclusions(_ windowNumbers: Set<Int>) async throws {
        guard let stream, let display, !finished else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        try await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: excluded))
    }

    func stop() {
        stoppedByUser = true
        finish(error: nil)
    }

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true
        stream?.stopCapture { _ in }
        stream = nil
        window.delegate = nil
        window.orderOut(nil)
        onStop?(error, stoppedByUser)
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                          as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let schedule: Bool = lock.withLock {
            latest = image
            defer { drawPending = true }
            return !drawPending
        }
        if schedule { DispatchQueue.main.async { [weak self] in self?.view.draw() } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.finish(error: error) }
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let (image, settings): (CIImage?, FilterSettings) = lock.withLock {
            drawPending = false
            return (latest, _filters)
        }
        guard let image, let ciContext, let drawable = view.currentDrawable,
              let commands = commandQueue?.makeCommandBuffer() else { return }
        let size = view.drawableSize
        let pixelsPerPoint = image.extent.width / CGFloat(max(1, NSScreen.screen(for: sourceID)?.frame.width ?? 1))
        let filtered = settings.apply(to: image, pixelsPerPoint: pixelsPerPoint,
                                      lut: LUTStore.shared.cubeParameters(for: settings.lutID))
        // Aspect-fit into the window, letterboxed with black.
        let s = min(size.width / image.extent.width, size.height / image.extent.height)
        let w = image.extent.width * s, h = image.extent.height * s
        let placed = filtered.transformed(by: CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2)))
        let output = placed.composited(over: CIImage(color: .black)).cropped(to: CGRect(origin: .zero, size: size))
        ciContext.render(output, to: drawable.texture, commandBuffer: commands,
                         bounds: CGRect(origin: .zero, size: size), colorSpace: outputColorSpace)
        commands.present(drawable)
        commands.commit()
        framesRendered += 1
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) { stop() }
    func windowDidMove(_ notification: Notification) { onFrameChange?(window.frame) }
    func windowDidEndLiveResize(_ notification: Notification) { onFrameChange?(window.frame) }
}

extension VideoFilterWindows.Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id and displays are required; everything else falls back to defaults.
        self.init(id: try c.decode(Int.self, forKey: .id), sourceKey: try c.decode(String.self, forKey: .sourceKey),
                  targetKey: try c.decode(String.self, forKey: .targetKey))
        selfStream = c.value(.selfStream, or: selfStream)
        x = c.value(.x, or: x); y = c.value(.y, or: y)
        width = c.value(.width, or: width); height = c.value(.height, or: height)
        alpha = c.value(.alpha, or: alpha)
        clickThrough = c.value(.clickThrough, or: clickThrough)
        titlebar = c.value(.titlebar, or: titlebar)
        shadow = c.value(.shadow, or: shadow)
        fps = c.value(.fps, or: fps)
        autostart = c.value(.autostart, or: autostart)
        hdr = c.value(.hdr, or: hdr)
        filters = c.value(.filters, or: filters)
    }
}
