# Security Policy

## Supported versions

This project is pre-1.0 and moves quickly. Security fixes are applied to the
latest released version only.

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1   | :x:                |

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
- **No shell interpolation.** The `shortcuts` binary is invoked with an argument
  vector via `Process`, never by building a shell string, so shortcut names and
  input cannot inject shell commands.
- **User-owned trust boundary.** What a shortcut can do is bounded by what the
  user put in it and by the macOS permissions (TCC) they granted. Adding a
  dangerous shortcut to the allowlist is outside the server's control.

Reports that broaden the blast radius beyond the allowlist, bypass the
`side_effect` confirmation, or achieve command injection are especially valuable.
