import Foundation

/// New-version notices (Phobos, ADR-010): the app never updates itself; it
/// can read one small file that names the newest version and say so.
public enum Versioning {
    public struct Notice: Equatable, Sendable {
        public let version: String
        /// Where to get it. Empty, or a web link.
        public let url: String
        public let note: String
    }

    /// True when `remote` is a later version than `local`: "2.10" is later than "2.9".
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func numbers(_ text: String) -> [Int] {
            text.split(separator: ".").map { part in Int(part.filter(\.isNumber)) ?? 0 }
        }
        let a = numbers(remote)
        let b = numbers(local)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Reads the small file that says which version is newest. A link in it
    /// that is not a web link is dropped, so the button can only open a page.
    public static func parseNotice(_ data: Data) -> Notice? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? String, !version.trimmed.isEmpty else { return nil }
        let link = (object["url"] as? String) ?? ""
        return Notice(version: version.trimmed, url: Links.isWebLink(link) ? link : "", note: (object["note"] as? String) ?? "")
    }

    /// The notice to show: only one that names a later version than this one.
    public static func notice(in data: Data, current: String) -> Notice? {
        guard let found = parseNotice(data), isNewer(found.version, than: current) else { return nil }
        return found
    }

    /// Where the notice is read from. Only a secure web address counts; with
    /// none set when the app was built, nothing is ever asked for.
    public static func noticeAddress(_ configured: String?) -> URL? {
        guard let text = configured?.trimmed, let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
}

/// The short introduction shown the first time the app opens.
public struct TourStep: Equatable, Sendable {
    public let symbol: String
    public let title: String
    public let text: String
}

public enum Tour {
    public static let steps: [TourStep] = [
        TourStep(symbol: "link", title: Messages.tourPasteTitle, text: Messages.tourPasteText),
        TourStep(symbol: "list.bullet.rectangle", title: Messages.tourPickTitle, text: Messages.tourPickText),
        TourStep(symbol: "square.grid.2x2", title: Messages.tourLibraryTitle, text: Messages.tourLibraryText),
        TourStep(symbol: "command", title: Messages.tourYoursTitle, text: Messages.tourYoursText),
    ]

    /// Moves through the steps; nil means the tour is over.
    public static func next(after step: Int) -> Int? { step < steps.count - 1 ? step + 1 : nil }
    public static func back(from step: Int) -> Int { max(step - 1, 0) }
}
