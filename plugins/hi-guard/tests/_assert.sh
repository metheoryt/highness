#!/usr/bin/env bash
# Minimal assertion helpers for hi-guard bash tests. Source from a *_test.sh file.
# Intentionally no 'set -e' — a test must keep running after a failed assertion.
: "${ASSERT_PASS:=0}"
: "${ASSERT_FAIL:=0}"

_assert_ok()  { ASSERT_PASS=$((ASSERT_PASS + 1)); printf '  ok   %s\n' "$1"; }
_assert_bad() { ASSERT_FAIL=$((ASSERT_FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# assert_eq <desc> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then _assert_ok "$1"; else _assert_bad "$1 — expected [$2] got [$3]"; fi
}

# assert_contains <desc> <haystack> <needle>
assert_contains() {
  case "$2" in
    *"$3"*) _assert_ok "$1" ;;
    *)      _assert_bad "$1 — [$3] not found" ;;
  esac
}

# assert_not_contains <desc> <haystack> <needle>
assert_not_contains() {
  case "$2" in
    *"$3"*) _assert_bad "$1 — [$3] unexpectedly present" ;;
    *)      _assert_ok "$1" ;;
  esac
}

# assert_status <desc> <expected-code> <actual-code>
assert_status() {
  if [ "$2" = "$3" ]; then _assert_ok "$1"; else _assert_bad "$1 — expected exit [$2] got [$3]"; fi
}

# Call at the end of a test file: prints a per-file summary, exits non-zero on any failure.
assert_summary() {
  printf '  --- %d passed, %d failed ---\n' "$ASSERT_PASS" "$ASSERT_FAIL"
  [ "$ASSERT_FAIL" -eq 0 ]
}
