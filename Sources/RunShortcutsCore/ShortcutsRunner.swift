// SPDX-License-Identifier: Apache-2.0
//
//  ShortcutsRunner.swift
//  RunShortcutsMCP
//
//  Thin, injection-safe wrapper around the macOS `/usr/bin/shortcuts` CLI.
//  Spawns the tool as a subprocess (argv array, never a shell string), pipes any
//  input to its stdin, and captures stdout/stderr/exit code. Also defines the
//  result value types, including the JSON payload returned by `run_shortcut`.
//

import Foundation

/// The captured result of one `shortcuts` invocation.
public struct ShortcutResult: Equatable, Sendable {
    /// (`Int32`) Process exit status; `0` means success.
    public let exitCode: Int32
    /// (`String`) Everything the shortcut wrote to standard output.
    public let stdout: String
    /// (`String`) Everything the shortcut wrote to standard error.
    public let stderr: String
    /// (`Bool`) Whether the invocation was force-terminated for exceeding its timeout.
    public let timedOut: Bool

    /// Creates a result value.
    /// - Parameters:
    ///   - exitCode: (`Int32`) Process exit status.
    ///   - stdout: (`String`) Captured standard output.
    ///   - stderr: (`String`) Captured standard error.
    ///   - timedOut: (`Bool`) Whether the invocation was force-terminated for exceeding its timeout; defaults to `false`.
    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// The JSON-encodable form of a `ShortcutResult` returned to the MCP client by
/// `run_shortcut`. Uses snake_case keys (`exit_code`) for the wire payload.
public struct RunOutput: Codable, Sendable {
    /// (`Int32`) Process exit status; `0` means success.
    public let exit_code: Int32
    /// (`String`) Captured standard output.
    public let stdout: String
    /// (`String`) Captured standard error.
    public let stderr: String
    /// (`Bool`) Whether the invocation was force-terminated for exceeding its timeout.
    public let timed_out: Bool

    /// Wraps a `ShortcutResult` for serialization.
    /// - Parameter result: (`ShortcutResult`) The captured invocation result to expose over the wire.
    public init(_ result: ShortcutResult) {
        exit_code = result.exitCode
        stdout = result.stdout
        stderr = result.stderr
        timed_out = result.timedOut
    }

    /// Serializes this output to a pretty-printed JSON string.
    /// - Returns: (`String`) Pretty-printed JSON; falls back to `{"exit_code":<n>}` if encoding fails.
    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"exit_code\":\(exit_code)}"
        }
        return json
    }
}

/// Thread-safe, size-capped accumulator for bytes read from a child's output
/// stream. Bounds memory use (CWE-400): once `cap` bytes are held, further bytes
/// are dropped and `truncated` becomes `true`.
private final class OutputCollector: @unchecked Sendable {
    private let cap: Int
    private let lock = NSLock()
    private var storage = Data()
    private var didTruncate = false

    /// Creates a collector.
    /// - Parameter cap: (`Int`) Maximum bytes to retain.
    init(cap: Int) { self.cap = cap }

    /// Appends a chunk, keeping at most `cap` total bytes.
    /// - Parameter chunk: (`Data`) Newly read bytes.
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard storage.count < cap else { didTruncate = true; return }
        let room = cap - storage.count
        if chunk.count <= room {
            storage.append(chunk)
        } else {
            storage.append(chunk.prefix(room))
            didTruncate = true
        }
    }

    /// (`Data`) Snapshot of the captured bytes.
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }

    /// (`Bool`) Whether any bytes were dropped because the cap was reached.
    var truncated: Bool { lock.lock(); defer { lock.unlock() }; return didTruncate }
}

