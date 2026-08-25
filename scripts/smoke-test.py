#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
#  smoke-test.py
#  RunShortcutsMCP
#
#  Protocol-level smoke test: drives a *built* RunShortcutsMCP binary over the
#  real MCP stdio JSON-RPC transport and asserts on what a client actually
#  receives back.
#
#  WHY THIS EXISTS (read before deleting it)
#  -----------------------------------------
#  The Swift unit tests in Tests/ cover RunShortcutsCore thoroughly, but they
#  cannot reach the MCP wire layer at all: tool declarations, argument decoding,
#  and the JSON payload shapes all live in Sources/RunShortcutsMCP/main.swift,
#  which is top-level executable code with no test target. Bugs in that layer are
#  invisible to `swift test`.
#
#  That is not hypothetical. During 1.2.0 development, `get_shortcut_result`
#  silently ignored its `wait_seconds` argument whenever a client sent a bare
#  integer (20) rather than a decimal (20.0) -- the MCP SDK's `Value.doubleValue`
#  only matches its `.double` case and returns nil for `.int`, so the argument
#  was dropped and the default 45s wait was used instead. Every real MCP client
#  sends whole numbers as bare integers, so this affected every caller. All 56
#  unit tests passed. Only driving the real binary caught it.
#
#  So: this script exists to cover the argument-decoding and wire-format seam
#  that unit tests structurally cannot. Add a case here whenever you add or
#  change a tool's arguments or response shape.
#
#  USAGE
#  -----
#      ./scripts/build-app.sh release          # build first -- this tests the binary
#      python3 scripts/smoke-test.py
#
#      # Full coverage, including the wait_seconds timing checks, needs a
#      # shortcut that runs longer than ~30s so a job is observably still
#      # running when polled. Any allowlisted, side-effect-free shortcut works:
#      python3 scripts/smoke-test.py --slow-shortcut "GetReminderLayout" \
#                                    --slow-input '{"all": true}'
#
#  Without --slow-shortcut the timing checks are SKIPPED (and say so loudly);
#  everything else still runs. Exit code is 0 only if every executed check passed.
#
#  The default checks never run a real shortcut: they use a deliberately
#  nonexistent name, so `shortcuts run` fails fast with no side effects.
#

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time

DEFAULT_BIN = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "build", "RunShortcutsMCP.app", "Contents", "MacOS", "RunShortcutsMCP",
)

# A name that must not exist in anyone's Shortcuts library. `shortcuts run` fails
# fast on it, which exercises the whole job pipeline with zero side effects.
MISSING_SHORTCUT = "RunShortcutsMCP-SmokeTest-DoesNotExist"

failures = []
skipped = []


def check(label, condition, detail=""):
    """Records one assertion's outcome and prints it.

    Args:
        label (str): Human-readable name of what is being checked.
        condition (bool): Whether the check passed.
        detail (str): Extra context appended to the output line.

    Returns:
        bool: `condition`, so callers can branch on it.
    """
    if condition:
        print(f"  ok   {label}{(' -- ' + detail) if detail else ''}")
    else:
        print(f"  FAIL {label}{(' -- ' + detail) if detail else ''}")
        failures.append(label)
    return condition


def skip(label, why):
    """Records a check that was deliberately not run.

    Args:
        label (str): Name of the skipped check.
        why (str): Why it was skipped.
    """
    print(f"  skip {label} -- {why}")
    skipped.append(label)


