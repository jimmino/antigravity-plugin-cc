#!/usr/bin/env bash
# agy-run.sh — Claude Code wrapper around Google Antigravity CLI (`agy`).
# Subcommands: check | models | ask | review | image | help.
#
# Model selection is *discovered*, never hardcoded: `agy models` is the source
# of truth, aliases resolve against that live catalogue, and anything the
# wrapper does not recognise is handed to `agy` verbatim so custom models and
# future catalogue entries keep working without a plugin release.

set -euo pipefail

# ---------------------------------------------------------------- paths ----
AGY_HOME="${AGY_HOME:-${HOME}/.gemini/antigravity-cli}"
AGY_SETTINGS_FILE="${AGY_SETTINGS_FILE:-${AGY_HOME}/settings.json}"
AGY_SETTINGS_DIR="$(dirname "$AGY_SETTINGS_FILE")"
AGY_SETTINGS_LOCKDIR="${AGY_SETTINGS_DIR}/.agy-plugin.lock"
AGY_SETTINGS_BACKUP="${AGY_SETTINGS_FILE}.agy-plugin.bak"
AGY_SETTINGS_SENTINEL="${AGY_SETTINGS_DIR}/.agy-plugin.patched"

AGY_PLUGIN_CACHE_DIR="${AGY_PLUGIN_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/agy-plugin}"
AGY_MODELS_CACHE="${AGY_PLUGIN_CACHE_DIR}/models.tsv"
AGY_MODELS_CACHE_TTL="${AGY_MODELS_CACHE_TTL:-3600}"

AGY_PLUGIN_CONFIG_DIR="${AGY_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agy-plugin}"
# Deliberately user-scoped only: a project-local alias file would let any
# checked-out repo silently redirect which model your prompts are sent to.
AGY_ALIASES_FILE="${AGY_ALIASES_FILE:-${AGY_PLUGIN_CONFIG_DIR}/aliases.conf}"

AGY_ALIAS_MAX_DEPTH=5

# ------------------------------------------------------------ discovery ----
find_agy() {
  if command -v agy >/dev/null 2>&1; then
    command -v agy
    return 0
  fi
  for candidate in \
      "$HOME/.local/bin/agy" \
      "$HOME/AppData/Local/agy/bin/agy.exe" \
      "$HOME/AppData/Local/agy/bin/agy" \
      "/opt/antigravity/bin/agy" \
      "/usr/local/bin/agy"; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

auth_status() {
  if [ -n "${ANTIGRAVITY_API_KEY:-}" ]; then
    echo "api-key"
  elif [ -d "$HOME/.config/antigravity" ] || [ -d "$AGY_HOME" ]; then
    echo "oauth"
  else
    echo "missing"
  fi
}

j_esc() {
  local s="$1"
  s="${s//\/\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\n}"
  s="${s//$'\r'/\r}"
  s="${s//$'\t'/\t}"
  printf '%s' "$s"
}

# Capability probe against the *installed* agy, so the wrapper adapts to old
# and new builds instead of assuming a feature set.
_AGY_HELP_CACHE=""
agy_help_text() {
  if [ -z "$_AGY_HELP_CACHE" ]; then
    local path
    path="$(find_agy 2>/dev/null || true)"
    [ -n "$path" ] || return 1
    _AGY_HELP_CACHE="$("$path" --help 2>&1 || true)"
  fi
  printf '%s' "$_AGY_HELP_CACHE"
}

agy_supports_model_flag() {
  [ "${AGY_FORCE_LEGACY_MODEL:-0}" = "1" ] && return 1
  agy_help_text 2>/dev/null | grep -qE '^[[:space:]]*--model([[:space:]]|$)'
}

agy_supports_effort_flag() {
  agy_help_text 2>/dev/null | grep -qE '^[[:space:]]*--effort([[:space:]]|$)'
}

agy_supports_models_cmd() {
  agy_help_text 2>/dev/null | grep -qE '^[[:space:]]*models([[:space:]]|$)'
}

# ------------------------------------------------------------ catalogue ----
# Normalised catalogue format, one model per line: "<id><TAB><label>".

_cache_age_seconds() {
  local f="$1" now mtime
  [ -f "$f" ] || { echo "-1"; return 0; }
  now="$(date +%s 2>/dev/null || echo 0)"
  mtime="$(date -r "$f" +%s 2>/dev/null || stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
  if [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ]; then
    echo $(( now - mtime ))
  else
    echo "-1"
  fi
}

_json_models_to_tsv() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - <<'PY'
import json, sys

def walk(node):
    if isinstance(node, dict):
        mid = node.get("id") or node.get("slug") or node.get("name") or node.get("model")
        label = node.get("label") or node.get("displayName") or node.get("display_name") or node.get("title")
        if isinstance(mid, str) and mid.strip():
            yield mid.strip(), (label if isinstance(label, str) and label.strip() else mid).strip()
            return
        for v in node.values():
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

seen = set()
for mid, label in walk(data):
    if "\t" in mid or "\n" in mid or mid in seen:
        continue
    seen.add(mid)
    print(f"{mid}\t{label}")
PY
}

