#!/usr/bin/env bash
# review.sh — the deterministic parts of /hi-review:review: fetching a PR's head, checking that an
# inline comment's anchor is in the diff, reading threads and the person's pending review, and
# building and posting the one review. The model decides what to say; this decides what GitHub
# will accept, so a test can pin it.
#
#   review.sh head --pr N --base-ref B         BASE<TAB>HEAD: the PR head fetched to refs/hi-review/N,
#                                              and its merge-base with origin/B
#   review.sh anchor <base> <head> <path> <line|start-end> [RIGHT|LEFT]
#                                              exit 0 when GitHub can anchor a comment there: the
#                                              line (or the whole span) sits in one hunk of the
#                                              diff, on that side (RIGHT, the head, by default)
#   review.sh threads <owner/repo> <n>         the PR's review threads, one JSON object per line:
#                                              path, line, resolved, outdated, comments[] of
#                                              {author, bot, body, createdAt, url}
#   review.sh pending <owner/repo> <n> <login> the login's own PENDING review as one JSON object
#                                              {id, body, comments[]}; exit 1 when there is none
#   review.sh payload --event E [--body-file F] [--comments-file C]
#                                              the review payload on stdout (see payload below)
#   review.sh delete-pending <owner/repo> <n> <id>
#   review.sh post <owner/repo> <n> <payload file>
#                                              one POST that creates AND submits the review;
#                                              prints {id, state, html_url}
#
# Exit: 0 ok · 1 no (not in the diff, no pending review) · 2 usage or bad input · 3 git/gh failed
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${HI_REVIEW_GH:-gh}"

say() { printf 'review.sh: %s\n' "$*" >&2; }

# head: a PRIVATE ref (never a branch, so it cannot collide with anyone's), forced so a force-push
# does not fail the review. Serves fork PRs too, through the base repo. The same ref hi's wt.sh
# review-head writes, so a quick review and a review workspace share one fetch.
cmd_head() {
  local pr='' base_ref='' out head base
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)       pr="${2:-}";       shift 2 ;;
      --base-ref) base_ref="${2:-}"; shift 2 ;;
      *) say "head: unknown flag $1"; return 2 ;;
    esac
  done
  case "$pr" in ''|*[!0-9]*) say "head: --pr must be a plain PR number (got [$pr])"; return 2 ;; esac
  [ -n "$base_ref" ] || { say 'head: --base-ref <baseRefName> is required'; return 2; }
  base_ref=${base_ref#origin/}
  out=$(git fetch --quiet origin "+pull/$pr/head:refs/hi-review/$pr" 2>&1) || {
    say "head: git fetch pull/$pr/head failed: $out"; return 3; }
  git fetch --quiet origin "$base_ref" >/dev/null 2>&1 || true
  head=$(git rev-parse --verify --quiet "refs/hi-review/$pr") || head=''
  [ -n "$head" ] || { say "head: refs/hi-review/$pr did not resolve"; return 3; }
  base=$(git merge-base "$head" "origin/$base_ref" 2>/dev/null) || base=''
  [ -n "$base" ] || { say "head: no merge-base between $head and origin/$base_ref"; return 3; }
  printf '%s\t%s\n' "$base" "$head"
}

