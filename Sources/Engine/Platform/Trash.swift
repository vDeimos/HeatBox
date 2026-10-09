import Foundation

/// Moving a file to the Trash. The engine removes a file a person may still
/// want only this way (plan Section 1), and through this protocol, so tests
/// never touch the real Trash.
public protocol Trash: Sendable {
    /// Returns where the file is now, when the system says, so the move can be undone.
    @discardableResult
    func trash(_ file: URL) throws -> URL?
}

/// The Mac's own Trash.
public struct SystemTrash: Trash {
    public init() {}

    @discardableResult
    public func trash(_ file: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
