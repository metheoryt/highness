#!/usr/bin/env bash
# lib/review.sh: the PR head under a private ref, which anchors GitHub takes, the payload shapes
# (a bare approve is the event alone; COMMENT and REQUEST_CHANGES need a body), and the reads of
# threads and the pending review. No network: a local bare origin, and a stub gh (HI_REVIEW_GH).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/../lib/review.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_CONFIG="$T/user.json" GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$HOME"
echo '{}' >"$HIGHNESS_CONFIG"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1: [$3] is there" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }
g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# --- a repo with a PR: main has a.txt (10 lines) and old.txt; the PR edits line 5 of a.txt,
# appends 2 lines, and renames old.txt to new.txt with one line changed.
g init -q --bare "$T/up.git"
g init -q "$T/src"
# Also: a name with a space, a non-ASCII name, and a file whose added line reads `++ i;` (in the
# diff `+++ i;`, which must not read as a file header) with a later hunk.
( cd "$T/src" || exit 1
  seq 1 10 >a.txt; seq 101 120 >old.txt; seq 1 10 >'sp ace.txt'; seq 1 10 >"caf$(printf '\303\251').txt"
  seq 1 40 >c.txt
  g add . && g commit -qm base && g push -q "$T/up.git" HEAD:main
  g checkout -qb feature
  { seq 1 4; echo five; seq 6 10; echo eleven; echo twelve; } >a.txt
  g mv old.txt new.txt; { seq 101 109; echo changed; seq 111 120; } >new.txt
  { seq 1 4; echo five; seq 6 10; } >'sp ace.txt'; { seq 1 4; echo five; seq 6 10; } >"caf$(printf '\303\251').txt"
  { seq 1 2; echo '++ i;'; seq 4 29; echo thirty; seq 31 40; } >c.txt
  g add . && g commit -qm feature && g push -q "$T/up.git" HEAD:refs/pull/7/head )
g clone -q -b main "$T/up.git" "$T/clone"
cd "$T/clone" || exit 1

out=$(bash "$R" head --pr 7 --base-ref main); rc=$?
check 'head: exit 0' "$rc" 0
BASE=$(printf '%s' "$out" | cut -f1); HEAD=$(printf '%s' "$out" | cut -f2)
check 'head: BASE is the merge-base with origin/main' "$BASE" "$(git rev-parse origin/main)"
check 'head: HEAD is the PR head, under refs/hi-review/7' "$HEAD" "$(git rev-parse refs/hi-review/7)"
check 'head: no branch is created' "$(git branch --list | wc -l | tr -d ' ')" 1
bash "$R" head --pr 7x --base-ref main 2>/dev/null; check 'head: a PR that is not a number is usage' "$?" 2
bash "$R" head --pr 8 --base-ref main 2>/dev/null; check 'head: a PR the origin does not have fails' "$?" 3

# A fork checkout: origin is the fork (no pull/7), upstream is the PR's repo.
g init -q --bare "$T/fork.git"
g clone -q -b main "$T/up.git" "$T/fork"
( cd "$T/fork" && git remote rename origin upstream && git remote set-url upstream "https://example.invalid/Up-Owner/up.git" &&
  git config "url.$T/up.git.insteadOf" "https://example.invalid/Up-Owner/up.git" &&
  git remote add origin "$T/fork.git" && git push -q origin main )
out=$(cd "$T/fork" && bash "$R" head --pr 7 --base-ref main --repo up-owner/up); rc=$?
check 'head --repo: the remote naming the repo is used, case-insensitively' "$rc/$(printf '%s' "$out" | cut -f2)" "0/$(git rev-parse refs/hi-review/7)"
(cd "$T/fork" && bash "$R" head --pr 7 --base-ref main 2>/dev/null); check 'head: without --repo a fork origin has no pull/7' "$?" 3

