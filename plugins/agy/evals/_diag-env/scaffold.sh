#!/usr/bin/env bash
# diag-env: plants markers next to the working directory, so the probe can
# show which of them reach the agent's HOME.
set -euo pipefail
cd "${1:-$PWD}"
echo "scaffold PWD=$PWD" > scaffold-pwd.txt
mkdir -p ../.gemini/antigravity-cli ../.config/antigravity ../.agy-eval
touch ../.gemini/antigravity-cli/marker ../.config/antigravity/marker ../.agy-eval/marker ../plain-marker
{
  echo "scaffold AGY_EVAL_MODE=${AGY_EVAL_MODE:-<unset>}"
  echo "scaffold agy: $(command -v agy || echo none)"
} >> scaffold-pwd.txt
# Lets the probe call the wrapper without a machine-specific path.
here="$(cd "$(dirname "$0")" && pwd)"
printf '%s\n' "$(cd "$here/../../scripts" && pwd)/agy-run.sh" > wrapper-path.txt
