import Foundation

/// A named recipe.
public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public enum Group: String, Codable, CaseIterable, Sendable {
        /// Phobos's explained choices.
        case guided
        /// Studio's built-in presets.
        case advanced
        /// Made by the user.
        case user
    }

    /// Built-in presets have fixed readable ids (Phobos's choice ids are kept:
    /// `best`, `compatible`, `res1080`, `audio`). User presets get a UUID.
    public var id: String
    public var name: String
    public var group: Group
    public var recipe: DownloadRecipe

    public var isBuiltIn: Bool { group != .user }

    public init(id: String = UUID().uuidString, name: String, group: Group = .user, recipe: DownloadRecipe) {
        self.id = id
        self.name = name
        self.group = group
        self.recipe = recipe
    }

    private enum CodingKeys: String, CodingKey { case id, name, group, recipe }

    /// A preset saved by another version keeps what still fits (see `DownloadRecipe.lenient`).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = (try? container.decode(Group.self, forKey: .group)) ?? .user
        let raw = try container.decode(JSONValue.self, forKey: .recipe)
        guard case .object(let fields) = raw else {
            throw DecodingError.dataCorruptedError(forKey: .recipe, in: container, debugDescription: "A recipe is an object.")
        }
        recipe = DownloadRecipe.lenient(from: fields.mapValues(\.foundationValue))
    }
}

/// Any JSON value, so a recipe can be read field by field.
enum JSONValue: Decodable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null }
        else if let value = try? single.decode(Bool.self) { self = .bool(value) }
        else if let value = try? single.decode(Double.self) { self = .number(value) }
        else if let value = try? single.decode(String.self) { self = .string(value) }
        else if let value = try? single.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try single.decode([String: JSONValue].self)) }
    }

    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.foundationValue)
        case .object(let value): return value.mapValues(\.foundationValue)
        }
    }
}
