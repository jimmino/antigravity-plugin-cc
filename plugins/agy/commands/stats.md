---
description: Show how many runs and tokens went to the Google plan (agy) and to your Claude plan (claude -p)
argument-hint: "[--days N | --all]"
allowed-tools: ['Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" stats)', 'Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" stats *)', 'Bash("${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" stats)', 'Bash("${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" stats *)']
---

Run one of these. Pass `--days N` or `--all` only if the user gave it; the
default window is 30 days.

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" stats
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" stats --days <N>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" stats --all
```

User argument:

```
$ARGUMENTS
```

Show the table as-is. Then add at most two lines: the share of agy tokens that
ran on Claude models, and a reminder that the tokens this session spent on
prompts and answers are not in the ledger.
