#!/usr/bin/env bash
# shape-inventory: stages 30 config files whose first line says what each is for.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_config_dir
