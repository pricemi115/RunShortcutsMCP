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

/// Runs the macOS `shortcuts` CLI as a subprocess. Stateless and `Sendable`; the
/// executable path is configurable to ease testing.
public struct ShortcutsRunner: Sendable {
    /// (`String`) Path to the `shortcuts` binary to invoke.
    public let executable: String

    /// Creates a runner.
    /// - Parameter executable: (`String`) Path to the `shortcuts` binary; defaults to `/usr/bin/shortcuts`.
    public init(executable: String = "/usr/bin/shortcuts") {
        self.executable = executable
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

    /// Spawns `executable` with the given arguments, feeds `input` to stdin, and captures its output.
    /// - Parameters:
    ///   - arguments: (`[String]`) Argument vector passed to the process (no shell involved).
    ///   - input: (`String?`) Data written to the child's stdin as UTF-8; `nil` to write nothing.
    /// - Returns: (`ShortcutResult`) The captured exit status and streams.
    /// - Throws: An error from `Process.run()` if the subprocess cannot be launched.
    private func invoke(arguments: [String], input: String?) throws -> ShortcutResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        if let input, let data = input.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ShortcutResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
