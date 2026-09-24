#!/usr/bin/env bash
# Hermetic test suite for plugins/agy/scripts/agy-run.sh.
# No network, no real `agy`, no quota spend — everything runs against
# tests/fixtures/fake-agy in a throwaway HOME.
#
# Usage: bash tests/run-tests.sh [name-filter]

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
WRAPPER="$REPO_ROOT/plugins/agy/scripts/agy-run.sh"
FIXTURES="$TESTS_DIR/fixtures"
FILTER="${1:-}"

# Captured once: individual tests mutate PATH/HOME, so every sandbox is built
# from these rather than from whatever the previous test left behind.
ORIG_PATH="$PATH"
ORIG_HOME="$HOME"

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

red()   { printf '\033[31m%s\033[0m' "$1"; }
green() { printf '\033[32m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }

# ------------------------------------------------------------ sandboxing --
# Each test gets its own HOME so caches, settings and aliases never leak
# between cases or touch the developer's real ~/.gemini.
SANDBOX=""
setup_sandbox() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agy-test.XXXXXX")"
  mkdir -p "$SANDBOX/home/.gemini/antigravity-cli" "$SANDBOX/bin" "$SANDBOX/cache" "$SANDBOX/config"
  cp "$FIXTURES/fake-agy" "$SANDBOX/bin/agy"
  chmod +x "$SANDBOX/bin/agy"
  cat > "$SANDBOX/home/.gemini/antigravity-cli/settings.json" <<'JSON'
{
  "model": "Gemini 3.1 Pro (High)",
  "allowNonWorkspaceAccess": true
}
JSON
  export HOME="$SANDBOX/home"
  export PATH="$SANDBOX/bin:$ORIG_PATH"
  export AGY_HOME="$SANDBOX/home/.gemini/antigravity-cli"
  export AGY_SETTINGS_FILE="$AGY_HOME/settings.json"
  export AGY_PLUGIN_CACHE_DIR="$SANDBOX/cache"
  export AGY_PLUGIN_CONFIG_DIR="$SANDBOX/config"
  export AGY_ALIASES_FILE="$SANDBOX/config/aliases.conf"
  export FAKE_AGY_CATALOG="$FIXTURES/catalog-current.tsv"
  export FAKE_AGY_ARGV_LOG="$SANDBOX/argv.log"
  export FAKE_AGY_MODE="new"
  export ANTIGRAVITY_API_KEY="test-key-not-real"
  unset FAKE_AGY_JSON FAKE_AGY_MODELS_FAIL FAKE_AGY_EXIT FAKE_AGY_SETTINGS FAKE_AGY_STDOUT 2>/dev/null || true
  # Tests export these; without clearing them a knob set by one case
  # silently steers the next one.
  unset FAKE_AGY_RESPONSE FAKE_AGY_EMPTY FAKE_AGY_STATUS FAKE_AGY_IN FAKE_AGY_OUT 2>/dev/null || true
  unset FAKE_AGY_DENIED_COMMAND FAKE_AGY_STDERR FAKE_AGY_FAIL_MODELS FAKE_AGY_ARGV_APPEND 2>/dev/null || true
  unset FAKE_AGY_CTX_COPY FAKE_CLAUDE_PWD FAKE_TIMEOUT_LOG 2>/dev/null || true
  unset FAKE_CLAUDE_ARGV FAKE_CLAUDE_STDIN FAKE_CLAUDE_RESULT FAKE_CLAUDE_ERROR FAKE_CLAUDE_HELP 2>/dev/null || true
  unset AGY_FORCE_LEGACY_MODEL AGY_QUIET AGY_ALLOW_PREVIEW 2>/dev/null || true
  # The bridge installs into HOME and finds the plugin through
  # CLAUDE_CONFIG_DIR, so neither may point at the developer's real ones.
  unset AGY_BRIDGE_DIR AGY_BRIDGE_WINDOWS AGY_BRIDGE_ARGV AGY_RUN_SH CLAUDE_CONFIG_DIR 2>/dev/null || true
  unset AGY_ASK_CLAUDE_TIMEOUT AGY_SECOND_OPINION_TIMEOUT 2>/dev/null || true
  # Set when the suite runs from a Claude Code hook or tool call. The wrapper
  # prefers it to $PWD, which would point review and offload at the real repo.
  unset CLAUDE_PROJECT_DIR 2>/dev/null || true
  export AGY_MODELS_CACHE_TTL=3600
}

teardown_sandbox() {
  if [ -n "$SANDBOX" ]; then rm -rf "$SANDBOX"; fi
  SANDBOX=""
  export PATH="$ORIG_PATH"
  export HOME="$ORIG_HOME"
}

# ------------------------------------------------------------- assertions --
TEST_ERRORS=()

fail_msg() { TEST_ERRORS+=("$1"); }

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" != "$actual" ]; then
    fail_msg "${msg:-values differ}
      expected: [$expected]
      actual:   [$actual]"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) : ;;
    *) fail_msg "${msg:-missing substring}
      looking for: [$needle]
      in:          [$(printf '%s' "$haystack" | head -c 600)]" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) fail_msg "${msg:-unexpected substring}
      should not contain: [$needle]
      in:                 [$(printf '%s' "$haystack" | head -c 600)]" ;;
  esac
}

