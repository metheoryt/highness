#!/usr/bin/env bash
# forge.sh: the agenda's built-in forge sections from a fake gh — each PR's next step, the review
# requests split by who was asked, the dedupe against what the agenda already shows, config.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$HERE/../lib/forge.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

# Fake gh: answers a search by its terms from $T/fx, logs the terms.
mkdir -p "$T/bin" "$T/fx" "$T/repo"
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
for a; do case "$a" in q=*) printf '%s\n' "${a#q=}" >>"$FX/log"; q=${a#q=} ;; esac; done
[ -n "${FAKE_FAIL:-}" ] && { echo 'HTTP 401: Bad credentials' >&2; exit 1; }
case "$q" in
  *review-requested:@me*) f=reviews ;;
  *-author:@me*) f=extra ;;
  *author:@me*) f=mine ;;
  *) f=extra ;;
esac
[ -f "$FX/$f.json" ] && exec cat "$FX/$f.json"
echo '{"data":{"viewer":{"login":"me"},"search":{"nodes":[]}}}'
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" FX="$T/fx"
git -C "$T/repo" init -q

# A PR node: defaults overridden by the object given.
pr() { jq -c --argjson o "$1" -n '{
  number: 1, title: "t", url: "https://github.com/o/r/pull/1", isDraft: false, updatedAt: "2026-01-05T00:00:00Z",
  reviewDecision: "", mergeStateStatus: "CLEAN", headRefName: "feat", baseRefName: "main",
  repository: {nameWithOwner: "o/r"}, labels: {nodes: []}, autoMergeRequest: null,
  reviewRequests: {nodes: []}, latestOpinionatedReviews: {nodes: []}, reviews: {nodes: []},
  comments: {nodes: []}, reviewThreads: {nodes: []},
  commits: {nodes: [{commit: {committedDate: "2026-01-01T00:00:00Z", statusCheckRollup: {contexts: {nodes: [
    {__typename: "CheckRun", name: "build", conclusion: "SUCCESS", status: "COMPLETED"}]}}}}]}} + $o'; }
answer() { jq -s -c '{data: {viewer: {login: "me"}, search: {nodes: .}}}'; }
U() { printf '{"login":"%s","__typename":"User"}' "$1"; }
run() { (cd "$T/repo" && printf '%s' "${1:-}" | bash "$F" sections); }
next_of() { printf '%s\n' "$1" | jq -r --arg n "$2" 'select(.title | startswith("o/r#" + $n + " ")) | .group + " | " + .next'; }

