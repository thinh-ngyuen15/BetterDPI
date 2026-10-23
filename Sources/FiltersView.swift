import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Selection shared between the menu and the filters window.
final class FiltersModel: ObservableObject {
    static let shared = FiltersModel()

    enum Tab: Hashable { case display, windows, luts, stored }

    @Published var tab: Tab = .display
    @Published var displayKey: String?
    @Published var windowID: Int?

    func select(displayKey: String) {
        self.displayKey = displayKey
        tab = .display
    }
}

struct FiltersView: View {
    @ObservedObject var model = FiltersModel.shared

    var body: some View {
        TabView(selection: $model.tab) {
            DisplayFiltersTab().tabItem { Text("Display Filters") }.tag(FiltersModel.Tab.display)
            VideoFilterWindowsTab().tabItem { Text("Video Filter Windows") }.tag(FiltersModel.Tab.windows)
            LUTLibraryTab().tabItem { Text("LUT Library") }.tag(FiltersModel.Tab.luts)
            StoredDisplaysTab().tabItem { Text("Stored Displays") }.tag(FiltersModel.Tab.stored)
        }
        .padding(12)
        .frame(minWidth: 680, minHeight: 500)
        .onAppear { DockIcon.windowOpen = true }
        .onDisappear { DockIcon.windowOpen = false }
    }
}

// MARK: - Shared filter controls

struct FilterControls: View {
    @Binding var settings: FilterSettings
    /// The compositor path cannot run Core Image effects or LUTs.
    var compositorOnly: Bool
    @ObservedObject private var luts = LUTStore.shared

    var body: some View {
        Form {
            Section("Adjustments") {
                slider("Brightness", \.brightness, -1...1, neutral: 0)
                slider("Contrast", \.contrast, 0...2, neutral: 1)
                slider("Saturation", \.saturation, 0...2, neutral: 1)
                slider("Hue", \.hue, -180...180, neutral: 0, format: "%.0f°")
                slider("Blur", \.blur, 0...30, neutral: 0, format: "%.0f pt")
                slider("Sepia", \.sepia, 0...1, neutral: 0)
                slider("Red gain", \.red, 0...2, neutral: 1)
                slider("Green gain", \.green, 0...2, neutral: 1)
                slider("Blue gain", \.blue, 0...2, neutral: 1)
                Toggle("Invert colors", isOn: $settings.invert)
            }
            if compositorOnly {
                Text("Effects and LUTs need a Video Filter Window: the compositor layer only runs Core Animation filters.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Section("Effect & LUT") {
                    Picker("Effect", selection: $settings.effect) {
                        ForEach(FilterSettings.Effect.allCases) { Text($0.title).tag($0) }
                    }
                    if settings.effect.hasAmount {
                        slider("Effect amount", \.effectAmount, 0...1, neutral: 0.5, format: "%.0f%%", scale: 100)
                    }
                    Picker("3D LUT", selection: $settings.lutID) {
                        Text("None").tag(UUID?.none)
                        ForEach(luts.records) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
            }
            Button("Reset Filters") { settings = FilterSettings() }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ path: WritableKeyPath<FilterSettings, Double>, _ range: ClosedRange<Double>,
                        neutral: Double, format: String = "%.2f", scale: Double = 1) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: Binding(get: { settings[keyPath: path] }, set: { settings[keyPath: path] = $0 }), in: range)
            Text(String(format: format, settings[keyPath: path] * scale)).monospacedDigit().frame(width: 56, alignment: .trailing)
            Button { settings[keyPath: path] = neutral } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .disabled(settings[keyPath: path] == neutral)
                .help("Reset")
        }
    }
}

// MARK: - Display filters (compositor layer)

private struct DisplayFiltersTab: View {
    @ObservedObject var store = DisplayStore.shared
    @ObservedObject var model = FiltersModel.shared