an() { bash "$R" anchor "$BASE" "$HEAD" "$@" 2>/dev/null; echo $?; }
check 'anchor: the changed line, head side' "$(an a.txt 5)" 0
check 'anchor: an added line' "$(an a.txt 12)" 0
check 'anchor: a context line in the hunk' "$(an a.txt 2)" 0
check 'anchor: the removed line on the base side' "$(an a.txt 5 LEFT)" 0
check 'anchor: base side has no line 12' "$(an a.txt 12 LEFT)" 1
check 'anchor: a span inside one hunk' "$(an a.txt 4-6)" 0
check 'anchor: a file the PR does not touch' "$(an b.txt 1)" 1
check 'anchor: the renamed file, head side' "$(an new.txt 10)" 0
check 'anchor: the renamed file keeps its own diff (not the old name)' "$(an old.txt 10)" 1
check 'anchor: a line far from any hunk' "$(an new.txt 1)" 1
check 'anchor: a span out of the hunk' "$(an new.txt 1-10)" 1
check 'anchor: a bad side is usage' "$(an a.txt 5 BOTH)" 2
check 'anchor: a backwards span is usage' "$(an a.txt 6-4)" 2
check 'anchor: a half-open span is usage' "$(an a.txt 5-)/$(an a.txt -5)" 2/2
check 'anchor: a name with a space' "$(an 'sp ace.txt' 5)" 0
check 'anchor: a non-ASCII name' "$(an "caf$(printf '\303\251').txt" 5)" 0
check 'anchor: an added "++ i;" line is content, not a header' "$(an c.txt 3)" 0
check 'anchor: and the hunk after it still counts' "$(an c.txt 30)" 0
check 'anchor: an unresolvable range is a failure, not a no' "$(bash "$R" anchor deadbeef "$HEAD" a.txt 5 2>/dev/null; echo $?)" 3

# --- payload
pl() { bash "$R" payload "$@" 2>"$T/err"; echo "rc=$?"; }
printf '' >"$T/empty"; printf '\n\n2 things, the rest is good.\n\n' >"$T/body"
echo '[{"path":"a.txt","line":5,"body":"Why five?"},{"path":"a.txt","line":6,"start_line":4,"side":"LEFT","body":"span"}]' >"$T/c.json"
check 'payload: a bare approve is the event alone' "$(pl --event APPROVE)" '{"event":"APPROVE"}
rc=0'
check 'payload: an empty body file is still a bare approve' "$(pl --event APPROVE --body-file "$T/empty")" '{"event":"APPROVE"}
rc=0'
out=$(pl --event REQUEST_CHANGES --body-file "$T/body" --comments-file "$T/c.json")
has 'payload: the body, trimmed of blank lines' "$out" '"body":"2 things, the rest is good."'
has 'payload: side defaults to RIGHT' "$out" '{"path":"a.txt","line":5,"side":"RIGHT","body":"Why five?"}'
has 'payload: a span keeps start_line, start_side follows side' "$out" '"start_line":4,"start_side":"LEFT"'
has 'payload: exit 0' "$out" 'rc=0'
check 'payload: COMMENT without a body is refused' "$(pl --event COMMENT --comments-file "$T/c.json" | tail -1)" 'rc=2'
check 'payload: an unknown event is refused' "$(pl --event PENDING | tail -1)" 'rc=2'
echo '[{"path":"a.txt","body":"no line"}]' >"$T/bad.json"
check 'payload: a comment without a line is refused' "$(pl --event APPROVE --comments-file "$T/bad.json" | tail -1)" 'rc=2'
has 'payload: and says which comment' "$(cat "$T/err")" 'comment 0: no line'
echo '[{"path":"a.txt","line":4,"start_line":4,"body":"x"}]' >"$T/bad.json"
check 'payload: a span that does not run forward is refused' "$(pl --event APPROVE --comments-file "$T/bad.json" | tail -1)" 'rc=2'
echo '[{"path":"a.txt","line":4,"side":"BOTH","body":"x"}]' >"$T/bad.json"
check 'payload: a bad side is refused' "$(pl --event APPROVE --comments-file "$T/bad.json" | tail -1)" 'rc=2'
echo '[{"path":"a.txt","line":6,"start_line":4,"start_side":"right","body":"x"}]' >"$T/bad.json"
check 'payload: a bad start_side is refused' "$(pl --event APPROVE --comments-file "$T/bad.json" | tail -1)" 'rc=2'
for l in 0 4.5 '"4"'; do
  echo "[{\"path\":\"a.txt\",\"line\":$l,\"body\":\"x\"}]" >"$T/bad.json"
  check "payload: line $l is refused" "$(pl --event APPROVE --comments-file "$T/bad.json" | tail -1)" 'rc=2'