/// Thread-safe holder for a launched `Process`, coordinating termination requests
/// against the child's actual lifecycle. `Process` is not `Sendable`, so every
/// touch of it happens here, under `lock` — the same earned-`@unchecked` shape as
/// `OutputCollector` above.
///
/// The hazard this exists to prevent, not present in a purely synchronous
/// implementation: a timeout work item scheduled at submission time can fire long
/// after the child has exited and its PID been recycled by the OS. `killIfRunning`
/// signals a raw PID, so without a guard it could reach an unrelated process; the
/// `liveTarget()` check narrows that window to the interval between the check and
/// the `kill(2)` itself.
///
/// Note what is *not* a hazard here, since it is easy to assume otherwise:
/// `Process.terminate()` raises `NSInvalidArgumentException` only for a process
/// that was never launched ("task not launched"), not for one that has already
/// exited — terminating an exited-but-launched process is a safe no-op. That is
/// why the attach-race path in `invoke` may call `process.terminate()` directly
/// after a successful `run()` without consulting this type.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var running = false
    private var hasExited = false
    private var exitStatus: Int32 = 0
    private var timedOut = false
    private var cancelled = false

    /// Attaches the just-launched process, unless cancellation was already
    /// requested before the attach could happen.
    /// - Parameter process: (`Process`) The already-`run()` child process.
    /// - Returns: (`Bool`) `false` if a cancellation raced ahead of this call — the caller must terminate `process` itself in that case, since no future timeout/cancel work item will see it as attached.
    func attach(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        // A fast child can exit — and `markExited` can run — before this call is
        // reached, so treat it as running only if that hasn't already happened.
        running = !hasExited
        return true
    }

    /// Records the child's exit status. Called exactly once, from `Process.terminationHandler`.
    /// - Parameter status: (`Int32`) The process's `terminationStatus`.
    func markExited(status: Int32) {
        lock.lock(); defer { lock.unlock() }
        running = false
        hasExited = true
        exitStatus = status
    }

    /// Marks that the wall-clock timeout fired.
    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        timedOut = true
    }

    /// The attached process, but only while it is genuinely still alive — our own
    /// bookkeeping and Foundation's own view must both agree. This is the single
    /// guard behind every signal this type sends; see the type's doc comment for
    /// why signalling an already-exited process is unsafe.
    /// - Returns: (`Process?`) The live child, or `nil` if none is attached or it has exited.
    private func liveTarget() -> Process? {
        lock.lock(); defer { lock.unlock() }
        guard running, !hasExited, let process, process.isRunning else { return nil }
        return process
    }

    /// Requests cancellation: latches `didCancel`, and terminates the attached
    /// process if one is currently running.
    /// - Returns: (`Bool`) `true` if a live process was signaled; `false` if none was attached yet (in which case the caller of the eventual `attach(_:)` is responsible for terminating the process it just launched).
    @discardableResult
    func requestCancel() -> Bool {
        lock.lock()
        cancelled = true
        lock.unlock()
        guard let target = liveTarget() else { return false }
        target.terminate()
        return true
    }

    /// Sends `SIGTERM` if the process is still attached and running; a no-op otherwise.
    func terminateIfRunning() {
        liveTarget()?.terminate()
    }

    /// Sends `SIGKILL` if the process is still attached and running; a no-op otherwise.
    func killIfRunning() {
        guard let target = liveTarget() else { return }
        kill(target.processIdentifier, SIGKILL)
    }

    /// (`Int32`) The recorded exit status; `0` until `markExited(status:)` has been called.
    var status: Int32 { lock.lock(); defer { lock.unlock() }; return exitStatus }

    /// (`Bool`) Whether the wall-clock timeout fired.
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }

    /// (`Bool`) Whether cancellation was requested.
    var didCancel: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Runs the macOS `shortcuts` CLI as a subprocess. Stateless and `Sendable`; the
/// executable path is configurable to ease testing.
public struct ShortcutsRunner: Sendable {
    /// (`TimeInterval`) Default per-run timeout applied when a shortcut specifies none.
    public static let defaultTimeout: TimeInterval = 120

    /// (`ClosedRange<TimeInterval>`) Allowed bounds (seconds) for a configured timeout
    /// on a synchronous `run_shortcut` call, which must fit inside the MCP client's
    /// own request-timeout ceiling.
    public static let timeoutRange: ClosedRange<TimeInterval> = 5...300

