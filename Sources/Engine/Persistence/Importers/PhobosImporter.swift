import Foundation

/// Brings Phobos's library, followed channels and settings over (Phase 7).
/// It only reads: the folder it is given is Phobos's own and nothing in it
/// is written, moved or removed. Pictures and the transcript database are
/// copied.
public enum PhobosImporter {
    public struct Result: Equatable, Sendable {
        public var records: [LibraryRecord] = []
        public var channels: [Channel] = []
        public var settings: AppSettings?
        /// Pictures to copy: record id -> the file in Phobos's `thumbs` folder.
        public var pictures: [UUID: URL] = [:]
        public var transcriptDatabase: URL?
        public var notes: [String] = []
    }

    /// Phobos wrote its dates as ISO 8601, with or without fractions.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }

    private static func objects(_ data: Data?) -> [[String: Any]]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    public static func records(fromLibrary data: Data?) -> [LibraryRecord] {
        (objects(data) ?? []).compactMap { entry in
            guard let path = entry["path"] as? String, path.hasPrefix("/"), let title = entry["title"] as? String else { return nil }
            let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            let videoID = (entry["videoID"] as? String) ?? ""
            return LibraryRecord(id: id, videoID: videoID, title: title, uploader: (entry["uploader"] as? String) ?? "",
                                 duration: (entry["duration"] as? String) ?? "", site: (entry["site"] as? String) ?? "",
                                 choice: (entry["choice"] as? String) ?? "", path: path, link: (entry["link"] as? String) ?? "",
                                 added: date(entry["date"]) ?? Date(timeIntervalSince1970: 0),
                                 watched: (entry["watched"] as? Bool) ?? false, isCopy: (entry["isCopy"] as? Bool) ?? false,
                                 bytes: ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value)
        }
    }

    public static func channels(fromFollowing data: Data?) -> [Channel] {
        (objects(data) ?? []).compactMap { entry in
            guard let link = entry["link"] as? String, Links.isWebLink(link), let name = entry["name"] as? String else { return nil }
            return Channel(id: (entry["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(), name: name,
                           site: (entry["site"] as? String) ?? "", link: link, seen: (entry["seen"] as? [String]) ?? [],
                           lastChecked: date(entry["lastChecked"]), choiceID: (entry["choiceID"] as? String) ?? PresetCatalog.compatibleID)
        }
    }

    /// Phobos's `settings.v2`, as the Preferences it saved. A field it lacks or this app lacks is skipped.
    public static func settings(fromPreferences data: Data?) -> AppSettings? {
        guard let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var fields = object
        // Phobos's names for what is called something else here.
        if let value = object["maxAtOnce"] { fields["maxConcurrent"] = value }
        var settings = AppSettings()
        guard let envelope = try? JSONSerialization.data(withJSONObject: ["version": SettingsStore.version, "settings": fields]),
              let decoded = SettingsStore.decode(envelope) else { return nil }
        settings = decoded
        settings.toolPaths = [:]
        // Phobos's saved sign-in is not copied (it stays Phobos's), and this app's tour is its own.
        settings.useSignIn = false
        settings.tourSeen = false
        return settings
    }

    /// Reads a Phobos support folder (`~/Library/Application Support/Phobos`) and its saved preferences.
    public static func read(supportFolder: URL, preferences: Data?) -> Result {
        var result = Result()
        let fm = FileManager.default
        result.records = records(fromLibrary: try? Data(contentsOf: supportFolder.appendingPathComponent("library.json")))
        result.channels = channels(fromFollowing: try? Data(contentsOf: supportFolder.appendingPathComponent("following.json")))
        result.settings = settings(fromPreferences: preferences)
        let thumbs = supportFolder.appendingPathComponent("thumbs", isDirectory: true)
        for record in result.records where !record.videoID.isEmpty && !record.videoID.contains("/") {
            let picture = thumbs.appendingPathComponent(record.videoID + ".jpg")
            if fm.fileExists(atPath: picture.path) { result.pictures[record.id] = picture }
        }
        let transcripts = supportFolder.appendingPathComponent("transcripts.sqlite")
        if fm.fileExists(atPath: transcripts.path) { result.transcriptDatabase = transcripts }
        if fm.fileExists(atPath: supportFolder.appendingPathComponent("queue.json").path) { result.notes.append(Messages.importPhobosQueueLeft) }
        if fm.fileExists(atPath: supportFolder.appendingPathComponent("cookies.txt").path) { result.notes.append(Messages.importPhobosSignInLeft) }
        return result
    }
}
