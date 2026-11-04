#!/usr/bin/env bash
# lib/orca.sh — the branch-for-ticket helpers (candidates, land-branch) and the terminal
# verbs (terminals, gated send). Never drives a real Orca: every Orca call goes to a stub
# on HI_ORCA, and a sentinel `orca-ide` first on PATH proves resolution never fell through.
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
O="$LIB/orca.sh"

# Sentinel: if anything here resolved Orca without HI_ORCA, it lands on this shim, not on
# the real orca-ide further down PATH. SANDBOX is not exported, so the log path is baked
# into the shim when it is written (unquoted heredoc), not read from its environment.
SENTINEL_LOG="$SANDBOX/orca-ide.log"
cat > "$SHIM/orca-ide" <<SH
#!/bin/sh
printf '%s\\n' "\$*" >> '$SENTINEL_LOG'
exit 45
SH
chmod +x "$SHIM/orca-ide"
# The sentinel must be able to go red: invoking it once must leave a log, then reset.
"$SHIM/orca-ide" self-check 2>/dev/null
assert_eq "sentinel: an invocation is recorded" "self-check" "$(cat "$SENTINEL_LOG" 2>/dev/null)"
rm -f "$SENTINEL_LOG"

git init -q --bare "$SANDBOX/origin.git"
git init -q "$SANDBOX/seed"; git -C "$SANDBOX/seed" commit -q --allow-empty -m init
for b in task/x/AB-101-a task/AB-1018-b bug/AB-101; do git -C "$SANDBOX/seed" branch "$b"; done
git -C "$SANDBOX/seed" push -q "$SANDBOX/origin.git" --all
git clone -q "$SANDBOX/origin.git" "$SANDBOX/repo"

# --- candidates ------------------------------------------------------------------
assert_eq "candidates: whole-token key match only" "bug/AB-101
task/x/AB-101-a" "$(bash "$O" candidates --repo "$SANDBOX/repo" --key AB-101)"
out=$(bash "$O" candidates --repo "$SANDBOX/repo" --key AB-999); rc=$?
assert_status "candidates: none is exit 0" 0 "$rc"; assert_eq "candidates: none is empty" "" "$out"
bash "$O" candidates --repo "$SANDBOX/repo" 2>/dev/null; assert_status "candidates: --key required" 2 "$?"
# origin cannot be asked (here: no origin remote at all) -> exit 4, unknown, never "none".
git init -q "$SANDBOX/noorigin"
out=$(bash "$O" candidates --repo "$SANDBOX/noorigin" --key AB-101 2>"$SANDBOX/cand.err"); rc=$?
assert_status "candidates: ls-remote failure is exit 4" 4 "$rc"
assert_eq "candidates: ls-remote failure prints nothing on stdout" "" "$out"
assert_contains "candidates: ls-remote failure gives the reason on stderr" "$(cat "$SANDBOX/cand.err")" \
  "orca.sh candidates: cannot list remote branches: "
assert_contains "candidates: …including git's own message" "$(cat "$SANDBOX/cand.err")" "origin"

# --- land-branch -----------------------------------------------------------------
git -C "$SANDBOX/repo" worktree add -q "$SANDBOX/wt1" -b dev/AB-7
bash "$O" land-branch "$SANDBOX/wt1" --branch task/x/AB-8-z --key AB-7 2>/dev/null
assert_status "land-branch: key/branch disagreement refused" 2 "$?"
assert_eq "…and HEAD unchanged" "dev/AB-7" "$(git -C "$SANDBOX/wt1" rev-parse --abbrev-ref HEAD)"
bash "$O" land-branch "$SANDBOX/wt1" --branch a/AB-7 --adopt b/AB-7 --key AB-7 2>/dev/null
assert_status "land-branch: --branch and --adopt exclusive" 2 "$?"
bash "$O" land-branch "$SANDBOX/wt1" --branch task/x/AB-7-slug --key AB-7; assert_status "land-branch: rename" 0 "$?"
assert_eq "renamed onto the convention name" "task/x/AB-7-slug" "$(git -C "$SANDBOX/wt1" rev-parse --abbrev-ref HEAD)"

git -C "$SANDBOX/repo" worktree add -q "$SANDBOX/wt2" -b dev/AB-101
bash "$O" land-branch "$SANDBOX/wt2" --adopt task/x/AB-101-a --key AB-101; assert_status "land-branch: adopt" 0 "$?"
assert_eq "adopted the origin branch" "task/x/AB-101-a" "$(git -C "$SANDBOX/wt2" rev-parse --abbrev-ref HEAD)"
assert_eq "tracking origin" "origin/task/x/AB-101-a" "$(git -C "$SANDBOX/wt2" rev-parse --abbrev-ref '@{u}')"
git -C "$SANDBOX/repo" show-ref --verify --quiet refs/heads/dev/AB-101; assert_status "the auto branch is dropped" 1 "$?"