    /// (`ClosedRange<TimeInterval>`) Allowed bounds (seconds) for a configured timeout
    /// on an asynchronous job (`run_shortcut_async`), which is not bound by the
    /// synchronous client-side ceiling.
    public static let asyncTimeoutRange: ClosedRange<TimeInterval> = 5...3600

    /// (`Int`) Default per-stream output cap applied when a shortcut specifies none.
    public static let defaultMaxOutputBytes: Int = 10_000_000

    /// (`ClosedRange<Int>`) Allowed bounds (bytes) for a configured output cap: 1 KB–100 MB.
    public static let outputBytesRange: ClosedRange<Int> = 1_024...100_000_000

    /// (`String`) Path to the `shortcuts` binary to invoke.
    public let executable: String

    /// (`TimeInterval`) Wall-clock limit for a single invocation before the child is terminated.
    public let timeout: TimeInterval

    /// (`Int`) Maximum bytes captured from stdout and from stderr (each); further output is dropped.
    public let maxOutputBytes: Int

    /// Creates a runner.
    /// - Parameters:
    ///   - executable: (`String`) Path to the `shortcuts` binary; defaults to `/usr/bin/shortcuts`.
    ///   - timeout: (`TimeInterval`) Seconds before a running invocation is force-terminated; defaults to `defaultTimeout` (120). Not clamped here — bounds are applied by the allowlist policy layer.
    ///   - maxOutputBytes: (`Int`) Per-stream cap on captured output in bytes; defaults to `defaultMaxOutputBytes` (10 MB). Not clamped here.
    public init(executable: String = "/usr/bin/shortcuts", timeout: TimeInterval = ShortcutsRunner.defaultTimeout, maxOutputBytes: Int = ShortcutsRunner.defaultMaxOutputBytes) {
        self.executable = executable
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    /// Lists the shortcuts installed on this machine (`shortcuts list`).
    /// - Returns: (`[String]`) Installed shortcut names, trimmed, with blank lines removed.
    /// - Throws: An error from `Process.run()` (e.g. the binary is missing or not executable).
    public func list() async throws -> [String] {
        let result = try await invoke(arguments: ["list"], input: nil)
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Runs a named shortcut (`shortcuts run <name>`), passing optional input on stdin.
    /// - Parameters:
    ///   - name: (`String`) The shortcut name to run. Passed as a discrete argv element, never interpolated into a shell.
    ///   - input: (`String?`) Text/JSON written to the shortcut's stdin; `nil` to send nothing.
    /// - Returns: (`ShortcutResult`) The captured exit code, stdout, and stderr.
    /// - Throws: An error from `Process.run()` if the subprocess cannot be launched.
    public func run(name: String, input: String?) async throws -> ShortcutResult {
        try await invoke(arguments: ["run", name], input: input)
    }

    /// Spawns `executable` with the given arguments, feeds `input` to stdin, captures
    /// its output, and enforces a wall-clock timeout and a per-stream output cap.
    ///
    /// stdout and stderr are drained concurrently to avoid a pipe-buffer deadlock
    /// (CWE-833); stdin is written on a background queue so a full pipe can't block;
    /// captured output is capped to bound memory (CWE-400); and a child that outlives
    /// `timeout` is terminated (SIGTERM, then SIGKILL after a short grace). Runs
    /// entirely off the calling task's cooperative thread — the only suspension point
    /// is the single continuation resumed once the child has exited and both streams
    /// have reached EOF — so a long-running invocation never blocks other work.
    /// Cooperative with `Task` cancellation: cancelling the calling task terminates
    /// the child. Internal (not private) so it can be unit-tested with arbitrary
    /// executables/arguments.
    /// - Parameters:
    ///   - arguments: (`[String]`) Argument vector passed to the process (no shell involved).
    ///   - input: (`String?`) Data written to the child's stdin as UTF-8; `nil` to write nothing.
    /// - Returns: (`ShortcutResult`) The captured exit status and streams; truncation/timeout/cancellation notes are appended to stderr.
    /// - Throws: An error from `Process.run()` if the subprocess cannot be launched.
    func invoke(arguments: [String], input: String?) async throws -> ShortcutResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        // Each handle is used only inside its own task below.
        let inHandle = stdinPipe.fileHandleForWriting
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading

        let box = ProcessBox()
        let queue = DispatchQueue(label: "dev.grumptech.runshortcutsmcp.runner", attributes: .concurrent)
        let io = DispatchGroup()
        let outCollector = OutputCollector(cap: maxOutputBytes)
        let errCollector = OutputCollector(cap: maxOutputBytes)
        let runTimeout = timeout
        let outputCap = maxOutputBytes

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShortcutResult, Error>) in
                // Signaled (via io.leave()) when the child exits, from Foundation's own
                // callback queue — exactly once, since terminationHandler fires once per
                // successfully launched process.
                io.enter()
                process.terminationHandler = { finished in
                    box.markExited(status: finished.terminationStatus)
                    io.leave()
                }

                do {
                    try process.run()
                } catch {
                    io.leave()
                    continuation.resume(throwing: error)
                    return
                }

                if !box.attach(process) {
                    // A cancellation raced ahead of attach(); the child was already
                    // launched (process.run() above), so terminate it directly rather
                    // than leaving it running with no future timeout/cancel work item
                    // able to see it as attached.
                    process.terminate()
                }

                // Write stdin on a background queue so a full pipe can't block the caller.
                queue.async {
                    if let input, let data = input.data(using: .utf8) {
                        try? inHandle.write(contentsOf: data)
                    }
                    try? inHandle.close()
                }

                // Drain both streams concurrently until EOF.
                io.enter()
                queue.async {
                    while true {
                        let chunk = outHandle.availableData
                        if chunk.isEmpty { break }
                        outCollector.append(chunk)
                    }
                    io.leave()
                }
                io.enter()
                queue.async {
                    while true {
                        let chunk = errHandle.availableData
                        if chunk.isEmpty { break }
                        errCollector.append(chunk)
                    }
                    io.leave()
                }

                // Enforce the timeout: SIGTERM, then SIGKILL after a short grace. Both
                // work items are cancelled once the child has actually exited (in the
                // io.notify block below) so a slow-firing item can never reach a process
                // that has already gone away — see ProcessBox's doc comment.
                let sigterm = DispatchWorkItem {
                    box.markTimedOut()
                    box.terminateIfRunning()
                }
                let sigkill = DispatchWorkItem {
                    box.killIfRunning()
                }
                queue.asyncAfter(deadline: .now() + runTimeout, execute: sigterm)
                queue.asyncAfter(deadline: .now() + runTimeout + 2, execute: sigkill)

                // Fires once the exit signal and both drains have all left the group —
                // i.e. once the child has exited and its streams have reached EOF.
                io.notify(queue: queue) {
                    sigterm.cancel()
                    sigkill.cancel()

                    var stderrText = String(data: errCollector.data, encoding: .utf8) ?? ""
                    if outCollector.truncated {
                        stderrText += "\n[runner] stdout truncated at \(outputCap) bytes."
                    }
                    if errCollector.truncated {
                        stderrText += "\n[runner] stderr truncated at \(outputCap) bytes."
                    }
                    let timedOut = box.didTimeOut
                    if timedOut {
                        stderrText += "\n[runner] timed out after \(Int(runTimeout))s; process terminated."
                    } else if box.didCancel {
                        stderrText += "\n[runner] cancelled; process terminated."
                    }

                    continuation.resume(returning: ShortcutResult(
                        exitCode: box.status,
                        stdout: String(data: outCollector.data, encoding: .utf8) ?? "",
                        stderr: stderrText,
                        timedOut: timedOut
                    ))
                }
            }
        } onCancel: {
            box.requestCancel()
        }
    }
}
