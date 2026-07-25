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

    /// Creates a result value.
    /// - Parameters:
    ///   - exitCode: (`Int32`) Process exit status.
    ///   - stdout: (`String`) Captured standard output.
    ///   - stderr: (`String`) Captured standard error.
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
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

    /// Wraps a `ShortcutResult` for serialization.
    /// - Parameter result: (`ShortcutResult`) The captured invocation result to expose over the wire.
    public init(_ result: ShortcutResult) {
        exit_code = result.exitCode
        stdout = result.stdout
        stderr = result.stderr
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

/// Runs the macOS `shortcuts` CLI as a subprocess. Stateless and `Sendable`; the
/// executable path is configurable to ease testing.
public struct ShortcutsRunner: Sendable {
    /// (`TimeInterval`) Default per-run timeout applied when a shortcut specifies none.
    public static let defaultTimeout: TimeInterval = 120

    /// (`ClosedRange<TimeInterval>`) Allowed bounds (seconds) for a configured timeout.
    public static let timeoutRange: ClosedRange<TimeInterval> = 5...300

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
    public func list() throws -> [String] {
        let result = try invoke(arguments: ["list"], input: nil)
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
    public func run(name: String, input: String?) throws -> ShortcutResult {
        try invoke(arguments: ["run", name], input: input)
    }

    /// Spawns `executable` with the given arguments, feeds `input` to stdin, captures
    /// its output, and enforces a wall-clock timeout and a per-stream output cap.
    ///
    /// stdout and stderr are drained concurrently to avoid a pipe-buffer deadlock
    /// (CWE-833); stdin is written on a background queue so a full pipe can't block;
    /// captured output is capped to bound memory (CWE-400); and a child that outlives
    /// `timeout` is terminated (SIGTERM, then SIGKILL after a short grace). Internal
    /// (not private) so it can be unit-tested with arbitrary executables/arguments.
    /// - Parameters:
    ///   - arguments: (`[String]`) Argument vector passed to the process (no shell involved).
    ///   - input: (`String?`) Data written to the child's stdin as UTF-8; `nil` to write nothing.
    /// - Returns: (`ShortcutResult`) The captured exit status and streams; truncation/timeout notes are appended to stderr.
    /// - Throws: An error from `Process.run()` if the subprocess cannot be launched.
    func invoke(arguments: [String], input: String?) throws -> ShortcutResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        // Signaled by the termination handler when the child exits.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        let queue = DispatchQueue(label: "dev.grumptech.runshortcutsmcp.runner", attributes: .concurrent)
        let io = DispatchGroup()
        let outCollector = OutputCollector(cap: maxOutputBytes)
        let errCollector = OutputCollector(cap: maxOutputBytes)

        // Each handle is used only inside its own task below.
        let inHandle = stdinPipe.fileHandleForWriting
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading

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

        // Enforce the timeout: SIGTERM, then SIGKILL after a short grace.
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }

        // Readers finish once the child's pipe ends close (on exit/kill).
        io.wait()

        var stderrText = String(data: errCollector.data, encoding: .utf8) ?? ""
        if outCollector.truncated {
            stderrText += "\n[runner] stdout truncated at \(maxOutputBytes) bytes."
        }
        if errCollector.truncated {
            stderrText += "\n[runner] stderr truncated at \(maxOutputBytes) bytes."
        }
        if timedOut {
            stderrText += "\n[runner] timed out after \(Int(timeout))s; process terminated."
        }

        return ShortcutResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outCollector.data, encoding: .utf8) ?? "",
            stderr: stderrText
        )
    }
}