# ------------------------------------------------------------- utilities --
# Run the wrapper as a subprocess. Sets OUT / ERR / RC.
OUT=""; ERR=""; RC=0
run_wrapper() {
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  RC=0
  bash "$WRAPPER" "$@" >"$outf" 2>"$errf" || RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

argv_log() { cat "$FAKE_AGY_ARGV_LOG" 2>/dev/null || true; }

# Exact-line match against the recorded argv.
#
# Reads the file directly instead of piping into `grep -Fxq`: grep exits on
# the first match, and with `set -o pipefail` the writer's SIGPIPE makes the
# pipeline report failure even on a match. That raced on macOS and failed
# whichever assertions happened to lose.
argv_has() {
  local needle="$1"
  [ -f "${FAKE_AGY_ARGV_LOG:-}" ] || return 1
  grep -Fxq -- "$needle" "$FAKE_AGY_ARGV_LOG"
}

settings_model() {
  grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$AGY_SETTINGS_FILE" \
    | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' | head -n1
}

it() {
  local name="$1"; shift
  if [ -n "$FILTER" ] && ! grep -qi -- "$FILTER" <<<"$name"; then
    SKIP=$((SKIP + 1)); return 0
  fi
  setup_sandbox
  TEST_ERRORS=()
  "$@" || fail_msg "test function returned non-zero"
  if [ "${#TEST_ERRORS[@]}" -eq 0 ]; then
    PASS=$((PASS + 1))
    printf '  %s %s\n' "$(green ok)" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    printf '  %s %s\n' "$(red FAIL)" "$name"
    local e
    for e in "${TEST_ERRORS[@]}"; do
      printf '       %s\n' "$e"
    done
  fi
  teardown_sandbox
}

# ============================================================== test cases ==

# ---------------------------------------------------- catalogue discovery --
t_catalogue_parses_tsv() {
  run_wrapper models --ids
  assert_eq 0 "$RC" "models --ids should succeed"
  assert_contains "$OUT" "gemini-3.8-flash-high" "catalogue should list current ids"
  assert_contains "$OUT" "claude-opus-4-6-thinking" "catalogue should list claude ids"
  assert_eq 14 "$(printf '%s\n' "$OUT" | grep -c .)" "all 14 fixture models parsed"
}

t_catalogue_strips_spinner_noise() {
  run_wrapper models --ids
  assert_not_contains "$OUT" "Fetching" "progress text must not leak into the catalogue"
  assert_not_contains "$OUT" $'\033' "escape sequences must be stripped"
}

t_catalogue_writes_cache() {
  run_wrapper models --ids
  [ -f "$AGY_PLUGIN_CACHE_DIR/models.tsv" ] || fail_msg "cache file was not written"
  assert_contains "$(cat "$AGY_PLUGIN_CACHE_DIR/models.tsv")" "gemini-3.8-flash-high" "cache holds the catalogue"
}

t_catalogue_uses_cache_when_fresh() {
  run_wrapper models --ids                       # populates cache
  export FAKE_AGY_MODELS_FAIL=1                  # any refetch would now fail
  run_wrapper models --ids
  assert_eq 0 "$RC" "fresh cache should be served without refetching"
  assert_contains "$OUT" "gemini-3.8-flash-high" "cached ids still returned"
}

t_catalogue_refresh_bypasses_cache() {
  run_wrapper models --ids
  export FAKE_AGY_CATALOG="$FIXTURES/catalog-future.tsv"
  run_wrapper models --refresh --ids
  assert_contains "$OUT" "gemini-4.0-flash-high" "--refresh must refetch"
  assert_not_contains "$OUT" "gemini-3.8-flash-high" "stale entries must be gone after refresh"
}

t_catalogue_falls_back_to_stale_cache_offline() {
  run_wrapper models --ids                       # populate
  export AGY_MODELS_CACHE_TTL=0                  # force "expired"
  export FAKE_AGY_MODELS_FAIL=1                  # and make the network fail
  run_wrapper models --ids
  assert_eq 0 "$RC" "stale cache should still serve when offline"
  assert_contains "$OUT" "gemini-3.8-flash-high" "stale cache content returned"
}

t_catalogue_prefers_json_when_supported() {
  export FAKE_AGY_JSON=1
  run_wrapper models --ids
  assert_eq 0 "$RC" "json catalogue path should work"
  assert_contains "$OUT" "gemini-3.8-flash-high" "json path yields same ids"
  assert_eq 14 "$(printf '%s\n' "$OUT" | grep -c .)" "json path parses every model"
}

t_catalogue_absent_reports_clearly() {
  export FAKE_AGY_MODE="old-no-models"
  export FAKE_AGY_MODELS_FAIL=1
  run_wrapper models --ids
  assert_eq 1 "$RC" "no catalogue should exit 1"
  assert_contains "$ERR" "no model catalogue available" "error explains the situation"
}

# --------------------------------------------- alias resolution (current) --
t_alias_flash_picks_newest_flash() {
  run_wrapper ask --model flash "hi"
  assert_eq 0 "$RC" "ask should succeed"
  argv_has "gemini-3.8-flash-high" || fail_msg "flash must resolve to the newest high-effort Flash; argv was: $(argv_log | tr '\n' ' ')"
}

t_alias_flash_never_resolves_to_retired_model() {
  run_wrapper ask --model flash "hi"
  assert_not_contains "$(argv_log)" "3.5" "the retired Gemini 3.5 Flash must never be selected"
}

t_alias_fast_is_low_effort_flash() {
  run_wrapper ask --model fast "hi"
  argv_has "gemini-3.8-flash-low" || fail_msg "fast => newest low-effort Flash; argv: $(argv_log | tr '\n' ' ')"
}

t_alias_balanced_is_high_effort_flash() {
  run_wrapper ask --model balanced "hi"
  argv_has "gemini-3.8-flash-high" || fail_msg "balanced => newest high-effort Flash"
}

t_alias_deep_is_high_effort_pro() {
  run_wrapper ask --model deep "hi"
  argv_has "gemini-3.1-pro-high" || fail_msg "deep => newest high-effort Pro"
}

t_alias_flash_medium() {
  run_wrapper ask --model flash-medium "hi"
  argv_has "gemini-3.8-flash-medium" || fail_msg "flash-medium => newest medium Flash"
}

t_alias_pro_low() {
  run_wrapper ask --model pro-low "hi"
  argv_has "gemini-3.1-pro-low" || fail_msg "pro-low => low-effort Pro"
}

t_alias_opus() {
  run_wrapper ask --model opus "hi"
  argv_has "claude-opus-4-6-thinking" || fail_msg "opus => the Claude Opus entry"
}

t_alias_sonnet() {
  run_wrapper ask --model sonnet "hi"
  argv_has "claude-sonnet-4-6" || fail_msg "sonnet => the Claude Sonnet entry"
}

t_alias_gpt_oss() {
  run_wrapper ask --model gpt-oss "hi"
  argv_has "gpt-oss-120b-medium" || fail_msg "gpt-oss => the GPT-OSS entry"
}

t_alias_is_case_insensitive() {
  run_wrapper ask --model FLASH "hi"
  argv_has "gemini-3.8-flash-high" || fail_msg "aliases must be case-insensitive"
}

t_alias_resolution_is_announced() {
  run_wrapper ask --model flash "hi"
  assert_contains "$ERR" "flash -> gemini-3.8-flash-high" "the concrete model must be auditable on stderr"
}

t_alias_announcement_can_be_silenced() {
  export AGY_QUIET=1
  run_wrapper ask --model flash "hi"
  assert_not_contains "$ERR" "[wrapper] model:" "AGY_QUIET=1 suppresses the note"
}

# -------------------------------------------- future-proofing (the point) --
# These run against a catalogue that does not exist yet: new Gemini and Claude
# generations, a retired family, and a two-digit minor version. Nothing in the
# wrapper is allowed to need editing for them to resolve correctly.
t_future_flash_follows_new_generation() {
  export FAKE_AGY_CATALOG="$FIXTURES/catalog-future.tsv"
  run_wrapper ask --model flash "hi"
  argv_has "gemini-4.0-flash-high" || fail_msg "flash must follow to Gemini 4.0 with no plugin change; argv: $(argv_log | tr '\n' ' ')"
}

t_future_pro_follows_new_generation() {
  export FAKE_AGY_CATALOG="$FIXTURES/catalog-future.tsv"
  run_wrapper ask --model deep "hi"
  argv_has "gemini-5.2-pro-high" || fail_msg "deep must follow to Gemini 5.2 Pro"
}

t_future_opus_follows_new_generation() {
  export FAKE_AGY_CATALOG="$FIXTURES/catalog-future.tsv"
  run_wrapper ask --model opus "hi"
  argv_has "claude-opus-5-thinking" || fail_msg "opus must follow to Claude Opus 5"
}

t_future_new_family_resolves() {
  # `haiku` matches nothing in today's catalogue but should work the day it ships.
  export FAKE_AGY_CATALOG="$FIXTURES/catalog-future.tsv"
  run_wrapper ask --model haiku "hi"
  argv_has "claude-haiku-5-fast" || fail_msg "a family absent today must resolve once it appears"
}

t_future_version_ordering_is_numeric() {
  # 3.10 > 3.9 numerically but not lexically; 4.0 must still beat both.
  printf 'gemini-3.9-flash-high\tGemini 3.9 Flash (High)\ngemini-3.10-flash-high\tGemini 3.10 Flash (High)\n' \
    > "$SANDBOX/two.tsv"
  export FAKE_AGY_CATALOG="$SANDBOX/two.tsv"
  run_wrapper ask --model flash "hi"
  argv_has "gemini-3.10-flash-high" || fail_msg "3.10 must sort above 3.9; argv: $(argv_log | tr '\n' ' ')"
}

t_future_newest_ignores_locale_collation() {
  # A UTF-8 collation skips punctuation, so a bare `sort` compared
  # "gemini3flash" with "gemini31flash" and put 3 above 3.1. Git Bash and
  # Ubuntu CI run with a codepoint locale, which hid it; force a real one.
  local loc="" l
  for l in en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -qx "$l"; then loc="$l"; break; fi
  done
  printf 'gemini-3-flash-high\tGemini 3 Flash (High)\ngemini-3.1-flash-high\tGemini 3.1 Flash (High)\n' \
    > "$SANDBOX/two.tsv"
  export FAKE_AGY_CATALOG="$SANDBOX/two.tsv"
  ( if [ -n "$loc" ]; then export LC_ALL="$loc"; fi
    bash "$WRAPPER" ask --model flash "hi" ) >/dev/null 2>&1
  argv_has "gemini-3.1-flash-high" || fail_msg "3.1 must beat 3 under ${loc:-the default} locale; argv: $(argv_log | tr '\n' ' ')"
}

t_future_claude_picks_newest_version_not_name() {
  # Claude ids put the family before the version; sorting the whole id made
  # `claude` mean "alphabetically last family", so Sonnet 4.6 beat Opus 5.
  printf 'claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\nclaude-opus-5-thinking\tClaude Opus 5 (Thinking)\n' \
    > "$SANDBOX/claude.tsv"
  export FAKE_AGY_CATALOG="$SANDBOX/claude.tsv"
  run_wrapper ask --model claude "hi"
  argv_has "claude-opus-5-thinking" || fail_msg "claude => the newest Claude version; argv: $(argv_log | tr '\n' ' ')"
}

t_future_gemini_prefers_high_effort_on_a_tie() {
  # Every newest-version Gemini carries an effort suffix; a lexical tie-break
  # picked "medium" only because it sorts after "high".
  run_wrapper ask --model gemini "hi"
  argv_has "gemini-3.8-flash-high" || fail_msg "gemini => newest version at high effort; argv: $(argv_log | tr '\n' ' ')"
}

t_future_unknown_model_is_passed_through() {
  # agy knows about custom models the wrapper cannot enumerate, so an
  # unrecognised name must reach agy rather than being rejected locally.
  run_wrapper ask --model "my-private-endpoint-v2" "hi"
  assert_eq 0 "$RC" "unknown models must not be rejected by the wrapper"
  argv_has "my-private-endpoint-v2" || fail_msg "unknown model must be forwarded verbatim"
  assert_contains "$ERR" "passing it to agy as-is" "pass-through should be noted"
}

# ------------------------------------- catalogue shape changes (hardening) --
# Writes a TSV catalogue from "id|label" lines and points fake-agy at it.
use_catalog() {
  printf '%s\n' "$@" | tr '|' '\t' > "$SANDBOX/cat.tsv"
  export FAKE_AGY_CATALOG="$SANDBOX/cat.tsv"
}

t_effort_suffix_renamed_refuses_to_guess() {
  # If low/high became lite/max, "newest Flash" alone would give `fast` and
  # `balanced` the same model. That must be an error, not a silent pick.
  use_catalog 'gemini-4.0-flash-lite|Gemini 4.0 Flash (Lite)' \
              'gemini-4.0-flash-max|Gemini 4.0 Flash (Max)'
  run_wrapper ask --model fast "hi"
  assert_eq 64 "$RC" "unreadable effort variants are a usage error"
  assert_contains "$ERR" "will not guess" "error explains the refusal"
  assert_contains "$ERR" "gemini-4.0-flash-lite" "error lists the candidates"
  assert_contains "$ERR" "gemini-4.0-flash-max" "error lists every candidate"
  assert_not_contains "$(argv_log)" "--model" "no prompt may run"
}

t_effort_single_unsuffixed_model_is_used_with_note() {
  # One model and no variants: effort has nothing to choose between.
  use_catalog 'gemini-5-flash|Gemini 5 Flash'
  run_wrapper ask --model fast "hi"
  assert_eq 0 "$RC" "a lone model should still resolve"
  argv_has "gemini-5-flash" || fail_msg "fast => the only Flash; argv: $(argv_log | tr '\n' ' ')"
  assert_contains "$ERR" "has no effort variants" "the ignored effort is reported"
}

t_effort_older_generation_is_flagged() {
  # The new generation renamed its variants; the old one still has `-low`.
  # Right effort beats newest, but the alias must say it fell behind.
  use_catalog 'gemini-4.0-flash-lite|Gemini 4.0 Flash (Lite)' \
              'gemini-4.0-flash-max|Gemini 4.0 Flash (Max)' \
              'gemini-3.8-flash-low|Gemini 3.8 Flash (Low)' \
              'gemini-3.8-flash-high|Gemini 3.8 Flash (High)'
  run_wrapper ask --model fast "hi"
  assert_eq 0 "$RC" "a real low-effort model still resolves"
  argv_has "gemini-3.8-flash-low" || fail_msg "fast => newest real low-effort Flash; argv: $(argv_log | tr '\n' ' ')"
  assert_contains "$ERR" "has no 'low' variant" "falling a generation behind is reported"
}

t_effort_current_catalogue_is_silent() {
  run_wrapper ask --model fast "hi"
  assert_not_contains "$ERR" "[wrapper] note:" "a normal resolution needs no note"
}

t_preview_is_skipped_by_aliases() {
  use_catalog 'gemini-4.0-flash-preview-high|Gemini 4.0 Flash Preview (High)' \
              'gemini-3.8-flash-high|Gemini 3.8 Flash (High)'
  run_wrapper ask --model flash "hi"
  argv_has "gemini-3.8-flash-high" || fail_msg "flash must stay on the newest stable Flash; argv: $(argv_log | tr '\n' ' ')"
}

t_preview_marked_only_in_label_is_skipped() {
  use_catalog 'gemini-4.0-flash-high|Gemini 4.0 Flash (High, Preview)' \
              'gemini-3.8-flash-high|Gemini 3.8 Flash (High)'
  run_wrapper ask --model flash "hi"
  argv_has "gemini-3.8-flash-high" || fail_msg "a preview flagged only in the label is still a preview; argv: $(argv_log | tr '\n' ' ')"
}

t_experimental_is_skipped_by_aliases() {
  use_catalog 'gemini-exp-9999|Gemini Experimental' \
              'gemini-3.8-flash-high|Gemini 3.8 Flash (High)'
  run_wrapper ask --model gemini "hi"
  argv_has "gemini-3.8-flash-high" || fail_msg "gemini must not land on an experimental id; argv: $(argv_log | tr '\n' ' ')"
}

t_preview_filter_matches_whole_words_only() {
  # "express" contains "exp" but is not an experiment.
  use_catalog 'gemini-9-express|Gemini 9 Express'
  run_wrapper ask --model gemini "hi"
  argv_has "gemini-9-express" || fail_msg "only whole-word markers count; argv: $(argv_log | tr '\n' ' ')"
}

t_preview_allowed_by_env() {
  use_catalog 'gemini-4.0-flash-preview-high|Gemini 4.0 Flash Preview (High)' \
              'gemini-3.8-flash-high|Gemini 3.8 Flash (High)'
  export AGY_ALLOW_PREVIEW=1
  run_wrapper ask --model flash "hi"
  argv_has "gemini-4.0-flash-preview-high" || fail_msg "AGY_ALLOW_PREVIEW=1 lets aliases pick previews; argv: $(argv_log | tr '\n' ' ')"
}

t_preview_only_family_errors_with_hint() {
  use_catalog 'claude-haiku-6-preview|Claude Haiku 6 (Preview)' \
              'gemini-3.8-flash-high|Gemini 3.8 Flash (High)'
  run_wrapper ask --model haiku "hi"
  assert_eq 64 "$RC" "a preview-only family is a usage error"
  assert_contains "$ERR" "claude-haiku-6-preview" "error names the preview"
  assert_contains "$ERR" "AGY_ALLOW_PREVIEW=1" "error says how to opt in"
}

t_preview_exact_id_is_honoured() {
  use_catalog 'gemini-4.0-flash-preview-high|Gemini 4.0 Flash Preview (High)' \
              'gemini-3.8-flash-high|Gemini 3.8 Flash (High)'
  run_wrapper ask --model gemini-4.0-flash-preview-high "hi"
  argv_has "gemini-4.0-flash-preview-high" || fail_msg "an exact preview id must still work"
}

t_exact_id_resolves_without_warning() {
  run_wrapper ask --model gemini-3.7-flash-low "hi"
  argv_has "gemini-3.7-flash-low" || fail_msg "an exact id must be honoured"
  assert_not_contains "$ERR" "passing it to agy as-is" "a catalogue id is not a pass-through"
}

t_exact_display_name_resolves_to_id() {
  run_wrapper ask --model "Gemini 3.7 Flash (Low)" "hi"
  argv_has "gemini-3.7-flash-low" || fail_msg "a display name must map to its id; argv: $(argv_log | tr '\n' ' ')"
}

t_display_name_is_case_insensitive() {
  run_wrapper ask --model "gemini 3.7 flash (low)" "hi"
  argv_has "gemini-3.7-flash-low" || fail_msg "display-name match should ignore case"
}

t_empty_model_exits_64() {
  run_wrapper ask --model "" "hi"
  assert_eq 64 "$RC" "empty --model is a usage error"
  assert_contains "$ERR" "requires a non-empty value" "error names the problem"
  assert_contains "$ERR" "Available models" "error shows the live list"
}

t_model_table_is_live_not_hardcoded() {
  export FAKE_AGY_CATALOG="$FIXTURES/catalog-future.tsv"
  run_wrapper models
  assert_contains "$OUT" "gemini-4.0-flash-high" "table reflects the live catalogue"
  assert_not_contains "$OUT" "Gemini 3.5 Flash" "no retired model may be hardcoded in the table"
}

t_help_contains_no_hardcoded_model_versions() {
  run_wrapper help
  assert_eq 0 "$RC" "help should succeed"
  assert_contains "$OUT" "/agy:models" "help documents the models command"
  assert_contains "$OUT" "gemini-3.8-flash-high" "help shows live catalogue entries"
}

# ------------------------------------------------------------ user aliases --
t_user_alias_resolves() {
  printf 'cheap = flash-low\n' > "$AGY_ALIASES_FILE"
  run_wrapper ask --model cheap "hi"
  argv_has "gemini-3.8-flash-low" || fail_msg "user alias should chain to a builtin"
}

t_user_alias_can_pin_exact_id() {
  printf 'pinned: gemini-3.6-flash-medium\n' > "$AGY_ALIASES_FILE"
  run_wrapper ask --model pinned "hi"
  argv_has "gemini-3.6-flash-medium" || fail_msg "user alias should pin an exact id"
}

t_user_alias_accepts_bare_whitespace_form() {
  printf 'wide   gemini-3.1-pro-low\n' > "$AGY_ALIASES_FILE"
  run_wrapper ask --model wide "hi"
  argv_has "gemini-3.1-pro-low" || fail_msg "whitespace-separated alias form should work"
}

t_user_alias_shadows_builtin() {
  printf 'flash = gemini-3.6-flash-low\n' > "$AGY_ALIASES_FILE"
  run_wrapper ask --model flash "hi"
  argv_has "gemini-3.6-flash-low" || fail_msg "a user alias must win over the builtin of the same name"
}

t_user_alias_ignores_comments_and_junk() {
  cat > "$AGY_ALIASES_FILE" <<'CONF'
# a comment
   # indented comment

this line has no separator and is not an alias
bad!name = flash-low
good = pro-low          # trailing comment
CONF
  run_wrapper ask --model good "hi"
  argv_has "gemini-3.1-pro-low" || fail_msg "valid alias should survive junk around it"
}

t_user_alias_loop_is_detected() {
  printf 'a = b\nb = a\n' > "$AGY_ALIASES_FILE"
  run_wrapper ask --model a "hi"
  assert_eq 64 "$RC" "an alias cycle must exit 64, not hang"
  assert_contains "$ERR" "loop detected" "error names the cycle"
}

t_user_alias_strips_control_characters() {
  printf 'evil = gemini-3.6-flash-low\x1b[31m\n' > "$AGY_ALIASES_FILE"
  run_wrapper ask --model evil "hi"
  assert_not_contains "$(argv_log)" $'\033' "control characters must never reach agy's argv"
}

t_project_local_alias_file_is_ignored() {
  # A checked-out repo must not be able to redirect the model.
  mkdir -p "$SANDBOX/project/.agy-plugin"
  printf 'flash = gpt-oss-120b-medium\n' > "$SANDBOX/project/.agy-plugin/aliases.conf"
  printf 'flash = gpt-oss-120b-medium\n' > "$SANDBOX/project/aliases.conf"
  ( cd "$SANDBOX/project" && bash "$WRAPPER" ask --model flash "hi" >/dev/null 2>&1 )
  argv_has "gemini-3.8-flash-high" || fail_msg "project-local alias files must be ignored; argv: $(argv_log | tr '\n' ' ')"
}

# ----------------------------------------------------------------- effort --
t_effort_is_forwarded() {
  run_wrapper ask --model flash --effort low "hi"
  argv_has "--effort" || fail_msg "--effort should be forwarded"
  argv_has "low" || fail_msg "--effort value should be forwarded"
}

t_effort_without_model_is_forwarded() {
  run_wrapper ask --effort high "hi"
  argv_has "--effort" || fail_msg "--effort alone should still reach agy"
  assert_not_contains "$(argv_log)" "--model" "no --model means none is sent"
}

t_effort_rejects_bad_value() {
  run_wrapper ask --effort turbo "hi"
  assert_eq 64 "$RC" "invalid effort is a usage error"
  assert_contains "$ERR" "invalid --effort" "error names the flag"
}

t_effort_rejects_missing_value() {
  run_wrapper ask --effort
  assert_eq 64 "$RC" "bare --effort is a usage error"
}

t_effort_skipped_on_builds_without_the_flag() {
  export FAKE_AGY_MODE="no-effort"
  run_wrapper ask --model flash --effort low "hi"
  assert_eq 0 "$RC" "an old build should still run"
  assert_not_contains "$(argv_log)" "--effort" "--effort must not be sent to a build that lacks it"
  assert_contains "$ERR" "no --effort flag" "the user is told it was dropped"
}

# ------------------------------------------------------------- invocation --
t_native_model_flag_is_used() {
  run_wrapper ask --model flash "hello world"
  argv_has "--model" || fail_msg "native --model should be used"
  argv_has "-p" || fail_msg "prompt should be passed with -p"
  argv_has "hello world" || fail_msg "prompt text should arrive intact"
}

t_no_model_means_no_model_flag() {
  run_wrapper ask "hello"
  assert_not_contains "$(argv_log)" "--model" "without --model the user's default must be left alone"
}

t_settings_file_untouched_on_native_path() {
  local before; before="$(cat "$AGY_SETTINGS_FILE")"
  run_wrapper ask --model opus "hi"
  assert_eq "$before" "$(cat "$AGY_SETTINGS_FILE")" "the native path must not rewrite settings.json"
}

t_extra_args_forwarded_after_prompt() {
  run_wrapper ask --model flash "hi" --sandbox --print-timeout 10m
  argv_has "--sandbox" || fail_msg "agy-native flags must pass through"
  argv_has "10m" || fail_msg "agy-native flag values must pass through"
}

t_prompt_with_shell_metacharacters_is_safe() {
  local nasty='hi $(touch /tmp/agy-pwned-$$) `id` ; rm -rf / && echo x'
  run_wrapper ask --model flash "$nasty"
  assert_eq 0 "$RC" "a metacharacter-laden prompt should run normally"
  argv_has "$nasty" || fail_msg "the prompt must reach agy byte-for-byte, unexpanded"
  if [ -e "/tmp/agy-pwned-$$" ]; then fail_msg "command substitution in the prompt was executed"; fi
}

t_model_name_starting_with_dash_is_safe() {
  run_wrapper ask --model "--dangerously-skip-permissions" "hi"
  # It must be sent as the *value* of --model, never as its own flag.
  local joined; joined="$(argv_log)"
  assert_contains "$joined" "--model" "--model should still be present"
  local idx; idx="$(printf '%s\n' "$joined" | grep -n -- '--model' | head -n1 | cut -d: -f1)"
  local nxt;  nxt="$(printf '%s\n' "$joined" | sed -n "$((idx + 1))p")"
  assert_eq "--dangerously-skip-permissions" "$nxt" "a dash-leading model must stay a value, not become a flag"
}

t_missing_prompt_exits_64() {
  run_wrapper ask
  assert_eq 64 "$RC" "no prompt is a usage error"
  assert_contains "$ERR" "requires a prompt" "error names the problem"
}

t_agy_exit_code_is_propagated() {
  export FAKE_AGY_EXIT=3
  run_wrapper ask --model flash "hi"
  assert_eq 3 "$RC" "agy's exit code must reach the caller"
}

t_unknown_subcommand_exits_64() {
  run_wrapper frobnicate
  assert_eq 64 "$RC" "unknown subcommand is a usage error"
}

# --------------------------------------------------- legacy fallback path --
t_legacy_path_patches_and_restores_settings() {
  export AGY_FORCE_LEGACY_MODEL=1
  export FAKE_AGY_SETTINGS="$AGY_SETTINGS_FILE"
  local before; before="$(cat "$AGY_SETTINGS_FILE")"
  run_wrapper ask --model opus "hi"
  assert_eq 0 "$RC" "legacy path should succeed"
  assert_contains "$OUT" "SETTINGS_MODEL_DURING_RUN=Claude Opus 4.6 (Thinking)" \
    "settings.json must hold the requested model while agy runs"
  assert_eq "Gemini 3.1 Pro (High)" "$(settings_model)" "the original model must be restored afterwards"
  assert_contains "$ERR" "falling back to temporary settings.json patching" "the fallback is announced"
}

t_legacy_path_restores_after_failure() {
  export AGY_FORCE_LEGACY_MODEL=1
  export FAKE_AGY_EXIT=7
  run_wrapper ask --model opus "hi"
  assert_eq 7 "$RC" "the failure code should propagate"
  assert_eq "Gemini 3.1 Pro (High)" "$(settings_model)" "settings must be restored even when agy fails"
  if [ -f "$AGY_SETTINGS_FILE.agy-plugin.bak" ]; then fail_msg "backup file should not be left behind"; fi
  if [ -d "$AGY_HOME/.agy-plugin.lock" ]; then fail_msg "lock directory should be released"; fi
}

t_legacy_path_detected_from_help() {
  export FAKE_AGY_MODE="old-no-model"
  export FAKE_AGY_SETTINGS="$AGY_SETTINGS_FILE"
  # No catalogue on this build either, so pin an explicit display name.
  run_wrapper ask --model "Claude Opus 4.6 (Thinking)" "hi"
  assert_eq 0 "$RC" "an old build should still work"
  assert_contains "$OUT" "SETTINGS_MODEL_DURING_RUN=Claude Opus 4.6 (Thinking)" \
    "old builds fall back to settings patching automatically"
}

t_legacy_orphan_backup_is_recovered() {
  export AGY_FORCE_LEGACY_MODEL=1
  # Simulate a previous run killed mid-flight: a backup plus a dead-PID sentinel.
  cp "$AGY_SETTINGS_FILE" "$AGY_SETTINGS_FILE.agy-plugin.bak"
  printf '%s\n%s\n' "999999" "Some Other Model" > "$AGY_HOME/.agy-plugin.patched"
  printf '{ "model": "Clobbered Model" }\n' > "$AGY_SETTINGS_FILE"
  run_wrapper models --ids >/dev/null 2>&1
  assert_eq "Gemini 3.1 Pro (High)" "$(settings_model)" "an orphaned backup must be restored on next run"
}

# ----------------------------------------------------------- check/review --
t_check_reports_capabilities() {
  run_wrapper check
  assert_eq 0 "$RC" "check should always succeed"
  assert_contains "$OUT" '"installed": true' "agy is found on PATH"
  assert_contains "$OUT" '"nativeModelFlag": true' "the new build advertises --model"
  assert_contains "$OUT" '"modelsSubcommand": true' "the new build advertises models"
}

t_check_reports_old_build() {
  export FAKE_AGY_MODE="old-no-model"
  run_wrapper check
  assert_contains "$OUT" '"nativeModelFlag": false' "an old build is reported as such"
}

t_check_reports_missing_binary() {
  mkdir -p "$SANDBOX/empty-bin"
  export PATH="$SANDBOX/empty-bin:/usr/bin:/bin"
  run_wrapper check
  assert_eq 0 "$RC" "check must not fail when agy is absent"
  assert_contains "$OUT" '"installed": false' "missing agy is reported"
}

t_check_output_is_valid_json() {
  run_wrapper check
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
      || fail_msg "check must emit valid JSON, got: $OUT"
  fi
}

t_review_requires_a_diff() {
  ( cd "$SANDBOX" && bash "$WRAPPER" review "focus" >/dev/null 2>"$SANDBOX/err" ) || true
  assert_contains "$(cat "$SANDBOX/err")" "no git diff found" "review explains an empty diff"
}

t_review_accepts_model_flag() {
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
    && git init -q . \
    && git config user.email t@e.st && git config user.name test \
    && echo one > f.txt && git add f.txt && git commit -qm init \
    && echo two >> f.txt ) >/dev/null 2>&1
  ( cd "$SANDBOX/repo" && bash "$WRAPPER" review --model deep "check this" ) >/dev/null 2>&1
  argv_has "gemini-3.1-pro-high" || fail_msg "review should honour --model"
}

