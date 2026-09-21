---
name: antigravity-cli
description: Internal runtime contract for invoking the Antigravity CLI (`agy`) from the `agy` subagent. Not user-invocable.
user-invocable: false
---

# Antigravity CLI runtime

Use this skill only inside the `agy` subagent.

## Primary helper

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask [--model <value>] [--effort <level>] "<prompt>" [agy-flags...]
```

The wrapper:

- Locates `agy` in `PATH`, `~/.local/bin`, `~/AppData/Local/agy/bin`,
  `/opt/antigravity/bin`, or `/usr/local/bin`.
- Verifies auth (system keyring OAuth or `ANTIGRAVITY_API_KEY`).
- Runs `agy -p "<prompt>"` non-interactively.
- If `--model` is supplied **before** the prompt, resolves it against the
  live catalogue and passes the resulting id to `agy --model`.
- Forwards any extra arguments **after** the prompt straight to `agy` — so
  `… ask "<prompt>" --sandbox` becomes `agy -p "<prompt>" --sandbox`.

## Rules of engagement

One wrapper call per task. The subagent is a forwarder, not an orchestrator —
keep the user's task text intact and let `agy` do the work.

Strip flags that belong to the parent slash command (`--background`) before
forwarding. Pass `--model` / `--effort` to the wrapper, not to agy directly,
so alias resolution and old-build fallbacks apply.

## Model selection

`agy models` is the source of truth, not this file. Never recite a model list
from memory — the catalogue moves, and a stale name either errors or silently
selects a different model.

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" models
```

`--model` accepts:

1. **Intent aliases**, which name a family and effort rather than a version
   and therefore follow new releases automatically:
   `fast`, `balanced`, `deep`, `flash-low`, `flash-medium`, `flash`,
   `pro-low`, `pro-medium`, `pro`, `sonnet`, `opus`, `haiku`, `gpt-oss`,
   `gemini`, `claude`. All case-insensitive.
2. **Exact ids or display names** from the catalogue above, when a specific
   version must be pinned.
3. **Anything else**, forwarded to `agy` verbatim — this is how custom models
   defined in the user's agy settings keep working.

Users can define their own aliases in
`~/.config/agy-plugin/aliases.conf` (`name = target`, one per line). They are
read from the user's config only, never from the checked-out project.

`--effort low|medium|high` selects a reasoning-effort variant and is passed to
`agy --effort` when the installed build supports it.

## agy-native flags worth knowing

Run `agy --help` for the full list. Useful ones that go **after** the
prompt argument:

- `--sandbox` — extra-restrictive execution; only when the user asked for it.
- `--print-timeout 10m` — extend the print timeout.
- `--add-dir <path>` — add a directory to the workspace (repeatable).

## What this skill does NOT do

- Does not install or authenticate `agy`. That is `/agy:setup`'s job.
- Does not retry, summarize, or post-process `agy`'s output.
- Does not read files, run `git`, or make HTTP calls outside the wrapper.

## Error handling

If the wrapper exits non-zero, return its stderr verbatim. Standard exit
codes:

- `127` — `agy` binary not found.
- `1` — not authenticated, no diff found (`review`), no catalogue available
  (`models`), or settings.json missing/malformed on the legacy `--model` path.
- `64` — bad CLI usage of the wrapper itself: empty `--model`, an invalid
  `--effort`, an alias that matches nothing in the catalogue, or an alias
  cycle in the user's config.
- Any other code is `agy`'s own and is passed through unchanged (agy uses `3`
  for headless model/agent API failures, alongside an `AGY_ERROR: {...}` JSON
  line on stderr).

A `[wrapper] model: <alias> -> <id>` line on stderr is informational: it
records which concrete model an alias resolved to.
