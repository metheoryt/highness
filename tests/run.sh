#!/usr/bin/env bash
# Runs every plugins/*/tests/*_test.sh as an isolated subprocess. Run before every commit to main.
#
# Usage: bash tests/run.sh [--bash PATH]...
# Each --bash runs the whole suite again with that bash first on PATH, so the tests' own
# `bash x.sh` and every `#!/usr/bin/env bash` resolve to it too; none runs it once under the first
# bash on PATH. bash 3.2 is the floor (macOS): tests/build-bash32.sh builds one on Linux.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -gt 0 ]; then
  rc=0; done_with=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --bash) [ $# -ge 2 ] || { echo 'usage: tests/run.sh [--bash PATH]...' >&2; exit 2; } ;;
      *) echo 'usage: tests/run.sh [--bash PATH]...' >&2; exit 2 ;;
    esac
    b=$2; shift 2
    [ -x "$b" ] || { echo "tests/run.sh: $b is not an executable bash" >&2; exit 2; }
    d=$(mktemp -d "${TMPDIR:-/tmp}/hi-run.XXXXXX") || exit 1
    ln -s "$(cd "$(dirname "$b")" && pwd -P)/$(basename "$b")" "$d/bash"
    PATH="$d:$PATH" "$d/bash" "$ROOT/tests/run.sh" || { rc=1; done_with="$done_with $b"; }
    rm -rf "$d"
  done
  [ "$rc" = 0 ] || printf '\nfailed under:%s\n' "$done_with"
  exit "$rc"
fi

printf 'bash %s (%s)\n' "$BASH_VERSION" "$(command -v bash)"
fail=0; n=0; failed=''
for t in "$ROOT"/tests/*_test.sh "$ROOT"/plugins/*/tests/*_test.sh; do
  [ -e "$t" ] || continue
  n=$((n + 1))
  printf '== %s\n' "${t#"$ROOT"/}"
  if bash "$t"; then :; else fail=$((fail + 1)); failed="$failed ${t#"$ROOT"/}"; fi
done
[ "$n" -gt 0 ] || { echo 'tests/run.sh: no *_test.sh found'; exit 1; }
# The failed files go on the closing line itself: output piped through tail/grep loses the '== ' headers.
if [ "$fail" -ne 0 ]; then printf '\n%d test file(s) failed under bash %s:%s\n' "$fail" "$BASH_VERSION" "$failed"; exit 1; fi
printf '\nAll %d test files passed under bash %s.\n' "$n" "$BASH_VERSION"
