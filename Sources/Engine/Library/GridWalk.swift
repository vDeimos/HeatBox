import Foundation

/// Where an arrow key takes the selection in the Library: groups of tiles,
/// one under another, each laid out in rows of the same number of columns.
/// The tiles are numbered from 0 through every group in turn.
public enum GridWalk {
    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// How many tiles fit side by side: as many of `minimum` width, with
    /// `spacing` between them, as `width` holds, and never fewer than one.
    public static func columns(width: Double, minimum: Double, spacing: Double) -> Int {
        guard width.isFinite, minimum > 0 else { return 1 }
        return max(1, Int((width + spacing) / (minimum + spacing)))
    }

    /// The tile an arrow key moves to. `groups` holds the number of tiles in
    /// each group. With nothing selected, any arrow picks the first tile. At
    /// an edge the selection stays where it is. Nil when there are no tiles.
    public static func move(from current: Int?, groups: [Int], columns: Int, _ direction: Direction) -> Int? {
        let sizes = groups.filter { $0 > 0 }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return nil }
        guard let current, current >= 0, current < total else { return 0 }
        let columns = max(1, columns)

        switch direction {
        case .left: return max(0, current - 1)
        case .right: return min(total - 1, current + 1)
        case .up, .down: break
        }

        // Which group the tile is in, and where that group starts.
        var group = 0
        var start = 0
        while current >= start + sizes[group] {
            start += sizes[group]
            group += 1
        }
        let offset = current - start
        let column = offset % columns

        if direction == .down {
            let below = offset + columns
            if below < sizes[group] { return start + below }
            // A short last row: from the row above it, go to its last tile.
            let lastRowStart = ((sizes[group] - 1) / columns) * columns
            if offset < lastRowStart { return start + sizes[group] - 1 }
            guard group + 1 < sizes.count else { return current }
            // The first row of the next group, in the same column if it has one.
            let next = start + sizes[group]
            return next + min(column, sizes[group + 1] - 1)
        }

        if offset >= columns { return current - columns }
        guard group > 0 else { return current }
        // The last row of the group above, in the same column if it has one.
        let size = sizes[group - 1]
        let previous = start - size
        let lastRowStart = ((size - 1) / columns) * columns
        return previous + min(lastRowStart + column, size - 1)
    }
}
