#!/usr/bin/env bash
# Runs the offloading eval suite against a fake agy.
#
#   bash plugins/agy/evals/run.sh [extra claude plugin eval args]
#
# Every case runs against tests/fixtures/fake-agy, which returns the canned
# answer the case sets in execution.env. No case spends Antigravity quota.
#
# There is no live mode. `claude plugin eval` runs the agent in a sandbox
# that gives it its own HOME (so ~/.gemini and agy's sign-in are hidden) and
# denies network access to googleapis.com, so a real agy cannot answer from
# inside it. Checked with the diag-env case on 2026-10-05.
#
# The agent turns run on your Claude credential. Narrow with --case <glob>
# or --tag <tag>; --runs 1 --ablation none for a smoke run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
plugin="$(cd "$here/.." && pwd)"
repo="$(cd "$plugin/../.." && pwd)"

if [ "${1:-}" = "--live" ]; then
  echo "run.sh: there is no live mode; see the comment at the top of this script" >&2
  exit 2
fi
[ "${1:-}" = "--mock" ] && shift

tag_given=0
for a in "$@"; do
  case "$a" in --tag|--tag=*|--case|--case=*) tag_given=1 ;; esac
done

# Where the fake goes matters (checked with the diag-env case):
# - not under /tmp: the sandbox gives the agent its own /tmp;
# - not in the plugin tree under /mnt/c: the agent can read it there but
#   not execute it, so `command -v agy` falls through to a real agy;
# - under the host home it runs, as ~/.local/bin/agy does.
# PATH is passed to the agent unchanged, so this directory first makes the
# fake win over a real agy in ~/.local/bin.
mock="${XDG_CACHE_HOME:-$HOME/.cache}/agy-plugin-eval"
rm -rf "$mock"
mkdir -p "$mock/bin"
trap 'rm -rf "$mock"' EXIT
cp "$repo/tests/fixtures/fake-agy" "$mock/bin/fake-agy"
# Next to the shim, not beside bin/: the sandbox exposes the PATH directory
# itself, and a sibling of it is not visible to the agent.
cp "$repo/tests/fixtures/catalog-current.tsv" "$mock/bin/catalog.tsv"
# The sandbox drops every variable this script exports except PATH, and
# case.yaml may only set EVAL_* variables. So the shim fixes the fake's own
# settings and renames the case's EVAL_FAKE_AGY_* knobs to FAKE_AGY_*.
cat > "$mock/bin/agy" <<'SHIM'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"
export FAKE_AGY_MODE=new FAKE_AGY_CATALOG="$here/catalog.tsv"
for k in $(compgen -e); do
  case "$k" in EVAL_FAKE_AGY_*) export "${k#EVAL_}=${!k}" ;; esac
done
exec "$here/fake-agy" "$@"
SHIM
chmod +x "$mock/bin/agy" "$mock/bin/fake-agy"

export PATH="$mock/bin:$PATH"

args=("$plugin" --scaffold --allow-tools Bash)
[ "$tag_given" = 1 ] || args+=(--tag mock)

rc=0
claude plugin eval "${args[@]}" "$@" || rc=$?
exit "$rc"
