#!/usr/bin/env bash
# lib/wt.sh remove / remove-if-safe / sweep — guards first, then removal judged by the filesystem.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
pr() { printf '[{"state":"%s","number":%s,"headRefOid":"%s"}]\n' "$2" "$3" "$4" > "$FX/prs/$(printf '%s' "$1" | tr '/' '_').json"; }
mk() { bash "$WT" create --kind ticket --key "$1" --name "$1 · $2" --base main --branch "task/dev/$1-$2" 2>/dev/null | cut -f1; }
done_pr() { (cd "$2" && git commit -q --allow-empty -m w && git push -q origin HEAD); pr "task/dev/$1" MERGED "$3" "$(git -C "$2" rev-parse HEAD)"; }
count_wt() { git -C "$R" worktree list | wc -l | tr -d ' '; }

mk_repo; cd "$R"
OTHER="$SANDBOX/other"; git init -q "$OTHER"; git -C "$OTHER" commit -q --allow-empty -m x

# guards: nothing that is not a workspace of this repo is ever removed
n=$(count_wt); reset_log
for t in '' "$R" "$OTHER" "$SANDBOX" "$R/.git"; do
  bash "$WT" remove "$t" >/dev/null 2>&1; rc=$?
  assert_status "remove guard [${t:-<empty>}]: exit 2" 2 "$rc"
  bash "$WT" remove-if-safe "$t" >/dev/null 2>&1; rc=$?
  assert_status "remove-if-safe guard [${t:-<empty>}]: exit 2" 2 "$rc"
done
assert_eq "guards: no worktree removed" "$n" "$(count_wt)"
assert_not_contains "guards: no removal call" "$(logged)" "worktree rm"
assert_eq "guards: the other repo is intact" yes "$([ -d "$OTHER/.git" ] && echo yes || echo no)"

# the workspace this session stands in is never removed, even on an explicit remove
P=$(mk AB-101 here); done_pr AB-101-here "$P" 11
out=$(cd "$P" && bash "$WT" remove "$P" 2>&1); rc=$?
assert_status   "remove from inside: exit 2" 2 "$rc"
assert_contains "remove from inside: says why" "$out" "inside it"
assert_eq "remove from inside: still there" yes "$([ -d "$P" ] && echo yes || echo no)"

# remove-if-safe refuses with reasons; nothing removed
P=$(mk AB-102 dirty); done_pr AB-102-dirty "$P" 12; echo x > "$P/new.txt"
out=$(bash "$WT" remove-if-safe "$P" 2>/dev/null); rc=$?
assert_status "unsafe: exit 3" 3 "$rc"
assert_eq "unsafe: reason line" "unsafe	dirty	uncommitted changes" "$out"
assert_eq "unsafe: still there" yes "$([ -d "$P" ] && echo yes || echo no)"

# remove-if-safe on a safe git workspace: teardown in the tree, removal, record, merged branch deleted
P=$(mk AB-103 gone); done_pr AB-103-gone "$P" 13
bash "$WT" rec set --ticket AB-103 session s-103
reset_log
bash "$WT" remove-if-safe "$P" 2>"$SANDBOX/err"; rc=$?
assert_status "safe: exit 0" 0 "$rc"
assert_eq "safe: directory gone" no "$([ -e "$P" ] && echo yes || echo no)"
assert_contains "safe: teardown ran inside the tree first" "$(logged)" "teardown $P"
assert_contains "safe: gortex untrack, best-effort" "$(logged)" "gortex untrack $P"
assert_eq "safe: branch merged at its head is deleted" "" "$(git branch --list task/dev/AB-103-gone)"
assert_contains "safe: announce names the way back" "$(cat "$SANDBOX/err")" "branch task/dev/AB-103-gone deleted, its work is merged (back: git branch task/dev/AB-103-gone"
out=$(bash "$WT" rec get --ticket AB-103 workspace); rc=$?
assert_status "safe: record workspace unset" 1 "$rc"
assert_contains "safe: announce names the resume command" "$(cat "$SANDBOX/err")" "claude --resume s-103"