# Drop progress noise / blank lines and keep only plausible "<id><TAB><label>"
# rows. Control characters are stripped so nothing downstream sees an escape
# sequence from the CLI's spinner.
_sanitise_catalogue() {
  tr -d '\000-\010\013\014\016-\037\177' \
    | awk -F'\t' '
        NF >= 2 {
          id = $1; label = $2
          gsub(/^[ \t]+|[ \t]+$/, "", id)
          gsub(/^[ \t]+|[ \t]+$/, "", label)
          if (id == "" || label == "") next
          if (id ~ / /) next            # ids are slugs; a space means noise
          if (seen[id]++) next
          print id "\t" label
        }'
}

# Newer agy builds grew `models --output-format json`; older ones only print
# TSV. Try the structured form first and fall back, so both keep working.
_fetch_catalogue_raw() {
  local path="$1" out="" parsed=""
  if out="$("$path" models --output-format json 2>/dev/null)" && [ -n "$out" ]; then
    if parsed="$(printf '%s' "$out" | _json_models_to_tsv 2>/dev/null)" && [ -n "$parsed" ]; then
      printf '%s' "$parsed" | _sanitise_catalogue
      return 0
    fi
  fi
  # TSV form: "<id><TAB><label>" on stdout, spinner/progress on stderr.
  out="$("$path" models 2>/dev/null)" || return 1
  printf '%s' "$out" | _sanitise_catalogue
}

_write_cache_atomic() {
  local content="$1" tmp
  mkdir -p "$AGY_PLUGIN_CACHE_DIR" 2>/dev/null || return 1
  chmod 700 "$AGY_PLUGIN_CACHE_DIR" 2>/dev/null || true
  tmp="$(mktemp "${AGY_MODELS_CACHE}.XXXXXX" 2>/dev/null)" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$AGY_MODELS_CACHE" || { rm -f "$tmp"; return 1; }
}

