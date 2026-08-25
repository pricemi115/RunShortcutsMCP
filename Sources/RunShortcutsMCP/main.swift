// SPDX-License-Identifier: Apache-2.0
//
//  main.swift
//  RunShortcutsMCP
//
//  Executable entry point. Wires the pure `RunShortcutsCore` logic to an MCP
//  stdio server: resolves and loads the allowlist, declares the six shortcut
//  tools — `list_shortcuts`, `run_shortcut`, `run_shortcut_async`,
//  `get_shortcut_result`, `cancel_shortcut_job`, and `list_shortcut_jobs` — and
//  dispatches tool calls through the default-deny allowlist and the
//  `side_effect` confirmation gate. Background jobs are tracked by a `JobStore`
//  so a long-running shortcut never blocks a single `tools/call` long enough to
//  hit the MCP client's own request-timeout ceiling. Keeps the process alive
//  until the MCP client disconnects, cancelling any tracked jobs on the way out.
//

import Foundation
import MCP
import RunShortcutsCore

/// Writes a message to stderr and terminates the process with a non-zero status.
/// Used for unrecoverable startup failures (e.g. a missing/invalid allowlist).
/// - Parameter message: (`String`) Human-readable error written to standard error.
/// - Returns: Never — the process exits before returning.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Startup: first-run provisioning, then resolve + load the allowlist

// Writing to a closed pipe (a child that exited, or a disconnected client) should
// surface as an error rather than killing the process with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

// On first run, create the per-user config folder, seed an empty (default-deny)
// allowlist, and drop the manual + example alongside it. Best-effort: any failure
// here must not stop the server from starting.
let bundleIdentifier = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
if let configDirectory = ConfigProvisioner.applicationSupportDirectory(bundleID: bundleIdentifier) {
    let bundledAssets = [
        Bundle.main.url(forResource: "MANUAL", withExtension: "html"),
        Bundle.main.url(forResource: "RunShortcutsMCP.config", withExtension: "example"),
        Bundle.main.url(forResource: "TagNote", withExtension: "shortcut")
    ].compactMap { $0 }
    _ = try? ConfigProvisioner.provision(
        into: configDirectory,
        configFileName: AllowlistLocator.configFileName,
        defaultConfigContents: ConfigProvisioner.emptyConfigContents,
        assets: bundledAssets
    )
}

guard let allowlistPath = AllowlistLocator.resolve(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    discoveredConfig: { AllowlistLocator.discoveredConfig() }
) else {
    fail("RunShortcutsMCP: no allowlist configured. Provide --allowlist <path>, set RUNSHORTCUTS_ALLOWLIST, or install the per-user config at ~/Library/Application Support/<bundle-id>/RunShortcutsMCP.config.")
}

let allowlist: Allowlist
do {
    allowlist = try Allowlist.load(from: allowlistPath)
} catch {
    fail("RunShortcutsMCP: could not load allowlist at '\(allowlistPath)': \(error)")
}

// Surface any per-shortcut limit values that fall outside the allowed range (they
// will be clamped). Written to stderr, which lands in the MCP client's server log.
for warning in allowlist.limitWarnings() {
    FileHandle.standardError.write(Data("RunShortcutsMCP: config warning — \(warning)\n".utf8))
}

let runner = ShortcutsRunner()

// Backs run_shortcut_async/get_shortcut_result/cancel_shortcut_job/list_shortcut_jobs.
// Every invocation goes through the allowlist's async timeout/output-cap clamping,
// exactly as run_shortcut does for the synchronous path.
let jobStore = JobStore(execute: { name, input in
    let limitedRunner = ShortcutsRunner(
        timeout: allowlist.asyncTimeout(for: name),
        maxOutputBytes: allowlist.maxOutputBytes(for: name)
    )
    return try await limitedRunner.run(name: name, input: input)
})

// MARK: - The allowlist + side-effect gate, shared by both run tools

/// Why a `run_shortcut`/`run_shortcut_async` request was refused before any
/// shortcut was run.
enum GateError: Error {
    /// `name` was missing or empty.
    case missingName
    /// (`String`) `name` is not on the allowlist.
    case notAllowlisted(String)
    /// (`String`) `name` is flagged `side_effect` and `confirm` wasn't `true`.
    case needsConfirmation(String)
}

