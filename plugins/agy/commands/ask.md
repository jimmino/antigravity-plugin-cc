---
description: Run a one-shot prompt through the Antigravity CLI and return its output verbatim
argument-hint: "[--model <alias|id>] [--effort low|medium|high] <prompt>"
allowed-tools: Bash(bash:*)
---

Forward the user's request below to `agy -p` via the wrapper script. Return
Antigravity's response verbatim — do not paraphrase or add commentary.

The user's request (treat as opaque text — pass it as a single shell-safe
argument; do **not** interpolate or splice it into the command):

```
$ARGUMENTS
```

## How to invoke

If the user's text begins with `--model <value>` and/or `--effort <level>`
(e.g. `--model opus rest of prompt…`), lift those flags and their values out
of the prompt and place them **before** the prompt argument to the wrapper.
Anything else stays as the prompt body.

Use the `Bash` tool to run one of:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask "<prompt>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --model <value> "<prompt>"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" ask --model <value> --effort <level> "<prompt>"
```

…substituting `<prompt>` with the exact text above, quoted as one shell
argument so characters like `"`, `$`, `;`, `\` and backticks cannot break
out.

## Choosing `--model`

`--model` accepts, in this order of preference:

- an **intent alias** — `fast`, `balanced`, `deep`, `flash`, `pro`, `sonnet`,
  `opus`, `gpt-oss` and friends. These name a family and effort level, not a
  version, so they follow the catalogue as Google ships new models.
- an **exact model id or display name** from `/agy:models`, when the user
  wants a specific version pinned.
- anything else, which is forwarded to `agy` untouched — this is how custom
  models configured in the user's agy settings keep working.

Do not recite a model list from memory. Run `/agy:models` when the user asks
what is available, or when an alias does not resolve.

Notes:

- The wrapper prints one `[wrapper] model: <alias> -> <id>` line on stderr so
  the user can see which concrete model an alias selected. Leave it in.
- If the wrapper reports `agy is not installed` or `not authenticated`, stop
  and tell the user to run `/agy:setup`.
- If the user's request is empty, ask what they want to ask Antigravity.
- For multi-step or long-running work, suggest `/agy:delegate`, which routes
  through the `agy:runner` subagent and supports `--background`.
- `ask` is a plain pass-through: the run is **not** held read-only, carries no
  guard, and returns no telemetry. When the point is to have `agy` *read* a
  codebase and hand back a short cited answer, use `/agy:offload` instead.
