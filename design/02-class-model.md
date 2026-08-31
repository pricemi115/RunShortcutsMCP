<!-- SPDX-License-Identifier: Apache-2.0 -->
# 2. Class Model

Every type in the system, what it owns, and how the types relate. Diagrams are
split by concern; §2.6 shows the whole graph at once.

## 2.1 Type inventory

| Type | Kind | Module | File | Responsibility |
|------|------|--------|------|----------------|
| `AllowlistEntry` | struct | Core | `Allowlist.swift` | One permitted shortcut and its metadata. |
| `Allowlist` | struct | Core | `Allowlist.swift` | The full permitted set; the authority every run consults. |
| `AllowlistError` | enum | Core | `Allowlist.swift` | Load-time validation failures. |
| `ShortcutDescription` | struct | Core | `Allowlist.swift` | Flattened, agent-facing view of an entry, plus live install status. |
| `AllowlistLocator` | enum (namespace) | Core | `AllowlistLocator.swift` | Decides *which file* the allowlist comes from. |
| `ConfigProvisioner` | enum (namespace) | Core | `ConfigProvisioner.swift` | First-run creation of the per-user config folder. |
| `ConfigProvisionerError` | enum | Core | `ConfigProvisioner.swift` | Provisioning write failures (carries `errno`). |
| `ShortcutsRunner` | struct | Core | `ShortcutsRunner.swift` | Injection-safe wrapper around `/usr/bin/shortcuts`. |
| `ShortcutResult` | struct | Core | `ShortcutsRunner.swift` | Captured exit code, stdout, stderr, timed-out flag. |
| `RunOutput` | struct | Core | `ShortcutsRunner.swift` | `ShortcutResult` in wire form (snake_case JSON). |
| `OutputCollector` | final class | Core | `ShortcutsRunner.swift` | Thread-safe, size-capped byte accumulator. `private`. |
| `ProcessBox` | final class | Core | `ShortcutsRunner.swift` | Thread-safe custody of one `Process`; the only place it is signalled. `private`. |
| `JobStore` | **actor** | Core | `JobStore.swift` | Registry + scheduler for background jobs. |
| `Job` | struct | Core | `JobStore.swift` | Snapshot of one job. |
| `JobState` | enum | Core | `JobStore.swift` | The six lifecycle states. |
| `JobStoreError` | enum | Core | `JobStore.swift` | Submission refusals (`queueFull`). |
| `ExpiredJob` | struct | Core | `JobStore.swift` | Tombstone: a retired job's outcome, without its output. |
| `JobSubmission` | struct | Core | `JobPayload.swift` | Wire payload for `run_shortcut_async`. |
| `JobStatus` | struct | Core | `JobPayload.swift` | Wire payload for `get_shortcut_result` / `cancel_shortcut_job`. |
| `JobListing` | struct | Core | `JobPayload.swift` | One row of `list_shortcut_jobs`. |
| `AuditEvent` | struct | Core | `AuditEvent.swift` | One security-relevant event, as a line of JSON. |
| `GateError` | enum | Executable | `main.swift` | Why a run was refused before anything executed. |
| `MarkdownHTMLRenderer` | struct | MarkdownHTML | `MarkdownHTMLRenderer.swift` | `MarkupVisitor` that emits an HTML page. Build-time only. |

## 2.2 Policy layer — allowlist and configuration