class Server:
    """A running RunShortcutsMCP subprocess speaking MCP over stdio.

    Args:
        binary (str): Path to the RunShortcutsMCP executable.
        allowlist (dict): The allowlist JSON to run the server with.
    """

    def __init__(self, binary, allowlist):
        self._config = tempfile.NamedTemporaryFile(mode="w", suffix=".config", delete=False)
        json.dump(allowlist, self._config)
        self._config.close()
        self._next_id = 0
        self.proc = subprocess.Popen(
            [binary, "--allowlist", self._config.name],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1,
        )

    def request(self, method, params=None):
        """Sends a JSON-RPC request and returns the decoded response.

        Args:
            method (str): JSON-RPC method name.
            params (dict | None): Method parameters, omitted when None.

        Returns:
            dict: The decoded JSON-RPC response object.

        Raises:
            SystemExit: If the server produced no response (its stderr is printed).
        """
        self._next_id += 1
        message = {"jsonrpc": "2.0", "id": self._next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            print("!! server produced no response; stderr follows:", file=sys.stderr)
            print(self.proc.stderr.read(), file=sys.stderr)
            sys.exit(1)
        return json.loads(line)

    def notify(self, method, params=None):
        """Sends a JSON-RPC notification (no response expected).

        Args:
            method (str): JSON-RPC method name.
            params (dict | None): Method parameters, omitted when None.
        """
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def call_tool(self, name, arguments):
        """Calls one MCP tool.

        Args:
            name (str): Tool name.
            arguments (dict): Tool arguments.

        Returns:
            tuple[dict | str, bool]: The parsed JSON body (or raw text when the
            payload is a plain refusal string), and the response's isError flag.
        """
        response = self.request("tools/call", {"name": name, "arguments": arguments})
        result = response["result"]
        text = result["content"][0]["text"]
        try:
            return json.loads(text), result["isError"]
        except json.JSONDecodeError:
            return text, result["isError"]

    def handshake(self):
        """Performs the MCP initialize handshake.

        Returns:
            dict: The full initialize result, including serverInfo and any
            server-level `instructions`.
        """
        response = self.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "smoke-test", "version": "1.0"},
        })
        self.notify("notifications/initialized")
        return response["result"]

    def close(self, expect_clean_exit=False):
        """Shuts the server down and cleans up its temporary allowlist.

        Args:
            expect_clean_exit (bool): When True, asserts the process exits
                promptly on SIGTERM (it installs its own handler, so a
                regression there would hang instead of exiting).
        """
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                code = self.proc.wait(timeout=8)
                if expect_clean_exit:
                    check("SIGTERM exits cleanly", code == 0, f"returncode={code}")
            except subprocess.TimeoutExpired:
                if expect_clean_exit:
                    check("SIGTERM exits cleanly", False, "still alive after 8s -- signal ignored?")
                self.proc.kill()
                self.proc.wait()
        os.unlink(self._config.name)


def run_tool_surface_checks(server):
    """Checks the advertised tool list and its annotations.

    Args:
        server (Server): A server that has completed its handshake.
    """
    print("\n[tool surface]")
    tools = {t["name"]: t for t in server.request("tools/list")["result"]["tools"]}
    expected = {
        "list_shortcuts", "run_shortcut", "run_shortcut_async",
        "get_shortcut_result", "cancel_shortcut_job", "list_shortcut_jobs",
    }
    check("all six tools advertised", expected <= tools.keys(),
          f"missing: {sorted(expected - tools.keys()) or 'none'}")
    for name in ("list_shortcuts", "get_shortcut_result", "list_shortcut_jobs"):
        if name in tools:
            check(f"{name} is readOnlyHint",
                  tools[name].get("annotations", {}).get("readOnlyHint") is True)
    for name in ("run_shortcut", "run_shortcut_async", "cancel_shortcut_job"):
        if name in tools:
            check(f"{name} is destructiveHint",
                  tools[name].get("annotations", {}).get("destructiveHint") is True)


def run_job_lifecycle_checks(server):
    """Runs a job against a nonexistent shortcut and checks the whole lifecycle.

    Uses a name that cannot exist, so the underlying `shortcuts run` fails fast
    and nothing on the machine is touched.

    Args:
        server (Server): A server that has completed its handshake.
    """
    print("\n[async job lifecycle]")
    body, is_error = server.call_tool("run_shortcut_async", {"name": MISSING_SHORTCUT})
    check("run_shortcut_async accepted", is_error is False, str(body)[:80])
    if not isinstance(body, dict) or "job_id" not in body:
        check("run_shortcut_async returned a job_id", False, str(body)[:120])
        return
    job_id = body["job_id"]
    check("job_id is well formed", job_id.startswith("job_") and len(job_id) == 12, job_id)
    check("submission reports queued", body.get("state") == "queued")
    check("submission omits output keys", "stdout" not in body and "exit_code" not in body)

    status = None
    for _ in range(20):
        status, is_error = server.call_tool(
            "get_shortcut_result", {"job_id": job_id, "wait_seconds": 2}
        )
        if status.get("state") not in ("queued", "running"):
            break
        time.sleep(0.2)
    check("job reached failed (shortcut does not exist)", status.get("state") == "failed", str(status.get("state")))
    check("terminal result carries exit_code", "exit_code" in status)
    check("terminal result carries timed_out", "timed_out" in status)
    check("failed job sets isError", is_error is True)

    listing, _ = server.call_tool("list_shortcut_jobs", {})
    check("job appears in listing", any(j["job_id"] == job_id for j in listing))
    check("listing never leaks output",
          all("stdout" not in j and "stderr" not in j for j in listing))

    cancelled, _ = server.call_tool("cancel_shortcut_job", {"job_id": job_id})
    check("cancel on terminal job is a no-op", cancelled.get("state") == "failed",
          str(cancelled.get("state")))

    unknown, is_error = server.call_tool("get_shortcut_result", {"job_id": "job_deadbeef"})
    check("unknown job id refused", is_error is True and "Unknown job id" in str(unknown))