# --------------------------------------------------------- image hardening --
t_image_rejects_non_image_path_from_model() {
  printf 'secret\n' > "$SANDBOX/secret.txt"
  FAKE_AGY_STDOUT="done
IMAGE_PATH: $SANDBOX/secret.txt"
  export FAKE_AGY_STDOUT
  run_wrapper image --output "$SANDBOX/out.png" "a cat"
  if [ -f "$SANDBOX/out.png" ]; then fail_msg "a non-image IMAGE_PATH must never be copied"; fi
  assert_contains "$ERR" "not an image file" "the rejection is explained"
}

t_image_copies_real_image() {
  printf 'PNGDATA' > "$SANDBOX/pic.png"
  FAKE_AGY_STDOUT="done
IMAGE_PATH: $SANDBOX/pic.png"
  export FAKE_AGY_STDOUT
  run_wrapper image --output "$SANDBOX/out.png" "a cat"
  [ -f "$SANDBOX/out.png" ] || fail_msg "a genuine image path should be copied"
  assert_contains "$OUT" "copied to" "the copy is reported"
}

t_image_requires_description() {
  run_wrapper image
  assert_eq 64 "$RC" "image with no description is a usage error"
}

t_image_warns_when_no_path_found() {
  export FAKE_AGY_STDOUT="I could not make that image."
  run_wrapper image --output "$SANDBOX/out.png" "a cat"
  assert_contains "$ERR" "no image path was found" "the miss is reported"
  if [ -f "$SANDBOX/out.png" ]; then fail_msg "nothing should be copied when no path was found"; fi
}

# --------------------------------------------------------------- security --
t_cache_dir_is_not_world_readable() {
  run_wrapper models --ids
  # Windows/MSYS and some mounts ignore chmod entirely. Probe first so this
  # asserts a real guarantee where the filesystem can offer one, and skips
  # where it cannot, instead of failing for the platform.
  local probe; probe="$SANDBOX/probe"
  : > "$probe"; chmod 700 "$probe" 2>/dev/null || true
  local probe_perms; probe_perms="$(stat -c '%a' "$probe" 2>/dev/null || echo "")"
  if [ "$probe_perms" != "700" ]; then
    return 0   # filesystem does not honour POSIX modes
  fi
  local perms; perms="$(stat -c '%a' "$AGY_PLUGIN_CACHE_DIR" 2>/dev/null || echo "")"
  if [ "$perms" != "700" ]; then
    fail_msg "cache dir should be 0700, got $perms"
  fi
}

t_catalogue_rejects_malformed_rows() {
  printf 'no-tab-here\n\t\nid with space\tLabel\ngood-id\tGood Label\n' > "$SANDBOX/bad.tsv"
  export FAKE_AGY_CATALOG="$SANDBOX/bad.tsv"
  run_wrapper models --ids
  assert_eq "good-id" "$OUT" "only well-formed rows survive parsing"
}

t_aliases_file_is_never_executed() {
  printf 'boom = %s\n' '$(touch PWNMARK)' > "$AGY_ALIASES_FILE"
  ( cd "$SANDBOX" && bash "$WRAPPER" ask --model boom "hi" ) >/dev/null 2>&1
  if [ -e "$SANDBOX/PWNMARK" ]; then fail_msg "alias values must never be evaluated by the shell"; fi
  if [ -e "PWNMARK" ]; then fail_msg "alias values must never be evaluated by the shell"; fi
}

t_catalogue_content_is_never_executed() {
  printf '%s\tLabel\n' '$(touch PWNMARK2)' > "$SANDBOX/evil.tsv"
  export FAKE_AGY_CATALOG="$SANDBOX/evil.tsv"
  ( cd "$SANDBOX" && bash "$WRAPPER" models --ids ) >/dev/null 2>&1
  if [ -e "$SANDBOX/PWNMARK2" ]; then fail_msg "catalogue content must never be evaluated by the shell"; fi
}


