#!/usr/bin/env bash
# lib/wt.sh list --state — every safety check, one workspace per case, all read-only.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }
st() { bash "$WT" list --state 2>/dev/null | awk -F'\t' -v s="/$1" 'substr($1, length($1) - length(s) + 1) == s'; }
pr() { printf '[{"state":"%s","number":%s,"headRefOid":"%s"}]\n' "$2" "$3" "$4" > "$FX/prs/$(printf '%s' "$1" | tr '/' '_').json"; }
mk() { bash "$WT" create --kind ticket --key "$1" --name "$1 · $2" --base main --branch "task/dev/$1-$2" 2>/dev/null | cut -f1; }

mk_repo; cd "$R"
printf '.claude/\n' > .gitignore && git add .gitignore && git commit -qm ignore && git push -q origin main
mkdir -p .claude/memory && echo main-memory > .claude/memory/project.md

# 1. merged, pushed, clean → safe
P=$(mk AB-101 merged); (cd "$P" && git commit -q --allow-empty -m work && git push -q origin HEAD)
pr task/dev/AB-101-merged MERGED 11 "$(git -C "$P" rev-parse HEAD)"
s=$(st AB-101-merged)
assert_eq "merged+pushed: 18 columns" 18 "$(printf '%s' "$s" | awk -F'\t' '{print NF}')"
assert_eq "merged+pushed: dirty 0" 0 "$(col "$s" 11)"
assert_eq "merged+pushed: pushed yes" yes "$(col "$s" 12)"
assert_eq "merged+pushed: pr merged#11" 'merged#11' "$(col "$s" 14)"
assert_eq "merged+pushed: safe" yes "$(col "$s" 17)"
assert_eq "merged+pushed: no reasons" "" "$(col "$s" 18)"
assert_eq "merged+pushed: age is a number" yes "$(col "$s" 16 | grep -Eq '^[0-9]+$' && echo yes || echo no)"

# 2. squash-merged: the branch is gone from origin, HEAD == the PR's final head → safe
P=$(mk AB-102 squash); (cd "$P" && git commit -q --allow-empty -m work)
pr task/dev/AB-102-squash MERGED 12 "$(git -C "$P" rev-parse HEAD)"
assert_eq "squash: safe via headRefOid" yes "$(col "$(st AB-102-squash)" 17)"

# 3. merged, but HEAD moved on after the PR and was never pushed → unpushed
P=$(mk AB-103 moved); (cd "$P" && git commit -q --allow-empty -m pr)
pr task/dev/AB-103-moved MERGED 13 "$(git -C "$P" rev-parse HEAD)"
(cd "$P" && git commit -q --allow-empty -m later)
s=$(st AB-103-moved)
assert_eq "moved on: pushed no" no "$(col "$s" 12)"
assert_eq "moved on: reason unpushed" unpushed "$(col "$s" 18)"

# 4. open PR
P=$(mk AB-104 open); pr task/dev/AB-104-open OPEN 14 x
assert_eq "open: reason pr-open" pr-open "$(col "$(st AB-104-open)" 18)"

# 5. dirty (an untracked file counts; an ignored one does not)
P=$(mk AB-105 dirty); (cd "$P" && git commit -q --allow-empty -m w && git push -q origin HEAD)
pr task/dev/AB-105-dirty MERGED 15 "$(git -C "$P" rev-parse HEAD)"
mkdir -p "$P/.claude" && echo x > "$P/.claude/settings.local.json"
assert_eq "ignored file: still safe" yes "$(col "$(st AB-105-dirty)" 17)"
echo x > "$P/new.txt"
assert_eq "untracked file: dirty" dirty "$(col "$(st AB-105-dirty)" 18)"

# 6. memory: a regular file forks the memory; a link to main's copy is fine; a link elsewhere is not
P=$(mk AB-106 mem); (cd "$P" && git commit -q --allow-empty -m w && git push -q origin HEAD)
pr task/dev/AB-106-mem MERGED 16 "$(git -C "$P" rev-parse HEAD)"
mkdir -p "$P/.claude/memory" && echo forked > "$P/.claude/memory/project.md"
s=$(st AB-106-mem)
assert_eq "memory regular file: unique" unique "$(col "$s" 13)"
assert_eq "memory regular file: reason" memory "$(col "$s" 18)"
rm "$P/.claude/memory/project.md" && ln -s "$R/.claude/memory/project.md" "$P/.claude/memory/project.md"
assert_eq "memory link to main: ok" ok "$(col "$(st AB-106-mem)" 13)"
echo other > "$SANDBOX/other.md"; rm "$P/.claude/memory/project.md"; ln -s "$SANDBOX/other.md" "$P/.claude/memory/project.md"
assert_eq "memory link elsewhere: unique" unique "$(col "$(st AB-106-mem)" 13)"

