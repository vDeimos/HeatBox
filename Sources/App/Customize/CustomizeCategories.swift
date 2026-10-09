// CustomizeCategories.swift: the ten groups of settings in the Customize panel.
//
// Every control is bound to one field of the recipe on the Download screen
// (`DownloadDraft.edit`). What a setting comes to as a command, and whether
// the recipe can run at all, is the engine's business.

import Engine
import SwiftUI

enum CustomizeCategory: String, CaseIterable, Identifiable {
    case format, audio, encode, chapters, subtitles, metadata, playlist, network, naming, extra

    var id: String { rawValue }

    var label: String {
        switch self {
        case .format: return "Format"
        case .audio: return "Audio"
        case .encode: return "Re-encode"
        case .chapters: return "Chapters and sponsors"
        case .subtitles: return "Subtitles"
        case .metadata: return "Tags and cover"
        case .playlist: return "Playlist"
        case .network: return "Network"
        case .naming: return "File names"
        case .extra: return "Extra options"
        }
    }

    var symbol: String {
        switch self {
        case .format: return "film"
        case .audio: return "waveform"
        case .encode: return "arrow.triangle.2.circlepath"
        case .chapters: return "list.number"
        case .subtitles: return "captions.bubble"
        case .metadata: return "tag"
        case .playlist: return "list.bullet.rectangle"
        case .network: return "network"
        case .naming: return "textformat"
        case .extra: return "terminal"
        }
    }

    /// The recipe fields whose problems are shown in this group.
    var fields: Set<String> {
        switch self {
        case .format: return ["container", "customFormat", "customSort"]
        case .audio: return ["audioFormat", "gainDB", "evenLoudness"]
        case .encode: return ["encodeEnabled", "qualityFactor", "hardwareBitrateMbps"]
        case .chapters: return ["clip", "splitChapters", "sponsorCategories"]
        case .subtitles: return ["subtitleLanguages", "embedSubtitles", "subtitleSleep"]
        case .metadata: return ["embedThumbnail"]
        case .playlist: return ["playlistItems"]
        case .network: return ["rateLimit", "proxy", "cookieBrowser", "concurrentFragments", "retries", "sleepInterval", "maxSleepInterval"]
        case .naming: return ["customTemplate"]
        case .extra: return ["extraArguments"]
        }
    }
}

struct CustomizeCategoryView: View {
    let category: CustomizeCategory
    @ObservedObject var model: DownloadModel
    @Environment(\.palette) private var p

    private var r: DownloadRecipe { model.draft?.custom?.recipe ?? DownloadRecipe() }
    private var oneVideo: Bool { model.draft?.media != nil }

