---
description: Show or switch the model profile — `claude` runs the plugin's work on agy's Claude models, on the Google plan's quota instead of your Claude plan
argument-hint: "[show | claude | gemini]"
allowed-tools: ['Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" profile)', 'Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" profile *)', 'Bash("${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" profile)', 'Bash("${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" profile *)']
---

Run exactly one of these, matching the user's argument (`show` when there is
none):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" profile show
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" profile claude
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" profile gemini
```

User argument:

```
$ARGUMENTS
```

Show the output as-is. Any other argument: say the profile is `claude` or
`gemini`, and run nothing.

What the profiles mean, if the user asks:

- `gemini` (default) — offload and review use Flash (`balanced`); ask,
  delegate and research use agy's own default; `/agy-bridge:second-opinion` runs a
  fresh Claude Code on the user's Claude plan.
- `claude` — offload, ask and delegate use Sonnet inside agy; review and
  research use Opus; `/agy-bridge:second-opinion` runs Opus inside agy. All of it
  spends the Google plan's quota. A Claude model that runs out of capacity
  falls back to the other Claude family, then Pro, then Flash — never to the
  claude CLI.
- An explicit `--model` always wins. Per-task overrides such as
  `default.offload = opus-medium` and `second-opinion.via = claude` go in the
  config file the output names.

This session still spends Claude tokens to write each prompt and read each
answer. `/agy-bridge:stats` shows how the work split between the two plans.
