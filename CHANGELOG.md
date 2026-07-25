# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

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