t_capability_probe_is_not_racy() {
  # `agy --help` is normally small enough to fit a pipe buffer, which hid a
  # SIGPIPE-under-pipefail bug in the probe. A build with verbose help must
  # still be detected as supporting --model, or the wrapper silently starts
  # rewriting settings.json.
  {
    printf 'Usage of fake-agy:
'
    i=0; while [ "$i" -lt 4000 ]; do printf '  --filler-%s  padding to overflow the pipe buffer
' "$i"; i=$((i+1)); done
    printf '  --model                         Model for the current CLI session
'
    printf '  --effort                        Reasoning effort (low|medium|high)
'
    printf '  -p                              Short alias for --print
'
    printf '
Available subcommands:
  models          List available models
'
  } > "$SANDBOX/verbose-help.txt"
  cat > "$SANDBOX/bin/agy" <<AGYSTUB
#!/usr/bin/env bash
case "\${1:-}" in
  --help|-h) cat "$SANDBOX/verbose-help.txt"; exit 0 ;;
  --version) echo 9.9.9-fake; exit 0 ;;
  models)    cat "$FAKE_AGY_CATALOG"; exit 0 ;;
esac
: > "$FAKE_AGY_ARGV_LOG"
for a in "\$@"; do printf '%s
' "\$a" >> "$FAKE_AGY_ARGV_LOG"; done
echo fake-agy-ok
AGYSTUB
  chmod +x "$SANDBOX/bin/agy"

  local before; before="$(cat "$AGY_SETTINGS_FILE")"
  run_wrapper ask --model flash "hi"
  assert_eq 0 "$RC" "the call should succeed"
  argv_has "--model" || fail_msg "the native --model flag must still be detected with large help output"
  assert_eq "$before" "$(cat "$AGY_SETTINGS_FILE")" "settings.json must not be patched when --model is supported"
  assert_not_contains "$ERR" "falling back to temporary settings.json patching"     "a false-negative probe would silently switch to the legacy path"
}

t_repeated_calls_are_stable() {
  # The SIGPIPE race was intermittent, so assert over repetitions rather than
  # a single run.
  local i=0 fails=0
  while [ "$i" -lt 15 ]; do
    run_wrapper ask --model gpt-oss "hi"
    argv_has "gpt-oss-120b-medium" || fails=$((fails + 1))
    i=$((i + 1))
  done
  assert_eq 0 "$fails" "alias resolution must be deterministic across repeated calls"
}


# ------------------------------------------------------------- offload ----
# Substring match over the whole recorded argv, for things that live inside the
# prompt argument (the guard, the context note) rather than on their own line.
argv_contains() {
  [ -f "${FAKE_AGY_ARGV_LOG:-}" ] || return 1
  grep -Fq -- "$1" "$FAKE_AGY_ARGV_LOG"
}

# Same as run_wrapper, but with something on stdin.
run_wrapper_stdin() {
  local data="$1"; shift
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  RC=0
  printf '%s' "$data" | bash "$WRAPPER" "$@" >"$outf" 2>"$errf" || RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

install_fake_claude() {
  cp "$FIXTURES/fake-claude" "$SANDBOX/bin/claude"
  chmod +x "$SANDBOX/bin/claude"
  export FAKE_CLAUDE_ARGV="$SANDBOX/claude-argv.log"
  export FAKE_CLAUDE_STDIN="$SANDBOX/claude-stdin.txt"
}

claude_argv_has() {
  [ -f "${FAKE_CLAUDE_ARGV:-}" ] || return 1
  grep -Fxq -- "$1" "$FAKE_CLAUDE_ARGV"
}

# The argument that follows $1 in claude's recorded argv.
claude_argv_after() {
  [ -f "${FAKE_CLAUDE_ARGV:-}" ] || return 0
  awk -v flag="$1" 'prev == flag { print; exit } { prev = $0 }' "$FAKE_CLAUDE_ARGV"
}

t_offload_runs_read_only() {
  export FAKE_AGY_RESPONSE="AUTH | src/a.ts:1 | ok"
  run_wrapper offload --dir "$SANDBOX" "where is auth"
  assert_eq 0 "$RC" "offload should succeed"
  argv_has "--mode"  || fail_msg "offload must pass --mode"
  argv_has "plan"    || fail_msg "offload must run agy in plan mode"
  argv_has "--disable-slash-commands" || fail_msg "offload must disable slash commands"
  argv_has "--output-format" || fail_msg "offload must ask for structured output"
}

t_offload_injects_the_guard() {
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" "where is auth"
  argv_contains "Do NOT create, edit or delete files" || fail_msg "guard must ban writes"
  argv_contains "Never open .env files"               || fail_msg "guard must ban .env reads"
  argv_contains "Cite evidence as path:line"          || fail_msg "guard must demand citations"
  argv_contains "say UNKNOWN"                         || fail_msg "guard must prefer UNKNOWN to a guess"
}

t_offload_adds_workspace_roots() {
  mkdir -p "$SANDBOX/extra"
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" --add-dir "$SANDBOX/extra" "q"
  argv_has "$(cd "$SANDBOX" && pwd)"       || fail_msg "--dir must become a workspace root"
  argv_has "$(cd "$SANDBOX/extra" && pwd)" || fail_msg "--add-dir must become a workspace root"
}

t_offload_rejects_a_file_as_add_dir() {
  : > "$SANDBOX/a-file.txt"
  run_wrapper offload --dir "$SANDBOX" --add-dir "$SANDBOX/a-file.txt" "q"
  assert_eq 64 "$RC" "--add-dir takes a directory"
  assert_contains "$ERR" "existing directory" "the error should say why"
}

t_offload_defaults_to_the_balanced_tier() {
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" "q"
  argv_has "gemini-3.8-flash-high" || fail_msg "the default offload tier is balanced"
  assert_contains "$ERR" "balanced" "the default tier should be announced"
}

t_offload_honours_an_explicit_model() {
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" --model fast "q"
  argv_has "gemini-3.8-flash-low" || fail_msg "offload should honour --model"
}

t_offload_accepts_tier_as_a_synonym() {
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" --tier deep "q"
  argv_has "gemini-3.1-pro-high" || fail_msg "--tier should resolve like --model"
}

t_offload_reports_telemetry() {
  export FAKE_AGY_RESPONSE="ok" FAKE_AGY_IN=4321 FAKE_AGY_OUT=99
  run_wrapper offload --dir "$SANDBOX" --label recon "q"
  assert_contains "$ERR" "recon | gemini-3.8-flash-high" "telemetry names the label and model"
  assert_contains "$ERR" "in=4321 out=99" "telemetry reports token usage"
}

t_offload_marks_a_partial_answer() {
  export FAKE_AGY_DENIED_COMMAND=1 FAKE_AGY_RESPONSE="I will start by listing the directory"
  run_wrapper offload --dir "$SANDBOX" "count the errors"
  assert_eq 1 "$RC" "a turn cut short by a denial is not a success"
  assert_contains "$ERR" "PARTIAL" "a partial answer must be labelled"
  assert_contains "$OUT" "I will start by listing" "the text still comes back, labelled"
}

t_offload_explains_an_auto_denied_shell_command() {
  export FAKE_AGY_DENIED_COMMAND=1 FAKE_AGY_EMPTY=1
  run_wrapper offload --dir "$SANDBOX" "count the errors"
  assert_eq 1 "$RC" "an aborted turn is a failure"
  assert_contains "$ERR" "ABORTED" "the abort must be named"
  assert_contains "$ERR" "not offloadable" "and the remedy stated"
}

t_offload_falls_back_on_a_capacity_failure() {
  export FAKE_AGY_FAIL_MODELS="gemini-3.8-flash-high" FAKE_AGY_RESPONSE="from the fallback"
  export FAKE_AGY_ARGV_APPEND=1
  run_wrapper offload --dir "$SANDBOX" "q"
  assert_eq 0 "$RC" "the fallback answer is still an answer"
  assert_contains "$OUT" "from the fallback" "the fallback answer is returned"
  assert_contains "$ERR" "capacity failure" "the fallback is announced"
  assert_contains "$ERR" "weaker than the one asked for" "and flagged as weaker"
  argv_has "gemini-3.8-flash-medium" || fail_msg "the chain should try the next model"
}

t_offload_does_not_retry_other_failures() {
  export FAKE_AGY_EMPTY=1 FAKE_AGY_STDERR="fatal: the prompt was malformed"
  export FAKE_AGY_ARGV_APPEND=1
  run_wrapper offload --dir "$SANDBOX" "q"
  assert_eq 1 "$RC" "a non-capacity failure fails"
  assert_not_contains "$ERR" "capacity failure" "and is not retried"
  if argv_has "gemini-3.8-flash-medium"; then fail_msg "no fallback should be attempted"; fi
}

t_offload_puts_stdin_in_a_context_file() {
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper_stdin "THE-DIFF-BODY" offload --dir "$SANDBOX" --stdin "q"
  assert_eq 0 "$RC" "offload with context should succeed"
  argv_contains "Context from the calling agent" || fail_msg "the prompt must point at the context file"
  argv_contains "context.md" || fail_msg "the context file must be named"
  if argv_contains "THE-DIFF-BODY"; then
    fail_msg "the context body must NOT travel on the command line"
  fi
}

t_offload_ignores_stdin_without_the_flag() {
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper_stdin "THE-DIFF-BODY" offload --dir "$SANDBOX" "q"
  assert_eq 0 "$RC" "offload without --stdin still runs"
  if argv_contains "Context from the calling agent"; then
    fail_msg "stdin must only be read behind an explicit --stdin"
  fi
}

t_offload_fails_closed_without_plan_mode() {
  export FAKE_AGY_MODE=old-no-mode FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" "q"
  assert_eq 1 "$RC" "an offload that cannot be held read-only must not run"
  assert_contains "$ERR" "read-only" "and must say why"
}

t_offload_requires_a_prompt() {
  run_wrapper offload --dir "$SANDBOX"
  assert_eq 64 "$RC" "a missing prompt is a usage error"
}

t_offload_rejects_a_bad_budget() {
  run_wrapper offload --dir "$SANDBOX" --budget soon "q"
  assert_eq 64 "$RC" "--budget takes seconds"
}

t_offload_warns_about_token_files_in_a_root() {
  mkdir -p "$SANDBOX/tokens"
  echo '{}' > "$SANDBOX/tokens/refresh-token.json"
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" "q"
  assert_contains "$ERR" "refresh-token.json" "a token store in a root must be flagged"
  assert_contains "$ERR" "Narrow --dir" "with the remedy"
}

t_offload_refuses_flags_after_the_prompt() {
  # agy honours the last --mode it is given, so one after the prompt would
  # replace the wrapper's plan mode.
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" "q" --mode accept-edits
  assert_eq 64 "$RC" "--mode after the prompt must be refused"
  assert_contains "$ERR" "except --sandbox" "and the refusal says what is allowed"
  run_wrapper offload --dir "$SANDBOX" "q" --mode=accept-edits
  assert_eq 64 "$RC" "--mode=value after the prompt must be refused"
  run_wrapper offload --dir "$SANDBOX" "q" --dangerously-skip-permissions
  assert_eq 64 "$RC" "--dangerously-skip-permissions must be refused"
  run_wrapper offload --dir "$SANDBOX" "q" --sandbox --add-dir /
  assert_eq 64 "$RC" "an allowed flag does not let others through"
  if [ -s "$FAKE_AGY_ARGV_LOG" ]; then fail_msg "agy must not run at all when a flag is refused"; fi
}

t_offload_forwards_sandbox_after_the_prompt() {
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" "q" --sandbox
  assert_eq 0 "$RC" "--sandbox only narrows the run, so it is allowed"
  argv_has "--sandbox" || fail_msg "--sandbox must reach agy"
  argv_has "plan"      || fail_msg "and the run stays in plan mode"
}

# -------------------------------------------------------------- fanout ----
t_fanout_runs_several_prompts() {
  export FAKE_AGY_RESPONSE="an answer" FAKE_AGY_ARGV_APPEND=1
  run_wrapper fanout --dir "$SANDBOX" --prompt "where is auth" --prompt "where is logging" --throttle 2
  assert_eq 0 "$RC" "fanout should succeed"
  assert_contains "$OUT" "## job1" "answers are grouped by label"
  assert_contains "$OUT" "## job2" "one group per job"
  assert_contains "$ERR" "2 jobs" "the summary counts the jobs"
}

t_fanout_reads_a_jobs_file() {
  export FAKE_AGY_RESPONSE="an answer" FAKE_AGY_ARGV_APPEND=1
  cat > "$SANDBOX/jobs.json" <<JSON
[
  { "label": "auth",    "dir": "$SANDBOX", "prompt": "where is auth",    "model": "fast" },
  { "label": "billing", "dir": "$SANDBOX", "prompt": "where is billing", "model": "deep" }
]
JSON
  run_wrapper fanout --jobs "$SANDBOX/jobs.json" --throttle 2
  assert_eq 0 "$RC" "fanout --jobs should succeed"
  assert_contains "$OUT" "## auth  [fast]" "per-job labels and models are shown"
  assert_contains "$OUT" "## billing  [deep]" "both jobs are reported"
  argv_has "gemini-3.8-flash-low" || fail_msg "the fast job should resolve to Flash Low"
  argv_has "gemini-3.1-pro-high"  || fail_msg "the deep job should resolve to Pro High"
}

t_fanout_forwards_per_job_add_dirs() {
  mkdir -p "$SANDBOX/lib" "$SANDBOX/vendor"
  export FAKE_AGY_RESPONSE="an answer" FAKE_AGY_ARGV_APPEND=1
  cat > "$SANDBOX/jobs.json" <<JSON
[
  { "label": "span", "dir": "$SANDBOX/lib", "prompt": "q",
    "addDir": ["$SANDBOX/vendor"] }
]
JSON
  run_wrapper fanout --jobs "$SANDBOX/jobs.json"
  assert_eq 0 "$RC" "fanout with addDir should succeed"
  argv_has "$(cd "$SANDBOX/vendor" && pwd)" || fail_msg "addDir must become a workspace root"
}

t_fanout_explains_a_misescaped_windows_path() {
  printf '[{"label":"x","dir":"C:\Data\backend","prompt":"p"}]\n' > "$SANDBOX/bad.json"
  run_wrapper fanout --jobs "$SANDBOX/bad.json"
  assert_eq 64 "$RC" "an unparseable jobs file is a usage error"
  assert_contains "$ERR" "mis-escaped" "the Windows-path trap must be named"
}

t_fanout_requires_work() {
  run_wrapper fanout --dir "$SANDBOX"
  assert_eq 64 "$RC" "fanout with no jobs is a usage error"
}

# -------------------------------------------------------------- review ----
t_review_sends_the_diff_as_context_not_argv() {
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
    && git init -q . \
    && git config user.email t@e.st && git config user.name test \
    && echo one > f.txt && git add f.txt && git commit -qm init \
    && echo DIFF-BODY-MARKER >> f.txt ) >/dev/null 2>&1
  export FAKE_AGY_RESPONSE="LOW | f.txt:2 | fine"
  ( cd "$SANDBOX/repo" && bash "$WRAPPER" review "focus" ) >/dev/null 2>&1
  argv_contains "context.md" || fail_msg "the diff must go in as a context file"
  if argv_contains "DIFF-BODY-MARKER"; then
    fail_msg "the diff body must not travel on the command line"
  fi
}

