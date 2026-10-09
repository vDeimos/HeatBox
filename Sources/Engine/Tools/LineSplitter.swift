import Foundation

/// Splits a byte stream into lines on `\n` or `\r`. yt-dlp and FFmpeg redraw
/// progress with a bare `\r`, so both end a line. Empty lines are dropped,
/// which also makes `\r\n` one break. Bytes are held until their line ends,
/// so a character split across two reads is never decoded in halves.
///
/// With a `maxLineLength`, a line longer than that many bytes is cut there
/// and ends in `truncationMark`; the rest of it is read and thrown away, so a
/// tool that never ends a line cannot grow memory. Without one (a lookup,
/// whose whole answer is one very long line) a line may be any length.
public struct LineSplitter: Sendable {
    public static let truncationMark = "…"

    public let maxLineLength: Int?
    private var bytes: [UInt8] = []
    /// The line being read has already lost bytes to the limit.
    private var truncated = false

    public init(maxLineLength: Int? = nil) {
        self.maxLineLength = maxLineLength.map { max(1, $0) }
    }

    /// Adds bytes and returns every line they completed, in order.
    public mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var start = 0
            for index in 0..<buffer.count where buffer[index] == 0x0A || buffer[index] == 0x0D {
                hold(buffer[start..<index])
                if let line = takeLine() { lines.append(line) }
                start = index + 1
            }
            hold(buffer[start..<buffer.count])
        }
        return lines
    }

    /// The unfinished last line, if any. Call once the stream has ended.
    public mutating func flush() -> String? {
        takeLine()
    }

    private mutating func hold(_ piece: Slice<UnsafeRawBufferPointer>) {
        guard !piece.isEmpty else { return }
        let room = maxLineLength.map { max(0, $0 - bytes.count) } ?? piece.count
        if room >= piece.count {
            bytes.append(contentsOf: piece)
        } else {
            bytes.append(contentsOf: piece.prefix(room))
            truncated = true
        }
    }

    private mutating func takeLine() -> String? {
        defer {
            bytes.removeAll(keepingCapacity: bytes.count < 65_536)
            truncated = false
        }
        guard !bytes.isEmpty else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        return truncated ? text + Self.truncationMark : text
    }
}
