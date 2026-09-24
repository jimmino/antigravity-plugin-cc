#!/usr/bin/env python3
"""Test gate: run tests/run-tests.sh at the end of every Claude Code turn
that changed the code the suite exercises.

Wired up in .claude/settings.json:

  turn-start  UserPromptSubmit hook. Records a fingerprint of the tested
              sources, so the Stop hook can tell whether the turn changed them.
  stop        Stop hook. If the turn changed the tested sources, runs the
              suite and blocks the stop while it fails, so Claude fixes the
              failures before it finishes.
  run         Entry point for people and for the test-runner agent: runs the
              suite and prints a summary. `run <filter>` runs matching tests
              only. Exit 0 = pass, 1 = fail, 2 = could not run.

On native Windows the suite runs through WSL (about 40 s, against about
7 minutes under Git Bash); elsewhere it runs with the local bash. State lives
in the git dir (.git/agy-test-gate), so it is never committed.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Everything tests/run-tests.sh reads. Changes anywhere else cannot change
# its result, so they do not trigger a run.
WATCHED = ("plugins/agy/scripts", "tests")

SUITE_TIMEOUT = 240           # seconds; a normal WSL run takes about 40
MAX_BLOCKS = 3                # automatic fix rounds per user prompt
EXCERPT_LINES = 60            # failure lines handed back to Claude
STALE_AFTER = 7 * 24 * 3600   # per-session state older than this is pruned

ANSI = re.compile(r"\x1b\[[0-9;]*m")
SUMMARY = re.compile(r"^(?:PASS|FAIL)\s+\d+ passed.*$", re.MULTILINE)


# ---------------------------------------------------------------- helpers --

def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True,
                          check=True).stdout


def state_dir():
    path = Path(git("rev-parse", "--git-path", "agy-test-gate").decode().strip())
    if not path.is_absolute():
        path = ROOT / path
    path.mkdir(parents=True, exist_ok=True)
    return path


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def write_atomic(path, text):
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def fingerprint():
    """Hash of every tracked or untracked (not ignored) file the suite reads."""
    listed = git("ls-files", "-z", "--cached", "--others", "--exclude-standard",
                 "--", *WATCHED)
    digest = hashlib.sha256()
    for rel in sorted(set(listed.split(b"\0")) - {b""}):
        digest.update(rel + b"\0")
        try:
            digest.update(hashlib.sha256((ROOT / rel.decode()).read_bytes()).digest())
        except OSError:  # tracked, but deleted from the working tree
            digest.update(b"<missing>")
    return digest.hexdigest()


def session_key(payload):
    sid = re.sub(r"[^A-Za-z0-9_-]", "", str(payload.get("session_id") or ""))
    return sid[:64] or "default"


def one_line(text):
    return " ".join(text.split())


def has_suite():
    return (ROOT / "tests" / "run-tests.sh").is_file()


# ------------------------------------------------------------------ suite --

def suite_command(extra):
    if os.name == "nt":
        wsl = shutil.which("wsl.exe") or shutil.which("wsl")
        if not wsl:
            return None, None
        return [wsl, "--cd", str(ROOT), "--", "bash", "tests/run-tests.sh", *extra], "WSL"
    return ["bash", "tests/run-tests.sh", *extra], "bash"


def failure_excerpt(text):
    """The FAIL lines of the suite and the assertion messages under them."""
    lines, keep = [], False
    for line in text.splitlines():
        if line.startswith("  FAIL "):
            keep = True
            lines.append(line.rstrip())
        elif keep and line.startswith("     "):
            lines.append(line.rstrip())
        else:
            keep = False
    if not lines:  # the harness died before reporting a test: show its tail
        lines = [line.rstrip() for line in text.splitlines()[-30:]]
    if len(lines) > EXCERPT_LINES:
        extra = len(lines) - EXCERPT_LINES
        lines = lines[:EXCERPT_LINES] + [f"  ... {extra} more lines in the full log"]
    return "\n".join(lines)


def run_suite(extra=()):
    cmd, where = suite_command(list(extra))
    if cmd is None:
        return {"status": "skipped", "note": (
            "WSL is not available, and under Git Bash the suite takes about "
            "7 minutes, so it was not run. CI still runs it on every PR.")}
    started = time.monotonic()
    try:
        proc = subprocess.run(cmd, cwd=ROOT, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=SUITE_TIMEOUT)
        raw, code = proc.stdout, proc.returncode
    except subprocess.TimeoutExpired as exc:
        raw, code = exc.output or b"", None
    except OSError as exc:
        return {"status": "skipped", "note": f"could not start the suite: {exc}"}
    text = ANSI.sub("", raw.replace(b"\0", b"").decode("utf-8", "replace"))
    found = SUMMARY.findall(text)
    summary = one_line(found[-1]) if found else ""
    if code is None:
        status, summary = "fail", f"timed out after {SUITE_TIMEOUT} s"
    elif code == 0 and summary.startswith("PASS"):
        status = "pass"
    elif not found and b"\0" in raw:
        # wsl.exe prints its own errors in UTF-16: the suite never started.
        return {"status": "skipped", "note": "WSL failed: " + one_line(text)[:300]}
    else:
        status = "fail"
        summary = summary or f"the suite exited with code {code} before its summary"
    return {"status": status, "summary": summary, "where": where,
            "elapsed": round(time.monotonic() - started),
            "excerpt": failure_excerpt(text) if status == "fail" else "",
            "log": text}


def record(sd, fp, result):
    write_atomic(sd / "last-run.log", result["log"])
    state = {key: result[key] for key in ("status", "summary", "where", "elapsed", "excerpt")}
    state["fp"] = fp
    write_atomic(sd / "last.json", json.dumps(state))


def label(result):
    return f"{result['summary']} ({result['where']}, {result['elapsed']} s)"


# ------------------------------------------------------------------ modes --

def on_turn_start(payload):
    sd = state_dir()
    sid = session_key(payload)
    write_atomic(sd / f"turn-{sid}", fingerprint())
    (sd / f"blocks-{sid}").unlink(missing_ok=True)
    cutoff = time.time() - STALE_AFTER
    for path in sd.iterdir():
        if path.name.startswith(("turn-", "blocks-")) and path.stat().st_mtime < cutoff:
            path.unlink(missing_ok=True)


def on_stop(payload):
    if not has_suite():
        return None
    sd = state_dir()
    sid = session_key(payload)
    fp = fingerprint()
    try:
        if (sd / f"turn-{sid}").read_text(encoding="utf-8") == fp:
            return None  # this turn left the tested sources alone
    except OSError:
        pass  # no turn-start record (hook added mid-session): use the last run
    last = read_json(sd / "last.json")
    if last and last.get("fp") == fp:
        if last.get("status") == "pass":
            return None  # this exact tree already passed
        result = last
    else:
        result = run_suite()
        if result["status"] == "skipped":
            return {"systemMessage": "agy tests not run: " + result["note"]}
        record(sd, fp, result)

    blocks_file = sd / f"blocks-{sid}"
    if result["status"] == "pass":
        blocks_file.unlink(missing_ok=True)
        return {"systemMessage": "agy tests: " + label(result)}

    log = sd / "last-run.log"
    blocks = read_json(blocks_file) or {"count": 0, "seen": []}
    if fp in blocks["seen"]:
        return {"systemMessage": (
            f"agy tests still failing: {label(result)}. Claude stopped "
            f"without changing the tested files. Log: {log}")}
    if blocks["count"] >= MAX_BLOCKS:
        return {"systemMessage": (
            f"agy tests still failing after {MAX_BLOCKS} automatic fix "
            f"rounds: {label(result)}. Log: {log}")}
    blocks["count"] += 1
    blocks["seen"].append(fp)
    write_atomic(blocks_file, json.dumps(blocks))
    return {"decision": "block", "reason": (
        f"The agy test suite fails after this turn's changes to "
        f"{' or '.join(WATCHED)}: {label(result)}.\n"
        "Fix the failures before you finish. If they come from changes you "
        "did not make, say so and stop instead of editing unrelated code.\n\n"
        f"{result['excerpt']}\n\n"
        f"Full log: {log}\n"
        "Re-run: python3 .claude/hooks/test-gate.py run [name-filter]")}


def on_run(args):
    if not has_suite():
        print(f"tests/run-tests.sh not found under {ROOT}")
        return 2
    sd = state_dir()
    fp = fingerprint()
    result = run_suite(args)
    if result["status"] == "skipped":
        print(result["note"])
        return 2
    if args:  # a filtered run says nothing about the whole tree
        log = sd / "filtered-run.log"
        write_atomic(log, result["log"])
    else:
        record(sd, fp, result)
        log = sd / "last-run.log"
    print(label(result))
    if result["status"] == "pass":
        return 0
    print()
    print(result["excerpt"])
    print()
    print(f"Full log: {log}")
    return 1


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    mode = sys.argv[1] if len(sys.argv) > 1 else "run"
    if mode == "run":
        return on_run(sys.argv[2:])
    if mode not in ("turn-start", "stop"):
        print(f"usage: {Path(__file__).name} [run [filter] | turn-start | stop]",
              file=sys.stderr)
        return 2
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace") or "{}")
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    try:
        if mode == "turn-start":
            on_turn_start(payload)
        else:
            out = on_stop(payload)
            if out:
                sys.stdout.write(json.dumps(out))
    except Exception as exc:  # a broken gate must never wedge the session
        if mode == "stop":
            sys.stdout.write(json.dumps({"systemMessage": f"agy test gate error: {exc!r}"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