# Prints the catalogue on stdout. Never fatal: an empty catalogue degrades the
# wrapper to pass-through mode rather than blocking the call.
_CATALOGUE_CACHE=""
_CATALOGUE_LOADED=0
catalogue() {
  local force="${1:-0}"
  if [ "$_CATALOGUE_LOADED" = "1" ] && [ "$force" != "1" ]; then
    printf '%s' "$_CATALOGUE_CACHE"
    return 0
  fi

  local age fresh=""
  age="$(_cache_age_seconds "$AGY_MODELS_CACHE")"
  if [ "$force" != "1" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$AGY_MODELS_CACHE_TTL" ]; then
    fresh="$(cat "$AGY_MODELS_CACHE" 2>/dev/null || true)"
  fi

  if [ -z "$fresh" ]; then
    local path
    path="$(find_agy 2>/dev/null || true)"
    if [ -n "$path" ] && agy_supports_models_cmd; then
      local fetched=""
      fetched="$(_fetch_catalogue_raw "$path" 2>/dev/null || true)"
      if [ -n "$fetched" ]; then
        fresh="$fetched"
        _write_cache_atomic "$fetched" || true
      fi
    fi
  fi

  # Offline / fetch failure: fall back to a stale cache rather than nothing.
  if [ -z "$fresh" ] && [ -f "$AGY_MODELS_CACHE" ]; then
    fresh="$(cat "$AGY_MODELS_CACHE" 2>/dev/null || true)"
  fi

  _CATALOGUE_CACHE="$fresh"
  _CATALOGUE_LOADED=1
  printf '%s' "$_CATALOGUE_CACHE"
}

catalogue_ids()    { catalogue | awk -F'\t' 'NF>=2 {print $1}'; }
catalogue_labels() { catalogue | awk -F'\t' 'NF>=2 {print $2}'; }

_lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# Exact id match, then exact label match, then case-insensitive either way.
# Prints "<id><TAB><label>".
catalogue_lookup() {
  local needle="${1:-}"
  [ -n "$needle" ] || return 1
  catalogue | awk -F'\t' -v needle="$needle" '
    NF>=2 {
      ids[NR]=$1; labels[NR]=$2; n=NR
      if ($1 == needle || $2 == needle) { print $1 "\t" $2; found=1; exit }
    }
    END {
      if (found) exit
      for (i=1; i<=n; i++) {
        if (tolower(ids[i]) == tolower(needle) || tolower(labels[i]) == tolower(needle)) {
          print ids[i] "\t" labels[i]; exit
        }
      }
      exit 1
    }'
}

# Portable "newest wins" ordering: zero-pad every digit run so a plain lexical
# sort orders 3.10 after 3.9 and we never depend on GNU `sort -V`.
_pick_newest() {
  awk '
    function padnums(s,   out, c, num, i, n) {
      out=""; num=""; n=length(s)
      for (i=1; i<=n; i++) {
        c = substr(s, i, 1)
        if (c ~ /^[0-9]$/) { num = num c }
        else { if (num != "") { out = out sprintf("%06d", num+0); num="" } ; out = out c }
      }
      if (num != "") out = out sprintf("%06d", num+0)
      return out
    }
    length($0) > 0 { print padnums($0) "\t" $0 }
  ' | sort | tail -n1 | cut -f2-
}

# Resolve "family + optional effort" against the live catalogue.
_resolve_family() {
  local family="$1" effort="${2:-}"
  local ids
  ids="$(catalogue_ids | grep -iE -- "$family" || true)"
  [ -n "$ids" ] || return 1

  if [ -n "$effort" ]; then
    local scoped
    scoped="$(printf '%s\n' "$ids" | grep -iE -- "-${effort}\$" || true)"
    if [ -n "$scoped" ]; then
      printf '%s\n' "$scoped" | _pick_newest
      return 0
    fi
  fi

  # No effort variant for this family (e.g. a single Claude entry): prefer ids
  # that carry no effort suffix at all, else just the newest in the family.
  local plain
  plain="$(printf '%s\n' "$ids" | grep -ivE -- '-(low|medium|high)$' || true)"
  if [ -n "$plain" ]; then
    printf '%s\n' "$plain" | _pick_newest
  else
    printf '%s\n' "$ids" | _pick_newest
  fi
}

# --------------------------------------------------------- user aliases ----
# Format: `name = target`, `name: target` or `name target`; `#` starts a
# comment. Values are validated, never evaluated.
_alias_rows() {
  [ -f "$AGY_ALIASES_FILE" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (match(line, /^[A-Za-z0-9._-]+[[:space:]]*[=:][[:space:]]*/)) {
        key = substr(line, 1, RLENGTH)
        val = substr(line, RLENGTH + 1)
        sub(/[[:space:]]*[=:][[:space:]]*$/, "", key)
      } else if (match(line, /^[A-Za-z0-9._-]+[[:space:]]+/)) {
        key = substr(line, 1, RLENGTH)
        val = substr(line, RLENGTH + 1)
        sub(/[[:space:]]+$/, "", key)
      } else { next }
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      if (val == "" || length(val) > 200) next
      print key "\t" val
    }
  ' "$AGY_ALIASES_FILE" 2>/dev/null | tr -d '\000-\010\013\014\016-\037\177'
}

user_alias_lookup() {
  local name; name="$(_lower "${1:-}")"
  [ -n "$name" ] || return 1
  local row
  row="$(_alias_rows | awk -F'\t' -v want="$name" 'tolower($1) == want { print $2; exit }')"
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

user_alias_names() { _alias_rows; }

# ----------------------------------------------------- built-in aliases ----
# Intent-shaped, not version-shaped: each one names a *family and effort*, and
# the concrete model is whatever the live catalogue currently offers there.
# Adding a "Gemini 4 Flash" upstream makes `flash` point at it automatically.
builtin_alias_spec() {
  case "$(_lower "${1:-}")" in
    fast)                     echo "flash|low" ;;
    balanced)                 echo "flash|high" ;;
    deep)                     echo "pro|high" ;;
    flash-low)                echo "flash|low" ;;
    flash-medium|flash-med)   echo "flash|medium" ;;
    flash|flash-high)         echo "flash|high" ;;
    pro-low)                  echo "pro|low" ;;
    pro-medium|pro-med)       echo "pro|medium" ;;
    pro|pro-high)             echo "pro|high" ;;
    sonnet|claude-sonnet)     echo "sonnet|" ;;
    opus|claude-opus)         echo "opus|" ;;
    haiku|claude-haiku)       echo "haiku|" ;;
    gpt-oss|gpt-oss-120b)     echo "gpt-oss|" ;;
    gemini)                   echo "gemini|" ;;
    claude)                   echo "claude|" ;;
    *) return 1 ;;
  esac
}

builtin_alias_names() {
  cat <<'ALIASES'
fast	newest Flash, low effort
balanced	newest Flash, high effort
deep	newest Pro, high effort
flash-low	newest Flash, low effort
flash-medium (flash-med)	newest Flash, medium effort
flash (flash-high)	newest Flash, high effort
pro-low	newest Pro, low effort
pro-medium (pro-med)	newest Pro, medium effort
pro (pro-high)	newest Pro, high effort
sonnet (claude-sonnet)	newest Claude Sonnet
opus (claude-opus)	newest Claude Opus
haiku (claude-haiku)	newest Claude Haiku
gpt-oss (gpt-oss-120b)	newest GPT-OSS
gemini	newest Gemini of any family
claude	newest Claude of any family
ALIASES
}

