#!/usr/bin/env bash
# route-meta-question: stages the ~1.4 MB backend and its log.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_backend full
make_log logs/app.log
