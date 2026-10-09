import Foundation

/// The person's own presets on disk (`presets.json`, ADR-007): a version
/// number and a list. A preset that cannot be read is skipped without
/// losing the others, and a file that cannot be read at all is set aside.
/// Presets pass through the extra-argument check on the way in, so a
/// preset from anywhere cannot carry a refused option.
public struct PresetStore: Sendable {
    public static let version = 1

    public let file: URL

    public init(file: URL) { self.file = file }
    public init(paths: AppPaths) { self.init(file: paths.presetsFile) }

    private struct Envelope: Encodable {
        var version: Int
        var presets: [Preset]
    }

    public static func encode(_ presets: [Preset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(version: version, presets: presets))
    }

    public static func decode(_ data: Data) -> [Preset]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["presets"] as? [Any] else { return nil }
        return entries.compactMap { entry in
            guard JSONSerialization.isValidJSONObject(entry), let data = try? JSONSerialization.data(withJSONObject: entry),
                  var preset = try? JSONDecoder().decode(Preset.self, from: data) else { return nil }
            preset.group = .user
            return preset
        }
    }

    public func save(_ presets: [Preset]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encode(presets).write(to: file, options: .atomic)
    }

    public func load() -> [Preset] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let presets = Self.decode(data) else {
            let aside = file.deletingLastPathComponent().appendingPathComponent("presets.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: file, to: aside)
            return []
        }
        return presets
    }
}