t_review_omits_dotenv_but_keeps_the_example() {
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
    && git init -q . \
    && git config user.email t@e.st && git config user.name test \
    && echo one > app.js && echo "SECRET=old" > .env && echo "KEY=x" > .env.example \
    && git add -A && git commit -qm init \
    && echo two >> app.js \
    && echo "SECRET=LEAKED-VALUE" > .env \
    && echo "KEY2=y" >> .env.example ) >/dev/null 2>&1
  review_capturing_context
  assert_contains "$ERR" "omitted from the review" ".env must be dropped, loudly"
  # The diff travels in the context file, never in argv, so that is where a
  # leak would show.
  assert_not_contains "$(review_context)" "LEAKED-VALUE" "a .env value must never reach agy"
  assert_contains "$(review_context)" "KEY2=y" "the .env.example change is still reviewed"
}

# A repository whose first commit holds $1 with SECRET=old. The working tree
# then sets it to SECRET=LEAKED-VALUE and adds APP-CHANGE to app.js.
make_repo_with_secret_change() {
  local secret="$1"
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
    && git init -q . \
    && git config user.email t@e.st && git config user.name test \
    && mkdir -p "$(dirname "$secret")" \
    && echo one > app.js && echo "SECRET=old" > "$secret" \
    && git add -A && git commit -qm init \
    && echo APP-CHANGE >> app.js && echo "SECRET=LEAKED-VALUE" > "$secret" ) >/dev/null 2>&1
}

# Runs review with --dir $1 (default: the sandbox repo) plus any further
# arguments. Keeps the wrapper's stderr in ERR and a copy of the context file
# agy was given, which review_context prints.
review_capturing_context() {
  local where="${1:-$SANDBOX/repo}"
  if [ $# -gt 0 ]; then shift; fi
  export FAKE_AGY_RESPONSE="ok" FAKE_AGY_CTX_COPY="$SANDBOX/ctx.md"
  ERR="$( ( cd "$where" && bash "$WRAPPER" review --dir "$where" "$@" ) 2>&1 >/dev/null )"
}

review_context() { cat "$SANDBOX/ctx.md" 2>/dev/null || true; }

t_review_omits_dotenv_in_a_dir_with_a_space() {
  make_repo_with_secret_change "my config/.env"
  review_capturing_context
  assert_contains "$(review_context)" "APP-CHANGE" "the rest of the diff is reviewed"
  assert_not_contains "$(review_context)" "LEAKED-VALUE" "a .env under a directory with a space must not be sent"
  assert_contains "$ERR" "(holds secrets): my config/.env" "and the omission names the whole path"
}

t_review_omits_dotenv_renamed_from_the_example() {
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
    && git init -q . \
    && git config user.email t@e.st && git config user.name test \
    && printf 'KEY_%s=placeholder\n' 1 2 3 4 5 6 7 8 9 10 > .env.example \
    && echo one > app.js && git add -A && git commit -qm init \
    && git mv .env.example .env && echo "SECRET=LEAKED-VALUE" >> .env \
    && echo APP-CHANGE >> app.js ) >/dev/null 2>&1
  # Big enough for git to pair the two files as a rename; a smaller example
  # shows up as a delete plus an add, which never exercised the bug.
  case "$(git -C "$SANDBOX/repo" diff HEAD -M --name-status 2>/dev/null)" in
    R*) : ;;
    *)  fail_msg "setup: git should report a rename here, or this test proves nothing" ;;
  esac
  review_capturing_context
  assert_contains "$(review_context)" "APP-CHANGE" "the rest of the diff is reviewed"
  assert_not_contains "$(review_context)" "LEAKED-VALUE" "a .env renamed from .env.example must not be sent"
}

t_review_omits_files_under_a_dotenvs_dir() {
  make_repo_with_secret_change ".envs/.production/.django"
  review_capturing_context
  assert_contains "$(review_context)" "APP-CHANGE" "the rest of the diff is reviewed"
  assert_not_contains "$(review_context)" "LEAKED-VALUE" "a file under .envs/ must not be sent"
}

t_review_omits_dotenv_whatever_its_case() {
  make_repo_with_secret_change "config/.ENV.local"
  review_capturing_context
  assert_contains "$(review_context)" "APP-CHANGE" "the rest of the diff is reviewed"
  assert_not_contains "$(review_context)" "LEAKED-VALUE" "an upper-case .ENV must not be sent"
}

t_review_omits_a_root_dotenv_from_a_subfolder() {
  # git lists changed files relative to the repository root, not to --dir.
  make_repo_with_secret_change ".env"
  mkdir -p "$SANDBOX/repo/sub"
  review_capturing_context "$SANDBOX/repo/sub"
  assert_contains "$(review_context)" "APP-CHANGE" "the whole repository's diff is reviewed"
  assert_not_contains "$(review_context)" "LEAKED-VALUE" "a root .env must not be sent when --dir is a subfolder"
}

t_commands_preapprove_only_their_own_wrapper_call() {
  # A broad rule such as Bash(bash:*) pre-approves `bash -c '<anything>'` for
  # as long as a command runs. Each command may pre-approve only the wrapper
  # subcommand it documents, and nothing that downloads or runs other code.
  local prefix='bash "${CLAUDE_PLUGIN_ROOT}/scripts/agy-run.sh" '
  local f name want rules rule line n=0
  for f in "$REPO_ROOT"/plugins/agy/commands/*.md; do
    name="$(basename "$f" .md)"
    want="$name"
    if [ "$name" = "setup" ]; then want="check"; fi
    rules="$(sed -n 's/^allowed-tools:[[:space:]]*//p' "$f" | grep -oE 'Bash\([^)]*\)' || true)"
    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      n=$((n + 1))
      case "$rule" in
        "Bash(${prefix}${want})"|"Bash(${prefix}${want} *)") : ;;
        *) fail_msg "$name.md pre-approves more than its own wrapper call: $rule" ;;
      esac
    done <<<"$rules"
    # Claude Code matches a rule against the command text Claude writes, so
    # every documented call has to have exactly the shape the rule allows.
    while IFS= read -r line; do
      case "$line" in
        *"${prefix}${want}"*) : ;;
        *) fail_msg "$name.md documents a call its rule does not cover: $line" ;;
      esac
    done < <(grep -F 'agy-run.sh"' "$f" || true)
  done
  [ "$n" -ge 9 ] || fail_msg "expected a Bash rule in each of the 9 wrapper commands, found $n"
}

t_secret_path_predicate() {
  local p
  for p in ".env" ".env.local" "a/b/.env.production" "my config/.env" ".ENV" \
           "Config/.Env.Local" ".envs/.production/.django" "deploy/.envs/app.yml" ".envrc"; do
    ( source "$WRAPPER"; _path_holds_secrets "$p" ) || fail_msg "'$p' should count as holding secrets"
  done
  for p in ".env.example" "config/.env.example" ".ENV.EXAMPLE" "env.txt" \
           "src/environment.ts" "my.env" "docs/env/notes.md"; do
    if ( source "$WRAPPER"; _path_holds_secrets "$p" ); then
      fail_msg "'$p' should not count as holding secrets"
    fi
  done
}

t_review_names_untracked_files() {
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
    && git init -q . \
    && git config user.email t@e.st && git config user.name test \
    && echo one > f.txt && git add f.txt && git commit -qm init \
    && echo two >> f.txt \
    && echo new > brand-new-file.js ) >/dev/null 2>&1
  export FAKE_AGY_RESPONSE="ok"
  ( cd "$SANDBOX/repo" && bash "$WRAPPER" review ) >/dev/null 2>&1
  argv_contains "brand-new-file.js" || fail_msg "new files are not in the diff and must be named"
}

# ------------------------------------------------------ second opinion ----
t_second_opinion_runs_claude_read_only() {
  install_fake_claude
  export FAKE_CLAUDE_RESULT="the independent answer"
  run_wrapper second-opinion --model sonnet --dir "$SANDBOX" "why does it deadlock"
  assert_eq 0 "$RC" "the second opinion should succeed"
  assert_contains "$OUT" "the independent answer" "the answer comes back"
  claude_argv_has "plan"            || fail_msg "it must run in plan mode"
  claude_argv_has "Read,Grep,Glob"  || fail_msg "it must be read-only: Read, Grep, Glob"
  claude_argv_has "sonnet"          || fail_msg "--model must be forwarded"
  assert_contains "$ERR" "cost=" "telemetry reports the cost"
}

t_second_opinion_passes_context_on_stdin() {
  install_fake_claude
  run_wrapper_stdin "ESTABLISHED-FACT" second-opinion --dir "$SANDBOX" --stdin "why"
  assert_eq 0 "$RC" "a second opinion with context should succeed"
  assert_contains "$(cat "$FAKE_CLAUDE_STDIN")" "ESTABLISHED-FACT" "context must reach claude on stdin"
  assert_contains "$(cat "$FAKE_CLAUDE_STDIN")" "read-only" "the guard must be prepended"
}

t_second_opinion_reports_an_auth_failure() {
  install_fake_claude
  export FAKE_CLAUDE_ERROR=1
  run_wrapper second-opinion --dir "$SANDBOX" "why"
  assert_eq 1 "$RC" "an error is a failure"
  assert_contains "$ERR" "credentials" "and suggests the fix"
}

t_second_opinion_without_claude_exits_127() {
  # A PATH narrow enough to hide claude still has to be able to run bash, and
  # the wrapper calls dirname at load time. On macOS bash is /bin/bash while
  # dirname lives in /usr/bin, so bash's directory alone is not enough.
  local bin_dir tool_dir minimal outf errf
  bin_dir="$(dirname "$(command -v bash)")"
  tool_dir="$(dirname "$(command -v dirname)")"
  minimal="$SANDBOX/bin:$bin_dir:$tool_dir"
  if PATH="$minimal" command -v claude >/dev/null 2>&1; then
    return 0   # claude sits next to bash here; nothing to assert
  fi
  outf="$(mktemp)"; errf="$(mktemp)"
  RC=0
  PATH="$minimal" bash "$WRAPPER" second-opinion --dir "$SANDBOX" "why" >"$outf" 2>"$errf" || RC=$?
  ERR="$(cat "$errf")"; rm -f "$outf" "$errf"
  assert_eq 127 "$RC" "a missing claude is exit 127"
  assert_contains "$ERR" "not on PATH" "and says so"
}

t_second_opinion_rejects_a_bad_effort() {
  install_fake_claude
  run_wrapper second-opinion --effort turbo "why"
  assert_eq 64 "$RC" "an invalid effort is a usage error"
}

t_second_opinion_ignores_project_settings() {
  # `claude -p` skips the folder-trust prompt, so a repository's own
  # .claude/settings.json would run its hooks the moment --dir points at it.
  install_fake_claude
  run_wrapper second-opinion --dir "$SANDBOX" "why"
  assert_eq 0 "$RC" "the second opinion should succeed"
  assert_eq "user" "$(claude_argv_after --setting-sources)" "only the user's own settings may load"
  claude_argv_has "--strict-mcp-config" || fail_msg "MCP servers must be left out"
}

# Stands in for coreutils timeout: records the limit it was given, then runs
# the command, so a test can see the limit without waiting for it.
install_fake_timeout() {
  cat > "$SANDBOX/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" > "$FAKE_TIMEOUT_LOG"
shift
exec "$@"
STUB
  chmod +x "$SANDBOX/bin/timeout"
  export FAKE_TIMEOUT_LOG="$SANDBOX/timeout.log"
}

