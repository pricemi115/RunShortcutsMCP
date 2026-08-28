// SPDX-License-Identifier: Apache-2.0
//
//  AuditEvent.swift
//  RunShortcutsMCP
//
//  One security-relevant thing the server did, rendered as a single line of JSON
//  for the server log. Records what ran, what was refused, and why — the trail
//  needed to reconstruct a session after the fact.
//
//  Refusals are logged as deliberately as successes: a burst of `not_allowlisted`
//  is a caller probing for shortcut names it was never given, and a
//  `needs_confirmation` immediately followed by a confirmed run of the same
//  shortcut is the signature of a confirmation gate being self-answered rather
//  than escalated to the user. Neither is visible if only successes are recorded.
//
//  Shortcut *input* is never logged — it can carry personal content, and the
//  value of the trail is in what was invoked, not what was passed.
//

import Foundation

/// A single security-relevant event, serialized as one line of JSON.
public struct AuditEvent: Codable, Sendable, Equatable {
    /// (`String`) ISO 8601 timestamp of the event.
    public let ts: String
    /// (`String`) What happened: `run`, `refused`, or `failed`.
    public let event: String
    /// (`String`) The MCP tool involved.
    public let tool: String
    /// (`String?`) The shortcut named by the caller, when one was named.
    public let shortcut: String?
    /// (`String?`) The job id, for background runs.
    public let job_id: String?
    /// (`Bool?`) Whether the caller asserted `confirm=true`.
    public let confirm: Bool?
    /// (`Bool?`) Whether the allowlist entry is flagged `side_effect`.
    public let side_effect: Bool?
    /// (`String?`) Why a request was refused or a run failed.
    public let reason: String?

    /// Creates an event. Prefer the factory methods below.
    /// - Parameters:
    ///   - ts: (`String`) ISO 8601 timestamp.
    ///   - event: (`String`) Event kind.
    ///   - tool: (`String`) The MCP tool involved.
    ///   - shortcut: (`String?`) Shortcut name, if any.
    ///   - job_id: (`String?`) Job id, if any.
    ///   - confirm: (`Bool?`) Caller's `confirm` assertion, if relevant.
    ///   - side_effect: (`Bool?`) The entry's `side_effect` flag, if known.
    ///   - reason: (`String?`) Refusal/failure reason, if any.
    public init(
        ts: String, event: String, tool: String,
        shortcut: String? = nil, job_id: String? = nil,
        confirm: Bool? = nil, side_effect: Bool? = nil, reason: String? = nil
    ) {
        self.ts = ts
        self.event = event
        self.tool = tool
        self.shortcut = shortcut
        self.job_id = job_id
        self.confirm = confirm
        self.side_effect = side_effect
        self.reason = reason
    }

    /// A shortcut that passed the allowlist and confirmation gates and was started.
    /// - Parameters:
    ///   - tool: (`String`) The tool that started it.
    ///   - shortcut: (`String`) The shortcut name.
    ///   - jobID: (`String?`) The background job id, or `nil` for a synchronous run.
    ///   - confirm: (`Bool`) Whether the caller asserted approval.
    ///   - sideEffect: (`Bool`) Whether the entry is flagged `side_effect`.
    ///   - now: (`Date`) Event time.
    /// - Returns: (`AuditEvent`) The event.
    public static func run(tool: String, shortcut: String, jobID: String?, confirm: Bool, sideEffect: Bool, now: Date = Date()) -> AuditEvent {
        AuditEvent(ts: iso8601(now), event: "run", tool: tool, shortcut: shortcut,
                   job_id: jobID, confirm: confirm, side_effect: sideEffect)
    }

    /// A request the server declined to act on.
    /// - Parameters:
    ///   - tool: (`String`) The tool called.
    ///   - shortcut: (`String?`) The shortcut named, if any.
    ///   - reason: (`String`) Machine-readable refusal reason.
    ///   - now: (`Date`) Event time.
    /// - Returns: (`AuditEvent`) The event.
    public static func refused(tool: String, shortcut: String?, reason: String, now: Date = Date()) -> AuditEvent {
        AuditEvent(ts: iso8601(now), event: "refused", tool: tool, shortcut: shortcut, reason: reason)
    }

    /// A run that was permitted but could not be launched.
    /// - Parameters:
    ///   - tool: (`String`) The tool that attempted it.
    ///   - shortcut: (`String`) The shortcut name.
    ///   - jobID: (`String?`) The background job id, if any.
    ///   - reason: (`String`) The underlying failure, for the local log only.
    ///   - now: (`Date`) Event time.
    /// - Returns: (`AuditEvent`) The event.
    public static func failed(tool: String, shortcut: String, jobID: String?, reason: String, now: Date = Date()) -> AuditEvent {
        AuditEvent(ts: iso8601(now), event: "failed", tool: tool, shortcut: shortcut,
                   job_id: jobID, reason: reason)
    }

    /// Serializes to a single line of JSON, newline-terminated, ready for the log.
    /// Compact and key-sorted so the log stays greppable and diffable.
    /// - Returns: (`String`) One JSON object followed by a newline.
    public func logLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"event\":\"\(event)\",\"tool\":\"\(tool)\"}\n"
        }
        return json + "\n"
    }
}

/// Renders a date as an ISO 8601 string.
/// - Parameter date: (`Date`) The date.
/// - Returns: (`String`) ISO 8601 representation.
private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
