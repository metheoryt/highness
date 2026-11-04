#!/usr/bin/env bash
# lib/wt.sh — real workspaces it misjudged: two trees of one ticket, a rebased branch
# that landed, a PR on a differently named upstream branch, a tree removed while create ran.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }
row() { bash "$WT" list --state 2>/dev/null | awk -F'\t' -v p="$1" '$1 == p'; }
pr() { printf '[{"state":"%s","number":%s,"headRefOid":"%s"}]\n' "$2" "$3" "$4" > "$FX/prs/$(printf '%s' "$1" | tr '/' '_').json"; }
mk() { bash "$WT" create --kind ticket --key "$1" --name "$1 · $2" --base main --branch "task/dev/$1-$2" 2>"$SANDBOX/create.err" | cut -f1; }
there() { [ -d "$1" ] && echo yes || echo no; }

mk_repo; cd "$R"

# two workspaces of one ticket. The record names the new one; the old one keeps its own
# folder name and no borrowed session, and removing it leaves the new one's record alone.
OLD=$(mk AB-1 old); bash "$WT" rec set --ticket AB-1 session s-old
(cd "$OLD" && git commit -q --allow-empty -m work && git push -q origin HEAD:main)
git merge -q --ff-only origin/main
NEW=$(mk AB-1 new)
assert_contains "second tree: create warns the key has one" "$(cat "$SANDBOX/create.err")" "AB-1 already has a workspace"
assert_contains "second tree: the warning names the old path" "$(cat "$SANDBOX/create.err")" "$OLD"
bash "$WT" rec set --ticket AB-1 session s-new
o=$(row "$OLD"); n=$(row "$NEW")
assert_eq "old tree: listed by its folder name" "${OLD##*/}" "$(col "$o" 7)"
assert_eq "old tree: no borrowed session" "" "$(col "$o" 9)"
assert_eq "new tree: the record's name" "AB-1 · new" "$(col "$n" 7)"
assert_eq "new tree: the record's session" s-new "$(col "$n" 9)"
assert_eq "find --ticket: the tree the record names" "$NEW" "$(bash "$WT" find --ticket AB-1 | cut -f1)"
assert_eq "old tree: landed by its own branch, not the new tree's base" landed "$(col "$o" 14)"
assert_eq "new tree: fresh, not landed" no-pr "$(col "$n" 18)"
bash "$WT" remove-if-safe "$OLD" >/dev/null 2>&1; rc=$?
assert_status "old tree: removed" 0 "$rc"
assert_eq "old tree: gone" no "$(there "$OLD")"
assert_eq "removing the old tree keeps the new one's record" "$NEW" "$(bash "$WT" rec get --ticket AB-1 workspace)"
assert_eq "removing the old tree keeps the new one's session" s-new "$(bash "$WT" rec get --ticket AB-1 session)"
bash "$WT" remove "$NEW" >/dev/null 2>&1
assert_status "removing the recorded tree still clears the record" 1 "$(bash "$WT" rec get --ticket AB-1 workspace >/dev/null 2>&1; echo $?)"

# rebased (here: cherry-picked) into trunk before it landed. Its own sha is on no remote
# and its tree is no trunk commit's, yet every patch is in trunk.
P=$(mk AB-2 rebased); (cd "$P" && echo a > a.txt && git add a.txt && git commit -qm a)
H=$(git -C "$P" rev-parse HEAD)
s=$(row "$P")
assert_eq "not yet landed: pr none" none "$(col "$s" 14)"
assert_eq "not yet landed: not safe" no "$(col "$s" 17)"
echo t > t.txt && git add t.txt && git commit -qm trunk-moved && git cherry-pick "$H" >/dev/null && git push -q origin main
s=$(row "$P")
assert_eq "rebased and landed: pr landed" landed "$(col "$s" 14)"
assert_eq "rebased and landed: pushed (its work is in trunk)" yes "$(col "$s" 12)"
assert_eq "rebased and landed: safe" yes "$(col "$s" 17)"
out=$(bash "$WT" remove-if-safe "$P" 2>&1); rc=$?
assert_status "rebased and landed: removed" 0 "$rc"
assert_eq "rebased and landed: branch deleted" "" "$(git branch --list task/dev/AB-2-rebased)"
# empty commits share one patch id: an empty commit on trunk must not "land" an empty branch
P=$(mk AB-3 empty); (cd "$P" && git commit -q --allow-empty -m nothing)
git commit -q --allow-empty -m trunk-empty && git push -q origin main
assert_eq "empty unpushed commit: not safe" no "$(col "$(row "$P")" 17)"
bash "$WT" remove "$P" >/dev/null 2>&1

