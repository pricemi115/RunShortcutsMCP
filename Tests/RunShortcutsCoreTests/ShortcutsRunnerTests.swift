// SPDX-License-Identifier: Apache-2.0
//
//  ShortcutsRunnerTests.swift
//  RunShortcutsMCPTests
//
//  Exercises the subprocess wrapper's robustness guarantees — output capture,
//  stdin delivery, the wall-clock timeout, and the per-stream output cap — using
//  ordinary Unix tools (`/bin/echo`, `/bin/cat`, `/bin/sleep`) as stand-ins for
//  the `shortcuts` CLI, via the internal `invoke(arguments:input:)` seam.
//

import XCTest
@testable import RunShortcutsCore

final class ShortcutsRunnerTests: XCTestCase {

    /// Captures stdout and a zero exit code from a fast, well-behaved child.
    /// - Throws: Rethrows a launch error from `invoke`.
    func testCapturesStdoutAndZeroExit() throws {
        let runner = ShortcutsRunner(executable: "/bin/echo")
        let result = try runner.invoke(arguments: ["hello", "world"], input: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello world\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    /// Delivers stdin to the child and reads back what it echoes (`cat`).
    /// - Throws: Rethrows a launch error from `invoke`.
    func testWritesStdinAndCapturesIt() throws {
        let runner = ShortcutsRunner(executable: "/bin/cat")
        let result = try runner.invoke(arguments: [], input: "ping")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "ping")
    }

    /// A child that outlives the timeout is terminated well before it would finish,
    /// and the timeout is reported.
    /// - Throws: Rethrows a launch error from `invoke`.
    func testTimeoutTerminatesLongRunningProcess() throws {
        let runner = ShortcutsRunner(executable: "/bin/sleep", timeout: 0.5)
        let start = Date()
        let result = try runner.invoke(arguments: ["5"], input: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4, "should terminate well before the 5s sleep")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("timed out"))
    }

    /// Output beyond the cap is dropped (bounding memory) and flagged, without
    /// deadlocking on a child that writes far more than the cap.
    /// - Throws: Rethrows a launch error from `invoke`.
    func testCapsLargeOutput() throws {
        let runner = ShortcutsRunner(executable: "/bin/cat", maxOutputBytes: 1024)
        let big = String(repeating: "a", count: 100_000)
        let result = try runner.invoke(arguments: [], input: big)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 1024)
        XCTAssertTrue(result.stderr.contains("truncated"))
    }
}