# 7. no PR, fresh from trunk → never finished
P=$(mk AB-107 fresh)
s=$(st AB-107-fresh)
assert_eq "no PR: pr none" none "$(col "$s" 14)"
assert_eq "no PR: reason no-pr" no-pr "$(col "$s" 18)"

# 7b. no PR, its own commits fast-forwarded into origin/main → landed, safe
P=$(mk AB-110 landed); (cd "$P" && git commit -q --allow-empty -m work && git push -q origin HEAD:main)
s=$(st AB-110-landed)
assert_eq "landed: pr landed" landed "$(col "$s" 14)"
assert_eq "landed: safe" yes "$(col "$s" 17)"
assert_eq "landed: no reasons" "" "$(col "$s" 18)"
# a fresh workspace made from that newer trunk is still not finished
git merge -q --ff-only origin/main; P=$(mk AB-111 fresh2)
assert_eq "fresh from a newer trunk: no-pr" no-pr "$(col "$(st AB-111-fresh2)" 18)"
# its own commits, not in origin → unpushed, never landed
P=$(mk AB-112 local); (cd "$P" && git commit -q --allow-empty -m wip)
s=$(st AB-112-local)
assert_eq "commits not in origin: pr none" none "$(col "$s" 14)"
assert_eq "commits not in origin: not safe" no "$(col "$s" 17)"
# a tree made before `base` was recorded: the branch's reflog gives the start
P=$(mk AB-113 oldrec); (cd "$P" && git commit -q --allow-empty -m work && git push -q origin HEAD:main)
bash "$WT" rec set --ticket AB-113 base '' 2>/dev/null
assert_eq "no base in the record: reflog decides, landed" landed "$(col "$(st AB-113-oldrec)" 14)"
# merged inside the workspace onto a detached HEAD (`checkout --detach origin/main && merge`):
# no branch to ask a PR or a reflog about, so the recorded base decides → landed
git fetch -q origin && git merge -q --ff-only origin/main
P=$(mk AB-114 detached); (cd "$P" && git commit -q --allow-empty -m work && git push -q origin HEAD:main &&
  git fetch -q origin && git checkout -q --detach origin/main)
s=$(st AB-114-detached)
assert_eq "detached, in trunk past base: branch column empty" "" "$(col "$s" 3)"
assert_eq "detached, in trunk past base: pr landed" landed "$(col "$s" 14)"
assert_eq "detached, in trunk past base: safe" yes "$(col "$s" 17)"
# detached at the very commit it started from → still not finished
P=$(mk AB-115 detfresh); git -C "$P" checkout -q --detach HEAD
assert_eq "detached at base: no-pr" no-pr "$(col "$(st AB-115-detfresh)" 18)"
# detached, no base in the record and no branch reflog to fall back on → cannot tell, no-pr
bash "$WT" rec set --ticket AB-114 base '' 2>/dev/null
assert_eq "detached, no base: no-pr" no-pr "$(col "$(st AB-114-detached)" 18)"
# origin/HEAD unset → cannot tell, stays no-pr
git remote set-head origin -d
assert_eq "origin/HEAD unset: no-pr" no-pr "$(col "$(st AB-110-landed)" 18)"
git remote set-head origin main >/dev/null

# 8. gh fails → pr-unknown
echo 1 > "$FX/gh.rc"
assert_contains "gh failure: pr-unknown" "$(col "$(st AB-101-merged)" 18)" pr-unknown
# a repo gh cannot read (Forgejo origin): work landed in trunk is still landed and safe
s=$(st AB-110-landed)
assert_eq "gh failure, landed: pr landed" landed "$(col "$s" 14)"
assert_eq "gh failure, landed: safe" yes "$(col "$s" 17)"
rm -f "$FX/gh.rc"

# 9. review: finished by its PR; pushed is '-'
SHA=$(git rev-parse HEAD)
V=$(bash "$WT" create --kind review --key 7 --name 'review #7' --detach "$SHA" 2>/dev/null | cut -f1)
printf '{"state":"CLOSED","number":7,"headRefOid":"%s"}\n' "$SHA" > "$FX/prs/view-7.json"
s=$(st review-7)
assert_eq "review: pushed '-'" - "$(col "$s" 12)"
assert_eq "review: closed#7" 'closed#7' "$(col "$s" 14)"
assert_eq "review: safe" yes "$(col "$s" 17)"
rm "$FX/prs/view-7.json"
assert_eq "review without a readable PR: pr-unknown" pr-unknown "$(col "$(st review-7)" 18)"

# 10. cwd: the session stands inside the workspace
P1=$(bash "$WT" find --ticket AB-101 | cut -f1)
assert_contains "cwd: reason" "$(cd "$P1" && bash "$WT" list --state | awk -F'\t' -v p="$P1" '$1 == p' | cut -f18)" cwd

# 11. tmux window still open (git backend)
printf 'AB-102 · squash\n' > "$FX/tmux-windows"
s=$(st AB-102-squash)
assert_eq "tmux window: terminal open" open "$(col "$s" 15)"
assert_eq "tmux window: reason" open-window "$(col "$s" 18)"
rm -f "$FX/tmux-windows"