# the local branch tracks a differently named origin branch; the PR is on the upstream's name
P=$(bash "$WT" create --kind ticket --key AB-4 --name 'AB-4 · up' --base main --branch fix/AB-4-up 2>/dev/null | cut -f1)
(cd "$P" && git commit -q --allow-empty -m w && git push -q -u origin HEAD:bug/AB-4-up)
pr bug/AB-4-up OPEN 44 "$(git -C "$P" rev-parse HEAD)"
s=$(row "$P")
assert_eq "upstream branch: its PR found" 'open#44' "$(col "$s" 14)"
assert_eq "upstream branch: pr-open, not no-pr" pr-open "$(col "$s" 18)"
rm -f "$FX/prs/bug_AB-4-up.json"; pr fix/AB-4-up OPEN 45 x
assert_eq "no PR on the upstream: the local name is still asked" 'open#45' "$(col "$(row "$P")" 14)"
bash "$WT" remove "$P" >/dev/null 2>&1
# a branch cut from origin/main tracks it: a PR whose head is main is never this workspace's
P=$(mk AB-7 trunk); git -C "$P" branch -q --set-upstream-to=origin/main
pr main MERGED 70 "$(git -C "$P" rev-parse HEAD)"
s=$(row "$P")
assert_eq "upstream is the trunk: its PR is not this one" none "$(col "$s" 14)"
assert_eq "upstream is the trunk: fresh, not safe" no "$(col "$s" 17)"
rm -f "$FX/prs/main.json"; bash "$WT" remove "$P" >/dev/null 2>&1

# the tree is removed while setup runs (create timed out, the work landed and was
# cleaned up). No record is written; a leftover with only setup's .claude/ is cleared.
cat > "$STUB/setup-gone" <<'SH'
#!/usr/bin/env bash
p=$(pwd -P); cd /
git -C "$FX_REPO" worktree remove --force "$p" >/dev/null 2>&1
mkdir -p "$p/.claude" && : > "$p/.claude/settings.local.json"
[ -n "${FX_SETUP_EXTRA:-}" ] && : > "$p/$FX_SETUP_EXTRA"
exit 0
SH
chmod +x "$STUB/setup-gone"
out=$(HI_WT_SETUP="$STUB/setup-gone" bash "$WT" create --kind ticket --key AB-5 --name 'AB-5 · gone' \
        --base main --branch task/dev/AB-5-gone 2>&1); rc=$?
D="$SANDBOX/wt/app/AB-5-gone"
assert_status "removed during setup: exit 1" 1 "$rc"
assert_contains "removed during setup: says so" "$out" "was removed while setup ran"
assert_not_contains "removed during setup: not the old riddle" "$out" "cannot list it"
assert_eq "removed during setup: .claude-only leftover cleared" no "$(there "$D")"
assert_status "removed during setup: no record" 1 "$(bash "$WT" rec get --ticket AB-5 workspace >/dev/null 2>&1; echo $?)"
out=$(FX_SETUP_EXTRA=notes.txt HI_WT_SETUP="$STUB/setup-gone" bash "$WT" create --kind ticket --key AB-6 \
        --name 'AB-6 · left' --base main --branch task/dev/AB-6-left 2>&1); rc=$?
D="$SANDBOX/wt/app/AB-6-left"
assert_status "leftover with other files: exit 1" 1 "$rc"
assert_contains "leftover with other files: named, not deleted" "$out" "not deleted"
assert_eq "leftover with other files: kept" yes "$(there "$D")"
rm -rf "$D"

assert_summary
