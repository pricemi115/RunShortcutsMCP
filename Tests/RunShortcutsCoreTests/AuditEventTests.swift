// SPDX-License-Identifier: Apache-2.0
//
//  AuditEventTests.swift
//  RunShortcutsMCPTests
//
//  Pins the audit log's wire shape. The log is the only record of what the server
//  was asked to do, so its format is worth holding still: one JSON object per
//  line, key-sorted, carrying the fields an investigation needs — and never
//  carrying shortcut input, which can hold personal content.
//

import XCTest
@testable import RunShortcutsCore

final class AuditEventTests: XCTestCase {

    private let when = Date(timeIntervalSince1970: 1_756_000_000)

    func testRunEventCarriesTheGateDecision() throws {
        let line = AuditEvent.run(
            tool: "run_shortcut_async", shortcut: "TagNote", jobID: "job_1a2b3c4d",
            confirm: true, sideEffect: true, now: when
        ).logLine()

        XCTAssertTrue(line.hasSuffix("\n"), "each event must be exactly one log line")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
        for fragment in ["\"event\":\"run\"", "\"tool\":\"run_shortcut_async\"",
                         "\"shortcut\":\"TagNote\"", "\"job_id\":\"job_1a2b3c4d\"",
                         "\"confirm\":true", "\"side_effect\":true"] {
            XCTAssertTrue(line.contains(fragment), "missing \(fragment) in \(line)")
        }
    }

    /// The confirmation decision must be recoverable from the log — an unconfirmed
    /// run of a side-effecting shortcut is the thing an audit is looking for.
    func testRunEventDistinguishesUnconfirmedRuns() throws {
        let line = AuditEvent.run(
            tool: "run_shortcut", shortcut: "BatteryLevel", jobID: nil,
            confirm: false, sideEffect: false, now: when
        ).logLine()
        XCTAssertTrue(line.contains("\"confirm\":false"))
        XCTAssertTrue(line.contains("\"side_effect\":false"))
        XCTAssertFalse(line.contains("\"job_id\""), "a synchronous run has no job id")
    }

    func testRefusalsCarryAMachineReadableReason() throws {
        let notAllowed = AuditEvent.refused(tool: "run_shortcut", shortcut: "Sneaky", reason: "not_allowlisted", now: when).logLine()
        XCTAssertTrue(notAllowed.contains("\"event\":\"refused\""))
        XCTAssertTrue(notAllowed.contains("\"reason\":\"not_allowlisted\""))

        let needsConfirm = AuditEvent.refused(tool: "run_shortcut_async", shortcut: "SendMessage", reason: "needs_confirmation", now: when).logLine()
        XCTAssertTrue(needsConfirm.contains("\"reason\":\"needs_confirmation\""))
        XCTAssertTrue(needsConfirm.contains("\"shortcut\":\"SendMessage\""))
    }

    func testFailureEventRecordsTheUnderlyingReason() throws {
        let line = AuditEvent.failed(tool: "run_shortcut_async", shortcut: "Broken", jobID: "job_deadbeef", reason: "launch error", now: when).logLine()
        XCTAssertTrue(line.contains("\"event\":\"failed\""))
        XCTAssertTrue(line.contains("\"reason\":\"launch error\""))
    }

    /// Shortcut input can carry personal content and is deliberately never logged.
    func testInputIsNeverPresentInTheWireShape() throws {
        let line = AuditEvent.run(tool: "run_shortcut", shortcut: "TagNote", jobID: nil, confirm: true, sideEffect: true, now: when).logLine()
        XCTAssertFalse(line.contains("input"))
    }

    /// Keys are sorted so the log stays greppable and diffable across releases.
    func testKeysAreSorted() throws {
        let line = AuditEvent.run(tool: "t", shortcut: "s", jobID: "j", confirm: true, sideEffect: false, now: when).logLine()
        let confirmAt = try XCTUnwrap(line.range(of: "\"confirm\""))
        let eventAt = try XCTUnwrap(line.range(of: "\"event\""))
        let toolAt = try XCTUnwrap(line.range(of: "\"tool\""))
        XCTAssertTrue(confirmAt.lowerBound < eventAt.lowerBound)
        XCTAssertTrue(eventAt.lowerBound < toolAt.lowerBound)
    }
}
