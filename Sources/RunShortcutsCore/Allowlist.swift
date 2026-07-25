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

    /// (`Double?`) Optional per-shortcut run timeout in seconds; `nil` uses the default. Clamped to the allowed range when applied.
    public let timeoutSeconds: Double?

    /// (`Int?`) Optional per-shortcut output cap in bytes; `nil` uses the default. Clamped to the allowed range when applied.
    public let maxOutputBytes: Int?

    /// Maps Swift property names to their JSON keys (notably `side_effect` → `sideEffect`).
    enum CodingKeys: String, CodingKey {
        case description, input, schema
        case sideEffect = "side_effect"
        case timeoutSeconds = "timeout_seconds"
        case maxOutputBytes = "max_output_bytes"
    }

    /// Creates an entry directly (used by tests and programmatic construction).
    /// - Parameters:
    ///   - description: (`String`) Human-readable explanation of the shortcut.
    ///   - input: (`String?`) Expected input-shape hint; defaults to `nil`.
    ///   - schema: (`[String: String]?`) Field → description map for structured input; defaults to `nil`.
    ///   - sideEffect: (`Bool`) Whether the shortcut changes state; defaults to `true` (fail-closed).
    ///   - timeoutSeconds: (`Double?`) Optional per-shortcut timeout override; defaults to `nil`.
    ///   - maxOutputBytes: (`Int?`) Optional per-shortcut output-cap override; defaults to `nil`.
    public init(description: String, input: String? = nil, schema: [String: String]? = nil, sideEffect: Bool = true, timeoutSeconds: Double? = nil, maxOutputBytes: Int? = nil) {
        self.description = description
        self.input = input
        self.schema = schema
        self.sideEffect = sideEffect
        self.timeoutSeconds = timeoutSeconds
        self.maxOutputBytes = maxOutputBytes
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
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        maxOutputBytes = try c.decodeIfPresent(Int.self, forKey: .maxOutputBytes)
    }

    /// Human-readable warnings for any configured limit that falls outside the allowed
    /// range (and will therefore be clamped when applied). Empty when everything is in range.
    /// - Returns: (`[String]`) Zero or more messages describing the out-of-range values.
    public func limitWarnings() -> [String] {
        var messages: [String] = []
        if let requested = timeoutSeconds, !ShortcutsRunner.timeoutRange.contains(requested) {
            let used = requested.clamped(to: ShortcutsRunner.timeoutRange)
            messages.append("timeout_seconds \(secondsText(requested)) is outside the allowed \(secondsText(ShortcutsRunner.timeoutRange.lowerBound))–\(secondsText(ShortcutsRunner.timeoutRange.upperBound)); using \(secondsText(used))")
        }
        if let requested = maxOutputBytes, !ShortcutsRunner.outputBytesRange.contains(requested) {
            let used = requested.clamped(to: ShortcutsRunner.outputBytesRange)
            messages.append("max_output_bytes \(requested) is outside the allowed \(ShortcutsRunner.outputBytesRange.lowerBound)–\(ShortcutsRunner.outputBytesRange.upperBound); using \(used)")
        }
        return messages
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

    /// The effective run timeout for a shortcut: its configured `timeout_seconds`
    /// (or the default), clamped to `ShortcutsRunner.timeoutRange`.
    /// - Parameter name: (`String`) The shortcut name.
    /// - Returns: (`TimeInterval`) Seconds within the allowed range.
    public func timeout(for name: String) -> TimeInterval {
        let requested = entry(for: name)?.timeoutSeconds ?? ShortcutsRunner.defaultTimeout
        return requested.clamped(to: ShortcutsRunner.timeoutRange)
    }

    /// The effective per-stream output cap for a shortcut: its configured
    /// `max_output_bytes` (or the default), clamped to `ShortcutsRunner.outputBytesRange`.
    /// - Parameter name: (`String`) The shortcut name.
    /// - Returns: (`Int`) Bytes within the allowed range.
    public func maxOutputBytes(for name: String) -> Int {
        let requested = entry(for: name)?.maxOutputBytes ?? ShortcutsRunner.defaultMaxOutputBytes
        return requested.clamped(to: ShortcutsRunner.outputBytesRange)
    }

    /// All per-shortcut limit warnings across the allowlist, each prefixed with the
    /// shortcut name (sorted). Empty when every entry's limits are in range.
    /// - Returns: (`[String]`) One message per out-of-range value.
    public func limitWarnings() -> [String] {
        shortcuts.sorted { $0.key < $1.key }.flatMap { name, entry in
            entry.limitWarnings().map { "shortcut '\(name)': \($0)" }
        }
    }

    /// Renders the allowlist as the JSON payload returned by `list_shortcuts`,
    /// annotating each entry with whether it is currently installed on the machine.
    /// - Parameter installed: (`[String]`) Names of shortcuts actually present (from `shortcuts list`), used to set each `installed` flag.
    /// - Returns: (`String`) A pretty-printed JSON array of `ShortcutDescription`, sorted by name; `"[]"` if encoding fails.
    public func describe(installed: [String]) -> String {
        let installedSet = Set(installed)
        let descriptions = shortcuts
            .sorted { $0.key < $1.key }
            .map { name, entry -> ShortcutDescription in
                let warnings = entry.limitWarnings()
                return ShortcutDescription(
                    name: name,
                    description: entry.description,
                    input: entry.input,
                    sideEffect: entry.sideEffect,
                    schema: entry.schema,
                    installed: installedSet.contains(name),
                    configWarning: warnings.isEmpty ? nil : warnings.joined(separator: "; ")
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
/// Formats a seconds value without a trailing `.0` when it is a whole number.
/// - Parameter value: (`Double`) Seconds.
/// - Returns: (`String`) e.g. `"300"` or `"2.5"`.
private func secondsText(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
}

/// Clamps a comparable value into a closed range.
private extension Comparable {
    /// - Parameter range: (`ClosedRange<Self>`) Inclusive bounds.
    /// - Returns: (`Self`) `self` limited to `range`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

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
    /// (`String?`) Present when the entry's configured limits are out of range (and were clamped); `nil` when fine.
    public let configWarning: String?
}
