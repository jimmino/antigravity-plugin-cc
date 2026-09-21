# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2026-09-20

### Added
- **`/agy:offload` — a read-only bulk read.** `agy` reads the files itself and
  a short cited answer comes back, so the bulk tokens land in its context
  window instead of Claude Code's. The run is held read-only with
  `--mode plan` and `--disable-slash-commands`, and carries a guard that bans
  writes and shell commands, skips `.env` files other than `.env.example`,
  treats file contents as data rather than instructions, and demands
  `path:line` citations or an explicit `UNKNOWN`.
- **Long context on stdin.** `--stdin` writes whatever is piped in to a temp
  file, adds it to the workspace and tells the model to read it first. The
  prompt argument travels on the command line, which Windows caps at ~32K
  characters, so a diff or a log excerpt never belongs there. Stdin is only
  read behind the flag: a wrapper that read it on spec would hang whenever it
  was launched with an inherited pipe nobody closes.
- **Telemetry and partial-answer detection.** Offloads parse
  `agy --output-format json` and print one line per call on stderr:
  `label | model | seconds | in= out=`. A turn cut short by an auto-denied
  shell command is reported as `PARTIAL` (the text is probably narration, not
  an answer) or `ABORTED`, with the remedy, instead of being passed off as a
  result.
- **A capacity fallback chain.** A 503/429 retries down a chain of *aliases*
  resolved against the live catalogue — no version is named in the script — and
  the answer is flagged as weaker than the one asked for. Timeouts are not
  retried: the task was too big, and the retry would get a smaller slice of the
  budget. The whole chain runs under a 540-second budget, below Claude Code's
  600-second tool kill.
- **Workspace roots.** `--dir` plus repeatable `--add-dir`, so one question can
  span sibling trees without pointing the workspace at their common parent —
  which is usually where the credentials live. The wrapper warns when a root
  carries a `*token*.json`, `*credential*.json` or `*secret*.json` at its top
  level or one below.
- **`/agy:fanout`** — several offload jobs in parallel, from repeated
  `--prompt` or a jobs file with per-job label, directory, model and extra
  roots. Mis-escaped Windows paths in the jobs file (`C:\Data\backend`, where
  `\b` is a valid JSON escape) are diagnosed instead of surfacing as a
  baffling "directory not found".
- **`/agy:second-opinion`** — an independent answer from a fresh Claude Code
  running headless with only `Read`, `Grep` and `Glob` in plan mode. It can
  search rather than brute-force read, and unlike a Claude model selected
  inside `agy` it will not reach for a shell, get auto-denied and hand back its
  opening narration as an answer.
- **`agy:offload` subagent** and the user-invocable **`agy:offloading` skill**,
  which carries the doctrine: offload semantics and never arithmetic, name the
  files, bound the answer, anchor the citations, treat the result as evidence
  rather than verdict, and never conclude absence without grepping for it.
- `/agy:setup` now reports `planMode`, `jsonOutput` and `offload` alongside the
  existing capability probes.

### Changed
- **`/agy:review` runs through the offload path.** The diff goes in as a
  context file rather than on the command line, where a real diff blows past
  the Windows argv cap; the run is read-only; untracked files are named so the
  model reads them off disk; and any `.env` other than `.env.example` is
  stripped from the diff before it leaves the machine, with a note saying
  which. Review also takes `-- <paths>` to scope the diff.
- `/agy:ask` is documented as what it is: a plain pass-through with no
  read-only guarantee, no guard and no telemetry.

### Fixed
- Python helpers now force LF on stdout. On Windows they emitted CRLF, so every
  value read back in the shell carried a trailing carriage return and compared
  unequal to what it plainly was. The answer files they write are now opened
  with `newline=""` too, for the same reason.
