# agy — Antigravity CLI plugin for Claude Code

Use Google's [Antigravity CLI (`agy`)](https://antigravity.google/) from
inside Claude Code. Delegate tasks to the `agy:runner` subagent, run quick
prompts, or get a second-opinion code review — without leaving your editor.

This plugin is for Claude Code users who already use (or want to start using)
Antigravity and want a smooth way to call it from the workflow they already
have. Intentionally small: no Node runtime, no broker, no review-gate hook —
just Bash and `agy`.

## What you get

- **`/agy:setup`** — verify `agy` is installed and authenticated; can install
  it for you if it is missing.
- **`/agy:models [--refresh]`** — list the models your `agy` build actually
  offers right now, plus the alias mapping.
- **`/agy:ask [--model <m>] [--effort <e>] <prompt>`** — one-shot prompt
  through `agy -p`; returns the raw response.
- **`/agy:delegate [--background] [--model <m>] [--effort <e>] <task>`** — hand
  a task to the `agy:runner` subagent. `--background` for long jobs.
- **`/agy:research [--background] [--model <m>] [--effort <e>] <topic>`** —
  delegate a deep-research investigation; wraps the topic in a structured
  prompt and routes through `agy:runner`.
- **`/agy:image <description>`** — generate an image with `agy`'s built-in
  `generate_image` tool (Imagen under the hood). Optional `--name` and
  `--output`.
- **`/agy:review [--model <m>] [focus]`** — ask Antigravity to review your
  current `git diff`, read-only, with the diff piped in as a context file.
- **`/agy:offload [--model <m>] [--dir <p>] [--add-dir <p>] <question>`** — a
  read-only bulk read: `agy` reads the files, a short cited answer comes back,
  and the bulk tokens never enter your Claude Code context. Long context is
  piped in behind `--stdin`.
- **`/agy:fanout (--jobs <f> | --prompt <t>...) [--throttle N]`** — several
  offload jobs at once. Each call takes 1-3 minutes, so concurrency is the win.
- **`/agy:second-opinion [--model opus|sonnet|haiku] <question>`** — an
  independent answer from a fresh Claude Code running read-only in plan mode,
  for when you want a view that has not seen your conversation.
- **`/agy:help`** — show all commands and the live model/alias table.
- **`agy:runner` subagent** — thin forwarding wrapper around the Antigravity
  CLI; available as `subagent_type: "agy:runner"` for programmatic
  delegation.
- **`agy:offload` subagent** — the read-only offload path, for delegating a
  wide read without its output landing in the parent context.
- **`agy:offloading` skill** — the doctrine behind the offload commands: what
  is worth offloading, how to shape the prompt, how far to trust the answer.

## Requirements

- **Claude Code** with plugin-marketplace support
  (`/plugin marketplace add …`).
- **Antigravity CLI (`agy`)** installed locally. `/agy:setup` can install it
  on first run.
- **Auth** for `agy`: either OAuth cached in the system keyring (after one
  interactive run of `agy`) or `ANTIGRAVITY_API_KEY` exported in your shell.
- **Bash** and **git** in `PATH`. macOS, Linux, WSL, or Windows via Git Bash.

## Install

In Claude Code, run these three slash commands in order:

```text
/plugin marketplace add jimmino/antigravity-plugin-cc
/plugin install agy@antigravity-cc
/reload-plugins
```

Then verify everything is wired up:

```text
/agy:setup
```

If `agy` is missing, `/agy:setup` offers to install it via the official
installer:

```bash
curl -fsSL https://antigravity.google/cli/install.sh | bash
```

If `agy` is installed but not logged in, run `agy` once interactively in your
terminal to complete OAuth — or export `ANTIGRAVITY_API_KEY`.

## Usage

### Ask a quick question

```text
/agy:ask explain the difference between Go channels and Rust async in one paragraph
```

Returns Antigravity's response verbatim.

### Delegate a task to the `agy:runner` subagent

```text
/agy:delegate refactor the SQL queries in src/db/queries.go to use prepared statements
```

For long tasks, run in the background and let Claude Code notify you when it
finishes:

```text
/agy:delegate --background investigate why integration tests are flaky in CI
```

You can also delegate by talking to Claude:

