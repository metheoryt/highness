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

exit $fail
