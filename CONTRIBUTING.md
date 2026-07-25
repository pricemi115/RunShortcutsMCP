# Contributing to RunShortcutsMCP

Thanks for your interest in improving RunShortcutsMCP! Contributions of all kinds
are welcome — bug reports, fixes, features, docs, and tests.

## Ways to contribute

- **Report a bug** or **request a feature** by opening an issue. Include your macOS
  version, the app version, and clear reproduction steps.
- **Submit a pull request** for a fix or improvement.
- For anything **security-related**, do **not** open a public issue — see
  [`SECURITY.md`](SECURITY.md) (report privately via GitHub advisories or
  `security@grumptech.dev`).

For a large or design-changing contribution, please open an issue to discuss it
first so we can agree on the approach before you invest time.

## Development setup

Requirements: **macOS 13+** and **Swift 6 (Xcode 16+)**. No third-party build
tooling — plain Swift Package Manager.

```bash
git clone <your fork>
cd RunShortcutsMCP
swift build
swift test
```

To produce a signed, notarized `.app` for distribution, see the README's
"Distribution" section (`scripts/build-app.sh` and `scripts/notarize.sh`).

**The user manual** is authored in `assets/MANUAL.md`. Edit that file — the build
renders it to `MANUAL.html` (via the `md2html` tool) for end users. Don't hand-edit
generated HTML. Keep the manual to the Markdown constructs the renderer supports
(headings, lists, tables, code, block quotes, links, emphasis); the renderer lives
in `Sources/MarkdownHTML` if you need to extend it.

## Coding standards

- **Documentation is required.** Every source file gets a header describing its
  purpose, and every function gets a doc comment covering its purpose, each
  parameter (type + meaning), the return (type + meaning), and any errors thrown.
  Use Swift `///` doc comments.
- **Tests for new logic.** Add or update unit tests for any new behavior; keep the
  pure logic in `RunShortcutsCore` (which is unit-testable) rather than in the
  MCP wiring where practical.
- **Keep dependencies minimal.** The only runtime dependency is the official
  MCP Swift SDK. If you believe a new dependency is warranted, explain why in
  the pull request.
- **No unnecessary comments.** Inline comments only where the *why* is non-obvious;
  the doc headers carry the *what*.
- **Match the surrounding code's conventions.**
- **Preserve the safety model.** The default-deny allowlist, the `side_effect`
  confirmation gate, and argv-array process invocation (no shell strings) are
  load-bearing — don't weaken them without discussion.

## Commit messages

Use an imperative subject line (e.g. "Add timeout to shortcut runs"), wrapped at
~72 columns, with a body explaining *what* changed and *why* when it isn't obvious.
Reference issues in the footer (e.g. `Fixes #12`).

## Pull request process

1. Work on a feature branch off the default branch.
2. Ensure `swift build` and `swift test` pass, and that new logic has tests.
3. Add a bullet to the `[Unreleased]` section of [`CHANGELOG.md`](CHANGELOG.md).
4. Open the PR with a clear description of the change and its motivation; link any
   related issues.

## Licensing of contributions

This project is licensed under the **Apache License 2.0**. By submitting a
contribution, you agree that your contribution is licensed under the same terms,
in accordance with Section 5 of the license (see [`LICENSE`](LICENSE)). You retain
copyright to your contributions.

Please keep an `SPDX-License-Identifier: Apache-2.0` header at the top of any new
source files you add.

## Be respectful

Be kind and constructive in issues and reviews. We're all here to make the tool
better.