done

# --- a stub gh: logs every call, answers from files named by the call.
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
  *graphql*) cat "$STUB_DIR/threads.json" ;;
  *'reviews/55/comments'*) cat "$STUB_DIR/pending-comments.json" ;;
  'api --paginate repos/o/r/pulls/7/reviews') cat "$STUB_DIR/reviews.json" ;;
  *'--input -'*) cat >"$STUB_DIR/stdin.json"; echo '{"id":10,"state":"PENDING"}' ;;
  'api -X POST repos/o/r/pulls/7/reviews'*) [ -f "$STUB_DIR/post-fails" ] && exit 1; echo '{"id":9,"state":"APPROVED","html_url":"u"}' ;;
  'api -X DELETE'*) ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export HI_REVIEW_GH="$T/bin/gh" STUB_LOG="$T/gh.log" STUB_DIR="$T"
: >"$STUB_LOG"

cat >"$T/threads.json" <<'EOF'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
 {"isResolved":true,"isOutdated":false,"path":"a.txt","line":null,"originalLine":5,
  "comments":{"nodes":[{"author":{"login":"lint-helper"},"body":"b1","createdAt":"t","url":"u1"},
                       {"author":{"login":"alice"},"body":"b2","createdAt":"t","url":"u2"}]}},
 {"isResolved":false,"isOutdated":false,"path":"new.txt","line":10,
  "comments":{"totalCount":60,"nodes":[{"author":{"login":"some-ci[bot]"},"body":"b3","createdAt":"t","url":"u3"}]}}],
 "pageInfo":{"hasNextPage":true}}}}}}
EOF
echo '{"review":{"bots":["lint-helper"]}}' >"$HIGHNESS_CONFIG"
out=$(bash "$R" threads o/r 7 2>"$T/err")
check 'threads: one line per thread' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 2
has 'threads: a cut list of threads is said' "$(cat "$T/err")" 'only the first 100 were read'
has 'threads: a thread with cut replies is truncated' "$out" '"path":"new.txt","line":10,"resolved":false,"outdated":false,"truncated":true'
has 'threads: a whole thread is not' "$out" '"truncated":false'
has 'threads: line falls back to originalLine' "$out" '"path":"a.txt","line":5,"resolved":true'
has 'threads: a configured bot is a bot' "$out" '{"author":"lint-helper","bot":true'
has 'threads: a person is not' "$out" '{"author":"alice","bot":false'
has 'threads: a [bot] login is a bot without config' "$out" '{"author":"some-ci[bot]","bot":true'
echo '{}' >"$HIGHNESS_CONFIG"
has 'threads: without config only [bot] logins are bots' "$(bash "$R" threads o/r 7 2>/dev/null)" '{"author":"lint-helper","bot":false'

echo '[{"id":54,"state":"COMMENTED","user":{"login":"Me"}}][{"id":55,"state":"PENDING","user":{"login":"Me"},"body":"draft"},{"id":56,"state":"PENDING","user":{"login":"other"}}]' >"$T/reviews.json"
echo '[{"path":"a.txt","line":5,"side":"RIGHT","start_line":null,"start_side":null,"body":"mine","id":1}]' >"$T/pending-comments.json"
out=$(bash "$R" pending o/r 7 me); rc=$?
check 'pending: found across pages, login compared case-insensitively' "$rc" 0
check 'pending: id, body and the comments' "$(printf '%s' "$out" | jq -c '[.id, .body, .comments[0].body, (.comments[0] | has("id"))]')" '[55,"draft","mine",false]'
echo '[{"id":54,"state":"COMMENTED","user":{"login":"me"}}]' >"$T/reviews.json"
bash "$R" pending o/r 7 me >/dev/null; check 'pending: none is exit 1' "$?" 1

