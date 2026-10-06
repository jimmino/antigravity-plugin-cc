#!/usr/bin/env bash
# positive-diff-review: stages a git repo with an uncommitted change to src/photo.service.ts.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_photo_repo
