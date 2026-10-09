import Foundation

/// Where downloads are saved. These are defaults set in Settings (plan Rule 6).
public struct FolderRules: Codable, Equatable, Sendable {
    public var mainFolder: String
    public var audioFolder: String
    /// Site name -> folder chosen for that site.
    public var perSite: [String: String]
    public var playlistSubfolder: Bool

    public init(mainFolder: String, audioFolder: String, perSite: [String: String] = [:], playlistSubfolder: Bool = true) {
        self.mainFolder = mainFolder
        self.audioFolder = audioFolder
        self.perSite = perSite
        self.playlistSubfolder = playlistSubfolder
    }

    /// Videos under Movies, one folder per site; audio under Music.
    public static func standard(home: String = NSHomeDirectory()) -> FolderRules {
        named(Engine.productName, home: home)
    }

    /// What `standard` was while the app was called Studio x Phobos. An
    /// install from then that never saved its folders keeps this one, so its
    /// audio stays where it was (ADR-011).
    public static func legacy(home: String = NSHomeDirectory()) -> FolderRules {
        named("Studio x Phobos", home: home)
    }

    private static func named(_ audio: String, home: String) -> FolderRules {
        let home = home as NSString
        return FolderRules(mainFolder: home.appendingPathComponent("Movies"),
                           audioFolder: (home.appendingPathComponent("Music") as NSString)
                               .appendingPathComponent(Naming.clean(audio, limit: 60)))
    }

    public func folder(site: String, audioOnly: Bool, playlistTitle: String?) -> String {
        var base: String
        if audioOnly {
            base = audioFolder
        } else if let chosen = perSite[site], !chosen.isEmpty {
            base = chosen
        } else {
            base = (mainFolder as NSString).appendingPathComponent(Naming.clean(site, limit: 60))
        }
        if playlistSubfolder, let playlistTitle, !playlistTitle.isEmpty {
            base = (base as NSString).appendingPathComponent(Naming.clean(playlistTitle, limit: 80))
        }
        return base
    }
}