```mermaid
classDiagram
    class Allowlist {
        <<struct, Sendable>>
        +[String: AllowlistEntry] shortcuts
        +decode(Data) Allowlist$
        +load(from: String) Allowlist$
        +entry(for: String) AllowlistEntry?
        +isAllowed(String) Bool
        +timeout(for: String) TimeInterval
        +asyncTimeout(for: String) TimeInterval
        +maxOutputBytes(for: String) Int
        +limitWarnings() [String]
        +describe(installed: [String]) String
    }

    class AllowlistEntry {
        <<struct, Codable, Sendable>>
        +String description
        +String? input
        +[String: String]? schema
        +Bool sideEffect
        +Double? timeoutSeconds
        +Int? maxOutputBytes
        +limitWarnings() [String]
    }

    class ShortcutDescription {
        <<struct, Codable, Sendable>>
        +String name
        +String description
        +String? input
        +Bool sideEffect
        +[String: String]? schema
        +Bool installed
        +String? configWarning
    }

    class AllowlistError {
        <<enum, Error>>
        invalidShortcutName(String)
    }

    class AllowlistLocator {
        <<enum, namespace>>
        +String environmentKey$
        +String configFileName$
        +resolve(arguments, environment, discoveredConfig) String?$
        +discoveredConfig(fileManager) String?$
        +userConfigIfPresent(fileManager) String?$
        +adjacentConfigIfPresent(fileManager) String?$
    }

    class ConfigProvisioner {
        <<enum, namespace>>
        +String emptyConfigContents$
        +applicationSupportDirectory(bundleID, fileManager) URL?$
        +provision(into, configFileName, defaultConfigContents, assets, fileManager) URL$
        -writeNewFileSecurely(Data, to: URL)$
        -isSymlink(at: URL) Bool$
    }

    class ConfigProvisionerError {
        <<enum, Error>>
        writeFailed(path, code)
    }

    Allowlist "1" o-- "0..*" AllowlistEntry : keyed by name
    Allowlist ..> ShortcutDescription : produces in describe()
    Allowlist ..> AllowlistError : throws on load
    ConfigProvisioner ..> ConfigProvisionerError : throws
    AllowlistLocator ..> Allowlist : supplies the path
    ConfigProvisioner ..> AllowlistLocator : seeds the file it will find
```

**Design notes**

- `Allowlist` is immutable and `Sendable`. It is loaded once and read from every
  isolation domain without synchronization.
- `AllowlistEntry.sideEffect` has a **custom `init(from:)`** that defaults it to
  `true` when the JSON key is absent. This is the one place fail-closed behaviour
  is encoded in a decoder.
- `ShortcutDescription` exists so the `list_shortcuts` payload can carry two
  things the entry itself does not know: whether the shortcut is *installed*
  right now, and whether its configured limits were out of range.
- `AllowlistLocator.resolve` takes `discoveredConfig` as an **injected closure**
  so the precedence logic is testable with no filesystem at all.

## 2.3 Execution layer — the subprocess runner

```mermaid
classDiagram
    class ShortcutsRunner {
        <<struct, Sendable>>
        +TimeInterval defaultTimeout$ = 120
        +ClosedRange~TimeInterval~ timeoutRange$ = 5...300
        +ClosedRange~TimeInterval~ asyncTimeoutRange$ = 5...3600
        +Int defaultMaxOutputBytes$ = 10_000_000
        +ClosedRange~Int~ outputBytesRange$ = 1_024...100_000_000
        +String executable
        +TimeInterval timeout
        +Int maxOutputBytes
        +list() async [String]
        +run(name: String, input: String?) async ShortcutResult
        ~invoke(arguments: [String], input: String?) async ShortcutResult
    }

    class ShortcutResult {
        <<struct, Sendable>>
        +Int32 exitCode
        +String stdout
        +String stderr
        +Bool timedOut
    }

    class RunOutput {
        <<struct, Codable, Sendable>>
        +Int32 exit_code
        +String stdout
        +String stderr
        +Bool timed_out
        +jsonString() String
    }

    class OutputCollector {
        <<final class, @unchecked Sendable>>
        -Int cap
        -NSLock lock
        -Data storage
        -Bool didTruncate
        +append(Data)
        +Data data
        +Bool truncated
    }

    class ProcessBox {
        <<final class, @unchecked Sendable>>
        -NSLock lock
        -Process? process
        -Bool running
        -Bool hasExited
        -Int32 exitStatus
        -Bool timedOut
        -Bool cancelled
        +attach(Process) Bool
        +markExited(status: Int32)
        +markTimedOut()
        +requestCancel() Bool
        +terminateIfRunning()
        +killIfRunning()
        -liveTarget() Process?
        +Int32 status
        +Bool didTimeOut
        +Bool didCancel
    }

    ShortcutsRunner ..> ShortcutResult : returns
    ShortcutsRunner ..> OutputCollector : one per stream
    ShortcutsRunner ..> ProcessBox : one per invocation
    RunOutput ..> ShortcutResult : wraps
```

**Design notes**

- `ShortcutsRunner` carries **no state between calls**. The per-run limits are
  properties of the value, so `main.swift` builds a fresh, correctly-limited
  runner for every job rather than mutating a shared one.
- **The class-level constants are the policy bounds**, not the runner's own
  behaviour: `invoke` does not clamp anything. Clamping happens in `Allowlist`
  (`timeout(for:)`, `asyncTimeout(for:)`, `maxOutputBytes(for:)`), which keeps
  mechanism and policy separate.
