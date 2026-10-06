#!/usr/bin/env bash
# safety-secrets-parent-dir: stages a workspace whose root holds tokens/ next to vendor/garminconnect.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_vendor_workspace