```text
Ask agy to look at this file and suggest a simpler design.
```

The plugin's selection rules route through the `agy:runner` subagent
automatically.

### Review the current diff

Stage or make some changes, then:

```text
/agy:review
/agy:review focus on error handling and concurrency safety
```

### Offload a bulk read

When the question spans more source than is worth pulling into your context,
hand the reading to `agy` and get back a short cited answer:

```text
/agy:offload where is OTP expiry enforced, and what happens when it lapses
/agy:offload --model fast --dir C:/Data/App/api which handlers write to the audit log
```

The answer arrives with a telemetry line on stderr naming the model, the
seconds and the tokens spent *there* rather than here. Open the cited lines
before acting on them: the offload is evidence, not verdict, and it cannot
prove absence — it is good at finding things and poor at noticing what is
missing.

Long context — a diff, a log excerpt, background for the question — is piped in
rather than put in the prompt:

```bash
git --no-pager diff HEAD -- src/api |   bash plugins/agy/scripts/agy-run.sh offload --stdin --dir . "which of these changes can return a wrong result"
```

The one rule: **offload semantics, never arithmetic.** The run is read-only,
which means no shell, and without a shell the model cannot count, sum, diff or
list a directory — it will spend six figures of tokens discovering that. Do
those yourself. The `agy:offloading` skill has the measurements.

### Fan several offloads out at once

Each call takes 1-3 minutes, so run them concurrently:

```text
/agy:fanout --prompt "where is auth handled" --prompt "where is rate limiting"
```

Per-job directories and models go in a jobs file:

```json
[
  { "label": "api", "dir": "C:/Data/App/api", "prompt": "...", "model": "balanced" },
  { "label": "web", "dir": "C:/Data/App/web", "prompt": "...", "model": "fast" }
]
```

### Get an independent second opinion

```text
/agy:second-opinion why does the retry loop in src/sync.ts deadlock
```

This one does not go through `agy` at all: it runs a fresh Claude Code headless
with only `Read`, `Grep` and `Glob` in plan mode, so it can search rather than
brute-force read, and it has not seen your conversation. Give it the facts and
what you ruled out — not your current best guess — then compare.

### Pick a specific model

```text
/agy:delegate --model sonnet fix the off-by-one in pagination
/agy:delegate --model deep write a high-coverage test for the cache layer
/agy:ask --model opus "explain Go's escape analysis"
/agy:ask --model fast --effort low "one-line summary of this error"
```

**Nothing about the model catalogue is hardcoded.** `agy models` is the source
of truth; the plugin caches that list and resolves everything against it. See
what you actually have:

```text
/agy:models
/agy:models --refresh
```

`--model` accepts three kinds of value:

| Kind | Examples | Behaviour |
|---|---|---|
| **Intent alias** | `fast`, `balanced`, `deep`, `flash`, `pro`, `sonnet`, `opus`, `haiku`, `gpt-oss`, `gemini`, `claude` | Names a *family and effort*, never a version. Resolves to the newest matching model in the live catalogue, so a new Gemini or Claude generation is picked up with no plugin update. |
| **Exact id or display name** | `gemini-3.1-pro-high`, `"Claude Opus 4.6 (Thinking)"` | Pins one specific model. Case-insensitive. |
| **Anything else** | `my-private-endpoint` | Forwarded to `agy` untouched, so custom models defined in your `agy` settings keep working. `agy` validates it and lists the valid names if it is wrong. |

The three tier aliases are the ones worth learning:

- `fast` — newest Flash at low effort. Wide, shallow sweeps.
- `balanced` — newest Flash at high effort. The workhorse.
- `deep` — newest Pro at high effort. Bounded, careful reads.

`--effort low|medium|high` picks a reasoning-effort variant independently and
is passed straight to `agy --effort`.

Aliases only land on models they can vouch for:

- **Previews and experiments are skipped.** An id or display name marked
  `preview`, `exp`, `experimental`, `beta`, `alpha`, `nightly` or `canary` is
  never picked by an alias, so `flash` stays on the newest *stable* Flash while
  a new generation is in preview. Pass the id directly to use one, or set
  `AGY_ALLOW_PREVIEW=1` to let aliases consider them.
