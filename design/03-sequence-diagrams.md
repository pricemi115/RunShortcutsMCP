<!-- SPDX-License-Identifier: Apache-2.0 -->
# 3. Sequence Diagrams

Every externally-visible flow, traced end to end. Participants are consistent
across diagrams:

| Participant | What it is |
|-------------|------------|
| `Client` | The MCP client process (Claude Desktop / Claude Code) |
| `Main` | `Sources/RunShortcutsMCP/main.swift` — handlers, gate, audit |
| `Allowlist` | The immutable policy loaded at startup |
| `Store` | `JobStore` actor |
| `Runner` | `ShortcutsRunner` (a fresh, limit-configured value per job) |
| `shortcuts` | The `/usr/bin/shortcuts` child process |
| `stderr` | The audit/server log the client captures |

## 3.1 Startup

```mermaid
sequenceDiagram
    autonumber
    participant Client
    participant Main
    participant Provisioner as ConfigProvisioner
    participant Locator as AllowlistLocator
    participant FS as Filesystem
    participant stderr

    Client->>Main: spawn (stdio pipes attached)
    Main->>Main: signal(SIGPIPE, SIG_IGN)
    Main->>Provisioner: applicationSupportDirectory(bundleID)
    Provisioner-->>Main: ~/Library/Application Support/dev.grumptech.runshortcutsmcp/
    Main->>Provisioner: provision(into:configFileName:defaultContents:assets:)
    Provisioner->>FS: createDirectory(0700)
    alt config absent
        Provisioner->>FS: open(O_CREAT|O_EXCL|O_NOFOLLOW, 0600) + write empty allowlist
    else config present
        Provisioner-->>Provisioner: leave the user's config untouched
    end
    Provisioner->>FS: refresh MANUAL.html, .config.example, 11 × .shortcut
    Note over Main,Provisioner: Best-effort — any failure here must not stop startup

    Main->>Locator: resolve(arguments, environment, discoveredConfig)
    Locator-->>Main: path or nil
    alt nil
        Main->>stderr: "no allowlist configured…"
        Main-->>Client: exit(1) — fail closed
    end
    Main->>FS: Allowlist.load(from: path)
    alt decode fails or a name is empty / starts with "-"
        Main->>stderr: "could not load allowlist…"
        Main-->>Client: exit(1)
    end
    Main->>stderr: one line per out-of-range limit (clamping warning)
    Main->>Main: construct ShortcutsRunner + JobStore(execute:)
    Main->>Main: register ListTools + CallTool handlers
    Main->>Main: trap SIGTERM / SIGINT
    Main->>Client: server.start(StdioTransport)
    Note over Main: sleep loop keeps the process alive — the client owns its lifecycle
```

## 3.2 `list_shortcuts`

The only tool that touches the machine without running anything the user
allowlisted — `shortcuts list` is invoked purely to compute the `installed` flag.

```mermaid
sequenceDiagram
    autonumber
    participant Client
    participant Main
    participant Runner
    participant shortcuts
    participant Allowlist

    Client->>Main: tools/call list_shortcuts {}
    Main->>Runner: list()
    Runner->>shortcuts: exec /usr/bin/shortcuts list
    shortcuts-->>Runner: names on stdout
    Runner-->>Main: [String]
    Note over Main: `(try? await runner.list()) ?? []` — a failure here degrades<br/>to "nothing installed", it never fails the call
    Main->>Allowlist: describe(installed:)
    Allowlist-->>Main: JSON array of ShortcutDescription, sorted by name
    Main-->>Client: text content, isError = false
```

Each element carries `name`, `description`, `input`, `schema`, `side_effect`,
`installed`, and `config_warning` when a configured limit was out of range.

## 3.3 `run_shortcut` — the synchronous path

Since 1.2.0 this path **also goes through the job store**, so it shares the
concurrency cap, the backlog limit, the watchdog, cancellation, and visibility in
`list_shortcut_jobs`. The response payload is unchanged from the direct-execution
version it replaced.

