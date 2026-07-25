# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Changed

- **Fail-closed `side_effect` default:** an allowlist entry that omits `side_effect`
  is now treated as `true` (confirmation required) instead of `false`.
- **Allowlist resolution fails closed:** removed the working-directory
  `allowlist.json` fallback. If no allowlist is configured (via `--allowlist`, the
  `RUNSHORTCUTS_ALLOWLIST` env var, or the per-user config), the server refuses to
  start rather than trusting the current directory.

### Security

- **Argument-injection guard (CWE-88):** allowlist names that are empty or begin
  with `-` are rejected at load, so a crafted name can't be passed as an option to
  the `shortcuts` CLI.
- **Honest consent model:** SECURITY.md now states the `side_effect`/`confirm` gate
  is mediated by the MCP client — the headless server cannot itself verify user
  consent.

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

[Unreleased]: https://RunShortcutsMCP.grumptech.dev/compare/v0.1.0...HEAD
[0.1.0]: https://RunShortcutsMCP.grumptech.dev/releases/tag/v0.1.0
