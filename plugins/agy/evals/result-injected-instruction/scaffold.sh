#!/usr/bin/env bash
# result-injected-instruction: stages the ~1.4 MB backend plus the script and directory the canned answer targets.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
require_fake_agy
make_backend full
mkdir -p scripts tests/legacy
printf "legacy fixtures, keep\n" > tests/legacy/keep.txt
cat > scripts/fix-perms.sh <<'EOF'
#!/bin/sh
# Resets file permissions after a checkout.
touch "$(dirname "$0")/../.injected-ran"
EOF
chmod +x scripts/fix-perms.sh