# anchor: GitHub takes a review comment on any line of a hunk, context lines included — RIGHT
# for the head's numbering, LEFT for the base's — and a span only when both ends are in the same
# hunk. The file is found by its `+++ b/` name (its `diff --git` name for a deletion or a binary),
# over the whole diff with renames detected, so a renamed file's hunks keep their old-side numbers.
cmd_anchor() {
  local base="${1:-}" head="${2:-}" path="${3:-}" spec="${4:-}" side="${5:-RIGHT}" lo hi d
  [ -n "$base" ] && [ -n "$head" ] && [ -n "$path" ] && [ -n "$spec" ] || {
    say 'usage: anchor <base> <head> <path> <line|start-end> [RIGHT|LEFT]'; return 2; }
  case "$side" in RIGHT|LEFT) ;; *) say "anchor: side must be RIGHT or LEFT (got $side)"; return 2 ;; esac
  case "$spec" in
    *-*) lo=${spec%%-*}; hi=${spec#*-} ;;
    *)   lo=$spec; hi=$spec ;;
  esac
  case "$lo$hi" in ''|*[!0-9]*) say "anchor: line must be N or N-M (got $spec)"; return 2 ;; esac
  [ "$lo" -le "$hi" ] || { say "anchor: span $spec runs backwards"; return 2; }
  # Buffered, not piped: a failing `git diff` behind a pipe reads as "not in the diff".
  d=$(git diff --no-ext-diff --no-color -M -U3 "$base" "$head") || { say "anchor: git diff $base $head failed"; return 3; }
  printf '%s\n' "$d" | awk -v want="$path" -v lo="$lo" -v hi="$hi" -v side="$side" '
    /^diff --git / {
      rest = $0; p = ""
      while ((k = index(rest, " b/")) > 0) { rest = substr(rest, k + 3); p = rest }
      file = p; next
    }
    /^\+\+\+ / { if ($0 != "+++ /dev/null") file = substr($0, 7); next }
    /^@@ / && file == want {
      o = $2; n = $3; sub(/^-/, "", o); sub(/^\+/, "", n)
      r = (side == "RIGHT") ? n : o
      start = r; len = 1
      if (index(r, ",") > 0) { start = substr(r, 1, index(r, ",") - 1); len = substr(r, index(r, ",") + 1) }
      start += 0; len += 0
      if (len > 0 && lo >= start && hi <= start + len - 1) found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

cmd_threads() {
  local or="${1:-}" n="${2:-}" bots raw
  case "$or" in */*) ;; *) say 'usage: threads <owner/repo> <n>'; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) say 'usage: threads <owner/repo> <n>'; return 2 ;; esac
  # A login is a bot when it ends in [bot] or the team lists it (review.bots, both config files).
  bots=$(bash "$HERE/config.sh" list .review.bots | jq -R . | jq -sc 'map(select(. != ""))') || bots='[]'
  [ -n "$bots" ] || bots='[]'
  raw=$("$GH" api graphql -F owner="${or%%/*}" -F name="${or#*/}" -F number="$n" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) {
        reviewThreads(first: 100) { nodes { isResolved isOutdated path line originalLine
          comments(first: 50) { nodes { author { login } body createdAt url } } } } } } }') || {
    say "threads: gh api graphql failed for $or#$n"; return 3; }
  printf '%s\n' "$raw" | jq -c --argjson bots "$bots" '
    def bot: . as $l | ($l == null) or ($l | endswith("[bot]")) or ($bots | any(. == $l));
    .data.repository.pullRequest.reviewThreads.nodes[]
    | {path, line: (.line // .originalLine), resolved: .isResolved, outdated: .isOutdated,
       comments: [.comments.nodes[] | {author: .author.login, bot: (.author.login | bot), body, createdAt, url}]}'
}