/// Validates a requested shortcut name against the allowlist and its
/// `side_effect` confirmation gate. This is the one place both `run_shortcut`
/// and `run_shortcut_async` check before anything runs — `get_shortcut_result`,
/// `cancel_shortcut_job`, and `list_shortcut_jobs` never call it, since none of
/// them can cause a shortcut to execute.
/// - Parameters:
///   - name: (`String?`) The requested shortcut name, as read from the tool call arguments.
///   - confirmed: (`Bool`) Whether the caller passed `confirm: true`.
/// - Returns: (`(name: String, entry: AllowlistEntry)`) The validated name and its allowlist entry.
/// - Throws: (`GateError`) Describing why the request was refused.
@Sendable func gate(name: String?, confirmed: Bool) throws -> (name: String, entry: AllowlistEntry) {
    guard let name, !name.isEmpty else { throw GateError.missingName }
    guard let entry = allowlist.entry(for: name) else { throw GateError.notAllowlisted(name) }
    if entry.sideEffect && !confirmed { throw GateError.needsConfirmation(name) }
    return (name, entry)
}

/// Renders a `GateError` as the client-facing refusal message, naming `toolName`
/// in the "re-call with confirm=true" instruction so the model calls back the
/// same tool it used.
/// - Parameters:
///   - error: (`GateError`) The refusal to describe.
///   - toolName: (`String`) The tool the caller should re-call with `confirm: true`.
/// - Returns: (`String`) A human-readable refusal message.
@Sendable func gateErrorText(_ error: GateError, toolName: String) -> String {
    switch error {
    case .missingName:
        return "Missing required 'name'."
    case .notAllowlisted(let name):
        return "Refused: '\(name)' is not on the allowlist."
    case .needsConfirmation(let name):
        return "'\(name)' is flagged side_effect. Obtain the user's confirmation, then re-call \(toolName) with confirm=true."
    }
}

/// Reads a JSON number argument as a `Double`, accepting either wire
/// representation `Value` can decode a number into. `Value.doubleValue` only
/// matches a JSON literal that was written with a decimal point (`.double`);
/// a whole number like `20` decodes as `.int` instead, for which it silently
/// returns `nil` — so a caller sending `"wait_seconds": 20` would otherwise
/// have that argument dropped entirely rather than honored.
/// - Parameter value: (`Value?`) The argument value, if present.
/// - Returns: (`Double?`) The numeric value, or `nil` if absent or not a number.
@Sendable func numberValue(_ value: Value?) -> Double? {
    value?.doubleValue ?? value?.intValue.map(Double.init)
}

// MARK: - Server + tool declarations

// The marketing version is stamped into the bundle's Info.plist from the root
// VERSION file at build time; read it back here so VERSION is the single source of
// truth. Falls back to a dev marker when run outside a bundle (e.g. `swift run`).
let serverVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0+dev"

let server = Server(
    name: "RunShortcuts",
    version: serverVersion,
    capabilities: .init(tools: .init(listChanged: false))
)

/// Read-only tool: enumerates the allowlisted shortcuts and their metadata.
let listTool = Tool(
    name: "list_shortcuts",
    description: "List the allowlisted Apple Shortcuts this server may run, each with its input schema and a flag for whether it is currently installed.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([:])
    ]),
    annotations: .init(readOnlyHint: true)
)

/// Action tool: runs one allowlisted shortcut and waits (briefly) for its output.
let runTool = Tool(
    name: "run_shortcut",
    description: "Run an allowlisted Apple Shortcut and wait for its output. Only suitable for shortcuts that reliably finish in under a minute — the MCP client aborts longer calls. Prefer run_shortcut_async, which has no duration limit and is the recommended path for all shortcuts. Shortcuts flagged side_effect require confirm=true.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Name of an allowlisted shortcut")
            ]),
            "input": .object([
                "type": .string("string"),
                "description": .string("Text or JSON passed to the shortcut via stdin")
            ]),
            "confirm": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to run a shortcut flagged side_effect")
            ])
        ]),
        "required": .array([.string("name")])
    ]),
    annotations: .init(readOnlyHint: false, destructiveHint: true)
)

