---
description: Delegate a task to the Antigravity CLI (`agy`); supports background execution and model selection
argument-hint: "[--background] [--model <alias|id>] [--effort low|medium|high] <task description>"
allowed-tools: ['Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask *)', 'Bash("${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask *)']
---

Hand the user's task to the Antigravity CLI through the wrapper, in one `Bash`
call. No subagent: a subagent that only forwards one call spends Claude tokens
for nothing.

Raw user request:
$ARGUMENTS

## How to invoke

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --for delegate "<task>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --for delegate --model <value> "<task>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --for delegate --model <value> --effort <level> "<task>"
```

- Pass the task text verbatim, quoted as one shell argument so characters like
  `"`, `$`, `;`, `\` and backticks cannot break out.
- If the request contains `--background`, run the Bash call with
  `run_in_background: true`. Strip the flag from the task text.
- If the request contains `--model <value>` or `--effort <level>`, put them
  **before** the task argument and strip them from the task text.
- Set the Bash tool timeout to 600000 ms.

## Choosing `--model`

Without `--model`, the user's profile decides (`/agy-bridge:profile`). Under the
`claude` profile that is a Claude model inside agy, which runs on the Google
plan's quota. Under the default `gemini` profile it is whatever the user's agy
TUI is set to.

Prefer an intent alias — `fast`, `balanced`, `deep`, `flash`, `pro`,
`sonnet`, `opus`, `gpt-oss` — which resolves against the live catalogue
rather than a pinned version. Run `/agy-bridge:models` rather than reciting a model
list from memory.

## Response style

Return Antigravity's stdout verbatim — no extra commentary before or after.
The wrapper may print one `[wrapper] model: …` line on stderr naming the model
it chose. If the call exits non-zero, return its stderr verbatim and stop.

If the user did not supply a task, ask what they would like Antigravity to do.
