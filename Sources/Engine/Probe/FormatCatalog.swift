import Foundation

/// One version of a video or track that a site offers.
public struct MediaFormat: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        /// Picture and sound in one stream.
        case combined
        case video
        case audio
        /// The site says nothing about what the file holds (a direct link to a file, usually).
        case unknown
    }

    /// The tool's id for this version, which a format choice is written with ("137", "hls-720").
    public var id: String
    public var ext: String
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    /// Nil when there is no picture or the site does not say what it is.
    public var videoCodec: String?
    /// Nil when there is no sound or the site does not say what it is.
    public var audioCodec: String?
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Total bitrate in kilobits a second.
    public var bitrate: Double?
    public var bytes: Int64?
    /// True when `bytes` is the tool's estimate rather than the site's figure.
    public var bytesEstimated: Bool
    /// The tool's own description of the size of the picture ("1920x1080", "audio only").
    public var resolution: String
    public var note: String
    public var transport: String
    public var dynamicRange: String?
    public var language: String?

    public init(id: String, ext: String = "", width: Int? = nil, height: Int? = nil, fps: Double? = nil,
                videoCodec: String? = nil, audioCodec: String? = nil, hasVideo: Bool, hasAudio: Bool,
                bitrate: Double? = nil, bytes: Int64? = nil, bytesEstimated: Bool = false, resolution: String = "",
                note: String = "", transport: String = "", dynamicRange: String? = nil, language: String? = nil) {
        self.id = id
        self.ext = ext
        self.width = width
        self.height = height
        self.fps = fps
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.bitrate = bitrate
        self.bytes = bytes
        self.bytesEstimated = bytesEstimated
        self.resolution = resolution
        self.note = note
        self.transport = transport
        self.dynamicRange = dynamicRange
        self.language = language
    }

    public var kind: Kind {
        switch (hasVideo, hasAudio) {
        case (true, true): return .combined
        case (true, false): return .video
        case (false, true): return .audio
        case (false, false): return .unknown
        }
    }

    /// The number a resolution is named by: 1080 for 1920x1080, and also for
    /// an upright 1080x1920 phone video.
    public var shortSide: Int? {
        if let width, let height { return min(width, height) }
        return height ?? width
    }

    public var isH264: Bool {
        guard let codec = videoCodec?.lowercased() else { return false }
        return codec.hasPrefix("avc") || codec.hasPrefix("h264")
    }

    /// Reads one entry of the tool's `formats` list. Nil for something that
    /// is not a version of the media: an entry without an id, or a storyboard
    /// (the strip of preview pictures).
    init?(_ raw: [String: Any]) {
        guard let id = raw["format_id"] as? String, !id.isEmpty else { return nil }
        let ext = (raw["ext"] as? String) ?? ""
        let vcodec = raw["vcodec"] as? String
        let acodec = raw["acodec"] as? String
        if vcodec == "none" && acodec == "none" && (ext == "mhtml" || (raw["format_note"] as? String) == "storyboard") { return nil }
        let width = Probe.number(raw["width"]).map { Int($0) }
        let height = Probe.number(raw["height"]).map { Int($0) }

        // "none" means the stream is absent; a missing value means the site
        // does not say. A version with a picture size and no word on either
        // codec is an ordinary file with picture and sound (many sites
        // outside YouTube report theirs so), and one that is known to have no
        // picture must be sound. With no clue at all, nothing is claimed.
        let hasVideo = vcodec.map { $0 != "none" } ?? (width != nil || height != nil)
        let hasAudio = acodec.map { $0 != "none" } ?? (vcodec == "none" || (vcodec == nil && hasVideo))
        let exact = Probe.number(raw["filesize"])
        let approximate = Probe.number(raw["filesize_approx"])
        let size = (exact ?? approximate).flatMap { $0 > 0 ? Int64($0) : nil }

        self.init(id: id, ext: ext, width: width, height: height, fps: Probe.number(raw["fps"]),
                  videoCodec: vcodec == "none" ? nil : vcodec, audioCodec: acodec == "none" ? nil : acodec,
                  hasVideo: hasVideo, hasAudio: hasAudio,
                  bitrate: Probe.number(raw["tbr"]), bytes: size, bytesEstimated: size != nil && exact == nil,
                  resolution: (raw["resolution"] as? String) ?? "", note: (raw["format_note"] as? String) ?? "",
                  transport: (raw["protocol"] as? String) ?? "",
                  dynamicRange: raw["dynamic_range"] as? String, language: raw["language"] as? String)
    }
}