# remove (owner said yes) works on an unsafe tree
bash "$WT" remove "$(bash "$WT" find --ticket AB-102 | cut -f1)" 2>/dev/null; rc=$?
assert_status "remove: exit 0 on a dirty tree" 0 "$rc"

# remove (owner said yes) of unproven work keeps its branch
P=$(mk AB-104 wip); (cd "$P" && git commit -q --allow-empty -m wip)
out=$(bash "$WT" remove "$P" 2>&1)
assert_eq "unproven: branch kept" task/dev/AB-104-wip "$(git branch --list task/dev/AB-104-wip | tr -d ' *')"
assert_contains "unproven: announced kept" "$out" "branch task/dev/AB-104-wip kept"

# no PR, fast-forwarded into origin/main: safe, and its branch goes with it
P=$(mk AB-105 landed); (cd "$P" && git commit -q --allow-empty -m work && git push -q origin HEAD:main)
out=$(bash "$WT" remove-if-safe "$P" 2>&1); rc=$?
assert_status "landed: removed" 0 "$rc"
assert_eq "landed: branch deleted" "" "$(git branch --list task/dev/AB-105-landed)"
git merge -q --ff-only origin/main

# squash-merged with no PR: its commits are off trunk, but a trunk commit carries its exact tree
P=$(mk AB-106 squash); (cd "$P" && echo a > a.txt && git add a.txt && git commit -qm a &&
  echo b > b.txt && git add b.txt && git commit -qm b && git push -q origin HEAD)
out=$(bash "$WT" remove-if-safe "$P" 2>/dev/null); rc=$?
assert_status "squash, not yet merged: refused" 3 "$rc"
assert_contains "squash, not yet merged: no-pr" "$out" "no-pr"
git merge -q --squash task/dev/AB-106-squash && git commit -qm squash && git push -q origin main
out=$(bash "$WT" remove-if-safe "$P" 2>&1); rc=$?
assert_status "squash-merged: removed" 0 "$rc"
assert_eq "squash-merged: branch deleted" "" "$(git branch --list task/dev/AB-106-squash)"

# review removal drops the private ref
SHA=$(git rev-parse HEAD); git update-ref refs/hi-review/7 "$SHA"
V=$(bash "$WT" create --kind review --key 7 --name 'review #7' --detach "$SHA" 2>/dev/null | cut -f1)
bash "$WT" remove "$V" 2>/dev/null
assert_eq "review: ref dropped" "" "$(git for-each-ref refs/hi-review/7)"

# Orca removal: --run-hooks, never --allow-failed-archive-hook; filesystem decides
orca_on
P=$(mk AB-201 orca); done_pr AB-201-orca "$P" 21
export FX_RM_PATH="$P"; reset_log
bash "$WT" remove-if-safe "$P" 2>/dev/null; rc=$?
assert_status "orca: exit 0" 0 "$rc"
assert_contains "orca: rm argv" "$(logged)" "orca worktree rm --worktree id:R::"
assert_contains "orca: --run-hooks" "$(logged)" "--force --run-hooks --json"
assert_not_contains "orca: never waives the archive hook" "$(logged)" "allow-failed-archive-hook"
assert_not_contains "orca: no teardown dispatcher (Orca's hook runs it)" "$(logged)" "teardown "

P=$(mk AB-202 hook); done_pr AB-202-hook "$P" 22
export FX_RM_PATH="$P" FX_RM_KEEP=1
printf '%s\n' '{"ok":false,"error":{"code":"worktree_archive_hook_failed","message":"db busy"}}' > "$FX/rm.json"; echo 1 > "$FX/rm.rc"
out=$(bash "$WT" remove-if-safe "$P" 2>&1); rc=$?
assert_status   "archive hook failed: exit 1" 1 "$rc"
assert_contains "archive hook failed: surfaced" "$out" "db busy"
assert_eq "archive hook failed: still there" yes "$([ -d "$P" ] && echo yes || echo no)"
unset FX_RM_KEEP

