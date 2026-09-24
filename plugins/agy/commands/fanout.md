---
description: Run several Antigravity offload jobs in parallel — one question across many folders, or many questions about one tree
argument-hint: "[--jobs <file.json>] [--prompt <text>]... [--dir <path>] [--throttle N]"
allowed-tools: ['Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" fanout *)', Write, Read, Grep, Glob]
---

Each offload takes 1–3 minutes, so concurrency is the whole win. Use this when
the same question applies to several folders, or several independent questions
apply to one tree.

The user's request:

```
$ARGUMENTS
```

## How to invoke

For a handful of short questions against one directory:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" fanout --dir <abs-path> --prompt "<question one>" --prompt "<question two>" --throttle 3
```

Keep the call on one line, in exactly the shape above: it is the only shape
this command pre-approves.

For anything with per-job directories or models, write a jobs file first:

```json
[
  { "label": "auth",    "dir": "C:/Data/App/api", "prompt": "...", "model": "balanced" },
  { "label": "billing", "dir": "C:/Data/App/web", "prompt": "...", "model": "fast" }
]
```

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" fanout --jobs <file.json> --throttle 3
```

Per job: `label`, `dir`, `prompt`, `model` (or `tier`), `effort`, `addDir` (a
path or an array). Anything omitted falls back to the command-line default.

**Write Windows paths with forward slashes** (`C:/Data/App`) or doubled
backslashes. A single backslash before `b`, `f`, `n`, `r`, `t` or `u` is a
valid JSON escape, so `C:\Data\backend` parses as a control character rather
than a path. The wrapper detects that and says so.

## Rules

- Split by area, one job per area. Do not cram a whole backend into one job; it
  will time out.
- Every job runs through the same read-only offload path, so the same rule
  applies to each: **offload semantics, never arithmetic.**
- Run it with `run_in_background: true`. There is no reason to sit idle for
  three minutes.
- Keep prompts short. Long context per job is not supported here — if a job
  needs a diff or a log, run it on its own with `/agy:offload --stdin`.

## Reading the result

Answers come back grouped under `## <label>  [<model>]`, telemetry per job on
stderr prefixed `[fanout]`. A job that produced nothing shows
`(no answer — exit N)` — check its telemetry line for `ABORTED` (the model
reached for a shell) or a capacity failure.

Verify the findings the same way as a single offload: open the cited lines, and
grep for anything the sweep claims is absent.
