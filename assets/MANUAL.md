# RunShortcutsMCP — Installation & User Guide

RunShortcutsMCP is a small macOS helper that lets an AI assistant (like Claude) run **Apple Shortcuts** you have explicitly approved — and nothing else. You keep a short list of the shortcuts it's allowed to run; the assistant can run those by name and read back whatever they produce.

This guide covers installing it, connecting it to Claude, managing your approved-shortcuts list, and — importantly — how to build shortcuts that work with it.

---

## 1. Install the app

1. Move **`RunShortcutsMCP.app`** to your **Applications** folder (either `/Applications` or `~/Applications`).
2. You don't "open" this app the normal way — there's no window. The assistant launches it in the background when it needs it. (It's a notarized, signed app, so macOS won't show a scary "unidentified developer" warning.)
3. **First run permission:** the very first time it runs a shortcut, macOS may ask whether to allow it to control **Shortcuts** (or Notes, Calendar, etc., depending on what the shortcut touches). Click **OK / Allow**. This is a one-time prompt per target app, remembered afterward. You can review or change these later in **System Settings ▸ Privacy & Security ▸ Automation** (and the relevant app categories).

---

## 2. Connect it to Claude

The app talks to Claude Desktop through a small config file.

> These instructions use Claude Desktop, which is what this guide assumes throughout. The helper is a standard MCP server, though, so it works with any app that speaks MCP — the setup is the same idea (point the app at the executable), only the config file and its location differ. Consult that app's documentation for where its MCP settings live.

1. In Claude Desktop, open the **Claude** menu (macOS menu bar) ▸ **Settings…** ▸ **Developer** ▸ **Edit Config**. That opens `claude_desktop_config.json` (creating it if needed). Its location is:

   ```
   ~/Library/Application Support/Claude/claude_desktop_config.json
   ```

2. Add a `run-shortcuts` server entry. Point **`command`** at the binary *inside* the app bundle, and **`args`** at your allowlist file (see §3):

   ```json
   {
     "mcpServers": {
       "run-shortcuts": {
         "command": "/Applications/RunShortcutsMCP.app/Contents/MacOS/RunShortcutsMCP"
       }
     }
   }
   ```

   That's all — no other arguments needed. The app automatically finds your allowlist file, **`RunShortcutsMCP.config`**, in your personal config folder (see §3). Adjust the `command` path if you put the app somewhere other than `/Applications`.

   *(Advanced, optional: to keep the config somewhere else, add `"args": ["--allowlist", "/full/path/to/RunShortcutsMCP.config"]`.)*