t_second_opinion_default_timeout_fits_the_tool_limit() {
  # Claude Code kills a foreground tool call at 600s. A longer default meant the
  # harness killed the run first: no answer, no clean timeout message.
  install_fake_claude
  install_fake_timeout
  run_wrapper second-opinion --dir "$SANDBOX" "why"
  assert_eq 0 "$RC" "the second opinion should succeed"
  assert_eq "540s" "$(cat "$FAKE_TIMEOUT_LOG" 2>/dev/null)" "the default must sit under the 600s tool kill"
}

t_second_opinion_timeout_can_be_raised() {
  install_fake_claude
  install_fake_timeout
  run_wrapper second-opinion --timeout 900 --dir "$SANDBOX" "why"
  assert_eq "900s" "$(cat "$FAKE_TIMEOUT_LOG" 2>/dev/null)" "an explicit --timeout still wins"
}

# ---------------------------------------------------------- ask-claude ----
claude_ran() { [ -s "${FAKE_CLAUDE_ARGV:-}" ]; }

t_ask_claude_is_read_only_by_default() {
  install_fake_claude
  export FAKE_CLAUDE_RESULT="the answer"
  run_wrapper ask-claude --dir "$SANDBOX" "why does it deadlock"
  assert_eq 0 "$RC" "ask-claude should succeed"
  assert_contains "$OUT" "the answer" "the answer comes back"
  assert_eq "Read,Grep,Glob" "$(claude_argv_after --tools)" "read-only tools only"
  assert_eq "plan" "$(claude_argv_after --permission-mode)" "plan mode"
  assert_eq "none" "$(claude_argv_after --permission-prompts)" "nobody can approve anything"
  assert_eq "opus" "$(claude_argv_after --model)" "opus by default"
  if claude_argv_has "--restricted"; then fail_msg "a read-only run keeps the user's settings"; fi
  assert_contains "$(cat "$FAKE_CLAUDE_STDIN")" "Antigravity CLI" "the guard names the caller"
  assert_contains "$(cat "$FAKE_CLAUDE_STDIN")" "You are read-only" "the guard says it is read-only"
  assert_contains "$ERR" "ask-claude | opus/high (read-only)" "telemetry names the mode"
}

t_ask_claude_ignores_project_settings() {
  # Same hole as second-opinion: claude -p trusts the folder without asking.
  install_fake_claude
  mkdir -p "$SANDBOX/proj"
  local mode
  for mode in --read-only --allow-write; do
    run_wrapper ask-claude "$mode" --dir "$SANDBOX/proj" "q"
    assert_eq 0 "$RC" "ask-claude $mode should succeed"
    assert_eq "user" "$(claude_argv_after --setting-sources)" "$mode: only the user's own settings may load"
    claude_argv_has "--strict-mcp-config" || fail_msg "$mode: MCP servers must be left out"
  done
}

t_ask_claude_allow_write_edits_but_never_runs_commands() {
  install_fake_claude
  mkdir -p "$SANDBOX/proj"
  run_wrapper ask-claude --allow-write --dir "$SANDBOX/proj" "rename foo to bar"
  assert_eq 0 "$RC" "a write run should succeed"
  assert_eq "Read,Grep,Glob,Edit,Write" "$(claude_argv_after --tools)" "file tools, and no Bash"
  assert_eq "acceptEdits" "$(claude_argv_after --permission-mode)" "edits are accepted"
  assert_eq "none" "$(claude_argv_after --permission-prompts)" "and nothing else can be approved"
  claude_argv_has "--restricted" || fail_msg "a write run must be restricted"
  claude_argv_has "Edit(**/.agents/**)" || fail_msg "agy's hooks and skills are off limits"
  claude_argv_has "Edit(**/.git/**)" || fail_msg "git's hooks and config are off limits"
  claude_argv_has "Edit(**/.claude/**)" || fail_msg "Claude Code's settings are off limits"
  assert_contains "$(cat "$FAKE_CLAUDE_STDIN")" "list every file you changed" "the guard asks for a change list"
  assert_contains "$ERR" "ask-claude | opus/high (write)" "telemetry names the mode"
  assert_contains "$ERR" "not in a git work tree" "a folder git cannot undo is flagged"
}

t_ask_claude_write_needs_an_explicit_dir() {
  install_fake_claude
  run_wrapper ask-claude --allow-write "fix it"
  assert_eq 64 "$RC" "no --dir is a usage error"
  assert_contains "$ERR" "needs --dir" "and says so"
  if claude_ran; then fail_msg "claude must not start"; fi
}

t_ask_claude_write_refuses_a_home_folder() {
  install_fake_claude
  run_wrapper ask-claude --allow-write --dir "$HOME" "fix it"
  assert_eq 64 "$RC" "a home folder is too broad to write in"
  if claude_ran; then fail_msg "claude must not start"; fi
}

t_ask_claude_write_fails_closed_without_restricted() {
  install_fake_claude
  export FAKE_CLAUDE_HELP=old
  mkdir -p "$SANDBOX/proj"
  run_wrapper ask-claude --allow-write --dir "$SANDBOX/proj" "fix it"
  assert_eq 1 "$RC" "a build without --restricted cannot write"
  assert_contains "$ERR" "--restricted" "and says why"
  if claude_ran; then fail_msg "claude must not start"; fi
}

t_ask_claude_modes_contradict() {
  install_fake_claude
  mkdir -p "$SANDBOX/proj"
  run_wrapper ask-claude --read-only --allow-write --dir "$SANDBOX/proj" "fix it"
  assert_eq 64 "$RC" "--read-only with --allow-write is a usage error"
  if claude_ran; then fail_msg "claude must not start"; fi
}

t_ask_claude_rejects_a_flag_after_the_task() {
  # agy's permission rule matches the start of the command, so a flag after
  # the task must not be quietly dropped into it.
  install_fake_claude
  run_wrapper ask-claude --read-only --dir "$SANDBOX" "fix it" --allow-write
  assert_eq 64 "$RC" "a flag after the task is a usage error"
  assert_contains "$ERR" "comes after the task" "and says so"
  if claude_ran; then fail_msg "claude must not start"; fi
}

t_ask_claude_rejects_an_unknown_flag() {
  install_fake_claude
  run_wrapper ask-claude --alow-write --dir "$SANDBOX" "fix it"
  assert_eq 64 "$RC" "a misspelt flag is a usage error, not part of the task"
  if claude_ran; then fail_msg "claude must not start"; fi
}

t_ask_claude_joins_an_unquoted_task() {
  install_fake_claude
  run_wrapper ask-claude --dir "$SANDBOX" why does it fail
  assert_eq 0 "$RC" "an unquoted task should still run"
  assert_contains "$(cat "$FAKE_CLAUDE_STDIN")" "why does it fail" "the words become one task"
}

t_ask_claude_passes_context_on_stdin() {
  install_fake_claude
  run_wrapper_stdin "ESTABLISHED-FACT" ask-claude --stdin --dir "$SANDBOX" "why"
  assert_eq 0 "$RC" "ask-claude with context should succeed"
  assert_contains "$(cat "$FAKE_CLAUDE_STDIN")" "ESTABLISHED-FACT" "context must reach claude on stdin"
}

t_ask_claude_default_timeout() {
  install_fake_claude
  install_fake_timeout
  run_wrapper ask-claude --dir "$SANDBOX" "why"
  assert_eq 0 "$RC" "ask-claude should succeed"
  assert_eq "900s" "$(cat "$FAKE_TIMEOUT_LOG" 2>/dev/null)" "agy is the caller, so the 600s tool kill does not apply"
}

# -------------------------------------------------------------- bridge ----
bridge_dir() { printf '%s' "$HOME/.gemini/config/skills/ask-claude"; }

# Records $1 as the agy plugin Claude Code has installed, the way
# installed_plugins.json does.
register_agy_plugin() {
  mkdir -p "$HOME/.claude/plugins"
  python3 - "$HOME/.claude/plugins/installed_plugins.json" "$1" <<'PY'
import json, sys
entry = {"scope": "user", "installPath": sys.argv[2], "version": "test"}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({"version": 2, "plugins": {"agy@antigravity-cc": [entry]}}, fh)
PY
}

# A copy of the wrapper in Claude Code's plugin cache as version $1; prints
# the plugin root. With a second argument, a wrapper from before the bridge.
cache_agy_version() {
  local root="$HOME/.claude/plugins/cache/antigravity-cc/agy/$1"
  mkdir -p "$root/scripts"
  if [ -n "${2:-}" ]; then
    printf '#!/usr/bin/env bash\necho "old wrapper: $*"\n' > "$root/scripts/agy-run.sh"
  else
    cp "$WRAPPER" "$root/scripts/agy-run.sh"
  fi
  printf '%s' "$root"
}

