import AppKit
import CoreGraphics

/// One entry from the private CGS mode table. Includes modes the
/// public CGDisplayCopyAllDisplayModes API hides.
struct DisplayMode: Hashable, Identifiable {
    let index: Int32
    let width: Int          // points
    let height: Int         // points
    let scale: Double       // 2.0 = HiDPI
    let refresh: Int        // Hz, 0 when unknown; for a variable mode, the maximum
    let depth: Int
    let flags: UInt32
    /// Variable refresh rate (ProMotion, Adaptive-Sync): the panel runs anywhere up to `refresh`.
    var isVariable = false
    var minRefresh = 0      // lowest rate of a variable mode, 0 when unknown

    // IOGraphics mode flags, as reported in the CGS mode record.
    static let defaultFlag: UInt32 = 0x0000_0004
    static let nativeFlag: UInt32 = 0x0200_0000
    static let hiddenFlag: UInt32 = 0x4000_0000   // duplicate entries macOS never shows

    var id: Int32 { index }
    var isHiDPI: Bool { scale > 1.5 }
    var isNative: Bool { flags & Self.nativeFlag != 0 }
    var isHidden: Bool { flags & Self.hiddenFlag != 0 }
    var pixelWidth: Int { Int(Double(width) * scale) }
    var pixelHeight: Int { Int(Double(height) * scale) }

    var sizeLabel: String { "\(width)×\(height)" }
    var refreshLabel: String {
        guard refresh > 0 else { return isVariable ? "Variable" : "Default" }
        guard isVariable else { return "\(refresh) Hz" }
        return minRefresh > 0 && minRefresh < refresh ? "Variable (\(minRefresh)–\(refresh) Hz)" : "Variable (up to \(refresh) Hz)"
    }

    /// Same point size and HiDPI state (the refresh rate may differ).
    func sameResolution(as other: DisplayMode) -> Bool {
        width == other.width && height == other.height && isHiDPI == other.isHiDPI
    }
    var label: String {
        var s = sizeLabel
        if isHiDPI { s += " HiDPI" }
        if refresh > 0 { s += " @ \(refresh)Hz" }
        if isVariable { s += minRefresh > 0 && minRefresh < refresh ? " VRR \(minRefresh)–\(refresh)Hz" : " VRR" }
        if isHidden { s += " (hidden)" }
        return s
    }
    var detail: String { isHiDPI ? "\(pixelWidth)×\(pixelHeight) px" : "LoDPI" }
}

struct Display: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let mirrorOf: CGDirectDisplayID?   // set when this display mirrors another
    let current: DisplayMode?
    let modes: [DisplayMode]

    var vendor: UInt32 { CGDisplayVendorNumber(id) }
    var model: UInt32 { CGDisplayModelNumber(id) }
    var serial: UInt32 { CGDisplaySerialNumber(id) }
    /// Stable key for persisting per-display settings across reconnects.
    var persistentKey: String { "\(vendor)-\(model)-\(serial)" }

    /// Modes macOS itself would offer (no hidden duplicates).
    var usableModes: [DisplayMode] { modes.filter { !$0.isHidden } }

    /// The panel's native pixel size: the mode flagged native, else the largest LoDPI mode.
    var nativePixelSize: (width: Int, height: Int)? {
        if let n = usableModes.first(where: \.isNative) { return (n.pixelWidth, n.pixelHeight) }
        return usableModes.filter { !$0.isHiDPI }
            .max { $0.width * $0.height < $1.width * $1.height }
            .map { ($0.width, $0.height) }
    }

    /// The mode with the same point size but the opposite HiDPI state, if any.
    /// Falls back to the same pixel size when no point-size match exists.
    func hiDPICounterpart() -> DisplayMode? {
        guard let cur = current else { return nil }
        let wantHiDPI = !cur.isHiDPI
        let candidates = usableModes.filter { $0.isHiDPI == wantHiDPI }
        let samePoints = candidates.filter { $0.width == cur.width && $0.height == cur.height }
        let samePixels = candidates.filter { $0.pixelWidth == cur.pixelWidth && $0.pixelHeight == cur.pixelHeight }
        let pool = samePoints.isEmpty ? samePixels : samePoints
        return pool.min {
            (abs($0.refresh - cur.refresh), $0.isVariable == cur.isVariable ? 0 : 1)
                < (abs($1.refresh - cur.refresh), $1.isVariable == cur.isVariable ? 0 : 1)
        }
    }

    /// Whether the current resolution offers a variable refresh rate mode.
    var supportsVariableRefresh: Bool {
        guard let cur = current else { return false }
        return usableModes.contains { $0.isVariable && $0.sameResolution(as: cur) }
    }

    /// The mode at the current resolution that turns variable refresh rate on (the variable
    /// mode with the highest maximum) or off (the fixed rate closest to the current maximum).
    func variableRefreshCounterpart(on: Bool) -> DisplayMode? {
        guard let cur = current else { return nil }
        let pool = usableModes.filter { $0.sameResolution(as: cur) && $0.isVariable == on }
        if on { return pool.max { ($0.refresh, $0.depth) < ($1.refresh, $1.depth) } }
        return pool.min { (abs($0.refresh - cur.refresh), -$0.refresh, -$0.depth) < (abs($1.refresh - cur.refresh), -$1.refresh, -$1.depth) }
    }
}

