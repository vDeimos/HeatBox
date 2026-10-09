import Foundation

/// One running copy of the app per data folder. Two copies reading and
/// writing the same queue, settings and Library would each restart the
/// other's downloads and overwrite what the other saved. That can happen:
/// macOS starts a second copy when the app is opened from another place (a
/// copy in Downloads beside the one in Applications, or an older version
/// under its earlier name).
///
/// The lock is the system's own on a file in the folder. It ends with the
/// process, however the process ends, so a crash never leaves the folder
/// locked.
public final class InstanceLock: @unchecked Sendable {
    public enum Claim {
        /// This copy has the folder until it quits or calls `release()`.
        case held(InstanceLock)
        /// Another running copy has it.
        case taken
        /// The folder cannot be locked (it cannot be written, or the disk has
        /// no locks). Not a reason to refuse to start.
        case unavailable
    }

    static let fileName = ".lock"

    private let guardLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Asks for the data folder at `root`, creating the folder if need be.
    public static func claim(_ root: URL) -> Claim {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Closed in the tools the app starts, so a tool that outlives the app
        // never keeps the folder locked.
        let descriptor = open(root.appendingPathComponent(fileName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .unavailable }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return .held(InstanceLock(descriptor: descriptor)) }
        let code = errno
        close(descriptor)
        return code == EWOULDBLOCK ? .taken : .unavailable
    }

    /// Gives the folder up before the process ends. Safe to call twice.
    public func release() {
        guardLock.lock()
        defer { guardLock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