    var body: some View {
        let displays = store.visibleDisplays
        VStack(alignment: .leading, spacing: 10) {
            Text("Applied by the window server to everything on the display, with no capture and no added latency.")
                .font(.callout).foregroundStyle(.secondary)
            if !CompositorFilters.shared.isAvailable {
                Text("The compositor filter layer is not available on this macOS version.").foregroundStyle(.red)
            }
            Picker("Display", selection: Binding(
                get: { model.displayKey ?? displays.first?.persistentKey },
                set: { model.displayKey = $0 })) {
                ForEach(displays) { Text($0.name).tag(String?.some($0.persistentKey)) }
            }
            if let key = model.displayKey ?? displays.first?.persistentKey,
               let display = displays.first(where: { $0.persistentKey == key }) {
                let state = CompositorFilters.shared.state(for: key)
                let set: (CompositorFilters.State) -> Void = { store.setCompositorFilters($0, for: display) }
                HStack {
                    Toggle("Enabled", isOn: Binding(get: { state.enabled }, set: { var s = state; s.enabled = $0; set(s) }))
                    Toggle("Hide from screenshots and recordings", isOn: Binding(
                        get: { state.hideFromCapture }, set: { var s = state; s.hideFromCapture = $0; set(s) }))
                }
                .toggleStyle(.switch)
                FilterControls(settings: Binding(get: { state.settings }, set: { var s = state; s.settings = $0; set(s) }),
                               compositorOnly: true)
            }
        }
    }
}

// MARK: - Video Filter Windows

private struct VideoFilterWindowsTab: View {
    @ObservedObject var store = DisplayStore.shared
    @ObservedObject var windows = VideoFilterWindows.shared
    @ObservedObject var model = FiltersModel.shared

