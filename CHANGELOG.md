# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- New changes land here and roll into the next release. -->

## [1.2.0] - 2026-08-24

### Added

- **Shortcuts can now run in the background, with no one-minute limit.** A
  shortcut that takes longer than about a minute used to fail, because the MCP
  client gives up on a request that slow — and no setting on this side could
  change that. The new **`run_shortcut_async`** starts a shortcut and hands back
  a `job_id` straight away, and **`get_shortcut_result`** reports on it. This is
  now the recommended way to run any shortcut, not just slow ones.
- **`cancel_shortcut_job`** — stops waiting on a background shortcut and ends the
  command that launched it. Be aware this does **not** reliably stop the shortcut
  itself: a shortcut already under way is run by the Shortcuts app, not by this
  helper, and will usually carry on and finish. Treat it as "stop waiting", not
  "undo".
- **`list_shortcut_jobs`** — lists jobs from roughly the last ten minutes, so one
  can be found again if its `job_id` is lost.
- **`timed_out` in the run result**, which tells a shortcut stopped for exceeding
  its time limit apart from one that simply failed.
- **The server log now records what was run and what was refused** — one line per
  event, noting the shortcut, whether it ran in the background, and whether the
  assistant claimed you had approved it. Refusals are recorded too, so a shortcut
  being asked for repeatedly, or a confirmation being answered without reaching
  you, is visible after the fact. Shortcut *input* is deliberately never written.
  These go to the helper's error output; where that is kept is decided by the app
  you connect it to, and an app that discards it leaves no record at all. Claude
  Desktop keeps it under `~/Library/Logs/Claude/`.

### Changed

- **`timeout_seconds` can now be as high as 3600 (one hour)** for a shortcut run
  in the background, up from 300. Shortcuts run with `run_shortcut` keep the
  300-second limit, since those still have to finish inside the MCP client's own
  request timeout.
- **Several shortcuts can now run at the same time** — up to four background jobs
  at once, rather than one after another.
- **Quitting the MCP client no longer leaves a shortcut running.** Background
  jobs are stopped as the app shuts down, so a shortcut that changes something
  can't keep going unattended after you quit. (A force-quit can't be intercepted,
  so that case is still possible.)
- **`run_shortcut` returns the same result as before**, and still waits for the
  shortcut to finish — so it remains bound by the MCP client's roughly one-minute
  limit. Its description now says so plainly and points at `run_shortcut_async`.
- **`run_shortcut` now shares the same queue as background runs.** One subtle
  consequence: if four shortcuts are already running, a fifth waits its turn
  instead of starting immediately, and if its time limit passes while it is still
  waiting it reports a timeout — for a shortcut that never actually started. The
  result says so, and **retrying is safe in that case**, including for a shortcut
  that changes something. The upside is that no number of requests can now spawn
  an unlimited number of shortcuts at once, and a synchronous run can be seen in
  `list_shortcut_jobs` and stopped like any other.
- **There is now a limit on how many shortcuts can be queued at once** (16 waiting
  or running). Beyond that, further requests are refused until some finish. This
  bounds what a single burst of requests can set in motion.

### Security

- **The confirmation rule for `side_effect` shortcuts is now stated
  unambiguously.** It previously read only "shortcuts flagged side_effect require
  confirm=true", which an assistant could reasonably act on by simply setting the
  flag — approving a state-changing shortcut on the user's behalf without ever
  asking. Both run tools now say explicitly to obtain the user's approval first
  and never to set `confirm=true` unprompted. This server runs headless and
  cannot verify consent itself, so this wording is what the safety gate rests on.
- **The server now sends MCP `instructions`** describing how its tools work
  together — discovery order, which run tool to prefer, the consent rule, and an
  instruction to treat whatever a shortcut returns as data rather than as commands.
  Clients that pass this to their assistant give it that guidance up front rather
  than leaving it to be discovered through refusals. Support varies by client, so
  every rule that matters is still stated in the individual tool descriptions too.
- **A shortcut whose result has expired is no longer reported as an unknown job.**
  Previously, asking about a job after its result was discarded produced "unknown
  id — start a new run", which for a shortcut that had *already succeeded* was an
  invitation to do it a second time. The server now remembers that the job ran and
  says so, telling the assistant not to repeat it just to recover the output.
- **The manual is franker about what the confirmation does and doesn't
  guarantee** (§7). It previously said the app "requires your confirmation" for
  `side_effect` shortcuts, which reads as a promise the software can't keep — it
  runs headless and cannot show you a prompt, so it can only take the assistant's
  word. The manual now says that plainly, explains that the allowlist is where you
  actually grant permission, and notes that a shortcut which *reads* untrusted
  content is a route into your assistant, not only a route out.