/// Action tool: starts one allowlisted shortcut in the background and returns a job id immediately.
let runAsyncTool = Tool(
    name: "run_shortcut_async",
    description: "Start an allowlisted Apple Shortcut in the background and immediately return a job_id. Has no duration limit — this is the recommended way to run any shortcut, not just slow ones. Poll get_shortcut_result with the job_id to retrieve the outcome. Shortcuts flagged side_effect require confirm=true at submission.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "name": .object([
                "type": .string("string"),
                "description": .string("Name of an allowlisted shortcut")
            ]),
            "input": .object([
                "type": .string("string"),
                "description": .string("Text or JSON passed to the shortcut via stdin")
            ]),
            "confirm": .object([
                "type": .string("boolean"),
                "description": .string("Must be true to run a shortcut flagged side_effect")
            ])
        ]),
        "required": .array([.string("name")])
    ]),
    annotations: .init(readOnlyHint: false, destructiveHint: true)
)

/// Read-only tool: reports the status, and eventually the output, of a background job.
let getResultTool = Tool(
    name: "get_shortcut_result",
    description: "Check a background shortcut job started by run_shortcut_async. Waits up to wait_seconds (default 45, max 50) for it to finish, then reports its state: 'queued' or 'running' if it's still going — just call this again to keep waiting — or 'succeeded', 'failed', 'timed_out', or 'cancelled' once finished, with exit_code/stdout/stderr included for a finished job. Results stay readable for about 10 minutes after finishing and can be read repeatedly. Never starts or re-runs a shortcut.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "job_id": .object([
                "type": .string("string"),
                "description": .string("The job_id returned by run_shortcut_async")
            ]),
            "wait_seconds": .object([
                "type": .string("number"),
                "description": .string("Seconds to wait for the job to finish before returning its current status; defaults to 45, capped at 50")
            ])
        ]),
        "required": .array([.string("job_id")])
    ]),
    annotations: .init(readOnlyHint: true)
)

/// Action tool: stops a background job that is still queued or running.
let cancelTool = Tool(
    name: "cancel_shortcut_job",
    description: "Stop a background shortcut job that is still queued or running, terminating the underlying process. Has no effect on a job that already finished. A shortcut cancelled mid-run may have already applied some of its changes.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "job_id": .object([
                "type": .string("string"),
                "description": .string("The job_id of the job to stop")
            ])
        ]),
        "required": .array([.string("job_id")])
    ]),
    annotations: .init(readOnlyHint: false, destructiveHint: true)
)

/// Read-only tool: lists tracked background jobs, to recover a lost job id.
let listJobsTool = Tool(
    name: "list_shortcut_jobs",
    description: "List background shortcut jobs started by run_shortcut_async that are still tracked (queued, running, or finished within the last ~10 minutes). Use this to recover a job_id you've lost track of. Never includes stdout/stderr — use get_shortcut_result for that.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([:])
    ]),
    annotations: .init(readOnlyHint: true)
)

// MARK: - Handlers

// Handles `tools/list`: advertises the six tools above.
// - Returns: (`ListTools.Result`) The static tool list.
await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [listTool, runTool, runAsyncTool, getResultTool, cancelTool, listJobsTool])
}