    var body: some View {
        let displays = store.visibleDisplays
        HSplitView {
            VStack(alignment: .leading) {
                List(selection: $model.windowID) {
                    ForEach(windows.configs) { c in
                        HStack {
                            Image(systemName: windows.running.contains(c.id) ? "play.circle.fill" : "pause.circle")
                                .foregroundStyle(windows.running.contains(c.id) ? .green : .secondary)
                            Text(c.selfStream ? "\(c.id). Self-Stream" : "\(c.id). Window")
                        }.tag(Optional(c.id))
                    }
                }
                HStack {
                    Button("Add Window") {
                        guard let first = displays.first?.persistentKey else { return }
                        model.windowID = windows.add(source: first, target: first, selfStream: false).id
                    }
                    Button("Add Self-Stream") {
                        guard let first = displays.first?.persistentKey else { return }
                        model.windowID = windows.add(source: first, target: first, selfStream: true).id
                    }
                }
                .disabled(displays.isEmpty)
            }
            .frame(minWidth: 180, maxWidth: 220)

            Group {
                if let id = model.windowID, let config = windows.configs.first(where: { $0.id == id }) {
                    WindowEditor(config: config, displays: displays)
                } else {
                    Text("Add or select a Video Filter Window.\nIt shows a live, filtered copy of a display. Self-Stream covers the display itself with its filtered copy.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
        .overlay(alignment: .bottom) {
            if let err = windows.lastError {
                Text(err).font(.caption).foregroundStyle(.red).padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct WindowEditor: View {
    let config: VideoFilterWindows.Config
    let displays: [Display]
    @ObservedObject var windows = VideoFilterWindows.shared

    var body: some View {
        let running = windows.running.contains(config.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(running ? "Stop" : "Start") {
                    running ? windows.stop(config.id) : windows.start(config.id)
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button("Remove", role: .destructive) { windows.remove(config.id) }
            }
            Form {
                Section("Window") {
                    Picker("Source display", selection: bind(\.sourceKey)) { displayOptions }
                    if !config.selfStream {
                        Picker("Target display", selection: bind(\.targetKey)) { displayOptions }
                        HStack {
                            percent("X", \.x); percent("Y", \.y); percent("W", \.width); percent("H", \.height)
                        }
                        Toggle("Title bar", isOn: bind(\.titlebar))
                        Toggle("Shadow", isOn: bind(\.shadow))
                        Toggle("Mouse click-through", isOn: bind(\.clickThrough))
                    }
                    HStack {
                        Text("Opacity")
                        Slider(value: bind(\.alpha), in: 5...100)
                        Text("\(Int(config.alpha))%").monospacedDigit().frame(width: 40)
                    }
                    Stepper("Frame rate: \(config.fps == 0 ? "unlimited" : "\(config.fps) fps")",
                            value: bind(\.fps), in: 0...200, step: 5)
                    Toggle("Start automatically", isOn: bind(\.autostart))
                    Toggle("HDR rendering", isOn: bind(\.hdr))
                }
                Section("Filters") {
                    FilterControls(settings: bind(\.filters), compositorOnly: false)
                        .frame(minHeight: 420)
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private var displayOptions: some View {
        ForEach(displays) { Text($0.name).tag($0.persistentKey) }
        if !displays.contains(where: { $0.persistentKey == config.sourceKey }) {
            Text("Disconnected display").tag(config.sourceKey)
        }
        if !displays.contains(where: { $0.persistentKey == config.targetKey }), config.targetKey != config.sourceKey {
            Text("Disconnected display").tag(config.targetKey)
        }
    }

    private func bind<T>(_ path: WritableKeyPath<VideoFilterWindows.Config, T>) -> Binding<T> {
        Binding(get: { config[keyPath: path] }, set: {
            var c = config
            c[keyPath: path] = $0
            if c.selfStream { c.targetKey = c.sourceKey }
            windows.update(c)
        })
    }

    private func percent(_ label: String, _ path: WritableKeyPath<VideoFilterWindows.Config, Double>) -> some View {
        TextField(label, value: bind(path), format: .number.precision(.fractionLength(0...1)))
            .frame(width: 60)
    }
}

// MARK: - LUT library

private struct LUTLibraryTab: View {
    @ObservedObject var luts = LUTStore.shared
    @State private var selection: UUID?
    @State private var error: String?
    @State private var renaming = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import UTF-8 .cube files with a 3D LUT (LUT_3D_SIZE 2–128). LUTs can be used by Video Filter Windows.")
                .font(.callout).foregroundStyle(.secondary)
            List(luts.records, selection: $selection) { r in
                HStack {
                    Text(r.name)
                    Spacer()
                    Text("\(r.dimension)³").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack {
                Button("Import…") { pick { url in try luts.importFile(url) } }
                Button("Replace…") { if let id = selection { pick { url in try luts.replace(id, with: url) } } }
                    .disabled(selection == nil)
                    .help("Upload a replacement CUBE file while keeping this LUT's name and assignments.")
                Button("Export…") { export() }.disabled(selection == nil)
                Button("Delete", role: .destructive) { if let id = selection { luts.remove(id); selection = nil } }
                    .disabled(selection == nil)
                Spacer()
                TextField("New name", text: $renaming).frame(width: 160)
                Button("Rename") {
                    guard let id = selection else { return }
                    do { try luts.rename(id, to: renaming); renaming = "" } catch { self.error = error.localizedDescription }
                }
                .disabled(selection == nil || renaming.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func pick(_ action: (URL) throws -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try action(url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func export() {
        guard let id = selection else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (luts.name(for: id) ?? "LUT") + ".cube"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try luts.export(id, to: url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Stored displays

private struct StoredDisplaysTab: View {
    @ObservedObject var store = DisplayStore.shared
    @AppStorage(KnownDisplays.pruneDaysKey) private var pruneDays = 0
    @State private var confirmReset = false

    var body: some View {
        let online = Set(store.visibleDisplays.map(\.persistentKey))
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings are kept for every display BetterDPI has seen, including ones that are not connected now.")
                .font(.callout).foregroundStyle(.secondary)
            List(KnownDisplays.all(), id: \.key) { item in
                HStack {
                    Circle().fill(online.contains(item.key) ? .green : .secondary.opacity(0.4)).frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(item.record.name)
                        Text(online.contains(item.key) ? "Connected"
                             : "Last seen \(item.record.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { store.forget(key: item.key) }
                        .help("Removes its saved settings, HiDPI virtual screen, overlays and Video Filter Windows, and resets GPU dithering if it was changed.")
                }
            }
            HStack {
                Picker("Forget displays not seen for", selection: $pruneDays) {
                    Text("Never").tag(0)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .frame(width: 320)
                Spacer()
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
            }
            Text("Tip: hold ⇧ Shift while launching BetterDPI to start in safe mode without restoring any settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Reset all BetterDPI settings?", isPresented: $confirmReset) {
            Button("Reset and Relaunch", role: .destructive) { store.resetAll() }
        } message: {
            Text("This removes every display setting, filter, Video Filter Window and imported LUT, then relaunches the app.")
        }
    }
}
