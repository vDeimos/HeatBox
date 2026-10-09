import Foundation

/// The person's own presets, and what can be done with them: save, rename,
/// delete, export and import (plan Phase 8). A value: the app keeps one,
/// changes it, and writes `presets` to `PresetStore`. Built-in presets are
/// not on the shelf and cannot be changed; they are offered beside it.
public struct PresetShelf: Equatable, Sendable {
    public private(set) var presets: [Preset]

    public init(_ presets: [Preset] = []) {
        self.presets = presets.map { preset in
            var own = preset
            own.group = .user
            return own
        }
    }

    public func preset(id: String) -> Preset? { presets.first { $0.id == id } }

    private func index(named name: String) -> Int? {
        presets.firstIndex { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// What a preset keeps of a recipe. A clip belongs to one video, so it
    /// is not saved: a preset says how to download, not which part of what.
    public static func storable(_ recipe: DownloadRecipe) -> DownloadRecipe {
        var recipe = recipe
        recipe.clip = nil
        return recipe
    }

    /// Saves a recipe under a name. A preset of the person's that already
    /// has the name is replaced, keeping its id; nil when the name is empty.
    @discardableResult
    public mutating func save(name: String, recipe: DownloadRecipe) -> Preset? {
        let name = name.trimmed
        guard !name.isEmpty else { return nil }
        if let index = index(named: name) {
            presets[index].name = name
            presets[index].recipe = Self.storable(recipe)
            return presets[index]
        }
        let preset = Preset(name: name, group: .user, recipe: Self.storable(recipe))
        presets.append(preset)
        return preset
    }

    /// False when the name is empty or another preset of the person's has it.
    @discardableResult
    public mutating func rename(id: String, to name: String) -> Bool {
        let name = name.trimmed
        guard !name.isEmpty, let index = presets.firstIndex(where: { $0.id == id }) else { return false }
        if let taken = self.index(named: name), taken != index { return false }
        presets[index].name = name
        return true
    }

    public mutating func remove(id: String) {
        presets.removeAll { $0.id == id }
    }

    /// A name nobody on the shelf has: "Name", then "Name 2", "Name 3".
    public func freeName(_ wanted: String) -> String {
        guard index(named: wanted) != nil else { return wanted }
        var number = 2
        while index(named: "\(wanted) \(number)") != nil { number += 1 }
        return "\(wanted) \(number)"
    }

    /// Takes in presets read from a file. Each gets a new id and, when its
    /// name is taken, a number, so an import never replaces anything.
    @discardableResult
    public mutating func add(imported: [Preset]) -> [Preset] {
        var added: [Preset] = []
        for preset in imported {
            let own = Preset(name: freeName(preset.name), group: .user, recipe: preset.recipe)
            presets.append(own)
            added.append(own)
        }
        return added
    }
}

/// Presets as a file to share (plan Phase 8). A preset from anywhere is
/// only a recipe: it passes through the same reading and the same checks as
/// one made here, and one whose extra options could run a program or load
/// other settings is refused whole (plan Section 1, "Deliberately left out").
public enum PresetExchange {
    public static let format = "studio-x-phobos.presets"
    public static let version = 1
    public static let fileExtension = "json"

    private struct Envelope: Encodable {
        var format: String
        var version: Int
        var presets: [Entry]
    }

    private struct Entry: Encodable {
        var name: String
        var recipe: DownloadRecipe
    }

    /// Ids and groups stay at home: a shared preset is a name and a recipe.
    public static func export(_ presets: [Preset]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let entries = presets.map { Entry(name: $0.name, recipe: PresetShelf.storable($0.recipe)) }
        return try encoder.encode(Envelope(format: format, version: version, presets: entries))
    }

    /// A file name for an export: the preset's own name for one, a general one for several.
    public static func suggestedFileName(for presets: [Preset]) -> String {
        let stem = presets.count == 1 ? Naming.clean(presets[0].name, limit: 80) : "\(Engine.productName) presets"
        return stem + "." + fileExtension
    }

    public struct Imported: Equatable, Sendable {
        /// Presets that may be added to the shelf.
        public var presets: [Preset] = []
        /// One sentence per preset that was refused.
        public var refused: [String] = []
        /// One sentence per preset that came over but cannot run as it is.
        public var notes: [String] = []

        /// One or two sentences saying what happened, for the screen.
        public var summary: String {
            var parts: [String] = []
            if !presets.isEmpty || refused.isEmpty { parts.append(Messages.presetsImported(presets.count)) }
            return (parts + refused + notes).joined(separator: " ")
        }
    }

    /// Reads a presets file. Nil when the data is not one. A preset without
    /// a name or a recipe is skipped; a recipe is read leniently, as a saved
    /// one is (`DownloadRecipe.lenient`).
    public static func read(_ data: Data) -> Imported? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["presets"] as? [Any] else { return nil }
        var result = Imported()
        for entry in entries {
            guard let fields = entry as? [String: Any],
                  let name = (fields["name"] as? String)?.trimmed, !name.isEmpty,
                  let saved = fields["recipe"] as? [String: Any] else { continue }
            let shown = String(name.prefix(80))
            // The extra options are judged as they were written, before
            // anything is read into a recipe.
            let extras = (saved["extraArguments"] as? String) ?? ""
            if let problem = ExtraArgsPolicy.check(extras).problems.first {
                result.refused.append(Messages.presetRefused(shown, why: Messages.recipeExtraArguments(problem)))
                continue
            }
            let recipe = PresetShelf.storable(DownloadRecipe.lenient(from: saved))
            if let issue = RecipeValidator.errors(in: recipe).first {
                result.notes.append(Messages.presetNeedsAttention(shown, why: issue.message))
            }
            result.presets.append(Preset(name: shown, group: .user, recipe: recipe))
        }
        return result
    }
}
