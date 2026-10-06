# agy-bridge — Antigravity CLI for Claude Code

Use Google's [Antigravity CLI (`agy`)](https://antigravity.google/) from
inside Claude Code. Hand a wide read to `agy` and get a short answer with
`path:line` citations back, so the bulk tokens never enter your Claude Code
context. Delegate a task, review the current diff, or ask for an independent
second opinion. With the `claude` profile, that work runs on the Claude
models your Google plan offers inside `agy`, so it spends Google's quota
instead of your Claude subscription.

This plugin works in **Claude Code only**. It runs a Bash wrapper and the
`agy` CLI on your machine, so it does nothing in claude.ai chat or Cowork.

## Requirements

- The Antigravity CLI (`agy`), installed and signed in. `/agy-bridge:setup` checks
  both and can install `agy` for you.
- A Google account that `agy` accepts (Google AI Pro or Ultra, Code Assist,
  or an enterprise GCP project).
- Bash and git on `PATH`: macOS, Linux, WSL, or Windows with Git Bash.

## Commands

- `/agy-bridge:setup` — check that `agy` is installed and signed in.
- `/agy-bridge:models` — list the models your `agy` build offers, and the aliases.
- `/agy-bridge:ask <prompt>` — one prompt through `agy`, answer returned as is.
- `/agy-bridge:delegate <task>` and `/agy-bridge:research <topic>` — hand a task or an
  investigation to `agy`, optionally in the background.
- `/agy-bridge:offload <question>` and `/agy-bridge:fanout` — read-only bulk reads, one or
  several in parallel, each returning a short cited answer.
- `/agy-bridge:review [focus]` — a read-only review of your current `git diff`.
- `/agy-bridge:second-opinion <question>` — an answer from a Claude that has not seen
  your conversation, through a fresh `claude -p` or through `agy`.
- `/agy-bridge:image <description>` — generate an image with `agy`.
- `/agy-bridge:profile`, `/agy-bridge:stats`, `/agy-bridge:help` — choose the default models, see
  runs and tokens per plan, list every command.
- `/agy-bridge:bridge` — let `agy` hand tasks back to Claude Code.

The plugin also has two subagents, `agy-bridge:runner` and `agy-bridge:offload`, and the
`agy-bridge:offloading` skill that tells Claude when an offload is worth it.

## What the plugin runs, sends and writes

The plugin is plain Bash. It has no hooks, no MCP servers and no network code
of its own.

**Programs it runs.** `scripts/agy-run.sh` runs your local `agy`. For
`/agy-bridge:second-opinion --via claude` and for the bridge, it runs your local
`claude` headless with only your user settings and no MCP servers.

**Where your data goes.** Prompts, the files `agy` reads, and the diff for
`/agy-bridge:review` go to Google through `agy`, under your Google account and
Google's terms. Prompts for a headless `claude` run go to Anthropic under your
Claude account. The plugin sends nothing anywhere else.

**Install step.** If `agy` is missing, `/agy-bridge:setup` asks before it runs
Google's installer: `curl -fsSL https://antigravity.google/cli/install.sh | bash`.
No other command downloads anything.

**Read-only by default.** `/agy-bridge:offload`, `/agy-bridge:fanout` and `/agy-bridge:review` run
`agy --mode plan`, which gives the model a file viewer only. The prompt also
tells it not to read `.env` files. `/agy-bridge:ask`, `/agy-bridge:delegate` and
`/agy-bridge:research` run `agy` with its normal permissions, so `agy` can edit files
and run commands there, as it does in your terminal.

**Credentials.** The plugin reads no credentials. It only checks whether
`ANTIGRAVITY_API_KEY` is set or an `agy` sign-in folder exists, to tell you
whether `agy` is signed in. `agy` itself reads the key.

**Files it writes on your machine.**

- `~/.gemini/antigravity-cli/settings.json` — when a run uses a model other
  than agy's default (from `--model` or the profile), the wrapper sets agy's
  `model` field for that run, keeps a backup, and puts the old value back
  when the run ends.
- `~/.cache/agy-plugin/` — the model list from `agy models`, kept for an hour.
- `~/.config/agy-plugin/` — your profile and model aliases, if you set them.
- `~/.local/state/agy-plugin/usage.tsv` — one line per run: time, command,
  model, duration, outcome and token counts. Never the prompt, the answer or a file path.
  `AGY_LEDGER=0` turns it off.
- `~/.gemini/config/skills/ask-claude/` — only after `/agy-bridge:bridge install`:
  the launcher `agy` calls to reach Claude Code. `/agy-bridge:bridge uninstall`
  removes it. Claude Code started this way is read-only unless `agy` asks for
  writes, and a write run refuses to start on a Claude Code build without
  `--restricted`.
- Temporary folders under `$TMPDIR` for offload context, removed when the run
  ends. `/agy-bridge:image` saves the image where you ask.

## More

Full usage, configuration and environment variables are in the
[repository README](https://github.com/jimmino/antigravity-plugin-cc#readme).
Changes are in the
[changelog](https://github.com/jimmino/antigravity-plugin-cc/blob/main/CHANGELOG.md).

This plugin is a fork of
[simplybychris/antigravity-plugin-cc](https://github.com/simplybychris/antigravity-plugin-cc).
It is not made or endorsed by Google or Anthropic.

## License

MIT. See [LICENSE](LICENSE).
