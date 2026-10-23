import AppKit

enum CLI {
    static let usage = """
    usage: BetterDPI <command>
      list                          list online displays and their current mode
      modes <id> [--all]            list HiDPI modes (--all: every mode incl. hidden)
      set <id> <index>              apply mode by index (from `modes`)
      set <id> <W>x<H> [hidpi|lodpi] [@<Hz>] [vrr|fixed]
                                    W×H is the "looks like" size in points (HiDPI 2560x1440 = 5120×2880 px)
      hidpi <id> on|off             switch between HiDPI and LoDPI of the current size
      vrr <id> [on|off]             show or set variable refresh rate (ProMotion, Adaptive-Sync) at the current size
      virtual <id>                  HiDPI virtual screen for <id>; runs until Ctrl-C
      dither <id> [on|off]          show or set GPU dithering (Apple silicon)
      nightshift [on|off|0-100]     show or set Night Shift (or its strength in %)
      truetone [on|off]             show or set True Tone
      darkmode [on|off]             show or set Dark Mode
      filter <id> key=value,...     compositor filters until Ctrl-C, e.g. saturation=0,invert=on
                                    keys: brightness contrast saturation hue blur sepia red green blue invert
      upscale <id> [gain]           brightness upscaling until Ctrl-C (EDR displays, default 1.5)
      videofilter <src> <target|self> [key=value,...]
                                    Video Filter Window until Ctrl-C (needs Screen Recording)
    Long-running commands (virtual, filter, upscale, videofilter) never change the app's saved settings.
    """