```mermaid
sequenceDiagram
    autonumber
    participant Client
    participant Main
    participant Allowlist
    participant Store as JobStore
    participant Runner
    participant shortcuts
    participant stderr

    Client->>Main: tools/call run_shortcut {name, input?, confirm?}
    Main->>Allowlist: gate(name:confirmed:)
    alt name missing / not allowlisted / needs confirmation
        Main->>stderr: AuditEvent.refused(reason)
        Main-->>Client: refusal text, isError = true
    end
    Allowlist-->>Main: (name, entry)
    Main->>Allowlist: timeout(for: name) → clamped to 5...300
    Main->>Store: submit(shortcutName, input, timeoutOverride: syncTimeout)
    alt 16 jobs already queued or running
        Store-->>Main: throw JobStoreError.queueFull(16)
        Main->>stderr: AuditEvent.refused("queue_full")
        Main-->>Client: "Refused: 16 shortcut jobs are already queued…", isError = true
    end
    Store-->>Main: Job(state: queued)
    Main->>stderr: AuditEvent.run(tool, shortcut, jobID, confirm, sideEffect)

    Store->>Store: acquireSlot() — up to 4 concurrent
    Store->>Runner: execute(name, input, syncTimeout)
    Runner->>shortcuts: exec /usr/bin/shortcuts run NAME (argv, no shell)
    Runner->>shortcuts: write input to stdin, close
    shortcuts-->>Runner: stdout / stderr / exit status
    Runner-->>Store: ShortcutResult
    Store->>Store: finalize → succeeded | failed | timed_out | cancelled

    Main->>Store: wait(for: jobID, timeout: syncTimeout)
    alt terminal with a captured result
        Store-->>Main: Job(result:)
    else terminal with no result (could not launch)
        Main-->>Client: "Failed to run 'NAME'. See the server log for details." (CWE-209)
    else still queued or running at the deadline
        Main->>Store: cancel(id:)
        Note over Main: synthesises a timed-out ShortcutResult whose stderr says the<br/>shortcut may never have started — so retrying is safe even for a<br/>side-effecting one
    end
    Main->>Main: append any per-entry "[config]" limit warnings to stderr text
    Main-->>Client: RunOutput JSON {exit_code, stdout, stderr, timed_out},<br/>isError = (exit_code != 0)
```

### The queued-timeout case, stated plainly

If four shortcuts are already running, a fifth `run_shortcut` waits its turn. If
its own timeout elapses while it is *still queued*, the client gets a
timeout-shaped result for a shortcut that **never executed**. The stderr note
says so explicitly, because the correct action differs from a real timeout:
retrying is safe, including for a shortcut that changes something.

## 3.4 `run_shortcut_async` + `get_shortcut_result` — the recommended path

```mermaid
sequenceDiagram
    autonumber
    participant Client
    participant Main
    participant Store as JobStore
    participant Runner
    participant shortcuts
    participant stderr

    Client->>Main: tools/call run_shortcut_async {name, input?, confirm?}
    Main->>Main: gate(name:confirmed:)
    Main->>Store: submit(shortcutName, input) — no timeoutOverride
    Store-->>Main: Job(id: "job_1a2b3c4d", state: queued)
    Main->>stderr: AuditEvent.run(...)
    Main-->>Client: JobSubmission {job_id, shortcut, state, submitted_at}
    Note over Client,Main: returns immediately — no duration limit on this path

    par background
        Store->>Store: acquireSlot()
        Store->>Runner: execute(name, input, nil)
        Note over Runner: timeout = allowlist.asyncTimeout(name), clamped 5...3600
        Runner->>shortcuts: exec + drain + enforce timeout
        shortcuts-->>Runner: result
        Runner-->>Store: ShortcutResult
        Store->>Store: finalize()
        Store->>Store: releaseSlot() → hand directly to oldest waiter
    and polling
        Client->>Main: get_shortcut_result {job_id, wait_seconds?}
        Main->>Main: numberValue() accepts 20 and 20.0 alike
        Main->>Store: wait(for: id, timeout: min(max(w,0),50))
        loop until terminal, deadline, or caller cancellation
            Store->>Store: reap(), then poll every 200 ms
        end
        Store-->>Main: Job snapshot
        Main-->>Client: JobStatus JSON
    end
```

