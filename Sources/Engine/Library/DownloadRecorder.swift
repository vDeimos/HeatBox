import Foundation

extension LibraryRecord {
    /// The record for a file a job has just delivered. What the download
    /// tool noted about the video comes first (a playlist's items are only
    /// known that way); what the job knows about a single video fills the gaps.
    public static func downloaded(job: Job, note: DownloadNote.Note?, path: String, now: Date) -> LibraryRecord {
        let single = job.source == .video
        func pick(_ noted: String?, _ known: String?) -> String {
            if let noted, !noted.isEmpty { return noted }
            if single, let known, !known.isEmpty { return known }
            return ""
        }
        var title = pick(note?.title, job.facts?.title)
        if title.isEmpty { title = Delivery.stemWithoutID(((path as NSString).lastPathComponent as NSString).deletingPathExtension) }
        var duration = note?.seconds.flatMap { $0 > 0 ? TimeText.clock($0.rounded()) : nil } ?? (single ? job.duration : "")
        if let clip = job.recipe.clip {
            title += Messages.clipSuffix
            // A clip is as long as what was cut out, when both ends are known.
            let end = clip.end ?? note?.seconds
            duration = end.map { TimeText.clock(max($0 - clip.start, 0).rounded()) } ?? ""
        }
        let link = note?.link ?? job.link
        return LibraryRecord(videoID: pick(note?.videoID, job.facts?.id), title: title, uploader: pick(note?.uploader, job.facts?.uploader),
                             duration: duration, site: job.site, choice: job.label, path: path, link: link, added: now,
                             bytes: ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value,
                             archiveID: note?.archiveID)
    }
}

/// Writes each file a job delivers into the Library, with its picture.
struct DownloadRecorder: Sendable {
    let library: LibraryRepository
    let job: Job
    let workspace: Workspace
    let clock: any EngineClock

    /// File endings a video's picture comes in.
    private static let pictureExtensions = ["jpg", "jpeg", "webp", "png"]

    /// `listed` is the file as the download tool named it; `final` is where it is now.
    func record(listed: String, final: String) async {
        let notes = (try? String(contentsOf: workspace.noteList, encoding: .utf8)) ?? ""
        let note = DownloadNote.note(for: listed, inLines: notes)
        var record = LibraryRecord.downloaded(job: job, note: note, path: final, now: clock.now())
        if let picture = picture(for: record.videoID) {
            record.thumbnail = library.storeThumbnail(from: picture, moving: true)
        } else if let saved = savedPicture(beside: final) {
            // The recipe saved the picture beside the video; that one stays where it is.
            record.thumbnail = library.storeThumbnail(from: saved, moving: false)
        }
        await library.add(record)
        // A re-encoded version kept beside its download is a copy of it.
        for copy in encodedCopies(of: final) {
            await library.addCopy(of: final, at: copy, label: Messages.libraryConvertedCopy, now: clock.now())
        }
    }

    /// The picture the tool wrote for this video. It is named by the video's
    /// id; a single video's job has only the one.
    private func picture(for videoID: String) -> URL? {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: workspace.thumbnails.path)) ?? [])
            .filter { Self.pictureExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        let name = files.first { !videoID.isEmpty && ($0 as NSString).deletingPathExtension == videoID }
            ?? (job.source == .video && files.count == 1 ? files[0] : nil)
        return name.map { workspace.thumbnails.appendingPathComponent($0) }
    }

    private func savedPicture(beside file: String) -> URL? {
        guard job.recipe.writeThumbnail else { return nil }
        let stem = (file as NSString).deletingPathExtension
        return Self.pictureExtensions.map { URL(fileURLWithPath: stem + "." + $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func encodedCopies(of file: String) -> [String] {
        guard job.recipe.encodeEnabled, !job.recipe.replaceOriginal else { return [] }
        let folder = (file as NSString).deletingLastPathComponent
        let prefix = ((file as NSString).lastPathComponent as NSString).deletingPathExtension + ".encoded."
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix(prefix) }.sorted().map { (folder as NSString).appendingPathComponent($0) }
    }
}