# ---- my PRs
{
  # 1: CI red; the cancelled run of "lint" has a green sibling and does not count.
  pr '{"number":1,"commits":{"nodes":[{"commit":{"committedDate":"2026-01-01T00:00:00Z","statusCheckRollup":{"contexts":{"nodes":[
      {"__typename":"CheckRun","name":"build","conclusion":"FAILURE","status":"COMPLETED"},
      {"__typename":"CheckRun","name":"lint","conclusion":"CANCELLED","status":"COMPLETED"},
      {"__typename":"CheckRun","name":"lint","conclusion":"SUCCESS","status":"COMPLETED"}]}}}}]}}'
  # 2: changes requested, and an outdated thread of theirs nobody answered.
  pr "{\"number\":2,\"latestOpinionatedReviews\":{\"nodes\":[{\"author\":$(U rev),\"state\":\"CHANGES_REQUESTED\",\"submittedAt\":\"2026-01-02T00:00:00Z\"}]},
      \"reviewThreads\":{\"nodes\":[{\"isResolved\":false,\"comments\":{\"nodes\":[{\"author\":$(U rev),\"createdAt\":\"2026-01-02T00:00:00Z\"}]}}]}}"
  # 3: a thread, then my summary reply on the PR after it; approved: resolve, then merge.
  pr "{\"number\":3,\"reviewDecision\":\"APPROVED\",
      \"reviewThreads\":{\"nodes\":[{\"isResolved\":false,\"comments\":{\"nodes\":[{\"author\":$(U rev),\"createdAt\":\"2026-01-02T00:00:00Z\"}]}}]},
      \"comments\":{\"nodes\":[{\"author\":$(U me),\"createdAt\":\"2026-01-03T00:00:00Z\"}]}}"
  # 4: a draft whose ticket is blocked; 5: a draft with no ticket.
  pr '{"number":4,"isDraft":true,"headRefName":"feature/AB-7-thing"}'
  pr '{"number":5,"isDraft":true,"headRefName":"feature/AB-70-other"}'
  # 6: approved, green.
  pr "{\"number\":6,\"latestOpinionatedReviews\":{\"nodes\":[{\"author\":$(U rev),\"state\":\"APPROVED\",\"submittedAt\":\"2026-01-02T00:00:00Z\"}]}}"
  # 7: a requested reviewer; a bot's comment after mine asks nothing.
  pr "{\"number\":7,\"reviewDecision\":\"REVIEW_REQUIRED\",\"mergeStateStatus\":\"BLOCKED\",
      \"reviewRequests\":{\"nodes\":[{\"requestedReviewer\":{\"__typename\":\"User\",\"login\":\"rev\"}}]},
      \"comments\":{\"nodes\":[{\"author\":$(U ci-helper),\"createdAt\":\"2026-01-04T00:00:00Z\"},
                                {\"author\":{\"login\":\"coderabbitai\",\"__typename\":\"Bot\"},\"createdAt\":\"2026-01-04T00:00:00Z\"}]}}"
  # 8: conflicts.
  pr '{"number":8,"mergeStateStatus":"DIRTY","reviewDecision":"REVIEW_REQUIRED"}'
  # 9: a person's comment after my last word.
  pr "{\"number\":9,\"comments\":{\"nodes\":[{\"author\":$(U me),\"createdAt\":\"2026-01-02T00:00:00Z\"},{\"author\":$(U rev),\"createdAt\":\"2026-01-03T00:00:00Z\"}]}}"
  # 10: the changes request answered (a later commit, nothing owed): re-request.
  pr "{\"number\":10,\"latestOpinionatedReviews\":{\"nodes\":[{\"author\":$(U rev),\"state\":\"CHANGES_REQUESTED\",\"submittedAt\":\"2025-12-30T00:00:00Z\"}]}}"
  # 14: a bot's finding nobody answered counts; a bot's reply after mine in another thread does not.
  pr "{\"number\":14,\"reviewDecision\":\"REVIEW_REQUIRED\",\"comments\":{\"nodes\":[{\"author\":$(U me),\"createdAt\":\"2026-01-02T00:00:00Z\"}]},
      \"reviewThreads\":{\"nodes\":[
        {\"isResolved\":false,\"comments\":{\"totalCount\":1,\"nodes\":[{\"author\":{\"login\":\"coderabbitai\",\"__typename\":\"Bot\"},\"createdAt\":\"2026-01-03T00:00:00Z\"}]}},
        {\"isResolved\":false,\"comments\":{\"totalCount\":3,\"nodes\":[{\"author\":{\"login\":\"coderabbitai\",\"__typename\":\"Bot\"},\"createdAt\":\"2026-01-03T00:00:00Z\"}]}}]}}"
  # 11: already on the agenda (a worker's PR).
  pr '{"number":11,"url":"https://github.com/o/r/pull/11/"}'
} | answer >"$T/fx/mine.json"
printf '{"crew":{"bots":["ci-helper"]}}' >"$HIGHNESS_CONFIG"
seen='{"key":"AB-7","role":"waiting","status":"Blocked","title":"x"}
{"key":"AB-70","role":"active","status":"In Progress","title":"y"}
{"url":"https://github.com/O/R/pull/11"}'
out=$(run "$seen")
check 'mine: CI failing names the failed check, not a superseded cancel' "$(next_of "$out" 1)" 'you | CI failing: build'
check 'mine: changes requested, an outdated thread still counts' "$(next_of "$out" 2)" 'you | changes requested by @rev; 1 unanswered comment'
check 'mine: a summary reply answers the thread' "$(next_of "$out" 3)" 'you | resolve 1 answered thread, then merge'
check 'mine: a draft whose ticket is blocked waits' "$(next_of "$out" 4)" 'others | draft; its ticket AB-7 is Blocked: waiting'
check 'mine: a draft whose ticket is not blocked is the person'"'"'s' "$(next_of "$out" 5)" 'you | draft: mark it ready for review when it is done'
check 'mine: approved and green' "$(next_of "$out" 6)" 'you | approved and green: merge it'
check 'mine: waiting on a reviewer; bots ask nothing' "$(next_of "$out" 7)" 'others | waiting on @rev to review'
check 'mine: conflicts' "$(next_of "$out" 8)" 'you | merge conflicts with main: merge it in'
check 'mine: a person'"'"'s comment after mine' "$(next_of "$out" 9)" 'you | 1 unanswered review comment'
check 'mine: an answered changes request is re-requested' "$(next_of "$out" 10)" 'you | re-request a review from @rev: their changes are answered'
check 'mine: an unanswered bot finding counts, a bot'"'"'s reply does not' "$(next_of "$out" 14)" 'you | 1 unanswered review comment'
check 'mine: a PR the agenda shows is left out' "$(next_of "$out" 11)" ''
check 'mine: section and fields' "$(printf '%s\n' "$out" | head -1 | jq -r '[.section, .url, .since] | join("|")')" 'my PRs|https://github.com/o/r/pull/1|2026-01-05T00:00:00Z'

# Config: review labels, review checks, extra search terms.
pr '{"number":12,"reviewDecision":"REVIEW_REQUIRED","commits":{"nodes":[{"commit":{"committedDate":"2026-01-01T00:00:00Z","statusCheckRollup":{"contexts":{"nodes":[
    {"__typename":"StatusContext","context":"gate/reviews","state":"PENDING"},
    {"__typename":"StatusContext","context":"ai/review","state":"ERROR"}]}}}}]}}' | answer >"$T/fx/mine.json"
