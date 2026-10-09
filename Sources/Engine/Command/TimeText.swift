import Foundation

/// Times as people write them and as the download tool reads them.
public enum TimeText {
    /// "2:45" or "1:02:05"; a fraction of a second is kept ("2:45.5").
    public static func clock(_ seconds: Double) -> String {
        let rounded = (seconds * 1000).rounded() / 1000
        let whole = Int(rounded)
        let fraction = rounded - Double(whole)
        let h = whole / 3600, m = (whole % 3600) / 60, s = whole % 60
        var text = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if fraction > 0 {
            var digits = String(format: "%.3f", fraction)
            digits.removeFirst()                       // the leading 0
            while digits.hasSuffix("0") { digits.removeLast() }
            text += digits
        }
        return text
    }

    /// Reads "2:45", "1:02:05" or a plain number of seconds. Nil if it is none of those.
    public static func seconds(from text: String) -> Double? {
        let parts = text.trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
