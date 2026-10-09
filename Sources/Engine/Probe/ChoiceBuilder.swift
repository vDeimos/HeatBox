import Foundation

/// One explained way to download: a preset from `PresetCatalog`, described
/// for the video that was looked up.
public struct Choice: Equatable, Identifiable, Codable, Sendable {
    /// The preset's id (`best`, `compatible`, `res1080`, `audio`): the ids
    /// Phobos's saved queue and library already use.
    public let id: String
    public let title: String
    public let badge: String
    /// "about 312 MB", "size unknown" or "varies".
    public let size: String
    /// The estimate behind `size`, when there is one.
    public let bytes: Int64?
    public let explanation: String
    public let preset: Preset

    public var recipe: DownloadRecipe { preset.recipe }
    public var audioOnly: Bool { preset.recipe.mode == .audio }
}

/// Turns a lookup into the short list of choices the Download screen shows
/// (Phobos's tiers, sizes and explanations), each one a built-in preset.
public enum ChoiceBuilder {
    /// The resolutions a video is sorted into, largest first.
    public static let tiers = [2160, 1440, 1080, 720, 480, 360, 240, 144]

    /// The tier a resolution belongs to. Sites offer odd sizes (1072, 1920x804),
    /// so anything within a tenth below a tier counts as that tier.
    public static func bucket(_ resolution: Int) -> Int {
        for tier in tiers where Double(resolution) >= Double(tier) * 0.9 {
            return tier
        }
        return 144
    }

    public static func sizeText(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return Messages.sizeUnknown }
        return Messages.sizeAbout(ByteText.string(bytes))
    }

    /// The versions a single video offers, each explained.
    public static func choices(for media: MediaFacts) -> [Choice] {
        choices(from: media.formats)
    }

    public static func choices(from formats: [MediaFormat]) -> [Choice] {
        // The largest audio-only stream: the size of "Audio only", and what a
        // video-only stream is joined with.
        let audioSize = formats.filter { $0.kind == .audio }.compactMap(\.bytes).max()
        let hasAudio = formats.contains { $0.hasAudio }

        var tierSize: [Int: Int64] = [:]
        var tiersPresent = Set<Int>()
        var topResolution = 0
        var h264Top = 0
        var h264Size: Int64?
        for format in formats where format.hasVideo {
            guard let resolution = format.shortSide, resolution > 0 else { continue }
            let tier = bucket(resolution)
            tiersPresent.insert(tier)
            topResolution = max(topResolution, resolution)
            var size = format.bytes
            if let base = size, !format.hasAudio { size = base + (audioSize ?? 0) }
            if let size, size > (tierSize[tier] ?? 0) { tierSize[tier] = size }
            if format.isH264 {
                if resolution > h264Top {
                    h264Top = resolution
                    h264Size = size
                } else if resolution == h264Top, let size, size > (h264Size ?? 0) {
                    h264Size = size
                }
            }
        }

        var list: [Choice] = []
        let sortedTiers = tiersPresent.sorted(by: >)
        if let top = sortedTiers.first {
            list.append(make(PresetCatalog.best, title: Messages.choiceBestTitle,
                             badge: Messages.choiceResolution(topResolution), bytes: tierSize[top],
                             explanation: Messages.choiceBestExplanation))
        } else {
            list.append(make(PresetCatalog.best, title: Messages.choiceOriginalTitle,
                             badge: Messages.choiceOriginalBadge, bytes: nil,
                             explanation: Messages.choiceOriginalExplanation))
        }
        if h264Top > 0 {
            list.append(make(PresetCatalog.playsEverywhere, title: Messages.choiceCompatibleTitle,
                             badge: Messages.choiceCompatibleBadge(upTo: h264Top), bytes: h264Size,
                             explanation: Messages.choiceCompatibleExplanation))
        }
        // The top tier is "Best available"; a tier under 360 is not worth a choice.
        for tier in sortedTiers.dropFirst() {
            guard PresetCatalog.resolutionTiers.contains(tier), let preset = PresetCatalog.upTo(height: tier) else { continue }
            list.append(make(preset, title: Messages.choiceResolution(tier), badge: Messages.choiceTierBadge,
                             bytes: tierSize[tier],
                             explanation: Messages.choiceTierNotes[tier] ?? Messages.choiceTierFallback))
        }
        if hasAudio {
            list.append(make(PresetCatalog.audioOnly, title: Messages.choiceAudioTitle, badge: Messages.choiceAudioBadge,
                             bytes: audioSize, explanation: Messages.choiceAudioExplanation))
        }
        return list
    }

    /// Choices that work for any video: used for playlists, channels and
    /// several links, where there is no single video to measure.
    public static var generic: [Choice] {
        var list = [
            Choice(id: PresetCatalog.bestID, title: Messages.choiceBestTitle, badge: Messages.choiceAnyBestBadge,
                   size: Messages.sizeVaries, bytes: nil, explanation: Messages.choiceAnyBestExplanation,
                   preset: PresetCatalog.best),
            Choice(id: PresetCatalog.compatibleID, title: Messages.choiceCompatibleTitle, badge: Messages.choiceAnyCompatibleBadge,
                   size: Messages.sizeVaries, bytes: nil, explanation: Messages.choiceAnyCompatibleExplanation,
                   preset: PresetCatalog.playsEverywhere),
        ]
        for tier in genericTiers {
            guard let preset = PresetCatalog.upTo(height: tier) else { continue }
            list.append(Choice(id: preset.id, title: Messages.choiceUpTo(tier),
                               badge: Messages.choiceAnyTierBadges[tier] ?? Messages.choiceTierBadge,
                               size: Messages.sizeVaries, bytes: nil,
                               explanation: Messages.choiceAnyTierNotes[tier] ?? Messages.choiceTierFallback,
                               preset: preset))
        }
        list.append(Choice(id: PresetCatalog.audioID, title: Messages.choiceAudioTitle, badge: Messages.choiceAudioBadge,
                           size: Messages.sizeVaries, bytes: nil, explanation: Messages.choiceAudioExplanation,
                           preset: PresetCatalog.audioOnly))
        return list
    }

    /// The "Up to N p" choices offered when nothing was measured.
    public static let genericTiers = [1080, 720, 480]

    private static func make(_ preset: Preset, title: String, badge: String, bytes: Int64?, explanation: String) -> Choice {
        Choice(id: preset.id, title: title, badge: badge, size: sizeText(bytes), bytes: bytes.flatMap { $0 > 0 ? $0 : nil },
               explanation: explanation, preset: preset)
    }
}
