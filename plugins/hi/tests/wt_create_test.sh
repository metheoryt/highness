#!/usr/bin/env bash
# lib/wt.sh create — git backend: ticket / work / review, reuse, setup, records, guards.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }

mk_repo; cd "$R"
D="$SANDBOX/wt/app"

# ticket, new branch
out=$(bash "$WT" create --kind ticket --key AB-101 --name 'AB-101 · Retry lock ordering' \
        --base main --branch task/dev/AB-101-retry-lock 2>"$SANDBOX/err"); rc=$?
assert_status "ticket: exit 0" 0 "$rc"
assert_eq "ticket: folder from key + summary" "$D/AB-101-retry-lock-ordering" "$(col "$out" 1)"
assert_eq "ticket: on the convention branch" task/dev/AB-101-retry-lock "$(col "$out" 3)"
assert_eq "ticket: kind/key" "ticket AB-101" "$(col "$out" 5) $(col "$out" 6)"
assert_eq "ticket: human name" 'AB-101 · Retry lock ordering' "$(col "$out" 7)"
assert_contains "ticket: announce line" "$(cat "$SANDBOX/err")" 'created "AB-101 · Retry lock ordering"'
assert_contains "ticket: setup ran inside the workspace" "$(logged)" "setup $D/AB-101-retry-lock-ordering"
assert_eq "ticket: record workspace" "$D/AB-101-retry-lock-ordering" "$(bash "$WT" rec get --ticket AB-101 workspace)"
assert_eq "ticket: record backend" git "$(bash "$WT" rec get --ticket AB-101 backend)"

# reuse: same branch again → same row, no second setup
reset_log
out2=$(bash "$WT" create --kind ticket --key AB-101 --name 'AB-101 · Retry lock ordering' \
         --base main --branch task/dev/AB-101-retry-lock 2>"$SANDBOX/err"); rc=$?
assert_status "reuse: exit 0" 0 "$rc"
assert_eq "reuse: same workspace" "$(col "$out" 1)" "$(col "$out2" 1)"
assert_contains "reuse: says so" "$(cat "$SANDBOX/err")" "reusing"
assert_not_contains "reuse: no second setup" "$(logged)" "setup "

# adopt an origin branch
git branch task/dev/AB-202-billing main && git push -q origin task/dev/AB-202-billing && git branch -D -q task/dev/AB-202-billing
out=$(bash "$WT" create --kind ticket --key AB-202 --name 'AB-202 · Billing' --base main \
        --adopt task/dev/AB-202-billing 2>/dev/null); rc=$?
assert_status "adopt: exit 0" 0 "$rc"
assert_eq "adopt: on the origin branch" task/dev/AB-202-billing "$(col "$out" 3)"
assert_eq "adopt: tracks origin" origin/task/dev/AB-202-billing \
  "$(git -C "$(col "$out" 1)" rev-parse --abbrev-ref '@{upstream}')"

# a branch that does not carry the key
bash "$WT" create --kind ticket --key AB-101 --name 'AB-101 · x' --base main --branch task/dev/AB-303-x >/dev/null 2>&1
assert_status "ticket: a branch without the key exits 2" 2 "$?"
bash "$WT" create --kind ticket --key AB-101 --name 'AB-101 · x' --base main >/dev/null 2>&1
assert_status "ticket: no --branch/--adopt exits 2" 2 "$?"

# work
out=$(bash "$WT" create --kind work --key refund-spike --name 'refund webhook spike' --base main \
        --branch work/refund-spike 2>/dev/null); rc=$?
assert_status "work: exit 0" 0 "$rc"
assert_eq "work: folder is the slug" "$D/refund-spike" "$(col "$out" 1)"
assert_eq "work: record name" 'refund webhook spike' "$(bash "$WT" rec get --work refund-spike name)"

# review: detached at the sha, no setup unless --tests
SHA=$(git rev-parse HEAD)
reset_log
out=$(bash "$WT" create --kind review --key 7 --name 'review #7 · AB-101 retry' --detach "$SHA" 2>/dev/null); rc=$?
assert_status "review: exit 0" 0 "$rc"
assert_eq "review: folder review-<n>" "$D/review-7" "$(col "$out" 1)"
assert_eq "review: detached (no branch)" "" "$(col "$out" 3)"
assert_eq "review: at the sha" "$SHA" "$(col "$out" 4)"
assert_not_contains "review: no setup by default" "$(logged)" "setup "
reset_log
bash "$WT" create --kind review --key 8 --name 'review #8 · y' --detach "$SHA" --tests >/dev/null 2>&1
assert_contains "review --tests: setup ran" "$(logged)" "setup $D/review-8"
bash "$WT" create --kind review --key 9 --name 'review #9' --detach deadbeef >/dev/null 2>&1
assert_status "review: an unknown sha exits 2" 2 "$?"

# parent
out=$(bash "$WT" create --kind work --key child-check --name 'child check' --base main --branch work/child \
        --parent "$D/AB-101-retry-lock-ordering" 2>/dev/null)