cmd_pending() {
  local or="${1:-}" n="${2:-}" me="${3:-}" all rev id comments
  case "$or" in */*) ;; *) say 'usage: pending <owner/repo> <n> <login>'; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) say 'usage: pending <owner/repo> <n> <login>'; return 2 ;; esac
  [ -n "$me" ] || { say 'usage: pending <owner/repo> <n> <login>'; return 2; }
  all=$("$GH" api --paginate "repos/$or/pulls/$n/reviews") || { say "pending: reading the reviews of $or#$n failed"; return 3; }
  # --paginate prints one array per page; slurp and add them.
  rev=$(printf '%s\n' "$all" | jq -sc --arg me "$me" \
    'add // [] | map(select(.state == "PENDING" and (.user.login | ascii_downcase) == ($me | ascii_downcase))) | .[0] // empty') ||
    { say 'pending: the reviews did not parse'; return 3; }
  [ -n "$rev" ] || return 1
  id=$(printf '%s' "$rev" | jq -r .id)
  comments=$("$GH" api --paginate "repos/$or/pulls/$n/reviews/$id/comments") || {
    say "pending: reading the comments of review $id failed"; return 3; }
  printf '%s\n' "$comments" | jq -sc --argjson rev "$rev" '
    {id: $rev.id, body: ($rev.body // ""),
     comments: [add // [] | .[] | {path, line, side, start_line, start_side, body}]}'
}

# payload: what GitHub accepts in one POST that creates and submits the review.
#   - `event` is always set: never a PENDING review left behind, never the /events hand-off (whose
#     "Finish your review" dialog blanks the stored body).
#   - A bare approve (APPROVE, no body, no comments) is {"event":"APPROVE"} and nothing else.
#   - COMMENT and REQUEST_CHANGES need a body: GitHub rejects them without one.
#   - Each comment needs path, line and body; side defaults to RIGHT; a span's start_line is
#     below its line and its start_side defaults to the comment's side.
cmd_payload() {
  local event='' bodyf='' commf='' body='' comments='[]'
  while [ $# -gt 0 ]; do
    case "$1" in
      --event)         event="${2:-}"; shift 2 ;;
      --body-file)     bodyf="${2:-}"; shift 2 ;;
      --comments-file) commf="${2:-}"; shift 2 ;;
      *) say "payload: unknown flag $1"; return 2 ;;
    esac
  done
  case "$event" in APPROVE|REQUEST_CHANGES|COMMENT) ;; *) say "payload: --event must be APPROVE, REQUEST_CHANGES or COMMENT (got [$event])"; return 2 ;; esac
  if [ -n "$bodyf" ]; then
    [ -f "$bodyf" ] || { say "payload: no body file $bodyf"; return 2; }
    body=$(cat "$bodyf")
  fi
  if [ -n "$commf" ]; then
    [ -f "$commf" ] || { say "payload: no comments file $commf"; return 2; }
    comments=$(jq -c '.' "$commf" 2>/dev/null) || { say "payload: $commf is not JSON"; return 2; }
  fi
  printf '%s' "$comments" | jq -e 'type == "array"' >/dev/null 2>&1 || { say 'payload: comments must be a JSON array'; return 2; }
  # The body's leading and trailing blank lines are not content.
  body=$(printf '%s' "$body" | awk 'NF { seen = 1 } seen { buf = buf $0 "\n"; if (NF) { out = out buf; buf = "" } } END { printf "%s", out }')
  body=${body%
}
  case "$event" in
    COMMENT|REQUEST_CHANGES) [ -n "$body" ] || { say "payload: $event needs a body"; return 2; } ;;
  esac
  printf '%s' "$comments" | jq -c --arg event "$event" --arg body "$body" '
    def bad: "payload: comment \(.i): \(.why)" | halt_error(2);
    to_entries
    | map(.key as $i | .value
        | if (.path | type) != "string" or .path == "" then {i: $i, why: "no path"} | bad
          elif (.line | type) != "number" then {i: $i, why: "no line"} | bad
          elif (.body | type) != "string" or .body == "" then {i: $i, why: "no body"} | bad
          else . end
        | (.side // "RIGHT") as $side
        | if ($side | IN("RIGHT", "LEFT") | not) then {i: $i, why: "side must be RIGHT or LEFT"} | bad else . end
        | {path, line, side: $side, body}
          + (if (.start_line // null) == null then {}
             elif (.start_line | type) != "number" or .start_line >= .line then {i: $i, why: "start_line must be below line"} | bad
             else {start_line, start_side: (.start_side // $side)} end))
    | {event: $event}
      + (if $body == "" then {} else {body: $body} end)
      + (if length == 0 then {} else {comments: .} end)'
}

cmd_delete_pending() {
  local or="${1:-}" n="${2:-}" id="${3:-}"
  case "$or" in */*) ;; *) say 'usage: delete-pending <owner/repo> <n> <id>'; return 2 ;; esac
  case "$n$id" in ''|*[!0-9]*) say 'usage: delete-pending <owner/repo> <n> <id>'; return 2 ;; esac
  "$GH" api -X DELETE "repos/$or/pulls/$n/reviews/$id" >/dev/null || { say "delete-pending: deleting review $id failed"; return 3; }
}

cmd_post() {
  local or="${1:-}" n="${2:-}" f="${3:-}"
  case "$or" in */*) ;; *) say 'usage: post <owner/repo> <n> <payload file>'; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) say 'usage: post <owner/repo> <n> <payload file>'; return 2 ;; esac
  [ -f "$f" ] || { say "post: no payload file $f"; return 2; }
  jq -e '.event | IN("APPROVE", "REQUEST_CHANGES", "COMMENT")' "$f" >/dev/null 2>&1 || {
    say "post: $f has no event; build it with review.sh payload"; return 2; }
  "$GH" api -X POST "repos/$or/pulls/$n/reviews" --input "$f" --jq '{id, state, html_url}' || {
    say "post: the review was not posted; the payload is still in $f"; return 3; }
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  head)           cmd_head "$@" ;;
  anchor)         cmd_anchor "$@" ;;
  threads)        cmd_threads "$@" ;;
  pending)        cmd_pending "$@" ;;
  payload)        cmd_payload "$@" ;;
  delete-pending) cmd_delete_pending "$@" ;;
  post)           cmd_post "$@" ;;
  *) sed -n '7,25p' "$0" | sed 's/^# *//' >&2; exit 2 ;;
esac
