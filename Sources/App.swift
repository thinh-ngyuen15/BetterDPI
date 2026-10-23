import AppKit
import ServiceManagement
import SwiftUI

/// When BetterDPI shows a Dock icon. It is a menu-bar app, so by default the
/// icon only appears while one of its windows (the filters window) is open.
enum DockIcon: String, CaseIterable, Identifiable {
    case never, whileWindowOpen, always

    static let defaultsKey = "dockIcon"
    static var windowOpen = false { didSet { update() } }

    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: return "Never"
        case .whileWindowOpen: return "While a window is open"
        case .always: return "Always"
        }
    }

    static var current: DockIcon {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(DockIcon.init(rawValue:)) ?? .whileWindowOpen
    }

    /// Show or hide the Dock icon to match the setting and open windows.
    static func update() {
        let show = current == .always || (current == .whileWindowOpen && windowOpen)
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Becoming a regular app does not bring its window forward by itself.
        if show && windowOpen { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Display add/remove/mode/mirror changes. A named function so it can be unregistered.
private let displayReconfigured: CGDisplayReconfigurationCallBack = { _, flags, _ in
    if flags.contains(.beginConfigurationFlag) { return }
    DispatchQueue.main.async { DisplayStore.shared.scheduleRefresh() }
}

final class DisplayStore: ObservableObject {
    static let shared = DisplayStore()

    @Published private(set) var displays: [Display] = []
    @Published var lastError: String?
    @Published var showAllModes = UserDefaults.standard.bool(forKey: "showAllModes") {
        didSet { UserDefaults.standard.set(showAllModes, forKey: "showAllModes") }
    }
    @Published private(set) var safeMode = false
    @Published private(set) var nightShift: Bool?
    @Published private(set) var nightShiftStrength: Float = 0.5
    @Published private(set) var trueTone: Bool?
    @Published private(set) var darkMode: Bool?

    private var nameCache: [CGDirectDisplayID: String] = [:]
    private var pendingRefresh = false
    /// persistentKeys online at the last refresh, to spot newly connected displays.
    private var onlineKeys: Set<String> = []
    /// Off until launch finishes: reconciling can create virtual displays,
    /// which spins the run loop, and that must not happen inside `shared`'s
    /// initializer (the reconfiguration callback would re-enter it).
    private var reconcileEnabled = false
    /// Set while resetting all settings: nothing may write settings any more.
    private var resetting = false

    private init() {
        refresh()
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        // EDR headroom changes arrive this way; the upscaling label shows it.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Restore remembered settings (unless in safe mode) and start tracking connects.
    func start() {
        safeMode = SafeMode.isActive
        VideoFilterWindows.shared.resolve = { [weak self] key in self?.screenID(forKey: key) }
        reconcileEnabled = true
        refresh()
        refreshSystemControls()
        if !safeMode { KnownDisplays.prune(online: onlineKeys) }
    }

    func leaveSafeMode() {
        SafeMode.leave()
        safeMode = false
        onlineKeys = []   // treat every display as newly connected, so all settings are restored
        refresh()
        KnownDisplays.prune(online: onlineKeys)
    }

    func scheduleRefresh() {
        guard !pendingRefresh, !resetting else { return }
        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.pendingRefresh = false
            self.refresh()
        }
    }

    func refresh() {
        guard !resetting else { return }
        var all = Displays.snapshot(nameCache: nameCache)
        for d in all where !d.name.hasPrefix("Display ") { nameCache[d.id] = d.name }
        if reconcileEnabled {
            let before = all.map { VirtualHiDPI.shared.virtualID(for: $0.id) }
            let errors = VirtualHiDPI.shared.reconcile(displays: all)
            if !errors.isEmpty { lastError = errors.joined(separator: "\n") }
            if before != all.map({ VirtualHiDPI.shared.virtualID(for: $0.id) }) {
                all = Displays.snapshot(nameCache: nameCache)
                for d in all where !d.name.hasPrefix("Display ") { nameCache[d.id] = d.name }
            }
        }
        displays = all
        if reconcileEnabled { applyDisplaySettings() }
    }

    /// Keep overlays, dithering and video filter windows in step with the
    /// connected displays. In safe mode nothing saved is applied automatically.
    private func applyDisplaySettings() {
        KnownDisplays.touch(visibleDisplays)
        guard !SafeMode.isActive else { return }
        var targets: [String: CGDirectDisplayID] = [:]
        for d in visibleDisplays where targets[d.persistentKey] == nil { targets[d.persistentKey] = effective(d).id }
        CompositorFilters.shared.sync(targets: targets)
        BrightnessUpscaling.shared.sync(targets: targets)
        VideoFilterWindows.shared.sync()
        let appeared = Set(targets.keys).subtracting(onlineKeys)
        for d in visibleDisplays where appeared.contains(d.persistentKey) {
            do {
                try Dithering.restore(d)
            } catch {
                lastError = "\(d.name): could not restore GPU dithering (\(error.localizedDescription))."
            }
        }
        if !appeared.isEmpty { VideoFilterWindows.shared.startAutostart() }
        onlineKeys = Set(targets.keys)
    }

    /// The online display that currently shows `key`'s content (its virtual
    /// display when HiDPI virtual mode is on).
    func screenID(forKey key: String) -> CGDirectDisplayID? {
        visibleDisplays.first { $0.persistentKey == key }.map { effective($0).id }
    }

    // MARK: Per-display features

    func setCompositorFilters(_ state: CompositorFilters.State, for d: Display) {
        CompositorFilters.shared.setState(state, for: d, on: effective(d).id)
        objectWillChange.send()
    }

    func setUpscaling(_ state: BrightnessUpscaling.State, for d: Display) {
        BrightnessUpscaling.shared.setState(state, for: d, on: effective(d).id)
        objectWillChange.send()
    }

    func setDithering(_ on: Bool, for d: Display) {
        run { try Dithering.set(on, for: d.id, persistentKey: d.persistentKey) }
    }

    /// Forget every stored setting for a display and undo what is active: its
    /// HiDPI virtual screen, overlays, Video Filter Windows and a changed dithering
    /// setting (back to the macOS default, on).
    func forget(key: String) {
        if let d = visibleDisplays.first(where: { $0.persistentKey == key }) {
            VirtualHiDPI.shared.disable(for: d.id, forget: true)
            if Dithering.savedValue(for: key) == false { try? Dithering.set(true, for: d.id, persistentKey: nil) }
        }
        VideoFilterWindows.shared.removeAll(usingDisplay: key)
        Store.forget(key)
        KnownDisplays.suppress(key)   // otherwise the next refresh records it again at once
        refresh()
    }

    /// Remove every setting and the LUT library, then relaunch.
    func resetAll() {
        // Stop everything that could write settings before removing them: the
        // display changes caused by tearing down virtual screens would otherwise
        // trigger a refresh that records displays again.
        resetting = true
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, nil)
        VideoFilterWindows.shared.stopAll()
        CompositorFilters.shared.removeAll()
        BrightnessUpscaling.shared.removeAll()
        VirtualHiDPI.shared.disableAll()
        Store.resetAll()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: support.appendingPathComponent("BetterDPI"))
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "Settings were reset, but BetterDPI could not relaunch."
                    alert.informativeText = "\(error.localizedDescription)\n\nOpen BetterDPI again from its folder."
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: System controls

    func refreshSystemControls() {
        nightShift = SystemControls.nightShift
        nightShiftStrength = SystemControls.nightShiftStrength ?? nightShiftStrength
        trueTone = SystemControls.trueTone
        darkMode = SystemControls.darkMode
    }

    func setNightShift(_ on: Bool) { runSystem { try SystemControls.setNightShift(on) } }
    func setNightShiftStrength(_ s: Float) { runSystem { try SystemControls.setNightShiftStrength(s) } }
    func setTrueTone(_ on: Bool) { runSystem { try SystemControls.setTrueTone(on) } }
    func setDarkMode(_ on: Bool) { runSystem { try SystemControls.setDarkMode(on) } }

    private func runSystem(_ body: () throws -> Void) {
        do {
            try body()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshSystemControls()
    }

    /// Physical displays shown in the UI (our own virtual displays are folded
    /// into the monitor they back).
    var visibleDisplays: [Display] {
        displays.filter { !VirtualHiDPI.shared.isVirtual($0.id) }
    }

    /// The display whose modes control what the user sees: the virtual display
    /// when HiDPI virtual mode is on, otherwise the display itself.
    func effective(_ d: Display) -> Display {
        if let vid = VirtualHiDPI.shared.virtualID(for: d.id),
           let v = displays.first(where: { $0.id == vid }) {
            return v
        }
        return d
    }

    func apply(_ mode: DisplayMode, to id: CGDirectDisplayID) {
        run { try Displays.apply(mode, to: id) }
    }

    func toggleHiDPI(_ d: Display) {
        let e = effective(d)
        guard let target = e.hiDPICounterpart() else {
            lastError = "\(d.name) has no matching \(e.current?.isHiDPI == true ? "LoDPI" : "HiDPI") mode. Try the HiDPI virtual screen."
            return
        }
        apply(target, to: e.id)
    }

    func setVariableRefresh(_ d: Display, on: Bool) {
        let e = effective(d)
        guard let target = e.variableRefreshCounterpart(on: on) else {
            lastError = "\(d.name) has no \(on ? "variable" : "fixed") refresh rate at this resolution."
            return
        }
        apply(target, to: e.id)
    }

    func setVirtualHiDPI(_ d: Display, on: Bool) {
        run {
            if on {
                try VirtualHiDPI.shared.enable(for: d)
            } else if let warning = VirtualHiDPI.shared.disable(for: d.id, forget: true) {
                throw DisplayError.message(warning)
            }
        }
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}

struct DisplaySection: View {
    @ObservedObject var store: DisplayStore
    let display: Display
    @State private var showMore = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let eff = store.effective(display)
        let virtualOn = VirtualHiDPI.shared.virtualID(for: display.id) != nil
        let resolutions = Displays.resolutionChoices(eff.modes, current: eff.current, includeLoDPI: store.showAllModes)
        let rates = eff.current.map { Displays.refreshChoices(eff.modes, for: $0, includeHidden: store.showAllModes) } ?? []

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                Text(display.name).font(.headline)
                if display.isMain || eff.isMain {
                    Text("Main").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
            }
            if let cur = eff.current {
                Text("\(cur.label) · \(cur.detail)").font(.caption).foregroundStyle(.secondary)
            }

            Toggle("HiDPI", isOn: Binding(
                get: { eff.current?.isHiDPI ?? false },
                set: { _ in store.toggleHiDPI(display) }))
                .disabled(eff.hiDPICounterpart() == nil)

            if !display.isBuiltin {
                Toggle("HiDPI virtual screen", isOn: Binding(
                    get: { virtualOn },
                    set: { store.setVirtualHiDPI(display, on: $0) }))
                    .help("Mirror this monitor from a HiDPI virtual display so macOS renders at 2× and scales down.")
            }

            Picker("Resolution", selection: Binding(
                get: { resolutions.first { m in eff.current.map(m.sameResolution) ?? false }?.index ?? -1 },
                set: { index in
                    guard let m = resolutions.first(where: { $0.index == index }),
                          let cur = eff.current, !m.sameResolution(as: cur) else { return }
                    store.apply(m, to: eff.id)
                })) {
                if resolutions.isEmpty { Text("No modes").tag(Int32(-1)) }
                ForEach(resolutions) { m in
                    Text(resolutionTitle(m, markHiDPI: store.showAllModes)).tag(m.index)
                }
            }
            .pickerStyle(.menu)

            Picker("Refresh rate", selection: Binding(
                get: { eff.current?.index ?? -1 },
                set: { index in
                    guard index != eff.current?.index, let m = rates.first(where: { $0.index == index }) else { return }
                    store.apply(m, to: eff.id)
                })) {
                if rates.isEmpty { Text("Unknown").tag(Int32(-1)) }
                ForEach(rates) { m in
                    Text(m.isHidden ? "\(m.refreshLabel) (hidden)" : m.refreshLabel).tag(m.index)
                }
            }
            .pickerStyle(.menu)
            .disabled(rates.count < 2)
            .help(rates.count < 2 ? "This resolution offers a single refresh rate." : "Refresh rates available at the current resolution.")

            if eff.supportsVariableRefresh {
                Toggle("Variable refresh rate", isOn: Binding(
                    get: { eff.current?.isVariable ?? false },
                    set: { store.setVariableRefresh(display, on: $0) }))
                    .disabled(eff.variableRefreshCounterpart(on: !(eff.current?.isVariable ?? false)) == nil)
                    .help("Let the display vary its refresh rate up to the maximum (ProMotion, Adaptive-Sync) instead of holding a fixed rate.")
            }

            DisclosureGroup("Image & more", isExpanded: $showMore) {
                if showMore { more(eff) }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    /// "2048×1152 · 4096×2304 px"; with LoDPI sizes listed too, HiDPI is named.
    private func resolutionTitle(_ m: DisplayMode, markHiDPI: Bool) -> String {
        let pixels = "\(m.pixelWidth)×\(m.pixelHeight) px"
        return m.isHiDPI ? "\(m.sizeLabel)\(markHiDPI ? " HiDPI" : "") · \(pixels)" : "\(m.sizeLabel) · LoDPI"
    }

    @ViewBuilder
    private func more(_ eff: Display) -> some View {
        let key = display.persistentKey
        let filters = CompositorFilters.shared.state(for: key)
        let upscale = BrightnessUpscaling.shared.state(for: key)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Compositor filters", isOn: Binding(
                    get: { filters.enabled },
                    set: { var f = filters; f.enabled = $0; store.setCompositorFilters(f, for: display) }))
                Spacer()
                Button("Edit…") {
                    FiltersModel.shared.select(displayKey: key)
                    openWindow(id: "filters")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            if let maxGain = BrightnessUpscaling.maxGain(for: eff.id) {
                Toggle("Brightness upscaling", isOn: Binding(
                    get: { upscale.enabled },
                    set: { var u = upscale; u.enabled = $0; store.setUpscaling(u, for: display) }))
                if upscale.enabled {
                    HStack {
                        Image(systemName: "sun.max")
                        Slider(value: Binding(
                            get: { min(upscale.gain, maxGain) },
                            set: { var u = upscale; u.gain = $0; store.setUpscaling(u, for: display) }),
                               in: 1...maxGain)
                        Text(String(format: "%.1f×", min(upscale.gain, maxGain))).monospacedDigit().frame(width: 36)
                    }
                    let now = BrightnessUpscaling.effectiveGain(upscale.gain, on: eff.id)
                    if now < min(upscale.gain, maxGain) - 0.05 {
                        Text(String(format: "Limited to %.1f× by the current EDR headroom (it rises at lower backlight levels).", now))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let dither = Dithering.isEnabled(display.id) {
                Toggle("GPU dithering", isOn: Binding(
                    get: { dither },
                    set: { store.setDithering($0, for: display) }))
            }
            Button("Forget settings for this display") { store.forget(key: key) }
                .help("Removes its saved settings, HiDPI virtual screen, overlays and Video Filter Windows, and resets GPU dithering if it was changed.")
        }
        .padding(.top, 4)
    }
}

struct SystemSection: View {
    @ObservedObject var store: DisplayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("System").font(.headline)
            if let on = store.nightShift {
                Toggle("Night Shift", isOn: Binding(get: { on }, set: { store.setNightShift($0) }))
                if on {
                    HStack {
                        Image(systemName: "moon")
                        Slider(value: Binding(get: { Double(store.nightShiftStrength) },
                                              set: { store.setNightShiftStrength(Float($0)) }), in: 0...1)
                    }
                }
            }
            if let on = store.trueTone {
                Toggle("True Tone", isOn: Binding(get: { on }, set: { store.setTrueTone($0) }))
            }
            if let on = store.darkMode {
                Toggle("Dark Mode", isOn: Binding(get: { on }, set: { store.setDarkMode($0) }))
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct MenuContent: View {
    @ObservedObject var store = DisplayStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(DockIcon.defaultsKey) private var dockIcon = DockIcon.whileWindowOpen.rawValue

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BetterDPI").font(.title3.bold())
            if store.safeMode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe mode: ⇧ Shift was held at launch, so saved settings were not restored.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Restore settings now") { store.leaveSafeMode() }
                }
                .padding(8)
                .background(.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(store.visibleDisplays) { d in
                DisplaySection(store: store, display: d)
                Divider()
            }
            SystemSection(store: store)
            Divider()
            Button("Filters, Video Filter Windows & LUTs…") {
                openWindow(id: "filters")
                NSApp.activate(ignoringOtherApps: true)
            }
            if let err = store.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Show LoDPI resolutions and hidden refresh rates", isOn: $store.showAllModes)
            Picker("Dock icon", selection: $dockIcon) {
                ForEach(DockIcon.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            .onChange(of: dockIcon) { _, _ in DockIcon.update() }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        store.lastError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            HStack {
                Button("Refresh") { store.refresh() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 340)
        .onAppear { store.refreshSystemControls() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SafeMode.checkAtLaunch()
        DockIcon.update()
        DispatchQueue.main.async { DisplayStore.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        VideoFilterWindows.shared.stopAll()
        // Unmirror monitors so they are not left showing a vanished display.
        VirtualHiDPI.shared.disableAll()
    }
}

struct BetterDPIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)

        Window("BetterDPI Filters", id: "filters") {
            FiltersView()
        }
        .defaultSize(width: 760, height: 560)
    }
}
