# Plugin layout

How `plugins/agy/` is put together, for contributors. Paths are relative to
that folder. For install and usage,
see the [README](README.md); for what the listing shows, see
[plugins/agy/README.md](plugins/agy/README.md).

## Layout

- `commands/` — slash commands: `/agy-bridge:setup`, `/agy-bridge:models`, `/agy-bridge:ask`,
  `/agy-bridge:offload`, `/agy-bridge:fanout`, `/agy-bridge:second-opinion`, `/agy-bridge:bridge`,
  `/agy-bridge:delegate`, `/agy-bridge:research`, `/agy-bridge:review`, `/agy-bridge:image`, `/agy-bridge:profile`,
  `/agy-bridge:stats`, `/agy-bridge:help`.
- `agents/runner.md` — the `agy-bridge:runner` subagent (thin forwarder around the
  Antigravity CLI). It and `agy-bridge:offload` run on Haiku.
- `agents/offload.md` — the `agy-bridge:offload` subagent (read-only bulk read, returns
  a short cited answer).
- `skills/antigravity-cli/` — internal runtime skill, used only inside the
  `agy-bridge:runner` subagent.
- `skills/offloading/` — the offload doctrine: what is worth offloading, how to
  shape the prompt, how far to trust the answer. User-invocable.
- `scripts/agy-run.sh` — bash wrapper that locates `agy`, checks auth,
  resolves model aliases against the live catalogue, and runs `agy`. Its
  subcommands are `check`, `models`, `ask`, `offload`, `fanout`, `review`,
  `second-opinion`, `ask-claude`, `bridge`, `profile`, `stats`, `image` and
  `help`.
- `scripts/bridge/` — what `/agy-bridge:bridge install` copies into `agy`'s
  customization folder: the `ask-claude` launcher that `agy` calls, its
  PowerShell front end for Windows, and the `SKILL.md` template that tells
  `agy` how to call it. The launcher runs `agy-run.sh ask-claude` from the
  installed plugin version, so its own path never changes.

Tests for the wrapper live in [`tests/`](tests) at the repo root:

```bash
bash tests/run-tests.sh
```

They are hermetic: a throwaway `HOME`, a fake `agy` and a fake `claude` in
`tests/fixtures/`, no network and no quota spend.

## Model selection

No model name is hardcoded anywhere in this directory. `agy models` is the
source of truth; the wrapper caches it and resolves aliases against it, so a
new Gemini or Claude generation needs no change here. If you are editing a
command or the subagent, do not add a model list — point at `/agy-bridge:models`
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
answer from the narration of a turn cut short. `agy` gives such a run only
`view_file`, so they also write a map of the workspace for the model to read.
On a build with no `--mode` flag they refuse to run rather than silently drop
the read-only guarantee.

Without `--model`, every path takes its model from the profile
(`agy-run.sh profile`): `gemini` keeps the original defaults, `claude` uses
the Claude models inside `agy`. Each `agy` and `claude` run adds one line to
the usage ledger that `agy-run.sh stats` sums.

`second-opinion --via claude` and `ask-claude` do not run `agy` at all: they start a
headless Claude Code through one shared runner, which loads only the user's
settings and no MCP servers. `ask-claude` is the side `agy` calls. It stays
read-only unless `--allow-write`, and a write run fails closed on a Claude
Code build without `--restricted`.

## Why this layout

Mirrors the conventions used by
[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc), trimmed
down: no Node runtime, no broker, no review-gate hook. Plain Bash plus two
subagents.
