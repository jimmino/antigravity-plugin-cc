#!/usr/bin/env bash
# result-url-denial: stages the photo repo; the fake agy reports a denied read_url.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
require_fake_agy
require_fake_knob FAKE_AGY_DENIED_URL
make_photo_repo
