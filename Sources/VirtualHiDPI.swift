import CoreGraphics
import Foundation

/// HiDPI for non-Retina monitors: create a CGVirtualDisplay
/// with HiDPI modes matching the monitor's aspect ratio, then mirror the
/// physical monitor from it. macOS renders at 2x into the virtual framebuffer
/// and scales it down onto the panel.
final class VirtualHiDPI {
    static let shared = VirtualHiDPI()

    private struct Entry {
        let display: CGVirtualDisplay
        let virtualID: CGDirectDisplayID
        let persistentKey: String
    }

    /// physical display ID -> virtual display backing it
    private var entries: [CGDirectDisplayID: Entry] = [:]
    /// Physical displays whose virtual display is being created. enable() spins
    /// the run loop while waiting, so re-entrant calls must be ignored.
    private var creating: Set<CGDirectDisplayID> = []
    /// Remembered monitors whose automatic restore failed. They are not retried
    /// until they reconnect or the user turns the setting on again, so a
    /// persistent failure cannot loop (each attempt blocks for up to 3 s and
    /// itself causes another display-change refresh).
    private var failedRestores: Set<String> = []
    private let table = "virtualHiDPI"

    private init() {
        // The first BetterDPI build saved this setting as a plain [String: Bool].
        let legacyKey = "virtualHiDPIDisplays"
        if let old = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: Bool] {
            for (key, on) in old where on { Store.setValue(true, in: table, for: key) }
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        entries.values.contains { $0.virtualID == id }
    }

    func virtualID(for physical: CGDirectDisplayID) -> CGDirectDisplayID? {
        entries[physical]?.virtualID
    }

    /// Point sizes offered on the virtual display: from half the native width
    /// (classic 2x "looks like") up to the native width, keeping the aspect
    /// ratio. Uses exact-aspect sizes (thinned to "round" widths such as 1600,
    /// 1920, 2048) when the aspect allows it; otherwise approximates with widths
    /// in multiples of 8 and heights rounded to even numbers (e.g. 1366×768).
    static func pointSizes(nativeWidth w: Int, nativeHeight h: Int) -> [(Int, Int)] {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(w, h)
        let stepW = w / g, stepH = h / g
        if stepW <= 64 {
            var exact: [(Int, Int)] = []
            for n in ((w / 2 + stepW - 1) / stepW)...(w / stepW) { exact.append((n * stepW, n * stepH)) }
            if exact.count >= 6 {
                if exact.count <= 32 { return exact }
                let round = exact.filter { $0.0 % 64 == 0 || $0.0 % 80 == 0 || $0.0 == w || $0 == exact[0] }
                if round.count >= 12 { return round }
                let stride = (exact.count + 23) / 24
                return exact.enumerated().filter { $0.offset % stride == 0 || $0.offset == exact.count - 1 }.map(\.element)
            }
        }
        let step = max(8, ((w / 2) / 24) / 8 * 8)
        var sizes: [(Int, Int)] = []
        var x = (w / 2 + 7) / 8 * 8
        while x < w {
            let y = Int((Double(x) * Double(h) / Double(w) / 2).rounded()) * 2
            sizes.append((x, y))
            x += step
        }
        sizes.append((w, h))
        return sizes
    }

    /// Create the virtual display for `physical` and mirror the monitor from it.
    /// `persist` remembers the choice so the app restores it at launch/reconnect.
    @discardableResult
    func enable(for physical: Display, persist: Bool = true) throws -> CGDirectDisplayID {
        failedRestores.remove(physical.persistentKey)
        if let existing = entries[physical.id] { return existing.virtualID }
        guard !creating.contains(physical.id) else {
            throw DisplayError.message("A HiDPI virtual screen for \(physical.name) is already being created.")
        }
        guard !isVirtual(physical.id) else {
            throw DisplayError.message("\(physical.name) is a BetterDPI virtual screen.")
        }
        guard CGDisplayIsInMirrorSet(physical.id) == 0 else {
            throw DisplayError.message("\(physical.name) is already part of a mirror set. Turn mirroring off first.")
        }
        guard let native = physical.nativePixelSize else {
            throw DisplayError.message("Could not determine the native resolution of \(physical.name).")
        }
        creating.insert(physical.id)
        defer { creating.remove(physical.id) }

        let currentRefresh = physical.current?.refresh ?? 0
        let refresh = Double(currentRefresh > 0 ? currentRefresh : 60)
        let sizes = Self.pointSizes(nativeWidth: native.width, nativeHeight: native.height)

        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = "BetterDPI \(physical.name)"
        desc.maxPixelsWide = UInt32(native.width * 2)
        desc.maxPixelsHigh = UInt32(native.height * 2)
        let mm = CGDisplayScreenSize(physical.id)
        desc.sizeInMillimeters = mm.width > 0 ? mm : CGSize(width: 600, height: 340)
        desc.vendorID = 0xBD91
        desc.productID = physical.model & 0xFFFF
        desc.serialNum = physical.serial &+ 0x5EED
        desc.terminationHandler = { _, _ in }

        guard let virtual = CGVirtualDisplay(descriptor: desc) else {
            throw DisplayError.message("Could not create a virtual display.")
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        var modes: [CGVirtualDisplayMode] = []
        for (w, h) in sizes.reversed() {
            modes.append(CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: refresh))
            if refresh != 60 {
                modes.append(CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: 60))
            }
        }
        settings.modes = modes
        guard virtual.apply(settings) else {
            throw DisplayError.message("The system rejected the virtual display settings.")
        }
        let vid = virtual.displayID
        guard vid != 0, waitUntilOnline(vid) else {
            throw DisplayError.message("The virtual display did not come online.")
        }

