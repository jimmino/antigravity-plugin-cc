# agy (Claude Code plugin payload)

This directory is the actual Claude Code plugin. For install instructions and
full usage, see the [repo-level README](../../README.md).

## Layout

- `commands/` — slash commands: `/agy:setup`, `/agy:models`, `/agy:ask`,
  `/agy:delegate`, `/agy:research`, `/agy:review`, `/agy:image`, `/agy:help`.
- `agents/runner.md` — the `agy:runner` subagent (thin forwarder around the
  Antigravity CLI).
- `skills/antigravity-cli/` — internal runtime skill, used only inside the
  `agy:runner` subagent.
- `scripts/agy-run.sh` — bash wrapper that locates `agy`, checks auth,
  resolves model aliases against the live catalogue, and invokes `agy -p`.

Tests for the wrapper live in [`tests/`](../../tests) at the repo root:

```bash
bash tests/run-tests.sh
```

## Model selection

No model name is hardcoded anywhere in this directory. `agy models` is the
source of truth; the wrapper caches it and resolves aliases against it, so a
new Gemini or Claude generation needs no change here. If you are editing a
command or the subagent, do not add a model list — point at `/agy:models`
instead.

## Why this layout

Mirrors the conventions used by
[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc), trimmed
down: no Node runtime, no broker, no review-gate hook. Plain Bash plus a
single subagent.
