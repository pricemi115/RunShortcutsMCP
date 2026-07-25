# RunShortcutsMCP

A small, signed macOS MCP server (Swift) that lets an MCP client (e.g. Claude) run **allowlisted** Apple Shortcuts by name and read their output. It's a general bridge to the Shortcuts automation surface — the first consumer is a `TagNote` shortcut that applies live Apple Notes tags.

## Design in one breath

Two tools over stdio:

- `list_shortcuts` — returns the allowlisted shortcuts (description, input schema, `side_effect`, and whether each is currently installed).
- `run_shortcut(name, input?, confirm?)` — runs `shortcuts run "<name>"`, piping `input` to stdin, returns `{ exit_code, stdout, stderr }`.

Safety is the point: **default-deny allowlist.** Only shortcuts in the config are runnable, and any flagged `side_effect` refuse to run unless the caller passes `confirm: true` (the client is expected to get the user's OK first).

No third-party build tooling — plain Swift Package Manager (`swift build`). The shipped binary's only dependency is the official [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk). A separate build-time tool (`md2html`) uses Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown) to render the manual to HTML; it lives in its own targets and is never linked into the distributed executable.

## Requirements

- macOS 13+ and Swift 6 (Xcode 16+).
- A Developer ID for signing (needed so macOS TCC attributes automation permission to a stable bundle).

## Layout

```
Sources/RunShortcutsCore/   # pure logic: allowlist model, process runner, path resolver, provisioner
Sources/RunShortcutsMCP/    # main.swift: wires the core to the MCP server
Sources/MarkdownHTML/       # build-time only: Markdown → HTML renderer (uses swift-markdown)
Sources/md2html/            # build-time only: CLI that renders assets/MANUAL.md → MANUAL.html
Tests/RunShortcutsCoreTests # unit tests for the allowlist/authorization/provisioning logic
Tests/MarkdownHTMLTests     # unit tests for the Markdown → HTML renderer
packaging/                  # Info.plist + entitlements for the .app bundle
scripts/                    # build-app.sh, build-dmg.sh, notarize.sh
assets/                     # deployable inputs: MANUAL.md (source), RunShortcutsMCP.config.example, TagNote.shortcut
```

The manual is authored in `assets/MANUAL.md` (the maintainable source) and rendered to `MANUAL.html` at build time so end users can open it in any browser without a Markdown viewer.

## Build & test

```bash
swift build
swift test
```

## Make the signed .app (milestone 1)

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/build-app.sh release
```

This produces `build/RunShortcutsMCP.app`. The bundled executable is at:

```
build/RunShortcutsMCP.app/Contents/MacOS/RunShortcutsMCP
```

## Allowlist resolution

The server resolves its allowlist path in this order:

1. `--allowlist <path>` argument,
2. `RUNSHORTCUTS_ALLOWLIST` environment variable,
3. **Per-user config** — `~/Library/Application Support/<bundle-id>/<AppName>.config` (e.g. `…/dev.grumptech.runshortcutsmcp/RunShortcutsMCP.config`). The bundle id is read at runtime from `Bundle.main`, so it always matches the signed identity. This is the recommended default.
4. **Next to the app** — `<AppName>.config` beside the `.app` bundle (single-user convenience fallback).

If none of these resolve, the server **fails closed** — it refuses to start rather than falling back to an `allowlist.json` in the current working directory.

The deployable inputs live in `assets/` (`MANUAL.md`, `RunShortcutsMCP.config.example`, `TagNote.shortcut`); the build scripts render the manual to `MANUAL.html` and bundle everything into the app and the installer. See `assets/MANUAL.md` for the end-user walkthrough.

## Register with the MCP client

Point the client at the **bundled** executable (not a bare `.build` binary) so TCC uses the signed identity. With the config file sitting next to the app, no `args` are needed:

```json
{
  "mcpServers": {
    "run-shortcuts": {
      "command": "/Applications/RunShortcutsMCP.app/Contents/MacOS/RunShortcutsMCP"
    }
  }
}
```

To use an allowlist elsewhere, add `"args": ["--allowlist", "/full/path/to/RunShortcutsMCP.config"]`.

### Milestone-1 check

Ask the client to call `list_shortcuts`. If it returns your allowlisted entries (with `installed: true/false`), the bundle + permission + process-spawn path all work. Then wire up `TagNote` via `run_shortcut`.

## Distribution: Developer ID + notarization (not the App Store)

This tool is distributed **outside** the Mac App Store, by design. The Mac App Store mandates the App Sandbox, and a sandboxed app **cannot execute `/usr/bin/shortcuts`** (sandboxed apps may only launch helper tools embedded in the bundle with an *inherited* sandbox — which can't reach the system `shortcuts`). The architecture also runs as a headless stdio server launched by the MCP client as a child process, which isn't how MAS apps run. So the release path is **Developer ID + notarization**:

```bash
# 1. Build + sign (Developer ID)
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/build-app.sh release

# 2. Notarize + staple (one-time credential setup documented in scripts/notarize.sh)
./scripts/notarize.sh
```

**Credential setup (one-time) — App Store Connect API key.** notarize.sh uses an API key rather than an Apple ID, so no personal login or app-specific password is involved:

```bash
# From App Store Connect → Users and Access → Integrations → App Store Connect API
xcrun notarytool store-credentials "grumptech-notary" \
  --key   /path/to/AuthKey_ABCD1234.p8 \
  --key-id ABCD1234 \
  --issuer 11111111-2222-3333-4444-555555555555
```

The `.p8` key downloads only once — keep it safe. For CI, set `NOTARY_KEY` / `NOTARY_KEY_ID` / `NOTARY_ISSUER` env vars instead of storing a profile.

**Storing the profile in a non-default keychain.** To keep the notary profile out of your login keychain, create a dedicated keychain and pass `--keychain` to *both* `store-credentials` and `submit` (this flag can't be combined with `--sync`/iCloud Keychain):

```bash
security create-keychain -p "<pw>" ~/Library/Keychains/grumptech.keychain-db
security unlock-keychain  -p "<pw>" ~/Library/Keychains/grumptech.keychain-db

xcrun notarytool store-credentials "grumptech-notary" \
  --key /path/AuthKey_ABCD1234.p8 --key-id ABCD1234 \
  --issuer 11111111-2222-3333-4444-555555555555 \
  --keychain ~/Library/Keychains/grumptech.keychain-db
```

Then run notarization pointing at that keychain (unlock it first if locked):

```bash
NOTARY_KEYCHAIN=~/Library/Keychains/grumptech.keychain-db ./scripts/notarize.sh
```

**Privacy.** The notarization credential authenticates only the upload to Apple — it is never embedded in the app or the stapled ticket, and downloaders can't see it. What *is* visible in the signed app (`codesign -dv`) is the certificate's common name and Team ID, e.g. `Developer ID Application: Grumpy Technologies LLC (NK1234567890)`. If you enrolled as an **individual**, that common name is your **legal name** and appears on every app you ship; enroll/sign as an **organization** to show a business name instead. Decide this before distributing publicly — changing it later means re-signing.

### Verify notarization

`codesign -dv` shows the *signature* but says nothing about notarization — the ticket lives in a stapled record and on Apple's servers, so use these instead.

**1. Is the ticket stapled to this copy?** (works offline)

```bash
xcrun stapler validate /Applications/RunShortcutsMCP.app
# want: "The validate action worked!"
```

**2. Will Gatekeeper accept it, and as what?** Use `-t exec` for an `.app` (`-t install` is for `.pkg`/`.dmg`):

```bash
spctl -a -t exec -vvv /Applications/RunShortcutsMCP.app
# want:
#   accepted
#   source=Notarized Developer ID     <-- the key line
```

A signed-but-not-notarized app shows `source=Developer ID` (no "Notarized") or is rejected.

**3. Confirm from Apple's records** (independent of the local copy):

```bash
xcrun notarytool history --keychain-profile "grumptech-notary"
xcrun notarytool info  <submission-id> --keychain-profile "grumptech-notary"   # status: Accepted
xcrun notarytool log   <submission-id> --keychain-profile "grumptech-notary"   # detail if it failed
```

**4. Human check:** re-download (or re-apply quarantine) and double-click — a notarized app opens with "Apple checked it for malicious software and none was detected"; a non-notarized one shows the "cannot verify the developer" block.

Prefer Xcode's build system? Open `Package.swift` directly in Xcode (File ▸ Open…) — it builds the package natively and can archive/sign from there. No `.xcodeproj` is required.

## Notes / caveats (verify on build)

- **SDK API**: written against the MCP Swift SDK 0.11.x server API (`Server`, `StdioTransport`, `withMethodHandler(ListTools/CallTool)`, `Tool(inputSchema:)`). Pre-1.0 minor versions can introduce breaking changes; if `server.start` shifts, adjust `main.swift`. The process is kept alive with a sleep loop (no reliance on version-specific helpers); the client terminates the subprocess on disconnect.
- **GUI flash**: `shortcuts run` can briefly surface the Shortcuts app. Keep allowlisted shortcuts headless-safe (no interactive prompts) so runs don't hang.
- **Blocking I/O**: the process runner reads output synchronously. Fine for small results; revisit if a shortcut streams large output.
- **Notarization**: only needed to distribute to other Macs. For local use, a Developer ID signature is enough.

## Installer (.dmg)

For end users, ship a signed, notarized **disk image**. Build the app first, then the DMG:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./scripts/build-app.sh release     # → build/RunShortcutsMCP.app
./scripts/build-dmg.sh             # → build/RunShortcutsMCP.dmg (signed + notarized)
```

The DMG is signed with the same **Developer ID Application** cert as the app (no separate installer certificate) and notarized/stapled using the same credentials as `notarize.sh`. The disk image shows the app and a drag-to-`/Applications` shortcut at the top level, with the manual (`MANUAL.html`), a reference config, and the example **`TagNote.shortcut`** tucked into a `Resources/` folder.

**First-run provisioning.** Users don't set up the config by hand. The first time the app runs (when the MCP client first launches it), it creates `~/Library/Application Support/<bundle-id>/`, seeds an empty (default-deny) `RunShortcutsMCP.config`, and drops `MANUAL.html`, `RunShortcutsMCP.config.example`, and `TagNote.shortcut` beside it for reference. The user just edits the config.

## License

Licensed under the **Apache License 2.0** — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
You may use, modify, and redistribute this software, including for commercial
purposes, free of charge. See [`CHANGELOG.md`](CHANGELOG.md) for release history
and [`SECURITY.md`](SECURITY.md) to report vulnerabilities.
