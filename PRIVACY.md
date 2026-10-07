# Privacy policy

This policy covers the `agy-bridge` plugin for Claude Code, published from
[jimmino/antigravity-plugin-cc](https://github.com/jimmino/antigravity-plugin-cc).
Last updated: 2026-10-07.

## What the plugin collects

Nothing. The plugin has no server, no analytics and no telemetry. Its author
receives no data from it.

## Where your data goes

The plugin is a Bash wrapper that runs programs already on your machine:

- **Google, through the Antigravity CLI (`agy`).** Prompts, the files `agy`
  reads, and the diff for `/agy-bridge:review` go to Google under your Google
  account. Google's [privacy policy](https://policies.google.com/privacy) and
  the terms of your Google plan apply.
- **Anthropic, through Claude Code (`claude`).** `/agy-bridge:second-opinion
  --via claude` and the bridge run your local `claude` headless. Those
  prompts go to Anthropic under your Claude account. Anthropic's
  [privacy policy](https://www.anthropic.com/legal/privacy) applies.

The plugin sends nothing anywhere else.

## What stays on your machine

The plugin writes these files under your home folder. None of them leaves
your machine through the plugin.

- `~/.local/state/agy-plugin/usage.tsv`: one line per run with the time, the
  command, the model, the duration, the outcome and token counts. It never
  holds a prompt, an answer or a file path. Set `AGY_LEDGER=0` to turn it
  off, and delete the file to clear it.
- `~/.cache/agy-plugin/`: the model list from `agy models`.
- `~/.config/agy-plugin/`: your profile and model aliases, if you set them.
- `~/.gemini/config/skills/ask-claude/`: only after `/agy-bridge:bridge
  install`. `/agy-bridge:bridge uninstall` removes it.
- `~/.gemini/antigravity-cli/settings.json`: changed for the length of one
  run when a run picks a model, then restored.

## Credentials

The plugin reads no credentials. It only checks whether `ANTIGRAVITY_API_KEY`
is set or an `agy` sign-in folder exists, to tell you whether `agy` is signed
in.

## Children

The plugin is not intended for people under 18.

## Changes

Changes to this policy are recorded in the repository's git history.
