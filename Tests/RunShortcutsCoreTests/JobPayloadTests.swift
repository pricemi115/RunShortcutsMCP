// SPDX-License-Identifier: Apache-2.0
//
//  JobPayloadTests.swift
//  RunShortcutsMCPTests
//
//  Pins the JSON wire shape of the background-job payloads: which fields
//  appear for which job state, and that output never leaks into the job
//  listing. Constructs `Job` values directly rather than running real jobs
//  through a `JobStore` — these tests are purely about serialization.
//

import XCTest
@testable import RunShortcutsCore

final class JobPayloadTests: XCTestCase {

    func testJobStatusOmitsResultFieldsWhileNonTerminal() throws {
        let job = Job(id: "job_aaaaaaaa", shortcutName: "Test", state: .running, submittedAt: Date(), submittedUptime: 100, startedUptime: 100)
        let json = JobStatus(job: job).jsonString()

        XCTAssertTrue(json.contains("\"elapsed_seconds\""))
        XCTAssertFalse(json.contains("\"stdout\""))
        XCTAssertFalse(json.contains("\"stderr\""))
        XCTAssertFalse(json.contains("\"exit_code\""))
        XCTAssertFalse(json.contains("\"duration_seconds\""))
    }

    func testJobStatusIncludesResultFieldsWhenTerminal() throws {
        var job = Job(id: "job_bbbbbbbb", shortcutName: "Test", state: .succeeded, submittedAt: Date(), submittedUptime: 100)
        job.startedUptime = 100
        job.finishedUptime = 142
        job.result = ShortcutResult(exitCode: 0, stdout: "hi", stderr: "", timedOut: false)

        let json = JobStatus(job: job).jsonString()

        XCTAssertTrue(json.contains("\"stdout\""))
        XCTAssertTrue(json.contains("\"stderr\""))
        XCTAssertTrue(json.contains("\"exit_code\""))
        XCTAssertFalse(json.contains("\"elapsed_seconds\""))
        // Derived from the monotonic readings (142 - 100), not from the Dates.
        XCTAssertTrue(json.contains("\"duration_seconds\" : 42"), json)
    }

    /// `elapsed_seconds` on a running job counts from its monotonic start, so a
    /// wall-clock change between submission and the poll cannot distort it.
    func testElapsedSecondsUsesMonotonicReadings() throws {
        let job = Job(
            id: "job_ffffffff", shortcutName: "Test", state: .running,
            submittedAt: Date(timeIntervalSince1970: 0), submittedUptime: 100, startedUptime: 110
        )
        let json = JobStatus(job: job, uptime: 135).jsonString()
        XCTAssertTrue(json.contains("\"elapsed_seconds\" : 25"), json)
    }

    /// A cancelled job omits `exit_code`/`timed_out` (a signal-derived exit
    /// status isn't meaningful) but keeps any output actually captured before
    /// the kill, plus a `message` explaining the state.
    func testJobStatusForCancelledJobOmitsExitCodeButKeepsPartialOutput() throws {
        var job = Job(id: "job_cccccccc", shortcutName: "Test", state: .cancelled, submittedAt: Date(), submittedUptime: 100)
        job.startedUptime = 100
        job.finishedUptime = 142
        job.result = ShortcutResult(exitCode: -15, stdout: "partial", stderr: "", timedOut: false)

        let json = JobStatus(job: job).jsonString()

        XCTAssertFalse(json.contains("\"exit_code\""))
        XCTAssertFalse(json.contains("\"timed_out\""))
        XCTAssertTrue(json.contains("\"stdout\""))
        XCTAssertTrue(json.contains("partial"))
        XCTAssertTrue(json.contains("\"message\""))
    }

    func testJobSubmissionKeySet() throws {
        let job = Job(id: "job_dddddddd", shortcutName: "Test", state: .queued, submittedAt: Date(), submittedUptime: 100)
        let json = JobSubmission(job: job).jsonString()
        for key in ["job_id", "shortcut", "state", "submitted_at"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing key \(key)")
        }
    }

    func testJobListingNeverContainsOutput() throws {
        var job = Job(id: "job_eeeeeeee", shortcutName: "Test", state: .succeeded, submittedAt: Date(), submittedUptime: 100)
        job.finishedUptime = 142
        job.result = ShortcutResult(exitCode: 0, stdout: "should not appear", stderr: "nor this", timedOut: false)

        let json = jobListingJSONString([job])

        XCTAssertFalse(json.contains("should not appear"))
        XCTAssertFalse(json.contains("nor this"))
        XCTAssertFalse(json.contains("\"stdout\""))
        XCTAssertFalse(json.contains("\"stderr\""))
        XCTAssertTrue(json.contains("job_eeeeeeee"))
    }

    func testRunOutputIncludesTimedOut() throws {
        let result = ShortcutResult(exitCode: 0, stdout: "hi", stderr: "", timedOut: false)
        let json = RunOutput(result).jsonString()
        for key in ["exit_code", "stdout", "stderr", "timed_out"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing key \(key)")
        }
    }
}
