#!/usr/bin/env bash
# review.sh — the deterministic parts of /hi-review:review: fetching a PR's head, checking that an
# inline comment's anchor is in the diff, reading threads and the person's pending review, and
# building and posting the one review. The model decides what to say; this decides what GitHub
# will accept, so a test can pin it.
#
#   review.sh head --pr N --base-ref B [--repo O/R]
#                                              BASE<TAB>HEAD: the PR head fetched to refs/hi-review/N,
#                                              and its merge-base with <remote>/B, where <remote>
#                                              is the one whose URL names O/R, else origin
#   review.sh anchor <base> <head> <path> <line|start-end> [RIGHT|LEFT]
#                                              exit 0 when GitHub can anchor a comment there: the
#                                              line (or the whole span) sits in one hunk of the
#                                              diff, on that side (RIGHT, the head, by default)
#   review.sh threads <owner/repo> <n>         the PR's review threads, one JSON object per line:
#                                              path, line, resolved, outdated, truncated,
#                                              comments[] of {author, bot, body, createdAt, url}
#   review.sh pending <owner/repo> <n> <login> the login's own PENDING review as one JSON object
#                                              {id, body, comments[]}; exit 1 when there is none
#   review.sh payload --event E [--body-file F] [--comments-file C]
#                                              the review payload on stdout (see payload below)
#   review.sh delete-pending <owner/repo> <n> <id>
#   review.sh restore-pending <owner/repo> <n> <pending file>
#                                              put a deleted pending review back after a failed post
#   review.sh post <owner/repo> <n> <payload file>
#                                              one POST that creates AND submits the review;
#                                              prints {id, state, html_url}
#
# Deep mode (reference/deep.md):
#   review.sh slices <base> <head> [--max-lines N] [--max-files M]
#                                              the diff cut into slices for reviewer subagents,
#                                              TSV: slice, changed lines, path (git's path order;
#                                              a file is never split)
#   review.sh key <owner/repo> <n>             the hi-crew key of the review: review-<owner>-<repo>-<n>
#   review.sh task --pr-url U --key K --base SHA --head SHA --workspace P [--voice F]
#                                              the review worker's task (reference/deep-task.md)
#   review.sh submit <owner/repo> <n> <payload> --head SHA --login L [--sha256 S] [--seen-pending F]
#                                              post, as the action the person said yes to, only
#                                              what they saw: exit 4 when the PR's head moved, the
#                                              payload is not the one of sha256 S, or their pending
#                                              review is not the one the cards showed
#
# Exit: 0 ok · 1 no (not in the diff, no pending review) · 2 usage or bad input · 3 git/gh failed
#       · 4 changed since the cards (submit)
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${HI_REVIEW_GH:-gh}"

say() { printf 'review.sh: %s\n' "$*" >&2; }

