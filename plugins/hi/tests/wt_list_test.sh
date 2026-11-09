#!/usr/bin/env bash
# lib/wt.sh list / find — rows from git, kinds from records or inferred, Orca ids when listed.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }

mk_repo; cd "$R"
D="$SANDBOX/wt/app"; mkdir -p "$D"
git worktree add -q -b task/dev/ab-101-thing "$D/AB-101-thing" main
git worktree add -q --detach "$D/review-7" main
git worktree add -q -b scratch "$D/scratch" main
git worktree add -q -b feat/AB-202-x "$D/AB-202-x" main
git worktree add -q -b gone "$D/gone" main && rm -rf "$D/gone"
bash "$WT" rec set --ticket AB-202 workspace "$D/AB-202-x" name 'AB-202 · x thing' \
  parent "$D/AB-101-thing" session s-202

out=$(bash "$WT" list); rc=$?
assert_status "list: exit 0" 0 "$rc"
assert_eq "list: four rows (main and a vanished dir excluded)" 4 "$(printf '%s\n' "$out" | grep -c .)"
assert_eq "list: main checkout excluded" 0 "$(printf '%s\n' "$out" | cut -f1 | grep -cx "$R")"
t=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /AB-101-thing$/')
assert_eq "inferred ticket: kind" ticket "$(col "$t" 5)"
assert_eq "inferred ticket: key from a lowercase branch" AB-101 "$(col "$t" 6)"
assert_eq "inferred ticket: name falls back to the folder" AB-101-thing "$(col "$t" 7)"
assert_eq "inferred ticket: branch" task/dev/ab-101-thing "$(col "$t" 3)"
assert_eq "inferred ticket: head is a full sha" 40 "$(col "$t" 4 | tr -d '\n' | wc -c | tr -d ' ')"
assert_eq "git backend: sel empty" "" "$(col "$t" 2)"
assert_eq "git backend: backend git" git "$(col "$t" 10)"
v=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /review-7$/')
assert_eq "inferred review: kind/key" "review 7" "$(col "$v" 5) $(col "$v" 6)"
assert_eq "inferred review: detached, empty branch" "" "$(col "$v" 3)"
s=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /scratch$/')
assert_eq "inferred work: kind/key" "work scratch" "$(col "$s" 5) $(col "$s" 6)"
x=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /AB-202-x$/')
assert_eq "record: name" 'AB-202 · x thing' "$(col "$x" 7)"
assert_eq "record: parent" "$D/AB-101-thing" "$(col "$x" 8)"
assert_eq "record: session" s-202 "$(col "$x" 9)"
assert_eq "row has exactly 10 columns" 10 "$(printf '%s' "$x" | awk -F'\t' '{print NF}')"

# find
assert_eq "find --branch" "$D/AB-202-x" "$(col "$(bash "$WT" find --branch feat/AB-202-x)" 1)"
assert_eq "find --branch accepts refs/heads/" "$D/AB-202-x" "$(col "$(bash "$WT" find --branch refs/heads/feat/AB-202-x)" 1)"
assert_eq "find --ticket" "$D/AB-101-thing" "$(col "$(bash "$WT" find --ticket AB-101)" 1)"
assert_eq "find --review" "$D/review-7" "$(col "$(bash "$WT" find --review 7)" 1)"
assert_eq "find --work" "$D/scratch" "$(col "$(bash "$WT" find --work scratch)" 1)"
assert_eq "find --path" "$D/scratch" "$(col "$(bash "$WT" find --path "$D/scratch")" 1)"
assert_eq "find --path from a subdirectory path is not a match" "" "$(mkdir -p "$D/scratch/sub"; bash "$WT" find --path "$D/scratch/sub" 2>/dev/null)"
out=$(bash "$WT" find --ticket AB-999); rc=$?
assert_status "find: no match exits 1" 1 "$rc"
assert_eq     "find: no match prints nothing" "" "$out"
out=$(bash "$WT" find --path "$R"); rc=$?
assert_status "find --path main: never a workspace" 1 "$rc"
bash "$WT" find --branch '' >/dev/null 2>&1; assert_status "find: empty value exits 2" 2 "$?"
bash "$WT" find --nope x >/dev/null 2>&1;    assert_status "find: unknown flag exits 2" 2 "$?"
assert_eq "find from a linked worktree sees the same rows" "$D/review-7" \
  "$(cd "$D/scratch" && bash "$WT" find --review 7 | cut -f1)"

# A GitHub-issue ticket rides its branch as <n>-<slug> (create's rule, highness#12): inferred as
# ticket <repo>#<n>, <repo> from origin's name, or the key a record of this repo already holds.
git worktree add -q -b feat/3-slug "$D/gh-3" main
git worktree add -q -b fix/4_other "$D/gh-4" main
bash "$WT" rec set --ticket 'app#4' name 'app#4 · other'
out=$(bash "$WT" list)
g=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /gh-3$/')
assert_eq "inferred #-ticket: kind/key from origin's name" "ticket up#3" "$(col "$g" 5) $(col "$g" 6)"
g=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /gh-4$/')
assert_eq "inferred #-ticket: the key a record holds" "ticket app#4" "$(col "$g" 5) $(col "$g" 6)"
assert_eq "inferred #-ticket: its record's name" 'app#4 · other' "$(col "$g" 7)"
assert_eq "find --ticket <repo>#<n>" "$D/gh-3" "$(col "$(bash "$WT" find --ticket 'up#3')" 1)"

# Orca: listed paths get the Orca id verbatim and backend orca; unlisted stay git.
orca_on
export FX_ORCA_ONLY="$D/review-7"
out=$(bash "$WT" list)
v=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /review-7$/')
assert_eq "orca: the path stays POSIX" "$D/review-7" "$(col "$v" 1)"
assert_contains "orca: sel is Orca's id (UNC, verbatim)" "$(col "$v" 2)" 'R::\\wsl.localhost\d'
assert_eq "orca: backend orca" orca "$(col "$v" 10)"
s=$(printf '%s\n' "$out" | awk -F'\t' '$1 ~ /scratch$/')
assert_eq "orca: a path Orca does not list stays git" "git" "$(col "$s" 10)"
unset FX_ORCA_ONLY
assert_summary
