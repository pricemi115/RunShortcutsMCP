// SPDX-License-Identifier: Apache-2.0
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

    /// Verifies `side_effect` decodes when present and defaults to `true` (fail-closed) when absent.
    /// - Throws: Rethrows decoding errors from `makeAllowlist`.
    func testSideEffectDefaultsToTrueWhenAbsent() throws {
        let allowlist = try makeAllowlist()
        XCTAssertTrue(allowlist.entry(for: "TagNote")?.sideEffect == true)
        XCTAssertTrue(allowlist.entry(for: "WordOfTheDay")?.sideEffect == true)
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

    /// Verifies path resolution precedence: `--allowlist` argument, then env var, then nil (fail-closed).
    func testLocatorPrefersArgumentThenEnvThenNil() {
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: ["--allowlist", "/tmp/a.json"], environment: [:]),
            "/tmp/a.json"
        )
        XCTAssertEqual(
            AllowlistLocator.resolve(arguments: [], environment: ["RUNSHORTCUTS_ALLOWLIST": "/tmp/b.json"]),
            "/tmp/b.json"
        )
        XCTAssertNil(
            AllowlistLocator.resolve(arguments: [], environment: [:])
        )
    }

    /// Verifies a shortcut name that is empty or begins with `-` (argument-injection
    /// risk, CWE-88) is rejected at decode time.
    func testRejectsShortcutNameStartingWithHyphen() {
        let bad = """
        { "shortcuts": { "--output-path=/tmp/x": { "description": "evil" } } }
        """
        XCTAssertThrowsError(try Allowlist.decode(Data(bad.utf8))) { error in
            XCTAssertEqual(error as? AllowlistError, .invalidShortcutName("--output-path=/tmp/x"))
        }
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
        // Fails closed (nil) when nothing is discovered.
        XCTAssertNil(
            AllowlistLocator.resolve(arguments: [], environment: [:], discoveredConfig: { nil })
        )
    }

    /// Verifies per-shortcut `timeout_seconds`/`max_output_bytes` decode, and that the
    /// resolved values fall back to defaults and are clamped to the allowed bounds.
    func testPerShortcutLimitsDecodeAndClamp() throws {
        let json = """
        {
          "shortcuts": {
            "Quick":    { "description": "in range",   "timeout_seconds": 30,   "max_output_bytes": 2048 },
            "TooBig":   { "description": "over range",  "timeout_seconds": 9999, "max_output_bytes": 999999999 },
            "TooSmall": { "description": "under range", "timeout_seconds": 1,    "max_output_bytes": 10 },
            "Plain":    { "description": "no limits" }
          }
        }
        """
        let a = try Allowlist.decode(Data(json.utf8))

        // Raw decoded values.
        XCTAssertEqual(a.entry(for: "Quick")?.timeoutSeconds, 30)
        XCTAssertEqual(a.entry(for: "Quick")?.maxOutputBytes, 2048)

        // In-range resolves unchanged.
        XCTAssertEqual(a.timeout(for: "Quick"), 30)
        XCTAssertEqual(a.maxOutputBytes(for: "Quick"), 2048)

        // Over-range clamps to the max.
        XCTAssertEqual(a.timeout(for: "TooBig"), 300)
        XCTAssertEqual(a.maxOutputBytes(for: "TooBig"), 100_000_000)

        // Under-range clamps to the min.
        XCTAssertEqual(a.timeout(for: "TooSmall"), 5)
        XCTAssertEqual(a.maxOutputBytes(for: "TooSmall"), 1_024)

        // Missing values fall back to the hard-coded defaults.
        XCTAssertEqual(a.timeout(for: "Plain"), 120)
        XCTAssertEqual(a.maxOutputBytes(for: "Plain"), 10_000_000)

        // An unknown (non-allowlisted) name also yields the defaults.
        XCTAssertEqual(a.timeout(for: "Nope"), 120)
        XCTAssertEqual(a.maxOutputBytes(for: "Nope"), 10_000_000)
    }

    /// Verifies out-of-range limits produce warnings (per-entry, aggregated, and in the
    /// `list_shortcuts` payload) while in-range/absent limits produce none.
    func testOutOfRangeLimitsProduceWarnings() throws {
        let json = """
        {
          "shortcuts": {
            "Bad":  { "description": "x", "timeout_seconds": 9999, "max_output_bytes": 10 },
            "Good": { "description": "y", "timeout_seconds": 60 }
          }
        }
        """
        let a = try Allowlist.decode(Data(json.utf8))

        // Per-entry: Bad has two issues, Good none.
        XCTAssertEqual(try XCTUnwrap(a.entry(for: "Bad")).limitWarnings().count, 2)
        XCTAssertTrue(try XCTUnwrap(a.entry(for: "Good")).limitWarnings().isEmpty)

        // Aggregated warnings are name-prefixed and only for Bad.
        let all = a.limitWarnings()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { $0.contains("Bad") })

        // list_shortcuts payload carries configWarning for Bad, not Good.
        let items = try JSONDecoder().decode([ShortcutDescription].self, from: Data(a.describe(installed: []).utf8))
        XCTAssertNotNil(try XCTUnwrap(items.first { $0.name == "Bad" }).configWarning)
        XCTAssertNil(try XCTUnwrap(items.first { $0.name == "Good" }).configWarning)
    }
}
