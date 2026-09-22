---
description: Get an independent second opinion from a fresh Claude Code running read-only in plan mode
argument-hint: "[--model opus|sonnet|haiku] [--effort L] [--dir <path>] <question>"
allowed-tools: Bash(bash:*), Read, Grep, Glob
---

For a genuine second opinion, use this rather than an `agy` model. It runs real
Claude Code headless with only `Read`, `Grep` and `Glob` in plan mode, so it can
*search* instead of brute-force reading — and unlike a Claude model selected
inside `agy`, it will not reach for a shell, get auto-denied, and hand back its
opening narration dressed up as an answer.

The user's question:

```
$ARGUMENTS
```

## How to invoke

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" second-opinion --dir <abs-path> "<question>"
```

Long context goes on **stdin** behind `--stdin`:

```
printf '%s' "<established facts, what you ruled out and how>" |
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" second-opinion --stdin --dir <abs-path> "<question>"
```

- `--model opus` (default) for reasoning, `sonnet` for speed, `haiku` for
  triage. `--effort low|medium|high|xhigh|max` (default `high`).
- `--timeout <seconds>` (default 540, under Claude Code's 600s tool kill). Set
  the Bash tool timeout to 600000 ms. A longer `--timeout` only helps with
  `run_in_background: true`; in the foreground the tool call is killed at 600s
  before the wrapper can report anything.
- The run is read-only by construction. There is no write mode here: the caller
  of this command is already a Claude that can edit files.

## Framing it so the answer is independent

Give the established facts with `file:line`, what you ruled out and how, and the
constraints that matter — but **not your current best guess**. Ask for its
answer, its confidence, the evidence, and what would change its mind. Compare
afterwards.

## Reading the result

Telemetry on stderr names the model, effort, seconds, turns and cost. Open every
`file:line` it cites and mark each claim confirmed or wrong, then report
`AGREES` / `DISAGREES` / `PARTIAL` against your own view, or `INDEPENDENT
ANSWER` if you had none.