- **Backslashes lost in transit.** Earlier edits to the wrapper dropped
  backslashes, silently breaking two escapers. `/agy:setup`'s JSON no longer
  escaped `\` or newlines, so a Windows path or a multi-line version string
  made it unparseable. The legacy `settings.json` patch (the no-`python3` sed
  path) turned `/` and `&` in a model name into sed metacharacters.
- **Offload answers lost their indentation.** A per-line whitespace trim
  flattened every nested list and code block. Only a wholly blank answer is
  treated as empty now. The same applied to `/agy:second-opinion`.
- **`--budget` under 120s did nothing.** The retry floor also gated the first
  attempt, so the call exited 1 without ever running agy. The floor now
  applies to retries only.
- **On Windows the model was sent a context path it could not open.** agy is a
  native `.exe`. MSYS rewrites paths that stand as whole arguments, but not
  the `/tmp/...` path written into the prompt. That path now goes through
  `cygpath -m` when it is available.
- **`/agy:review -- <paths>` with no focus** took the first path as the focus
  and reviewed the whole diff. Untracked files are now scoped to the given
  paths, an untracked `.env` is never named for the model to read, and a diff
  that held only `.env` changes fails with an explanation instead of sending
  an empty review.
- The `agy --help` and catalogue caches were filled inside `$(...)`
  subshells, so they never persisted and every capability probe spawned `agy`
  again (seven times per offload). They are now filled once, in the calling
  shell.
- `/agy:fanout` passes each prompt after `--`, so a prompt that looks like a
  flag stays a prompt.
- `/agy:second-opinion` starts Claude in `--dir` rather than the caller's
  working directory. Grep and Glob search the working directory by default.
- An offload interrupted by a signal now exits. Before, the cleanup trap
  returned, and the loop could go on to the next model with its context file
  already deleted.
- Legacy settings patch: the sentinel is written before the backup, so a
  concurrent wrapper can no longer delete a fresh backup as "stale".

## [0.5.0] - 2026-09-20

### Changed
- **Model selection is now discovered at runtime instead of hardcoded.**
  `agy models` is the source of truth. The wrapper caches that catalogue
  (1h TTL, `AGY_MODELS_CACHE_TTL`) and resolves every `--model` value
  against it. No model name is compiled into the plugin any more.
- Built-in aliases now name a **family and effort** rather than a version:
  `flash` means "newest Flash at high effort", `deep` means "newest Pro at
  high effort". A new Gemini or Claude generation is picked up with no
  plugin release.
- `--model` is passed to `agy --model` natively, so a call no longer
  rewrites `~/.gemini/antigravity-cli/settings.json` at all. The old
  lock-and-patch path is kept purely as an automatic fallback for `agy`
  builds that predate the flag, detected from `agy --help`.
- An unrecognised `--model` value is now forwarded to `agy` verbatim
  (with a note on stderr) instead of failing with exit 64. This is what
  makes custom models from `customModelsConfig` usable, and it lets `agy`
  — which knows the real catalogue — produce the error.

### Fixed
- **Every `flash*` alias selected the wrong model.** They mapped to
  `Gemini 3.5 Flash (…)`, which no longer exists; because the old code
  wrote that name into `settings.json` rather than passing it as a flag,
  `agy` silently fell back to the saved default instead of erroring. A
  `--model flash` call was quietly served by `Gemini 3.1 Pro (High)` —
  slower and more expensive than requested, with no indication.
- `/agy:image`: when `agy`'s reply contained no image path, the fallback
  `grep` returned 1 and, under `set -o pipefail`, aborted the script
  before the "no image path was found" warning could print. The command
  died silently instead of explaining itself.
- `/agy:setup` referred to `/antigravity:ask` and friends; those commands
  were renamed to `/agy:*` in 0.3.0.
- The `agy --help` capability probes used `agy_help_text | grep -q`. `grep -q`
  exits on the first match, and under `set -o pipefail` the writer's SIGPIPE
  makes the pipeline report failure *even though the pattern matched*. A
  false negative there would have silently downgraded the wrapper to the
  settings.json-patching path against a modern `agy`. Only latent today —
  `agy --help` fits a pipe buffer — but the same pattern raced for real in
  the test harness on macOS. Replaced with here-strings; there is a
  regression test using a deliberately oversized help output.
- `/agy:image`'s image-extension guard had the same shape and could have
  rejected a perfectly good generated path. Now a `case`.

### Added
- `/agy:models [--refresh]` — list the models the installed `agy` build
  actually offers, with the alias mapping.
- `--effort low|medium|high` on `/agy:ask` and `/agy:review`, forwarded to
  `agy --effort` when the installed build supports it.
- Tier aliases `fast` / `balanced` / `deep`, plus `haiku`, `gemini` and
  `claude` family aliases.
- User-defined aliases in `~/.config/agy-plugin/aliases.conf`
  (`name = target`, chainable, cycle-detected). Read from user config
  only — never from the checked-out project, so a repository cannot
  redirect which model your prompts go to.
- `[wrapper] model: <alias> -> <id>` on stderr so an alias's choice stays
  auditable. Silence with `AGY_QUIET=1`.
- `nativeModelFlag` and `modelsSubcommand` in `/agy:setup`'s JSON, so the
  capability path in use is visible.
- A hermetic test suite (`bash tests/run-tests.sh`): 73 tests against a
  stub CLI, covering catalogue parsing and caching, alias resolution
  against a *hypothetical future catalogue*, user aliases, the legacy
  fallback, argument-injection safety, and image-path hardening. Runs in
  CI on Linux and macOS alongside shellcheck.

### Security
- `/agy:image` no longer copies an arbitrary path that the model printed
  after `IMAGE_PATH:` — only paths ending in an image extension are
  honoured, so a prompt-injected reply cannot use `--output` to copy an
  unrelated file.
- Catalogue output and alias-file values are stripped of control
  characters and never evaluated by the shell.
- The catalogue cache is written atomically into a `0700` directory.

## [0.4.1] - 2026-05-27

### Fixed
- `/agy:ask` and `/agy:image`: stop silent fallback / silent exit when
  a flag value is missing. `--model` (no value) used to die with exit 1
  and no message; `--model=` (empty) used to silently fall back to the
  default model. Both now print `error: --model requires a non-empty
  value`, the alias table, and a tip showing the current default. Same
  fix applied to `cmd_image` for `--name` and `--output`, plus `=` form
  support (`--name=foo`, `--output=path`).
- `/agy:help`: prints the wrapper's stdout verbatim in the reply as a
  code block instead of leaving it as a collapsed tool result.

## [0.4.0] - 2026-05-26

### Added
- `/agy:help` — single discoverable index of every `/agy:*` command,
  supported `--model` aliases, and the canonical model names. The wrapper
  is the single source of truth; the slash command just prints its
  `help` subcommand verbatim.
- `--model <alias>` on `/agy:ask`, `/agy:delegate`, and `/agy:research`.
  Per-call model selection: the wrapper takes a lock on
  `~/.gemini/antigravity-cli/settings.json`, atomically swaps in the
  requested model, invokes `agy`, then restores the original on exit
  (including SIGINT / SIGTERM / SIGHUP).
- Alias table: `flash-low`, `flash-medium` (`flash-med`), `flash`
  (`flash-high`), `pro-low`, `pro` (`pro-high`), `sonnet` (`claude-sonnet`),
  `opus` (`claude-opus`), `gpt-oss` (`gpt-oss-120b`). Canonical TUI strings
  (e.g. `"Claude Opus 4.6 (Thinking)"`) are accepted verbatim.
- `agy-run.sh` gains `cmd_help`, `resolve_model_alias`,
  `validate_settings_file`, `with_settings_lock`, `with_model_override`,
  and `restore_orphaned_backup` (cleans up after a `SIGKILL`ed previous
  run on the next invocation).

### Fixed
- Removed stale references to `agy -m <model>` from `runner.md`,
  `commands/delegate.md`, `commands/research.md`, and
  `skills/antigravity-cli/SKILL.md`. `agy` v1.0.2 has no `-m` / `--model`
  CLI flag — model selection is now correctly handled by the wrapper.
  Users who tried `--model` in 0.3.x and earlier got failures; 0.4.0
  makes the documented behavior work.
- Removed references to `~/.config/antigravity/config.toml` from the
  root README and `commands/delegate.md`. `agy` does not read that path;
  its actual settings live in `~/.gemini/antigravity-cli/settings.json`.
- Dropped the `--output-format json` mention from `SKILL.md` — that flag
  does not exist either.

### Internal
- `_patch_model_field` writes via `python3 -c "json.dump(...)"` when
  available, falling back to a narrow `sed` regex that targets only
  single-line `"model"` entries. Atomic `mv` from a tmpfile is used in
  both paths.
- `mkdir`-based portable lockfile (no `flock(1)` dependency — macOS has
  none by default). Dead-holder detection via `kill -0` prevents
  deadlocks after `SIGKILL`.
- Wrapper now has a sourcing guard so individual functions can be unit
  tested without triggering the dispatch.

## [0.3.1] - 2026-05-24

### Fixed
- `/agy:image` now extracts the saved image path deterministically. The
  wrapper instructs `agy` to end its reply with an `IMAGE_PATH:` marker line
  and parses it; a regex scrape of absolute `*.png/.jpg/.jpeg/.webp` paths
  in the reply is kept as a fallback. Previously the path was only printed
  when `agy` happened to mention it in its natural-language reply.

## [0.3.0] - 2026-05-24

### Added
- `/agy:research` — delegate a deep-research investigation. Wraps the
  topic in a structured prompt (background, key findings, caveats,
  sources) and routes through the `agy:runner` subagent. Defaults toward
  background execution for long jobs.
- `/agy:image` — generate an image with `agy`'s built-in `generate_image`
  tool (Imagen under the hood). Optional `--name <slug>` for the saved
  filename and `--output <path>` to copy the generated PNG next to your
  project.
- `agy-run.sh` gains an `image` subcommand that builds the right prompt
  for `agy`'s native image tool and optionally copies the result.

## [0.2.0] - 2026-05-24

### Changed
- **Breaking:** plugin renamed `antigravity` → `agy`, so slash commands move
  from `/antigravity:*` to `/agy:*`. Install command is now
  `/plugin install agy@antigravity-cc`.
- Subagent renamed from `agy` to `runner`; full identifier is `agy:runner`
  (avoids the awkward `agy:agy` form).

## [0.1.0] - 2026-05-24

### Added
- Initial plugin scaffold and Claude Code marketplace manifest.
- `/agy:setup` — verify `agy` install and authentication; offer to install
  if missing.
- `/agy:ask` — run a one-shot `agy -p` prompt and return its output
  verbatim.
- `/agy:delegate` — hand a task to the `agy:runner` subagent; supports
  `--background` and `--model`.
- `/agy:review` — pipe the current `git diff` into `agy` for review.
- `agy:runner` subagent — thin forwarding wrapper around the Antigravity
  CLI.
- `antigravity-cli` internal skill — runtime contract for invoking `agy`
  from the subagent.
- `agy-run.sh` — bash wrapper that handles binary discovery, auth
  detection, and exit codes.