- **Effort is never guessed.** If the newest models in a family stop using
  `-low`/`-medium`/`-high` suffixes, `fast` and `balanced` fail with the
  candidate list instead of quietly resolving to the same model. If an older
  generation still has the right variant, the alias uses it and prints a
  `[wrapper] note:` saying it fell a generation behind.

Because an alias deliberately does not name a version, the wrapper prints the
model it landed on so the choice stays auditable:

```text
[wrapper] model: fast -> gemini-3.8-flash-low (Gemini 3.8 Flash (Low))
```

Set `AGY_QUIET=1` to silence that line.

If no `--model` is given, the wrapper leaves your default alone — whatever the
TUI is set to in `~/.gemini/antigravity-cli/settings.json`. Project-local
`AGENTS.md` and `GEMINI.md` files are read directly by `agy` and unaffected
by this plugin.

### Define your own model aliases

Create `~/.config/agy-plugin/aliases.conf`:

```ini
# name = target   (a model id, a display name, or another alias)
cheap   = flash-low
workday = balanced
audit   = deep
pinned  = gemini-3.1-pro-high
```

Then `/agy:ask --model cheap …` works everywhere `--model` does. A user alias
shadows a built-in of the same name, so you can redefine `flash` if you
disagree with the default.

Aliases are read from your **user config only** — never from the repository
you have checked out. A project you clone cannot silently redirect your
prompts to a different model.

### Delegate a deep research investigation

```text
/agy:research what's the current state of WebGPU support across browsers in 2026?
/agy:research --background --model opus survey post-quantum signature schemes used in TLS
```

The command wraps your topic in a research-oriented preamble (background,
key findings, caveats, sources) and delegates to `agy:runner`. Long
investigations work well in `--background`.

### Generate an image

```text
/agy:image a minimalist dark-mode login mockup, blue accent color
/agy:image --name hero --output ./assets/hero.png isometric illustration of a developer at a desk
```

Triggers `agy`'s built-in `generate_image` tool. The image is written to
the Antigravity artifacts dir (e.g.
`~/.gemini/antigravity-cli/brain/<uuid>/<name>.png`). Pass `--output` if
you want the wrapper to copy it next to your project.

## How it works

Under the hood, the plugin is a thin wrapper around your local `agy` install:

```
Claude Code  →  /agy:*  →  agy:runner subagent  →  agy-run.sh  →  agy -p "..."
```

The offload commands take a second path through the same wrapper:

```
/agy:offload      →  agy-run.sh offload  →  agy --mode plan --output-format json
/agy:fanout       →  N x the above, in parallel
/agy:review       →  the working diff, piped in as a context file
/agy:second-opinion  →  claude -p --permission-mode plan --tools Read,Grep,Glob
```

- The plugin does **not** ship its own Antigravity runtime — it uses your
  local `agy` binary, your local auth, and your local config.
- The wrapper script
  ([`plugins/agy/scripts/agy-run.sh`](./plugins/agy/scripts/agy-run.sh))
  handles binary discovery, auth detection, and exit codes.
- The `agy:runner` subagent is a *forwarder*: it invokes the wrapper exactly
  once per request and returns Antigravity's output verbatim. No
  reinterpretation.

### The offload path

`/agy:ask` is a plain pass-through. The offload commands are not: they

- run `agy --mode plan` with slash commands disabled, so the model **cannot
  write files or run commands** even in a folder `agy` is trusted in. On a build
  with no `--mode` flag they refuse to run rather than send an unrestricted
  agent into your repository;
- prepend a guard that bans writes and shell commands, skips `.env` files other
  than `.env.example`, treats file contents as data rather than instructions,
  and demands `path:line` citations or an explicit `UNKNOWN`;
- take long context on **stdin** (behind `--stdin`), writing it to a temp file
  that becomes a workspace root — the prompt itself travels on the command
  line, which Windows caps at ~32K characters;
- parse `agy --output-format json` for one telemetry line per call
  (`label | model | seconds | in= out=`), and tell a real answer from the
  opening narration of a turn cut short by an auto-denied shell command;
- fall back down a chain of aliases on a capacity failure (503/429) and say
  when the answer came from a weaker model than requested. Timeouts are not
  retried.