def run_instructions_checks(init_result):
    """Checks the server-level `instructions` returned at initialize.

    This is the LLM-facing manual: cross-tool guidance a client may inject into
    the model's context. Client support is uneven, so nothing here may be the
    only place a rule is stated -- but the field must be present and must carry
    the rules that span tools.

    Args:
        init_result (dict): The full initialize result from the handshake.
    """
    print("\n[server instructions]")
    text = init_result.get("instructions") or ""
    if not check("instructions present in initialize result", bool(text.strip()),
                 f"{len(text)} chars"):
        return
    lowered = text.lower()
    check("tells the model to discover via list_shortcuts", "list_shortcuts" in lowered)
    check("steers toward the async path", "run_shortcut_async" in lowered)
    check("explains queued/running is not an error",
          "queued" in lowered and "running" in lowered)
    check("states the consent rule", "confirm=true" in lowered and "approval" in lowered)
    check("forbids self-authorizing a side-effecting run",
          "never set confirm=true" in lowered)
    check("explains expired job ids", "expired" in lowered)


def run_sync_and_gate_checks(server):
    """Checks the synchronous run path and the allowlist/side-effect gate.

    Args:
        server (Server): A server that has completed its handshake.
    """
    print("\n[sync path and gating]")
    body, _ = server.call_tool("run_shortcut", {"name": MISSING_SHORTCUT})
    check("run_shortcut returns the full payload",
          all(k in body for k in ("exit_code", "stdout", "stderr", "timed_out")),
          str(sorted(body.keys())) if isinstance(body, dict) else str(body)[:80])

    refusal, is_error = server.call_tool("run_shortcut", {"name": "NotOnTheAllowlist"})
    check("non-allowlisted name refused", is_error is True and "not on the allowlist" in str(refusal))

    refusal, is_error = server.call_tool("run_shortcut_async", {"name": "NotOnTheAllowlist"})
    check("non-allowlisted name refused (async)",
          is_error is True and "not on the allowlist" in str(refusal))

    refusal, is_error = server.call_tool("run_shortcut_async", {"name": "SideEffecting"})
    check("side_effect requires confirm", is_error is True and "confirm=true" in str(refusal))
    check("side_effect refusal names the async tool", "run_shortcut_async" in str(refusal),
          "refusal must tell the model which tool to re-call")
    check("side_effect refusal directs the model to the user",
          "confirmation" in str(refusal).lower(),
          "the refusal must say to ask the user, not just to set the flag")


