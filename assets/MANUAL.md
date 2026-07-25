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

> **Logs, if something's off:** `~/Library/Logs/Claude/mcp-server-run-shortcuts.log` shows anything the helper printed — most often a wrong path to the config file.

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

The default install **includes a ready-to-use shortcut called `TagNote`** — it's the one the example config refers to, and it appends a tag to an Apple Note.

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
      "description": "Append a tag to an Apple Note.",
      "input": "json",
      "schema": {
        "tag": "the tag name (no # symbol)",
        "note": "the exact title of the note"
      },
      "side_effect": true
    },
    "BatteryLevel": {
      "description": "Report the current battery percentage.",
      "input": "none",
      "side_effect": false
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
| `side_effect` | true/false | `true` if the shortcut **changes something** (sends a message, toggles a light, edits a note). When `true`, the assistant must get your explicit OK before running it. Use `false` only for read-only "just tell me something" shortcuts. **If omitted, it defaults to `true`** (confirmation required). |

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

---

## 6. Troubleshooting

- **Claude doesn't see the tool.** Fully quit and reopen Claude Desktop. Double-check the `command` path points at `…/RunShortcutsMCP.app/Contents/MacOS/RunShortcutsMCP`. Check the log at `~/Library/Logs/Claude/mcp-server-run-shortcuts.log`.
- **"… is not on the allowlist."** The shortcut name isn't in your `.config`, or the spelling doesn't match. Add/fix it, then restart Claude.
- **It runs but hangs / times out.** The shortcut almost certainly isn't headless (§5) — it's waiting for a person. Remove the interactive action.
- **A "tell me…" shortcut returns nothing.** It's missing a **Stop and Output** / final **Text** action (§4.3).
- **Permission errors.** Check **System Settings ▸ Privacy & Security ▸ Automation** and the relevant app (Notes, Calendar, etc.).

---

## 7. Why the allowlist matters (security)

Apple Shortcuts can do powerful things — send messages, control your home, move files. This app deliberately runs **only** what you list, and requires your confirmation for anything marked `side_effect`. Keep your `.config` small and intentional: add a shortcut only when you're comfortable with the assistant being able to run it.