- `OutputCollector` and `ProcessBox` are the system's only two `@unchecked
  Sendable` types, and both earn it the same way: one `NSLock`, every field
  guarded, no field readable outside it.
- `ProcessBox.liveTarget()` is the single guard behind every signal sent. Without
  it, a timeout work item scheduled at launch could fire after the child exited
  and its PID was recycled — `killIfRunning` signals a raw PID, so it could reach
  an unrelated process. The check narrows that window to the interval between the
  check and the `kill(2)`.

## 2.4 Job layer — the background store

```mermaid
classDiagram
    class JobStore {
        <<actor>>
        -execute closure
        -Int maxConcurrent = 4
        -Int maxJobs = 32
        -Int maxPending = 16
        -Int maxRetainedBytes = 64_000_000
        -TimeInterval retention = 600
        -TimeInterval watchdogTimeout = 3630
        -now closure
        -uptime closure
        -[String: Job] jobs
        -[String: Task] runningTasks
        -Int runningCount
        -waiters array
        -[ExpiredJob] tombstones
        -Set~String~ slotHolders
        +submit(shortcutName, input, timeoutOverride) Job
        +job(id: String) Job?
        +allJobs() [Job]
        +wait(for: String, timeout: TimeInterval) async Job?
        +cancel(id: String) Job?
        +cancelAll()
        +expiredJob(id: String) ExpiredJob?
        -runJob(id, shortcutName, input, timeoutOverride) async
        -finalize(id, result)
        -finalizeFailure(id, message)
        -acquireSlot(id) async Bool
        -releaseSlot(id)
        -reap()
        -remove(id)
        -generateID() String
        -retainedBytes(of: Job) Int
    }

    class Job {
        <<struct, Sendable>>
        +String id
        +String shortcutName
        +JobState state
        +Date submittedAt
        +TimeInterval submittedUptime
        +TimeInterval? startedUptime
        +TimeInterval? finishedUptime
        +ShortcutResult? result
        +String? failureMessage
    }

    class JobState {
        <<enum, String, Codable>>
        queued
        running
        succeeded
        failed
        timed_out
        cancelled
        +Bool isTerminal
    }

    class ExpiredJob {
        <<struct, Sendable>>
        +String id
        +String shortcutName
        +JobState state
    }

    class JobStoreError {
        <<enum, Error>>
        queueFull(limit: Int)
    }

    JobStore "1" o-- "0..*" Job : jobs
    JobStore "1" o-- "0..*" ExpiredJob : tombstones
    Job "1" --> "1" JobState
    Job "1" --> "0..1" ShortcutResult
    ExpiredJob --> JobState
    JobStore ..> JobStoreError : throws on submit
    JobStore ..> ShortcutResult : via injected execute
```

**Design notes**

- The `execute` closure is the **seam that keeps the store testable**. Its
  signature is `(name, input, timeoutOverride) async throws -> ShortcutResult`;
  `main.swift` is the only place that binds it to a real `ShortcutsRunner`.
- `Job` is a **value**. Every query returns an independent copy — mutating a
  returned `Job` cannot affect the store's record.
- **Two clocks are tracked deliberately and are not interchangeable.**
  `submittedAt` (wall clock) exists only to be *reported* as `submitted_at`. Every
  elapsed-time decision — the watchdog, retention, `wait(for:timeout:)` — reads
  the monotonic `uptime` closure. A clock jump must never expire a fresh result
  or declare a healthy job abandoned.
- `slotHolders` tracks concurrency slots **by job id** rather than as a bare
  counter. That is what makes `releaseSlot(id:)` idempotent, which is what lets
  the watchdog reclaim an abandoned job's slot without risking a double release
  when that job's task eventually returns.

## 2.5 Wire layer — payloads and audit

```mermaid
classDiagram
    class JobSubmission {
        <<struct, Codable, Sendable>>
        +String job_id
        +String shortcut
        +String state
        +String submitted_at
        +init(job: Job)
        +jsonString() String
    }

    class JobStatus {
        <<struct, Codable, Sendable>>
        +String job_id
        +String shortcut
        +String state
        +Int? elapsed_seconds
        +Int? duration_seconds
        +Int32? exit_code
        +String? stdout
        +String? stderr
        +Bool? timed_out
        +String? message
        +init(job: Job, uptime: TimeInterval)
        +jsonString() String
    }

    class JobListing {
        <<struct, Codable, Sendable>>
        +String job_id
        +String shortcut
        +String state
        +String submitted_at
        +Int? duration_seconds
        +init(job: Job)
    }

    class AuditEvent {
        <<struct, Codable, Sendable>>
        +String ts
        +String event
        +String tool
        +String? shortcut
        +String? job_id
        +Bool? confirm
        +Bool? side_effect
        +String? reason
        +run(tool, shortcut, jobID, confirm, sideEffect, now) AuditEvent$
        +refused(tool, shortcut, reason, now) AuditEvent$
        +failed(tool, shortcut, jobID, reason, now) AuditEvent$
        +logLine() String
    }

    class GateError {
        <<enum, Error>>
        missingName
        notAllowlisted(String)
        needsConfirmation(String)
    }

    JobSubmission ..> Job : built from
    JobStatus ..> Job : built from
    JobListing ..> Job : built from
    GateError ..> AuditEvent : mapped by auditGateRefusal
