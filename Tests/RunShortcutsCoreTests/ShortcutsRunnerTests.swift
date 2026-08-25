// SPDX-License-Identifier: Apache-2.0
//
//  ShortcutsRunnerTests.swift
//  RunShortcutsMCPTests
//
//  Exercises the subprocess wrapper's robustness guarantees — output capture,
//  stdin delivery, the wall-clock timeout, cancellation, and the per-stream
//  output cap — using ordinary Unix tools (`/bin/echo`, `/bin/cat`, `/bin/sleep`)
//  as stand-ins for the `shortcuts` CLI, via the internal `invoke(arguments:input:)`
//  seam. Also covers the non-blocking guarantee itself: `invoke` must never pin a
//  Swift-concurrency cooperative thread for the duration of a run.
//

import XCTest
@testable import RunShortcutsCore

final class ShortcutsRunnerTests: XCTestCase {

    /// Captures stdout and a zero exit code from a fast, well-behaved child.
    /// - Throws: Rethrows a launch error from `invoke`.
    func testCapturesStdoutAndZeroExit() async throws {
        let runner = ShortcutsRunner(executable: "/bin/echo")
        let result = try await runner.invoke(arguments: ["hello", "world"], input: nil)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello world\n")
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertFalse(result.timedOut)
    }

    /// Delivers stdin to the child and reads back what it echoes (`cat`).
    /// - Throws: Rethrows a launch error from `invoke`.
    func testWritesStdinAndCapturesIt() async throws {
        let runner = ShortcutsRunner(executable: "/bin/cat")
        let result = try await runner.invoke(arguments: [], input: "ping")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "ping")
    }

    /// A child that outlives the timeout is terminated well before it would finish,
    /// and the timeout is reported both in stderr and via `timedOut`.
    /// - Throws: Rethrows a launch error from `invoke`.
    func testTimeoutTerminatesLongRunningProcess() async throws {
        let runner = ShortcutsRunner(executable: "/bin/sleep", timeout: 0.5)
        let start = Date()
        let result = try await runner.invoke(arguments: ["5"], input: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4, "should terminate well before the 5s sleep")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("timed out"))
        XCTAssertTrue(result.timedOut)
    }

    /// Output beyond the cap is dropped (bounding memory) and flagged, without
    /// deadlocking on a child that writes far more than the cap.
    /// - Throws: Rethrows a launch error from `invoke`.
    func testCapsLargeOutput() async throws {
        let runner = ShortcutsRunner(executable: "/bin/cat", maxOutputBytes: 1024)
        let big = String(repeating: "a", count: 100_000)
        let result = try await runner.invoke(arguments: [], input: big)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 1024)
        XCTAssertTrue(result.stderr.contains("truncated"))
    }

    /// The non-blocking guarantee itself: four one-second sleeps run concurrently
    /// via a task group finish in roughly one second total, not four — proving
    /// `invoke` doesn't pin a cooperative thread for the duration of a run. Any
    /// design that blocks synchronously inside `invoke` fails this test.
    /// - Throws: Rethrows a launch error from `invoke`, or a task group error.
    func testConcurrentInvocationsDoNotBlock() async throws {
        let runner = ShortcutsRunner(executable: "/bin/sleep")
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = try await runner.invoke(arguments: ["1"], input: nil)
                }
            }
            try await group.waitForAll()
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.5, "four concurrent 1s sleeps should overlap, not serialize")
    }

    /// A timed-out invocation running concurrently with a fast one must not delay
    /// the fast one — the slow child's timeout wait cannot be blocking a thread the
    /// fast child needs.
    /// - Throws: Rethrows a launch error from `invoke`, or a task group error.
    func testTimeoutDoesNotStallOtherWork() async throws {
        let slow = ShortcutsRunner(executable: "/bin/sleep", timeout: 0.5)
        let fast = ShortcutsRunner(executable: "/bin/echo")

        async let slowResult = slow.invoke(arguments: ["5"], input: nil)

        let fastStart = Date()
        let fastResult = try await fast.invoke(arguments: ["hi"], input: nil)
        let fastElapsed = Date().timeIntervalSince(fastStart)

        XCTAssertLessThan(fastElapsed, 1, "the fast child should not be stalled by the slow one's timeout wait")
        XCTAssertEqual(fastResult.exitCode, 0)

        let result = try await slowResult
        XCTAssertTrue(result.timedOut)
    }

    /// Cancelling the calling task terminates the child promptly rather than
    /// letting it run to completion.
    /// - Throws: Rethrows an unexpected error from the task.
    func testCancellationTerminatesChild() async throws {
        let runner = ShortcutsRunner(executable: "/bin/sleep")
        let task = Task {
            try await runner.invoke(arguments: ["10"], input: nil)
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        let start = Date()
        let result = try await task.value
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3, "the child should be terminated promptly on cancellation")
        XCTAssertNotEqual(result.exitCode, 0)
    }

    /// Cancelling immediately — before the child has necessarily been attached to
    /// its `ProcessBox` — must still terminate it and must not hang. This is the
    /// attach-before-run race the cancellation handshake exists to close.
    /// - Throws: Rethrows an unexpected error from the task.
    func testCancellationBeforeAttachStillTerminates() async throws {
        let runner = ShortcutsRunner(executable: "/bin/sleep")
        let task = Task {
            try await runner.invoke(arguments: ["10"], input: nil)
        }
        task.cancel()

        let start = Date()
        _ = try await task.value
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3, "an immediate cancellation must not hang or let the child run to completion")
    }

    /// A fast-exiting child must not be reported as timed out — the pending
    /// SIGTERM/SIGKILL work items are cancelled once the child has already exited,
    /// so they never fire late against it.
    /// - Throws: Rethrows a launch error from `invoke`.
    func testWorkItemsAreCancelledOnFastExit() async throws {
        let runner = ShortcutsRunner(executable: "/bin/echo", timeout: 2)
        let start = Date()
        let result = try await runner.invoke(arguments: ["hi"], input: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.5, "should return promptly, not wait out the timeout")
        XCTAssertFalse(result.timedOut)
    }
}