/// The full table of versions for the "All formats" inspector (Studio's
/// format inspector), built from the same lookup as the guided choices.
public struct FormatCatalog: Equatable, Sendable {
    public enum Filter: String, CaseIterable, Sendable {
        case all, video, audio, combined
    }

    /// One row of the table, as text.
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let kind: String
        public let ext: String
        public let resolution: String
        public let fps: String
        public let videoCodec: String
        public let audioCodec: String
        public let bitrate: String
        public let size: String
        public let note: String
    }

    /// Best first: the tool lists worst first, the table shows the reverse.
    public let formats: [MediaFormat]

    public init(_ media: MediaFacts) {
        self.init(formats: media.formats)
    }

    /// `formats` in the tool's order (worst first).
    public init(formats: [MediaFormat]) {
        self.formats = formats.reversed()
    }

    public func formats(_ filter: Filter) -> [MediaFormat] {
        switch filter {
        case .all: return formats
        case .video: return formats.filter { $0.kind == .video }
        case .audio: return formats.filter { $0.kind == .audio }
        case .combined: return formats.filter { $0.kind == .combined }
        }
    }

    public func rows(_ filter: Filter = .all) -> [Row] {
        formats(filter).map(Self.row)
    }

    public static func row(_ format: MediaFormat) -> Row {
        let kind: String
        switch format.kind {
        case .combined: kind = Messages.formatKindCombined
        case .video: kind = Messages.formatKindVideo
        case .audio: kind = Messages.formatKindAudio
        case .unknown: kind = Messages.formatKindUnknown
        }
        var size = format.bytes.map(ByteText.string) ?? ""
        if format.bytesEstimated && !size.isEmpty { size = "~" + size }
        return Row(id: format.id, kind: kind, ext: format.ext,
                   resolution: format.resolution,
                   fps: format.fps.flatMap { $0 >= 1 ? "\(Int($0.rounded()))" : nil } ?? "",
                   videoCodec: format.videoCodec ?? "", audioCodec: format.audioCodec ?? "",
                   bitrate: format.bitrate.map { "\(Int($0.rounded()))k" } ?? "",
                   size: size, note: format.note)
    }

    /// The format choice for the rows a person picked, written the way the
    /// tool expects: one video stream joined to one audio stream ("137+140"),
    /// or a single version on its own. Nil when nothing usable is picked. The
    /// result goes into a recipe's `customFormat`.
    public func selector(for picked: Set<String>) -> String? {
        let chosen = formats.filter { picked.contains($0.id) }
        guard !chosen.isEmpty else { return nil }
        let video = chosen.first { $0.hasVideo }
        let audio = chosen.first { $0.kind == .audio }
        let ids = [video?.id, video?.hasAudio == true ? nil : audio?.id].compactMap { $0 }
        return ids.isEmpty ? chosen.first?.id : ids.joined(separator: "+")
    }
}

/// File sizes as text. Decimal units, as Finder shows them, and the same on
/// every machine whatever its language settings.
public enum ByteText {
    public static func string(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        if value < 1000 { return "\(Int(value)) bytes" }
        if value < 999_500 { return "\(Int((value / 1000).rounded())) KB" }
        if value < 9_950_000 { return decimal(value / 1_000_000, places: 1) + " MB" }
        if value < 999_500_000 { return "\(Int((value / 1_000_000).rounded())) MB" }
        return decimal(value / 1_000_000_000, places: 2) + " GB"
    }

    /// "1.9" rather than "1.90", "2" rather than "2.00".
    private static func decimal(_ value: Double, places: Int) -> String {
        var text = String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
