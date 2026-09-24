---
description: Let the Antigravity CLI (agy) hand tasks to Claude Code — install, check or remove the launcher agy calls at a fixed path
argument-hint: "[status|install|uninstall] [--force]"
allowed-tools: ['Bash(bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" bridge *)', Read, AskUserQuestion]
---

The reverse bridge: agy drives, Claude Code does the work. `install` writes an
`ask-claude` skill into agy's machine-wide customization folder
(`~/.gemini/config/skills/ask-claude/`). Its `scripts/ask-claude` launcher stays
at that path across plugin upgrades and runs `agy-run.sh ask-claude` from
whichever plugin version Claude Code has installed. On Windows a
`scripts/ask-claude.ps1` sits next to it, because agy runs commands through
PowerShell there.

The user asked for:

```
$ARGUMENTS
```

## Run it

Pick the action from the request; with no action, run `status`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" bridge status
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" bridge install
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" bridge uninstall
```

Add `--force` to `install` only if the user asked to overwrite a file the
installer did not write.

## Report

Relay the output. Keep the paths, the commands and the rule lines exactly as
printed.

After `install` or `status`, if the read-only rule is absent from agy's
settings, say that headless agy (`agy -p`) cannot call the bridge until
`permissions.allow` in `~/.gemini/antigravity-cli/settings.json` holds that
rule. Offer to add it with `AskUserQuestion`. If the user agrees, add only the
read-only rule with the Edit tool, which asks the user to approve the edit, and
keep the file valid JSON. Recommend leaving the `--allow-write` rule out, so
agy still asks before each run that may change files. Add it only if the user
asks for it by name.

## What agy gets

- Read-only by default: Claude reads and searches in `--dir`, and changes
  nothing.
- `--allow-write` also lets Claude edit files under `--dir`. It needs an explicit
  `--dir`, never runs commands, cannot write agent, editor or git configuration
  (`.agents`, `.gemini`, `.claude`, `.git`, `.vscode`, `.mcp.json`), and refuses
  a home folder or drive root.
- Both modes load only the user's own Claude Code settings, so a repository's
  `.claude/settings.json` hooks never run.
- The standalone `claude` CLI must be signed in. If calls fail with an OAuth
  error, the user runs `claude` once in a terminal.