run_launcher() {
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  RC=0
  bash "$(bridge_dir)/scripts/ask-claude" "$@" >"$outf" 2>"$errf" </dev/null || RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

t_bridge_install_writes_launcher_and_skill() {
  export AGY_BRIDGE_WINDOWS=0
  register_agy_plugin "$REPO_ROOT/plugins/agy"
  run_wrapper bridge install
  assert_eq 0 "$RC" "install should succeed"
  [ -x "$(bridge_dir)/scripts/ask-claude" ] || fail_msg "the launcher must be executable"
  if [ -f "$(bridge_dir)/scripts/ask-claude.ps1" ]; then fail_msg "no PowerShell launcher off Windows"; fi
  assert_contains "$(cat "$(bridge_dir)/SKILL.md")" "$(bridge_dir)/scripts/ask-claude --read-only" \
    "the skill tells agy the exact command"
  assert_not_contains "$(cat "$(bridge_dir)/SKILL.md")" "@ASK_CLAUDE@" "no placeholder is left"
  assert_contains "$OUT" "The launcher runs: $WRAPPER" "install proves the launcher reaches the plugin"
  assert_contains "$OUT" "\"command($(bridge_dir)/scripts/ask-claude --read-only)\"" "it prints the read-only rule"
}

t_bridge_launcher_runs_the_installed_plugin() {
  export AGY_BRIDGE_WINDOWS=0
  install_fake_claude
  register_agy_plugin "$REPO_ROOT/plugins/agy"
  run_wrapper bridge install
  run_launcher --read-only --dir "$SANDBOX" "why"
  assert_eq 0 "$RC" "agy's call through the launcher should succeed"
  assert_eq "plan" "$(claude_argv_after --permission-mode)" "and reach a read-only Claude Code"
}

t_bridge_launcher_follows_the_registry() {
  # The cache keeps versions Claude Code has already replaced; the registry
  # says which one is live.
  export AGY_BRIDGE_WINDOWS=0
  local live
  live="$(cache_agy_version 0.8.0)"
  cache_agy_version 0.9.0 >/dev/null
  register_agy_plugin "$live"
  run_wrapper bridge install
  run_launcher --where
  assert_eq 0 "$RC" "the launcher should find the plugin"
  assert_contains "$OUT" "/agy/0.8.0/scripts/agy-run.sh" "the registered version wins"
}

t_bridge_launcher_falls_back_to_the_newest_cached_version() {
  export AGY_BRIDGE_WINDOWS=0
  cache_agy_version 0.9.0 >/dev/null
  cache_agy_version 0.10.0 >/dev/null
  cache_agy_version 0.11.0 old >/dev/null
  run_wrapper bridge install
  run_launcher --where
  assert_eq 0 "$RC" "the launcher should find the plugin"
  assert_contains "$OUT" "/agy/0.10.0/scripts/agy-run.sh" "newest by number that knows ask-claude"
}

t_bridge_launcher_refuses_a_plugin_older_than_the_bridge() {
  export AGY_BRIDGE_WINDOWS=0
  cache_agy_version 0.10.0 >/dev/null
  register_agy_plugin "$(cache_agy_version 0.7.0 old)"
  run_wrapper bridge install
  run_launcher --read-only --dir "$SANDBOX" "why"
  assert_eq 127 "$RC" "an installed plugin without ask-claude is an error"
  assert_contains "$ERR" "older than this bridge" "that says to update"
  assert_not_contains "$OUT" "old wrapper" "the old wrapper must not run"
}

t_bridge_launcher_decodes_windows_arguments() {
  # ask-claude.ps1 cannot put the arguments on bash's command line intact, so
  # it sends them base64-encoded, each NUL-terminated.
  printf 'eA==' | base64 -d >/dev/null 2>&1 || return 0
  export AGY_BRIDGE_WINDOWS=0
  register_agy_plugin "$REPO_ROOT/plugins/agy"
  run_wrapper bridge install
  cat > "$SANDBOX/argv-dump" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do printf '<%s>\n' "$a"; done
STUB
  export AGY_RUN_SH="$SANDBOX/argv-dump"
  AGY_BRIDGE_ARGV="$(printf -- '--dir\0C:\\x y\0fix the "retry" loop\nand *.ts\0' | base64 | tr -d '\n')"
  export AGY_BRIDGE_ARGV
  run_launcher ignored-command-line-args
  assert_eq 0 "$RC" "the launcher should run"
  assert_eq "$(printf '<ask-claude>\n<--dir>\n<C:\\x y>\n<fix the "retry" loop\nand *.ts>')" "$OUT" \
    "every argument arrives exactly as agy wrote it"
}

t_bridge_install_on_windows_adds_the_powershell_launcher() {
  export AGY_BRIDGE_WINDOWS=1
  register_agy_plugin "$REPO_ROOT/plugins/agy"
  run_wrapper bridge install
  assert_eq 0 "$RC" "install should succeed"
  [ -f "$(bridge_dir)/scripts/ask-claude.ps1" ] || fail_msg "Windows needs the PowerShell launcher"
  assert_contains "$(cat "$(bridge_dir)/SKILL.md")" "pwsh -NoProfile -File " "agy starts it through pwsh"
  assert_contains "$OUT" "\"command(pwsh -NoProfile -File " "and the rule names that command"
}

t_bridge_install_keeps_a_file_it_did_not_write() {
  export AGY_BRIDGE_WINDOWS=0
  mkdir -p "$(bridge_dir)"
  echo "my own skill" > "$(bridge_dir)/SKILL.md"
  run_wrapper bridge install
  assert_eq 1 "$RC" "install must not overwrite a foreign file"
  assert_eq "my own skill" "$(cat "$(bridge_dir)/SKILL.md")" "the file is untouched"
  run_wrapper bridge install --force
  assert_eq 0 "$RC" "--force overwrites it"
  assert_contains "$(cat "$(bridge_dir)/SKILL.md")" "Written by agy-run.sh bridge install" "with the bridge's skill"
}

t_bridge_uninstall_removes_only_its_own_files() {
  export AGY_BRIDGE_WINDOWS=0
  run_wrapper bridge install
  echo "notes" > "$(bridge_dir)/notes.md"
  run_wrapper bridge uninstall
  assert_eq 0 "$RC" "uninstall should succeed"
  if [ -e "$(bridge_dir)/scripts/ask-claude" ]; then fail_msg "the launcher must be gone"; fi
  if [ -e "$(bridge_dir)/SKILL.md" ]; then fail_msg "the skill must be gone"; fi
  [ -f "$(bridge_dir)/notes.md" ] || fail_msg "a file the installer did not write stays"
  assert_contains "$OUT" "permissions.allow" "and it reminds you of agy's rules"
}

t_bridge_status_reports_agy_rules() {
  export AGY_BRIDGE_WINDOWS=0
  register_agy_plugin "$REPO_ROOT/plugins/agy"
  run_wrapper bridge status
  assert_eq 1 "$RC" "status before install reports failure"
  assert_contains "$OUT" "not installed" "and says so"
  run_wrapper bridge install
  # The rule goes through the environment: Git Bash rewrites what looks like a
  # POSIX path in the arguments of a native program, and the rule has to reach
  # the file exactly as the wrapper prints it.
  RULE="command($(bridge_dir)/scripts/ask-claude --read-only)" python3 - "$AGY_SETTINGS_FILE" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
data.setdefault("permissions", {}).setdefault("allow", []).append(os.environ["RULE"])
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
  run_wrapper bridge status
  assert_eq 0 "$RC" "status after install succeeds"
  assert_contains "$OUT" "agy rule for --read-only: present" "the read-only rule is found"
  assert_contains "$OUT" "agy rule for --allow-write: absent" "the write rule is not"
}

t_bridge_skill_text_keeps_ampersands() {
  local out
  out="$( source "$WRAPPER"; _bridge_skill_text 'run @ASK_CLAUDE@ or @ASK_CLAUDE@ now' 'C:\Tom&Jerry\x' )"
  assert_eq 'run C:\Tom&Jerry\x or C:\Tom&Jerry\x now' "$out" "a path with & must survive the template"
}

# ---------------------------------------------------------- regressions ----
t_json_escaping_round_trips() {
  # A backslash or newline in a path or version string must survive into
  # valid JSON — `check` output is parsed by /agy:setup.
  local input escaped decoded
  input="$(printf 'C:\\agy\\bin "quoted"\tTAB\nline2')"
  escaped="$( source "$WRAPPER"; j_esc "$input" )"
  decoded="$(python3 -c 'import json, sys
sys.stdout.reconfigure(newline="\n")
sys.stdout.write(json.loads("\"" + sys.argv[1] + "\""))' "$escaped")"
  assert_eq "$input" "$decoded" "j_esc output must decode back to the input"
}

t_offload_probes_agy_help_once() {
  mv "$SANDBOX/bin/agy" "$SANDBOX/bin/agy-real"
  cat > "$SANDBOX/bin/agy" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in --help|-h) echo probe >> "$SANDBOX/help-count" ;; esac
exec bash "$SANDBOX/bin/agy-real" "\$@"
STUB
  chmod +x "$SANDBOX/bin/agy"
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" "q"
  assert_eq 0 "$RC" "offload should succeed"
  assert_eq 1 "$(wc -l 2>/dev/null < "$SANDBOX/help-count" | tr -d ' ')" \
    "agy --help is probed once per call, not once per capability"
}

t_offload_keeps_answer_indentation() {
  FAKE_AGY_RESPONSE="$(printf 'findings:\n  - nested item\n      code line')"
  export FAKE_AGY_RESPONSE
  run_wrapper offload --dir "$SANDBOX" "q"
  assert_eq 0 "$RC" "offload should succeed"
  assert_contains "$OUT" "$(printf '\n  - nested item\n      code line')" "indentation must survive"
  assert_not_contains "$OUT" $'\r' "the answer must not pick up CRs"
}

t_offload_short_budget_still_runs() {
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper offload --dir "$SANDBOX" --budget 90 "q"
  assert_eq 0 "$RC" "a budget under the retry floor must still make one attempt"
  assert_contains "$OUT" "ok" "and return its answer"
}

t_offload_context_path_is_native() {
  # Under MSYS agy is a Windows .exe; the path inside the prompt has to be one
  # it can open. A stub cygpath stands in for the real one.
  cat > "$SANDBOX/bin/cygpath" <<'STUB'
#!/usr/bin/env bash
printf 'NATIVE:%s' "$2"
STUB
  chmod +x "$SANDBOX/bin/cygpath"
  export FAKE_AGY_RESPONSE="ok"
  run_wrapper_stdin "BODY" offload --dir "$SANDBOX" --stdin "q"
  assert_eq 0 "$RC" "offload should succeed"
  argv_contains "read this file first: NATIVE:" || fail_msg "the context path in the prompt must be converted"
}

