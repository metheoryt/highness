#!/usr/bin/env bash
# lib/wt.sh create — Orca backend: argv, UNC→POSIX, display name, lineage, branch landing,
# review detach + Orca-branch cleanup, failures that must not duplicate or leak.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }

mk_repo; cd "$R"; orca_on
O="$FX_ORCA_ROOT"

out=$(bash "$WT" create --kind ticket --key AB-101 --name 'AB-101 · Retry lock ordering' \
        --base main --branch task/dev/AB-101-retry-lock 2>"$SANDBOX/err"); rc=$?
assert_status "orca ticket: exit 0" 0 "$rc"
L=$(logged)
# a bare trunk as --base goes to Orca as origin/<trunk> (highness#16: handed `main` with a new
# --branch, Orca put the tree on [main] and create failed)
assert_contains "orca: create argv, bare trunk sent as origin/main" "$L" "orca worktree create --repo id:R --name AB-101-retry-lock-ordering --base-branch origin/main --setup skip --comment hi:ticket AB-101 --json --branch task/dev/AB-101-retry-lock --parent-worktree id:R::"
assert_contains "orca: display name set on the Orca id" "$L" "orca worktree set --worktree id:R::\\\\wsl.localhost\\d"
assert_contains "orca: display name value" "$L" "--display-name AB-101 · Retry lock ordering"
assert_eq "orca: path is POSIX" "$O/AB-101-retry-lock-ordering" "$(col "$out" 1)"
assert_contains "orca: sel is the Orca id" "$(col "$out" 2)" 'R::\\wsl.localhost\d'
assert_eq "orca: backend" orca "$(col "$out" 10)"
assert_eq "orca: landed on the convention branch" task/dev/AB-101-retry-lock "$(col "$out" 3)"
assert_eq "orca: no auto branch is cut" "" "$(git branch --list 'dev/AB-101-retry-lock-ordering')"
assert_contains "orca: setup ran (setup skip + our run)" "$L" "setup $O/AB-101-retry-lock-ordering"
assert_contains "orca: announce" "$(cat "$SANDBOX/err")" "(orca)"
assert_not_contains "orca: never --no-parent" "$L" "--no-parent"
assert_eq "orca: made from the main checkout → its parent is the main checkout" "$(cd "$R" && pwd -P)" "$(col "$out" 8)"

# a base that is not the trunk is passed as given
git branch -q epic/AB-1-thing main; reset_log
bash "$WT" create --kind ticket --key AB-150 --name 'AB-150 · on epic' --base epic/AB-1-thing --branch task/dev/AB-150-epic >/dev/null 2>&1
assert_contains "orca: a non-trunk base is kept" "$(logged)" "--base-branch epic/AB-1-thing --setup"

# made from inside a workspace, no --parent: that workspace is the parent
reset_log
out=$(cd "$O/AB-101-retry-lock-ordering" && bash "$WT" create --kind work --key from-inside --name 'from inside' \
        --base main --branch work/from-inside 2>/dev/null); rc=$?
assert_status "orca from inside: exit 0" 0 "$rc"
assert_eq "orca from inside: parent is the caller's workspace" "$O/AB-101-retry-lock-ordering" "$(col "$out" 8)"
assert_contains "orca from inside: --parent-worktree" "$(logged)" "--parent-worktree id:R::"

# a parent Orca does not list: refused, never made parentless
reset_log
out=$(cd "$O/AB-101-retry-lock-ordering" && FX_ORCA_ONLY="$O/none" bash "$WT" create --kind work --key hidden-parent \
        --name 'hidden parent' --base main --branch work/hidden-parent 2>&1); rc=$?
assert_status "orca unlisted parent: exit 1" 1 "$rc"
assert_contains "orca unlisted parent: says why" "$out" "no parent"
assert_not_contains "orca unlisted parent: no create call" "$(logged)" "worktree create"

# child work workspace: lineage to the ticket's Orca id, never --no-parent
reset_log
out=$(bash "$WT" create --kind work --key child-check --name 'child check' --base main --branch work/child \
        --parent "$O/AB-101-retry-lock-ordering" 2>/dev/null)
L=$(logged)
assert_contains "orca parent: --parent-worktree with the parent's Orca id" "$L" "--parent-worktree id:R::\\\\wsl.localhost\\d"
assert_not_contains "orca parent: no --no-parent" "$L" "--no-parent"
assert_eq "orca work: named the given branch" work/child "$(col "$out" 3)"

# review: detached at the sha, Orca's branch deleted, no setup
SHA=$(git rev-parse HEAD); reset_log
out=$(bash "$WT" create --kind review --key 7 --name 'review #7 · AB-101 retry' --detach "$SHA" 2>/dev/null); rc=$?
assert_status "orca review: exit 0" 0 "$rc"
assert_contains "orca review: created at the sha" "$(logged)" "--base-branch $SHA"
assert_eq "orca review: detached" "" "$(col "$out" 3)"
assert_eq "orca review: Orca's branch deleted" "" "$(git branch --list 'dev/review-7')"
assert_not_contains "orca review: no setup run (the argv's --setup skip is not one)" "$(logged)" "setup /"

# failure with a JSON reason: exit 1, reason shown, no record
printf '%s\n' '{"ok":false,"error":{"code":"repo_not_found"}}' > "$FX/create.json"; echo 1 > "$FX/create.rc"
out=$(bash "$WT" create --kind work --key failed --name f --base main --branch work/f 2>&1); rc=$?
assert_status   "orca failure: exit 1" 1 "$rc"
assert_contains "orca failure: Orca's reason" "$out" "repo_not_found"
out=$(bash "$WT" rec get --work failed workspace); rc=$?
assert_status "orca failure: no record" 1 "$rc"

