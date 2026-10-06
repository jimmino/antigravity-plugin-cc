#!/usr/bin/env bash
# route-count-log: stages a 6 000-line log with 873 ERROR lines.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_log logs/app.log