printf '%s\n' '{"ok":false,"error":{"code":"weird"}}' > "$FX/rm.json"
bash "$WT" remove "$P" 2>/dev/null; rc=$?
assert_status "ok:false but the tree is gone: success" 0 "$rc"
rm -f "$FX/rm.json" "$FX/rm.rc"

P=$(mk AB-203 leak); done_pr AB-203-leak "$P" 23
export FX_RM_PATH="$P" FX_RM_LEAK=1
out=$(bash "$WT" remove "$P" 2>&1); rc=$?
assert_status   "leak: exit 4" 4 "$rc"
assert_contains "leak: sudo hint" "$out" "sudo rm -rf $P"
unset FX_RM_LEAK FX_RM_PATH; rm -rf "$P"

# Orca answers before the tree is gone ("removing": true, the tree goes ~1 s
# later). Read at once, that is a false "still a worktree" or a false LEAKED: wt.sh waits.
P=$(mk AB-207 async); done_pr AB-207-async "$P" 27
export FX_RM_PATH="$P" FX_RM_ASYNC=1
out=$(bash "$WT" remove "$P" 2>&1); rc=$?
assert_status "async rm read at once (HI_WT_RM_WAIT=0): the race is real" 1 "$rc"
sleep 2
P=$(mk AB-208 async); done_pr AB-208-async "$P" 28
export FX_RM_PATH="$P"
out=$(HI_WT_RM_WAIT=10 bash "$WT" remove-if-safe "$P" 2>&1); rc=$?
assert_status "async rm, waited: exit 0" 0 "$rc"
assert_contains "async rm, waited: announced removed" "$out" "removed \"AB-208 · async\""
assert_not_contains "async rm, waited: no false failure" "$out" "removal failed"
assert_not_contains "async rm, waited: no false leak" "$out" "LEAKED"
unset FX_RM_ASYNC
P=$(mk AB-209 stuck); done_pr AB-209-stuck "$P" 29
export FX_RM_PATH="$P" FX_RM_KEEP=1
printf '%s\n' '{"ok":false,"error":{"code":"weird","message":"boom"}}' > "$FX/rm.json"; echo 1 > "$FX/rm.rc"
out=$(bash "$WT" remove "$P" 2>&1); rc=$?
assert_status   "a tree that stays: exit 1" 1 "$rc"
assert_contains "a tree that stays: Orca's error is named" "$out" "still a worktree after 0s (orca: weird boom)"
rm -f "$FX/rm.json" "$FX/rm.rc"; unset FX_RM_KEEP
bash "$WT" remove "$P" >/dev/null 2>&1; unset FX_RM_PATH

# Orca's rm deletes a branch it believes merged (it deleted one whose head was on no branch
# anywhere, 2026-09-25). wt.sh puts an unproven one back at the same sha; a merged one stays gone.
P=$(mk AB-205 delbr); (cd "$P" && git commit -q --allow-empty -m wip)
H205=$(git -C "$P" rev-parse HEAD)
export FX_RM_PATH="$P" FX_RM_DELBRANCH=task/dev/AB-205-delbr
out=$(bash "$WT" remove "$P" 2>&1)
assert_eq "orca deleted the branch: restored at its head" "$H205" "$(git rev-parse --verify -q refs/heads/task/dev/AB-205-delbr)"
assert_contains "orca deleted the branch: announced as restored" "$out" "branch task/dev/AB-205-delbr kept (restored after Orca deleted it)"
P=$(mk AB-206 delmerged); done_pr AB-206-delmerged "$P" 26
export FX_RM_PATH="$P" FX_RM_DELBRANCH=task/dev/AB-206-delmerged
out=$(bash "$WT" remove-if-safe "$P" 2>&1)
assert_eq "orca deleted a merged branch: not restored" "" "$(git branch --list task/dev/AB-206-delmerged)"
assert_contains "orca deleted a merged branch: announced deleted" "$out" "branch task/dev/AB-206-delmerged deleted"
unset FX_RM_DELBRANCH FX_RM_PATH

