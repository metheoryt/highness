#!/usr/bin/env bash
# Every plugin's lib/config.sh is a byte-identical copy of shared/config.sh.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
for d in "$ROOT"/plugins/*/; do
  f="$d/lib/config.sh"
  if cmp -s "$ROOT/shared/config.sh" "$f"; then echo "  ok   ${f#"$ROOT"/}"; else echo "  FAIL ${f#"$ROOT"/} differs from shared/config.sh (copy it)"; rc=1; fi
done
exit $rc
