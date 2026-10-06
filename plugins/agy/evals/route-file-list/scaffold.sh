#!/usr/bin/env bash
# route-file-list: stages the ~1.4 MB backend.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_backend full