        // Start with a HiDPI mode that keeps the monitor's current "looks like" size.
        let vmodes = Displays.modes(for: vid).filter { $0.isHiDPI && !$0.isHidden }
        let curWidth = physical.current?.width ?? native.width / 2
        let wantRefresh = Int(refresh)
        func distance(_ m: DisplayMode) -> Int { abs(m.width - curWidth) * 100 + abs(m.refresh - wantRefresh) }
        if let target = vmodes.min(by: { distance($0) < distance($1) }) {
            try? Displays.apply(target, to: vid)
        }

        // Put the virtual display where the monitor was, so the arrangement
        // (and the main display, if the monitor sat at 0,0) is preserved.
        try Displays.mirror(physical.id, of: vid, placing: vid, at: CGDisplayBounds(physical.id).origin)
        entries[physical.id] = Entry(display: virtual, virtualID: vid, persistentKey: physical.persistentKey)
        if persist { remember(physical.persistentKey, true) }
        return vid
    }

    /// Stop mirroring and destroy the virtual display. `forget` clears the
    /// remembered setting so it is not restored at the next launch. Returns a
    /// warning when the monitor could not be unmirrored cleanly: releasing the
    /// virtual display still ends the mirror, but macOS then picks its position.
    @discardableResult
    func disable(for physicalID: CGDirectDisplayID, forget: Bool) -> String? {
        guard let entry = entries[physicalID] else { return nil }
        var warning: String?
        if Displays.onlineIDs().contains(physicalID) {
            do {
                try Displays.mirror(physicalID, of: kCGNullDirectDisplay,
                                    placing: physicalID, at: CGDisplayBounds(entry.virtualID).origin)
            } catch {
                warning = "The monitor was unmirrored by removing the virtual screen (\(error.localizedDescription)); check its position in System Settings > Displays."
            }
        }
        entries[physicalID] = nil   // releasing CGVirtualDisplay removes it
        if forget { remember(entry.persistentKey, false) }
        return warning
    }

    func disableAll() {
        for id in Array(entries.keys) { disable(for: id, forget: false) }
    }

    /// Keep virtual displays in step with the hardware: drop the virtual display
    /// when its monitor goes away (so windows are not stranded on an invisible
    /// screen), re-mirror if the mirror set was broken, and recreate it for
    /// remembered monitors that are (re)connected. Returns errors to report.
    func reconcile(displays: [Display]) -> [String] {
        guard creating.isEmpty else { return [] }
        let online = Set(displays.map(\.id))
        // A monitor that disconnected gets a fresh attempt when it comes back.
        failedRestores.formIntersection(displays.map(\.persistentKey))
        var errors: [String] = []
        for (pid, entry) in entries {
            if !online.contains(pid) {
                entries[pid] = nil
            } else if CGDisplayMirrorsDisplay(pid) != entry.virtualID {
                do {
                    try Displays.mirror(pid, of: entry.virtualID)
                } catch {
                    disable(for: pid, forget: false)
                    failedRestores.insert(entry.persistentKey)
                    errors.append("The HiDPI virtual screen was turned off: \(error.localizedDescription)")
                }
            }
        }
        for d in displays where !SafeMode.isActive && (Store.value(in: table, for: d.persistentKey) as Bool?) == true
            && entries[d.id] == nil && !failedRestores.contains(d.persistentKey)
            && !d.isBuiltin && !isVirtual(d.id) && CGDisplayIsInMirrorSet(d.id) == 0 {
            do {
                try enable(for: d)
            } catch {
                failedRestores.insert(d.persistentKey)
                errors.append("\(d.name): could not restore the HiDPI virtual screen (\(error.localizedDescription)). It will be retried when the monitor reconnects, or turn it on again.")
            }
        }
        return errors
    }

    private func remember(_ key: String, _ on: Bool) {
        Store.setValue(on ? true : nil, in: table, for: key)
    }

    private func waitUntilOnline(_ id: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if Displays.onlineIDs().contains(id) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }
}
