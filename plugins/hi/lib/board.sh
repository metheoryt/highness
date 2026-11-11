#!/usr/bin/env bash
# board.sh — Orca's board columns (workspace statuses) by name, for wt.sh board.
#
# A workspace stores only a status id, and the id behind a label differs per host (Orca keeps
# the set per host; `status-6` was "Blocked" on one box and "QA" on another). Orca also takes
# ANY id on `worktree set --workspace-status` and stores it, so a wrong id silently moves a
# workspace off the board. Hence every id comes from the live set, by label, and a label the
# set does not have is an error, never a guess.
#
# The live set is ui.workspaceStatuses in Orca's profile-state.db. It is read from a copy of
# the database with its -wal beside it: opened in place across /mnt/c (a Windows Orca seen
# from WSL) SQLite answers "disk I/O error", and the newest columns live in the WAL until Orca
# checkpoints. The orca-data.json beside it is frozen since Orca moved to SQLite (2026-09-29)
# and holds stale ids, so it is never read.
#
#   board.sh set          id<TAB>label<TAB>column, one per Orca column; column is the name
#                         below whose label it carries, empty for any other column
#   board.sh id <column>  the id of one of the columns below; exit 1 when the set lacks it
#   board.sh missing [column ...]
#                         the label of each named column the set lacks, one per line (nothing
#                         when it has them all); exit 1 when the set cannot be read, so an
#                         unreadable set never reads as "every column missing". No column named:
#                         the ones hi itself moves workspaces to ($HI_COLUMNS: wt.sh create puts
#                         a new workspace in active, a review one in review_queue). The other
#                         columns are for a plugin built on wt.sh board, which checks its own.
#
# Columns (the label each one looks for):
#   mains=Mains  active=In progress  in_review=In review  qa=QA  done=Done
#   review_queue=Review queue  waiting_author=Waiting author  needs_me=Needs me
#
# HI_ORCA_BOARD=<file of id<TAB>label lines> replaces the database (tests); HI_ORCA_STATE_DB
# names the database. Exit: 0 ok, 1 not found / set unreadable, 2 usage.
set -uo pipefail

say() { printf 'board: %s\n' "$*" >&2; }

COLUMNS='mains active in_review qa done review_queue waiting_author needs_me'
HI_COLUMNS='active review_queue'

label_of_column() {
  case "$1" in
    mains)          echo 'Mains' ;;
    active)         echo 'In progress' ;;
    in_review)      echo 'In review' ;;
    qa)             echo 'QA' ;;
    done)           echo 'Done' ;;
    review_queue)   echo 'Review queue' ;;
    waiting_author) echo 'Waiting author' ;;
    needs_me)       echo 'Needs me' ;;
    *) return 1 ;;
  esac
}

# The one profile-state.db on this box. Two (a Windows Orca and a Linux one) is ambiguous:
# refuse rather than pick the wrong host's ids.
state_db() {
  if [ -n "${HI_ORCA_STATE_DB:-}" ]; then printf '%s\n' "$HI_ORCA_STATE_DB"; return 0; fi
  local d found=''
  for d in "$HOME/.config/orca/profiles/local-default" \
           "$HOME/Library/Application Support/orca/profiles/local-default" \
           "$HOME/AppData/Roaming/orca/profiles/local-default" \
           /mnt/c/Users/*/AppData/Roaming/orca/profiles/local-default; do
    [ -f "$d/profile-state.db" ] || continue
    [ -z "$found" ] || { say "two Orca profile databases ($found, $d/profile-state.db): set HI_ORCA_STATE_DB"; return 1; }
    found="$d/profile-state.db"
  done
  [ -n "$found" ] || { say 'no Orca profile-state.db on this box'; return 1; }
  printf '%s\n' "$found"
}

the_set() {
  if [ -n "${HI_ORCA_BOARD:-}" ]; then
    [ -f "$HI_ORCA_BOARD" ] || { say "HI_ORCA_BOARD: no such file: $HI_ORCA_BOARD"; return 1; }
    cat "$HI_ORCA_BOARD"; return 0
  fi
  local db tmp rc=0
  db=$(state_db) || return 1
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/hi-board.XXXXXX") || return 1
  cp "$db" "$tmp/s.db" 2>/dev/null || rc=1
  [ ! -f "$db-wal" ] || cp "$db-wal" "$tmp/s.db-wal" 2>/dev/null || rc=1
  if [ "$rc" = 0 ]; then
    python3 -I - "$tmp/s.db" <<'PY' || rc=1
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1])
row = con.execute("select payload from profile_state_documents where domain = 'ui'").fetchone()
for s in json.loads(row[0]).get("workspaceStatuses") or []:
    i, l = str(s.get("id") or ""), str(s.get("label") or "")
    if i and l and "\t" not in i + l and "\n" not in i + l:
        print(i + "\t" + l)
PY
  fi
  rm -rf "$tmp"
  [ "$rc" = 0 ] || say "cannot read the status set from $db"
  return "$rc"
}

# id<TAB>label<TAB>column
named_set() {
  local s c map=''
  s=$(the_set) || return 1
  for c in $COLUMNS; do map="$map$(label_of_column "$c")	$c
"; done
  # The map goes through the environment: BSD awk (macOS) rejects a newline in a -v value.
  printf '%s\n' "$s" | BOARD_MAP="$map" awk -F'\t' '
    BEGIN { n = split(ENVIRON["BOARD_MAP"], m, "\n"); for (i = 1; i <= n; i++) { split(m[i], kv, "\t"); if (kv[1] != "") c[kv[1]] = kv[2] } }
    NF >= 2 { print $1 "\t" $2 "\t" (($2 in c) ? c[$2] : "") }'
}

case "${1:-}" in
  set) named_set ;;
  id)
    want=$(label_of_column "${2:-}") || { say "unknown column [${2:-}]"; exit 2; }
    s=$(the_set) || exit 1
    id=$(printf '%s\n' "$s" | awk -F'\t' -v l="$want" '$2 == l { print $1; exit }')
    [ -n "$id" ] || { say "Orca has no \"$want\" column"; exit 1; }
    printf '%s\n' "$id" ;;
  missing)
    shift
    [ $# -gt 0 ] || set -- $HI_COLUMNS
    for c in "$@"; do label_of_column "$c" >/dev/null || { say "unknown column [$c]"; exit 2; }; done
    s=$(the_set) || exit 1
    for c in "$@"; do
      l=$(label_of_column "$c")
      printf '%s\n' "$s" | awk -F'\t' -v l="$l" '$2 == l { f = 1 } END { exit !f }' || printf '%s\n' "$l"
    done ;;
  *) echo 'usage: board.sh set | id <column> | missing [column ...]' >&2; exit 2 ;;
esac