def run_wait_seconds_checks(server, slow_name, slow_input):
    """Checks that `wait_seconds` is actually honored, in both JSON number forms.

    This is the regression guard for the bug described in this file's header: a
    bare integer decodes as MCP `.int`, not `.double`, and was silently dropped.
    The only way to observe it is timing, which needs a job that is genuinely
    still running when polled -- hence the slow shortcut.

    Args:
        server (Server): A server that has completed its handshake.
        slow_name (str): Name of an allowlisted shortcut that runs >30s.
        slow_input (str | None): Optional stdin payload for that shortcut.
    """
    print("\n[wait_seconds honored -- the regression this script exists for]")
    arguments = {"name": slow_name}
    if slow_input:
        arguments["input"] = slow_input
    body, is_error = server.call_tool("run_shortcut_async", arguments)
    if is_error or "job_id" not in body:
        check("slow shortcut submitted", False, str(body)[:160])
        return
    job_id = body["job_id"]

    # Bare integer -- the exact form that regressed.
    start = time.monotonic()
    status, _ = server.call_tool("get_shortcut_result", {"job_id": job_id, "wait_seconds": 3})
    elapsed = time.monotonic() - start
    if status.get("state") not in ("queued", "running"):
        check("slow shortcut still running when polled", False,
              f"finished too fast (state={status.get('state')}); pick a slower shortcut")
        return
    check("wait_seconds=3 (bare int) is honored", 2.0 <= elapsed <= 6.0,
          f"returned after {elapsed:.1f}s (a dropped argument would wait ~45s)")

    # Decimal form -- always worked, checked so the two stay consistent.
    start = time.monotonic()
    server.call_tool("get_shortcut_result", {"job_id": job_id, "wait_seconds": 3.0})
    elapsed = time.monotonic() - start
    check("wait_seconds=3.0 (decimal) is honored", 2.0 <= elapsed <= 6.0, f"returned after {elapsed:.1f}s")

    # Zero must return immediately rather than falling back to the default.
    start = time.monotonic()
    server.call_tool("get_shortcut_result", {"job_id": job_id, "wait_seconds": 0})
    elapsed = time.monotonic() - start
    check("wait_seconds=0 returns immediately", elapsed < 2.0, f"returned after {elapsed:.1f}s")

    # A running job is a handoff, not an error.
    status, is_error = server.call_tool("get_shortcut_result", {"job_id": job_id, "wait_seconds": 0})
    check("running job is not an error", is_error is False, f"state={status.get('state')}")
    check("running job omits output keys", "stdout" not in status and "exit_code" not in status)
    check("running job reports elapsed_seconds", "elapsed_seconds" in status)

    cancelled, _ = server.call_tool("cancel_shortcut_job", {"job_id": job_id})
    check("running job can be cancelled", cancelled.get("state") in ("cancelled", "running"),
          str(cancelled.get("state")))


def main():
    """Runs the smoke test suite and exits non-zero if any check failed.

    Returns:
        int: Process exit status -- 0 when every executed check passed.
    """
    parser = argparse.ArgumentParser(description="Protocol-level smoke test for a built RunShortcutsMCP binary.")
    parser.add_argument("--binary", default=DEFAULT_BIN, help="Path to the built RunShortcutsMCP executable.")
    parser.add_argument("--slow-shortcut", default=None,
                        help="An allowlisted shortcut running >30s, enabling the wait_seconds timing checks.")
    parser.add_argument("--slow-input", default=None, help="Optional stdin payload for --slow-shortcut.")
    args = parser.parse_args()

    if not os.path.exists(args.binary):
        print(f"!! binary not found: {args.binary}\n   Build it first: ./scripts/build-app.sh release", file=sys.stderr)
        return 1

    allowlist = {
        "shortcuts": {
            MISSING_SHORTCUT: {"description": "Intentionally absent; used to exercise the failure path.",
                               "side_effect": False},
            "SideEffecting": {"description": "Never run; only used to check the confirm gate.",
                              "side_effect": True},
        }
    }
    if args.slow_shortcut:
        allowlist["shortcuts"][args.slow_shortcut] = {
            "description": "Long-running shortcut for the wait_seconds timing checks.",
            "side_effect": False,
            "timeout_seconds": 300,
        }

    server = Server(args.binary, allowlist)
    try:
        init_result = server.handshake()
        info = init_result["serverInfo"]
        print(f"[handshake]\n  ok   connected to {info['name']} {info['version']}")
        run_instructions_checks(init_result)
        run_tool_surface_checks(server)
        run_job_lifecycle_checks(server)
        run_sync_and_gate_checks(server)
        if args.slow_shortcut:
            run_wait_seconds_checks(server, args.slow_shortcut, args.slow_input)
        else:
            print("\n[wait_seconds honored -- the regression this script exists for]")
            skip("wait_seconds timing checks",
                 "no --slow-shortcut given; pass one that runs >30s for full coverage")
    finally:
        print("\n[shutdown]")
        server.close(expect_clean_exit=True)

    print()
    if failures:
        print(f"FAILED -- {len(failures)} check(s): {', '.join(failures)}")
        return 1
    if skipped:
        print(f"PASSED (with {len(skipped)} skipped -- see --slow-shortcut for full coverage)")
        return 0
    print("PASSED -- all checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