bash "$R" payload --event APPROVE >"$T/p.json"
check 'post: prints the state' "$(bash "$R" post o/r 7 "$T/p.json")" '{"id":9,"state":"APPROVED","html_url":"u"}'
has 'post: one POST with the payload as input' "$(tail -1 "$STUB_LOG")" "api -X POST repos/o/r/pulls/7/reviews --input $T/p.json"
echo '{"body":"x"}' >"$T/noevent.json"
bash "$R" post o/r 7 "$T/noevent.json" 2>/dev/null; check 'post: a payload without an event is refused' "$?" 2
check 'post: and never reaches gh' "$(grep -c noevent "$STUB_LOG")" 0
touch "$T/post-fails"
bash "$R" post o/r 7 "$T/p.json" 2>"$T/err"; check 'post: a failed POST is exit 3' "$?" 3
has 'post: and says the payload is kept' "$(cat "$T/err")" "still in $T/p.json"
bash "$R" delete-pending o/r 7 55; check 'delete-pending: exit 0' "$?" 0
has 'delete-pending: a DELETE of that review' "$(tail -1 "$STUB_LOG")" 'api -X DELETE repos/o/r/pulls/7/reviews/55'

# restore-pending: the same POST without an event; an outdated comment goes back into the body.
echo '{"id":55,"body":"draft","comments":[{"path":"a.txt","line":5,"side":"RIGHT","start_line":null,"start_side":null,"body":"mine"},{"path":"b.txt","line":null,"side":"RIGHT","start_line":null,"start_side":null,"body":"gone"}]}' >"$T/pend.json"
rm -f "$T/post-fails"
bash "$R" restore-pending o/r 7 "$T/pend.json" >/dev/null; check 'restore-pending: exit 0' "$?" 0
check 'restore-pending: no event, the outdated comment in the body, nulls dropped' "$(jq -c . "$T/stdin.json")" \
  '{"body":"draft\n\nb.txt: gone","comments":[{"path":"a.txt","line":5,"side":"RIGHT","body":"mine"}]}'

# --- deep mode: slices. Every changed file once, by its new path, with its changed lines; a slice
# closes before a file would take it past the limits, and a file is never split.
out=$(bash "$R" slices "$BASE" "$HEAD"); rc=$?
check 'slices: exit 0' "$rc" 0
check 'slices: one row per changed file' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" \
  "$(git diff --name-only -M "$BASE" "$HEAD" | wc -l | tr -d ' ')"
check 'slices: a small diff is one slice' "$(printf '%s\n' "$out" | cut -f1 | sort -u | tr '\n' ' ')" '1 '
has 'slices: a rename by its new path, with its lines' "$out" "$(printf '1\t2\tnew.txt')"
hasnt 'slices: never the old name' "$out" 'old.txt'
has 'slices: a name with a space' "$out" "$(printf '\tsp ace.txt')"
has 'slices: a non-ASCII name as is' "$out" "$(printf '\tcaf\303\251.txt')"
has 'slices: added plus deleted lines' "$out" "$(printf '\t4\ta.txt')"
out=$(bash "$R" slices "$BASE" "$HEAD" --max-files 1)
check 'slices: --max-files 1 is one file per slice' "$(printf '%s\n' "$out" | cut -f1 | sort -u | wc -l | tr -d ' ')" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
out=$(bash "$R" slices "$BASE" "$HEAD" --max-lines 5)
check 'slices: no slice over the line limit but a lone file' \
  "$(printf '%s\n' "$out" | awk -F'\t' '{ s[$1] += $2; c[$1]++ } END { for (k in s) if (s[k] > 5 && c[k] > 1) bad++; print bad + 0 }')" 0
check 'slices: in order, numbered from 1 without gaps' \
  "$(printf '%s\n' "$out" | awk -F'\t' 'NR == 1 && $1 != 1 { bad++ } NR > 1 && $1 != p && $1 != p + 1 { bad++ } { p = $1 } END { print bad + 0 }')" 0
printf 'x\0y' >"$T/bin.dat"; ( cd "$T/src" && cp "$T/bin.dat" bin.dat && g add bin.dat && g commit -qm bin && g push -q "$T/up.git" HEAD:refs/pull/9/head )
bash "$R" head --pr 9 --base-ref main >/dev/null
has 'slices: a binary file counts 0 lines' "$(bash "$R" slices "$BASE" refs/hi-review/9)" "$(printf '\t0\tbin.dat')"
bash "$R" slices "$BASE" "$HEAD" --max-lines 0 2>/dev/null; check 'slices: a zero limit is usage' "$?" 2
bash "$R" slices "$BASE" 2>/dev/null; check 'slices: no head is usage' "$?" 2
bash "$R" slices deadbeef "$HEAD" 2>/dev/null; check 'slices: an unresolvable range fails' "$?" 3