# ------------------------------------------------------------- resolver ----
# Sets RESOLVED_ID / RESOLVED_LABEL / RESOLVED_VIA.
RESOLVED_ID=""
RESOLVED_LABEL=""
RESOLVED_VIA=""

resolve_model() {
  local input="${1:-}" depth="${2:-0}"

  if [ -z "$input" ]; then
    echo "error: --model requires a non-empty value (e.g. --model pro)" >&2
    print_model_table 2
    local current; current="$(_current_default_model 2>/dev/null || true)"
    if [ -n "$current" ]; then
      echo >&2
      echo "Tip: omit --model to use your current default (\"$current\")." >&2
    fi
    exit 64
  fi

  if [ "$depth" -gt "$AGY_ALIAS_MAX_DEPTH" ]; then
    echo "error: alias resolution loop detected while resolving '$input'" >&2
    echo "       check $AGY_ALIASES_FILE for a cycle." >&2
    exit 64
  fi

  # 1. Exact catalogue hit (id or label) wins — no guessing needed.
  local hit
  if hit="$(catalogue_lookup "$input" 2>/dev/null)" && [ -n "$hit" ]; then
    RESOLVED_ID="${hit%%$'\t'*}"
    RESOLVED_LABEL="${hit#*$'\t'}"
    RESOLVED_VIA="catalogue"
    return 0
  fi

  # 2. User-defined alias (may point at another alias, an id or a label).
  local target
  if target="$(user_alias_lookup "$input" 2>/dev/null)" && [ -n "$target" ]; then
    resolve_model "$target" $(( depth + 1 ))
    RESOLVED_VIA="alias:$input"
    return 0
  fi

  # 3. Built-in intent alias resolved against the live catalogue.
  local spec
  if spec="$(builtin_alias_spec "$input" 2>/dev/null)" && [ -n "$spec" ]; then
    local family="${spec%%|*}" effort="${spec#*|}" id
    if id="$(_resolve_family "$family" "$effort" 2>/dev/null)" && [ -n "$id" ]; then
      local look
      if look="$(catalogue_lookup "$id" 2>/dev/null)" && [ -n "$look" ]; then
        RESOLVED_ID="${look%%$'\t'*}"
        RESOLVED_LABEL="${look#*$'\t'}"
      else
        RESOLVED_ID="$id"; RESOLVED_LABEL="$id"
      fi
      RESOLVED_VIA="builtin:$input"
      return 0
    fi
    if [ -z "$(catalogue)" ]; then
      echo "error: cannot resolve alias '$input' — no model catalogue available." >&2
      echo "       \`agy models\` returned nothing (offline, or an agy build without" >&2
      echo "       the \`models\` subcommand). Pass a full model id or name instead." >&2
      exit 64
    fi
    echo "error: alias '$input' matches no model in the current catalogue." >&2
    print_model_table 2
    exit 64
  fi

  # 4. Unknown: hand it to agy verbatim. agy also knows about custom models
  #    configured in its own settings, which this wrapper cannot enumerate.
  RESOLVED_ID="$input"
  RESOLVED_LABEL="$input"
  RESOLVED_VIA="passthrough"
  if [ -n "$(catalogue)" ]; then
    echo "[wrapper] note: '$input' is not a known alias or catalogue entry; passing it to agy as-is." >&2
  fi
  return 0
}

validate_effort() {
  local e; e="$(_lower "${1:-}")"
  case "$e" in
    low|medium|high) printf '%s' "$e" ;;
    "")
      echo "error: --effort requires a value (low, medium or high)" >&2
      exit 64 ;;
    *)
      echo "error: invalid --effort '$1' (expected low, medium or high)" >&2
      exit 64 ;;
  esac
}

# --------------------------------------------------------------- output ----
# fd arg lets cmd_help reuse the same table on stdout.
print_model_table() {
  local fd="${1:-2}"
  {
    echo "Available models (live from \`agy models\`):"
    local cat_out; cat_out="$(catalogue)"
    if [ -n "$cat_out" ]; then
      printf '%s\n' "$cat_out" | awk -F'\t' '{ printf "  %-28s %s\n", $1, $2 }'
    else
      echo "  (catalogue unavailable — agy not installed, offline, or too old)"
    fi
    echo
    echo "Built-in aliases (case-insensitive, resolved against the list above):"
    builtin_alias_names | awk -F'\t' '{ printf "  %-28s %s\n", $1, $2 }'
    local user_rows; user_rows="$(user_alias_names)"
    if [ -n "$user_rows" ]; then
      echo
      echo "Your aliases ($AGY_ALIASES_FILE):"
      printf '%s\n' "$user_rows" | awk -F'\t' '{ printf "  %-28s -> %s\n", $1, $2 }'
    fi
    echo
    echo "Any model id or display name is also accepted verbatim, including"
    echo "custom models defined in your agy settings."
  } >&"$fd"
}

