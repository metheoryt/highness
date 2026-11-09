#!/usr/bin/env bash
# lib/wt.sh review-head / waiting / dispatch --resume.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"

mk_repo; cd "$R"
BASE=$(git rev-parse HEAD)
git switch -q -c side && echo b > b && git add b && git commit -qm head1
git push -q origin HEAD:refs/pull/7/head
H1=$(git rev-parse HEAD)
git switch -q main && git branch -D -q side

# review-head: private ref, no branch, BASE/HEAD
out=$(bash "$WT" review-head --pr 7 --base-ref main 2>/dev/null); rc=$?
assert_status "review-head: exit 0" 0 "$rc"
assert_eq "review-head: BASE<TAB>HEAD" "$BASE	$H1" "$out"
assert_eq "review-head: private ref" "$H1" "$(git rev-parse refs/hi-review/7)"
assert_eq "review-head: no branch created" "" "$(git branch --list '*7*')"
out=$(bash "$WT" review-head --pr 7 --base-ref origin/main 2>/dev/null)
assert_eq "review-head: accepts origin/<base>" "$BASE	$H1" "$out"

# a force-push: the forced refspec moves the stale ref
git switch -q -c side2 "$BASE" && echo c > c && git add c && git commit -qm head2
git push -q -f origin HEAD:refs/pull/7/head; H2=$(git rev-parse HEAD); git switch -q main
out=$(bash "$WT" review-head --pr 7 --base-ref main 2>/dev/null); rc=$?
assert_status "review-head: survives a non-fast-forward" 0 "$rc"
assert_eq "review-head: moved to the new head" "$H2" "$(git rev-parse refs/hi-review/7)"

for v in '' 7a '7;rm' ../7; do
  bash "$WT" review-head --pr "$v" --base-ref main >/dev/null 2>&1
  assert_status "review-head: rejects pr [$v]" 2 "$?"
done
bash "$WT" review-head --pr 7 >/dev/null 2>&1; assert_status "review-head: needs --base-ref" 2 "$?"
bash "$WT" review-head --pr 99 --base-ref main >/dev/null 2>&1; assert_status "review-head: unknown PR exits 1" 1 "$?"

# waiting: only records with status ready
bash "$WT" rec set --review 7 status ready name 'review #7 · AB-101 retry' workspace /x/review-7 session s7 summary '2 blocking, 3 minor'
bash "$WT" rec set --review 8 status running name 'review #8'
bash "$WT" rec set --review 9 status posted name 'review #9'
echo '{}' > "$R/.git/hi/review-7.payload.json"
out=$(bash "$WT" waiting)
assert_eq "waiting: one line, the ready one" "7	review #7 · AB-101 retry	/x/review-7	s7" "$out"

# dispatch --resume: the same session, not a new one
row=$(bash "$WT" create --kind review --key 7 --name 'review #7 · AB-101 retry' --detach "$H2" 2>/dev/null)
P=$(printf '%s\n' "$row" | cut -f1)
printf 'delta round\n' > "$SANDBOX/brief.md"
out=$(HI_PLUGIN_DIR=/opt/hi HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" --resume 99999999-aaaa-bbbb-cccc-dddddddddddd 2>/dev/null); rc=$?
assert_status "resume: exit 0" 0 "$rc"
assert_contains "resume: claude --resume <uuid>" "$(printf '%s\n' "$out" | sed -n 2p)" "\"]}}' --resume 99999999-aaaa-bbbb-cccc-dddddddddddd 'Read "
assert_contains "resume: edits under the plugin root are denied" "$(printf '%s\n' "$out" | sed -n 2p)" "--add-dir /opt/hi --settings '{\"permissions\":{\"deny\":[\"Edit(//opt/hi/**)\""
assert_contains "resume: the brief dir is added" "$(printf '%s\n' "$out" | sed -n 2p)" "claude --add-dir $R/.git/hi/briefs "
assert_not_contains "resume: no new --session-id" "$out" "--session-id"
bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" --resume 'x;rm' >/dev/null 2>&1
assert_status "resume: rejects a malformed id" 2 "$?"
assert_summary
