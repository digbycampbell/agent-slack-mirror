#!/usr/bin/env bash
# Run every tests/*.test.sh. Exits nonzero if any file fails.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
shopt -s nullglob
for t in "$ROOT"/tests/*.test.sh; do
  printf '== %s ==\n' "${t#"$ROOT"/}"
  if ! bash "$t"; then
    fail=1
  fi
done
exit "$fail"