make_review_repo() {
  mkdir -p "$SANDBOX/repo"
  ( cd "$SANDBOX/repo" \
    && git init -q . \
    && git config user.email t@e.st && git config user.name test \
    && echo one > a.txt && echo one > b.txt && echo "SECRET=old" > .env \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
}

t_review_paths_without_focus() {
  make_review_repo
  ( cd "$SANDBOX/repo" && echo A-CHANGE >> a.txt && echo B-CHANGE >> b.txt ) >/dev/null 2>&1
  export FAKE_AGY_RESPONSE="ok" FAKE_AGY_CTX_COPY="$SANDBOX/ctx.md"
  ( cd "$SANDBOX/repo" && bash "$WRAPPER" review -- a.txt ) >/dev/null 2>&1
  if argv_contains "Focus: a.txt"; then fail_msg "a path after a leading -- is not a focus"; fi
  assert_contains "$(cat "$SANDBOX/ctx.md" 2>/dev/null)" "A-CHANGE" "the named path is reviewed"
  assert_not_contains "$(cat "$SANDBOX/ctx.md" 2>/dev/null)" "B-CHANGE" "and nothing else"
}

t_review_focus_and_paths() {
  make_review_repo
  ( cd "$SANDBOX/repo" && echo A-CHANGE >> a.txt && echo B-CHANGE >> b.txt ) >/dev/null 2>&1
  export FAKE_AGY_RESPONSE="ok" FAKE_AGY_CTX_COPY="$SANDBOX/ctx.md"
  ( cd "$SANDBOX/repo" && bash "$WRAPPER" review "error handling" -- b.txt ) >/dev/null 2>&1
  argv_contains "Focus: error handling" || fail_msg "the focus is passed on"
  assert_contains "$(cat "$SANDBOX/ctx.md" 2>/dev/null)" "B-CHANGE" "the named path is reviewed"
  assert_not_contains "$(cat "$SANDBOX/ctx.md" 2>/dev/null)" "A-CHANGE" "and nothing else"
}

t_review_refuses_a_dotenv_only_diff() {
  make_review_repo
  ( cd "$SANDBOX/repo" && echo "SECRET=LEAKED-VALUE" > .env ) >/dev/null 2>&1
  export FAKE_AGY_RESPONSE="ok"
  local err rc=0
  err="$( ( cd "$SANDBOX/repo" && bash "$WRAPPER" review ) 2>&1 >/dev/null )" || rc=$?
  assert_eq 1 "$rc" "nothing reviewable is a failure, not an empty review"
  assert_contains "$err" ".env files" "and says why"
  if [ -s "$FAKE_AGY_ARGV_LOG" ]; then fail_msg "agy must not be called with an empty diff"; fi
}

t_review_never_names_an_untracked_dotenv() {
  make_review_repo
  ( cd "$SANDBOX/repo" && echo A-CHANGE >> a.txt && echo x > new.js && echo "K=v" > .env.local ) >/dev/null 2>&1
  export FAKE_AGY_RESPONSE="ok"
  ( cd "$SANDBOX/repo" && bash "$WRAPPER" review ) >/dev/null 2>&1
  argv_contains "new.js" || fail_msg "untracked source files are named"
  if argv_contains ".env.local"; then fail_msg "an untracked .env must not be named for reading"; fi
}

t_fanout_prompt_that_looks_like_a_flag() {
  export FAKE_AGY_RESPONSE="an answer"
  run_wrapper fanout --dir "$SANDBOX" --prompt "--help"
  assert_contains "$OUT" "an answer" "a dash-leading prompt is still a prompt"
}

t_second_opinion_runs_in_the_target_dir() {
  install_fake_claude
  mkdir -p "$SANDBOX/proj"
  export FAKE_CLAUDE_PWD="$SANDBOX/claude-pwd.txt"
  run_wrapper second-opinion --dir "$SANDBOX/proj" "why"
  assert_eq 0 "$RC" "the second opinion should succeed"
  assert_eq "$(cd "$SANDBOX/proj" && pwd)" "$(cat "$FAKE_CLAUDE_PWD" 2>/dev/null)" "claude must start in --dir"
}

t_legacy_sed_fallback_escapes_the_model_name() {
  # Without python3 the settings patch falls back to sed, where `/` and `&`
  # in the replacement are metacharacters.
  local tools="$SANDBOX/nopy" t
  mkdir -p "$tools"
  for t in mktemp sed mv; do
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$t")" > "$tools/$t"
    chmod +x "$tools/$t"
  done
  ( source "$WRAPPER"; PATH="$tools"; _patch_model_field 'Team A/B & Co' ) >/dev/null 2>&1
  assert_eq 'Team A/B & Co' "$(settings_model)" "the model name must be written literally"
}

# --------------------------------------------------------- capabilities ----
t_check_reports_offload_capabilities() {
  run_wrapper check
  assert_contains "$OUT" '"planMode": true'   "a modern build supports plan mode"
  assert_contains "$OUT" '"jsonOutput": true' "and structured output"
  assert_contains "$OUT" '"offload": true'    "so offloading is available"
}

t_check_reports_offload_unavailable_on_old_builds() {
  export FAKE_AGY_MODE=old-no-mode
  run_wrapper check
  assert_contains "$OUT" '"planMode": false' "an old build has no plan mode"
  assert_contains "$OUT" '"offload": false'  "so offloading is unavailable"
}

# =================================================================== run ===
printf '\n%s\n' "agy-run.sh test suite"

printf '\n%s\n' "catalogue discovery"
it "catalogue: parses TSV from agy models"              t_catalogue_parses_tsv
it "catalogue: strips spinner noise"                    t_catalogue_strips_spinner_noise
it "catalogue: writes a cache"                          t_catalogue_writes_cache
it "catalogue: serves a fresh cache"                    t_catalogue_uses_cache_when_fresh
it "catalogue: --refresh bypasses the cache"            t_catalogue_refresh_bypasses_cache
it "catalogue: falls back to a stale cache offline"     t_catalogue_falls_back_to_stale_cache_offline
it "catalogue: prefers JSON output when supported"      t_catalogue_prefers_json_when_supported
it "catalogue: reports absence clearly"                 t_catalogue_absent_reports_clearly

printf '\n%s\n' "alias resolution"
it "alias: flash picks the newest Flash"                t_alias_flash_picks_newest_flash
it "alias: flash never picks a retired model"           t_alias_flash_never_resolves_to_retired_model
it "alias: fast is low-effort Flash"                    t_alias_fast_is_low_effort_flash
it "alias: balanced is high-effort Flash"               t_alias_balanced_is_high_effort_flash
it "alias: deep is high-effort Pro"                     t_alias_deep_is_high_effort_pro
it "alias: flash-medium"                                t_alias_flash_medium
it "alias: pro-low"                                     t_alias_pro_low
it "alias: opus"                                        t_alias_opus
it "alias: sonnet"                                      t_alias_sonnet
it "alias: gpt-oss"                                     t_alias_gpt_oss
it "alias: case-insensitive"                            t_alias_is_case_insensitive
it "alias: resolution is announced on stderr"           t_alias_resolution_is_announced
it "alias: announcement can be silenced"                t_alias_announcement_can_be_silenced

printf '\n%s\n' "future-proofing"
it "future: flash follows a new Gemini generation"      t_future_flash_follows_new_generation
it "future: deep follows a new Pro generation"          t_future_pro_follows_new_generation
it "future: opus follows a new Claude generation"       t_future_opus_follows_new_generation
it "future: a family absent today resolves later"       t_future_new_family_resolves
it "future: version ordering is numeric"                t_future_version_ordering_is_numeric
it "future: newest ignores locale collation"            t_future_newest_ignores_locale_collation
it "future: claude picks the newest version, not name"  t_future_claude_picks_newest_version_not_name
it "future: gemini prefers high effort on a tie"        t_future_gemini_prefers_high_effort_on_a_tie
it "future: unknown models pass through to agy"         t_future_unknown_model_is_passed_through
it "future: exact id resolves without a warning"        t_exact_id_resolves_without_warning
it "future: display name maps to id"                    t_exact_display_name_resolves_to_id
it "future: display name match ignores case"            t_display_name_is_case_insensitive
it "future: empty --model exits 64"                     t_empty_model_exits_64
it "shape: renamed effort suffixes refuse to guess"     t_effort_suffix_renamed_refuses_to_guess
it "shape: a lone unsuffixed model is used, with note"  t_effort_single_unsuffixed_model_is_used_with_note
it "shape: falling a generation behind is flagged"      t_effort_older_generation_is_flagged
it "shape: today's catalogue resolves without notes"    t_effort_current_catalogue_is_silent
it "shape: aliases skip previews"                       t_preview_is_skipped_by_aliases
it "shape: a preview flagged only in the label"         t_preview_marked_only_in_label_is_skipped
it "shape: aliases skip experimental ids"               t_experimental_is_skipped_by_aliases
it "shape: preview markers match whole words only"      t_preview_filter_matches_whole_words_only
it "shape: AGY_ALLOW_PREVIEW=1 lets aliases pick them"  t_preview_allowed_by_env
it "shape: a preview-only family errors with a hint"    t_preview_only_family_errors_with_hint
it "shape: an exact preview id still works"             t_preview_exact_id_is_honoured
it "future: model table is live, not hardcoded"         t_model_table_is_live_not_hardcoded
it "future: help shows live models"                     t_help_contains_no_hardcoded_model_versions

printf '\n%s\n' "user-defined aliases"
it "user alias: resolves through a builtin"             t_user_alias_resolves
it "user alias: pins an exact id"                       t_user_alias_can_pin_exact_id
it "user alias: bare whitespace form"                   t_user_alias_accepts_bare_whitespace_form
it "user alias: shadows a builtin"                      t_user_alias_shadows_builtin
it "user alias: ignores comments and junk"              t_user_alias_ignores_comments_and_junk
it "user alias: cycles are detected"                    t_user_alias_loop_is_detected
it "user alias: control characters are stripped"        t_user_alias_strips_control_characters
it "user alias: project-local files are ignored"        t_project_local_alias_file_is_ignored

printf '\n%s\n' "effort"
it "effort: forwarded to agy"                           t_effort_is_forwarded
it "effort: works without --model"                      t_effort_without_model_is_forwarded
it "effort: rejects a bad value"                        t_effort_rejects_bad_value
it "effort: rejects a missing value"                    t_effort_rejects_missing_value
it "effort: dropped on builds without the flag"         t_effort_skipped_on_builds_without_the_flag

printf '\n%s\n' "invocation"
it "invoke: native --model is used"                     t_native_model_flag_is_used
it "invoke: no --model leaves the default alone"        t_no_model_means_no_model_flag
it "invoke: settings.json untouched on native path"     t_settings_file_untouched_on_native_path
it "invoke: extra args forwarded after the prompt"      t_extra_args_forwarded_after_prompt
it "invoke: shell metacharacters in prompt are safe"    t_prompt_with_shell_metacharacters_is_safe
it "invoke: dash-leading model stays a value"           t_model_name_starting_with_dash_is_safe
it "invoke: missing prompt exits 64"                    t_missing_prompt_exits_64
it "invoke: agy exit code propagates"                   t_agy_exit_code_is_propagated
it "invoke: unknown subcommand exits 64"                t_unknown_subcommand_exits_64

printf '\n%s\n' "legacy fallback (agy without --model)"
it "legacy: patches then restores settings.json"        t_legacy_path_patches_and_restores_settings
it "legacy: restores settings.json after a failure"     t_legacy_path_restores_after_failure
it "legacy: detected from agy --help"                   t_legacy_path_detected_from_help
it "legacy: orphaned backup is recovered"               t_legacy_orphan_backup_is_recovered

printf '\n%s\n' "check / review"
it "check: reports capabilities"                        t_check_reports_capabilities
it "check: reports an old build"                        t_check_reports_old_build
it "check: reports a missing binary"                    t_check_reports_missing_binary
it "check: emits valid JSON"                            t_check_output_is_valid_json
it "check: reports offload capabilities"                t_check_reports_offload_capabilities
it "check: no offload on old builds"                    t_check_reports_offload_unavailable_on_old_builds
it "review: requires a diff"                            t_review_requires_a_diff
it "review: honours --model"                            t_review_accepts_model_flag
it "review: diff goes in as context, not argv"           t_review_sends_the_diff_as_context_not_argv
it "review: omits .env, keeps .env.example"             t_review_omits_dotenv_but_keeps_the_example
it "review: names untracked files"                      t_review_names_untracked_files

printf '\n%s\n' "image"
it "image: rejects a non-image IMAGE_PATH"              t_image_rejects_non_image_path_from_model
it "image: copies a genuine image"                      t_image_copies_real_image
it "image: requires a description"                      t_image_requires_description
it "image: warns when no path is found"                 t_image_warns_when_no_path_found

printf '\n%s\n' "offload"
it "offload: runs agy read-only in plan mode"              t_offload_runs_read_only
it "offload: injects the read-only guard"                  t_offload_injects_the_guard
it "offload: adds every workspace root"                    t_offload_adds_workspace_roots
it "offload: --add-dir rejects a file"                     t_offload_rejects_a_file_as_add_dir
it "offload: defaults to the balanced tier"                t_offload_defaults_to_the_balanced_tier
it "offload: honours an explicit --model"                  t_offload_honours_an_explicit_model
it "offload: --tier is a synonym for --model"              t_offload_accepts_tier_as_a_synonym
it "offload: reports telemetry on stderr"                  t_offload_reports_telemetry
it "offload: marks a partial answer"                       t_offload_marks_a_partial_answer
it "offload: explains an auto-denied command"              t_offload_explains_an_auto_denied_shell_command
it "offload: falls back on a capacity failure"             t_offload_falls_back_on_a_capacity_failure
it "offload: does not retry other failures"                t_offload_does_not_retry_other_failures
it "offload: stdin becomes a context file"                 t_offload_puts_stdin_in_a_context_file
it "offload: ignores stdin without --stdin"                t_offload_ignores_stdin_without_the_flag
it "offload: fails closed without plan mode"               t_offload_fails_closed_without_plan_mode
it "offload: requires a prompt"                            t_offload_requires_a_prompt
it "offload: rejects a bad --budget"                       t_offload_rejects_a_bad_budget
it "offload: warns about token files in a root"            t_offload_warns_about_token_files_in_a_root

printf '\n%s\n' "fanout"
it "fanout: runs several prompts"                          t_fanout_runs_several_prompts
it "fanout: reads a jobs file"                             t_fanout_reads_a_jobs_file
it "fanout: forwards per-job addDir"                    t_fanout_forwards_per_job_add_dirs
it "fanout: explains a mis-escaped Windows path"           t_fanout_explains_a_misescaped_windows_path
it "fanout: requires work"                                 t_fanout_requires_work

printf '\n%s\n' "second opinion"
it "second-opinion: runs claude read-only"                 t_second_opinion_runs_claude_read_only
it "second-opinion: context goes on stdin"                 t_second_opinion_passes_context_on_stdin
it "second-opinion: reports an auth failure"               t_second_opinion_reports_an_auth_failure
it "second-opinion: exits 127 without claude"              t_second_opinion_without_claude_exits_127
it "second-opinion: rejects a bad --effort"                t_second_opinion_rejects_a_bad_effort
it "second-opinion: default timeout fits the tool limit"   t_second_opinion_default_timeout_fits_the_tool_limit
it "second-opinion: --timeout can raise the limit"         t_second_opinion_timeout_can_be_raised

printf '\n%s\n' "reverse bridge (agy drives Claude Code)"
it "ask-claude: read-only by default"                      t_ask_claude_is_read_only_by_default
it "ask-claude: ignores project settings in both modes"    t_ask_claude_ignores_project_settings
it "ask-claude: --allow-write edits, never runs commands"  t_ask_claude_allow_write_edits_but_never_runs_commands
it "ask-claude: --allow-write needs an explicit --dir"     t_ask_claude_write_needs_an_explicit_dir
it "ask-claude: --allow-write refuses a home folder"       t_ask_claude_write_refuses_a_home_folder
it "ask-claude: write fails closed without --restricted"   t_ask_claude_write_fails_closed_without_restricted
it "ask-claude: --read-only and --allow-write conflict"    t_ask_claude_modes_contradict
it "ask-claude: a flag after the task is refused"          t_ask_claude_rejects_a_flag_after_the_task
it "ask-claude: an unknown flag is refused"                t_ask_claude_rejects_an_unknown_flag
it "ask-claude: an unquoted task is joined"                t_ask_claude_joins_an_unquoted_task
it "ask-claude: context goes on stdin"                     t_ask_claude_passes_context_on_stdin
it "ask-claude: default timeout is 900s"                   t_ask_claude_default_timeout
it "bridge: install writes the launcher and the skill"     t_bridge_install_writes_launcher_and_skill
it "bridge: the launcher runs the installed plugin"        t_bridge_launcher_runs_the_installed_plugin
it "bridge: the launcher follows the registry"             t_bridge_launcher_follows_the_registry
it "bridge: without a registry, newest cached version"     t_bridge_launcher_falls_back_to_the_newest_cached_version
it "bridge: a plugin older than the bridge is refused"     t_bridge_launcher_refuses_a_plugin_older_than_the_bridge
it "bridge: Windows arguments arrive intact"               t_bridge_launcher_decodes_windows_arguments
it "bridge: Windows gets the PowerShell launcher"          t_bridge_install_on_windows_adds_the_powershell_launcher
it "bridge: install keeps a file it did not write"         t_bridge_install_keeps_a_file_it_did_not_write
it "bridge: uninstall removes only its own files"          t_bridge_uninstall_removes_only_its_own_files
it "bridge: status reports agy's allow rules"              t_bridge_status_reports_agy_rules
it "bridge: the skill template keeps an & in a path"       t_bridge_skill_text_keeps_ampersands

printf '\n%s\n' "security"
it "security: cache dir is not world-readable"          t_cache_dir_is_not_world_readable
it "security: malformed catalogue rows are dropped"     t_catalogue_rejects_malformed_rows
it "security: alias values are never executed"          t_aliases_file_is_never_executed
it "security: catalogue content is never executed"      t_catalogue_content_is_never_executed
it "security: offload refuses agy flags after the prompt"  t_offload_refuses_flags_after_the_prompt
it "security: offload still forwards --sandbox"            t_offload_forwards_sandbox_after_the_prompt
it "security: second-opinion ignores project settings"     t_second_opinion_ignores_project_settings
it "security: commands pre-approve only their own call"    t_commands_preapprove_only_their_own_wrapper_call
it "security: secret-holding paths are recognised"         t_secret_path_predicate
it "security: review omits a .env under a spaced dir"      t_review_omits_dotenv_in_a_dir_with_a_space
it "security: review omits a .env renamed from example"    t_review_omits_dotenv_renamed_from_the_example
it "security: review omits files under .envs/"             t_review_omits_files_under_a_dotenvs_dir
it "security: review omits .env whatever its case"         t_review_omits_dotenv_whatever_its_case
it "security: review omits a root .env from a subfolder"   t_review_omits_a_root_dotenv_from_a_subfolder

printf '
%s
' "robustness"
it "robust: capability probe survives large help output"  t_capability_probe_is_not_racy
it "robust: repeated calls resolve identically"           t_repeated_calls_are_stable

printf '\n%s\n' "regressions"
it "regress: check JSON escapes backslashes and newlines"  t_json_escaping_round_trips
it "regress: agy --help is probed once per offload"        t_offload_probes_agy_help_once
it "regress: offload keeps the answer's indentation"       t_offload_keeps_answer_indentation
it "regress: a short --budget still makes one attempt"     t_offload_short_budget_still_runs
it "regress: context path in the prompt is native"         t_offload_context_path_is_native
it "regress: review -- paths works without a focus"        t_review_paths_without_focus
it "regress: review focus -- paths scopes the diff"        t_review_focus_and_paths
it "regress: review refuses a .env-only diff"              t_review_refuses_a_dotenv_only_diff
it "regress: review never names an untracked .env"         t_review_never_names_an_untracked_dotenv
it "regress: fanout prompt that looks like a flag"         t_fanout_prompt_that_looks_like_a_flag
it "regress: second-opinion runs in --dir"                 t_second_opinion_runs_in_the_target_dir
it "regress: legacy sed fallback escapes / and &"          t_legacy_sed_fallback_escapes_the_model_name

printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '%s  %d passed' "$(green PASS)" "$PASS"
else
  printf '%s  %d passed, %d failed' "$(red FAIL)" "$PASS" "$FAIL"
fi
if [ "$SKIP" -gt 0 ]; then printf ', %d skipped' "$SKIP"; fi
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  printf '\nfailed:\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
