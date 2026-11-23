#!/usr/bin/env bash
# forge.sh — the agenda's built-in forge sections (GitHub, through gh's own login): the person's
# open PRs that no worker owns, each with its next step in words, and the PRs waiting on their
# review. crew.sh sections runs it after the team's own agenda.sections.
#
#   forge.sh [--root DIR] sections
#
# stdin: the agenda lines printed so far, one JSON object per line, plus one {"url": <pr>} per PR
# a worker owns. A PR whose url is among them is not listed again (the worker's line, or the
# team's own section, already shows it). A line with `key`, `role` and `status` (the tracker's
# tickets, `{{TRACKER}} sections`) says which tickets are blocked: a draft PR whose branch or
# title names a ticket in role `waiting` waits on that ticket, it is not the person's to flip.
#
# Out: the agenda's section lines — section, group (you | others), title, next, url, since — in
# sections "my PRs", "reviews asked of me", "reviews asked of my team" and any configured below;
# or {section, error} when gh failed. No gh on PATH: nothing (the team is not on GitHub).
# Always exits 0: a broken forge shows as its error line, it never hides the rest of the agenda.
#
# Config (lib/config.sh), under `agenda.forge`; `"forge": false` turns the sections off (a team
# whose agenda.sections already list its PRs):
#   query          extra search terms ANDed into every search ("org:acme"); default none, every
#                  repo the person can see
#   approvals      how many approvals a PR needs before it is ready (0 or unset: GitHub's own
#                  review decision; a repo with no review rule is ready when green)
#   review_labels  labels that summon reviewers: a ready PR with none of them is told to add the
#                  first
#   review_checks  a regex of check names that are review gates, not CI: waited on, never "CI
#                  failing"
#   reviews        extra review queues, [{"name", "query", "group"}]: PRs matching the search
#                  terms (say "label:needs-review"), not the person's own, under section `name`,
#                  group `group` (default others)
# The bots whose comments ask nothing of the person: crew.bots, the forge Actions users, any
# [bot] login and any forge Bot account. Their activity is no review activity: a bot's comment or
# review after the person's last word owes nothing, its approval is no approval, a review
# requested from it is no one awaited. crew.bots is read at the root and, for each PR, from the
# user file's `repos.<owner/repo>` and `repos.<owner>` of the PR's repo.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"

if [ "${1:-}" = --root ]; then
  cd "${2:-}" 2>/dev/null || exit 0
  shift 2
fi
[ "${1:-}" = sections ] || { echo 'usage: forge.sh [--root DIR] sections' >&2; exit 3; }
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || { cat >/dev/null; exit 0; }

cfg() { bash "$CONFIG" get ".agenda.forge.$1" 2>/dev/null; }
[ "$(bash "$CONFIG" get '.agenda.forge' 2>/dev/null)" = false ] && { cat >/dev/null; exit 0; }
QUERY=$(cfg query) || QUERY=''
NEED=$(cfg approvals) || NEED=0
case "$NEED" in ''|*[!0-9]*) NEED=0 ;; esac
LABELS=$(bash "$CONFIG" get '.agenda.forge.review_labels | select(type == "array") | tojson' 2>/dev/null) || LABELS='[]'
GATES=$(cfg review_checks) || GATES=''
EXTRA=$(bash "$CONFIG" get '.agenda.forge.reviews | select(type == "array") | tojson' 2>/dev/null) || EXTRA='[]'
BOTS=$({ printf '%s\n' github-actions forgejo-actions gitea-actions; bash "$CONFIG" list '.crew.bots' 2>/dev/null; } \
  | jq -Rsc 'split("\n") | map(select(. != "")) | unique')
# The searches span every repo, but config.sh reads the overlays of the cwd's repo only: the
# crew.bots of each `repos.<owner/repo>` and `repos.<owner>` in the user file (config.sh's keys:
# lowercase) apply to the PRs of that repo or owner. A repo's own committed file is not read: the
# PR's repo may have no clone here.
OVERLAY_BOTS=$(jq -c '[(.repos // {}) | to_entries[] | {key, value: [.value.crew.bots? // [] | .[]? | strings]}
                       | select(.value | length > 0)] | from_entries' \
  "${HIGHNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/highness/config.json}" 2>/dev/null) || OVERLAY_BOTS='{}'