    static func run(_ args: [String]) -> Int32 {
        do {
            switch args.first {
            case "list": list()
            case "modes": try modes(args)
            case "set": try set(args)
            case "hidpi": try hidpi(args)
            case "vrr": try vrr(args)
            case "virtual": try virtual(args)
            case "dither": try dither(args)
            case "nightshift": try nightShift(args)
            case "truetone": try toggle(args, "True Tone", get: SystemControls.trueTone, set: SystemControls.setTrueTone)
            case "darkmode": try toggle(args, "Dark Mode", get: SystemControls.darkMode, set: SystemControls.setDarkMode)
            case "filter": try filter(args)
            case "upscale": try upscale(args)
            case "videofilter": try videoFilter(args)
            default:
                print(usage)
                return args.first == nil || args.first == "help" ? 0 : 2
            }
            return 0
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func display(_ arg: String?) throws -> Display {
        guard let s = arg, let id = UInt32(s) else { throw DisplayError.message("missing or invalid display id\n\(usage)") }
        guard let d = Displays.snapshot().first(where: { $0.id == id }) else {
            throw DisplayError.message("no online display with id \(id)")
        }
        return d
    }

    private static func list() {
        for d in Displays.snapshot() {
            var tags: [String] = []
            if d.isMain { tags.append("main") }
            if d.isBuiltin { tags.append("built-in") }
            if let m = d.mirrorOf { tags.append("mirrors \(m)") }
            if let dither = Dithering.isEnabled(d.id) { tags.append("dither \(dither ? "on" : "off")") }
            let cur = d.current.map { "\($0.label) (\($0.detail))" } ?? "?"
            print("\(d.id)\t\(d.name)\t\(cur)\t\(d.modes.count) modes\t\(tags.joined(separator: ", "))")
        }
    }

    private static func modes(_ args: [String]) throws {
        let d = try display(args.dropFirst().first)
        let all = args.contains("--all")
        let list = all ? d.modes : Displays.distinctModes(d.modes, preferredRefresh: d.current?.refresh ?? 60).filter(\.isHiDPI)
        if list.isEmpty {
            print(all ? "\(d.name) reports no display modes." : "\(d.name) has no HiDPI modes; use `modes \(d.id) --all` or `virtual \(d.id)`.")
        }
        for m in list {
            let mark = m.index == d.current?.index ? "*" : " "
            print("\(mark) \(m.index)\t\(m.label)\t\(m.detail)\t\(m.depth)-bit")
        }
    }

    private static func set(_ args: [String]) throws {
        let d = try display(args.dropFirst().first)
        guard args.count >= 3 else { throw DisplayError.message(usage) }
        let spec = args[2]
        let mode: DisplayMode?
        if let idx = Int32(spec) {
            mode = d.modes.first { $0.index == idx }
        } else {
            let parts = spec.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { throw DisplayError.message("bad size \(spec)") }
            let rest = args.dropFirst(3).map { $0.lowercased() }
            let wantHi: Bool? = rest.contains("hidpi") ? true : rest.contains("lodpi") ? false : nil
            let wantVariable: Bool? = rest.contains("vrr") ? true : rest.contains("fixed") ? false : nil
            var hz = d.current?.refresh ?? 60
            if let spec = rest.first(where: { $0.hasPrefix("@") }) {
                let digits = spec.dropFirst().replacingOccurrences(of: "hz", with: "")
                guard let v = Int(digits), v > 0 else { throw DisplayError.message("bad refresh rate \(spec); use e.g. @60") }
                hz = v
            }
            if let unknown = rest.first(where: { !["hidpi", "lodpi", "vrr", "fixed"].contains($0) && !$0.hasPrefix("@") }) {
                throw DisplayError.message("unknown option \(unknown)")
            }
            // Unless asked, keep the current variable/fixed state when the size offers it.
            let preferVariable = wantVariable ?? d.current?.isVariable ?? false
            mode = d.usableModes
                .filter { $0.width == parts[0] && $0.height == parts[1] && (wantHi == nil || $0.isHiDPI == wantHi)
                    && (wantVariable == nil || $0.isVariable == wantVariable) }
                .min {
                    (abs($0.refresh - hz), $0.isHiDPI ? 0 : 1, $0.isVariable == preferVariable ? 0 : 1)
                        < (abs($1.refresh - hz), $1.isHiDPI ? 0 : 1, $1.isVariable == preferVariable ? 0 : 1)
                }
        }
        guard let mode else { throw DisplayError.message("no mode matching \(args.dropFirst(2).joined(separator: " "))") }
        try Displays.apply(mode, to: d.id)
        print("applied \(mode.label) to \(d.name)")
    }

    private static func hidpi(_ args: [String]) throws {
        let d = try display(args.dropFirst().first)
        let want: Bool
        switch args.count > 2 ? args[2] : nil {
        case "on": want = true
        case "off": want = false
        case nil: want = !(d.current?.isHiDPI ?? false)
        case let other?: throw DisplayError.message("expected on|off, got \(other)")
        }
        if d.current?.isHiDPI == want { print("already \(want ? "HiDPI" : "LoDPI")"); return }
        guard let m = d.hiDPICounterpart() else {
            throw DisplayError.message("no \(want ? "HiDPI" : "LoDPI") counterpart for \(d.current?.label ?? "current mode"); try `virtual \(d.id)`")
        }
        try Displays.apply(m, to: d.id)
        print("applied \(m.label) to \(d.name)")
    }

    private static func vrr(_ args: [String]) throws {
        let d = try display(args.dropFirst().first)
        guard let cur = d.current else { throw DisplayError.message("\(d.name) reports no current mode") }
        guard let want = try onOff(args.count > 2 ? args[2] : nil) else {
            let support = d.supportsVariableRefresh ? "supported" : "not supported"
            print("\(d.name): \(cur.refreshLabel) at \(cur.sizeLabel); variable refresh rate \(support)")
            return
        }
        if cur.isVariable == want { print("already \(want ? "variable" : "fixed"): \(cur.refreshLabel)"); return }
        guard let m = d.variableRefreshCounterpart(on: want) else {
            throw DisplayError.message("\(d.name) has no \(want ? "variable" : "fixed") refresh rate at \(cur.sizeLabel)")
        }
        try Displays.apply(m, to: d.id)
        print("applied \(m.label) to \(d.name)")
    }

    private static func onOff(_ arg: String?) throws -> Bool? {
        switch arg {
        case nil: return nil
        case "on": return true
        case "off": return false
        case let other?: throw DisplayError.message("expected on|off, got \(other)")
        }
    }

    private static func dither(_ args: [String]) throws {
        let d = try display(args.dropFirst().first)
        if let on = try onOff(args.count > 2 ? args[2] : nil) {
            try Dithering.set(on, for: d.id, persistentKey: nil)
        }
        guard let state = Dithering.isEnabled(d.id) else {
            throw DisplayError.message("GPU dithering control is not available for \(d.name)")
        }
        print("\(d.name): GPU dithering \(state ? "on" : "off")")
    }

    private static func toggle(_ args: [String], _ name: String, get: @autoclosure () -> Bool?,
                               set: (Bool) throws -> Void) throws {
        if let on = try onOff(args.count > 1 ? args[1] : nil) { try set(on) }
        guard let state = get() else { throw DisplayError.message("\(name) is not available on this Mac") }
        print("\(name): \(state ? "on" : "off")")
    }

    private static func nightShift(_ args: [String]) throws {
        if args.count > 1, args[1] != "on", args[1] != "off" {
            guard let pct = Float(args[1]), pct.isFinite, (0...100).contains(pct) else {
                throw DisplayError.message("expected on|off or a strength from 0 to 100, got \(args[1])")
            }
            try SystemControls.setNightShiftStrength(pct / 100)
        } else if let on = try onOff(args.count > 1 ? args[1] : nil) {
            try SystemControls.setNightShift(on)
        }
        guard let on = SystemControls.nightShift else { throw DisplayError.message("Night Shift is not available") }
        let strength = SystemControls.nightShiftStrength.map { $0.isFinite ? "\(Int(($0 * 100).rounded()))%" : "unknown" } ?? "unknown"
        print("Night Shift: \(on ? "on" : "off"), strength \(strength)")
    }

    /// Parse `key=value,...` into FilterSettings for the compositor layer.
    static func parseFilters(_ spec: String) throws -> FilterSettings {
        var f = FilterSettings()
        // Same ranges as the app's sliders.
        let numeric: [String: (WritableKeyPath<FilterSettings, Double>, ClosedRange<Double>)] = [
            "brightness": (\.brightness, -1...1), "contrast": (\.contrast, 0...2), "saturation": (\.saturation, 0...2),
            "hue": (\.hue, -180...180), "blur": (\.blur, 0...30), "sepia": (\.sepia, 0...1),
            "red": (\.red, 0...2), "green": (\.green, 0...2), "blue": (\.blue, 0...2)]
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard kv.count == 2 else { throw DisplayError.message("expected key=value, got \(item)") }
            if kv[0] == "invert" {
                f.invert = try onOff(kv[1]) ?? false
            } else if let (path, range) = numeric[kv[0]] {
                guard let v = Double(kv[1]), v.isFinite, range.contains(v) else {
                    throw DisplayError.message("\(kv[0]) must be a number from \(range.lowerBound) to \(range.upperBound), got \(kv[1])")
                }
                f[keyPath: path] = v
            } else {
                throw DisplayError.message("unknown filter or bad value: \(item)")
            }
        }
        return f
    }

    private static func filter(_ args: [String]) throws {
        let d = try display(args.dropFirst().first)
        guard args.count > 2 else { throw DisplayError.message(usage) }
        var state = CompositorFilters.State()
        state.enabled = true
        state.hideFromCapture = false   // so scripts can verify the result with a screenshot
        state.settings = try parseFilters(args[2])
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard CompositorFilters.shared.isAvailable else { throw DisplayError.message("compositor filter layer unavailable") }
        guard NSScreen.screen(for: d.id) != nil else { throw notOnScreen(d) }
        CompositorFilters.shared.preview(state, on: d.id)
        print("compositor filters active on \(d.name). Ctrl-C to stop.")
        runUntilSignal { CompositorFilters.shared.removeAll() }
    }

    private static func upscale(_ args: [String]) throws {
        let d = try display(args.dropFirst().first)
        var gain = 1.5
        if args.count > 2 {
            guard let g = Double(args[2]), g.isFinite, g >= 1 else {
                throw DisplayError.message("gain must be a number of at least 1, got \(args[2])")
            }
            gain = g
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard NSScreen.screen(for: d.id) != nil else { throw notOnScreen(d) }
        guard let maxGain = BrightnessUpscaling.maxGain(for: d.id) else {
            throw DisplayError.message("\(d.name) has no EDR headroom (needs an XDR or HDR display in HDR mode)")
        }
        BrightnessUpscaling.shared.preview(.init(enabled: true, gain: gain), on: d.id)
        print(String(format: "brightness upscaling %.2fx requested (screen maximum %.2fx, %.2fx available now) on %@. Ctrl-C to stop.",
                     gain, maxGain, BrightnessUpscaling.currentHeadroom(for: d.id), d.name))
        runUntilSignal { BrightnessUpscaling.shared.removeAll() }
    }

    private static func videoFilter(_ args: [String]) throws {
        let src = try display(args.dropFirst().first)
        guard args.count > 2 else { throw DisplayError.message(usage) }
        let selfStream = args[2] == "self"
        let dst = selfStream ? src : try display(args[2])
        let filters = args.count > 3 ? try parseFilters(args[3]) : FilterSettings()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let all = Displays.snapshot()
        let windows = VideoFilterWindows.shared
        windows.persists = false   // a preview: never written to the app's window list
        windows.resolve = { key in all.first { $0.persistentKey == key }?.id }
        var config = windows.add(source: src.persistentKey, target: dst.persistentKey, selfStream: selfStream)
        config.filters = filters
        windows.update(config)
        let id = config.id
        windows.start(id)
        // Starting is asynchronous: wait for the first frame or an error before reporting.
        let deadline = Date().addingTimeInterval(10)
        while windows.framesRendered(id) == 0, windows.running.contains(id), windows.lastError == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let err = windows.lastError ?? (windows.running.contains(id) ? nil : "the window stopped while starting") {
            windows.remove(id)
            throw DisplayError.message(err)
        }
        guard windows.framesRendered(id) > 0 else {
            windows.remove(id)
            throw DisplayError.message("no frame was captured within 10 seconds")
        }
        print("Video Filter Window \(id) from \(src.name) on \(dst.name) is running. Ctrl-C to stop.")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if let err = windows.lastError {
                print("error: \(err)")
                windows.remove(id)
                exit(1)
            }
            print("frames rendered: \(windows.framesRendered(id))")
        }
        runUntilSignal { windows.remove(id) }
    }

    private static func notOnScreen(_ d: Display) -> DisplayError {
        .message("\(d.name) is not shown as its own screen (it is mirrored, e.g. by a HiDPI virtual screen); use the id of the screen that shows it")
    }

    /// Keep the process alive until Ctrl-C, kill or the terminal closing, then clean up.
    private static func runUntilSignal(_ cleanup: @escaping () -> Void) -> Never {
        let sources = [SIGINT, SIGTERM, SIGHUP].map { signo in
            signal(signo, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            src.setEventHandler {
                cleanup()
                print("\nstopped")
                exit(0)
            }
            src.resume()
            return src
        }
        withExtendedLifetime(sources) { NSApp.run() }
        exit(0)
    }

    private static func virtual(_ args: [String]) throws {
        let d = try display(args.dropFirst().first)
        _ = NSApplication.shared
        let vid = try VirtualHiDPI.shared.enable(for: d, persist: false)
        print("virtual HiDPI display \(vid) is now driving \(d.name); use `modes \(vid)` / `set \(vid) …` from another shell. Ctrl-C to stop.")
        // Restore on Ctrl-C, kill, or the terminal closing.
        let sources = [SIGINT, SIGTERM, SIGHUP].map { signo in
            signal(signo, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            src.setEventHandler {
                VirtualHiDPI.shared.disable(for: d.id, forget: false)
                print("\nrestored \(d.name)")
                exit(0)
            }
            src.resume()
            return src
        }
        withExtendedLifetime(sources) { dispatchMain() }
    }
}