enum DisplayError: LocalizedError {
    case cg(String, CGError)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cg(let what, let err): return "\(what) failed (CGError \(err.rawValue))"
        case .message(let m): return m
        }
    }
}

enum Displays {
    static func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Enumerate every mode via CGSGetNumberOfDisplayModes /
    /// CGSGetDisplayModeDescriptionOfLength.
    static func modes(for id: CGDirectDisplayID) -> [DisplayMode] {
        var n: Int32 = 0
        CGSGetNumberOfDisplayModes(id, &n)
        var out: [DisplayMode] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            var d = CGSDisplayModeDescription()
            CGSGetDisplayModeDescriptionOfLength(id, i, &d, Int32(MemoryLayout<CGSDisplayModeDescription>.size))
            var minRefresh: Float = 0
            let variable = BDDisplayModeIsVariable(id, i, &minRefresh)
            out.append(DisplayMode(index: i,
                                   width: Int(d.width), height: Int(d.height),
                                   scale: Double(d.density > 0 ? d.density : 1),
                                   refresh: Int(d.freq), depth: Int(d.depth), flags: d.flags,
                                   isVariable: variable, minRefresh: Int(minRefresh.rounded())))
        }
        return out
    }

    static func currentModeIndex(for id: CGDirectDisplayID) -> Int32 {
        var idx: Int32 = -1
        CGSGetCurrentDisplayMode(id, &idx)
        return idx
    }

    static func name(for id: CGDirectDisplayID, cache: [CGDirectDisplayID: String] = [:]) -> String {
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == id {
                return screen.localizedName
            }
        }
        if let cached = cache[id] { return cached }
        if VirtualHiDPI.shared.isVirtual(id) { return "BetterDPI Virtual" }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }

    static func snapshot(nameCache: [CGDirectDisplayID: String] = [:]) -> [Display] {
        onlineIDs().map { id in
            let modes = modes(for: id)
            let cur = currentModeIndex(for: id)
            let mirror = CGDisplayMirrorsDisplay(id)
            return Display(id: id,
                           name: name(for: id, cache: nameCache),
                           isBuiltin: CGDisplayIsBuiltin(id) != 0,
                           isMain: CGDisplayIsMain(id) != 0,
                           mirrorOf: mirror == kCGNullDirectDisplay ? nil : mirror,
                           current: modes.first { $0.index == cur },
                           modes: modes)
        }
    }

    /// Apply a mode with CGSConfigureDisplayMode inside a configuration transaction.
    static func apply(_ mode: DisplayMode, to id: CGDirectDisplayID) throws {
        try configure { config in
            let err = CGSConfigureDisplayMode(config, id, mode.index)
            if err != .success { throw DisplayError.cg("CGSConfigureDisplayMode", err) }
        }
    }

    /// Make `display` mirror `primary` (pass kCGNullDirectDisplay to stop mirroring).
    /// `origin` moves `placed` there in the same transaction, so the arrangement
    /// does not jump when a display enters or leaves the mirror set.
    static func mirror(_ display: CGDirectDisplayID, of primary: CGDirectDisplayID,
                       placing placed: CGDirectDisplayID? = nil, at origin: CGPoint = .zero) throws {
        try configure { config in
            if let placed {
                let o = CGConfigureDisplayOrigin(config, placed, Int32(origin.x), Int32(origin.y))
                if o != .success { throw DisplayError.cg("CGConfigureDisplayOrigin", o) }
            }
            let err = CGConfigureDisplayMirrorOfDisplay(config, display, primary)
            if err != .success { throw DisplayError.cg("CGConfigureDisplayMirrorOfDisplay", err) }
        }
    }

    private static func configure(_ body: (CGDisplayConfigRef?) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success else { throw DisplayError.cg("CGBeginDisplayConfiguration", begin) }
        do {
            try body(config)
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        let done = CGCompleteDisplayConfiguration(config, .permanently)
        guard done == .success else { throw DisplayError.cg("CGCompleteDisplayConfiguration", done) }
    }

    /// Entries for the Resolution dropdown: one per size (and HiDPI state), each
    /// the mode at the refresh rate closest to the current one, so picking a size
    /// keeps the refresh rate (and variable refresh rate) when it can. LoDPI sizes only when
    /// `includeLoDPI`. The current mode's size is always present so the dropdown can show it.
    static func resolutionChoices(_ modes: [DisplayMode], current: DisplayMode?, includeLoDPI: Bool) -> [DisplayMode] {
        var list = distinctModes(modes, preferredRefresh: current?.refresh ?? 60, preferVariable: current?.isVariable ?? false)
        if !includeLoDPI { list = list.filter(\.isHiDPI) }
        if let cur = current, !list.contains(where: { $0.sameResolution(as: cur) }) {
            list.append(cur)
            list.sort { ($0.width, $0.height, $0.isHiDPI ? 1 : 0) > ($1.width, $1.height, $1.isHiDPI ? 1 : 0) }
        }
        return list
    }

    /// Entries for the Refresh Rate dropdown: one per rate (variable and fixed
    /// listed apart) available at the current resolution, highest first, a
    /// variable rate before the fixed one of the same maximum. Hidden modes only
    /// when `includeHidden`. Within a rate, prefer the current mode, then a
    /// visible mode, then the greater colour depth.
    static func refreshChoices(_ modes: [DisplayMode], for current: DisplayMode, includeHidden: Bool) -> [DisplayMode] {
        struct Key: Hashable { let hz: Int, variable: Bool }
        var best: [Key: DisplayMode] = [:]
        for m in modes where m.sameResolution(as: current) && (includeHidden || !m.isHidden || m.index == current.index) {
            let k = Key(hz: m.refresh, variable: m.isVariable)
            guard let b = best[k] else {
                best[k] = m
                continue
            }
            func rank(_ x: DisplayMode) -> (Int, Int, Int) {
                (x.index == current.index ? 1 : 0, x.isHidden ? 0 : 1, x.depth)
            }
            if rank(m) > rank(b) { best[k] = m }
        }
        return best.values.sorted { ($0.refresh, $0.isVariable ? 1 : 0) > ($1.refresh, $1.isVariable ? 1 : 0) }
    }

    /// Modes collapsed to one entry per (size, HiDPI), keeping the refresh rate
    /// closest to `preferredRefresh`, then variable or fixed as `preferVariable`
    /// asks. Sorted largest first.
    static func distinctModes(_ modes: [DisplayMode], preferredRefresh: Int, preferVariable: Bool = false) -> [DisplayMode] {
        struct Key: Hashable { let w: Int, h: Int, hi: Bool }
        var best: [Key: DisplayMode] = [:]
        func rank(_ x: DisplayMode) -> (Int, Int, Int) {
            (-abs(x.refresh - preferredRefresh), x.isVariable == preferVariable ? 1 : 0, x.depth)
        }
        for m in modes where !m.isHidden {
            let k = Key(w: m.width, h: m.height, hi: m.isHiDPI)
            if let b = best[k] {
                if rank(m) > rank(b) { best[k] = m }
            } else {
                best[k] = m
            }
        }
        return best.values.sorted {
            ($0.width, $0.height, $0.isHiDPI ? 1 : 0) > ($1.width, $1.height, $1.isHiDPI ? 1 : 0)
        }
    }
}
