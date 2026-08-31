<!-- SPDX-License-Identifier: Apache-2.0 -->
# RunShortcutsMCP — Design Documentation

Software design documents for RunShortcutsMCP: what the server is, how it is put
together, and what a maintainer needs to know to change it safely.

These documents describe the system **as it is** at version `1.2.0`. They are
reference material, not a build plan — there are no milestones or phases here.
User-facing instructions live in [`../assets/MANUAL.md`](../assets/MANUAL.md);
release history lives in [`../CHANGELOG.md`](../CHANGELOG.md).

## The documents

| # | Document | Read it when you want to… |
|---|----------|---------------------------|
| 1 | [Architecture](01-architecture.md) | Understand the system boundaries, the process model, the module layout, and why the big decisions were made. |
| 2 | [Class Model](02-class-model.md) | See every type, what it owns, and how the types reference each other (Mermaid class diagrams). |
| 3 | [Sequence Diagrams](03-sequence-diagrams.md) | Trace a request end to end — startup, each of the six tools, timeouts, shutdown. |
| 4 | [Job Lifecycle & Concurrency](04-job-lifecycle.md) | Reason about job states, the concurrency cap, retention/reaping, the watchdog, and the two clocks. |
| 5 | [Security Model](05-security-model.md) | Understand the trust boundaries, the consent model, the implemented controls, and the residual risks. |
| 6 | [Configuration Reference](06-configuration.md) | Look up the allowlist schema, path resolution order, limit clamping, or first-run provisioning. |
| 7 | [Build, Test & Release](07-build-test-release.md) | Build, sign, notarize, or test the project — including why the Python smoke test exists. |
| 8 | [Maintenance Guide](08-maintenance-guide.md) | Add a tool or a shortcut, avoid the known traps, or diagnose a failure in the field. |

## One-paragraph summary

RunShortcutsMCP is a headless macOS **MCP (Model Context Protocol) server**,
written in Swift, that an MCP client (Claude Desktop, Claude Code) launches as a
child process and speaks JSON-RPC to over stdio. It exposes six tools that let
the client run **allowlisted** Apple Shortcuts by name and read their output. It
is a bridge, not a sandbox: safety comes from a default-deny allowlist the user
edits by hand, a `side_effect` confirmation gate, an injection-safe subprocess
runner, and hard limits on time, output size, and concurrency.

## Reading Mermaid diagrams

Every diagram in these documents is a fenced ` ```mermaid ` block. GitHub,
Obsidian, and most Markdown viewers render them inline. If yours does not, paste
the block into <https://mermaid.live>.

## Conventions used here

- **Type names** (`JobStore`) are Swift types; **tool names** (`run_shortcut`)
  are MCP wire names; **`snake_case` fields** are JSON wire keys.
- Code references are given as `path:symbol`, e.g.
  `Sources/RunShortcutsCore/JobStore.swift:reap()`.
- "The client" means the MCP client process. "The assistant" means the model
  driving that client. The distinction matters in the security model — the
  client is trusted to relay, the assistant is trusted only to assert.