# 14. an old merged PR on a reused branch name: HEAD is not that PR's head → never finished
P=$(mk AB-108 reuse); pr task/dev/AB-108-reuse MERGED 18 0123456789012345678901234567890123456789
s=$(st AB-108-reuse)
assert_eq "old PR on a reused branch: not safe" no "$(col "$s" 17)"
assert_contains "old PR on a reused branch: reason pr-stale" "$(col "$s" 18)" pr-stale
assert_contains "old PR on a reused branch: the owner reads why" "$(bash "$WT" remove-if-safe "$P" 2>/dev/null)" "PR #18 is merged, but HEAD"

# 13. a command that reads stdin must not eat the remaining rows
n=$(bash "$WT" list | grep -c .)
touch "$FX/gh.drain"
assert_eq "stdin-reading gh: every row still listed" "$n" "$(bash "$WT" list --state 2>/dev/null | grep -c .)"
rm -f "$FX/gh.drain"

# 14. memory: .claude/memory as a whole-directory link into a shared store, excluded via info/exclude
P=$(mk AB-109 dirlink); (cd "$P" && git commit -q --allow-empty -m w && git push -q origin HEAD)
pr task/dev/AB-109-dirlink MERGED 19 "$(git -C "$P" rev-parse HEAD)"
mkdir -p "$SANDBOX/store" "$SANDBOX/store-other"; echo shared > "$SANDBOX/store/project.md"
mv "$R/.claude/memory" "$SANDBOX/main-memory-real"; ln -s "$SANDBOX/store" "$R/.claude/memory"
rm -rf "$P/.claude/memory"; mkdir -p "$P/.claude"; ln -s "$SANDBOX/store" "$P/.claude/memory"
for g in "$R" "$P"; do printf '.claude/memory\n' >> "$(git -C "$g" rev-parse --git-path info/exclude)"; done
assert_eq "memory dir link to main's: ok" ok "$(col "$(st AB-109-dirlink)" 13)"
assert_eq "memory dir link to main's: safe" yes "$(col "$(st AB-109-dirlink)" 17)"
rm "$P/.claude/memory"; ln -s "$SANDBOX/store-other" "$P/.claude/memory"
assert_eq "memory dir link elsewhere: unique" unique "$(col "$(st AB-109-dirlink)" 13)"
# 15. the main checkout has no copy (memory linked per checkout from elsewhere): a link out of
# the tree loses nothing; one into it does
rm "$R/.claude/memory"
assert_eq "no main copy, dir link out of the tree: ok" ok "$(col "$(st AB-109-dirlink)" 13)"
assert_eq "no main copy, dir link out of the tree: safe" yes "$(col "$(st AB-109-dirlink)" 17)"
mkdir -p "$P/notes"; rm "$P/.claude/memory"; ln -s ../notes "$P/.claude/memory"
assert_eq "no main copy, link into the tree: unique" unique "$(col "$(st AB-109-dirlink)" 13)"
rm "$P/.claude/memory"; rmdir "$P/notes"; ln -s "$SANDBOX/store" "$P/.claude/memory"
mv "$SANDBOX/main-memory-real" "$R/.claude/memory"

# 12. Orca terminals: idle passes, busy blocks
orca_on
unc() { printf '%s%s' '\\wsl.localhost\d' "$(printf '%s' "$1" | tr '/' '\\')"; }
P2=$(bash "$WT" find --ticket AB-102 | cut -f1)
jq -n --arg p "$(unc "$P2")" '{ok:true,result:{terminals:[{handle:"h9",connected:true,writable:true,worktreePath:$p,title:"t",agentIdentity:"claude"}]}}' > "$FX/terms.json"
echo '{"ok":true}' > "$FX/wait.json"
assert_eq "orca idle terminal: idle" idle "$(col "$(st AB-102-squash)" 15)"
assert_eq "orca idle terminal: still safe" yes "$(col "$(st AB-102-squash)" 17)"
echo '{"ok":false,"error":{"code":"timeout"}}' > "$FX/wait.json"
assert_eq "orca busy terminal: reason busy" busy "$(col "$(st AB-102-squash)" 18)"
assert_not_contains "state never closes a terminal" "$(logged)" "terminal close"
# a bare shell never reports tui-idle: it is not a Claude terminal, so it neither blocks nor counts
jq -n --arg p "$(unc "$P2")" '{ok:true,result:{terminals:[{handle:"h8",connected:true,writable:true,worktreePath:$p,title:"Terminal 1"}]}}' > "$FX/terms.json"
assert_eq "plain shell, wait times out: terminal none" none "$(col "$(st AB-102-squash)" 15)"
assert_eq "plain shell, wait times out: still safe" yes "$(col "$(st AB-102-squash)" 17)"
rm -f "$FX/terms.json" "$FX/wait.json"; orca_off
assert_summary