3. **Completely quit and reopen Claude Desktop** (a window close isn't enough — it must relaunch to start the helper).

4. **Verify:** ask Claude to *"list my shortcuts."* If it returns your approved list, you're connected.

> **Logs, if something's off:** the helper reports problems on its *error output*, and the app you connect it to decides what to do with that. In **Claude Desktop** it's saved to `~/Library/Logs/Claude/`, in a file named after whatever you called the server in the config above — so the `run-shortcuts` entry shown here produces `mcp-server-run-shortcuts.log`. Other MCP apps keep their logs elsewhere (or, in a few cases, throw them away — see §8). The most common thing you'll find there is a wrong path to the config file.

---

## 3. Your approved-shortcuts list (`RunShortcutsMCP.config`)

The assistant can run a shortcut **only if it appears in your list**. Anything not listed is refused. This is your safety fence — you decide exactly what's on the table.

### Name and location

- **Name the file after the app, with a `.config` extension:** `RunShortcutsMCP.config`.
- **Put it in your personal Application Support folder**, in a subfolder named after the app's identifier:

  ```
  ~/Library/Application Support/dev.grumptech.runshortcutsmcp/RunShortcutsMCP.config
  ```

  This is a per-user location — your own list, editable without admin rights, and it works no matter where the app itself lives (including a shared `/Applications`). The app discovers it automatically; there's nothing to configure.

  **You don't have to create any of this by hand.** The first time the app runs (when Claude first calls it), it creates this folder, seeds an empty `RunShortcutsMCP.config`, and drops a browser-viewable copy of this manual (`MANUAL.html`), a reference `RunShortcutsMCP.config.example`, and the ready-to-install **`TagNote.shortcut`** right beside it. Just open the config and add your shortcuts (see **Format**, below). To open the folder in Finder:

  ```bash
  open ~/Library/Application\ Support/dev.grumptech.runshortcutsmcp
  ```

- *(Single-user convenience: a `RunShortcutsMCP.config` placed right next to `RunShortcutsMCP.app` also works, and is used only if the Application Support file above isn't present. Never put it **inside** `RunShortcutsMCP.app` — that breaks the app's signature.)*
- *(Advanced: point `--allowlist` at any path in the Claude config args, as in §2.)*

### The bundled example shortcut (TagNote)

The default install **includes a ready-to-use shortcut called `TagNote`** — it's the one the example config refers to, and it adds or removes a live tag on an Apple Note (send `"action": "add"` (the default) or `"remove"`). Apple's built-in **Find Notes** action only supports a "contains" match, not an exact one, so `TagNote` separately verifies the note it found matches the requested title exactly — if it doesn't, it returns a clear "not found" error instead of silently tagging the wrong note (or doing nothing).

**Where to find it.** A signed `TagNote.shortcut` file ships in two places:

- in the **`Resources`** folder inside the disk image you installed from (the window that opened when you double-clicked the download), and
- in your config folder, where the app drops a copy on first run:
  `~/Library/Application Support/dev.grumptech.runshortcutsmcp/TagNote.shortcut`
  (open that folder with the `open …` command above).

**How to install it.** Double-click `TagNote.shortcut` in Finder (or drag it onto the Shortcuts app). The Shortcuts app opens and adds it to your library — that's the whole process. Once it's installed *and* listed in your `RunShortcutsMCP.config`, the assistant can run it.

To confirm, ask the assistant to *"list my shortcuts"* — `TagNote` should appear with `installed: true`.

### Format

It's a JSON file. Each entry is keyed by the **exact name** of a Shortcut, with a little metadata:

```json
{
  "shortcuts": {
    "TagNote": {
      "description": "Add or remove a tag on an Apple Note.",
      "input": "json",
      "schema": {
        "tag": "the tag name (no # symbol)",
        "note": "the exact title of the note",
        "action": "\"add\" (default) or \"remove\""
      },
      "side_effect": true
    },
    "BatteryLevel": {
      "description": "Report the current battery percentage.",
      "input": "none",
      "side_effect": false,
      "timeout_seconds": 15
    }
  }
}
```

**Field reference:**

| Field | Type | Meaning |
|-------|------|---------|
| *(key)* | text | The **exact** Shortcut name, matching the Shortcuts app character-for-character. Must not be empty or begin with `-`. |
| `description` | text | Plain-English summary of what the shortcut does. The assistant sees this. |
| `input` | text | A hint about what to send: `"json"`, `"text"`, or `"none"`. Optional. |
| `schema` | object | For JSON input, a map of field name → description. Optional; documentation only. |
| `side_effect` | true/false | Whether the assistant must ask you again, at the moment it runs. `true` = ask every time; `false` = you've already decided, just run it. Set `false` for anything you want to *just work* — that's the normal case, and it's fine for shortcuts that change things, once you've decided you're happy for them to run on request. Keep `true` for the genuinely consequential ones (messaging other people, spending money, deleting). **If omitted, it defaults to `true`**, so a shortcut you haven't thought about yet prompts rather than running silently. See §7. |
| `timeout_seconds` | number | Max seconds the shortcut may run before it's stopped. Optional; default **120**. Allowed range depends on how the assistant runs it: **5–300** when it waits for the result directly, **5–3600** (up to an hour) when it runs the shortcut in the background — see "Time and output limits" below. Values outside the allowed range are clamped. |
| `max_output_bytes` | number | Max bytes of output captured before the result is truncated. Optional; default **10000000** (~10 MB), allowed **1024–100000000** (1 KB–100 MB, clamped). |

### Changing the list

Edit the file, then **quit and reopen Claude Desktop** so the helper reloads it. Adding a new automation is just: build the Shortcut (§4), then add one entry here — no reinstall.

---

## 4. Building a Shortcut that works with this app

Create shortcuts in the **Shortcuts** app (Applications ▸ Shortcuts). A few rules make them work smoothly with RunShortcutsMCP:

1. **The name must match exactly.** The name in the Shortcuts app must be identical to the key in your `.config` file — same spelling, spacing, and capitalization.

2. **Reading input.** When the assistant runs your shortcut, any input it sends arrives as the built-in **Shortcut Input**.
   - For simple text, just use **Shortcut Input** directly.
   - For structured input (recommended), have the assistant send **JSON** and start your shortcut with a **Get Dictionary from Input** action. Then pull fields with **Get Dictionary Value** (e.g. get `tag`, get `note`).

3. **Returning a result.** Whatever your shortcut *outputs* is what the assistant reads back.
   - End the shortcut with a **Stop and Output** action (or make the final action a **Text** action) containing the value you want to return.
   - If your shortcut only *does* something and returns nothing (like toggling a light), that's fine — the assistant just sees an empty, successful result.
   - **For "tell me the state of X" shortcuts** (e.g. *is the door locked?*), you **must** end with Stop and Output / Text, or the answer never leaves the shortcut.

4. **Mark side effects.** If the shortcut changes anything, set `"side_effect": true` in the config so the assistant asks you first.

5. **Test it yourself first.** In Terminal:

   ```bash
   # no input:
   shortcuts run "BatteryLevel"

   # JSON input (note: pass text via stdin, not the -i flag):
   shortcuts run "TagNote" <<< '{"tag":"Errands","note":"Groceries"}'
   ```

   If it behaves in Terminal, it'll behave for the assistant.

6. **Debugging mid-run values.** Headless shortcuts have no UI (§5), so you can't just watch one run to see what a variable holds partway through. Two actions make this easy while you're still building and testing — remove both before the shortcut goes on your allowlist:
   - **Speak Text** — drop it anywhere mid-shortcut to have your Mac read a variable's value out loud as it runs. It doesn't pause for a response, so it's safe during test runs.
   - **Stop and Output** — temporarily move it earlier, right after the step you want to inspect, so `shortcuts run` prints that intermediate value to the Terminal instead of running to the end. Move it back to the final action once the value looks right.

   A stray early **Stop and Output** left in place will make the assistant see a truncated result on every real run; a leftover **Speak Text** adds unwanted noise to what should be a silent, headless run. Strip both out (or move **Stop and Output** back to the end) before adding the shortcut to `RunShortcutsMCP.config`.

---

## 5. ⚠️ Every shortcut MUST be "headless" — please read this

**This is the single most important rule.** Every shortcut you allow **must run from start to finish completely on its own, without ever stopping to ask you anything or popping up something you have to tap.**

**What "headless" means, in plain terms:** *headless* means "no head" — no screen, no person watching, nobody to answer questions. When the assistant runs your shortcut, it runs **invisibly in the background**. There is **no one sitting there** to click a button, type an answer, pick from a menu, or dismiss a pop-up. If your shortcut stops and waits for any of that, it will **hang forever** — the assistant will just sit there waiting, because the answer it needs is never coming.

Think of it like leaving a voicemail for a robot: it can follow a fixed script perfectly, but the moment the script says "ask the human which option they want," everything freezes, because there's no human on the line.

**Do NOT use actions that stop and wait for a person, including:**

- **Ask for Input** (typing a response)
- **Choose from Menu** / **Choose from List** (picking an option)
- **Show Alert**, **Show Notification** that requires a tap, or any dialog with buttons to dismiss
- **"Ask Each Time"** parameters on any action (these secretly pause and ask)
- **Dictate Text**, **Take Photo**, **Scan** — anything that opens a live capture UI
- **Show Result** / any action whose only job is to display something to a person and wait

**These are fine** (they run straight through):

- Getting/looking up data (calendar, reminders, Home state, files, web)
- Doing something (toggle a light, send a *pre-addressed* message, edit a note)
- Transforming text, numbers, dictionaries
- Ending with **Stop and Output** / **Text** to hand a result back

**Rule of thumb:** if you can run the shortcut and it finishes **without you touching anything**, it's headless. If it ever pauses for you, fix it before adding it to your list — otherwise it will freeze the assistant.

> Tip: any action that has an **"Ask Each Time"** magic-variable option should instead be set to a **fixed value** or a value **taken from the Shortcut Input**.

### Time and output limits

Every run has two safety limits. Sensible **defaults apply automatically**, and you can **override them per shortcut** in the config (see the field reference in §3):

- **Time limit — default 120 seconds** (`timeout_seconds`). If a shortcut hasn't finished in this time, the assistant stops it. This mostly catches a shortcut stuck waiting on something (see the headless rule above) or doing too much work. The allowed range depends on how the assistant runs the shortcut — see "Running slow shortcuts in the background," next.
- **Output limit — default ~10 MB** (`max_output_bytes`; allowed range **1024–100000000** bytes, i.e. 1 KB–100 MB). Output beyond the limit is truncated.

Values outside the allowed range are **clamped** to the nearest bound, so you can't accidentally disable a limit. When a limit kicks in, the assistant sees a short note (e.g. *"timed out after 120s"* or *"output truncated"*). Keep most shortcuts quick and their output modest, and raise a limit only for the specific shortcut that needs it.

If you set a value outside the allowed range, it's clamped **and reported**, so you'll know: it appears next to the shortcut when you ask the assistant to *"list my shortcuts"*, in the result when that shortcut runs, and in the server log.

### Running slow shortcuts in the background

Claude's own connection to the helper has a roughly one-minute limit on any single request — nothing in this app's config can change that. So a shortcut that might take longer than a minute needs to run differently: the assistant starts it, gets back a **job ID** right away, and then checks back on that job ID until it's done, rather than sitting there waiting.

You don't need to do anything to enable this — it's how the assistant is instructed to run shortcuts by default, and it's the reason `timeout_seconds` can go as high as **3600** (one hour) instead of just 300: a background job isn't limited by Claude's one-minute request window the way a direct wait is. If you ask the assistant to run something and it comes back saying it's "still running, checking again," that's this working as intended — not a problem to fix.

A background job's result stays available for about **10 minutes** after it finishes. If the assistant loses track of a job (a very long gap between checks, or a restarted conversation), it's gone for good after that — there's no way to recover an expired result, only to run the shortcut again.

---

## 6. Troubleshooting

- **Claude doesn't see the tool.** Fully quit and reopen Claude Desktop. Double-check the `command` path points at `…/RunShortcutsMCP.app/Contents/MacOS/RunShortcutsMCP`. Then check the helper's log (§2 — for Claude Desktop, `~/Library/Logs/Claude/mcp-server-run-shortcuts.log`).
- **"… is not on the allowlist."** The shortcut name isn't in your `.config`, or the spelling doesn't match. Add/fix it, then restart Claude.
- **It runs but hangs, then stops after a while.** The shortcut almost certainly isn't headless (§5) — it's waiting for a person. Remove the interactive action. (The default time limit is 120s; a genuinely slow shortcut can raise it up to 3600s (1 hour) with `timeout_seconds` — see "Time and output limits" in §5.)
- **The result looks cut off, or mentions "truncated."** The shortcut returned more than the output limit (default ~10 MB). Have it return a smaller, more focused result, or raise `max_output_bytes` (up to 100 MB) for that shortcut.
- **A "tell me…" shortcut returns nothing.** It's missing a **Stop and Output** / final **Text** action (§4.3).
- **"Unknown job id" / "its result expired."** A background job's result is only kept for about 10 minutes after it finishes (§5). If the assistant checked back later than that, the result is gone — it needs to run the shortcut again, not keep asking about the old job.
- **Permission errors.** Check **System Settings ▸ Privacy & Security ▸ Automation** and the relevant app (Notes, Calendar, etc.).

---

## 7. Why the allowlist matters (security)

**The list is where you give permission.** That's the whole design, and it's worth being explicit about it, because it's different from how most apps ask.

The point of this tool is to *remove* friction — to let you say "file that note" and have it happen. An app that stopped to ask every single time would defeat its own purpose, so this one doesn't. Instead, you make the decision **once, deliberately, in advance**, by putting a shortcut in your `.config`. Everything not on that list is refused outright, no questions asked.

`side_effect` is a second, optional checkpoint on top of that, for the few shortcuts where you want to be asked again at the moment it runs. It defaults to `true` — a shortcut you haven't thought about yet gets a prompt rather than silently running. But **it is entirely normal, and expected, for most of your shortcuts to end up marked `side_effect: false`** and to run without prompting. That's the tool working as intended, not a corner being cut. Reserve `true` for the genuinely consequential ones — sending something to another person, spending money, deleting things.

Because permission is front-loaded, the quality of your list is doing the real work. Three things worth weighing before adding an entry:

- **Assume it can run at any time, on input you didn't choose.** The assistant decides when to call a shortcut and what to pass it. A shortcut that takes a file path, a URL, or a recipient is more powerful than it looks, because it's the assistant filling those in.
- **A shortcut that *reads* untrusted content is a way in, not just a way out.** Whatever it returns — the body of a note, an email, a web page — lands in front of the assistant alongside your instructions. If someone else can influence that text, they get a voice in your assistant's context. Be as thoughtful allowlisting a reader as an editor.
- **Cancelling probably won't stop it.** Cancelling a run, or hitting the time limit, stops the small command that launched the shortcut; the Shortcuts app keeps running the shortcut itself. Expect anything already started to finish.

One thing to know about the `side_effect` prompt specifically: this app runs invisibly in the background and has no way to put a dialog on your screen, so it can't verify you were actually asked — it refuses the run unless the assistant states you approved. Against a well-behaved assistant that reliably prevents accidents, which is what it's for. It is not a lock against one that has been tricked. That's another reason the list, not the prompt, is the control that counts.

Automation always trades some safety for leverage. Keeping the list short, specific, and reviewed now and then is how you stay on the right side of that trade.

---

## 8. Checking what actually ran (the activity log)

The helper writes a line every time it runs a shortcut and every time it refuses one. This is how you find out after the fact what your assistant actually did — useful when something happened you didn't expect, and the only place that information exists.

Each line is a small chunk of JSON, one per event:

```json
{"confirm":true,"event":"run","job_id":"job_1a2b3c4d","shortcut":"TagNote","side_effect":true,"tool":"run_shortcut_async","ts":"2026-08-25T10:56:44Z"}
{"event":"refused","reason":"not_allowlisted","shortcut":"SomethingElse","tool":"run_shortcut","ts":"2026-08-25T10:57:02Z"}
```

What's worth looking for:

- **`"event":"run"` with `"side_effect":true` and `"confirm":true`** — a shortcut that changes something ran because the assistant said you approved it. If you don't remember being asked, that's worth knowing.
- **`"reason":"needs_confirmation"` followed moments later by a `run` of the same shortcut with `"confirm":true`** — the app asked for approval and the assistant answered it. Whether *you* were asked in between is the interesting question.
- **Repeated `"reason":"not_allowlisted"`** — something is trying shortcut names that aren't on your list.

**Where it goes.** The helper writes these to its *error output*, and the app you connect it to decides what becomes of that. In **Claude Desktop** they're saved under `~/Library/Logs/Claude/`, in a file named after whatever you called the server in your config (the `run-shortcuts` example in §2 gives `mcp-server-run-shortcuts.log`). Other MCP apps put their logs elsewhere — and it's worth knowing that **an app which discards its servers' error output leaves you with no record at all.** If this log matters to you, check where your app keeps it before relying on it.

**What's never written.** The *input* sent to a shortcut is deliberately left out — it can contain personal content (note text, message bodies, file paths), and what matters for review is which shortcuts ran, not what was passed to them. The log also doesn't record what a shortcut *returned*.
