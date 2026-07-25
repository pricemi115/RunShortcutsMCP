// SPDX-License-Identifier: Apache-2.0
//
//  Allowlist.swift
//  RunShortcutsMCP
//
//  The default-deny allowlist model and its JSON (de)coding. Defines which Apple
//  Shortcuts the server is permitted to run, the per-shortcut metadata used to
//  gate and describe them, and the self-describing payload returned by the
//  `list_shortcuts` tool.
//

import Foundation

/// One entry in the allowlist: a single shortcut the server is permitted to run,
/// plus the metadata used to describe and gate it.
public struct AllowlistEntry: Codable, Equatable, Sendable {
    /// (`String`) Human-readable explanation of what the shortcut does.
    public let description: String
    /// (`String?`) Free-form hint about the expected input shape (e.g. `"json"`, `"text"`, `"none"`); `nil` if unspecified.
    public let input: String?
    /// (`[String: String]?`) Optional field-name → description map documenting a structured (JSON) input; `nil` if none.
    public let schema: [String: String]?
    /// (`Bool`) Whether running the shortcut changes state. When `true`, `run_shortcut` requires explicit confirmation.
    public let sideEffect: Bool

    /// Maps Swift property names to their JSON keys (notably `side_effect` → `sideEffect`).
    enum CodingKeys: String, CodingKey {
        case description, input, schema
        case sideEffect = "side_effect"
    }

    /// Creates an entry directly (used by tests and programmatic construction).
    /// - Parameters:
    ///   - description: (`String`) Human-readable explanation of the shortcut.
    ///   - input: (`String?`) Expected input-shape hint; defaults to `nil`.
    ///   - schema: (`[String: String]?`) Field → description map for structured input; defaults to `nil`.
    ///   - sideEffect: (`Bool`) Whether the shortcut changes state; defaults to `true` (fail-closed).
    public init(description: String, input: String? = nil, schema: [String: String]? = nil, sideEffect: Bool = true) {
        self.description = description
        self.input = input
        self.schema = schema
        self.sideEffect = sideEffect
    }

    /// Decodes an entry from JSON, defaulting `side_effect` to `true` when the key is
    /// absent (fail-closed: an unmarked shortcut is treated as state-changing and so
    /// requires confirmation).
    /// - Parameter decoder: (`Decoder`) The decoder positioned at a single entry object.
    /// - Throws: `DecodingError` if the required `description` field is missing or any field has the wrong type.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = try c.decode(String.self, forKey: .description)
        input = try c.decodeIfPresent(String.self, forKey: .input)
        schema = try c.decodeIfPresent([String: String].self, forKey: .schema)
        sideEffect = try c.decodeIfPresent(Bool.self, forKey: .sideEffect) ?? true
    }
}

/// Errors raised while loading or validating an allowlist.
public enum AllowlistError: Error, CustomStringConvertible, Equatable {
    /// A shortcut name is empty or begins with `-`, which the `shortcuts` CLI would
    /// misparse as a command-line option (CWE-88 argument injection).
    case invalidShortcutName(String)

    /// (`String`) Human-readable description of the error.
    public var description: String {
        switch self {
        case .invalidShortcutName(let name):
            return "Invalid shortcut name '\(name)': names must not be empty or begin with '-'."
        }
    }
}

/// The full set of allowlisted shortcuts, keyed by shortcut name. This is the
/// authority the server consults before running anything (default-deny).
public struct Allowlist: Equatable, Sendable {
    /// (`[String: AllowlistEntry]`) Allowlisted shortcuts keyed by their exact name.
    public let shortcuts: [String: AllowlistEntry]

    /// Creates an allowlist from an in-memory map.
    /// - Parameter shortcuts: (`[String: AllowlistEntry]`) Name → entry map of permitted shortcuts.
    public init(shortcuts: [String: AllowlistEntry]) {
        self.shortcuts = shortcuts
    }

    /// On-disk JSON shape: a top-level object with a `shortcuts` map.
    private struct File: Codable {
        let shortcuts: [String: AllowlistEntry]
    }

    /// Decodes an allowlist from raw JSON data.
    /// - Parameter data: (`Data`) UTF-8 JSON matching the `{ "shortcuts": { ... } }` shape.
    /// - Returns: (`Allowlist`) The decoded allowlist.
    /// - Throws: `DecodingError` if the JSON is malformed or does not match the expected shape.
    public static func decode(_ data: Data) throws -> Allowlist {
        let file = try JSONDecoder().decode(File.self, from: data)
        for name in file.shortcuts.keys where name.isEmpty || name.hasPrefix("-") {
            throw AllowlistError.invalidShortcutName(name)
        }
        return Allowlist(shortcuts: file.shortcuts)
    }

    /// Loads and decodes an allowlist from a file path.
    /// - Parameter path: (`String`) Absolute or relative filesystem path to the allowlist JSON.
    /// - Returns: (`Allowlist`) The decoded allowlist.
    /// - Throws: A `CocoaError` if the file cannot be read, or `DecodingError` if its contents are invalid JSON.
    public static func load(from path: String) throws -> Allowlist {
        try decode(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Looks up a single entry by name.
    /// - Parameter name: (`String`) Exact shortcut name to look up.
    /// - Returns: (`AllowlistEntry?`) The matching entry, or `nil` if the name is not allowlisted.
    public func entry(for name: String) -> AllowlistEntry? {
        shortcuts[name]
    }

    /// Reports whether a shortcut is permitted to run (default-deny).
    /// - Parameter name: (`String`) Exact shortcut name to test.
    /// - Returns: (`Bool`) `true` if the name is on the allowlist, otherwise `false`.
    public func isAllowed(_ name: String) -> Bool {
        shortcuts[name] != nil
    }

    /// Renders the allowlist as the JSON payload returned by `list_shortcuts`,
    /// annotating each entry with whether it is currently installed on the machine.
    /// - Parameter installed: (`[String]`) Names of shortcuts actually present (from `shortcuts list`), used to set each `installed` flag.
    /// - Returns: (`String`) A pretty-printed JSON array of `ShortcutDescription`, sorted by name; `"[]"` if encoding fails.
    public func describe(installed: [String]) -> String {
        let installedSet = Set(installed)
        let descriptions = shortcuts
            .sorted { $0.key < $1.key }
            .map { name, entry in
                ShortcutDescription(
                    name: name,
                    description: entry.description,
                    input: entry.input,
                    sideEffect: entry.sideEffect,
                    schema: entry.schema,
                    installed: installedSet.contains(name)
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(descriptions),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

/// A flattened, agent-facing view of one allowlist entry, including its name and
/// live-install status. This is the element type serialized by `Allowlist.describe`.
public struct ShortcutDescription: Codable, Equatable, Sendable {
    /// (`String`) The shortcut's exact name.
    public let name: String
    /// (`String`) Human-readable explanation of what the shortcut does.
    public let description: String
    /// (`String?`) Expected input-shape hint; `nil` if unspecified.
    public let input: String?
    /// (`Bool`) Whether running the shortcut changes state.
    public let sideEffect: Bool
    /// (`[String: String]?`) Field → description map for structured input; `nil` if none.
    public let schema: [String: String]?
    /// (`Bool`) Whether the shortcut is currently installed on this machine.
    public let installed: Bool
}