_current_default_model() {
  [ -f "$AGY_SETTINGS_FILE" ] || return 1
  grep -oE '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$AGY_SETTINGS_FILE" 2>/dev/null \
    | sed -E 's/.*"model"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
    | head -n1
}

# ----------------------------------------------------------- subcommands ---
cmd_check() {
  if ! path="$(find_agy | head -n1)"; then
    cat <<JSON
{ "installed": false, "path": "", "version": "", "auth": "unknown",
  "nativeModelFlag": false, "modelsSubcommand": false,
  "error": "agy binary not found; install with: curl -fsSL https://antigravity.google/cli/install.sh | bash" }
JSON
    return 0
  fi
  version="$("$path" --version 2>/dev/null | head -n1 || echo unknown)"
  auth="$(auth_status)"
  local native="false" models_cmd="false"
  agy_supports_model_flag && native="true"
  agy_supports_models_cmd && models_cmd="true"
  printf '{ "installed": true, "path": "%s", "version": "%s", "auth": "%s", "nativeModelFlag": %s, "modelsSubcommand": %s, "error": "" }\n' \
    "$(j_esc "$path")" "$(j_esc "$version")" "$(j_esc "$auth")" "$native" "$models_cmd"
}

cmd_models() {
  local force=0 ids_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --refresh) force=1; shift ;;
      --ids)     ids_only=1; shift ;;
      --)        shift; break ;;
      *)         echo "error: unknown flag for models: '$1'" >&2; exit 64 ;;
    esac
  done
  local out; out="$(catalogue "$force")"
  if [ -z "$out" ]; then
    echo "error: no model catalogue available." >&2
    echo "       agy may not be installed, may be offline, or may predate the" >&2
    echo "       \`models\` subcommand. Run /agy:setup to check." >&2
    exit 1
  fi
  if [ "$ids_only" = "1" ]; then
    printf '%s\n' "$out" | awk -F'\t' '{print $1}'
  else
    print_model_table 1
  fi
}

require_ready() {
  if ! path="$(find_agy)"; then
    echo "error: agy is not installed." >&2
    echo "       install: curl -fsSL https://antigravity.google/cli/install.sh | bash" >&2
    exit 127
  fi
  if [ "$(auth_status)" = "missing" ]; then
    echo "error: agy is not authenticated." >&2
    echo "       run \`agy\` once interactively, or export ANTIGRAVITY_API_KEY" >&2
    exit 1
  fi
  echo "$path"
}

# ------------------------------------------- legacy settings-patch path ----
# Compatibility shim, used only when the installed agy has no --model flag.
validate_settings_file() {
  if [ ! -f "$AGY_SETTINGS_FILE" ]; then
    echo "error: $AGY_SETTINGS_FILE not found." >&2
    echo "       run \`agy\` once interactively to create it." >&2
    exit 1
  fi
  if [ ! -s "$AGY_SETTINGS_FILE" ]; then
    echo "error: $AGY_SETTINGS_FILE is empty." >&2
    exit 1
  fi
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$AGY_SETTINGS_FILE" 2>/dev/null; then
      echo "error: $AGY_SETTINGS_FILE is not valid JSON." >&2
      exit 1
    fi
  fi
  if ! grep -q '"model"' "$AGY_SETTINGS_FILE"; then
    echo "error: $AGY_SETTINGS_FILE has no \"model\" field." >&2
    echo "       open \`agy\` and pick a model with /model first." >&2
    exit 1
  fi
}

restore_orphaned_backup() {
  [ -f "$AGY_SETTINGS_SENTINEL" ] || {
    if [ -f "$AGY_SETTINGS_BACKUP" ]; then
      echo "[wrapper] note: stale backup with no sentinel; removing $AGY_SETTINGS_BACKUP" >&2
      rm -f "$AGY_SETTINGS_BACKUP"
    fi
    return 0
  }
  local pid; pid="$(head -n1 "$AGY_SETTINGS_SENTINEL" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  if [ -f "$AGY_SETTINGS_BACKUP" ]; then
    mv "$AGY_SETTINGS_BACKUP" "$AGY_SETTINGS_FILE"
    echo "[wrapper] recovered orphaned settings backup from PID ${pid:-unknown}" >&2
  fi
  rm -f "$AGY_SETTINGS_SENTINEL"
}

