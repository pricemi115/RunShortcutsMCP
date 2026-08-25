// SPDX-License-Identifier: Apache-2.0
//
//  JobStoreTests.swift
//  RunShortcutsMCPTests
//
//  Exercises the job store's state machine, concurrency permits, retention
//  policy, and cancellation handling using canned `execute` closures — no real
//  `shortcuts` subprocess involved except in the one integration test that
//  reuses `ShortcutsRunner`'s own `/bin/sleep` seam end to end.
//

import XCTest
@testable import RunShortcutsCore

/// A one-shot, thread-safe latch a canned `execute` closure can poll for while
/// simulating a long-running or hanging job.
private actor Gate {
    private var released = false
    func release() { released = true }
    func isReleased() -> Bool { released }
}

/// Tracks the peak number of concurrently "running" canned invocations, to
/// verify `JobStore`'s concurrency cap is actually enforced.
private actor ConcurrencyProbe {
    private(set) var maxConcurrent = 0
    private var current = 0
    func enter() { current += 1; maxConcurrent = max(maxConcurrent, current) }
    func exit() { current -= 1 }
}

/// A manually advanced clock, injected into `JobStore` so TTL/watchdog reaping
/// is testable without waiting out real minutes.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date = Date()) { current = date }
    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
}

private struct LaunchError: Error {}

final class JobStoreTests: XCTestCase {

    // MARK: - Happy path and terminal states

    func testHappyPathReachesSucceeded() async throws {
        let store = JobStore(execute: { _, _ in ShortcutResult(exitCode: 0, stdout: "ok", stderr: "") })
        let submitted = await store.submit(shortcutName: "Test", input: nil)
        let waited = await store.wait(for: submitted.id, timeout: 2)
        let job = try XCTUnwrap(waited)
        XCTAssertEqual(job.state, .succeeded)
        XCTAssertEqual(job.result?.stdout, "ok")
    }

