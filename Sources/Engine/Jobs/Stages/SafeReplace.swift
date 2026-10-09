import Foundation

/// Putting a new version of a file in the old one's place without ever
/// risking both (plan Phase 6). The order is fixed: the result is first
/// moved beside the original under a temporary name, only then is the
/// original moved to the Trash, and last the result takes its final name.
/// Never the reverse: if any step fails, the original is still where it was
/// or in the Trash, and the result is still on disk.
public enum SafeReplace {
    public enum Failure: Error, Equatable {
        /// There is no finished result to put in place.
        case noResult
        /// The original could not be moved to the Trash. Nothing was changed;
        /// the result is at the path given.
        case originalKept(result: String)
    }

    /// Replaces `original` with `result`, which may have a different file
    /// ending. Returns where the result ended up: the original's name with
    /// the result's ending.
    @discardableResult
    public static func replace(original: String, with result: String, trash: any Trash) throws -> String {
        let size = ((try? FileManager.default.attributesOfItem(atPath: result))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw Failure.noResult }
        let folder = (original as NSString).deletingLastPathComponent
        let stem = ((original as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (result as NSString).pathExtension

        // 1. Beside the original, under a name nothing else uses.
        let waiting = (folder as NSString).appendingPathComponent(".\(UUID().uuidString).\(ext)")
        try FileManager.default.moveItem(atPath: result, toPath: waiting)
        // 2. Only now does the original go, and to the Trash, where it can be got back.
        do {
            try trash.trash(URL(fileURLWithPath: original))
        } catch {
            let kept = try Delivery.move(waiting, toFolder: folder, stem: stem + ".encoded", ending: ext.isEmpty ? "" : "." + ext)
            throw Failure.originalKept(result: kept)
        }
        // 3. The result takes the name. `move` never writes over a file.
        return try Delivery.move(waiting, toFolder: folder, stem: stem, ending: ext.isEmpty ? "" : "." + ext)
    }
}
