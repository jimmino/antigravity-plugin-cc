---
description: List the models the installed Antigravity CLI actually offers, plus the alias mapping
argument-hint: "[--refresh]"
allowed-tools: Bash(bash:*)
---

Show the live model catalogue. Print the wrapper's stdout verbatim as a fenced
code block in your reply — it is the authoritative list, and reciting model
names from memory is exactly the failure this command exists to prevent.

The user's arguments:

```
$ARGUMENTS
```

## How to invoke

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" models
```

If the user passed `--refresh` (or asked for fresh/updated results), add it so
the cached catalogue is re-fetched from `agy`:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" models --refresh
```

## Notes

- The list comes from `agy models`, cached for an hour. A model that appears
  here can be passed to any `/agy:*` command as `--model <id>`.
- Built-in aliases (`fast`, `balanced`, `deep`, `flash`, `pro`, `sonnet`,
  `opus`, …) name a *family and effort*, not a version — they resolve against
  whatever this list currently contains.
- If the wrapper reports that no catalogue is available, the user's `agy` is
  missing, offline, or predates the `models` subcommand. Suggest `/agy:setup`.