### What `get_shortcut_result` returns, by case

```mermaid
flowchart TD
    A["get_shortcut_result(job_id)"] --> B{"job_id present<br/>and non-empty?"}
    B -->|no| B1["'Missing required job_id.'<br/>isError = true"]
    B -->|yes| C["JobStore.wait(for:timeout:)"]
    C -->|"job found"| D{"state"}
    D -->|"queued / running"| D1["JobStatus with elapsed_seconds<br/><b>isError = false</b> — normal progress, poll again"]
    D -->|"succeeded"| D2["JobStatus with exit_code, stdout, stderr<br/>isError = false"]
    D -->|"failed / timed_out"| D3["JobStatus with exit_code, stdout, stderr<br/>isError = true"]
    D -->|"cancelled"| D4["JobStatus with stdout/stderr + message,<br/>no exit_code · isError = true"]
    C -->|"nil"| E{"tombstone exists?"}
    E -->|yes| E1["'…ran NAME and finished with state X, but its output is<br/>no longer retained. The shortcut DID run — do not run it<br/>again just to recover the result.'"]
    E -->|no| E2["'Unknown job id — no job with that id was started by<br/>this server. Check list_shortcut_jobs. Do not invent job ids.'"]
```

The tombstone branch is a security control, not a nicety. Telling an assistant
"unknown id" for a job that already ran reads as an invitation to run the
shortcut a second time — which, for a side-effecting shortcut that already
succeeded, means doing it twice.

## 3.5 Timeout and truncation inside one invocation

```mermaid
sequenceDiagram
    autonumber
    participant Runner as ShortcutsRunner.invoke
    participant PBox as ProcessBox
    participant Q as DispatchQueue (concurrent)
    participant Child as shortcuts
    participant Out as OutputCollector

    Runner->>Child: Process.run() with argv + 3 pipes
    Runner->>PBox: attach(process)
    alt cancellation raced ahead of attach
        PBox-->>Runner: false
        Runner->>Child: terminate() directly
    end
    Runner->>Q: async — write stdin, then close
    Runner->>Q: async — drain stdout until EOF
    Runner->>Q: async — drain stderr until EOF
    Note over Q,Out: both streams drained concurrently — a single-stream read<br/>would deadlock on a full pipe buffer (CWE-833)
    Out->>Out: append up to cap bytes, then set truncated (CWE-400)
    Runner->>Q: asyncAfter(+timeout) → SIGTERM work item
    Runner->>Q: asyncAfter(+timeout+2s) → SIGKILL work item

    alt child finishes in time
        Child-->>PBox: terminationHandler(status)
        Q->>Q: io.notify — cancel both work items
    else child overruns
        Q->>PBox: markTimedOut() then terminateIfRunning() → SIGTERM
        Q->>PBox: killIfRunning() → SIGKILL after 2s grace
        Child-->>PBox: terminationHandler(signal status)
    end
    Q->>Runner: resume continuation with ShortcutResult
    Note over Runner: stderr gains notes for truncation, timeout, or cancellation
```

Every signal goes through `ProcessBox.liveTarget()`, which requires both the
box's own bookkeeping and Foundation's `process.isRunning` to agree the child is
alive. Both work items are cancelled the moment the child actually exits, so a
slow-firing timer can never reach a recycled PID.

## 3.6 `cancel_shortcut_job`