# an idle Orca terminal is closed before the removal
P=$(mk AB-204 idle); done_pr AB-204-idle "$P" 24
unc() { printf '%s%s' '\\wsl.localhost\d' "$(printf '%s' "$1" | tr '/' '\\')"; }
jq -n --arg p "$(unc "$P")" '{ok:true,result:{terminals:[{handle:"h7",connected:true,writable:true,worktreePath:$p,title:"t"}]}}' > "$FX/terms.json"
export FX_RM_PATH="$P"; reset_log
bash "$WT" remove-if-safe "$P" 2>/dev/null; rc=$?
assert_status "idle terminal: removed" 0 "$rc"
assert_contains "idle terminal: closed before rm" "$(logged | sed 's/worktree rm.*//')" "terminal close --terminal h7"
rm -f "$FX/terms.json"; unset FX_RM_PATH; orca_off

# sweep: safe+finished removed, finished+unsafe asked, open left alone, cwd skipped silently
S1=$(mk AB-301 safe);  done_pr AB-301-safe "$S1" 31
S2=$(mk AB-302 ask);   done_pr AB-302-ask "$S2" 32; echo x > "$S2/new.txt"
S3=$(mk AB-303 open);  pr task/dev/AB-303-open OPEN 33 x
S4=$(mk AB-304 cwd);   done_pr AB-304-cwd "$S4" 34
S7=$(mk AB-307 landed); (cd "$S7" && git commit -q --allow-empty -m w && git push -q origin HEAD:main)
# a work workspace and an unrecorded scratch one, both landed in trunk: never removed unasked
S8=$(bash "$WT" create --kind work --key lounge --name 'lounge' --base main --branch work/lounge 2>/dev/null | cut -f1)
(cd "$S8" && git pull -q --rebase origin main && git commit -q --allow-empty -m work-lounge && git push -q origin HEAD:main)
S9="$SANDBOX/scratch-wt"; git worktree add -q -b scratch "$S9" main
(cd "$S9" && git pull -q --rebase origin main && git commit -q --allow-empty -m scratch && git push -q origin HEAD:main)
touch "$FX/gh.drain"
out=$(cd "$S4" && bash "$WT" sweep 2>/dev/null); rc=$?
rm -f "$FX/gh.drain"
assert_status "sweep: exit 0" 0 "$rc"
assert_contains "sweep: removed the safe one" "$out" "removed	$S1	AB-301 · safe"
assert_contains "sweep: removed the landed one (no PR)" "$out" "removed	$S7	AB-307 · landed"
assert_contains "sweep: asks about the dirty merged one" "$out" "ask	$S2	AB-302 · ask	uncommitted changes"
assert_not_contains "sweep: leaves the open one alone" "$out" "$S3"
assert_not_contains "sweep: never touches the cwd's workspace" "$out" "$S4"
assert_eq "sweep: cwd workspace still there" yes "$([ -d "$S4" ] && echo yes || echo no)"
assert_eq "sweep: open workspace still there" yes "$([ -d "$S3" ] && echo yes || echo no)"
assert_contains "sweep: a landed work workspace is an ask" "$out" "ask	$S8	lounge	a work or scratch workspace"
assert_contains "sweep: a landed scratch workspace is an ask" "$out" "ask	$S9	scratch-wt	a work or scratch workspace"
assert_not_contains "sweep: never removes a work workspace" "$out" "removed	$S8"
assert_not_contains "sweep: never removes a scratch workspace" "$out" "removed	$S9"
assert_eq "sweep: work workspace still there" yes "$([ -d "$S8" ] && echo yes || echo no)"
assert_eq "sweep: scratch workspace still there" yes "$([ -d "$S9" ] && echo yes || echo no)"