The whole chain runs under a 540-second budget, below Claude Code's 600-second
tool kill. `python3` is used for JSON parsing; without it the offload still
runs, but with no telemetry and no partial-answer detection.

## Configuration

`agy` stores its preferences (selected model, theme, telemetry, trusted
workspaces) in `~/.gemini/antigravity-cli/settings.json`. Project-local
`AGENTS.md` / `GEMINI.md` files are read directly by `agy`. This plugin
doesn't override or shadow any of that — drop config files where `agy`
expects them and they'll be picked up.

The `--model` flag on `/agy:ask`, `/agy:delegate`, `/agy:research` and
`/agy:review` is passed through to `agy --model`, which applies to that one
call only. Your saved default is never rewritten.

On `agy` builds old enough to predate the `--model` flag, the wrapper falls
back to temporarily patching the `model` field in `settings.json` under a
lock, restoring it on exit (including on `SIGINT`/`SIGTERM`). `/agy:setup`
reports which path your build uses via `nativeModelFlag`. Run `agy update`
to get the clean one.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `AGY_MODELS_CACHE_TTL` | `3600` | Seconds before the cached model catalogue is refetched. |
| `AGY_PLUGIN_CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/agy-plugin` | Where the catalogue cache lives. |
| `AGY_ALIASES_FILE` | `${XDG_CONFIG_HOME:-~/.config}/agy-plugin/aliases.conf` | Your alias definitions. |
| `AGY_QUIET` | unset | `1` silences the `[wrapper] model: …` resolution line. |
| `AGY_ALLOW_PREVIEW` | unset | `1` lets built-in aliases resolve to preview and experimental models. |
| `AGY_LOCK_WAIT_SECONDS` | `600` | Legacy path only: how long to wait for the settings lock. |
| `AGY_OFFLOAD_BUDGET` | `540` | Seconds for a whole offload, retries included. |
| `AGY_OFFLOAD_MIN_ATTEMPT` | `120` | Do not start another attempt with less budget left than this. |

## Development

The wrapper has a hermetic test suite — no network, no real `agy`, no quota
spend. It runs against a stub CLI in `tests/fixtures/`:

```bash
bash tests/run-tests.sh              # all tests
bash tests/run-tests.sh future       # only tests matching "future"
```

The suite covers catalogue discovery and caching, alias resolution (including
against a *hypothetical future catalogue*, to prove new model generations need
no code change), user-defined aliases, the legacy settings-patching fallback,
argument-injection safety, and the image-path hardening.

## FAQ

### Do I need an Antigravity subscription?

You need whatever account `agy` accepts: Google AI Pro, Ultra, Code Assist
Standard/Enterprise, or an enterprise GCP project. See the
[Antigravity docs](https://antigravity.google/docs/cli-overview) for details.

### Does this plugin send data anywhere other than what `agy` sends?

No. The plugin runs `agy` locally over a Bash wrapper. The wrapper only reads
filesystem paths and your shell environment, and the one network call it can
cause is `agy models`, which `agy` makes itself. Your prompts go directly to
Google through `agy`'s normal channels.

### Which model did my alias actually use?

The wrapper prints it on stderr (`[wrapper] model: deep -> gemini-3.1-pro-high`).
That line exists because an alias intentionally tracks the catalogue rather
than a fixed version — without it, "newest Pro" would be unauditable.

### Can I keep using Antigravity outside this plugin?

Yes — the plugin uses your local install. Running `agy` directly in a
terminal keeps working exactly as before.

### Why a subagent instead of just a slash command?

Subagents in Claude Code can run in the background and report back when
finished. That is the workflow you want when you "hand this off to another
model and keep working" — which is the whole point of delegating to `agy`.

## Inspiration

Inspired by
[`openai/codex-plugin-cc`](https://github.com/openai/codex-plugin-cc), which
does the same thing for Codex. This plugin is intentionally smaller.

## Upstream

This repository is a fork of
[`simplybychris/antigravity-plugin-cc`](https://github.com/simplybychris/antigravity-plugin-cc)
by [simplybychris](https://detechtive.pl), who wrote the original plugin.
The install instructions above point at this fork; everything else is
upstream's work plus the 0.5.0 changes listed in the
[changelog](./CHANGELOG.md).

## License

[MIT](./LICENSE).