[ -n "$OVERLAY_BOTS" ] || OVERLAY_BOTS='{}'

# What the agenda already shows: the urls to skip (normalized), and the tickets' roles.
SEEN=$(jq -Rsc '
  [split("\n")[] | fromjson? | objects] as $l
  | {urls: [$l[] | .url | strings | ascii_downcase | sub("/+$"; "")] | unique,
     tickets: [$l[] | select((.key | type) == "string" and (.role | type) == "string")
               | select(.key | test("^[A-Za-z0-9_.-]+$")) | {key, role, status: (.status // .role)}]}')
[ -n "$SEEN" ] || SEEN='{"urls":[],"tickets":[]}'

read -r -d '' MINE_QUERY <<'GQL' || true
query($q: String!) {
  viewer { login }
  search(query: $q, type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest {
        number title url isDraft updatedAt reviewDecision mergeStateStatus headRefName baseRefName
        repository { nameWithOwner }
        labels(first: 20) { nodes { name } }
        autoMergeRequest { enabledAt }
        reviewRequests(first: 20) {
          nodes { requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Team { combinedSlug } } }
        }
        latestOpinionatedReviews(first: 20) { nodes { author { __typename login } state submittedAt } }
        reviews(last: 50) { nodes { author { __typename login } state submittedAt body } }
        comments(last: 50) { nodes { author { __typename login } createdAt } }
        reviewThreads(first: 100) {
          nodes { isResolved comments(last: 1) { totalCount nodes { author { __typename login } createdAt } } }
        }
        commits(last: 1) {
          nodes { commit { committedDate statusCheckRollup { contexts(first: 100) { nodes {
            __typename ... on CheckRun { name conclusion status } ... on StatusContext { context state }
          } } } } }
        }
      }
    }
  }
}
GQL

read -r -d '' REVIEW_QUERY <<'GQL' || true
query($q: String!) {
  viewer { login }
  search(query: $q, type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest {
        number title url isDraft createdAt reviewDecision mergeStateStatus headRefOid
        repository { nameWithOwner }
        author { login }
        reviewRequests(first: 20) {
          nodes { requestedReviewer { __typename ... on User { login } ... on Team { combinedSlug } } }
        }
        latestOpinionatedReviews(first: 20) { nodes { author { __typename login } state submittedAt commit { oid } } }
        pendingReviews: reviews(states: PENDING, first: 5) { nodes { author { login } comments { totalCount } } }
      }
    }
  }
}
GQL

read -r -d '' JQ_DEFS <<'JQ' || true
def norm: ascii_downcase | sub("/+$"; "");
def seen: (.url // "" | norm) as $u | any($seen.urls[]; . == $u);
def bot: (.author.__typename // "") == "Bot"
         or ((.author.login // "") | test("(\\[bot\\]|-bot)$"; "i"))
         or ((.author.login // "") as $l | any($bots[]; . == $l));
def human: select(bot | not);
def name: "\(.repository.nameWithOwner)#\(.number) · \(.title)";
def ats: map("@" + .) | join(", ");
def day: (. // "") | .[0:10];
JQ

# search <query> <terms> → gh's answer; on failure the reason, exit 1.
search() {
  local out
  out=$(gh api graphql -f query="$1" -f q="$2${QUERY:+ $QUERY}" 2>&1) \
    || { printf '%s' "$out" | tail -1; return 1; }
  printf '%s' "$out" | jq -e '.data.search' >/dev/null 2>&1 \
    || { printf '%s' "$out" | jq -r '[.errors[]?.message] | first // "gh answered without data"' 2>/dev/null | head -1; return 1; }
  # A login on its repo's overlay bots list is a Bot account from here on, author or requested.
  printf '%s' "$out" | jq -c --argjson ob "$OVERLAY_BOTS" '
    .data.search.nodes |= ((. // []) | map(
      ((.repository.nameWithOwner // "") | ascii_downcase) as $r
      | (($ob[$r] // []) + ($ob[$r | split("/") | .[0] // ""] // [])) as $extra
      | if ($extra | length) == 0 then .
        else (.. | objects | select((.login // "") as $l | $l != "" and any($extra[]; . == $l))) |= (.__typename = "Bot")
        end))'
}
err() { jq -cn --arg s "$1" --arg e "$2" '{section: $s, error: ("gh: " + $e)}'; }

# ---- my open PRs ----
if raw=$(search "$MINE_QUERY" 'is:pr is:open author:@me'); then
  printf '%s' "$raw" | jq -c --argjson seen "$SEEN" --argjson bots "$BOTS" --argjson need "$NEED" \
      --argjson labels "$LABELS" --arg gates "$GATES" "$JQ_DEFS"'
    def ctx: .name // .context // "";
    def gate: $gates != "" and (ctx | . != "" and test($gates));
    def failed: (.conclusion // .state // "") as $c
      | $c == "FAILURE" or $c == "TIMED_OUT" or $c == "CANCELLED" or $c == "ERROR"
        or $c == "STARTUP_FAILURE" or $c == "ACTION_REQUIRED";
    def running: (.status // "") as $s | (.state // "") as $t
      | $s == "IN_PROGRESS" or $s == "QUEUED" or $s == "PENDING" or $s == "WAITING" or $s == "REQUESTED"
        or $t == "PENDING" or $t == "EXPECTED";
    # A re-run cancels the older run of the same check, and the rollup keeps both: a CANCELLED
    # run with a same-named sibling that was not cancelled does not count.
    def current: . as $all
      | [.[] | select((.conclusion // "") != "CANCELLED"
                      or (ctx as $n | $n == "" or ([$all[] | select(ctx == $n and (.conclusion // "") != "CANCELLED")] | length) == 0))];
    def plural($n; $w): "\($n) \($w)" + (if $n == 1 then "" else "s" end);
    (.data.viewer.login // "") as $me
    | (.data.search.nodes // [])[] | select(.number != null) | select(seen | not) | . as $p
    | ([($p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])[]] | current) as $all
    | [$all[] | select(gate | not)] as $ci
    | [$all[] | select(gate)] as $gate
    | [$ci[] | select(failed) | ctx | select(. != "")] as $failing
    | ([$ci[] | select(failed)] | length > 0) as $red
    | ([$ci[] | select(running)] | length > 0) as $ciRunning
    | [$gate[] | select(failed or running) | ctx] as $gateOpen
    # What the person last said on the PR, not in a thread: a PR comment, or a review with a body.
    # A reply inside a thread is a body-less review, so it answers only its own thread. A summary
    # reply answers every thread and comment before it.
    | ([($p.comments.nodes // [])[] | select(.author.login == $me) | .createdAt]
       + [($p.reviews.nodes // [])[] | select(.author.login == $me and (.body // "") != "") | .submittedAt]
       | map(select(. != null)) | max // "") as $said
    | (($p.commits.nodes[0].commit.committedDate // "") as $c | [$said, $c] | max) as $answered
    # Unresolved threads count whether outdated or not: a thread on rewritten lines still waits.
    # A finding of a bot that nobody answered yet counts (on a PR worked by hand, nothing else
    # shows it); a later reply of a bot in a thread does not reopen it.
    | [($p.reviewThreads.nodes // [])[] | select(.isResolved == false) | .comments as $c
       | $c.nodes[0] | select(. != null) | select(($c.totalCount // 1) == 1 or (bot | not))] as $open
    | ([$open[] | select(.author.login != $me and .createdAt > $said)] | length) as $threadsOwed
    | (($open | length) - $threadsOwed) as $threadsAnswered
    | ([($p.comments.nodes // [])[] | human | select(.author.login != $me and .createdAt > $said)]
       + [($p.reviews.nodes // [])[] | human
          | select(.author.login != $me and (.body // "") != "" and .state != "APPROVED" and .state != "PENDING"
                   and .submittedAt > $said)]
       | length) as $commentsOwed
    | ($threadsOwed + $commentsOwed) as $owed
    | [($p.latestOpinionatedReviews.nodes // [])[] | human | select(.author.login != $me)] as $verdicts
    | [$verdicts[] | select(.state == "CHANGES_REQUESTED")] as $crq
    | [$crq[] | select($owed == 0 and .submittedAt < $answered) | .author.login] as $crqAnswered
    | [$crq[] | .author.login | select(. as $l | ($crqAnswered | index($l)) == null)] as $crqOpen
    | ([$verdicts[] | select(.state == "APPROVED")] | length) as $approvals
    | [($p.reviewRequests.nodes // [])[] | .requestedReviewer
       | select(.__typename != "Bot") | (.login // .combinedSlug // "")
       | select(. != "" and . != $me and (. as $l | any($bots[]; . == $l) | not))] as $awaiting
    | ($p.reviewDecision // "") as $rd
    | ($p.mergeStateStatus // "") as $mss
    | ($rd == "APPROVED" or ($need > 0 and $approvals >= $need)
       or ($rd == "" and $need == 0 and $approvals > 0 and ($crq | length) == 0)) as $enough
    | ($rd == "" and $need == 0 and $approvals == 0 and ($crq | length) == 0 and ($awaiting | length) == 0) as $solo
    | ([$p.labels.nodes[]?.name | ascii_downcase] as $has
       | $labels | length > 0 and ([.[] | ascii_downcase | select(. as $x | ($has | index($x)) != null)] | length) == 0) as $noLabel
    | ([$seen.tickets[] | select(.role == "waiting") | . as $t
        | select(($p.headRefName + " " + $p.title) | test("(^|[^A-Za-z0-9])" + $t.key + "([^0-9]|$)"; "i"))] | first) as $blocked
    | (if $threadsAnswered > 0 then "; " + plural($threadsAnswered; "answered thread") + " unresolved" else "" end) as $tail
    | (if $red then {group: "you", next: ("CI failing: " + (if ($failing | length) > 0 then $failing | join(", ") else "see the checks" end))}
       elif ($crqOpen | length) > 0 then {group: "you", next: ("changes requested by " + ($crqOpen | ats)
                                          + (if $owed > 0 then "; " + plural($owed; "unanswered comment") else "" end))}
       elif $owed > 0 then {group: "you", next: plural($owed; "unanswered review comment")}
       elif $mss == "DIRTY" then {group: "you", next: ("merge conflicts with " + $p.baseRefName + ": merge it in")}
       elif $p.isDraft and $blocked != null then {group: "others", next: ("draft; its ticket \($blocked.key) is \($blocked.status): waiting")}
       elif $p.isDraft then {group: "you", next: "draft: mark it ready for review when it is done"}
       elif ($crqAnswered | length) > 0 then {group: "you", next: ("re-request a review from " + ($crqAnswered | ats) + ": their changes are answered")}
       elif $noLabel then {group: "you", next: ("add the label " + $labels[0] + ": it summons the reviewers")}
       elif $p.autoMergeRequest != null then {group: "others", next: "auto-merge is on: waiting for the checks"}
       elif ($enough or $solo) and ($ciRunning | not) and ($gateOpen | length) == 0
            and $mss != "BEHIND" and $mss != "BLOCKED" then
         (if $threadsAnswered > 0 then {group: "you", next: ("resolve " + plural($threadsAnswered; "answered thread") + ", then merge")}
          elif $enough then {group: "you", next: "approved and green: merge it"}
          else {group: "you", next: "green, no review required: merge it, or request a review"} end)
       elif $mss == "BEHIND" then {group: "you", next: ("behind " + $p.baseRefName + ": update the branch")}
       elif $ciRunning then {group: "others", next: ("CI running" + $tail)}
       elif ($gateOpen | length) > 0 then {group: "others", next: ("waiting on the review check " + ($gateOpen | join(", ")) + $tail)}
       elif ($awaiting | length) > 0 then {group: "others", next: ("waiting on " + ($awaiting | ats) + " to review" + $tail)}
       elif $mss == "BLOCKED" then {group: "others", next: ("GitHub blocks the merge: a required review or check is unmet" + $tail)}
       elif ($enough | not) then {group: "you", next: "request a review"}
       else {group: "others", next: ("waiting on review" + $tail)} end) as $step
    | {section: "my PRs", group: $step.group, title: ($p | name), next: $step.next, url: $p.url, since: $p.updatedAt}'
else
  err 'my PRs' "$raw"
fi

# ---- review requests ----
# review_lines <section for a direct request> <section for a team one> <group of a team one>
review_lines() {
  jq -c --argjson seen "$SEEN" --argjson bots "$BOTS" --arg ds "$1" --arg ts "$2" --arg tg "$3" "$JQ_DEFS"'
    (.data.viewer.login // "") as $me
    | (.data.search.nodes // [])[] | select(.number != null) | select(seen | not) | . as $p
    | select(($p.author.login // "") != $me)
    | ([($p.reviewRequests.nodes // [])[] | .requestedReviewer | select(.__typename == "User") | .login] | index($me) != null) as $direct
    | ([($p.reviewRequests.nodes // [])[] | .requestedReviewer | select(.__typename == "Team") | .combinedSlug]) as $teams
    | ([($p.pendingReviews.nodes // [])[] | select(.author.login == $me)] | first) as $draft
    | ([($p.latestOpinionatedReviews.nodes // [])[] | select(.author.login == $me)] | first) as $mine
    | [($p.latestOpinionatedReviews.nodes // [])[] | human | select(.author.login != $me)] as $verdicts
    | [$verdicts[] | select(.state == "APPROVED") | .author.login] as $approved
    | ([$verdicts[] | select(.state == "CHANGES_REQUESTED")] | length) as $crq
    | ($p.url | sub("/+$"; "")) as $u
    | (if $draft != null then
         {mine: true, next: ("your draft review (\($draft.comments.totalCount // 0) comments) is not submitted: finish and submit it"), url: $u}
       elif $mine != null and ($mine.commit.oid // "") != "" and $mine.commit.oid != $p.headRefOid then
         {mine: false, url: ($u + "/files/" + $mine.commit.oid + ".." + $p.headRefOid),
          next: ((if $mine.state == "CHANGES_REQUESTED" then "you asked for changes" else "you reviewed" end)
                 + " on " + ($mine.submittedAt | day) + ": review what changed since")}
       elif $mine != null then
         {mine: false, url: $u, next: ((if $mine.state == "CHANGES_REQUESTED" then "you asked for changes" else "you reviewed" end)
                                    + " on " + ($mine.submittedAt | day) + "; nothing pushed since: ask the author")}
       elif ($approved | length) > 0 and $crq == 0 and ($p.mergeStateStatus // "") != "BLOCKED"
            and ($p.reviewDecision // "") != "REVIEW_REQUIRED" then
         {mine: false, url: $u, next: ("approved by " + ($approved | ats) + ": your review is optional")}
       elif $p.isDraft then {mine: false, url: $u, next: "a draft: review it when it is ready"}
       else {mine: false, url: $u, next: "review it"} end) as $step
    | {section: (if $direct then $ds else $ts end),
       group: (if $direct or $step.mine then "you" else $tg end),
       title: (($p | name) + " (@" + ($p.author.login // "?") + ")"
               + (if $direct or ($teams | length) == 0 then "" else " for " + ($teams | ats) end)),
       next: $step.next, url: $step.url, since: $p.createdAt}'
}

if raw=$(search "$REVIEW_QUERY" 'is:pr is:open review-requested:@me'); then
  printf '%s' "$raw" | review_lines 'reviews asked of me' 'reviews asked of my team' others
  # The extra queues skip what the requests already list.
  SEEN=$(printf '%s' "$raw" | jq -c --argjson seen "$SEEN" '
    $seen + {urls: ($seen.urls + [(.data.search.nodes // [])[] | .url | strings | ascii_downcase | sub("/+$"; "")] | unique)}')
else
  err 'reviews asked of me' "$raw"
fi

n=$(printf '%s' "$EXTRA" | jq 'length' 2>/dev/null) || n=0
i=0
while [ "$i" -lt "${n:-0}" ]; do
  name=$(printf '%s' "$EXTRA" | jq -r ".[$i].name // \"review queue $i\"")
  terms=$(printf '%s' "$EXTRA" | jq -r ".[$i].query // empty")
  group=$(printf '%s' "$EXTRA" | jq -r ".[$i].group // \"others\"")
  case "$group" in you|others|later) ;; *) group=others ;; esac
  i=$((i + 1))
  [ -n "$terms" ] || continue
  if raw=$(search "$REVIEW_QUERY" "is:pr is:open -author:@me $terms"); then
    printf '%s' "$raw" | review_lines "$name" "$name" "$group"
  else
    err "$name" "$raw"
  fi
done
exit 0
