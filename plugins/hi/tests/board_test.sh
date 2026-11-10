#!/usr/bin/env bash
# Orca board columns: board.sh reads the live status set by label (a database copy with its
# WAL), wt.sh board moves a workspace only from the column it last set and keeps a hand move.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
BOARD="$HERE/../lib/board.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }
sets() { grep -c -- '--workspace-status' "$WT_TEST_LOG"; }

# --- board.sh: the set from a profile-state.db, the newest columns from its WAL ----------------
DB="$SANDBOX/orca/profile-state.db"; mkdir -p "$SANDBOX/orca"
python3 -I - "$DB" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(sys.argv[1]); con.execute("pragma journal_mode=wal")
con.execute("pragma wal_autocheckpoint=0")
con.execute("create table profile_state_documents (domain text, payload text)")
ui = {"workspaceStatuses": [{"id": "todo", "label": "Mains"}, {"id": "status-6", "label": "QA"}]}
con.execute("insert into profile_state_documents values ('ui', ?)", (json.dumps(ui),)); con.commit()
ui["workspaceStatuses"].append({"id": "status-7", "label": "Needs me"})
con.execute("update profile_state_documents set payload = ? where domain = 'ui'", (json.dumps(ui),)); con.commit()
import shutil, os
d = os.path.dirname(sys.argv[1]) + "/snap"; os.makedirs(d)
shutil.copy(sys.argv[1], d); shutil.copy(sys.argv[1] + "-wal", d)
PY
SNAP="$SANDBOX/orca/snap/profile-state.db"
out=$(HI_ORCA_BOARD= HI_ORCA_STATE_DB="$SNAP" bash "$BOARD" set)
assert_contains "set: a column from the WAL is read" "$out" "$(printf 'status-7\tNeeds me\tneeds_me')"
assert_contains "set: a known label names its column" "$out" "$(printf 'status-6\tQA\tqa')"
assert_eq "id: by label" status-7 "$(HI_ORCA_BOARD= HI_ORCA_STATE_DB="$SNAP" bash "$BOARD" id needs_me)"
HI_ORCA_BOARD= HI_ORCA_STATE_DB="$SNAP" bash "$BOARD" id done >/dev/null 2>&1
assert_status "id: a label the set lacks fails" 1 "$?"
HI_ORCA_BOARD= HI_ORCA_STATE_DB="$SANDBOX/none.db" bash "$BOARD" set >/dev/null 2>&1
assert_status "set: no database fails" 1 "$?"

# --- board.sh missing: the columns hi needs that the set lacks (#23) -------------------------
printf 'todo\tTodo\nin-progress\tIn progress\nin-review\tIn review\ncompleted\tDone\n' > "$SANDBOX/defaults.tsv"
out=$(HI_ORCA_BOARD="$SANDBOX/defaults.tsv" bash "$BOARD" missing); rc=$?
assert_status "missing: exit 0" 0 "$rc"
assert_eq "missing: Orca's four default columns lack exactly five" \
  "$(printf 'Mains\nQA\nReview queue\nWaiting author\nNeeds me')" "$out"
out=$(HI_ORCA_BOARD= HI_ORCA_STATE_DB="$SNAP" bash "$BOARD" missing)
assert_eq "missing: from the database" \
  "$(printf 'In progress\nIn review\nDone\nReview queue\nWaiting author')" "$out"
out=$(HI_ORCA_BOARD= HI_ORCA_STATE_DB="$SANDBOX/none.db" bash "$BOARD" missing 2>/dev/null); rc=$?
assert_status "missing: an unreadable set fails" 1 "$rc"
assert_eq "missing: an unreadable set lists nothing" "" "$out"

# --- wt.sh board ----------------------------------------------------------------------------
mk_repo; cd "$R"; orca_on
out=$(bash "$WT" create --kind ticket --key AB-1 --name 'AB-1 · one' --base main --branch task/AB-1-one 2>/dev/null)
P=$(col "$out" 1)
assert_eq "create: records the column it starts in" in-progress "$(bash "$WT" rec get --ticket AB-1 board)"

