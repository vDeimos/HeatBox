import Foundation

/// yt-dlp metadata rules that give a song proper tags (artist, title, album,
/// track number, year). They run inside yt-dlp, one video at a time, so they
/// also work for every item of a playlist.
///
/// Merged from both apps. From Phobos: only music is split at "Artist -
/// Title" (the site files it under Music, or names an artist itself), the
/// site's own artist, track name, album and track number win when it has
/// them, and nothing is guessed that the site does not say. From Studio: a
/// channel called "Name - Topic" or "NameVEVO" becomes "Name", junk such as
/// "(Official Video)" and leading track numbers are dropped, and the
/// playlist position or the playlist title can stand in for a missing track
/// number or album. Studio's guesses are options, off by default.
///
/// Tags go into `meta_*` fields, so file names change only when a naming
/// template asks for them. `clean_title` is a scratch field that is never
/// written into the file.
public enum MusicTags {
    /// Bracketed junk in video titles: "(Official Video)", "[Lyrics]", "(HD)", "(Full Album)".
    public static let junkTitlePattern = #"(?i)\s*[\(\[][^\)\]]*\b(?:official|lyrics?|lyric video|audio|visuali[sz]er|music video|video|hd|hq|4k|remaster(?:ed)?(?: \d{4})?|full album|full ep|album stream)\b[^\)\]]*[\)\]]"#

    /// A leading track number: "01.", "1 -", "03 ", "[04]", "(5)", "#6 -", "Track 7 -", "8)", "09:".
    /// Deliberately strict so real titles that start with a number survive
    /// ("7 Rings", "99 Luftballons", "4:44", "1-800-273-8255", "2 Become 1",
    /// "1999"). It carries no anchors or flags, so it can sit inside larger patterns.
    public static let leadingTrackNumber = #"(?:(?:track|no\.?)\s*)?(?:#?\d{1,3}\s*[.:)\-–—](?!\d)\s*|[\[(]\d{1,3}[\])]\s*|0\d\s+)"#

    /// "Artist - Song", with a hyphen, en dash or em dash.
    public static let artistTitlePattern = #"^(?!\d+\s*[-–—.)]\s)(?P<ta>.+?)\s+[-–—]\s+(?P<tt>.+)$"#

    /// Matches a title that comes with the site's Music category.
    public static let musicCategoryPattern = #"^(?:[^|]*\bMusic\b[^|]*)\|(?P<music_title>.+)$"#

    /// A channel's own suffix: "Name - Topic", "NameVEVO", "Name Official".
    public static let channelSuffixPattern = #"(?i)\s*(?:-\s*topic|vevo|official)\s*$"#

    /// Captures the title without its leading track number into the named group.
    static func numberStrippingPattern(into group: String) -> String {
        #"(?i)^\s*(?:"# + leadingTrackNumber + #")?(?P<"# + group + #">.+?)\s*$"#
    }

    static let leadingNumberRemovalPattern = #"(?i)^\s*(?:"# + leadingTrackNumber + #")(?=\S)"#

    /// The rules for a recipe, in the order they must run. Empty unless tags are active.
    public static func arguments(for recipe: DownloadRecipe) -> [String] {
        guard recipe.musicTagsActive else { return [] }
        var args: [String] = []
        func parse(_ rule: String) { args += ["--parse-metadata", rule] }
        func replace(_ fields: String, _ pattern: String) { args += ["--replace-in-metadata", fields, pattern, ""] }

        // 1. Strip a track number from the title, into a scratch field.
        var title = "title"
        if recipe.stripTitleNumbers {
            parse("title:" + numberStrippingPattern(into: "clean_title"))
            title = "clean_title,title"
        }

        // 2. Split "Artist - Song", for music only unless told otherwise.
        if recipe.splitArtistTitle {
            if recipe.splitOnlyMusic {
                parse("%(categories|)l|%(\(title))s:" + musicCategoryPattern)
                parse("%(music_title|)s:" + artistTitlePattern)
            } else {
                parse("%(\(title))s:" + artistTitlePattern)
            }
        }

        // 3. The site's own words first, then the split title, then the channel.
        parse("%(artist,ta,uploader|)s:%(meta_artist)s")
        parse("%(track,tt,\(title)|)s:%(meta_title)s")
        if recipe.albumFallback {
            parse("%(album,playlist_title,meta_title|)s:%(meta_album)s")
        } else {
            parse("%(album|)s:%(meta_album)s")
        }
        if recipe.trackNumbersFromPlaylist {
            parse(#"%(track_number,playlist_index|)s/%(n_entries|)s:^(?P<meta_track>\d+(?:/\d+)?)"#)
        } else {
            parse("%(track_number|)s:%(meta_track)s")
        }
        parse(#"%(album_artist,meta_artist,artist,uploader|)s:^(?P<meta_album_artist>.+)$"#)
        parse(#"%(release_year,upload_date|)s:^(?P<meta_date>\d{4})"#)

        // 4. Tidy what came out.
        if recipe.cleanTitles {
            replace("meta_artist,meta_album_artist", channelSuffixPattern)
            replace("meta_title,meta_album", junkTitlePattern)
        }
        if recipe.stripTitleNumbers {
            // A number after the artist ("Artist - 03. Song") or in the site's own track field.
            replace("meta_title", leadingNumberRemovalPattern)
        }
        return args
    }
}