assert_eq "parent: recorded" "$D/AB-101-retry-lock-ordering" "$(col "$out" 8)"
bash "$WT" create --kind work --key orphan --name 'o' --base main --branch work/o --parent "$SANDBOX" >/dev/null 2>&1
assert_status "parent: not a workspace exits 2" 2 "$?"
out=$(bash "$WT" create --kind work --key from-main --name 'fm' --base main --branch work/fm 2>/dev/null)
assert_eq "parent: default from the main checkout is the main checkout" "$(cd "$R" && pwd -P)" "$(col "$out" 8)"
out=$(cd "$D/AB-101-retry-lock-ordering" && bash "$WT" create --kind work --key from-in --name 'fi' --base main --branch work/fi 2>/dev/null)
assert_eq "parent: default from inside a workspace is that workspace" "$D/AB-101-retry-lock-ordering" "$(col "$out" 8)"

# pre-clean: an empty leftover directory is reused, a non-empty one refused and untouched
mkdir -p "$D/left-empty"
bash "$WT" create --kind work --key left-empty --name 'le' --base main --branch work/le >/dev/null 2>&1
assert_status "pre-clean: empty leftover dir → created" 0 "$?"
mkdir -p "$D/left-full" && echo keep > "$D/left-full/mine.txt"
out=$(bash "$WT" create --kind work --key left-full --name 'lf' --base main --branch work/lf 2>&1); rc=$?
assert_status   "pre-clean: non-empty leftover dir exits 1" 1 "$rc"
assert_contains "pre-clean: says why" "$out" "not empty"
assert_eq "pre-clean: the file is untouched" keep "$(cat "$D/left-full/mine.txt")"

# slug: non-ASCII collapses, --slug overrides
out=$(bash "$WT" create --kind ticket --key AB-404 --name 'AB-404 · Ретрай lock!!' --base main \
        --branch task/dev/AB-404-lock 2>/dev/null)
assert_eq "slug: non-ASCII collapses" "$D/AB-404-lock" "$(col "$out" 1)"
out=$(bash "$WT" create --kind ticket --key AB-505 --name 'AB-505 · whatever' --base main \
        --branch task/dev/AB-505-x --slug AB-505-custom 2>/dev/null)
assert_eq "slug: --slug overrides" "$D/AB-505-custom" "$(col "$out" 1)"

# reuse hands back only a workspace that matches the request
bash "$WT" create --kind work --key refund-spike --name 'refund webhook spike' --base main --branch work/other >/dev/null 2>&1
assert_status "reuse: a work workspace on another branch exits 1" 1 "$?"
git -C "$D/refund-spike" commit -q --allow-empty -m w1
SHA2=$(git -C "$D/refund-spike" rev-parse HEAD)
out=$(bash "$WT" create --kind review --key 7 --name 'review #7 · AB-101 retry' --detach "$SHA2" 2>/dev/null); rc=$?
assert_status "reuse review at a new head: exit 0" 0 "$rc"
assert_eq "reuse review at a new head: re-detached there" "$SHA2" "$(col "$out" 4)"
assert_eq "reuse review at a new head: record head" "$SHA2" "$(bash "$WT" rec get --review 7 head)"
echo x > "$D/review-7/scratch.txt"
bash "$WT" create --kind review --key 7 --name 'review #7 · AB-101 retry' --detach "$SHA" >/dev/null 2>&1
assert_status "reuse review, dirty tree, other head: exit 1" 1 "$?"
assert_eq "reuse review, dirty tree: not moved" "$SHA2" "$(git -C "$D/review-7" rev-parse HEAD)"
rm -f "$D/review-7/scratch.txt"

# argument guards
bash "$WT" create --kind ticket --key '' --name x --base main --branch b >/dev/null 2>&1
assert_status "guard: empty key exits 2" 2 "$?"
bash "$WT" create --kind work --key w1 --name "$(printf 'a\tb')" --base main --branch work/w1 >/dev/null 2>&1
assert_status "guard: a TAB in the name exits 2" 2 "$?"
out=$(bash "$WT" create --kind nope --key x --name x 2>&1); rc=$?
assert_status   "guard: unknown kind exits 2" 2 "$rc"
assert_contains "guard: unknown kind is named" "$out" "unknown --kind nope (want ticket, review or work)"
out=$(bash "$WT" create --key x --name x 2>&1); rc=$?
assert_status   "guard: no --kind exits 2" 2 "$rc"
assert_contains "guard: no --kind says it is required" "$out" "--kind is required: ticket, review or work"
# a missing or bad --key prints the accepted format for the kind given
out=$(bash "$WT" create --kind work --name x --base main --branch work/x 2>&1); rc=$?
assert_status   "guard: work without --key exits 2" 2 "$rc"
assert_contains "guard: work without --key prints the work rule" "$out" \
  'work needs --key, format ^[a-z0-9][a-z0-9-]*$ (lowercase letters, digits and dashes; no dots)'