# head: a PRIVATE ref (never a branch, so it cannot collide with anyone's), forced so a force-push
# does not fail the review. Serves fork PRs too, through the base repo. The same ref hi's wt.sh
# review-head writes, so a quick review and a review workspace share one fetch.
#
# The remote is the one whose URL names --repo (the PR's owner/repo), else origin: in a fork
# checkout origin is the fork, which has no pull/N and a stale trunk.
_remote_for() { # <owner/repo>
  local want r u
  want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for r in $(git remote); do
    u=$(git config --get "remote.$r.url") || continue
    u=${u%/}; u=${u%.git}; u=${u##*:}
    u=$(printf '%s\n' "$u" | awk -F/ 'NF >= 2 { print tolower($(NF-1) "/" $NF) }')
    [ "$u" = "$want" ] && { printf '%s\n' "$r"; return 0; }
  done
  printf 'origin\n'
}

cmd_head() {
  local pr='' base_ref='' repo='' rem out head base
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)       pr="${2:-}";       shift 2 ;;
      --base-ref) base_ref="${2:-}"; shift 2 ;;
      --repo)     repo="${2:-}";     shift 2 ;;
      *) say "head: unknown flag $1"; return 2 ;;
    esac
  done
  case "$pr" in ''|*[!0-9]*) say "head: --pr must be a plain PR number (got [$pr])"; return 2 ;; esac
  [ -n "$base_ref" ] || { say 'head: --base-ref <baseRefName> is required'; return 2; }
  rem=origin; [ -n "$repo" ] && rem=$(_remote_for "$repo")
  base_ref=${base_ref#"$rem"/}
  out=$(git fetch --quiet "$rem" "+pull/$pr/head:refs/hi-review/$pr" 2>&1) || {
    say "head: git fetch $rem pull/$pr/head failed: $out"; return 3; }
  git fetch --quiet "$rem" "$base_ref" >/dev/null 2>&1 || true
  head=$(git rev-parse --verify --quiet "refs/hi-review/$pr") || head=''
  [ -n "$head" ] || { say "head: refs/hi-review/$pr did not resolve"; return 3; }
  base=$(git merge-base "$head" "$rem/$base_ref" 2>/dev/null) || base=''
  [ -n "$base" ] || { say "head: no merge-base between $head and $rem/$base_ref"; return 3; }
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
  case "$lo" in ''|*[!0-9]*) say "anchor: line must be N or N-M (got $spec)"; return 2 ;; esac
  case "$hi" in ''|*[!0-9]*) say "anchor: line must be N or N-M (got $spec)"; return 2 ;; esac
  [ "$lo" -le "$hi" ] || { say "anchor: span $spec runs backwards"; return 2; }
  # Buffered, not piped: a failing `git diff` behind a pipe reads as "not in the diff".
  # quotePath=false keeps a non-ASCII name as is; a name with a space gets a trailing TAB on its
  # `+++` line, stripped below.
  d=$(git -c core.quotePath=false diff --no-ext-diff --no-color -M -U3 "$base" "$head") || {
    say "anchor: git diff $base $head failed"; return 3; }
  # Inside a hunk every line is content, even one that reads `+++ x` (an added `++ x`): the hunk's
  # own counts say where it ends, and only outside one is a line a file header.
  printf '%s\n' "$d" | awk -v want="$path" -v lo="$lo" -v hi="$hi" -v side="$side" '
    function span(r, which) {
      s = r; l = 1
      if (index(r, ",") > 0) { s = substr(r, 1, index(r, ",") - 1); l = substr(r, index(r, ",") + 1) }
      if (which == "start") return s + 0
      return l + 0
    }
    ol > 0 || nl > 0 {
      c = substr($0, 1, 1)
      if (c == " " || c == "") { ol--; nl-- } else if (c == "-") ol-- ; else if (c == "+") nl--
      next
    }
    /^diff --git / {
      rest = $0; p = ""
      while ((k = index(rest, " b/")) > 0) { rest = substr(rest, k + 3); p = rest }
      file = p; next
    }
    /^\+\+\+ / { if ($0 != "+++ /dev/null") { file = substr($0, 7); sub(/\t$/, "", file) } next }
    /^@@ / {
      o = $2; n = $3; sub(/^-/, "", o); sub(/^\+/, "", n)
      ol = span(o, "len"); nl = span(n, "len")
      if (file != want) next
      r = (side == "RIGHT") ? n : o
      start = span(r, "start"); len = span(r, "len")
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
        reviewThreads(first: 100) { pageInfo { hasNextPage } nodes { isResolved isOutdated path line originalLine
          comments(first: 50) { totalCount nodes { author { login } body createdAt url } } } } } } }') || {
    say "threads: gh api graphql failed for $or#$n"; return 3; }
  # Past 100 threads or 50 comments in one thread the read is cut, and says so: on stderr for the
  # threads, as `truncated` on the thread for its replies (a cut "still broken" reply matters).
  printf '%s\n' "$raw" | jq -e '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' >/dev/null 2>&1 &&
    say "threads: $or#$n has more than 100 review threads; only the first 100 were read"
  printf '%s\n' "$raw" | jq -c --argjson bots "$bots" '
    def bot: . as $l | ($l == null) or ($l | endswith("[bot]")) or ($bots | any(. == $l));
    .data.repository.pullRequest.reviewThreads.nodes[]
    | {path, line: (.line // .originalLine), resolved: .isResolved, outdated: .isOutdated,
       truncated: ((.comments.totalCount // 0) > (.comments.nodes | length)),
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
    def bad: "payload: comment \(.i): \(.why)\n" | halt_error(2);
    def posint: type == "number" and . >= 1 and . == floor;
    to_entries
    | map(.key as $i | .value
        | if (.path | type) != "string" or .path == "" then {i: $i, why: "no path"} | bad
          elif (.line | posint | not) then {i: $i, why: "no line (a positive whole number)"} | bad
          elif (.body | type) != "string" or .body == "" then {i: $i, why: "no body"} | bad
          else . end
        | (.side // "RIGHT") as $side
        | (.start_side // $side) as $sside
        | if ($side | IN("RIGHT", "LEFT") | not) then {i: $i, why: "side must be RIGHT or LEFT"} | bad
          elif ($sside | IN("RIGHT", "LEFT") | not) then {i: $i, why: "start_side must be RIGHT or LEFT"} | bad
          else . end
        | {path, line, side: $side, body}
          + (if (.start_line // null) == null then {}
             elif (.start_line | posint | not) or .start_line >= .line then {i: $i, why: "start_line must be a positive whole number below line"} | bad
             else {start_line, start_side: $sside} end))
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

# restore-pending: put back the person's pending review (as `pending` printed it) after a failed
# post, as a PENDING review again: the same POST without an `event`. A draft comment with no line
# (outdated) cannot be re-created on a line; it goes back into the body instead, so nothing the
# person wrote is lost.
cmd_restore_pending() {
  local or="${1:-}" n="${2:-}" f="${3:-}" p
  case "$or" in */*) ;; *) say 'usage: restore-pending <owner/repo> <n> <pending file>'; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) say 'usage: restore-pending <owner/repo> <n> <pending file>'; return 2 ;; esac
  [ -f "$f" ] || { say "restore-pending: no file $f"; return 2; }
  p=$(jq -c '
    [.comments[] | select(.line == null) | "\(.path): \(.body)"] as $lost
    | {body: ([(.body // ""), $lost[]] | map(select(. != "")) | join("\n\n"))}
      + {comments: [.comments[] | select(.line != null) | with_entries(select(.value != null))]}
    | if .body == "" then del(.body) else . end' "$f" 2>/dev/null) || { say "restore-pending: $f is not a pending review"; return 2; }
  printf '%s\n' "$p" | "$GH" api -X POST "repos/$or/pulls/$n/reviews" --input - --jq '{id, state}' || {
    say "restore-pending: the draft was not put back; its text is in $f"; return 3; }
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

# slices: a deep review's diff cut into parts one reviewer subagent can hold. Files stay in git's
# path order, so a directory's files sit together; a slice closes when the next file would take
# it past --max-lines changed lines (default 600) or --max-files files (default 20). A file larger
# than the limit is a slice of its own: a file is never split, since an anchor and its context
# must be in one review. A binary file counts 0 lines. A rename is listed by its new path.
cmd_slices() {
  local base="${1:-}" head="${2:-}" maxl=600 maxf=20 d rec a r p n=1 lines=0 files=0 l
  [ -n "$base" ] && [ -n "$head" ] || { say 'usage: slices <base> <head> [--max-lines N] [--max-files M]'; return 2; }
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-lines) maxl="${2:-}"; shift 2 ;;
      --max-files) maxf="${2:-}"; shift 2 ;;
      *) say "slices: unknown flag $1"; return 2 ;;
    esac
  done
  case "$maxl$maxf" in *[!0-9]*) say 'slices: --max-lines and --max-files take whole numbers'; return 2 ;; esac
  [ "$maxl" -gt 0 ] && [ "$maxf" -gt 0 ] || { say 'slices: the limits must be above 0'; return 2; }
  d="$(mktemp "${TMPDIR:-/tmp}/hi-review-slices.XXXXXX")" || { say 'slices: no temp file'; return 3; }
  git diff --no-ext-diff -z --numstat -M "$base" "$head" >"$d" 2>/dev/null || {
    rm -f "$d"; say "slices: git diff $base $head failed"; return 3; }
  # -z numstat: "<added>\t<deleted>\t<path>\0", or for a rename "<added>\t<deleted>\t\0<old>\0<new>\0".
  while IFS= read -r -d '' rec; do
    a=${rec%%"	"*}; r=${rec#*"	"}; p=${r#*"	"}; r=${r%%"	"*}
    if [ -z "$p" ]; then
      IFS= read -r -d '' p || break   # the old path
      IFS= read -r -d '' p || break   # the new path
    fi
    case "$a$r" in *[!0-9]*) l=0 ;; *) l=$((a + r)) ;; esac
    if [ "$files" -gt 0 ] && { [ $((lines + l)) -gt "$maxl" ] || [ "$files" -ge "$maxf" ]; }; then
      n=$((n + 1)); lines=0; files=0
    fi
    lines=$((lines + l)); files=$((files + 1))
    printf '%s\t%s\t%s\n' "$n" "$l" "$p"
  done <"$d"
  rm -f "$d"
}

# key: the hi-crew key of a deep review of <owner/repo>#<n>: review-<owner>-<repo>-<n>, lowercase,
# every byte outside [a-z0-9._-] a dash, so it is a file name crew.sh accepts.
cmd_key() {
  local or="${1:-}" n="${2:-}"
  case "$or" in */*) ;; *) say 'usage: key <owner/repo> <n>'; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) say 'usage: key <owner/repo> <n>'; return 2 ;; esac
  printf 'review-%s-%s\n' "$(printf '%s' "$or" | tr '[:upper:]' '[:lower:]' | sed 's#/#-#; s/[^a-z0-9._-]/-/g')" "$n"
}

# task: the deep review worker's task (crew.sh dispatch --task-file), from reference/deep-task.md
# with its placeholders filled. Every path is absolute: the worker runs in the review workspace,
# where this plugin may not be loaded.
cmd_task() {
  local pr='' key='' base='' head='' ws='' voice='' n or
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr-url) pr="${2:-}"; shift 2 ;;
      --key) key="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --head) head="${2:-}"; shift 2 ;;
      --workspace) ws="${2:-}"; shift 2 ;;
      --voice) voice="${2:-}"; shift 2 ;;
      *) say "task: unknown flag $1"; return 2 ;;
    esac
  done
  [ -n "$pr" ] && [ -n "$key" ] && [ -n "$base" ] && [ -n "$head" ] && [ -n "$ws" ] || {
    say 'usage: task --pr-url U --key K --base SHA --head SHA --workspace P [--voice F]'; return 2; }
  case "$pr" in https://github.com/*/*/pull/[0-9]*) ;; *) say "task: --pr-url must be a github.com pull request url (got [$pr])"; return 2 ;; esac
  n=${pr##*/pull/}; n=${n%%[!0-9]*}
  or=$(printf '%s\n' "$pr" | sed -n 's#^https://github\.com/\([^/]*\)/\([^/]*\)/pull/.*#\1/\2#p')
  [ -f "$HERE/../reference/deep-task.md" ] || { say "task: missing $HERE/../reference/deep-task.md"; return 3; }
  PLUGIN="$(cd "$HERE/.." && pwd -P)" PR=$pr N=$n REPO=$or KEY=$key BASE=$base HEAD=$head WS=$ws \
  VOICE=${voice:-none} awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { s = $0
      s = rep(s, "{{PLUGIN}}", ENVIRON["PLUGIN"]); s = rep(s, "{{PR}}", ENVIRON["PR"])
      s = rep(s, "{{N}}", ENVIRON["N"]); s = rep(s, "{{REPO}}", ENVIRON["REPO"])
      s = rep(s, "{{KEY}}", ENVIRON["KEY"]); s = rep(s, "{{BASE}}", ENVIRON["BASE"])
      s = rep(s, "{{HEAD}}", ENVIRON["HEAD"]); s = rep(s, "{{WS}}", ENVIRON["WS"])
      s = rep(s, "{{VOICE}}", ENVIRON["VOICE"])
      print s }' "$HERE/../reference/deep-task.md"
}