# --- key and task.
check 'key: lowercase, one dash per slash' "$(bash "$R" key Own.er/Re_po 42)" 'review-own.er-re_po-42'
check 'key: other bytes become dashes' "$(bash "$R" key 'o/r p' 1)" 'review-o-r-p-1'
bash "$R" key o/r 4x 2>/dev/null; check 'key: a PR that is not a number is usage' "$?" 2
out=$(bash "$R" task --pr-url https://github.com/o/r/pull/7 --key review-o-r-7 --base "$BASE" --head "$HEAD" --workspace /ws/rv-7); rc=$?
check 'task: exit 0' "$rc" 0
has 'task: the PR' "$out" 'https://github.com/o/r/pull/7 (o/r#7)'
has 'task: the plugin by absolute path' "$out" "PLUGIN=$(cd "$HERE/.." && pwd -P)"
has 'task: the shas' "$out" "BASE_SHA=$BASE"
has 'task: the workspace' "$out" '`/ws/rv-7`'
has 'task: no voice' "$out" 'VOICE=none'
has 'task: subagents asked for' "$out" 'subagent_type: "hi-review:reviewer"'
has 'task: the post is the person action' "$out" 'never by you'
hasnt 'task: every placeholder filled' "$out" '{{'
has 'task: a voice file' "$(bash "$R" task --pr-url https://github.com/o/r/pull/7 --key k --base b --head h --workspace w --voice /v.md)" 'VOICE=/v.md'
bash "$R" task --pr-url https://example.com/x --key k --base b --head h --workspace w 2>/dev/null
check 'task: not a github PR url is usage' "$?" 2

# --- submit: posts only what the cards showed. The stub answers the PR head from $T/headsha.
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
  'api repos/o/r/pulls/7 --jq .head.sha') cat "$STUB_DIR/headsha" ;;
  *'reviews/55/comments'*) cat "$STUB_DIR/pending-comments.json" ;;
  'api --paginate repos/o/r/pulls/7/reviews') cat "$STUB_DIR/reviews.json" ;;
  *'--input -'*) cat >"$STUB_DIR/stdin.json"; echo '{"id":10,"state":"PENDING"}' ;;
  'api -X POST repos/o/r/pulls/7/reviews'*) [ -f "$STUB_DIR/post-fails" ] && exit 1; echo '{"id":9,"state":"APPROVED","html_url":"u"}' ;;
  'api -X DELETE'*) ;;
  *) exit 1 ;;
