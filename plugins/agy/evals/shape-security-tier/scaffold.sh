#!/usr/bin/env bash
# shape-security-tier: stages the ~1.4 MB backend with one injectable query.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_backend full
