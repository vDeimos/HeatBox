import Foundation

/// The command as a person would type it: shell-quoted, identical to the
/// arguments that run except for the app's own bookkeeping.
public enum DisplayCommand {
    public static let program = "yt-dlp"

    public static func string(for plan: YtdlpCommand.Plan) -> String {
        ([program] + plan.visibleArguments.map(shellQuote)).joined(separator: " ")
    }

    /// Single-quotes anything a shell would treat specially.
    public static func shellQuote(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=,+@")
        if !text.isEmpty && text.unicodeScalars.allSatisfy({ safe.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