# remove-if-landed (an unattended caller's verb): safe is not enough, the ticket's work must be in trunk
L1=$(mk AB-401 merged); done_pr AB-401-merged "$L1" 41
L2=$(mk AB-402 closed); (cd "$L2" && git commit -q --allow-empty -m w && git push -q origin HEAD)
pr task/dev/AB-402-closed CLOSED 42 "$(git -C "$L2" rev-parse HEAD)"
out=$(bash "$WT" remove-if-landed "$L2" 2>/dev/null); rc=$?
assert_status "if-landed: a PR closed unmerged is refused" 3 "$rc"
assert_eq "if-landed: says it is not landed" "unsafe	not-landed	not landed: its PR is closed, not merged, and its work is not in trunk" "$out"
assert_eq "if-landed: the closed one stays" yes "$([ -d "$L2" ] && echo yes || echo no)"
out=$(bash "$WT" remove-if-landed "$S8" 2>/dev/null); rc=$?
assert_status "if-landed: a work workspace is refused, even landed" 3 "$rc"
assert_eq "if-landed: says it is not a ticket" "unsafe	not-ticket	a work workspace: only a ticket workspace is removed unattended" "$out"
out=$(bash "$WT" remove-if-landed "$S9" 2>/dev/null); rc=$?
assert_status "if-landed: an unrecorded scratch workspace is refused" 3 "$rc"
assert_eq "if-landed: the work and scratch ones stay" "yes yes" "$([ -d "$S8" ] && echo yes || echo no) $([ -d "$S9" ] && echo yes || echo no)"
out=$(bash "$WT" remove-if-landed "$S3" 2>/dev/null); rc=$?
assert_status "if-landed: an open PR is refused" 3 "$rc"
assert_contains "if-landed: the open PR is named" "$out" "unsafe	pr-open	"
bash "$WT" remove-if-landed "$L1" 2>/dev/null; rc=$?
assert_status "if-landed: a merged ticket workspace is removed" 0 "$rc"
assert_eq "if-landed: the merged one is gone" no "$([ -e "$L1" ] && echo yes || echo no)"
bash "$WT" remove "$L2" >/dev/null 2>&1

# sweep reports what went wrong: a failed archive hook and a leaked directory are rows, not
# stderr only (the skills render stdout)
orca_on
S5=$(mk AB-305 hook); done_pr AB-305-hook "$S5" 35
printf '%s\n' '{"ok":false,"error":{"code":"worktree_archive_hook_failed","message":"db busy"}}' > "$FX/rm.json"; echo 1 > "$FX/rm.rc"
export FX_RM_PATH="$S5" FX_RM_KEEP=1
out=$(cd "$R" && bash "$WT" sweep 2>/dev/null)
assert_contains "sweep: a failed removal is a failed row" "$out" "failed	$S5	AB-305 · hook	"
assert_contains "sweep: the failed row carries the reason" "$(printf '%s\n' "$out" | grep "^failed	$S5")" "db busy"
assert_not_contains "sweep: a failed removal is never reported removed" "$out" "removed	$S5"
rm -f "$FX/rm.json" "$FX/rm.rc"; unset FX_RM_KEEP
bash "$WT" remove "$S5" >/dev/null 2>&1
S6=$(mk AB-306 leak); done_pr AB-306-leak "$S6" 36
export FX_RM_PATH="$S6" FX_RM_LEAK=1
out=$(cd "$R" && bash "$WT" sweep 2>/dev/null)
assert_contains "sweep: a leaked directory is a leaked row with the sudo hint" "$out" "leaked	$S6	AB-306 · leak	sudo rm -rf $S6"
assert_not_contains "sweep: a leak is never reported removed" "$out" "removed	$S6"
unset FX_RM_LEAK FX_RM_PATH; rm -rf "$S6"; orca_off
assert_summary
