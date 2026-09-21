---
description: Verify the Antigravity CLI (`agy`) is installed and authenticated; offer to install it if missing
allowed-tools: Bash(bash:*), Bash(curl:*), AskUserQuestion
---

Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" check
```

Then interpret the JSON output:

- If `installed: false`, use `AskUserQuestion` once to offer installation.
  Options:
  - `Install agy now (Recommended)` — run the official installer:
    ```bash
    curl -fsSL https://antigravity.google/cli/install.sh | bash
    ```
    Then re-run the check.
  - `Skip for now` — explain that `/agy:ask`, `/agy:offload`, `/agy:fanout`,
    `/agy:delegate`, `/agy:research`, `/agy:review`, `/agy:image` and
    `/agy:models` will all fail until `agy` is installed.

- If `installed: true` but `auth: missing`, tell the user to either:
  - run `!agy` once interactively to complete OAuth (cached in the system
    keyring), **or**
  - export `ANTIGRAVITY_API_KEY` in their shell rc and reload it.

- If `installed: true` and `auth` is `api-key` or `oauth`, report that
  everything is ready — one short status line is enough.

## Capability fields

The check also reports what the installed `agy` build supports:

- `nativeModelFlag: true` — `agy` has its own `--model` flag, so `/agy:*`
  model selection is a plain flag pass-through and never touches the user's
  `settings.json`. This is the normal, preferred path.
- `nativeModelFlag: false` — an older build. Model selection still works, but
  the wrapper falls back to temporarily patching `settings.json` under a lock.
  Mention that updating `agy` (`agy update`) removes that fallback.
- `modelsSubcommand: false` — the build predates `agy models`, so the live
  catalogue and the intent aliases (`fast`, `flash`, `deep`, …) are
  unavailable; only exact model names will work. Suggest `agy update`.
- `planMode: false` — the build has no `--mode` flag, so a run cannot be held
  read-only. `/agy:offload`, `/agy:fanout` and `/agy:review` refuse to run
  rather than send an unrestricted agent into the user's repository. `agy
  update` fixes it.
- `jsonOutput: false` — no `--output-format json`, or no `python3` on PATH.
  Offloading still works, but without token telemetry or the detection that
  tells a real answer from the narration of a turn cut short.
- `offload: true` — the read-only offload path is available.
