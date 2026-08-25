# Security Policy

## Supported versions

Security fixes are applied to the latest released version.

| Version | Supported          |
| ------- | ------------------ |
| 1.2.x   | :white_check_mark: |
| < 1.2   | :x:                |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately using **GitHub's private vulnerability reporting** for this
repository (the **Security** tab → **Report a vulnerability**). If you prefer
email, contact **security@grumptech.dev**.

Please include:

- a description of the issue and its impact,
- the version or commit affected,
- steps to reproduce (a minimal allowlist/shortcut/config is ideal), and
- any suggested remediation.

You can expect an initial acknowledgment within a few days. Once a fix is ready,
a patched release is published and the advisory disclosed; credit is given to
reporters who wish to be named.

## Scope and security model

RunShortcutsMCP is a bridge that runs macOS Shortcuts on request. Its safety
rests on a small number of deliberate design choices — please keep these in mind
when assessing reports:

- **Default-deny allowlist.** The server runs **only** shortcuts explicitly
  listed in the user's config file; anything else is refused.
- **Side-effect gate (client-mediated consent).** Shortcuts flagged `side_effect`
  refuse to run unless the *caller* passes `confirm=true`. The server is headless
  and cannot itself verify that a human approved — enforcing genuine user consent
  before asserting `confirm=true` is the MCP client's responsibility. The gate
  bounds *which* runs require that assertion; it does not independently authenticate
  the user. An entry whose `side_effect` is unspecified is treated as `true`
  (confirmation required) by default.

  Because that assertion is the whole gate, the wording the assistant reads is
  part of the control. Both run tools' descriptions, the refusal message, and the
  server's MCP `instructions` all state that the user must be asked first and that
  `confirm=true` must never be set unprompted. Treat a change that weakens or
  removes that wording as a security-relevant change, not an editorial one.
- **No shell interpolation.** The `shortcuts` binary is invoked with an argument
  vector via `Process`, never by building a shell string, so shortcut names and
  input cannot inject shell commands.
- **Audit trail (client-dependent).** Every run, refusal, and launch failure is
  written to standard error as a single JSON line, including whether the caller
  asserted `confirm=true` and whether the entry is flagged `side_effect`. A
  `needs_confirmation` refusal followed closely by a confirmed run of the same
  shortcut is the observable signature of the gate being self-answered rather
  than escalated to the user. Shortcut *input* is never logged. Note the
  dependency: the server only emits to stderr — retention is entirely the MCP
  client's behaviour, and a client that discards stderr leaves no trail at all.
- **User-owned trust boundary.** What a shortcut can do is bounded by what the
  user put in it and by the macOS permissions (TCC) they granted. Adding a
  dangerous shortcut to the allowlist is outside the server's control.

Reports that broaden the blast radius beyond the allowlist, bypass the
`side_effect` confirmation, or achieve command injection are especially valuable.
