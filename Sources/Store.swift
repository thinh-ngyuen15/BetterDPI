import AppKit

/// Per-display settings, keyed by `Display.persistentKey` inside named tables in
/// UserDefaults.
enum Store {
    /// Every table holding per-display values, so a display can be forgotten everywhere.
    static let displayTables = ["virtualHiDPI", "ditheringByDisplay", "compositorFilters",
                                "brightnessUpscaling", "knownDisplays"]

    static func value<T: Decodable>(in table: String, for key: String) -> T? {
        guard let data = UserDefaults.standard.dictionary(forKey: table)?[key] as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func setValue<T: Encodable>(_ value: T?, in table: String, for key: String) {
        var dict = UserDefaults.standard.dictionary(forKey: table) ?? [:]
        dict[key] = value.flatMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(dict, forKey: table)
    }

    static func keys(in table: String) -> [String] {
        Array((UserDefaults.standard.dictionary(forKey: table) ?? [:]).keys)
    }

    /// Remove everything stored for one display.
    static func forget(_ key: String) {
        for table in displayTables { setValue(Optional<Data>.none, in: table, for: key) }
    }

    /// Remove every BetterDPI setting.
    static func resetAll() {
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
    }
}

/// Displays seen before, so their settings can be listed and forgotten while offline.
enum KnownDisplays {
    struct Record: Codable {
        var name: String
        var lastSeen: Date
    }

    private static let table = "knownDisplays"
    static let pruneDaysKey = "forgetDisplaysAfterDays"   // 0 = never
    /// Displays forgotten while connected: not recorded again until they reconnect.
    private static var suppressed: Set<String> = []

    static func suppress(_ key: String) { suppressed.insert(key) }

    static func all() -> [(key: String, record: Record)] {
        Store.keys(in: table).compactMap { key in
            (Store.value(in: table, for: key) as Record?).map { (key, $0) }
        }.sorted { $0.record.lastSeen > $1.record.lastSeen }
    }

    static func touch(_ displays: [Display]) {
        let now = Date()
        suppressed.formIntersection(displays.map(\.persistentKey))   // disconnected: record again next time
        for d in displays where !VirtualHiDPI.shared.isVirtual(d.id) && !suppressed.contains(d.persistentKey) {
            let old: Record? = Store.value(in: table, for: d.persistentKey)
            // Avoid rewriting defaults on every refresh: once an hour is enough.
            if old?.name != d.name || now.timeIntervalSince(old?.lastSeen ?? .distantPast) > 3600 {
                Store.setValue(Record(name: d.name, lastSeen: now), in: table, for: d.persistentKey)
            }
        }
    }

    /// Forget displays not seen for the configured number of days.
    static func prune(online: Set<String>) {
        let days = UserDefaults.standard.integer(forKey: pruneDaysKey)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for (key, record) in all() where record.lastSeen < cutoff && !online.contains(key) {
            Store.forget(key)
        }
    }
}

/// Holding ⇧ Shift at launch starts the app without restoring anything:
/// no virtual screens, filters, upscaling, dithering or video filter windows.
enum SafeMode {
    private(set) static var isActive = false

    static func checkAtLaunch() {
        isActive = NSEvent.modifierFlags.contains(.shift)
    }

    static func leave() { isActive = false }
}

/// Decodes a value, or nil when it is unreadable, so one bad entry does not
/// drop a whole saved list.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// The stored value, or `fallback` when the key is missing or unreadable.
    /// Saved settings use this so a field added in a later version does not
    /// reset everything else.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