esac
EOF
echo abc >"$T/headsha"
echo '[]' >"$T/reviews.json"
sb() { bash "$R" submit o/r 7 "$T/p.json" --login me "$@" 2>"$T/err"; echo "rc=$?"; }
: >"$STUB_LOG"
check 'submit: the head moved is exit 4' "$(sb --head def)" 'rc=4'
has 'submit: and says so' "$(cat "$T/err")" 'moved to abc'
check 'submit: and posts nothing' "$(grep -c 'X POST' "$STUB_LOG")" 0
check 'submit: no pending review, none seen: posts' "$(sb --head abc)" '{"id":9,"state":"APPROVED","html_url":"u"}
rc=0'
echo '[{"id":55,"state":"PENDING","user":{"login":"me"},"body":"draft"}]' >"$T/reviews.json"
: >"$STUB_LOG"
check 'submit: a pending review the cards did not show is exit 4' "$(sb --head abc)" 'rc=4'
check 'submit: and nothing is deleted or posted' "$(grep -c -e 'X POST' -e 'X DELETE' "$STUB_LOG")" 0
bash "$R" pending o/r 7 me >"$T/seen.json"
: >"$STUB_LOG"
check 'submit: the pending review the cards showed: posts' "$(sb --head abc --seen-pending "$T/seen.json" | tail -1)" 'rc=0'
check 'submit: it was deleted first, then the post' "$(grep -e 'X DELETE' -e 'X POST' "$STUB_LOG" | cut -d' ' -f2 | tr '\n' ' ')" '-X -X '
has 'submit: the delete is of that review' "$(grep 'X DELETE' "$STUB_LOG")" 'reviews/55'
check 'submit: the pending review kept beside the payload' "$(jq -c .id "$T/p.json.pending.json")" 55
echo '[{"path":"a.txt","line":5,"side":"RIGHT","start_line":null,"start_side":null,"body":"edited","id":1}]' >"$T/pending-comments.json"
check 'submit: a pending review changed since the cards is exit 4' "$(sb --head abc --seen-pending "$T/seen.json")" 'rc=4'
echo '[]' >"$T/reviews.json"
check 'submit: a pending review the cards showed that is gone is exit 4' "$(sb --head abc --seen-pending "$T/seen.json")" 'rc=4'
echo '[{"id":55,"state":"PENDING","user":{"login":"me"},"body":"draft"}]' >"$T/reviews.json"
bash "$R" pending o/r 7 me >"$T/seen.json"; rm -f "$T/stdin.json"; touch "$T/post-fails"
check 'submit: a failed post is exit 3' "$(sb --head abc --seen-pending "$T/seen.json")" 'rc=3'
check 'submit: and the pending review is put back' "$(jq -c '.comments[0].body' "$T/stdin.json")" '"edited"'
rm -f "$T/post-fails"
bash "$R" submit o/r 7 "$T/p.json" --head abc 2>/dev/null; check 'submit: no --login is usage' "$?" 2
echo '[]' >"$T/reviews.json"
psha=$( { command -v sha256sum >/dev/null 2>&1 && sha256sum "$T/p.json" || shasum -a 256 "$T/p.json"; } | cut -d' ' -f1)
check 'submit: the payload of that sha256 posts' "$(sb --head abc --sha256 "$psha" | tail -1)" 'rc=0'
: >"$STUB_LOG"
check 'submit: a payload changed since the cards is exit 4' "$(sb --head abc --sha256 0000)" 'rc=4'
check 'submit: and reaches no gh call' "$(wc -l <"$STUB_LOG" | tr -d ' ')" 0

# --- bots: a known review bot, so review points at brief. The team's lists, or a bot's review.
bo() { bash "$R" bots o/r "${1:-7}" 2>"$T/err"; echo "rc=$?"; }
echo '[]' >"$T/reviews.json"
check 'bots: none listed, no reviews: exit 1' "$(bo)" 'rc=1'
echo '[{"id":1,"state":"COMMENTED","user":{"login":"ann","type":"User"}},{"id":2,"state":"APPROVED","user":{"login":"github-actions[bot]","type":"Bot"}}]' >"$T/reviews.json"
check 'bots: a person s review and the Actions user are no review bot' "$(bo)" 'rc=1'
echo '[{"id":3,"state":"COMMENTED","user":{"login":"coderabbitai[bot]","type":"Bot"}}]' >"$T/reviews.json"
echo '[{"id":4,"state":"PENDING","user":{"login":"lazy[bot]","type":"Bot"}}]' >>"$T/reviews.json"
check 'bots: a Bot s submitted review, across pages; a pending one is not' "$(bo)" 'coderabbitai[bot]
rc=0'
echo '[{"id":5,"state":"COMMENTED","user":{"login":"gatekeeper","type":"User"}}]' >"$T/reviews.json"
check 'bots: a plain account reviewing is no bot unless listed' "$(bo)" 'rc=1'
mkdir -p .claude && echo '{"review": {"bots": ["gatekeeper"]}}' >.claude/highness.json
check 'bots: a review.bots login that reviewed' "$(bo)" 'gatekeeper
rc=0'
echo '[]' >"$T/reviews.json"
echo '{"crew": {"bots": ["reviewer-x"]}}' >"$HIGHNESS_CONFIG"
check 'bots: the team s lists count with no review yet' "$(bo)" 'gatekeeper
reviewer-x
rc=0'
check 'bots: the PR s reviews unreadable: exit 3, the lists still printed' "$(bo 8)" 'gatekeeper
reviewer-x
rc=3'
has 'bots: and the failure is said' "$(cat "$T/err")" 'reading the reviews of o/r#8 failed'
bash "$R" bots o/r 2>/dev/null; check 'bots: no PR is usage' "$?" 2
rm -f .claude/highness.json; echo '{}' >"$HIGHNESS_CONFIG"

exit $fail