# mkdir-based lock; macOS has no flock(1). Dead-holder detection avoids
# SIGKILL deadlocks.
with_settings_lock() {
  local fn="$1"; shift
  local attempt=0
  local max_wait="${AGY_LOCK_WAIT_SECONDS:-600}"
  while ! mkdir "$AGY_SETTINGS_LOCKDIR" 2>/dev/null; do
    local holder_pid_file="${AGY_SETTINGS_LOCKDIR}/pid"
    if [ -f "$holder_pid_file" ]; then
      local holder_pid; holder_pid="$(cat "$holder_pid_file" 2>/dev/null || true)"
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        rm -rf "$AGY_SETTINGS_LOCKDIR"
        continue
      fi
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$max_wait" ]; then
      echo "error: could not acquire settings lock after ${max_wait}s" >&2
      exit 1
    fi
    sleep 1
  done
  echo "$$" > "${AGY_SETTINGS_LOCKDIR}/pid"
  local rc=0
  "$fn" "$@" || rc=$?
  rm -rf "$AGY_SETTINGS_LOCKDIR"
  return "$rc"
}

# python3 preferred for correctness; sed fallback only matches single-line
# "model": "..." (the format agy itself writes).
_patch_model_field() {
  local canonical="$1"
  local tmp; tmp="$(mktemp "${AGY_SETTINGS_FILE}.tmp.XXXXXX")"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$AGY_SETTINGS_FILE" "$canonical" "$tmp" <<'PY'
import json, sys
src, model, dst = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    data = json.load(f)
data["model"] = model
with open(dst, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  else
    local esc; esc="$(printf '%s' "$canonical" | sed -e 's/[\/&]/\&/g')"
    sed -E "s/^([[:space:]]*\"model\"[[:space:]]*:[[:space:]]*\")[^\"]*(\".*)$/\1${esc}\2/" \
        "$AGY_SETTINGS_FILE" > "$tmp"
    echo "[wrapper] note: python3 missing, used sed fallback to patch settings.json" >&2
  fi
  mv "$tmp" "$AGY_SETTINGS_FILE"
}

_restore_settings() {
  if [ -f "$AGY_SETTINGS_BACKUP" ]; then
    mv "$AGY_SETTINGS_BACKUP" "$AGY_SETTINGS_FILE"
  fi
  rm -f "$AGY_SETTINGS_SENTINEL"
}

_do_patched_run() {
  local canonical="$1"; shift
  cp -p "$AGY_SETTINGS_FILE" "$AGY_SETTINGS_BACKUP"
  printf '%s\n%s\n' "$$" "$canonical" > "$AGY_SETTINGS_SENTINEL"
  trap '_restore_settings' EXIT INT TERM HUP
  _patch_model_field "$canonical"
  local rc=0
  "$@" || rc=$?
  _restore_settings
  trap - EXIT INT TERM HUP
  return "$rc"
}

# `--` separator guards against canonical names that start with `-`.
with_model_override() {
  local canonical="$1"; shift
  if [ "${1:-}" != "--" ]; then
    echo "internal: with_model_override expects '--' after canonical name" >&2
    exit 70
  fi
  shift
  validate_settings_file
  with_settings_lock _do_patched_run "$canonical" "$@"
}

# ------------------------------------------------------------ invocation ---
# Single place that decides *how* a model override reaches agy.
run_agy_prompt() {
  local model_id="$1" model_label="$2" effort="$3" agy_path="$4" prompt="$5"
  shift 5

  if [ -z "$model_id" ] && [ -z "$effort" ]; then
    "$agy_path" -p "$prompt" "$@"
    return $?
  fi

  if agy_supports_model_flag; then
    local argv=()
    [ -n "$model_id" ] && argv+=(--model "$model_id")
    if [ -n "$effort" ]; then
      if agy_supports_effort_flag; then
        argv+=(--effort "$effort")
      else
        echo "[wrapper] note: this agy build has no --effort flag; ignoring --effort $effort" >&2
      fi
    fi
    "$agy_path" ${argv[@]+"${argv[@]}"} -p "$prompt" "$@"
    return $?
  fi

  # Legacy build: no --model flag. Fall back to patching settings.json, which
  # stores the display label rather than the slug.
  if [ -n "$effort" ]; then
    echo "[wrapper] note: this agy build has no --effort flag; ignoring --effort $effort" >&2
  fi
  echo "[wrapper] note: agy has no --model flag; falling back to temporary settings.json patching." >&2
  with_model_override "${model_label:-$model_id}" -- "$agy_path" -p "$prompt" "$@"
}

# Shared --model/--effort parsing. Sets PARSED_MODEL_ID / PARSED_MODEL_LABEL /
# PARSED_EFFORT and leaves the remaining args in PARSED_REST.
PARSED_MODEL_ID=""
PARSED_MODEL_LABEL=""
PARSED_EFFORT=""
PARSED_REST=()
parse_model_flags() {
  local model_alias="" model_flag_seen=0
  PARSED_MODEL_ID=""; PARSED_MODEL_LABEL=""; PARSED_EFFORT=""; PARSED_REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --model)
        model_flag_seen=1
        # `shift 2` on a one-arg list would `set -e`-exit silently; handle the
        # empty case so resolve_model prints the real error.
        if [ $# -ge 2 ]; then model_alias="$2"; shift 2; else shift; fi ;;
      --model=*)
        model_flag_seen=1; model_alias="${1#--model=}"; shift ;;
      --effort)
        if [ $# -ge 2 ]; then
          PARSED_EFFORT="$(validate_effort "$2")"; shift 2
        else
          PARSED_EFFORT="$(validate_effort "")"
        fi ;;
      --effort=*)
        PARSED_EFFORT="$(validate_effort "${1#--effort=}")"; shift ;;
      --) shift; break ;;
      *)  break ;;
    esac
  done
  # Resolve before the caller's prompt check so an empty --model reports the
  # model error rather than a missing-prompt error.
  if [ "$model_flag_seen" -eq 1 ]; then
    resolve_model "$model_alias"
    PARSED_MODEL_ID="$RESOLVED_ID"
    PARSED_MODEL_LABEL="$RESOLVED_LABEL"
    # An alias deliberately does not name a version, so say which concrete
    # model it landed on — otherwise the indirection is unauditable.
    case "$RESOLVED_VIA" in
      builtin:*|alias:*)
        [ "${AGY_QUIET:-0}" = "1" ] ||           echo "[wrapper] model: $model_alias -> $RESOLVED_ID (${RESOLVED_LABEL})" >&2 ;;
    esac
  fi
  PARSED_REST=("$@")
}