```mermaid
sequenceDiagram
    autonumber
    participant Client
    participant Main
    participant Store as JobStore
    participant Task as job Task
    participant Runner
    participant Child as shortcuts

    Client->>Main: cancel_shortcut_job {job_id}
    Main->>Store: cancel(id:)
    alt unknown id
        Store-->>Main: nil
        Main-->>Client: "Unknown job id 'X'.", isError = true
    else state == queued
        Store->>Store: resume its waiter with false, cancel its Task
        Store->>Store: state = cancelled, finishedUptime = uptime()
        Note over Store: nothing ever ran — finalised immediately
    else state == running
        Store->>Task: Task.cancel()
        Note over Store: state stays `running` for now — deliberately
        Task->>Runner: cancellation observed
        Runner->>Child: ProcessBox.requestCancel() → terminate()
        Child-->>Runner: exits
        Runner-->>Store: ShortcutResult (partial output kept)
        Store->>Store: finalize() → cancelled (Task.isCancelled wins)
    else already terminal
        Store-->>Store: no-op
    end
    Store-->>Main: current Job snapshot
    Main-->>Client: JobStatus JSON, isError = false
```

**Why a running job is not marked cancelled immediately:** the state should
reflect the child process's real exit, not a projection of intent. Until
`invoke` returns, the shortcut may well still be doing work.

**What cancellation does *not* do:** it does not undo anything, and it does not
reliably stop the shortcut. A shortcut already under way is executed by the
Shortcuts app, not by this server, and will usually run to completion and apply
its changes. The tool description says this in as many words. Treat it as *stop
waiting for the result*.

## 3.7 `list_shortcut_jobs`

```mermaid
sequenceDiagram
    autonumber
    participant Client
    participant Main
    participant Store as JobStore

    Client->>Main: list_shortcut_jobs {}
    Main->>Store: allJobs()
    Store->>Store: reap() — watchdog, TTL, byte budget, count cap
    Store-->>Main: [Job] sorted by submittedUptime (oldest first)
    Main->>Main: jobListingJSONString([Job])
    Main-->>Client: JSON array of {job_id, shortcut, state, submitted_at, duration_seconds?}
```

Never includes `stdout`/`stderr`. Its purpose is recovering a lost `job_id`.

## 3.8 Graceful shutdown

```mermaid
sequenceDiagram
    autonumber
    participant Client
    participant OS
    participant Main
    participant Store as JobStore
    participant Child as shortcuts

    Client->>OS: terminate the server process
    OS->>Main: SIGTERM (or SIGINT)
    Note over Main: both are SIG_IGN'd, then handled via DispatchSource
    Main->>Store: cancelAll()
    loop every non-terminal job
        Store->>Store: cancel(id:)
        Store->>Child: terminate via ProcessBox
    end
    Main->>OS: exit(0)
```

Without this, a disconnecting client would leave in-flight shortcut subprocesses
running, reparented to `launchd` — a real consent problem for a side-effecting
shortcut. `SIGKILL` cannot be caught, so a force-quit can still orphan a child.

## 3.9 Backpressure: the queue-full path

```mermaid
flowchart TD
    A["submit()"] --> B["reap()"]
    B --> C["count jobs where !state.isTerminal"]
    C --> D{"pending &lt; maxPending (16)?"}
    D -->|no| E["throw JobStoreError.queueFull(16)"]
    E --> F["audit refused: queue_full"]
    F --> G["client sees: wait for some to finish,<br/>check list_shortcut_jobs"]
    D -->|yes| H["create Job(state: queued), spawn its Task"]
    H --> I{"runningCount &lt; maxConcurrent (4)?"}
    I -->|yes| J["take a slot → running"]
    I -->|no| K["append to waiters (FIFO), stay queued"]
```

Two separate limits doing two separate jobs: `maxConcurrent` (4) throttles how
much runs at once; `maxPending` (16) bounds the **backlog**, so no burst of
requests can enqueue an unbounded number of side-effecting runs that keep firing
four at a time long after anyone is watching.