# --- terminals / send against a stub Orca that speaks both POSIX and UNC paths ----
# term_b is read-only, term_e disconnected, term_f/term_g sit on paths that merely START
# with wt1 (a prefix match would wrongly claim them), term_d is elsewhere.
unc=$(jq -rn --arg p "$(printf '%s' "$SANDBOX/wt2" | tr '/' '\\')" '"\\\\wsl.localhost\\Ubuntu" + $p')
jq -n --arg a "$SANDBOX/wt1" --arg u "$unc" '{ok:true, result:{terminals:[
  {handle:"term_a", worktreePath:$a, connected:true,  writable:true,  agentIdentity:"claude", title:"t a"},
  {handle:"term_b", worktreePath:$a, connected:true,  writable:false, agentIdentity:"claude", title:"ro"},
  {handle:"term_e", worktreePath:$a, connected:false, writable:true,  agentIdentity:"claude", title:"gone"},
  {handle:"term_f", worktreePath:($a + "x"),    connected:true, writable:true, agentIdentity:"claude", title:"sib"},
  {handle:"term_g", worktreePath:($a + "/sub"), connected:true, writable:true, agentIdentity:"claude", title:"sub"},
  {handle:"term_c", worktreePath:$u, connected:true,  writable:true,  agentIdentity:"claude", title:"unc"},
  {handle:"term_d", worktreePath:"/elsewhere", connected:true, writable:true, agentIdentity:"", title:"x"} ]}}' > "$SANDBOX/terms.json"
# Logs each argument delimited as <arg>, so an unquoted --text (word-split) is visible.
cat > "$SHIM/fake-orca" <<'SH'
#!/usr/bin/env bash
{ printf '<%s>' "$@"; printf '\n'; } >> "$ORCA_STUB_LOG"
case "$1 $2" in
  "terminal list") cat "$ORCA_TERMS" ;;
  "terminal send") printf '{"ok":true}\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$SHIM/fake-orca"
export HI_ORCA="$SHIM/fake-orca" ORCA_TERMS="$SANDBOX/terms.json" ORCA_STUB_LOG="$SANDBOX/orca.log"
assert_eq "terminals: live+writable in that worktree" "$(printf 'term_a\tclaude\tt a')" "$(bash "$O" terminals "$SANDBOX/wt1")"
assert_eq "terminals: a UNC path matches its POSIX form" "term_c" "$(bash "$O" terminals "$SANDBOX/wt2" | cut -f1)"
assert_contains "terminals: asked the stub for the list" "$(cat "$ORCA_STUB_LOG")" "<terminal><list><--json>"

printf 'hello there\nsecond line\n' > "$SANDBOX/prompt.txt"
bash "$O" send term_a "$SANDBOX/prompt.txt" 2>/dev/null; assert_status "send: refused without HI_CONFIRMED" 3 "$?"
assert_not_contains "…and nothing was sent" "$(cat "$ORCA_STUB_LOG")" "<send>"
HI_CONFIRMED=1 bash "$O" send term_a "$SANDBOX/missing.txt" 2>/dev/null; assert_status "send: missing prompt file is exit 2" 2 "$?"
HI_CONFIRMED=1 bash "$O" send term_a "$SANDBOX/prompt.txt" >/dev/null; assert_status "send: confirmed" 0 "$?"
assert_contains "send: the whole prompt as ONE --text arg, then Enter, to that handle" "$(cat "$ORCA_STUB_LOG")" \
  "<terminal><send><--terminal><term_a><--text><hello there
second line><--enter><--json>"

# --- Orca absent: exit 1, nothing on stdout, nothing sent -------------------------
out=$(HI_ORCA="$SANDBOX/absent" bash "$O" terminals "$SANDBOX/wt1"); rc=$?
assert_status "terminals: absent Orca exits 1" 1 "$rc"; assert_eq "terminals: absent Orca prints nothing" "" "$out"
out=$(HI_ORCA="$SANDBOX/absent" HI_CONFIRMED=1 bash "$O" send term_a "$SANDBOX/prompt.txt" 2>/dev/null); rc=$?
assert_status "send: absent Orca exits 1" 1 "$rc"; assert_eq "send: absent Orca prints nothing" "" "$out"

assert_eq "the sentinel orca-ide never ran" "no" "$([ -e "$SENTINEL_LOG" ] && echo yes || echo no)"
# --- a GitHub Issues key <repo>#<n> matches branches by <n> alone ---
git -C "$SANDBOX/seed" branch feat/16-gh-issues; git -C "$SANDBOX/seed" branch feat/160-other
git -C "$SANDBOX/seed" push -q "$SANDBOX/origin.git" feat/16-gh-issues feat/160-other
assert_eq "candidates: repo#n matches <type>/<n>-<slug>, whole token" "feat/16-gh-issues" \
  "$(bash "$O" candidates --repo "$SANDBOX/repo" --key 'app#16')"

assert_summary
