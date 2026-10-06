---
description: Delegate a thorough research investigation to the Antigravity CLI (`agy`)
argument-hint: "[--background] [--model <alias|id>] [--effort low|medium|high] <topic or question>"
allowed-tools: ['Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask *)', 'Bash("${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask *)']
---

Hand a deep-research task to the Antigravity CLI through the wrapper, in one
`Bash` call. No subagent: a subagent that only forwards one call spends Claude
tokens for nothing.

Raw user request:
$ARGUMENTS

## How to invoke

Strip any routing flags — `--background`, `--model <value>`,
`--effort <level>` — from the topic, then build the prompt as:

```
Conduct a thorough research investigation on the following topic. Look up
authoritative sources, summarize the current state of knowledge, surface
disagreements or open questions, and structure the response with clear
sections (Background, Key findings, Caveats, Sources).

Topic: <stripped user request here>
```

Run one of:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --for research "<prompt>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --for research --model <value> "<prompt>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --for research --model <value> --effort <level> "<prompt>"
```

- Quote the prompt as one shell argument so characters like `"`, `$`, `;`,
  `\` and backticks cannot break out.
- Research is often long-running: run the Bash call with
  `run_in_background: true` unless the user explicitly asked for foreground.
  Set the Bash tool timeout to 600000 ms.
- Put `--model` and `--effort` **before** the prompt argument.

## Choosing `--model`

Without `--model`, the user's profile decides (`/agy:profile`). The `claude`
profile picks Opus inside agy, on the Google plan's quota. The default
`gemini` profile leaves the choice to the agy TUI's model; `deep` (newest Pro
at high effort) or `opus` work well for research. Aliases resolve against the
live catalogue — run `/agy:models` to see it rather than reciting model names
from memory.

## Response style

Return Antigravity's stdout verbatim — no extra commentary before or after.
If the call exits non-zero, return its stderr verbatim and stop.

If the user did not supply a topic, ask what they want researched.