cmd_ask() {
  parse_model_flags "$@"
  set -- ${PARSED_REST[@]+"${PARSED_REST[@]}"}

  local prompt="${1:-}"
  shift || true
  if [ -z "$prompt" ]; then
    echo "error: ask requires a prompt argument" >&2
    exit 64
  fi

  local path
  path="$(require_ready)"
  run_agy_prompt "$PARSED_MODEL_ID" "$PARSED_MODEL_LABEL" "$PARSED_EFFORT" "$path" "$prompt" "$@"
}

cmd_review() {
  parse_model_flags "$@"
  set -- ${PARSED_REST[@]+"${PARSED_REST[@]}"}

  local focus="${1:-Please review the following diff for correctness, edge cases, security issues, and style.}"
  local path
  path="$(require_ready)"
  local repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  local diff
  diff="$(git -C "$repo_dir" diff HEAD 2>/dev/null || true)"
  if [ -z "$diff" ]; then
    diff="$(git -C "$repo_dir" diff 2>/dev/null || true)"
  fi
  if [ -z "$diff" ]; then
    echo "error: no git diff found in $repo_dir. Stage or make changes first." >&2
    exit 1
  fi
  local full
  full=$(printf '%s\n\nDiff:\n```diff\n%s\n```\n' "$focus" "$diff")
  run_agy_prompt "$PARSED_MODEL_ID" "$PARSED_MODEL_LABEL" "$PARSED_EFFORT" "$path" "$full"
}

cmd_image() {
  local description="" name="" output=""
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)
        if [ $# -ge 2 ]; then
          name="$2"; shift 2
        else
          echo "error: --name requires a value (e.g. --name coffee_cup)" >&2
          exit 64
        fi ;;
      --name=*)
        name="${1#--name=}"
        if [ -z "$name" ]; then
          echo "error: --name= requires a non-empty value" >&2
          exit 64
        fi
        shift ;;
      --output)
        if [ $# -ge 2 ]; then
          output="$2"; shift 2
        else
          echo "error: --output requires a path (e.g. --output /tmp/out.png)" >&2
          exit 64
        fi ;;
      --output=*)
        output="${1#--output=}"
        if [ -z "$output" ]; then
          echo "error: --output= requires a non-empty path" >&2
          exit 64
        fi
        shift ;;
      --)        shift; positional+=("$@"); break ;;
      *)         positional+=("$1"); shift ;;
    esac
  done
  description="${positional[*]+${positional[*]}}"
  if [ -z "$description" ]; then
    echo "error: image requires a description" >&2
    exit 64
  fi
  local agy_path
  agy_path="$(require_ready)"

  local name_clause=""
  if [ -n "$name" ]; then
    name_clause=" Save the image with name \"${name}\"."
  fi
  local prompt
  prompt="Use your built-in generate_image tool to create the following image. Description: ${description}.${name_clause}

After the tool returns, you MUST end your reply with a single line in this exact format (no quotes, no markdown, nothing after it):
IMAGE_PATH: <absolute filesystem path to the saved image>