    private func bind<Value>(_ keyPath: WritableKeyPath<DownloadRecipe, Value>) -> Binding<Value> {
        Binding(get: { r[keyPath: keyPath] },
                set: { value in model.draft?.edit { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch category {
            case .format: format
            case .audio: audio
            case .encode: encode
            case .chapters: chapters
            case .subtitles: subtitles
            case .metadata: metadata
            case .playlist: playlist
            case .network: network
            case .naming: naming
            case .extra: extra
            }
        }
    }

    // MARK: Format

    @ViewBuilder
    private var format: some View {
        let video = r.mode != .audio
        let picked = !r.customFormat.trimmingCharacters(in: .whitespaces).isEmpty
        Rows([
            PickRow("Download", selection: bind(\.mode), name: \.label).row(),
            PickRow("File type", selection: bind(\.container), name: \.label).row(if: video),
            PickRow("Sharpest picture", selection: bind(\.maxResolution), name: \.label).row(if: video),
            PickRow("Video codec", selection: bind(\.videoCodec), name: \.label).row(if: video),
            PickRow("Audio codec", selection: bind(\.audioCodec), name: \.label).row(if: r.mode == .video),
            PickRow("Frames per second", selection: bind(\.frameRateLimit), name: \.label).row(if: video),
        ])
        if video {
            Rows([
                SwitchRow(title: "Prefer versions that fit the file type as they are",
                          detail: "Avoids converting, which takes time and can lose quality.",
                          isOn: bind(\.preferCompatibleStreams)).row(),
                SwitchRow(title: "Repackage into the file type when the site's file is another",
                          isOn: bind(\.forceRemux)).row(if: r.container != .automatic),
                SwitchRow(title: "Prefer open formats (VP9, Opus) when quality is equal",
                          isOn: bind(\.preferFreeFormats)).row(),
            ])
        }
        Rows([
            ControlRow(label: "Pick exact versions from the site's list") {
                Button("All Formats…") { model.showFormats(returnTo: .customize) }
                    .buttonStyle(PillButtonStyle())
            }.row(if: oneVideo),
            NoteRow(text: Messages.customizeFormatPicked).row(if: picked),
            TextRow(label: "Format expression", detail: "The download tool's own way of naming versions, such as 137+140. Leave empty to use the settings above.",
                    placeholder: "bv*+ba/b", wide: true, mono: true, text: bind(\.customFormat)).row(),
            TextRow(label: "Sort order", detail: "The download tool's own way of ranking versions. Leave empty to use the settings above.",
                    placeholder: "res:1080,vcodec:h264", wide: true, mono: true, text: bind(\.customSort)).row(),
        ])
    }

    // MARK: Audio

    @ViewBuilder
    private var audio: some View {
        if r.mode != .audio {
            Caption("These apply to an audio-only download. Choose \"Audio only\" under Format to use them.")
        }
        Rows([
            PickRow("Audio format", selection: bind(\.audioFormat), name: \.label).row(),
            PickRow("Quality", selection: bind(\.audioQuality), name: \.label)
                .row(if: !r.audioFormat.isLossless && r.audioFormat != .best),
        ])
        Rows([
            SwitchRow(title: "Even out the volume",
                      detail: "Brings every file to the same standard level, so tracks from different videos match.",
                      isOn: bind(\.evenLoudness)).row(),
            DecimalRow(label: "Volume change", detail: "0 leaves the volume alone.", unit: "dB", value: bind(\.gainDB)).row(),
            PickRow("Sample rate", selection: bind(\.sampleRate), name: \.label).row(),
            PickRow("Channels", selection: bind(\.channels), name: \.label).row(),
        ])
    }

    // MARK: Re-encode

    @ViewBuilder
    private var encode: some View {
        if r.mode == .audio {
            Caption("Re-encoding is for video. It is ignored for an audio-only download.")
        }
        Rows([
            SwitchRow(title: "Re-encode the video after downloading",
                      detail: "Makes the file smaller or more widely playable. It takes time and loses a little quality.",
                      isOn: bind(\.encodeEnabled)).row(),
        ])
        if r.encodeEnabled {
            Rows([
                PickRow("Encoder", selection: bind(\.encoder), name: \.label).row(),
                DecimalRow(label: "Quality factor", detail: "Lower is sharper and larger. 18 to 28 is the usual range.",
                           value: bind(\.qualityFactor)).row(if: r.encoder.usesQualityFactor),
                PickRow("Speed", selection: bind(\.encoderSpeed), name: \.label).row(if: r.encoder.usesQualityFactor),
                DecimalRow(label: "Bitrate", detail: "Higher is sharper and larger.", unit: "Mbps",
                           value: bind(\.hardwareBitrateMbps)).row(if: r.encoder.usesBitrate),
                PickRow("Picture height", detail: "A video is never made larger than it is.", selection: bind(\.scale), name: \.label).row(),
            ])
            Rows([
                SwitchRow(title: "Re-encode the sound too", detail: "Off keeps the sound as it is when the file type can hold it.",
                          isOn: bind(\.encodeAudio)).row(),
                PickRow("Sound quality", selection: bind(\.encodeAudioBitrate), name: \.label).row(),
                SwitchRow(title: "Replace the downloaded file",
                          detail: "The download goes to the Trash once the new file is in its place. Off keeps both.",
                          isOn: bind(\.replaceOriginal)).row(),
            ])
        }
    }

    // MARK: Chapters and SponsorBlock

    private func sponsorBinding(_ category: SponsorCategory) -> Binding<Bool> {
        Binding(get: { r.sponsorCategories.contains(category) },
                set: { on in
                    model.draft?.edit { recipe in
                        var chosen = Set(recipe.sponsorCategories)
                        if on { chosen.insert(category) } else { chosen.remove(category) }
                        // Kept in the order the choices are listed, so a saved preset reads the same every time.
                        recipe.sponsorCategories = SponsorCategory.allCases.filter(chosen.contains)
                    }
                })
    }

    private var commentLine: String {
        if model.draft?.chapterComment != nil { return "Using the list you picked." }
        return "Using the longest list, then the most liked."
    }

    @ViewBuilder
    private var chapters: some View {
        Rows([
            PickRow("Take chapters from", selection: bind(\.chapterSource), name: \.label).row(),
            ControlRow(label: commentLine) {
                Button("Pick a Comment…") { model.showComments() }
                    .buttonStyle(PillButtonStyle())
            }.row(if: r.chapterSource != .youtube && oneVideo),
            NoteRow(text: Messages.commentChaptersOneVideoOnly).row(if: r.chapterSource != .youtube && !oneVideo),
            SwitchRow(title: "Keep chapter marks in the file", isOn: bind(\.embedChapters)).row(),
            SwitchRow(title: "Also save each chapter as its own file", isOn: bind(\.splitChapters)).row(),
            NoteRow(text: Messages.customizeClipWinsOverChapters, warning: true).row(if: model.draft?.clipOverridesChapters ?? false),
            SwitchRow(title: "Put the chapter files in a folder of their own", isOn: bind(\.chaptersInFolder)).row(if: r.splitChapters),
            TextRow(label: "Leave out chapters whose title matches", detail: "A pattern, such as Intro|Outro. Leave empty to keep them all.",
                    wide: true, mono: true, text: bind(\.removeChaptersPattern)).row(),
        ])
        Grouped(title: "Sponsor segments (SponsorBlock)") {
            PickRow("Segments other viewers have marked", selection: bind(\.sponsorBlock), name: \.label)
            if r.sponsorBlock != .off {
                ForEach(SponsorCategory.allCases, id: \.self) { category in
                    RowDivider()
                    SwitchRow(title: category.label, isOn: sponsorBinding(category))
                }
            }
        }
        Rows([
            SwitchRow(title: "Cut exactly at the chosen times",
                      detail: "For a clip and for segments that are cut out. Slower, because the cut parts are re-encoded; off may start a second or two early.",
                      isOn: bind(\.exactCut)).row(),
            NoteRow(text: "To download only part of this video, use \"Download only part of this video\" on the Download screen.").row(if: oneVideo),
        ])
        if !oneVideo {
            partOfEach
        }
    }

    private var partOfEach: some View {
        let on = Binding(get: { r.clip != nil },
                         set: { value in model.draft?.edit { $0.clip = value ? Clip(start: 0, end: 60) : nil } })
        let start = Binding(get: { r.clip?.start ?? 0 },
                            set: { value in model.draft?.edit { $0.clip?.start = value } })
        let end = Binding(get: { r.clip?.end ?? 0 },
                          set: { value in model.draft?.edit { $0.clip?.end = value > 0 ? value : nil } })
        return Grouped {
            SwitchRow(title: "Download only part of each video", isOn: on)
            if r.clip != nil {
                RowDivider()
                HStack(spacing: 16) {
                    TimeField(label: "Start", seconds: start, lower: 0, upper: 86_400)
                    TimeField(label: "End", seconds: end, lower: 0, upper: 86_400)
                    Spacer(minLength: 0)
                    Text("An end of 0:00 means to the end.")
                        .font(p.font(12))
                        .foregroundColor(p.subtext)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: Subtitles

    @ViewBuilder
    private var subtitles: some View {
        let any = r.writeSubtitles || r.writeAutoSubtitles || r.embedSubtitles
        Rows([
            SwitchRow(title: "Get subtitles", isOn: bind(\.writeSubtitles)).row(),
            SwitchRow(title: "Get automatic captions where there are no subtitles", isOn: bind(\.writeAutoSubtitles)).row(),
            SwitchRow(title: "Put them inside the video file", isOn: bind(\.embedSubtitles)).row(if: r.mode != .audio),
            SwitchRow(title: "Also keep them as separate files", isOn: bind(\.keepSubtitleFiles)).row(if: r.embedSubtitles && r.mode != .audio),
        ])
        if any {
            Rows([
                TextRow(label: "Languages", detail: "Such as en, or en.*,de. \"all\" gets every one.", mono: true, text: bind(\.subtitleLanguages)).row(),
                PickRow("Subtitle format", selection: bind(\.subtitleFormat), name: \.label).row(),
                NumberRow(label: "Pause between subtitle requests", detail: "YouTube is strict about these.",
                          range: 0...600, unit: "s", value: bind(\.subtitleSleep)).row(),
            ])
        }
    }

    // MARK: Tags and cover

    @ViewBuilder
    private var metadata: some View {
        Rows([
            SwitchRow(title: "Write the title, uploader and date into the file", isOn: bind(\.embedMetadata)).row(),
            SwitchRow(title: "Put the cover image inside the file", isOn: bind(\.embedThumbnail)).row(),
            SwitchRow(title: "Save the cover image beside the file", isOn: bind(\.writeThumbnail)).row(),
            PickRow("Cover image format", selection: bind(\.thumbnailFormat), name: \.label).row(if: r.embedThumbnail || r.writeThumbnail),
            SwitchRow(title: "Save the description as a text file", isOn: bind(\.writeDescription)).row(),
            SwitchRow(title: "Save the video's details as a JSON file", isOn: bind(\.writeInfoJSON)).row(),
            SwitchRow(title: "Include the comments in the details", isOn: bind(\.writeComments)).row(if: r.writeInfoJSON),
        ])
        if r.embedMetadata {
            Grouped(title: "Music tags") {
                SwitchRow(title: "Write artist, album and track tags",
                          detail: "For audio downloads, so a music app files them properly.", isOn: bind(\.musicTags))
                if r.musicTags {
                    RowDivider()
                    SwitchRow(title: "Also for video downloads", isOn: bind(\.musicTagsOnVideo))
                    RowDivider()
                    SwitchRow(title: "Tidy titles", detail: "Removes \"(Official Video)\" and the like.", isOn: bind(\.cleanTitles))
                    RowDivider()
                    SwitchRow(title: "Remove leading track numbers from titles", isOn: bind(\.stripTitleNumbers))
                    RowDivider()
                    SwitchRow(title: "Split \"Artist - Song\" titles into artist and title", isOn: bind(\.splitArtistTitle))
                    if r.splitArtistTitle {
                        RowDivider()
                        SwitchRow(title: "Only for videos the site files as music", isOn: bind(\.splitOnlyMusic))
                    }
                    RowDivider()
                    SwitchRow(title: "Number tracks by their place in the playlist", isOn: bind(\.trackNumbersFromPlaylist))
                    RowDivider()
                    SwitchRow(title: "Use the playlist or the title as the album when the site names none", isOn: bind(\.albumFallback))
                    RowDivider()
                    SwitchRow(title: "Crop the cover to a square", isOn: bind(\.squareCover))
                    RowDivider()
                    SwitchRow(title: "Tag each chapter file as its own track", isOn: bind(\.tagChapterTracks))
                    RowDivider()
                    TextRow(label: "Genre", placeholder: "None", text: bind(\.genre))
                }
            }
        }
    }

    // MARK: Playlist

    @ViewBuilder
    private var playlist: some View {
        Caption(Messages.customizePlaylistOnly)
        Rows([
            TextRow(label: "Only these items", detail: "Such as 1-5, 8 or 3:10. Leave empty for all of them.",
                    placeholder: "All", mono: true, text: bind(\.playlistItems)).row(),
            SwitchRow(title: "Skip videos downloaded before",
                      detail: "Keeps a list of what has been downloaded with this switch on, and passes over anything on it.",
                      isOn: bind(\.useArchive)).row(),
        ])
        Caption("A playlist always carries on with the next item when one fails, and pauses briefly between items.")
    }

    // MARK: Network

    @ViewBuilder
    private var network: some View {
        Rows([
            TextRow(label: "Speed limit", detail: "Such as 500K or 2M. Empty uses the limit from Settings.",
                    placeholder: "From Settings", mono: true, text: bind(\.rateLimit)).row(),
            NumberRow(label: "Pieces downloaded at once", range: 1...16, value: bind(\.concurrentFragments)).row(),
            NumberRow(label: "Tries per piece", range: 0...100, value: bind(\.retries)).row(),
            NumberRow(label: "Shortest pause between downloads", range: 0...3600, unit: "s", value: bind(\.sleepInterval)).row(),
            NumberRow(label: "Longest pause between downloads", detail: "0 always waits the shortest pause.",
                      range: 0...3600, unit: "s", value: bind(\.maxSleepInterval)).row(),
        ])
        Rows([
            TextRow(label: "Proxy", placeholder: "socks5://127.0.0.1:1080", mono: true, text: bind(\.proxy)).row(),
            PickRow("Use the sign-in from a browser", selection: bind(\.cookieBrowser), name: \.label).row(),
            NoteRow(text: Messages.recipeCookiesBrowser, warning: true).row(if: r.cookieBrowser != .none),
        ])
    }

    // MARK: File names

    @ViewBuilder
    private var naming: some View {
        Rows([
            PickRow("Name files by", selection: bind(\.filenameTemplate), name: \.label).row(),
            TextRow(label: "Template", detail: "The download tool's own template. It must end in .%(ext)s.",
                    wide: true, mono: true, text: bind(\.customTemplate)).row(if: r.filenameTemplate == .custom),
            NoteRow(text: "Any choice but the first is used exactly as the download tool names the file.").row(if: r.filenameTemplate != .guided),
        ])
        Rows([
            SwitchRow(title: "Use only plain letters and digits in names", isOn: bind(\.restrictFilenames)).row(),
            SwitchRow(title: "Date the file when it was downloaded, not when it was published", isOn: bind(\.noMtime)).row(),
            SwitchRow(title: "Keep the separate video and audio files after joining them", isOn: bind(\.keepIntermediateFiles)).row(),
        ])
        Caption("\(Engine.productName) never replaces a file that exists: a name that is taken gets a number.")
    }

    // MARK: Extra

    @ViewBuilder
    private var extra: some View {
        Rows([
            TextRow(label: "Extra options for the download tool",
                    detail: "Added to the end of the command, as you would type them in Terminal.",
                    placeholder: "--no-check-certificates", wide: true, mono: true, text: bind(\.extraArguments)).row(),
        ])
        Caption("Options that run other programs, load other settings, read links from a file or choose the tools are refused, so a preset from someone else can only ever download.")
    }
}
