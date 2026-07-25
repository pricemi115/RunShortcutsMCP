//
//  AllowlistTests.swift
//  RunShortcutsMCPTests
//
//  Unit tests for the pure allowlist logic: JSON decoding, the `side_effect`
//  default, default-deny lookups, the `describe` install-annotation, and the
//  allowlist-path resolution precedence.
//

import XCTest
@testable import RunShortcutsCore

/// Exercises `Allowlist`, `AllowlistEntry`, `ShortcutDescription`, and `AllowlistLocator`.
final class AllowlistTests: XCTestCase {
    /// (`String`) Representative allowlist JSON with one side-effecting and one read-only entry.
    private let json = """
    {
      "shortcuts": {
        "TagNote": {
          "description": "Append a live tag to an Apple Note.",
          "input": "json",
          "schema": { "tag": "string (name, no #)", "note": "string (exact note title)" },
          "side_effect": true
        },
        "WordOfTheDay": {
          "description": "Return today's word of the day.",
          "input": "none"
        }
      }
    }
    """

    /// Decodes `json` into an `Allowlist` for use by the individual tests.
    /// - Returns: (`Allowlist`) The decoded fixture allowlist.
    /// - Throws: `DecodingError` if the fixture JSON is malformed.
    private func makeAllowlist() throws -> Allowlist {
        try Allowlist.decode(Data(json.utf8))
    }

    /// Verifies entries decode with their fields (count, input hint, schema).
    /// - Throws: Rethrows decoding errors from `makeAllowlist`.
    func testDecodesEntries() throws {
        let allowlist = try makeAllowlist()
        XCTAssertEqual(allowlist.shortcuts.count, 2)
        XCTAssertEqual(allowlist.entry(for: "TagNote")?.input, "json")
        XCTAssertEqual(allowlist.entry(for: "TagNote")?.schema?["tag"], "string (name, no #)")
    }

    /// Verifies `side_effect` decodes when present and defaults to `false` when absent.
    /// - Throws: Rethrows decoding errors from `makeAllowlist`.
    func testSideEffectDefaultsToFalse() throws {
        let allowlist = try makeAllowlist()
        XCTAssertTrue(allowlist.entry(for: "TagNote")?.sideEffect == true)
        XCTAssertFalse(allowlist.entry(for: "WordOfTheDay")?.sideEffect == true)
    }

    /// Verifies unknown names are denied (default-deny).
    /// - Throws: Rethrows decoding errors from `makeAllowlist`.
    func testDefaultDeny() throws {
        let allowlist = try makeAllowlist()
        XCTAssertFalse(allowlist.isAllowed("rm-rf-everything"))
        XCTAssertNil(allowlist.entry(for: "rm-rf-everything"))
    }

    /// Verifies `describe` marks each entry installed/not-installed against the provided list.
    /// - Throws: Rethrows decoding errors, or fails via `XCTUnwrap` if expected entries are missing.
    func testDescribeMarksInstalled() throws {
        let allowlist = try makeAllowlist()
        let describe = allowlist.describe(installed: ["TagNote"])
        let items = try JSONDecoder().decode([ShortcutDescription].self, from: Data(describe.utf8))
        let tagNote = try XCTUnwrap(items.first { $0.name == "TagNote" })
        let word = try XCTUnwrap(items.first { $0.name == "WordOfTheDay" })
        XCTAssertTrue(tagNote.installed)
        XCTAssertFalse(word.installed)
    }

    /// Verifies path resolution precedence: `--allowlist` argument, then env var, then default.
    func testLocatorPrefersArgumentThenEnvThenDefault() {
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: ["--allowlist", "/tmp/a.json"], environment: [:]),
            "/tmp/a.json"
        )
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: [], environment: ["RUNSHORTCUTS_ALLOWLIST": "/tmp/b.json"]),
            "/tmp/b.json"
        )
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: [], environment: [:]),
            "allowlist.json"
        )
    }

    /// Verifies the auto-discovered config is used when present but is outranked by
    /// an explicit `--allowlist` argument and by the environment variable.
    func testLocatorUsesDiscoveredConfigWhenPresent() {
        let discovered: () -> String? = { "/Users/me/Library/Application Support/dev.grumptech.runshortcutsmcp/RunShortcutsMCP.config" }

        // Used when no argument/env is given.
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: [], environment: [:], discoveredConfig: discovered),
            "/Users/me/Library/Application Support/dev.grumptech.runshortcutsmcp/RunShortcutsMCP.config"
        )
        // Argument still wins.
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: ["--allowlist", "/tmp/a.json"], environment: [:], discoveredConfig: discovered),
            "/tmp/a.json"
        )
        // Env still wins over discovered.
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: [], environment: ["RUNSHORTCUTS_ALLOWLIST": "/tmp/b.json"], discoveredConfig: discovered),
            "/tmp/b.json"
        )
        // Falls through to default when nothing is discovered.
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: [], environment: [:], discoveredConfig: { nil }),
            "allowlist.json"
        )
    }
}
