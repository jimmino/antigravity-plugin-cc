#!/usr/bin/env bash
# route-grep-liveness: stages seven agent definitions, three of which call scripts/ask-gemini.ps1.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_agents
