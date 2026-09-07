#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:---write}
if [[ "$mode" != --write && "$mode" != --check ]]; then
  echo 'Usage: bash scripts/format.sh [--write|--check]' >&2
  exit 2
fi
deps=${SV_DEPS_DIR:-$PWD/.build/deps}
janet=${JANET:-$deps/janet/build/janet}
formatter=$deps/spork/bin/janet-format
if [[ ! -x "$janet" || ! -f "$formatter" ]]; then
  echo 'Build first, or set JANET and SV_DEPS_DIR to the pinned build dependencies.' >&2
  exit 2
fi
export JANET_PATH="$deps/spork"
format_tmp=$(mktemp -d)
trap 'rm -f "$format_tmp/formatted"; rmdir "$format_tmp"' EXIT
status=0
while IFS= read -r -d '' source; do
  "$janet" "$formatter" --no-config --input "$source" --output "$format_tmp/formatted"
  if ! cmp -s "$source" "$format_tmp/formatted"; then
    if [[ "$mode" == --check ]]; then
      echo "Needs formatting: $source" >&2
      status=1
    else
      cp "$format_tmp/formatted" "$source"
      echo "Formatted $source"
    fi
  fi
done < <(git ls-files --cached --others --exclude-standard -z -- '*.janet')
if [[ "$status" != 0 ]]; then
  echo 'Run: bash scripts/format.sh --write' >&2
fi
exit "$status"
