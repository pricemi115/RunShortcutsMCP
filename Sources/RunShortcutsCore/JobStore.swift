// SPDX-License-Identifier: Apache-2.0
//
//  JobStore.swift
//  RunShortcutsMCP
//
//  In-memory registry of background shortcut jobs, backing `run_shortcut_async`,
//  `get_shortcut_result`, `cancel_shortcut_job`, and `list_shortcut_jobs`. Runs
//  jobs up to a concurrency cap, retires finished jobs on a bounded schedule
//  (TTL, byte budget, count cap), and never constructs a `ShortcutsRunner`
//  itself — execution is injected so the store is testable without a real
//  `shortcuts` binary.
//

import Foundation

/// A job's position in its lifecycle. `queued` and `running` are in-flight; the
/// remaining four are terminal — no further transitions occur once reached.
public enum JobState: String, Codable, Sendable, Equatable {
    /// Submitted, waiting for a concurrency slot.
    case queued
    /// Holding a concurrency slot; the shortcut is actually running.
    case running
    /// Finished with exit code `0`.
    case succeeded
    /// Finished with a non-zero exit code, or could not be launched.
    case failed
    /// Force-terminated for exceeding its configured timeout.
    case timedOut = "timed_out"
    /// Stopped via `cancel_shortcut_job`, or while queued/running at shutdown.
    case cancelled

    /// (`Bool`) Whether this is a final state — `true` for the four terminal cases.
    var isTerminal: Bool {
        switch self {
        case .queued, .running: return false
        case .succeeded, .failed, .timedOut, .cancelled: return true
        }
    }
}

/// A snapshot of one background shortcut job. Returned by every `JobStore`
/// query as an independent value — mutating a returned `Job` never affects the
/// store's own record.
///
/// Two clocks are deliberately tracked, and they are not interchangeable:
/// `submittedAt` is a wall-clock `Date` used only to *report* when the job was
/// submitted, while the `…Uptime` values are monotonic readings used for every
/// elapsed-time decision. Wall-clock time can jump — a manual clock change or a
/// large NTP correction moves `Date()` — which would otherwise let a healthy job
/// be declared abandoned, expire a fresh result, or stretch a bounded wait past
/// the MCP client's request ceiling. Nothing that measures a *duration* may read
/// `submittedAt`.
public struct Job: Sendable, Equatable {
    /// (`String`) Opaque job identifier (`job_` + 8 lowercase hex characters), unique for the store's lifetime.
    public let id: String
    /// (`String`) The allowlisted shortcut name this job runs.
    public let shortcutName: String
    /// (`JobState`) The job's current lifecycle state.
    public var state: JobState
    /// (`Date`) Wall-clock submission time, reported to the client as `submitted_at`. Never used to measure elapsed time.
    public let submittedAt: Date
    /// (`TimeInterval`) Monotonic reading taken when the job was submitted.
    public let submittedUptime: TimeInterval
    /// (`TimeInterval?`) Monotonic reading taken when the job left `queued` and began running; `nil` until then.
    public var startedUptime: TimeInterval?
    /// (`TimeInterval?`) Monotonic reading taken when the job reached a terminal state; `nil` until then.
    public var finishedUptime: TimeInterval?
    /// (`ShortcutResult?`) The captured invocation result; `nil` until terminal, and always `nil` for `.cancelled`.
    public var result: ShortcutResult?
    /// (`String?`) A client-safe failure description, set only when the shortcut could not be launched at all. Detailed errors are logged by the caller, not stored here (mirrors the existing `run_shortcut` CWE-209 discipline).
    public var failureMessage: String?
}

