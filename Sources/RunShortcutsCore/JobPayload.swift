// SPDX-License-Identifier: Apache-2.0
//
//  JobPayload.swift
//  RunShortcutsMCP
//
//  JSON-encodable wire payloads for the background-job tools (`run_shortcut_async`,
//  `get_shortcut_result`, `list_shortcut_jobs`), built from `Job` snapshots. Mirrors
//  `RunOutput`'s conventions: snake_case keys, pretty-printed/sorted JSON, and a
//  graceful fallback string if encoding ever fails.
//

import Foundation

/// Renders a date as an ISO 8601 string. A fresh formatter per call, since
/// `ISO8601DateFormatter` is a mutable class and these payload types may be
/// constructed concurrently across MCP requests.
/// - Parameter date: (`Date`) The date to render.
/// - Returns: (`String`) The ISO 8601 representation.
private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// The JSON payload returned immediately by `run_shortcut_async`: acknowledges
/// submission without waiting for the job to run.
public struct JobSubmission: Codable, Sendable {
    /// (`String`) The job id to poll with `get_shortcut_result`.
    public let job_id: String
    /// (`String`) The shortcut name this job runs.
    public let shortcut: String
    /// (`String`) The job's state at submission time — always `"queued"`.
    public let state: String
    /// (`String`) ISO 8601 submission timestamp.
    public let submitted_at: String

    /// Builds a submission payload from a freshly created job.
    /// - Parameter job: (`Job`) The job returned by `JobStore.submit(shortcutName:input:)`.
    public init(job: Job) {
        job_id = job.id
        shortcut = job.shortcutName
        state = job.state.rawValue
        submitted_at = iso8601(job.submittedAt)
    }

    /// Serializes this payload to a pretty-printed JSON string.
    /// - Returns: (`String`) Pretty-printed JSON; falls back to `{"job_id":"<id>"}` if encoding fails.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"job_id\":\"\(job_id)\"}"
        }
        return json
    }
}

/// The JSON payload returned by `get_shortcut_result`: a job's current status,
/// with fields present only where they're meaningful for that state —
/// `elapsed_seconds` while non-terminal, `stdout`/`stderr`/`exit_code`/`timed_out`
/// only when a result was captured, `duration_seconds` only once terminal, and
/// `message` only for a cancelled or launch-failed job (neither of which carries
/// a normal exit code). Optional properties are omitted from the JSON entirely
/// when `nil` (Swift's synthesized `Encodable` conformance uses `encodeIfPresent`
/// for `Optional` properties), so absence can never be mistaken for emptiness.
public struct JobStatus: Codable, Sendable {
    /// (`String`) The job id.
    public let job_id: String
    /// (`String`) The shortcut name this job runs.
    public let shortcut: String
    /// (`String`) The job's current state.
    public let state: String
    /// (`Int?`) Seconds since the job started (or was submitted, if still queued); present only while non-terminal.
    public let elapsed_seconds: Int?
    /// (`Int?`) Seconds the job took from start to finish; present only once terminal.
    public let duration_seconds: Int?
    /// (`Int32?`) Process exit status; present only when a normal (non-cancelled) result was captured.
    public let exit_code: Int32?
    /// (`String?`) Captured standard output; present only when a normal (non-cancelled) result was captured.
    public let stdout: String?
    /// (`String?`) Captured standard error; present only when a normal (non-cancelled) result was captured.
    public let stderr: String?
    /// (`Bool?`) Whether the invocation was force-terminated for exceeding its timeout; present only alongside `exit_code`.
    public let timed_out: Bool?
    /// (`String?`) A client-safe description, present only for `cancelled` or a launch failure.
    public let message: String?

    /// Builds a status payload from a job snapshot.
    /// - Parameters:
    ///   - job: (`Job`) The job snapshot to render.
    ///   - now: (`Date`) The current time, used to compute `elapsed_seconds` for a non-terminal job.
    public init(job: Job, now: Date = Date()) {
        job_id = job.id
        shortcut = job.shortcutName
        state = job.state.rawValue

        if job.state.isTerminal {
            elapsed_seconds = nil
            if let finishedAt = job.finishedAt {
                duration_seconds = Int(finishedAt.timeIntervalSince(job.startedAt ?? job.submittedAt))
            } else {
                duration_seconds = nil
            }
        } else {
            duration_seconds = nil
            elapsed_seconds = Int(now.timeIntervalSince(job.startedAt ?? job.submittedAt))
        }

        if job.state == .cancelled {
            // Cancellation can race a real result back from a killed process (see
            // ShortcutsRunner); a signal-derived exit code isn't meaningful to a
            // client, so it's omitted, but any output actually captured before
            // the kill is still useful and is kept.
            exit_code = nil
            timed_out = nil
            stdout = job.result?.stdout
            stderr = job.result?.stderr
            message = "Job was cancelled before it finished."
        } else if let result = job.result {
            exit_code = result.exitCode
            stdout = result.stdout
            stderr = result.stderr
            timed_out = result.timedOut
            message = nil
        } else {
            exit_code = nil
            stdout = nil
            stderr = nil
            timed_out = nil
            message = job.failureMessage
        }
    }

    /// Serializes this payload to a pretty-printed JSON string.
    /// - Returns: (`String`) Pretty-printed JSON; falls back to `{"job_id":"<id>","state":"<state>"}` if encoding fails.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"job_id\":\"\(job_id)\",\"state\":\"\(state)\"}"
        }
        return json
    }
}

/// One row of the JSON array returned by `list_shortcut_jobs`. Deliberately never
/// carries `stdout`/`stderr` — each stream can be up to the configured output cap
/// (megabytes), and this tool exists purely so a lost `job_id` is recoverable, not
/// to re-deliver output; use `get_shortcut_result` for that.
public struct JobListing: Codable, Sendable {
    /// (`String`) The job id.
    public let job_id: String
    /// (`String`) The shortcut name this job runs.
    public let shortcut: String
    /// (`String`) The job's current state.
    public let state: String
    /// (`String`) ISO 8601 submission timestamp.
    public let submitted_at: String
    /// (`Int?`) Seconds the job took from start to finish; present only once terminal.
    public let duration_seconds: Int?

    /// Builds a listing row from a job snapshot.
    /// - Parameter job: (`Job`) The job snapshot to render.
    public init(job: Job) {
        job_id = job.id
        shortcut = job.shortcutName
        state = job.state.rawValue
        submitted_at = iso8601(job.submittedAt)
        if job.state.isTerminal, let finishedAt = job.finishedAt {
            duration_seconds = Int(finishedAt.timeIntervalSince(job.startedAt ?? job.submittedAt))
        } else {
            duration_seconds = nil
        }
    }
}

/// Renders every tracked job as the JSON array payload for `list_shortcut_jobs`,
/// sorted by submission time (oldest first).
/// - Parameter jobs: (`[Job]`) The jobs to render, e.g. from `JobStore.allJobs()`.
/// - Returns: (`String`) Pretty-printed JSON array; `"[]"` if encoding fails.
public func jobListingJSONString(_ jobs: [Job]) -> String {
    let listings = jobs.map(JobListing.init)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(listings),
          let json = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return json
}
