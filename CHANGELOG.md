# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- New changes land here and roll into the next release. -->

## [1.0.0] - 2026-07-25

### Added

- **First-run provisioning:** on first launch the app creates its per-user config
  folder (`~/Library/Application Support/<bundle-id>/`), seeds an empty
  (default-deny) `RunShortcutsMCP.config`, and copies the manual and an example
  config alongside it. No manual setup required.
- **`scripts/build-dmg.sh`:** builds a signed, notarized, drag-to-Applications
  `.dmg` installer (Developer ID Application signature; same notarization
  credentials as `notarize.sh`).
- The manual, example config, and a signed **`TagNote.shortcut`** are bundled into
  the app's `Resources` and deployed on first run + in the `.dmg`, so the example
  config's `TagNote` entry has a matching, installable shortcut.
- Consolidated all deployable inputs under `assets/` (`MANUAL.md`,
  `RunShortcutsMCP.config.example`, `TagNote.shortcut`).
- **HTML manual:** the build now renders `assets/MANUAL.md` to a standalone,
  styled `MANUAL.html` (via a new build-time `md2html` tool using Apple's
  swift-markdown) and deploys the HTML instead of raw Markdown, so end users can
  open it in any browser. The Markdown stays the maintainable source in the repo.
  swift-markdown is scoped to the build tool's targets and is never linked into
  the distributed executable.
- **Per-shortcut execution limits:** optional `timeout_seconds` (5–300s, default 120) and `max_output_bytes` (1 KB–100 MB, default 10 MB) on each allowlist entry; omitting them keeps the secure defaults, and out-of-range values are clamped to the nearest bound and reported (in `list_shortcuts`, in the run result, and in the server log).
- **TagNote add/remove:** the bundled `TagNote` shortcut now takes an optional
  `action` field — `"add"` (default) or `"remove"` — to add or remove a live tag on
  an Apple Note. Removing a tag the note doesn't have is a silent no-op, and the
  shortcut returns a clear error when the required `tag`/`note` are missing or the
  note can't be found.

### Changed

- **Fail-closed `side_effect` default:** an allowlist entry that omits `side_effect`
  is now treated as `true` (confirmation required) instead of `false`.
- **Allowlist resolution fails closed:** removed the working-directory
  `allowlist.json` fallback. If no allowlist is configured (via `--allowlist`, the
  `RUNSHORTCUTS_ALLOWLIST` env var, or the per-user config), the server refuses to
  start rather than trusting the current directory.
- **Dependency pins:** `swift-sdk` and `swift-markdown` now use
  `.upToNextMinor(from:)`, so `swift package update` can't silently pull a breaking
  0.x minor (the committed `Package.resolved` already pins exact revisions).

### Security

- **Argument-injection guard (CWE-88):** allowlist names that are empty or begin
  with `-` are rejected at load, so a crafted name can't be passed as an option to
  the `shortcuts` CLI.
- **Honest consent model:** SECURITY.md now states the `side_effect`/`confirm` gate
  is mediated by the MCP client — the headless server cannot itself verify user
  consent.
- **Subprocess hardening (CWE-400/833):** the shortcuts runner drains stdout/stderr
  concurrently, enforces a wall-clock timeout (SIGTERM then SIGKILL), and caps
  captured output — so a hung or chatty shortcut can't deadlock the pipes, wedge the
  server, or exhaust memory. `SIGPIPE` is ignored so writes to a closed pipe error
  instead of crashing.
- **Provisioning hardening (CWE-59/276/209):** the per-user config directory is
  created `0700` and the seeded config is written `0600` with `O_NOFOLLOW`/`O_EXCL`
  (won't follow a pre-planted symlink). `run_shortcut` failures now return a generic
  message to the client, with the detailed error kept in the server log.

## [0.1.0] - 2026-07-25

### Added

- Initial release: a signed, notarized macOS MCP server that runs **allowlisted**
  Apple Shortcuts on behalf of an MCP client.
- `list_shortcuts` tool — returns the allowlisted shortcuts with their metadata
  and whether each is currently installed.
- `run_shortcut` tool — runs an allowlisted shortcut by name, passing optional
  text/JSON on stdin and returning `{ exit_code, stdout, stderr }`.
- **Default-deny allowlist** with per-entry `description`, `input`, `schema`, and
  `side_effect` metadata. Shortcuts flagged `side_effect` require `confirm=true`.
- Allowlist auto-discovery: `--allowlist` argument →
  `RUNSHORTCUTS_ALLOWLIST` env → `~/Library/Application Support/<bundle-id>/RunShortcutsMCP.config`
  → a config next to the app → `allowlist.json`.
- `scripts/build-app.sh` — builds the SwiftPM binary into a Developer ID–signable
  `.app` bundle and ships the manual + sample config beside it.
- `scripts/notarize.sh` — notarizes and staples via `notarytool` using an
  App Store Connect API key.
- `MANUAL.md` — end-user installation and usage guide, including the requirement
  that all shortcuts be headless.
- Unit tests for the allowlist and path-resolution logic.

## Version links

Reference-style link definitions: they turn the bracketed `[version]` headings
above into links to each version's compare/release page on GitHub. They render
invisibly — you see the linked headings, not these lines.

[Unreleased]: https://github.com/pricemi115/RunShortcutsMCP/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/pricemi115/RunShortcutsMCP/releases/tag/v1.0.0
[0.1.0]: https://github.com/pricemi115/RunShortcutsMCP/releases/tag/v0.1.0
