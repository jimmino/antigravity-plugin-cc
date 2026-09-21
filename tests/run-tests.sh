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
  unset FAKE_CLAUDE_ARGV FAKE_CLAUDE_STDIN FAKE_CLAUDE_RESULT FAKE_CLAUDE_ERROR 2>/dev/null || true
  unset AGY_FORCE_LEGACY_MODEL AGY_QUIET 2>/dev/null || true
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

t_future_unknown_model_is_passed_through() {
  # agy knows about custom models the wrapper cannot enumerate, so an
  # unrecognised name must reach agy rather than being rejected locally.
  run_wrapper ask --model "my-private-endpoint-v2" "hi"
  assert_eq 0 "$RC" "unknown models must not be rejected by the wrapper"
  argv_has "my-private-endpoint-v2" || fail_msg "unknown model must be forwarded verbatim"
  assert_contains "$ERR" "passing it to agy as-is" "pass-through should be noted"
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
  export FAKE_AGY_RESPONSE="ok"
  local err
  err="$( ( cd "$SANDBOX/repo" && bash "$WRAPPER" review ) 2>&1 >/dev/null )"
  assert_contains "$err" "omitted from the review" ".env must be dropped, loudly"
  if argv_contains "LEAKED-VALUE"; then fail_msg "a .env value must never reach the prompt"; fi
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
  # A PATH narrow enough to hide claude still has to be able to run bash.
  local bin_dir minimal outf errf
  bin_dir="$(dirname "$(command -v bash)")"
  minimal="$SANDBOX/bin:$bin_dir"
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
it "future: unknown models pass through to agy"         t_future_unknown_model_is_passed_through
it "future: exact id resolves without a warning"        t_exact_id_resolves_without_warning
it "future: display name maps to id"                    t_exact_display_name_resolves_to_id
it "future: display name match ignores case"            t_display_name_is_case_insensitive
it "future: empty --model exits 64"                     t_empty_model_exits_64
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

printf '\n%s\n' "security"
it "security: cache dir is not world-readable"          t_cache_dir_is_not_world_readable
it "security: malformed catalogue rows are dropped"     t_catalogue_rejects_malformed_rows
it "security: alias values are never executed"          t_aliases_file_is_never_executed
it "security: catalogue content is never executed"      t_catalogue_content_is_never_executed

printf '
%s
' "robustness"
it "robust: capability probe survives large help output"  t_capability_probe_is_not_racy
it "robust: repeated calls resolve identically"           t_repeated_calls_are_stable

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
