---
description: Get an independent second opinion from Claude, read-only — a fresh Claude Code (your Claude plan) or a Claude model inside agy (the Google plan)
argument-hint: "[--via claude|agy] [--model opus|sonnet|haiku] [--effort L] [--dir <path>] <question>"
allowed-tools: ['Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" second-opinion *)', 'Bash("${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" second-opinion *)', Read, Grep, Glob]
---

A second opinion from Claude, held read-only. It runs one of two ways:

- `--via claude` — real Claude Code, headless, with only `Read`, `Grep` and
  `Glob` in plan mode. It can *search*, so it finds things faster. It spends
  the user's own Claude plan. The default under the `gemini` profile.
- `--via agy` — a Claude model inside agy, through the read-only offload path.
  agy gives it only a file viewer, so the wrapper hands it a map of the
  workspace instead of a search tool. It spends the Google plan's quota, not
  the user's Claude plan. The default under the `claude` profile
  (`/agy:profile`).

Without `--via`, the profile decides, and `second-opinion.via` in the config
file beats the profile.

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
  triage (`--via claude` only; agy offers no Haiku). `--effort
  low|medium|high|xhigh|max` (default `high`). Through agy, `opus` and
  `sonnet` take the matching agy variant (`opus-high`, `sonnet-medium`), and
  `xhigh` or `max` fall back to the highest one agy offers.
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

Telemetry on stderr names the model, seconds and tokens (plus turns and cost
for `--via claude`). Through agy, a model other than the one asked for means a
capacity fallback, and the answer is weaker; `PARTIAL` or `ABORTED` means the
turn was cut short, so do not treat the text as an answer. Open every
`file:line` it cites and mark each claim confirmed or wrong, then report
`AGREES` / `DISAGREES` / `PARTIAL` against your own view, or `INDEPENDENT
ANSWER` if you had none.