out=$(bash "$WT" create --kind work --key gortex-0.64.11 --name x --base main --branch work/x 2>&1); rc=$?
assert_status   "guard: a dotted work key exits 2" 2 "$rc"
assert_contains "guard: a dotted work key is named with the work rule" "$out" \
  'key gortex-0.64.11 is not a valid work key, want ^[a-z0-9][a-z0-9-]*$'
out=$(bash "$WT" create --kind ticket --key ab --name x --base main --branch b 2>&1)
assert_contains "guard: a bad ticket key prints the ticket rule" "$out" \
  'key ab is not a valid ticket key, want ^[A-Za-z][A-Za-z0-9]*-[0-9]+$'
out=$(bash "$WT" create --kind review --key 7a --name x --detach HEAD 2>&1)
assert_contains "guard: a bad review key prints the review rule" "$out" \
  'key 7a is not a valid review key, want ^[0-9]+$ (a PR number)'
# usage: --help prints it; a bare name (every argument is a flag) and a missing flag say what is wrong
out=$(bash "$WT" create --help 2>&1); rc=$?
assert_status   "create --help: exit 0" 0 "$rc"
assert_contains "create --help: the work form" "$out" "create --kind work   --key SLUG --name N --base REF --branch B"
out=$(bash "$WT" create my-spike 2>&1); rc=$?
assert_status   "create <bare name>: exit 2" 2 "$rc"
assert_contains "create <bare name>: says every argument is a flag" "$out" "unknown flag my-spike (every argument is a flag)"
assert_contains "create <bare name>: prints the usage" "$out" "usage: wt.sh create --kind work"
out=$(bash "$WT" create --kind work --key w2 --name w2 --base main 2>&1); rc=$?
assert_status   "work without --branch: exit 2" 2 "$rc"
assert_contains "work without --branch: names only what is missing" "$out" "(missing: --branch)"
# ticket with a GitHub Issues key: the folder spells app#16 as app-16, the record keeps the '#'
out=$(bash "$WT" create --kind ticket --key 'app#16' --name 'app#16 · GitHub issues' \
        --base main --branch feat/16-gh-issues 2>/dev/null); rc=$?
assert_status "gh ticket: exit 0" 0 "$rc"
assert_eq "gh ticket: no # in the folder" "$D/app-16-github-issues" "$(col "$out" 1)"
assert_eq "gh ticket: record under app#16" "$D/app-16-github-issues" "$(bash "$WT" rec get --ticket 'app#16' workspace)"
# a name already carrying the dashed key: the prefix is written once, either shape
out=$(bash "$WT" create --kind ticket --key 'x#1' --name 'x-1-foo' --base main --branch fix/1-foo 2>/dev/null)
assert_eq "gh ticket: dashed-key name is not doubled" "$D/x-1-foo" "$(col "$out" 1)"
out=$(bash "$WT" create --kind ticket --key 'x#2' --name 'x#2 · bar' --base main --branch fix/2-bar 2>/dev/null)
assert_eq "gh ticket: '<key> · title' name" "$D/x-2-bar" "$(col "$out" 1)"
out=$(bash "$WT" create --kind ticket --key 'x#3' --name 'x#3 baz' --base main --branch fix/3-baz 2>/dev/null)
assert_eq "gh ticket: '<key> title' name" "$D/x-3-baz" "$(col "$out" 1)"
out=$(bash "$WT" create --kind ticket --key AB-606 --name 'AB-606-retry' --base main \
        --branch task/dev/AB-606-retry 2>/dev/null)
assert_eq "slug: uppercase key prefix is not doubled" "$D/AB-606-retry" "$(col "$out" 1)"
out=$(bash "$WT" create --kind ticket --key 'x#4' --name 'x-4' --base main --branch fix/4-x 2>/dev/null)
assert_eq "gh ticket: a name that is only the key" "$D/x-4" "$(col "$out" 1)"
out=$(bash "$WT" create --kind ticket --key 'x#5' --name 'x-50-qux' --base main --branch fix/5-qux 2>/dev/null)
assert_eq "gh ticket: another number is kept" "$D/x-5-x-50-qux" "$(col "$out" 1)"
bash "$WT" create --kind ticket --key 'app#16' --name 'app#16 · x' --base main --branch feat/17-x 2>/dev/null
assert_status "gh ticket: a branch with another number is refused" 2 "$?"
reset_log

# the default setup is the plugin's own worktree-setup.sh, run from inside the new tree
out=$(env -u HI_WT_SETUP bash "$WT" create --kind work --key dflt --name 'default setup' --base main --branch work/dflt 2>&1 >/dev/null)
assert_contains "default setup: lib/worktree-setup.sh" "$out" "setup: $(cd "$HERE/../lib" && pwd)/worktree-setup.sh"
assert_contains "default setup: it ran there" "$out" "[worktree-setup]"

assert_summary