printf '{"agenda":{"forge":{"query":"org:o","review_checks":"^(gate|ai)/"}}}' >"$HIGHNESS_CONFIG"; : >"$T/fx/log"
out=$(run)
check 'config: review checks are waited on, never CI failing' "$(next_of "$out" 12)" 'others | waiting on the review check gate/reviews, ai/review'
check 'config: query is added to every search' "$(grep -c 'org:o$' "$T/fx/log")" 2
printf '{"agenda":{"forge":{"review_labels":["needs-review"]}}}' >"$HIGHNESS_CONFIG"
pr '{"number":13,"reviewDecision":"REVIEW_REQUIRED"}' | answer >"$T/fx/mine.json"
check 'config: a ready PR without the review label is told to add it' "$(next_of "$(run)" 13)" 'you | add the label needs-review: it summons the reviewers'

# ---- review requests
rm -f "$T/fx/mine.json"
{
  pr '{"number":21,"createdAt":"2026-01-01T00:00:00Z","author":{"login":"ann"},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"me"}}]}}'
  pr '{"number":22,"createdAt":"2026-01-01T00:00:00Z","author":{"login":"ann"},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","combinedSlug":"o/devs"}}]}}'
  pr '{"number":23,"createdAt":"2026-01-01T00:00:00Z","author":{"login":"ann"},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","combinedSlug":"o/devs"}}]},
      "pendingReviews":{"nodes":[{"author":{"login":"me"},"comments":{"totalCount":2}}]}}'
  pr '{"number":24,"createdAt":"2026-01-01T00:00:00Z","author":{"login":"ann"},"headRefOid":"bbb","reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"me"}}]},
      "latestOpinionatedReviews":{"nodes":[{"author":{"login":"me","__typename":"User"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-02T10:00:00Z","commit":{"oid":"aaa"}}]}}'
  pr '{"number":25,"createdAt":"2026-01-01T00:00:00Z","author":{"login":"ann"},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"me"}}]}}' \
    | jq -c '.url = "https://github.com/o/r/pull/25"'
} | answer >"$T/fx/reviews.json"
pr '{"number":26,"createdAt":"2026-01-01T00:00:00Z","author":{"login":"bob"}}' | jq -c '.url = "https://github.com/o/r/pull/26"' >"$T/n26"
{ cat "$T/n26"; pr '{"number":21,"author":{"login":"ann"}}'; } | answer >"$T/fx/extra.json"
printf '{"agenda":{"forge":{"reviews":[{"name":"labelled","query":"label:needs-review"}]}}}' >"$HIGHNESS_CONFIG"
out=$(run '{"url":"https://github.com/o/r/pull/25"}')
line() { printf '%s\n' "$out" | jq -r --arg n "$1" 'select(.title | startswith("o/r#" + $n + " ")) | [.section, .group, .next] | join(" | ")'; }
check 'reviews: asked of me' "$(line 21)" 'reviews asked of me | you | review it'
check 'reviews: asked of my team' "$(line 22)" 'reviews asked of my team | others | review it'
check 'reviews: the team is named' "$(printf '%s\n' "$out" | jq -r 'select(.title | startswith("o/r#22 ")) | .title')" 'o/r#22 · t (@ann) for @o/devs'
check 'reviews: my pending draft review is mine' "$(line 23)" 'reviews asked of my team | you | your draft review (2 comments) is not submitted: finish and submit it'
check 'reviews: re-requested after my changes request, the delta' "$(line 24)" 'reviews asked of me | you | you asked for changes on 2026-01-02: review what changed since'
check 'reviews: the delta link' "$(printf '%s\n' "$out" | jq -r 'select(.title | startswith("o/r#24 ")) | .url')" 'https://github.com/o/r/pull/1/files/aaa..bbb'
check 'reviews: a PR the agenda shows is left out' "$(line 25)" ''
check 'reviews: an extra queue' "$(line 26)" 'labelled | others | review it'
check 'reviews: an extra queue skips what the requests list' "$(printf '%s\n' "$out" | grep -c '"section":"labelled"')" 1

# ---- off, failing, no gh
printf '{"agenda":{"forge":false}}' >"$HIGHNESS_CONFIG"
check 'off: agenda.forge false' "$(run)" ''
printf '{}' >"$HIGHNESS_CONFIG"
out=$(FAKE_FAIL=1 run); rc=$?
check 'failing: one error line per search, exit 0' "$(printf '%s\n' "$out" | jq -r '.section + ": " + .error' | tr '\n' '|')|$rc" 'my PRs: gh: HTTP 401: Bad credentials|reviews asked of me: gh: HTTP 401: Bad credentials||0'

exit "$fail"
