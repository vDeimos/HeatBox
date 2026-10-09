import Foundation

/// A small web server for the integration tests: it serves the files of one
/// folder on 127.0.0.1, answers `Range` requests (which is how the download
/// tool resumes a partial file), can slow media down so a test has time to
/// pause or cancel, and can drop a connection part-way through. It keeps a
/// record of what was asked for. Test code only.
final class RangeServer: @unchecked Sendable {
    struct Request: Equatable {
        var method: String
        var path: String
        /// The first byte asked for, when the request named a range.
        var rangeStart: Int?
    }

    let root: URL
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var bytesPerSecond = 0
    private var drops: [String: (after: Int, times: Int)] = [:]
    private var seen: [Request] = []
    private var sent: [String: Int] = [:]
    private var stopped = false

    init(root: URL) throws {
        self.root = root
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        listener = fd
        port = UInt16(bigEndian: actual.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)/\(path)" }

    /// Slows media files (not lists) to this many bytes a second; 0 is as fast as it goes.
    func throttle(bytesPerSecond rate: Int) {
        lock.lock(); bytesPerSecond = rate; lock.unlock()
    }

    /// Cuts the connection once `after` bytes of this file's body have gone out, `times` times.
    func drop(_ path: String, after: Int, times: Int = 1) {
        lock.lock(); drops["/" + path] = (after, times); lock.unlock()
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    /// How many bytes of a file's body have been sent in all.
    func bytesSent(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sent["/" + path] ?? 0
    }

    /// Stops accepting. The listening socket is closed by the thread that
    /// accepts on it, never from here: a socket closed under that thread
    /// frees its number, the next test's server can be given the same one,
    /// and the old thread would then answer the new server's requests from
    /// a folder that is gone ("not found" for a file that is there). So this
    /// only raises the flag and knocks once to wake the thread.
    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }
        let knock = socket(AF_INET, SOCK_STREAM, 0)
        guard knock >= 0 else { return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(knock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        close(knock)
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    deinit { stop() }

    // MARK: Serving

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if isStopped {
                if client >= 0 { close(client) }
                close(listener)
                return
            }
            if client < 0 {
                if errno == EINTR { continue }
                close(listener)
                return
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in
                serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var head = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil && head.count < 65_536 {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { return }
            head.append(buffer, count: count)
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        guard first.count >= 2 else { return }
        let method = first[0]
        let path = (first[1].split(separator: "?").first.map(String.init) ?? "/").removingPercentEncoding ?? first[1]
        var rangeStart: Int?
        var rangeEnd: Int?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("bytes=") {
                let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                rangeStart = parts.first.flatMap { Int($0) }
                rangeEnd = parts.count > 1 ? Int(parts[1]) : nil
            }
        }
        lock.lock()
        seen.append(Request(method: method, path: path, rangeStart: rangeStart))
        let rate = bytesPerSecond
        lock.unlock()

        let file = root.appendingPathComponent(String(path.dropFirst()))
        guard !path.contains(".."), FileManager.default.fileExists(atPath: file.path) else {
            send(client, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        // A file that is there but cannot be read just now (a busy machine out
        // of file handles) is not "not found": say so, and the tool asks again.
        guard let body = try? Data(contentsOf: file) else {
            send(client, Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let start = min(rangeStart ?? 0, body.count)
        let end = min(rangeEnd ?? (body.count - 1), body.count - 1)
        let slice = start <= end ? body.subdata(in: start..<(end + 1)) : Data()
        var header = rangeStart == nil ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\n"
        header += "Content-Type: \(Self.contentType(file.pathExtension))\r\nAccept-Ranges: bytes\r\nContent-Length: \(slice.count)\r\n"
        if rangeStart != nil { header += "Content-Range: bytes \(start)-\(end)/\(body.count)\r\n" }
        header += "Connection: close\r\n\r\n"
        guard send(client, Data(header.utf8)), method != "HEAD" else { return }

        let media = ["mp4", "m4a", "webm", "ts"].contains(file.pathExtension.lowercased())
        let slow = media && rate > 0
        // Twenty pieces a second when slowed down.
        let piece = slow ? max(1024, rate / 20) : 65_536
        var offset = 0
        while offset < slice.count {
            if let rule = dropRule(path), offset >= rule {
                consumeDrop(path)
                // Gone without a goodbye, as a connection that dropped.
                var hardClose = linger(l_onoff: 1, l_linger: 0)
                setsockopt(client, SOL_SOCKET, SO_LINGER, &hardClose, socklen_t(MemoryLayout<linger>.size))
                return
            }
            let next = min(offset + piece, slice.count)
            guard send(client, slice.subdata(in: offset..<next)) else { return }
            lock.lock(); sent[path, default: 0] += next - offset; lock.unlock()
            offset = next
            if slow { usleep(50_000) }
        }
    }

    /// The number of bytes after which this request is to be cut, if a drop is still owed for the path.
    private func dropRule(_ path: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let rule = drops[path], rule.times > 0 else { return nil }
        return rule.after
    }

    private func consumeDrop(_ path: String) {
        lock.lock()
        if let rule = drops[path] { drops[path] = (rule.after, rule.times - 1) }
        lock.unlock()
    }

    @discardableResult
    private func send(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(client, raw.baseAddress! + offset, raw.count - offset, 0)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
    }

    private static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp4": return "video/mp4"
        case "m4a": return "audio/mp4"
        case "xml": return "application/rss+xml"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        default: return "application/octet-stream"
        }
    }
}
