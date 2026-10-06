#!/usr/bin/env bash
# result-verify-citations: stages the ~1.4 MB backend; one canned citation is wrong.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
require_fake_agy
make_backend full