# runtime_unavailable and nothing exists: listed once, never retried
printf '%s\n' '{"ok":false,"error":{"code":"runtime_unavailable"}}' > "$FX/create.json"; reset_log
out=$(bash "$WT" create --kind work --key ru --name ru --base main --branch work/ru 2>&1); rc=$?
assert_status "runtime_unavailable: exit 1" 1 "$rc"
assert_eq "runtime_unavailable: exactly one create call" 1 "$(grep -c 'worktree create' "$WT_TEST_LOG")"
assert_contains "runtime_unavailable: listed after the failed create" "$(logged | sed 's/.*worktree create//')" "worktree list"
# … and the tree does exist (the create landed before the runtime dropped, on the branch
# --branch named): use it.
out=$(FX_CREATE_LANDS=1 bash "$WT" create --kind ticket --key AB-606 --name 'AB-606 · ru' --base main \
        --branch task/dev/AB-606-ru 2>"$SANDBOX/err"); rc=$?
assert_status "runtime_unavailable + existing tree: exit 0" 0 "$rc"
assert_eq "runtime_unavailable + existing tree: uses it" "$O/AB-606-ru" "$(col "$out" 1)"
assert_contains "runtime_unavailable + existing tree: says so" "$(cat "$SANDBOX/err")" "exists — using it"
assert_eq "runtime_unavailable + existing tree: landed on the ticket branch" task/dev/AB-606-ru "$(col "$out" 3)"

# ok, but a path this machine cannot reach: exit 1, and the Orca tree is removed
printf '%s\n' '{"ok":true,"result":{"worktree":{"path":"\\\\wsl.localhost\\d\\nowhere\\x","id":"R::\\\\wsl.localhost\\d\\nowhere\\x"}}}' > "$FX/create.json"
echo 0 > "$FX/create.rc"; reset_log
bash "$WT" create --kind work --key far --name far --base main --branch work/far >/dev/null 2>&1
assert_status "unreachable path: exit 1" 1 "$?"
assert_contains "unreachable path: the Orca tree is removed" "$(logged)" "orca worktree rm --worktree id:R::"
rm -f "$FX/create.json" "$FX/create.rc"

# landing fails after Orca made the tree: the fresh tree is removed, never left for a later
# create to "reuse" on Orca's auto branch
export FX_RM_PATH="$O/AB-707-foo"; reset_log
bash "$WT" create --kind ticket --key AB-707 --name 'AB-707 · foo' --base main --adopt task/dev/AB-707-nope >/dev/null 2>&1
assert_status "landing fails: exit 1" 1 "$?"
assert_contains "landing fails: the fresh Orca tree is removed" "$(logged)" "orca worktree rm --worktree id:R::"
assert_eq "landing fails: no directory left" no "$([ -e "$O/AB-707-foo" ] && echo yes || echo no)"
assert_eq "landing fails: Orca's auto branch gone" "" "$(git branch --list 'dev/AB-707-foo')"
unset FX_RM_PATH
out=$(bash "$WT" create --kind ticket --key AB-707 --name 'AB-707 · foo' --base main --branch task/dev/AB-707-foo 2>/dev/null); rc=$?
assert_status "landing fails, retry: exit 0" 0 "$rc"
assert_eq "landing fails, retry: on the asked branch" task/dev/AB-707-foo "$(col "$out" 3)"

# an existing local branch is not named at creation (Orca would cut `<name>-2` beside a branch
# that does not sit at the base): the tree is switched onto it
git branch task/dev/AB-808-old main; reset_log
out=$(bash "$WT" create --kind ticket --key AB-808 --name 'AB-808 · old' --base main --branch task/dev/AB-808-old 2>/dev/null); rc=$?
assert_status "existing branch: exit 0" 0 "$rc"
assert_eq "existing branch: on it" task/dev/AB-808-old "$(col "$out" 3)"
assert_not_contains "existing branch: no --branch to Orca" "$(logged)" "--branch"
assert_eq "existing branch: Orca's auto branch dropped" "" "$(git branch --list 'dev/AB-808-old')"
# … and a work workspace on an existing branch is refused before Orca is called
git branch work/taken main; reset_log
bash "$WT" create --kind work --key taken --name taken --base main --branch work/taken >/dev/null 2>&1
assert_status "work on an existing branch: exit 1" 1 "$?"
assert_not_contains "work on an existing branch: Orca never called" "$(logged)" "worktree create"

# an Orca below the floor: said once, plain git worktrees meanwhile
printf '%s\n' '{"ok":true,"result":{"runtime":{"state":"ready","reachable":true,"appVersion":"1.4.200"}}}' > "$FX/status.json"
out=$(bash "$WT" create --kind work --key oldorca --name oldorca --base main --branch work/oldorca 2>&1 >/dev/null); rc=$?
assert_status "old Orca: exit 0" 0 "$rc"
assert_contains "old Orca: says to update" "$out" "Orca 1.4.200 is older than 1.4.246 — update Orca"
assert_contains "old Orca: used git" "$out" "(git)"

# HI_WT_BACKEND=orca with Orca down: exit 1, never a silent git fallback
orca_off; export HI_WT_BACKEND=orca
bash "$WT" create --kind work --key forced --name forced --base main --branch work/forced >/dev/null 2>&1
assert_status "forced orca, Orca down: exit 1" 1 "$?"
assert_summary
