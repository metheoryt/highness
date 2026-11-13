#!/usr/bin/env bash
# Every plugin's lib/config.sh is a byte-identical copy of shared/config.sh, and the plugins that
# carry lib/session-state.sh (hi reads it, hi-crew writes it) carry shared/session-state.sh, and
# hi-threads (writes the journal) and hi-crew (shows it) carry shared/threads-read.sh.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
same() { # <shared file> <copy>
  if cmp -s "$1" "$2"; then echo "  ok   ${2#"$ROOT"/}"; else echo "  FAIL ${2#"$ROOT"/} differs from ${1#"$ROOT"/} (copy it)"; rc=1; fi
}
for d in "$ROOT"/plugins/*/; do same "$ROOT/shared/config.sh" "$d/lib/config.sh"; done
for p in hi hi-crew; do same "$ROOT/shared/session-state.sh" "$ROOT/plugins/$p/lib/session-state.sh"; done
for p in hi-threads hi-crew; do same "$ROOT/shared/threads-read.sh" "$ROOT/plugins/$p/lib/threads-read.sh"; done
exit $rc