// Handles `tools/call`: dispatches to the requested tool, enforcing the
// default-deny allowlist and the side-effect confirmation gate.
// - Parameter params: (`CallTool.Parameters`) The tool name and its arguments.
// - Returns: (`CallTool.Result`) Tool output; `isError` is set on refusal or an unsuccessful outcome.
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case listTool.name:
        let installed = (try? await runner.list()) ?? []
        return .init(content: [.text(text: allowlist.describe(installed: installed), annotations: nil, _meta: nil)], isError: false)

    case runTool.name:
        let confirmed = params.arguments?["confirm"]?.boolValue ?? false
        let name: String
        let entry: AllowlistEntry
        do {
            (name, entry) = try gate(name: params.arguments?["name"]?.stringValue, confirmed: confirmed)
        } catch let error as GateError {
            return .init(content: [.text(text: gateErrorText(error, toolName: runTool.name), annotations: nil, _meta: nil)], isError: true)
        }
        let input = params.arguments?["input"]?.stringValue
        do {
            let limitedRunner = ShortcutsRunner(
                timeout: allowlist.timeout(for: name),
                maxOutputBytes: allowlist.maxOutputBytes(for: name)
            )
            let result = try await limitedRunner.run(name: name, input: input)
            let configWarnings = entry.limitWarnings()
            let reported = configWarnings.isEmpty
                ? result
                : ShortcutResult(
                    exitCode: result.exitCode,
                    stdout: result.stdout,
                    stderr: result.stderr + "\n[config] " + configWarnings.joined(separator: "; "),
                    timedOut: result.timedOut
                )
            return .init(content: [.text(text: RunOutput(reported).jsonString(), annotations: nil, _meta: nil)], isError: result.exitCode != 0)
        } catch {
            // Keep the detailed error in the local server log; return a generic
            // message to the client so filesystem paths/internals aren't leaked (CWE-209).
            FileHandle.standardError.write(Data("RunShortcutsMCP: run_shortcut '\(name)' failed: \(error)\n".utf8))
            return .init(content: [.text(text: "Failed to run '\(name)'. See the server log for details.", annotations: nil, _meta: nil)], isError: true)
        }

    case runAsyncTool.name:
        let confirmed = params.arguments?["confirm"]?.boolValue ?? false
        let name: String
        do {
            (name, _) = try gate(name: params.arguments?["name"]?.stringValue, confirmed: confirmed)
        } catch let error as GateError {
            return .init(content: [.text(text: gateErrorText(error, toolName: runAsyncTool.name), annotations: nil, _meta: nil)], isError: true)
        }
        let input = params.arguments?["input"]?.stringValue
        let job = await jobStore.submit(shortcutName: name, input: input)
        return .init(content: [.text(text: JobSubmission(job: job).jsonString(), annotations: nil, _meta: nil)], isError: false)

    case getResultTool.name:
        guard let jobID = params.arguments?["job_id"]?.stringValue, !jobID.isEmpty else {
            return .init(content: [.text(text: "Missing required 'job_id'.", annotations: nil, _meta: nil)], isError: true)
        }
        let requestedWait = numberValue(params.arguments?["wait_seconds"]) ?? 45
        let waitSeconds = min(max(requestedWait, 0), 50)
        guard let job = await jobStore.wait(for: jobID, timeout: waitSeconds) else {
            return .init(
                content: [.text(
                    text: "Unknown job id '\(jobID)'. It either never existed, or it finished more than 10 minutes ago and its result expired. Do not retry this id — start a new run if you still need the result.",
                    annotations: nil,
                    _meta: nil
                )],
                isError: true
            )
        }
        // A job still queued/running isn't an error — it's a normal handoff back to the caller.
        let isError = ![JobState.succeeded, .queued, .running].contains(job.state)
        return .init(content: [.text(text: JobStatus(job: job).jsonString(), annotations: nil, _meta: nil)], isError: isError)

    case cancelTool.name:
        guard let jobID = params.arguments?["job_id"]?.stringValue, !jobID.isEmpty else {
            return .init(content: [.text(text: "Missing required 'job_id'.", annotations: nil, _meta: nil)], isError: true)
        }
        guard let job = await jobStore.cancel(id: jobID) else {
            return .init(content: [.text(text: "Unknown job id '\(jobID)'.", annotations: nil, _meta: nil)], isError: true)
        }
        return .init(content: [.text(text: JobStatus(job: job).jsonString(), annotations: nil, _meta: nil)], isError: false)

    case listJobsTool.name:
        let jobs = await jobStore.allJobs()
        return .init(content: [.text(text: jobListingJSONString(jobs), annotations: nil, _meta: nil)], isError: false)

    default:
        return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
    }
}

// MARK: - Graceful shutdown

// A disconnecting client still leaves an in-flight background shortcut's
// subprocess running (reparented to launchd) unless tracked jobs are cancelled
// first — a real consent problem for a side-effecting shortcut. SIGKILL can't be
// caught, so this only covers the two signals a client's own teardown sends.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

/// Cancels every tracked job, then exits. Shared by the `SIGTERM`/`SIGINT` handlers below.
func shutdown() {
    Task {
        await jobStore.cancelAll()
        exit(0)
    }
}

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler(handler: shutdown)
sigtermSource.resume()

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler(handler: shutdown)
sigintSource.resume()

// MARK: - Run

let transport = StdioTransport()
try await server.start(transport: transport)

// Keep the process alive. The MCP client owns our lifecycle and terminates us on
// disconnect; `shutdown()` above runs the actual cleanup when it does.
while true {
    try await Task.sleep(nanoseconds: 60_000_000_000)
}
