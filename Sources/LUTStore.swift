import CoreImage
import Foundation

/// Library of imported 3D LUTs. The original
/// .cube text is kept in Application Support so it can be exported again.
final class LUTStore: ObservableObject {
    static let shared = LUTStore()

    struct Record: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        let dimension: Int
    }

    /// Posted (object: the LUT's UUID) after a LUT is deleted from the library.
    static let didRemoveLUT = Notification.Name("BetterDPI.didRemoveLUT")

    @Published private(set) var records: [Record] = []
    /// Parsed tables, filled off the main thread. `.some(nil)` caches a failure.
    private var cache: [UUID: [String: Any]?] = [:]
    private var loading: Set<UUID> = []
    private let cacheLock = NSLock()
    private let loadQueue = DispatchQueue(label: "betterdpi.lut.load", qos: .userInitiated)
    private let indexKey = "lutLibrary"

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BetterDPI/LUTs", isDirectory: true)
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: indexKey),
           let saved = try? JSONDecoder().decode([Lenient<Record>].self, from: data) {
            records = saved.compactMap(\.value)
        }
        // Parse every LUT in the background so rendering never has to.
        for r in records { load(r.id) }
    }

    // MARK: Parsing

    struct Cube {
        let title: String?
        let dimension: Int
        let data: Data   // RGBA Float32, red changing fastest, as CIColorCube expects
    }

    static func parse(_ text: String) throws -> Cube {
        var title: String?
        var dimension = 0
        var domainMin = [0.0, 0.0, 0.0], domainMax = [1.0, 1.0, 1.0]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: \.isWhitespace)
            switch parts[0] {
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            case "LUT_3D_SIZE":
                guard parts.count == 2, let n = Int(parts[1]) else { throw lutError("Invalid LUT_3D_SIZE line.") }
                dimension = n
            case "LUT_1D_SIZE":
                throw lutError("One-dimensional or mixed CUBE files are not supported.")
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let v = parts.dropFirst().compactMap { Double($0) }
                guard v.count == 3 else { throw lutError("The CUBE input domain is invalid.") }
                if parts[0] == "DOMAIN_MIN" { domainMin = v } else { domainMax = v }
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                throw lutError("Input range lines are not supported.")
            default:
                let rgb = parts.compactMap { Float($0) }
                guard rgb.count == 3, parts.count == 3 else { continue }   // unknown keyword
                values.append(contentsOf: [rgb[0], rgb[1], rgb[2], 1])
            }
        }
        guard dimension > 0 else { throw lutError("The CUBE file does not contain LUT_3D_SIZE.") }
        guard (2...128).contains(dimension) else { throw lutError("The CUBE dimension must be between 2 and 128.") }
        guard domainMin == [0, 0, 0], domainMax == [1, 1, 1] else {
            throw lutError("Only CUBE files with a 0…1 input domain are supported.")
        }
        guard values.count == dimension * dimension * dimension * 4 else {
            throw lutError("Expected \(dimension * dimension * dimension) table entries, found \(values.count / 4).")
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return Cube(title: title, dimension: dimension, data: data)
    }

    private static func lutError(_ m: String) -> DisplayError { .message(m) }

    // MARK: Library

    @discardableResult
    func importFile(_ url: URL) throws -> Record {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw DisplayError.message("The LUT is not a valid UTF-8 CUBE file.")
        }
        let cube = try Self.parse(text)
        var name = cube.title.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        let base = name
        var n = 2
        while records.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        let record = Record(id: UUID(), name: name, dimension: cube.dimension)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: file(for: record.id), atomically: true, encoding: .utf8)
        cacheLock.withLock { cache[record.id] = Self.parameters(cube) }
        records.append(record)
        save()
        return record
    }

    /// Replace a LUT's table but keep its name, ID and every assignment.
    func replace(_ id: UUID, with url: URL) throws {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw DisplayError.message("The LUT is not a valid UTF-8 CUBE file.")
        }
        let cube = try Self.parse(text)
        try text.write(to: file(for: id), atomically: true, encoding: .utf8)
        records[i] = Record(id: id, name: records[i].name, dimension: cube.dimension)
        cacheLock.withLock { cache[id] = Self.parameters(cube) }
        save()
    }

    func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !records.contains(where: { $0.name == trimmed && $0.id != id }) else {
            throw DisplayError.message("A custom filter with this name already exists.")
        }
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].name = trimmed
        save()
    }

    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        cacheLock.withLock { cache[id] = nil }
        try? FileManager.default.removeItem(at: file(for: id))
        save()
        NotificationCenter.default.post(name: Self.didRemoveLUT, object: id)
    }

    func export(_ id: UUID, to url: URL) throws {
        try FileManager.default.copyItem(at: file(for: id), to: url)
    }

    func name(for id: UUID?) -> String? { records.first { $0.id == id }?.name }

    /// CIColorCubeWithColorSpace parameters for the LUT, or nil while it is still
    /// loading or when it cannot be read. Never reads or parses files itself, so
    /// it is cheap to call for every frame; each caller applies its own filter.
    func cubeParameters(for id: UUID?) -> [String: Any]? {
        guard let id else { return nil }
        let cached: [String: Any]?? = cacheLock.withLock { cache[id] }
        if let cached { return cached }
        load(id)
        return nil
    }

    /// Parse a LUT file on the background queue (once; failures are cached too).
    private func load(_ id: UUID) {
        let start: Bool = cacheLock.withLock {
            guard cache[id] == nil, !loading.contains(id) else { return false }
            loading.insert(id)
            return true
        }
        guard start else { return }
        let url = file(for: id)
        loadQueue.async { [weak self] in
            let p = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? Self.parse($0) }.map(Self.parameters)
            guard let self else { return }
            self.cacheLock.withLock {
                // replace() may have stored a newer table meanwhile; keep it.
                if self.cache[id] == nil { self.cache[id] = .some(p) }
                self.loading.remove(id)
            }
        }
    }

    private static func parameters(_ cube: Cube) -> [String: Any] {
        ["inputCubeDimension": cube.dimension, "inputCubeData": cube.data,
         "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any]
    }

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).cube") }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: indexKey)
    }
}
