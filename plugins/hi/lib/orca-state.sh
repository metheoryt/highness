# lib/orca-state.sh — read Orca's profile-state.db (sourced by board.sh and account.sh).
#
# Orca keeps its UI state and settings as JSON documents in profile-state.db, one row per domain
# (`ui`, `settings`, …) of profile_state_documents. The database is read from a copy with its
# -wal beside it: opened in place across /mnt/c (a Windows Orca seen from WSL) SQLite answers
# "disk I/O error", and the newest values live in the WAL until Orca checkpoints. Nothing here
# ever writes it.
#
#   orca_state_db          the one profile-state.db on this box ($HI_ORCA_STATE_DB names it)
#   orca_state_doc <domain> that domain's JSON document on stdout; exit 1 when it cannot be read
#
# Errors go to stderr as "<ORCA_STATE_NAME>: …" (default orca-state).

_orca_state_say() { printf '%s: %s\n' "${ORCA_STATE_NAME:-orca-state}" "$*" >&2; }

# Two databases (a Windows Orca and a Linux one) are ambiguous: refuse rather than read the
# wrong host's state.
orca_state_db() {
  if [ -n "${HI_ORCA_STATE_DB:-}" ]; then printf '%s\n' "$HI_ORCA_STATE_DB"; return 0; fi
  local d found=''
  for d in "$HOME/.config/orca/profiles/local-default" \
           "$HOME/Library/Application Support/orca/profiles/local-default" \
           "$HOME/AppData/Roaming/orca/profiles/local-default" \
           /mnt/c/Users/*/AppData/Roaming/orca/profiles/local-default; do
    [ -f "$d/profile-state.db" ] || continue
    [ -z "$found" ] || { _orca_state_say "two Orca profile databases ($found, $d/profile-state.db): set HI_ORCA_STATE_DB"; return 1; }
    found="$d/profile-state.db"
  done
  [ -n "$found" ] || { _orca_state_say 'no Orca profile-state.db on this box'; return 1; }
  printf '%s\n' "$found"
}

orca_state_doc() {
  local db tmp rc=0
  command -v python3 >/dev/null 2>&1 || { _orca_state_say 'python3 is required to read Orca state'; return 1; }
  db=$(orca_state_db) || return 1
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hi-orca-state.XXXXXX") || return 1
  cp "$db" "$tmp/s.db" 2>/dev/null || rc=1
  [ ! -f "$db-wal" ] || cp "$db-wal" "$tmp/s.db-wal" 2>/dev/null || rc=1
  if [ "$rc" = 0 ]; then
    python3 -I - "$tmp/s.db" "$1" <<'PY' || rc=1
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute("select payload from profile_state_documents where domain = ?", (sys.argv[2],)).fetchone()
if row is None:
    sys.exit(1)
sys.stdout.write(row[0] + "\n")
PY
  fi
  rm -rf "$tmp"
  [ "$rc" = 0 ] || _orca_state_say "cannot read Orca's $1 state from $db"
  return "$rc"
}