```

**Design notes**

- **Optionality is meaningful, not incidental.** `JobStatus`'s optional fields
  are omitted from the JSON entirely when `nil` (Swift's synthesized `Encodable`
  uses `encodeIfPresent`), so an absent `stdout` can never be mistaken for an
  empty one. `elapsed_seconds` appears only while non-terminal;
  `duration_seconds` only once terminal.
- A **cancelled** job reports `stdout`/`stderr` but deliberately omits
  `exit_code` and `timed_out` — a signal-derived exit code means nothing to a
  client, while partial output from a side-effecting shortcut is exactly what the
  caller needs to see.
- `JobListing` **never** carries `stdout`/`stderr`. The tool exists to recover a
  lost `job_id`, not to re-deliver megabytes of output.
- `AuditEvent` **never records shortcut input.** Input can carry personal
  content; the value of the trail is in what was invoked, not what was passed.
- `logLine()` emits compact, key-sorted JSON with one trailing newline, so the
  log stays greppable and diffable.

## 2.6 Whole-system relationships

```mermaid
classDiagram
    direction LR

    class main_swift {
        <<top-level executable>>
        +fail(String) Never
        +gate(name, confirmed) tuple
        +gateErrorText(GateError, toolName) String
        +auditGateRefusal(GateError, toolName)
        +audit(AuditEvent)
        +numberValue(Value?) Double?
        +shutdown()
    }

    class Server {
        <<MCP SDK>>
        +withMethodHandler(ListTools)
        +withMethodHandler(CallTool)
        +start(transport)
    }

    class StdioTransport {
        <<MCP SDK>>
    }

    main_swift --> Server : registers handlers
    Server --> StdioTransport : JSON-RPC over stdio
    main_swift --> Allowlist : loads once, reads per call
    main_swift --> AllowlistLocator : resolves the path
    main_swift --> ConfigProvisioner : first-run setup
    main_swift --> JobStore : submit / wait / cancel / list
    main_swift --> ShortcutsRunner : list() + injected execute
    main_swift --> AuditEvent : writes to stderr
    main_swift ..> GateError : throws + renders
    main_swift ..> JobSubmission : encodes
    main_swift ..> JobStatus : encodes
    main_swift ..> RunOutput : encodes
    JobStore --> Job
    JobStore ..> ShortcutsRunner : via execute closure
    ShortcutsRunner ..> ShortcutResult
    Allowlist o-- AllowlistEntry
    Allowlist ..> ShortcutDescription
```

## 2.7 The build-time renderer

Structurally separate from everything above; it exists only to turn
`assets/MANUAL.md` into `MANUAL.html` during `scripts/build-app.sh`.

```mermaid
classDiagram
    class MarkdownHTMLRenderer {
        <<struct, MarkupVisitor>>
        +typealias Result = String
        +renderPage(markdown: String, title: String) String$
        +defaultVisit(Markup) String
        -renderChildren(of: Markup) String
        -page(title, body) String$
    }
    class MarkupVisitor {
        <<protocol, swift-markdown>>
    }
    class md2html_main {
        <<top-level executable>>
        +warn(String)
    }
    MarkdownHTMLRenderer ..|> MarkupVisitor
    md2html_main --> MarkdownHTMLRenderer
```

Covers the constructs the manual actually uses: headings, paragraphs,
emphasis/strong, inline and fenced code, ordered/unordered lists, block quotes,
thematic breaks, links, soft/hard breaks, and GFM tables. Anything unhandled
falls through `defaultVisit` and degrades to its children's text. Output is a
single self-contained page with embedded CSS and no external assets.