The IMAGE_PATH line is required — the calling wrapper parses it to locate the file."

  local response rc
  response="$("$agy_path" -p "$prompt" 2>&1)" || rc=$?
  rc="${rc:-0}"
  printf '%s\n' "$response"

  local src
  src="$(printf '%s' "$response" \
    | sed -n 's/^[[:space:]]*IMAGE_PATH:[[:space:]]*//p' \
    | tail -n1 || true)"

  # The path comes from model output, so only ever act on an image file —
  # never copy an arbitrary path the model happened to print.
  if [ -n "$src" ] && ! printf '%s' "$src" | grep -qiE '\.(png|jpg|jpeg|webp)$'; then
    echo "[wrapper] warning: ignoring IMAGE_PATH '$src' — not an image file." >&2
    src=""
  fi

  # Fallback when the model skips the marker line. The `|| true` guards matter:
  # a no-match grep would otherwise fail the assignment under `set -o pipefail`
  # and abort before the warning below could print.
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    src="$(printf '%s' "$response" \
      | grep -oE '/[^[:space:]]+\.(png|jpg|jpeg|webp)' \
      | head -n1 || true)"
  fi

  if [ -n "$src" ] && [ -f "$src" ]; then
    echo
    echo "[wrapper] generated: $src"
    if [ -n "$output" ]; then
      cp "$src" "$output"
      echo "[wrapper] copied to: $output"
    fi
  else
    echo
    echo "[wrapper] warning: agy did not include an IMAGE_PATH line and no image path was found in its reply." >&2
    echo "[wrapper]          if --output was requested, the copy was skipped." >&2
  fi
  return "$rc"
}

cmd_help() {
  cat <<'HELP'
/agy:* commands (Claude Code plugin for the Antigravity CLI)

Slash commands
  /agy:setup                            Verify agy install + auth. Offers install if missing.
  /agy:models [--refresh]               List the models agy currently offers.
  /agy:ask [--model M] [--effort E] <prompt>
                                        One-shot prompt; returns agy's response verbatim.
  /agy:delegate [--background] [--model M] [--effort E] <task>
                                        Hand a task to the agy:runner subagent.
  /agy:research [--background] [--model M] [--effort E] <topic>
                                        Deep-research investigation via agy:runner.
  /agy:review [--model M] [--effort E] [focus]
                                        Send current `git diff` to agy for review.
  /agy:image [--name S] [--output P] <description>
                                        Generate an image via agy's built-in tool.
  /agy:help                             This help.

Model selection (--model / --effort)
HELP
  print_model_table 1
  cat <<HELP

Defining your own aliases
  Create ${AGY_ALIASES_FILE}
  with one alias per line:

      # name = target (a model id, a display name, or another alias)
      cheap   = flash-low
      review  = deep
      pinned  = <an exact id from /agy:models>

  Aliases are read from your user config only — never from the repository you
  have checked out — so a project cannot silently redirect your prompts.

How --model works
  \`agy models\` is the source of truth. The wrapper caches that list for
  ${AGY_MODELS_CACHE_TTL}s in
  ${AGY_MODELS_CACHE}
  (refresh with \`/agy:models --refresh\`), resolves aliases against it, and
  passes the resulting model id to \`agy --model\`. Built-in aliases name a
  *family and effort*, not a version, so when Google ships a newer Flash or
  Pro, \`flash\` and \`pro\` follow it with no plugin update.

  Anything the wrapper does not recognise is forwarded to agy untouched, so
  custom models defined in your agy settings work too; agy validates it and
  prints the valid list if it is wrong.

  On agy builds too old to have \`--model\`, the wrapper falls back to
  temporarily patching the "model" field in
  ${AGY_SETTINGS_FILE}
  under a lock, restoring it on exit (including SIGINT / SIGTERM).

Underlying CLI
  Run \`agy --help\` for agy's own flags: --add-dir, -c/--continue,
  --conversation, --dangerously-skip-permissions, -i/--prompt-interactive,
  --log-file, -p/--print, --print-timeout, --sandbox.

  Subcommands: agents, changelog, help, install, mcp, models, plugin/plugins,
  remote-control, update.
HELP
}

main() {
  restore_orphaned_backup 2>/dev/null || true

  case "${1:-}" in
    check)              cmd_check ;;
    models)  shift;     cmd_models "$@" ;;
    ask)     shift;     cmd_ask "$@" ;;
    review)  shift;     cmd_review "$@" ;;
    image)   shift;     cmd_image "$@" ;;
    help|-h|--help|"")  cmd_help ;;
    *)                  echo "error: unknown subcommand '$1'" >&2; cmd_help >&2; exit 64 ;;
  esac
}

# Skip dispatch when sourced (lets unit tests call functions directly).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
