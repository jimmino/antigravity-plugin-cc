#!/usr/bin/env bash
# route-small-tree-pref: stages the ~6 KB backend.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_backend small
