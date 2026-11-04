#!/usr/bin/env bash
# Behavior tests for worktree-setup.template.sh — the scaffold copied into a
# repo's .orca/. Asserts the non-fatal contract (always exit 0) and that the
# migrated template carries no gortex/ORCA_GORTEX handling (the dispatcher owns
# all gortex logic now and never starts the daemon).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/../reference/worktree-setup.template.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

# Valid bash, never uses `set -e`, ends at exit 0.
bash -n "$TEMPLATE" 2>/dev/null && pass "valid bash" || die "template has a syntax error"
grep -q 'set -e' "$TEMPLATE" && die "template must not use set -e" || pass "no set -e"
grep -q 'exit 0' "$TEMPLATE" && pass "has exit 0" || die "template missing exit 0"
grep -q 'repo-setup:managed:repo-steps' "$TEMPLATE" && pass "repo-steps marker" || die "no repo-steps marker"

# The gortex-readiness block was retired — the dispatcher owns all gortex handling
# now and never starts the daemon. The template must carry no gortex/ORCA_GORTEX logic.
grep -q 'orca-setup:managed:gortex-readiness' "$TEMPLATE" && die "gortex-readiness block must be gone" || pass "no gortex-readiness block"
grep -q 'ORCA_GORTEX' "$TEMPLATE" && die "template must not reference ORCA_GORTEX" || pass "no ORCA_GORTEX"

# Default run: clean, exit 0, no output.
out="$(cd "$tmp" && bash "$TEMPLATE" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "default exit 0" || die "default rc=$rc"
[ -z "$out" ] && pass "default produces no output" || die "default emitted output: $out"

grep -q 'orca-setup' "$TEMPLATE" && die "no old skill name" || pass "no old skill name"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
