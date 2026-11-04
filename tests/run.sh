#!/usr/bin/env bash
# Runs every plugins/*/tests/*_test.sh as an isolated subprocess. Run before every commit to main.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0; n=0; failed=''
for t in "$ROOT"/tests/*_test.sh "$ROOT"/plugins/*/tests/*_test.sh; do
  [ -e "$t" ] || continue
  n=$((n + 1))
  printf '== %s\n' "${t#"$ROOT"/}"
  if bash "$t"; then :; else fail=$((fail + 1)); failed="$failed ${t#"$ROOT"/}"; fi
done
[ "$n" -gt 0 ] || { echo 'tests/run.sh: no *_test.sh found'; exit 1; }
# The failed files go on the closing line itself: output piped through tail/grep loses the '== ' headers.
if [ "$fail" -ne 0 ]; then printf '\n%d test file(s) failed:%s\n' "$fail" "$failed"; exit 1; fi
printf '\nAll %d test files passed.\n' "$n"
