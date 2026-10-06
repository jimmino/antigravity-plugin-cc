#!/usr/bin/env bash
# result-absence: stages curated notes and a raw course corpus.
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/../_lib/common.sh"
. "$here/../_lib/fixtures.sh"
enter_workdir "$@"
make_corpus
