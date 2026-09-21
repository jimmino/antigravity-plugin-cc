---
description: Delegate a task to the Antigravity (`agy`) runner subagent; supports background execution and model selection
argument-hint: "[--background] [--model <alias|id>] [--effort low|medium|high] <task description>"
allowed-tools: Agent
---

Hand the user's task to the `agy:runner` subagent
(`subagent_type: "agy:runner"`).

Raw user request:
$ARGUMENTS

## Routing rules

- If the request contains `--background`, launch the subagent with
  `run_in_background: true`. Strip the flag from the forwarded task text.
- Otherwise run the subagent in the foreground.
- If the request contains `--model <value>` or `--effort <level>`, forward
  them to the subagent so they can be appended to the wrapper call **before**
  the prompt argument. Strip them from the task text.
- If no model is given, the wrapper leaves model selection to whatever the
  user's TUI is currently set to (stored in
  `~/.gemini/antigravity-cli/settings.json`).

## Choosing `--model`

Prefer an intent alias — `fast`, `balanced`, `deep`, `flash`, `pro`,
`sonnet`, `opus`, `gpt-oss` — which resolves against the live catalogue
rather than a pinned version. An exact id or display name from `/agy:models`
also works, as does any custom model name the user has configured in agy.

Run `/agy:models` rather than reciting a model list from memory.

## Response style

The subagent is a thin wrapper around `agy`. Return its output verbatim — no
extra commentary before or after.

If the user did not supply a task, ask what they would like Antigravity to do.