# submit: the post of a deep review, as the action the person says yes to. It posts only what the
# person saw: exit 4, posting nothing, when the PR's head is no longer --head, the payload's
# sha256 is not --sha256 (the action pins its script, not the files it reads), or the person's own
# pending review is not the one --seen-pending holds (one appeared, changed or went; with no
# --seen-pending, any pending review). A pending review that matches is kept beside the payload,
# deleted (GitHub holds one per person per PR), and put back when the post fails.
cmd_submit() {
  local or="${1:-}" n="${2:-}" f="${3:-}" head='' login='' seen='' sha='' now cur pend id
  local u='usage: submit <owner/repo> <n> <payload> --head SHA --login L [--sha256 S] [--seen-pending F]'
  case "$or" in */*) ;; *) say "$u"; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) say "$u"; return 2 ;; esac
  shift 3 2>/dev/null || { say "$u"; return 2; }
  while [ $# -gt 0 ]; do
    case "$1" in
      --head) head="${2:-}"; shift 2 ;;
      --login) login="${2:-}"; shift 2 ;;
      --sha256) sha="${2:-}"; shift 2 ;;
      --seen-pending) seen="${2:-}"; shift 2 ;;
      *) say "submit: unknown flag $1"; return 2 ;;
    esac
  done
  [ -n "$head" ] && [ -n "$login" ] || { say 'submit: --head and --login are required'; return 2; }
  [ -f "$f" ] || { say "submit: no payload file $f"; return 2; }
  [ -z "$seen" ] || [ -f "$seen" ] || { say "submit: no file $seen"; return 2; }
  # --sha256: the payload is the one the cards were built from, byte for byte.
  if [ -n "$sha" ]; then
    now=$( { command -v sha256sum >/dev/null 2>&1 && sha256sum "$f" || shasum -a 256 "$f"; } | cut -d' ' -f1)
    [ "$now" = "$sha" ] || { say "submit: $f changed since the cards were shown: nothing posted; show the cards again"; return 4; }
  fi
  now=$("$GH" api "repos/$or/pulls/$n" --jq .head.sha) || { say "submit: cannot read the head of $or#$n"; return 3; }
  [ "$now" = "$head" ] || { say "submit: $or#$n moved to $now since the review of $head: nothing posted; review the new head"; return 4; }
  pend="$f.pending.json"
  if cur=$(cmd_pending "$or" "$n" "$login"); then
    [ -n "$seen" ] && [ "$(printf '%s' "$cur" | jq -S -c .)" = "$(jq -S -c . "$seen")" ] || {
      say "submit: your pending review on $or#$n is not the one the cards showed: nothing posted; show the cards again"; return 4; }
    printf '%s\n' "$cur" >"$pend" || { say "submit: cannot keep your pending review in $pend"; return 3; }
    id=$(printf '%s' "$cur" | jq -r .id)
    cmd_delete_pending "$or" "$n" "$id" || return 3
  else
    case $? in 1) ;; *) return 3 ;; esac
    [ -z "$seen" ] || { say "submit: the pending review the cards showed on $or#$n is gone: nothing posted; show the cards again"; return 4; }
  fi
  cmd_post "$or" "$n" "$f" && return 0
  [ ! -f "$pend" ] || cmd_restore_pending "$or" "$n" "$pend" >/dev/null || say "submit: your pending review was not put back; it is in $pend"
  return 3
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  head)           cmd_head "$@" ;;
  anchor)         cmd_anchor "$@" ;;
  threads)        cmd_threads "$@" ;;
  pending)        cmd_pending "$@" ;;
  payload)        cmd_payload "$@" ;;
  delete-pending) cmd_delete_pending "$@" ;;
  restore-pending) cmd_restore_pending "$@" ;;
  post)           cmd_post "$@" ;;
  slices)         cmd_slices "$@" ;;
  key)            cmd_key "$@" ;;
  task)           cmd_task "$@" ;;
  submit)         cmd_submit "$@" ;;
  *) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2; exit 2 ;;
esac
