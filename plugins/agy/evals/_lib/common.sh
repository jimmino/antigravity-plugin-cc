# Shared by every case's scaffold.sh. Sourced, not executed.
#
# A scaffold runs once per run, before the agent starts, on the host side of
# the sandbox, in the run's working directory (<sandbox>/home/cwd). It
# stages the fixture the case's prompt talks about. The harness passes it
# PATH but not the other variables run.sh exports, so mock mode is detected
# by asking the agy on PATH what it is.

set -euo pipefail

EVAL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# fake_agy_on_path: true when the agy first on PATH is run.sh's fake.
# Captured, not piped into grep -q: under pipefail an early grep exit
# SIGPIPEs agy and fails the check at random.
fake_agy_on_path() {
  local help
  help="$(agy --help 2>/dev/null || true)"
  [[ "$help" == *fake-agy* ]]
}

# enter_workdir [DIR]: the harness runs the scaffold in the working directory;
# accept it as $1 as well, in case a harness version passes it that way.
# With the fake on PATH, also stage the agent's sandbox HOME.
enter_workdir() {
  cd "${1:-$PWD}"
  if fake_agy_on_path; then
    stage_agent_home
  fi
}

# stage_agent_home: the agent's HOME is the parent of the working directory.
# agy-run.sh treats agy as signed in when $HOME/.gemini/antigravity-cli
# exists; the fake needs nothing else. Files written here do reach the agent.
stage_agent_home() {
  local home
  home="$(dirname "$PWD")"
  if [ "$(basename "$PWD")" != "cwd" ]; then
    echo "scaffold: expected to run in <sandbox>/home/cwd, got $PWD" >&2
    exit 1
  fi
  mkdir -p "$home/.gemini/antigravity-cli"
  printf '{ "model": "Gemini 3.8 Flash (High)" }\n' > "$home/.gemini/antigravity-cli/settings.json"
}

# require_fake_agy: for cases whose graders depend on a canned agy answer.
# Refuses to stage the case unless run.sh put the fake first on PATH.
require_fake_agy() {
  if ! fake_agy_on_path; then
    echo "scaffold: this case needs the fake agy; run it through evals/run.sh" >&2
    exit 1
  fi
}

# require_fake_knob NAME: the fake agy must understand knob NAME. A knob it
# does not know is silently ignored, which would make the case test nothing.
require_fake_knob() {
  local fake
  fake="$(dirname "$(command -v agy)")/fake-agy"
  if ! grep -q "$1" "$fake" 2>/dev/null; then
    echo "scaffold: the fake agy does not support $1 (needs a newer tests/fixtures/fake-agy)" >&2
    exit 1
  fi
}

# expect_line FILE N TEXT: the canned agy answer cites FILE:N, so fail the
# scaffold loudly if fixture generation drifted.
expect_line() {
  if ! sed -n "${2}p" "$1" | grep -qF -- "$3"; then
    echo "scaffold: $1:$2 does not contain: $3" >&2
    exit 1
  fi
}