reset_log
out=$(bash "$WT" board "$P" qa 2>/dev/null); rc=$?
assert_status "move: exit 0" 0 "$rc"
assert_eq "move: row" "moved	$P	AB-1 · one	QA" "$out"
assert_contains "move: the id from the set, on the Orca id" "$(logged)" "--worktree id:R::"
assert_contains "move: the id" "$(logged)" "--workspace-status st-qa"
assert_eq "move: recorded" st-qa "$(bash "$WT" rec get --ticket AB-1 board)"

out=$(bash "$WT" board "$P" qa 2>/dev/null)
assert_eq "same column: same" same "$(col "$out" 1)"

# the user moves it by hand: kept, no set
printf 'completed' > "$FX/board-$(printf 'id:%s' "$(col "$(bash "$WT" find --path "$P")" 2)" | tr -c 'A-Za-z0-9' '_')"
reset_log
out=$(bash "$WT" board "$P" in_review 2>/dev/null)
assert_eq "hand move: kept, names where it sits" "kept	$P	AB-1 · one	Done" "$out"
assert_eq "hand move: no set" 0 "$(sets)"
# … until the user puts it where the agent would: adopted again
out=$(bash "$WT" board "$P" done 2>/dev/null)
assert_eq "hand move to the target: same" same "$(col "$out" 1)"
assert_eq "hand move to the target: recorded" completed "$(bash "$WT" rec get --ticket AB-1 board)"

# unknown column / unreadable set: skip, nothing written
reset_log
out=$(bash "$WT" board "$P" needs_me 2>/dev/null); rc=$?
assert_status "no such column: exit 1" 1 "$rc"
assert_contains "no such column: skip row" "$out" "skip	$P	AB-1 · one	Orca has no needs_me column"
out=$(HI_ORCA_BOARD="$SANDBOX/missing.tsv" bash "$WT" board "$P" qa 2>/dev/null); rc=$?
assert_status "unreadable set: exit 1" 1 "$rc"
assert_eq "unreadable set: skip" skip "$(col "$out" 1)"
assert_eq "skips: no set" 0 "$(sets)"

# a workspace with no record yet: adopted only from In progress
out=$(bash "$WT" create --kind ticket --key AB-2 --name 'AB-2 · two' --base main --branch task/AB-2-two 2>/dev/null)
P2=$(col "$out" 1); S2=$(col "$out" 2)
printf 'board: \n' >> "$(git rev-parse --git-common-dir)/hi/AB-2.md"
printf 'st-rev' > "$FX/board-$(printf 'id:%s' "$S2" | tr -c 'A-Za-z0-9' '_')"
out=$(bash "$WT" board "$P2" qa 2>/dev/null)
assert_eq "no record, not In progress: kept" kept "$(col "$out" 1)"

# board - : several moves from stdin, one row each; an unknown path is said, the rest still run
out=$(printf '%s\tdone\n%s\tqa\n%s\tqa\n' "$P" "$SANDBOX/nowhere" "$P2" | bash "$WT" board - 2>"$SANDBOX/err"); rc=$?
assert_status "batch: an unknown path fails the batch" 1 "$rc"
assert_eq "batch: first row" "same	$P	AB-1 · one	Done" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "batch: the row after the unknown path" kept "$(printf '%s\n' "$out" | sed -n 2p | cut -f1)"
assert_contains "batch: the unknown path is said" "$(cat "$SANDBOX/err")" "no workspace at $SANDBOX/nowhere"

# git backend: nothing to move
orca_off
out=$(bash "$WT" board "$P" qa 2>/dev/null)
assert_eq "git backend: skip" "skip	$P	AB-1 · one	not an Orca workspace" "$out"

assert_summary
