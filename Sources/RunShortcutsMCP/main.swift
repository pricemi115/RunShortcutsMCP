//
//  main.swift
//  RunShortcutsMCP
//
//  Executable entry point. Wires the pure `RunShortcutsCore` logic to an MCP
//  stdio server: resolves and loads the allowlist, declares the `list_shortcuts`
//  and `run_shortcut` tools, and dispatches tool calls through the default-deny
//  allowlist and the `side_effect` confirmation gate. Keeps the process alive
//  until the MCP client disconnects.
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

// MARK: - Startup: resolve + load the allowlist (fail fast if unusable)

let allowlistPath = AllowlistLocator.resolve(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    discoveredConfig: { AllowlistLocator.discoveredConfig() }
)

let allowlist: Allowlist
do {
    allowlist = try Allowlist.load(from: allowlistPath)
} catch {
    fail("RunShortcutsMCP: could not load allowlist at '\(allowlistPath)': \(error)")
}

let runner = ShortcutsRunner()

// MARK: - Server + tool declarations

let server = Server(
    name: "RunShortcuts",
    version: "0.1.0",
    capabilities: .init(tools: .init(listChanged: false))
)

/// Read-only tool: enumerates the allowlisted shortcuts and their metadata.
let listTool = Tool(
    name: "list_shortcuts",
    description: "List the allowlisted Apple Shortcuts this server may run, each with its input schema and a flag for whether it is currently installed.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([:])
    ])
)

/// Action tool: runs one allowlisted shortcut, guarded by the `confirm` flag.
let runTool = Tool(
    name: "run_shortcut",
    description: "Run an allowlisted Apple Shortcut by name, passing optional text or JSON input via stdin. Shortcuts flagged side_effect require confirm=true.",
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
    ])
)

// MARK: - Handlers

// Handles `tools/list`: advertises the two tools above.
// - Returns: (`ListTools.Result`) The static tool list.
await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [listTool, runTool])
}

// Handles `tools/call`: dispatches to the requested tool, enforcing the
// default-deny allowlist and the side-effect confirmation gate.
// - Parameter params: (`CallTool.Parameters`) The tool name and its arguments.
// - Returns: (`CallTool.Result`) Tool output; `isError` is set on refusal or non-zero exit.
await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case listTool.name:
        let installed = (try? runner.list()) ?? []
        return .init(content: [.text(text: allowlist.describe(installed: installed), annotations: nil, _meta: nil)], isError: false)

    case runTool.name:
        guard let name = params.arguments?["name"]?.stringValue, !name.isEmpty else {
            return .init(content: [.text(text: "Missing required 'name'.", annotations: nil, _meta: nil)], isError: true)
        }
        guard let entry = allowlist.entry(for: name) else {
            return .init(content: [.text(text: "Refused: '\(name)' is not on the allowlist.", annotations: nil, _meta: nil)], isError: true)
        }
        let confirmed = params.arguments?["confirm"]?.boolValue ?? false
        if entry.sideEffect && !confirmed {
            return .init(
                content: [.text(text: "'\(name)' is flagged side_effect. Obtain the user's confirmation, then re-call run_shortcut with confirm=true.", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let input = params.arguments?["input"]?.stringValue
        do {
            let result = try runner.run(name: name, input: input)
            return .init(content: [.text(text: RunOutput(result).jsonString(), annotations: nil, _meta: nil)], isError: result.exitCode != 0)
        } catch {
            return .init(content: [.text(text: "Failed to run '\(name)': \(error)", annotations: nil, _meta: nil)], isError: true)
        }

    default:
        return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)], isError: true)
    }
}

// MARK: - Run

let transport = StdioTransport()
try await server.start(transport: transport)

// Keep the process alive. The MCP client owns our lifecycle and terminates us on disconnect.
while true {
    try await Task.sleep(nanoseconds: 60_000_000_000)
}