## [1.1.0] - 2026-07-26

### Fixed

- **`TagNote` could silently match the wrong note, or none at all:** Apple's
  built-in **Find Notes** action only supports a "contains" match, not an exact
  one, so a non-unique note title could match unexpectedly, and a missing note
  would fail with no clear signal. `TagNote` now verifies the note it found
  matches the requested title exactly and returns a clear "not found" error
  instead of failing silently.

### Changed

- **Manual:** documented how to debug a headless shortcut mid-build using
  **Speak Text** and a temporarily relocated **Stop and Output** action (§4),
  and noted `TagNote`'s new exact-match verification (§3).

## [1.0.0] - 2026-07-25

First public release.

### Added

- A signed, notarized macOS MCP server that runs **allowlisted** Apple Shortcuts
  on behalf of an MCP client.
- **`list_shortcuts`** — returns your allowlisted shortcuts with their metadata
  and whether each is currently installed.
- **`run_shortcut`** — runs an allowlisted shortcut by name, passing optional
  text/JSON on stdin and returning `{ exit_code, stdout, stderr }`.
- **Default-deny allowlist** with per-entry `description`, `input`, `schema`, and
  `side_effect` metadata. Only shortcuts you list can run at all, and one flagged
  `side_effect` requires `confirm=true` before it will. An entry that omits
  `side_effect` is treated as `true` — it fails closed, so an unmarked shortcut
  still asks first.
- **Allowlist auto-discovery:** `--allowlist` argument → `RUNSHORTCUTS_ALLOWLIST`
  environment variable → `~/Library/Application Support/<bundle-id>/RunShortcutsMCP.config`
  → a config next to the app. If none is configured the server refuses to start,
  rather than trusting the current directory.
- **First-run provisioning:** on first launch the app creates its per-user config
  folder (`~/Library/Application Support/<bundle-id>/`), seeds an empty
  (default-deny) `RunShortcutsMCP.config`, and copies the manual and an example
  config alongside it. No manual setup required.
- **Drag-to-Applications `.dmg` installer**, signed and notarized, so the app can
  be installed the usual way without Gatekeeper warnings.
- The manual, an example config, and a signed **`TagNote.shortcut`** ship inside
  the app and are placed in your config folder on first run, so the example
  config's `TagNote` entry has a matching, installable shortcut ready to go.
- **The manual is a styled HTML page** you can open in any browser.
- **Per-shortcut execution limits:** optional `timeout_seconds` (5–300s, default
  120) and `max_output_bytes` (1 KB–100 MB, default 10 MB) on each allowlist
  entry. Omitting them keeps the safe defaults; a value outside the allowed range
  is clamped to the nearest bound and reported back to you, both when listing your
  shortcuts and when one runs.
- **TagNote add/remove:** the bundled `TagNote` shortcut takes an optional
  `action` field — `"add"` (default) or `"remove"` — to add or remove a live tag on
  an Apple Note. Removing a tag the note doesn't have is a silent no-op, and the
  shortcut returns a clear error when the required `tag`/`note` are missing or the
  note can't be found.

### Security

- **Argument-injection guard (CWE-88):** allowlist names that are empty or begin
  with `-` are rejected at load, so a crafted name can't be passed as an option to
  the `shortcuts` CLI.
- **Honest consent model:** the `side_effect`/`confirm` gate is documented as being
  mediated by the MCP client — this server runs headless and cannot itself verify
  that you actually approved a run.
- **Subprocess hardening (CWE-400/833):** a hung or extremely chatty shortcut can
  no longer wedge the server or exhaust memory. Runs are stopped at a wall-clock
  time limit and captured output is capped.
- **Provisioning hardening (CWE-59/276/209):** your per-user config folder and the
  config file itself are created with owner-only permissions, and will not follow a
  pre-planted symlink. Failed runs now return a generic message rather than one
  that could disclose local file paths; the detail stays in the server log.

## Version links

Reference-style link definitions: they turn the bracketed `[version]` headings
above into links to each version's compare/release page on GitHub. They render
invisibly — you see the linked headings, not these lines.

[Unreleased]: https://github.com/pricemi115/RunShortcutsMCP/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/pricemi115/RunShortcutsMCP/releases/tag/v1.2.0
[1.1.0]: https://github.com/pricemi115/RunShortcutsMCP/releases/tag/v1.1.0
[1.0.0]: https://github.com/pricemi115/RunShortcutsMCP/releases/tag/v1.0.0