/// In-memory registry and scheduler for background shortcut jobs. An `actor`
/// rather than a lock-guarded class: every caller is already `async`, so an
/// actor gives Swift-6-checked isolation with no `@unchecked` escape hatch.
public actor JobStore {
    /// Executes one shortcut invocation. Injected so the store never constructs
    /// a `ShortcutsRunner` itself, keeping it testable with a canned closure or a
    /// real subprocess via the same `/bin/sleep`-style seam `ShortcutsRunner`'s
    /// own tests use.
    private let execute: @Sendable (_ name: String, _ input: String?) async throws -> ShortcutResult

    /// (`Int`) Maximum jobs allowed to be `.running` at once; further submissions queue.
    private let maxConcurrent: Int

    /// (`Int`) Maximum terminal jobs retained at once (oldest evicted first past this).
    private let maxJobs: Int

    /// (`Int`) Maximum combined stdout+stderr bytes retained across all terminal jobs.
    private let maxRetainedBytes: Int

    /// (`TimeInterval`) How long a terminal job's result stays readable after it finishes.
    private let retention: TimeInterval

    /// (`TimeInterval`) A `.running` job older than this (measured monotonically from
    /// when it started) is presumed abandoned — e.g. a child in an uninterruptible sleep
    /// that never closes its pipes — and is cancelled. Deliberately a single conservative
    /// constant rather than each job's own configured timeout: `ShortcutsRunner.invoke`
    /// already enforces that timeout itself, so this only ever fires for a job that has
    /// outlived even the widest possible legitimate async timeout, which means it is
    /// definitely stuck.
    private let watchdogTimeout: TimeInterval

    /// (`() -> Date`) Wall-clock source, used only for the `submitted_at` timestamp
    /// reported to clients. Injected for testability.
    private let now: @Sendable () -> Date

    /// (`() -> TimeInterval`) Monotonic source backing every elapsed-time decision:
    /// the watchdog, result retention, and `wait(for:timeout:)`. Defaults to
    /// `ProcessInfo.systemUptime`, which cannot be moved by a clock change and — like
    /// the `DispatchTime` deadline `ShortcutsRunner` enforces its own timeout with —
    /// does not advance while the system is asleep, so the two layers agree on how
    /// long a job has actually been running. Injected so retention and the watchdog
    /// are testable without waiting out real minutes.
    private let uptime: @Sendable () -> TimeInterval

    /// (`[String: Job]`) All tracked jobs, keyed by id.
    private var jobs: [String: Job] = [:]

    /// (`[String: Task<Void, Never>]`) The running body for each in-flight job, so
    /// `cancel(id:)` can signal it regardless of whether it's queued or running.
    private var runningTasks: [String: Task<Void, Never>] = [:]

    /// (`Int`) Concurrency slots currently held by `.running` jobs.
    private var runningCount = 0

    /// (`[(id: String, continuation: CheckedContinuation<Bool, Never>)]`) Jobs waiting
    /// for a concurrency slot, oldest first. An array (not a dictionary) so slots are
    /// handed out in submission order.
    private var waiters: [(id: String, continuation: CheckedContinuation<Bool, Never>)] = []

    /// (`Set<String>`) Jobs currently holding one of the `maxConcurrent` slots.
    /// Tracked by id so a slot is released exactly once, which is what makes the
    /// watchdog's forced reclamation safe.
    private var slotHolders: Set<String> = []

    /// Creates a job store.
    /// - Parameters:
    ///   - execute: (`@Sendable (String, String?) async throws -> ShortcutResult`) Runs one shortcut invocation; the caller is responsible for any allowlist lookup and timeout/output-cap clamping before constructing this closure.
    ///   - maxConcurrent: (`Int`) Maximum simultaneously `.running` jobs; defaults to `4`.
    ///   - maxJobs: (`Int`) Maximum retained terminal jobs; defaults to `32`.
    ///   - maxRetainedBytes: (`Int`) Maximum combined stdout+stderr bytes retained across terminal jobs; defaults to `64_000_000`.
    ///   - retention: (`TimeInterval`) Seconds a terminal job's result stays readable after finishing; defaults to `600`.
    ///   - watchdogTimeout: (`TimeInterval`) Seconds after which a still-`.running` job is presumed abandoned and cancelled; defaults to the widest async timeout plus a 30s grace.
    ///   - now: (`@Sendable () -> Date`) Wall-clock source for the reported `submitted_at` timestamp; defaults to the real time.
    ///   - uptime: (`@Sendable () -> TimeInterval`) Monotonic source for every elapsed-time decision; defaults to `ProcessInfo.systemUptime`.
    public init(
        execute: @escaping @Sendable (_ name: String, _ input: String?) async throws -> ShortcutResult,
        maxConcurrent: Int = 4,
        maxJobs: Int = 32,
        maxRetainedBytes: Int = 64_000_000,
        retention: TimeInterval = 600,
        watchdogTimeout: TimeInterval = ShortcutsRunner.asyncTimeoutRange.upperBound + 30,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.execute = execute
        self.maxConcurrent = maxConcurrent
        self.maxJobs = maxJobs
        self.maxRetainedBytes = maxRetainedBytes
        self.retention = retention
        self.watchdogTimeout = watchdogTimeout
        self.now = now
        self.uptime = uptime
    }

    // MARK: - Public surface

    /// Submits a new job and returns immediately with it in `.queued` state; the
    /// shortcut runs in the background once a concurrency slot is available.
    /// - Parameters:
    ///   - shortcutName: (`String`) The allowlisted shortcut name to run.
    ///   - input: (`String?`) Text/JSON passed to the shortcut's stdin; `nil` for none.
    /// - Returns: (`Job`) The newly created job, in `.queued` state.
    public func submit(shortcutName: String, input: String?) -> Job {
        reap()
        let id = generateID()
        let job = Job(id: id, shortcutName: shortcutName, state: .queued, submittedAt: now(), submittedUptime: uptime())
        jobs[id] = job
        runningTasks[id] = Task { [self] in
            await runJob(id: id, shortcutName: shortcutName, input: input)
        }
        return job
    }

    /// Looks up a job by id.
    /// - Parameter id: (`String`) The job id.
    /// - Returns: (`Job?`) The job, or `nil` if it never existed or its result has expired.
    public func job(id: String) -> Job? {
        reap()
        return jobs[id]
    }

    /// Lists every currently tracked job (queued, running, and not-yet-expired terminal), oldest first.
    /// - Returns: (`[Job]`) Jobs sorted by submission time.
    public func allJobs() -> [Job] {
        reap()
        return jobs.values.sorted { $0.submittedUptime < $1.submittedUptime }
    }

    /// Waits for a job to reach a terminal state, up to `timeout` seconds, then
    /// returns its current snapshot regardless of whether it finished. Implemented
    /// as a bounded poll (not a continuation the caller could stack indefinitely),
    /// so a duplicate or concurrent `wait` for the same id is always safe.
    ///
    /// Returns early if the calling task is cancelled. That check is load-bearing,
    /// not defensive: a cancelled `Task.sleep` throws instead of suspending, so
    /// without it the loop would spin without ever yielding — and because this
    /// method is actor-isolated, that spin would hold the actor and starve every
    /// other job operation until the deadline.
    /// - Parameters:
    ///   - id: (`String`) The job id to wait for.
    ///   - timeout: (`TimeInterval`) Maximum seconds to wait.
    /// - Returns: (`Job?`) The job's snapshot at completion, timeout, or caller cancellation; `nil` if the id is unknown.
    public func wait(for id: String, timeout: TimeInterval) async -> Job? {
        let deadline = uptime() + timeout
        while true {
            reap()
            guard let current = jobs[id] else { return nil }
            if current.state.isTerminal || uptime() >= deadline || Task.isCancelled { return current }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Stops a job that is still `.queued` or `.running`. A no-op on an unknown or
    /// already-terminal job.
    ///
    /// A queued job is finalized to `.cancelled` immediately, since it never
    /// started running anything. A running job is only signaled here — the actual
    /// `.cancelled` transition happens once its underlying `ShortcutsRunner.invoke`
    /// call observes the cancellation, terminates the child, and returns, so the
    /// state reflects the process's real exit rather than a projection of intent.
    /// - Parameter id: (`String`) The job id to cancel.
    /// - Returns: (`Job?`) The job's current snapshot after the request; `nil` if the id is unknown.
    @discardableResult
    public func cancel(id: String) -> Job? {
        reap()
        guard var current = jobs[id] else { return nil }
        switch current.state {
        case .queued:
            if let index = waiters.firstIndex(where: { $0.id == id }) {
                waiters.remove(at: index).continuation.resume(returning: false)
            }
            runningTasks[id]?.cancel()
            current.state = .cancelled
            current.finishedUptime = uptime()
            jobs[id] = current
        case .running:
            runningTasks[id]?.cancel()
        case .succeeded, .failed, .timedOut, .cancelled:
            break
        }
        return jobs[id]
    }

    /// Cancels every job that is not yet in a terminal state. Used at shutdown so
    /// a disconnecting client doesn't leave a side-effecting shortcut running
    /// unattended.
    public func cancelAll() {
        for (id, job) in jobs where !job.state.isTerminal {
            cancel(id: id)
        }
    }

    /// Removes a job's record outright, regardless of state or retention policy.
    /// - Parameter id: (`String`) The job id to remove.
    private func remove(id: String) {
        jobs.removeValue(forKey: id)
        runningTasks.removeValue(forKey: id)
    }

    // MARK: - Job execution

    /// The body of one job's background `Task`: waits for a concurrency slot, runs
    /// the shortcut via the injected `execute` closure, and finalizes the job's
    /// terminal state from the result.
    /// - Parameters:
    ///   - id: (`String`) The job id.
    ///   - shortcutName: (`String`) The shortcut name to run.
    ///   - input: (`String?`) Text/JSON to pass on stdin.
    private func runJob(id: String, shortcutName: String, input: String?) async {
        let granted = await acquireSlot(id: id)
        guard granted else {
            // cancel(id:) already finalized this job while it was queued.
            return
        }
        guard var current = jobs[id], current.state == .queued else {
            // The job was cancelled/reaped between being granted a slot and now;
            // give the slot back rather than run anything.
            releaseSlot(id: id)
            return
        }
        if Task.isCancelled {
            current.state = .cancelled
            current.finishedUptime = uptime()
            jobs[id] = current
            releaseSlot(id: id)
            return
        }

        current.state = .running
        current.startedUptime = uptime()
        jobs[id] = current

        do {
            let result = try await execute(shortcutName, input)
            finalize(id: id, result: result)
        } catch {
            finalizeFailure(id: id, message: "Failed to run '\(shortcutName)'.")
        }
        releaseSlot(id: id)
    }

    /// Records a job's successful invocation result and derives its terminal
    /// state — preferring `.cancelled` when the job's task was cancelled, even
    /// though `execute` still returned a (killed-process) result rather than throwing.
    /// - Parameters:
    ///   - id: (`String`) The job id.
    ///   - result: (`ShortcutResult`) The captured invocation result.
    private func finalize(id: String, result: ShortcutResult) {
        // An already-terminal job was finalized by the watchdog after being
        // abandoned; a late result from its task must not resurrect or rewrite it.
        guard var current = jobs[id], !current.state.isTerminal else { return }
        current.finishedUptime = uptime()
        current.result = result
        if Task.isCancelled {
            current.state = .cancelled
        } else if result.timedOut {
            current.state = .timedOut
        } else if result.exitCode == 0 {
            current.state = .succeeded
        } else {
            current.state = .failed
        }
        jobs[id] = current
    }

    /// Records that a job's shortcut could not be launched at all.
    /// - Parameters:
    ///   - id: (`String`) The job id.
    ///   - message: (`String`) A client-safe description of the failure.
    private func finalizeFailure(id: String, message: String) {
        guard var current = jobs[id], !current.state.isTerminal else { return }
        current.finishedUptime = uptime()
        current.state = Task.isCancelled ? .cancelled : .failed
        current.failureMessage = message
        jobs[id] = current
    }

    // MARK: - Concurrency permits

    /// Suspends until a concurrency slot is available for `id`, or returns
    /// immediately if one already is.
    /// - Parameter id: (`String`) The job id acquiring a slot, recorded in `slotHolders` so the slot can be released exactly once, and used to locate this waiter if it must later be cancelled.
    /// - Returns: (`Bool`) `true` if a slot was granted; `false` if `cancel(id:)` resumed this wait before a slot was ever granted, in which case no slot is held.
    private func acquireSlot(id: String) async -> Bool {
        if runningCount < maxConcurrent {
            runningCount += 1
            slotHolders.insert(id)
            return true
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters.append((id: id, continuation: continuation))
        }
    }

    /// Releases the concurrency slot held by `id`, handing it directly to the
    /// oldest waiter if any rather than freeing and re-granting it, so
    /// `runningCount` never exceeds `maxConcurrent`.
    ///
    /// Idempotent by design: a job not currently in `slotHolders` releases
    /// nothing. That is what lets the watchdog reclaim an abandoned job's slot
    /// without risking a double release should that job's own task return later.
    /// - Parameter id: (`String`) The job whose slot to release.
    private func releaseSlot(id: String) {
        guard slotHolders.remove(id) != nil else { return }
        if waiters.isEmpty {
            runningCount -= 1
        } else {
            let next = waiters.removeFirst()
            slotHolders.insert(next.id)
            next.continuation.resume(returning: true)
        }
    }

    // MARK: - Housekeeping

    /// Generates a job id not currently in use: `job_` followed by 8 lowercase hex
    /// characters. Short enough to reliably transcribe into a follow-up tool call,
    /// unlike a full UUID; re-rolls on the (near-impossible) chance of a collision.
    /// - Returns: (`String`) A fresh, unused job id.
    private func generateID() -> String {
        while true {
            let candidate = "job_" + String(format: "%08x", UInt32.random(in: .min ... .max))
            if jobs[candidate] == nil { return candidate }
        }
    }

    /// Applies retention policy. Called at the top of every public accessor so
    /// reaping is driven entirely by client activity rather than a background
    /// timer, and is fully deterministic under the injected clocks. Never evicts a
    /// `.queued` or `.running` job outright — the watchdog transitions a stuck
    /// running job to `.cancelled` instead of deleting its record, and the
    /// eviction rules below only ever consider jobs already in a terminal state.
    ///
    /// Every age comparison here reads the monotonic clock, never `Date`. A
    /// wall-clock jump forward would otherwise declare healthy running jobs
    /// abandoned and expire every retained result at once.
    private func reap() {
        let currentUptime = uptime()

        for (id, job) in jobs where job.state == .running {
            guard let startedUptime = job.startedUptime,
                  currentUptime - startedUptime > watchdogTimeout else { continue }

            // Signal first, so a job that is merely slow unwinds cooperatively
            // and terminates its own child.
            runningTasks[id]?.cancel()

            // Then force it terminal and reclaim its slot without waiting to see
            // whether that signal took. A job whose child ignores termination —
            // one stuck in uninterruptible sleep that never closes its pipes —
            // never returns from `execute`, so `runJob` would never release the
            // slot, and enough of those would permanently exhaust `maxConcurrent`
            // and stall every future job. `releaseSlot(id:)` is idempotent and
            // both finalizers ignore already-terminal jobs, so this stays correct
            // even when the task does eventually return.
            var abandoned = job
            abandoned.state = .cancelled
            abandoned.finishedUptime = currentUptime
            abandoned.failureMessage = "Job exceeded the \(Int(watchdogTimeout))s watchdog limit and was abandoned; its slot has been reclaimed."
            jobs[id] = abandoned
            releaseSlot(id: id)
        }

        // Rule 1: TTL — evict a terminal job `retention` seconds after it finished.
        for (id, job) in jobs where job.state.isTerminal {
            if let finishedUptime = job.finishedUptime, currentUptime - finishedUptime > retention {
                remove(id: id)
            }
        }

        // Rule 2: retained-bytes budget — evict oldest-finished-first until under budget.
        var terminal = jobs.values
            .filter { $0.state.isTerminal }
            .sorted { ($0.finishedUptime ?? 0) < ($1.finishedUptime ?? 0) }
        var totalBytes = terminal.reduce(0) { $0 + retainedBytes(of: $1) }
        while totalBytes > maxRetainedBytes, let oldest = terminal.first {
            totalBytes -= retainedBytes(of: oldest)
            remove(id: oldest.id)
            terminal.removeFirst()
        }

        // Rule 3: count cap — evict oldest-finished-first past `maxJobs`.
        if terminal.count > maxJobs {
            for victim in terminal.prefix(terminal.count - maxJobs) {
                remove(id: victim.id)
            }
        }
    }

    /// The combined stdout+stderr byte size a terminal job is retaining.
    /// - Parameter job: (`Job`) The job to measure.
    /// - Returns: (`Int`) Combined UTF-8 byte count of `stdout` and `stderr`; `0` if there is no result.
    private func retainedBytes(of job: Job) -> Int {
        (job.result?.stdout.utf8.count ?? 0) + (job.result?.stderr.utf8.count ?? 0)
    }
}
