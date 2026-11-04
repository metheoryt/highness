#!/usr/bin/env bash
# lib/wt.sh — usage, repo detection, records.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"

out=$(bash "$WT" 2>&1); rc=$?
assert_status   "usage: no verb exits 2" 2 "$rc"
assert_contains "usage: names remove-if-safe" "$out" "remove-if-safe"
out=$(bash "$WT" frobnicate 2>&1); rc=$?
assert_status   "usage: unknown verb exits 2" 2 "$rc"

out=$(cd "$SANDBOX" && bash "$WT" list 2>&1); rc=$?
assert_status   "outside a repo: exit 2" 2 "$rc"
assert_contains "outside a repo: says so" "$out" "not inside a git work tree"

mk_repo
cd "$R"
bash "$WT" rec set --review 12 status running workspace /x/review-12; rc=$?
assert_status "rec set review: exit 0" 0 "$rc"
assert_eq "rec get review status" running "$(bash "$WT" rec get --review 12 status)"
assert_eq "review record lives in the store" yes "$([ -f "$R/.git/hi/review-12.md" ] && echo yes || echo no)"
bash "$WT" rec set --review 12 status ready
assert_eq "rec get: the last value wins" ready "$(bash "$WT" rec get --review 12 status)"
bash "$WT" rec set --review 12 workspace ''
out=$(bash "$WT" rec get --review 12 workspace); rc=$?
assert_status "rec get: an emptied field is unset (exit 1)" 1 "$rc"
assert_eq     "rec get: prints nothing when unset" "" "$out"
out=$(bash "$WT" rec get --review 99 status); rc=$?
assert_status "rec get: no record is unset (exit 1)" 1 "$rc"

git -C "$R" worktree add -q "$SANDBOX/lnk" -b lnk
assert_eq "rec get from a linked worktree reads the same store" ready \
  "$(cd "$SANDBOX/lnk" && bash "$WT" rec get --review 12 status)"

bash "$WT" rec set --ticket AB-101 workspace /x/AB-101-thing session abc
J=$(cat "$R/.git/hi/AB-101.md")
assert_eq "ticket record: a plain record file" "# hi ticket AB-101
workspace: /x/AB-101-thing
session: abc" "$J"
assert_eq "rec get ticket" abc "$(bash "$WT" rec get --ticket AB-101 session)"

# --- the older store: <git-common-dir>/us/ is read when hi/ has no record for the id ---------
mkdir -p "$R/.git/us"
printf '# Old journal\n\nSome prose.\n## State\nworkspace: /x/old\nsession: s-old\nname: Old one\n' > "$R/.git/us/AB-200.md"
printf 'status: ready\nname: old review\nworkspace: /x/review-77\n' > "$R/.git/us/review-77.md"
assert_eq "legacy: read from us/ when hi/ has none" s-old "$(bash "$WT" rec get --ticket AB-200 session)"
assert_contains "legacy: waiting lists a us/ review" "$(bash "$WT" waiting)" "77	old review	/x/review-77"
bash "$WT" rec set --ticket AB-200 dispatched send
assert_eq "legacy: the write lands in hi/" yes "$([ -f "$R/.git/hi/AB-200.md" ] && echo yes || echo no)"
assert_eq "legacy: us/ is left as it was" "" "$(grep dispatched "$R/.git/us/AB-200.md")"
assert_eq "legacy: a field the write did not touch is still read" /x/old "$(bash "$WT" rec get --ticket AB-200 workspace)"
assert_eq "legacy: the written field" send "$(bash "$WT" rec get --ticket AB-200 dispatched)"
assert_not_contains "legacy: prose is not copied" "$(cat "$R/.git/hi/AB-200.md")" "Old journal"
printf 'session: s-hi\n' >> "$R/.git/hi/AB-200.md"; printf 'session: s-later\n' >> "$R/.git/us/AB-200.md"
assert_eq "legacy: once hi/ has the record, us/ is not read" s-hi "$(bash "$WT" rec get --ticket AB-200 session)"
rm -rf "$R/.git/us"

bash "$WT" rec set --work refund-spike name 'refund webhook spike'
assert_eq "work record" 'refund webhook spike' "$(bash "$WT" rec get --work refund-spike name)"

for bad in "--review 1x" "--review ''" "--ticket ab" "--work Bad_Slug" "--other 1"; do
  eval "bash \"\$WT\" rec get $bad status" >/dev/null 2>&1; rc=$?
  assert_status "rec: rejects $bad" 2 "$rc"
done
bash "$WT" rec set --review 12 'Bad Field' x >/dev/null 2>&1
assert_status "rec set: rejects a bad field name" 2 "$?"
bash "$WT" rec set --review 12 status "$(printf 'a\nb')" >/dev/null 2>&1
assert_status "rec set: rejects a multi-line value" 2 "$?"
bash "$WT" rec set --review 12 status >/dev/null 2>&1
assert_status "rec set: rejects an odd pair count" 2 "$?"
# --- a GitHub Issues key repo#16 is a valid ticket key; its record file keeps the '#' ---
bash "$WT" rec set --ticket 'app#16' session gh1
assert_eq "rec get ticket app#16" gh1 "$(bash "$WT" rec get --ticket 'app#16' session)"
assert_eq "app#16 record file" yes "$([ -f "$R/.git/hi/app#16.md" ] && echo yes || echo no)"
bash "$WT" rec set --ticket 'app#x' session no 2>/dev/null; assert_status "rec: app#x is not a key" 2 "$?"

assert_summary
