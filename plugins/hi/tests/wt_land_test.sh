#!/usr/bin/env bash
# lib/wt.sh land — merge the trunk in, test, check the trunk did not move, fast-forward, push.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"

mk_repo
printf 'base\n' > "$R/a.txt"; git -C "$R" add a.txt; git -C "$R" commit -q -m a; git -C "$R" push -q origin main
cd "$R"

# OTHER: another agent's clone; `other_push <file>` lands a commit on origin/main from it.
OTHER="$SANDBOX/other"; git clone -q -b main "$UP" "$OTHER"
other_push() { (cd "$OTHER" && git pull -q --no-rebase origin main && printf '%s\n' "$1" > "$1" &&
  git add "$1" && git commit -q -m "other $1" && git push -q origin main); }
mk() { bash "$WT" create --kind ticket --key "$1" --name "$1 · land" --base origin/main --branch "task/$1" 2>/dev/null | cut -f1; }
work() { (cd "$1" && printf '%s\n' "$2" > "$2" && git add "$2" && git commit -q -m "work $2"); }
origin_main() { git -C "$UP" rev-parse main; }
# A test command that counts its runs in $SANDBOX/runs.
RUNS="$SANDBOX/runs"
TEST_OK="echo run >> '$RUNS'"
runs() { [ -f "$RUNS" ] && wc -l < "$RUNS" | tr -d ' ' || echo 0; }

# --- main moved during the suite: land merges it in, tests again, then lands ----------------
P=$(mk AB-1); work "$P" w1; : > "$RUNS"
# The first run of the suite pushes another agent's commit, as if it landed meanwhile.
MOVE="echo run >> '$RUNS'; [ \$(wc -l < '$RUNS') -gt 1 ] || ( cd '$OTHER' && git pull -q --no-rebase origin main && echo m > moved && git add moved && git commit -q -m moved && git push -q origin main )"
out=$(bash "$WT" land "$P" --test "$MOVE" 2>"$SANDBOX/err"); rc=$?
err=$(cat "$SANDBOX/err")
assert_status   "moved: exit 0" 0 "$rc"
assert_eq       "moved: the suite ran again after the merge" 2 "$(runs)"
assert_contains "moved: says the trunk moved" "$err" "moved during the tests"
assert_not_contains "moved: caught before the main checkout moved (no refused push)" "$err" "was refused"
head=$(git -C "$P" rev-parse HEAD)
assert_eq       "moved: prints path, branch, sha" "$(printf '%s\ttask/AB-1\t%s' "$P" "$head")" "$out"
assert_eq       "moved: origin/main is the branch head" "$head" "$(origin_main)"
assert_eq       "moved: the main checkout is fast-forwarded" "$head" "$(git -C "$R" rev-parse HEAD)"
assert_eq       "moved: the other agent's commit is kept" yes \
  "$(git -C "$R" cat-file -e HEAD:moved 2>/dev/null && echo yes || echo no)"
assert_eq       "moved: the work is on main" yes "$(git -C "$R" cat-file -e HEAD:w1 2>/dev/null && echo yes || echo no)"

# --- main checkout dirty: refused before anything runs ------------------------------------------
P=$(mk AB-2); work "$P" w2; : > "$RUNS"; before=$(origin_main)
printf 'local edit\n' >> "$R/a.txt"
out=$(bash "$WT" land "$P" --test "$TEST_OK" 2>&1); rc=$?
assert_status   "dirty main: refused (exit 3)" 3 "$rc"
assert_contains "dirty main: says why" "$out" "uncommitted changes"
assert_eq       "dirty main: the suite did not run" 0 "$(runs)"
assert_eq       "dirty main: nothing pushed" "$before" "$(origin_main)"
assert_eq       "dirty main: the edit is untouched" 'local edit' "$(tail -1 "$R/a.txt")"
git -C "$R" checkout -q -- a.txt

# --- the main checkout gets dirty during the suite: refused before the fast-forward ----------
: > "$RUNS"
out=$(bash "$WT" land "$P" --test "echo run >> '$RUNS'; echo x >> '$R/a.txt'" 2>&1); rc=$?
assert_status   "dirtied during the suite: exit 3" 3 "$rc"
assert_eq       "dirtied during the suite: nothing pushed" "$before" "$(origin_main)"
git -C "$R" checkout -q -- a.txt

