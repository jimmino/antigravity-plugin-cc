# agy (Claude Code plugin payload)

This directory is the actual Claude Code plugin. For install instructions and
full usage, see the [repo-level README](../../README.md).

## Layout

- `commands/` — slash commands: `/agy:setup`, `/agy:models`, `/agy:ask`,
  `/agy:offload`, `/agy:fanout`, `/agy:second-opinion`, `/agy:bridge`,
  `/agy:delegate`, `/agy:research`, `/agy:review`, `/agy:image`, `/agy:help`.
- `agents/runner.md` — the `agy:runner` subagent (thin forwarder around the
  Antigravity CLI).
- `agents/offload.md` — the `agy:offload` subagent (read-only bulk read, returns
  a short cited answer).
- `skills/antigravity-cli/` — internal runtime skill, used only inside the
  `agy:runner` subagent.
- `skills/offloading/` — the offload doctrine: what is worth offloading, how to
  shape the prompt, how far to trust the answer. User-invocable.
- `scripts/agy-run.sh` — bash wrapper that locates `agy`, checks auth,
  resolves model aliases against the live catalogue, and runs `agy`. Its
  subcommands are `check`, `models`, `ask`, `offload`, `fanout`, `review`,
  `second-opinion`, `ask-claude`, `bridge`, `image` and `help`.
- `scripts/bridge/` — what `/agy:bridge install` copies into `agy`'s
  customization folder: the `ask-claude` launcher that `agy` calls, its
  PowerShell front end for Windows, and the `SKILL.md` template that tells
  `agy` how to call it. The launcher runs `agy-run.sh ask-claude` from the
  installed plugin version, so its own path never changes.

Tests for the wrapper live in [`tests/`](../../tests) at the repo root:

```bash
bash tests/run-tests.sh
```

They are hermetic: a throwaway `HOME`, a fake `agy` and a fake `claude` in
`tests/fixtures/`, no network and no quota spend.

## Model selection

No model name is hardcoded anywhere in this directory. `agy models` is the
source of truth; the wrapper caches it and resolves aliases against it, so a
new Gemini or Claude generation needs no change here. If you are editing a
command or the subagent, do not add a model list — point at `/agy:models`
instead. That includes the offload fallback chain, which is expressed as
aliases and resolved at runtime.

## Two paths through the wrapper

`ask`, `delegate` and `research` are pass-throughs: whatever `agy` would do
normally, it does.

`offload`, `fanout` and `review` are not. They run `agy --mode plan` with slash
commands disabled so the model cannot write or shell out, prepend a guard that
bans `.env` reads and demands `path:line` citations, take long context on stdin
as a workspace file rather than on the command line, and parse
`--output-format json` for telemetry and for the detection that tells a real
answer from the narration of a turn cut short. On a build with no `--mode`
flag they refuse to run rather than silently drop the read-only guarantee.

`second-opinion` and `ask-claude` do not run `agy` at all: they start a
headless Claude Code through one shared runner, which loads only the user's
settings and no MCP servers. `ask-claude` is the side `agy` calls. It stays
read-only unless `--allow-write`, and a write run fails closed on a Claude
Code build without `--restricted`.

## Why this layout

Mirrors the conventions used by
[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc), trimmed
down: no Node runtime, no broker, no review-gate hook. Plain Bash plus two
subagents.