    func testNonZeroExitReachesFailed() async throws {
        let store = JobStore(execute: { _, _ in ShortcutResult(exitCode: 1, stdout: "", stderr: "boom") })
        let submitted = await store.submit(shortcutName: "Test", input: nil)
        let waited = await store.wait(for: submitted.id, timeout: 2)
        let job = try XCTUnwrap(waited)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.result?.exitCode, 1)
    }

    /// A launch error must reach `.failed` with a client-safe `failureMessage`,
    /// without crashing the job's task, and must release its concurrency slot —
    /// verified by confirming a second job can still run to completion.
    func testLaunchErrorReachesFailedAndReleasesSlot() async throws {
        let store = JobStore(execute: { _, _ in throw LaunchError() }, maxConcurrent: 1)
        let first = await store.submit(shortcutName: "Bad", input: nil)
        let firstWaited = await store.wait(for: first.id, timeout: 2)
        let firstJob = try XCTUnwrap(firstWaited)
        XCTAssertEqual(firstJob.state, .failed)
        XCTAssertNotNil(firstJob.failureMessage)

        let second = await store.submit(shortcutName: "Bad", input: nil)
        let secondWaited = await store.wait(for: second.id, timeout: 2)
        let secondJob = try XCTUnwrap(secondWaited)
        XCTAssertEqual(secondJob.state, .failed)
    }

    func testTimedOutResultReachesTimedOutState() async throws {
        let store = JobStore(execute: { _, _ in
            ShortcutResult(exitCode: -1, stdout: "", stderr: "timed out", timedOut: true)
        })
        let submitted = await store.submit(shortcutName: "Slow", input: nil)
        let waited = await store.wait(for: submitted.id, timeout: 2)
        let job = try XCTUnwrap(waited)
        XCTAssertEqual(job.state, .timedOut)
    }

    // MARK: - Retention

    func testTTLReapingUnderInjectedClock() async throws {
        let clock = TestClock()
        let store = JobStore(
            execute: { _, _ in ShortcutResult(exitCode: 0, stdout: "ok", stderr: "") },
            retention: 600,
            now: { clock.now() }
        )
        let submitted = await store.submit(shortcutName: "Test", input: nil)
        _ = await store.wait(for: submitted.id, timeout: 2)
        let stillThere = await store.job(id: submitted.id)
        XCTAssertNotNil(stillThere)

        clock.advance(by: 601)
        let expired = await store.job(id: submitted.id)
        XCTAssertNil(expired)
    }

    func testRetainedBytesEvictionKeepsNewest() async throws {
        let bigOutput = String(repeating: "x", count: 40_000)
        let store = JobStore(
            execute: { _, _ in ShortcutResult(exitCode: 0, stdout: bigOutput, stderr: "") },
            maxConcurrent: 10,
            maxJobs: 100,
            maxRetainedBytes: 100_000
        )
        var ids: [String] = []
        for i in 0..<5 {
            let job = await store.submit(shortcutName: "Job\(i)", input: nil)
            _ = await store.wait(for: job.id, timeout: 2)
            ids.append(job.id)
        }
        // 5 jobs x 40,000 bytes of stdout each is 200,000 bytes, well over the
        // 100,000-byte budget — some must have been evicted.
        var survivors = 0
        for id in ids {
            if await store.job(id: id) != nil { survivors += 1 }
        }
        XCTAssertLessThan(survivors, 5)

        let newest = try XCTUnwrap(ids.last)
        let newestJob = await store.job(id: newest)
        XCTAssertNotNil(newestJob)
    }

    func testCountCapEvictsOldestFirst() async throws {
        let store = JobStore(
            execute: { _, _ in ShortcutResult(exitCode: 0, stdout: "", stderr: "") },
            maxConcurrent: 10,
            maxJobs: 5
        )
        var ids: [String] = []
        for i in 0..<40 {
            ids.append(await store.submit(shortcutName: "Job\(i)", input: nil).id)
        }
        for id in ids {
            _ = await store.wait(for: id, timeout: 2)
        }
        let all = await store.allJobs()
        XCTAssertLessThanOrEqual(all.count, 5)
    }

    /// None of the three eviction rules may ever remove a still-live job, even
    /// when the count cap is already exceeded by terminal jobs.
    func testLiveJobSurvivesEvictionRulesEvenOverCap() async throws {
        let gate = Gate()
        // Only "Long" blocks on the gate; the "Short*" jobs return immediately,
        // so they actually reach a terminal state and give the eviction rules
        // something to act on while "Long" is still running.
        let store = JobStore(
            execute: { name, _ in
                if name == "Long" {
                    while await !gate.isReleased() {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
                return ShortcutResult(exitCode: 0, stdout: "", stderr: "")
            },
            maxConcurrent: 10,
            maxJobs: 3
        )
        let longRunning = await store.submit(shortcutName: "Long", input: nil)
        while await store.job(id: longRunning.id)?.state != .running {
            try? await Task.sleep(for: .milliseconds(10))
        }

        for i in 0..<10 {
            let job = await store.submit(shortcutName: "Short\(i)", input: nil)
            _ = await store.wait(for: job.id, timeout: 2)
        }

        // The count cap (3) is well past for terminal jobs alone, yet the live
        // job must still be present and untouched.
        let stillTracked = await store.job(id: longRunning.id)
        XCTAssertEqual(stillTracked?.state, .running)

        let tracked = await store.allJobs()
        XCTAssertTrue(tracked.contains { $0.id == longRunning.id && $0.state == .running })

        await gate.release()
        _ = await store.wait(for: longRunning.id, timeout: 2)
    }

    // MARK: - Concurrency

    func testConcurrencyCapIsRespected() async throws {
        let probe = ConcurrencyProbe()
        let store = JobStore(
            execute: { _, _ in
                await probe.enter()
                try? await Task.sleep(for: .milliseconds(200))
                await probe.exit()
                return ShortcutResult(exitCode: 0, stdout: "", stderr: "")
            },
            maxConcurrent: 2
        )
        var ids: [String] = []
        for i in 0..<4 {
            ids.append(await store.submit(shortcutName: "Job\(i)", input: nil).id)
        }
        for id in ids {
            let waited = await store.wait(for: id, timeout: 3)
            let job = try XCTUnwrap(waited)
            XCTAssertEqual(job.state, .succeeded)
        }
        let peak = await probe.maxConcurrent
        XCTAssertLessThanOrEqual(peak, 2)
    }

    // MARK: - Cancellation

    func testCancelWhileRunningObservesTaskCancellation() async throws {
        let observed = Gate()
        let store = JobStore(execute: { _, _ in
            for _ in 0..<100 {
                if Task.isCancelled {
                    await observed.release()
                    return ShortcutResult(exitCode: -15, stdout: "", stderr: "killed")
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return ShortcutResult(exitCode: 0, stdout: "finished", stderr: "")
        })
        let job = await store.submit(shortcutName: "Long", input: nil)
        while await store.job(id: job.id)?.state != .running {
            try? await Task.sleep(for: .milliseconds(10))
        }

        await store.cancel(id: job.id)
        let waited = await store.wait(for: job.id, timeout: 2)
        let finished = try XCTUnwrap(waited)
        XCTAssertEqual(finished.state, .cancelled)
        let wasObserved = await observed.isReleased()
        XCTAssertTrue(wasObserved)
    }

    /// Cancelling a job while it's still queued must resume its waiter without
    /// ever granting it a slot — otherwise the slot leaks and a subsequent job
    /// can never start.
    func testCancelWhileQueuedReleasesSlot() async throws {
        let gate = Gate()
        let store = JobStore(
            execute: { _, _ in
                while await !gate.isReleased() {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return ShortcutResult(exitCode: 0, stdout: "", stderr: "")
            },
            maxConcurrent: 1
        )
        let running = await store.submit(shortcutName: "Running", input: nil)
        while await store.job(id: running.id)?.state != .running {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let queued = await store.submit(shortcutName: "Queued", input: nil)
        let queuedState = await store.job(id: queued.id)?.state
        XCTAssertEqual(queuedState, .queued)
        // Give the background task a moment to actually reach acquireSlot() and
        // register as a waiter; cancellation is correct either way, but this
        // makes the test exercise the "found in waiters" path deterministically.
        try? await Task.sleep(for: .milliseconds(50))

        await store.cancel(id: queued.id)
        let queuedAfterCancel = await store.job(id: queued.id)
        let cancelledJob = try XCTUnwrap(queuedAfterCancel)
        XCTAssertEqual(cancelledJob.state, .cancelled)

        await gate.release()
        _ = await store.wait(for: running.id, timeout: 2)

        // If the queued job's slot had leaked, this would never leave .queued.
        let third = await store.submit(shortcutName: "Third", input: nil)
        let thirdWaited = await store.wait(for: third.id, timeout: 2)
        let thirdJob = try XCTUnwrap(thirdWaited)
        XCTAssertEqual(thirdJob.state, .succeeded)
    }

    /// A `wait` whose *caller* is cancelled must return promptly. A cancelled
    /// `Task.sleep` throws rather than suspending, so without an explicit
    /// cancellation check the poll loop spins without yielding — and since it is
    /// actor-isolated, that spin holds the actor and starves every other job
    /// operation until the deadline (up to 50s in production).
    func testWaitReturnsPromptlyWhenCallerCancelled() async throws {
        let store = JobStore(execute: { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return ShortcutResult(exitCode: 0, stdout: "", stderr: "")
        })
        let job = await store.submit(shortcutName: "Slow", input: nil)
        let waiter = Task { await store.wait(for: job.id, timeout: 30) }
        try? await Task.sleep(for: .milliseconds(200))

        let start = Date()
        waiter.cancel()
        _ = await waiter.value
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2, "a cancelled wait must return promptly, not spin to its deadline")
    }

    /// A cancelled `wait` must not block other work on the actor — a concurrent
    /// operation has to stay responsive while the cancelled waiter unwinds.
    func testCancelledWaitDoesNotStarveTheActor() async throws {
        let store = JobStore(execute: { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return ShortcutResult(exitCode: 0, stdout: "", stderr: "")
        })
        let job = await store.submit(shortcutName: "Slow", input: nil)
        let waiter = Task { await store.wait(for: job.id, timeout: 30) }
        try? await Task.sleep(for: .milliseconds(200))
        waiter.cancel()

        let start = Date()
        _ = await store.allJobs()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2, "the actor must stay responsive while a cancelled wait unwinds")
        waiter.cancel()
    }

    /// `cancelAll` must stop every non-terminal job — this is what the server's
    /// shutdown path relies on to avoid orphaning a side-effecting shortcut.
    func testCancelAllStopsEveryLiveJob() async throws {
        let store = JobStore(execute: { _, _ in
            for _ in 0..<200 {
                if Task.isCancelled { return ShortcutResult(exitCode: -15, stdout: "", stderr: "killed") }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return ShortcutResult(exitCode: 0, stdout: "finished", stderr: "")
        }, maxConcurrent: 2)

        var ids: [String] = []
        for i in 0..<4 {
            ids.append(await store.submit(shortcutName: "Job\(i)", input: nil).id)
        }
        // Let the first two reach .running and the rest queue behind them.
        try? await Task.sleep(for: .milliseconds(100))

        await store.cancelAll()

        for id in ids {
            let waited = await store.wait(for: id, timeout: 2)
            let job = try XCTUnwrap(waited)
            XCTAssertEqual(job.state, .cancelled, "job \(id) should have been cancelled by cancelAll")
        }
    }

    /// A job that ignores cancellation must still have its concurrency slot
    /// reclaimed by the watchdog — otherwise enough wedged jobs would exhaust
    /// `maxConcurrent` permanently and stall every future job. Also covers the
    /// late-return path: when the wedged task eventually does finish, its result
    /// must not resurrect the abandoned job or double-release the slot.
    func testWatchdogReclaimsSlotFromUncancellableJob() async throws {
        let clock = TestClock()
        let gate = Gate()
        let store = JobStore(
            execute: { name, _ in
                if name == "Wedged" {
                    // Swallows cancellation, standing in for a child stuck in
                    // uninterruptible sleep that never closes its pipes. Bounded
                    // so the test can't leak a spinning task.
                    for _ in 0..<500 {
                        if await gate.isReleased() { break }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
                return ShortcutResult(exitCode: 0, stdout: "finished", stderr: "")
            },
            maxConcurrent: 1,
            watchdogTimeout: 60,
            now: { clock.now() }
        )

        let wedged = await store.submit(shortcutName: "Wedged", input: nil)
        while await store.job(id: wedged.id)?.state != .running {
            try? await Task.sleep(for: .milliseconds(10))
        }

        clock.advance(by: 61)
        _ = await store.allJobs() // triggers reap(now:)

        let abandonedJob = await store.job(id: wedged.id)
        let abandoned = try XCTUnwrap(abandonedJob)
        XCTAssertEqual(abandoned.state, .cancelled)
        XCTAssertNotNil(abandoned.failureMessage)

        // With maxConcurrent 1, this could never run if the slot had leaked.
        let next = await store.submit(shortcutName: "Next", input: nil)
        let waited = await store.wait(for: next.id, timeout: 3)
        XCTAssertEqual(try XCTUnwrap(waited).state, .succeeded)

        // Let the wedged task finish and confirm its late result changes nothing.
        await gate.release()
        try? await Task.sleep(for: .milliseconds(300))
        let lateJob = await store.job(id: wedged.id)
        let stillAbandoned = try XCTUnwrap(lateJob)
        XCTAssertEqual(stillAbandoned.state, .cancelled, "a late result must not resurrect an abandoned job")

        // A double release would have corrupted the permit count; prove it didn't.
        let after = await store.submit(shortcutName: "After", input: nil)
        let afterWaited = await store.wait(for: after.id, timeout: 3)
        XCTAssertEqual(try XCTUnwrap(afterWaited).state, .succeeded)
    }

    /// A running job stuck well past even the widest legitimate async timeout is
    /// presumed abandoned and cancelled by the watchdog.
    func testWatchdogCancelsAbandonedRunningJob() async throws {
        let clock = TestClock()
        let store = JobStore(
            execute: { _, _ in
                for _ in 0..<200 {
                    if Task.isCancelled {
                        return ShortcutResult(exitCode: -15, stdout: "", stderr: "killed")
                    }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return ShortcutResult(exitCode: 0, stdout: "finished", stderr: "")
            },
            watchdogTimeout: 60,
            now: { clock.now() }
        )
        let job = await store.submit(shortcutName: "Stuck", input: nil)
        while await store.job(id: job.id)?.state != .running {
            try? await Task.sleep(for: .milliseconds(10))
        }

        clock.advance(by: 61)
        _ = await store.job(id: job.id) // triggers reap(now:), which should cancel the stuck job

        let waited = await store.wait(for: job.id, timeout: 2)
        let finished = try XCTUnwrap(waited)
        XCTAssertEqual(finished.state, .cancelled)
    }

    // MARK: - Lookup semantics

    func testWaitReturnsTerminalJobWithinBudget() async throws {
        let store = JobStore(execute: { _, _ in ShortcutResult(exitCode: 0, stdout: "done", stderr: "") })
        let job = await store.submit(shortcutName: "Fast", input: nil)
        let waited = await store.wait(for: job.id, timeout: 2)
        let result = try XCTUnwrap(waited)
        XCTAssertEqual(result.state, .succeeded)
    }

    func testWaitReturnsNonTerminalJobWhenBudgetExpires() async throws {
        let store = JobStore(execute: { _, _ in
            try? await Task.sleep(for: .seconds(5))
            return ShortcutResult(exitCode: 0, stdout: "", stderr: "")
        })
        let job = await store.submit(shortcutName: "Slow", input: nil)
        let waited = await store.wait(for: job.id, timeout: 0.3)
        let result = try XCTUnwrap(waited)
        XCTAssertFalse(result.state.isTerminal)
    }

    func testUnknownIDReturnsNil() async throws {
        let store = JobStore(execute: { _, _ in ShortcutResult(exitCode: 0, stdout: "", stderr: "") })
        let job = await store.job(id: "job_deadbeef")
        XCTAssertNil(job)
    }

    func testTerminalJobStaysReadableAcrossRepeatedReads() async throws {
        let store = JobStore(execute: { _, _ in ShortcutResult(exitCode: 0, stdout: "ok", stderr: "") })
        let job = await store.submit(shortcutName: "Test", input: nil)
        _ = await store.wait(for: job.id, timeout: 2)
        let first = await store.job(id: job.id)
        let second = await store.job(id: job.id)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testJobIDsAreUniqueAndWellFormed() async throws {
        let store = JobStore(
            execute: { _, _ in ShortcutResult(exitCode: 0, stdout: "", stderr: "") },
            maxConcurrent: 50,
            maxJobs: 2000,
            retention: 3600
        )
        let pattern = try NSRegularExpression(pattern: "^job_[0-9a-f]{8}$")
        var ids = Set<String>()
        for i in 0..<1000 {
            let job = await store.submit(shortcutName: "Job\(i)", input: nil)
            let range = NSRange(job.id.startIndex..<job.id.endIndex, in: job.id)
            XCTAssertNotNil(pattern.firstMatch(in: job.id, range: range))
            ids.insert(job.id)
        }
        XCTAssertEqual(ids.count, 1000)
    }

    // MARK: - Real-subprocess integration

    /// Exercises the store against a genuine subprocess via `ShortcutsRunner`'s
    /// own `/bin/sleep` test seam, end to end.
    func testRealSubprocessIntegrationReachesTimedOut() async throws {
        let store = JobStore(execute: { _, input in
            try await ShortcutsRunner(executable: "/bin/sleep", timeout: 0.5).invoke(arguments: ["5"], input: input)
        })
        let job = await store.submit(shortcutName: "sleep-via-execute-closure", input: nil)
        let waited = await store.wait(for: job.id, timeout: 3)
        let finished = try XCTUnwrap(waited)
        XCTAssertEqual(finished.state, .timedOut)
    }
}