# --- the main checkout is not on the trunk ---------------------------------------------------
git -C "$R" checkout -q -b side
out=$(bash "$WT" land "$P" --test "$TEST_OK" 2>&1); rc=$?
assert_status   "main off trunk: exit 3" 3 "$rc"
assert_contains "main off trunk: says so" "$out" "is not on main"
git -C "$R" checkout -q main

# --- no test command: refused; land.test from the repo's config is used ----------------------
out=$(bash "$WT" land "$P" 2>&1); rc=$?
assert_status   "no test command: exit 3" 3 "$rc"
assert_contains "no test command: names the key" "$out" "land.test"
mkdir -p "$P/.claude"; printf '{"land":{"test":"echo cfg >> %s"}}\n' "$RUNS" > "$P/.claude/highness.json"
(cd "$P" && git add .claude/highness.json && git commit -q -m cfg)
: > "$RUNS"
out=$(bash "$WT" land "$P" 2>/dev/null); rc=$?
assert_status   "config land.test: exit 0" 0 "$rc"
assert_eq       "config land.test: it ran" cfg "$(cat "$RUNS")"
assert_eq       "config land.test: landed" "$(git -C "$P" rev-parse HEAD)" "$(origin_main)"

# --- from inside the workspace, no path -------------------------------------------------------
P=$(mk AB-3); work "$P" w3
out=$(cd "$P" && bash "$WT" land --test true 2>/dev/null); rc=$?
assert_status   "no path, from inside: exit 0" 0 "$rc"
assert_eq       "no path, from inside: landed" "$(git -C "$P" rev-parse HEAD)" "$(origin_main)"

# --- failing tests: nothing lands --------------------------------------------------------------
P=$(mk AB-4); work "$P" w4; before=$(origin_main)
out=$(bash "$WT" land "$P" --test false 2>&1); rc=$?
assert_status   "tests fail: exit 1" 1 "$rc"
assert_eq       "tests fail: nothing pushed" "$before" "$(origin_main)"
assert_eq       "tests fail: main checkout untouched" "$before" "$(git -C "$R" rev-parse HEAD)"

# --- a conflict: the merge is aborted -------------------------------------------------------------
P=$(mk AB-5); (cd "$P" && echo mine > a.txt && git commit -q -am mine)
(cd "$OTHER" && git pull -q --no-rebase origin main && echo theirs > a.txt && git commit -q -am theirs && git push -q origin main)
before=$(origin_main)
out=$(bash "$WT" land "$P" --test true 2>&1); rc=$?
assert_status   "conflict: exit 1" 1 "$rc"
assert_contains "conflict: says so" "$out" "conflicts"
assert_eq       "conflict: the merge is aborted" "" "$(git -C "$P" status --porcelain)"
assert_eq       "conflict: nothing pushed" "$before" "$(origin_main)"

# --- the trunk never stops moving: gives up after HI_WT_LAND_TRIES ---------------------------
P=$(mk AB-6); work "$P" w6; : > "$RUNS"
ALWAYS="n=\$(date +%s)\$\$; echo run >> '$RUNS'; ( cd '$OTHER' && git pull -q --no-rebase origin main && echo \$n > \$n && git add \$n && git commit -q -m \$n && git push -q origin main )"
before_ff=$(git -C "$R" rev-parse HEAD)
out=$(HI_WT_LAND_TRIES=2 bash "$WT" land "$P" --test "$ALWAYS" 2>&1); rc=$?
assert_status   "always moving: exit 1" 1 "$rc"
assert_contains "always moving: gives up" "$out" "gave up after 2 tries"
assert_eq       "always moving: the suite ran twice" 2 "$(runs)"
assert_eq       "always moving: main checkout not moved" "$before_ff" "$(git -C "$R" rev-parse HEAD)"

# --- a review workspace and the main checkout are refused ------------------------------------
SHA=$(git -C "$R" rev-parse HEAD)
RV=$(bash "$WT" create --kind review --key 7 --name 'review #7 · x' --detach "$SHA" 2>/dev/null | cut -f1)
out=$(bash "$WT" land "$RV" --test true 2>&1); rc=$?
assert_status   "review workspace: exit 3" 3 "$rc"
assert_contains "review workspace: says why" "$out" "review workspace"
out=$(bash "$WT" land "$R" --test true 2>&1); rc=$?
assert_status   "main checkout as the target: exit 3" 3 "$rc"

assert_summary
