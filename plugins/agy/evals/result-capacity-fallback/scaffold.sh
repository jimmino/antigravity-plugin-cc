#!/usr/bin/env bash
# result-capacity-fallback: stages the ~1.4 MB backend; the balanced model returns 503.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
require_fake_agy
make_backend full
