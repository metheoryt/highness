#!/usr/bin/env bash
# brief.sh — the deterministic parts of /hi-review:brief: reading a pull request through the team's
# adapter (or gh), reading the person's review lens, and the journal of what became of each item.
# The model decides what the brief says; this decides where its inputs come from and keeps the
# record a team measures the briefs by.
#
#   brief.sh source <pr>          the PR as one JSON object, saved under the state dir: prints
#                                 <json file><TAB><diff file><TAB><one-line summary>
#   brief.sh lens [--login L]     the review lens: the team's (config review.brief.lens, a command
#                                 that prints it) and the person's own (user config review.lens:
#                                 text, or a path to a file), each under a `# source:` line;
#                                 --login asks the team's command for someone else's; exit 1: none
#   brief.sh log --pr P --item N --kind K --outcome O [--title T] [--note T] [--head SHA]
#                                 append one item's outcome to the journal
#   brief.sh stats [--since YYYY-MM-DD]
#                                 the journal summed up: items by kind and outcome, and the share
#                                 that led somewhere (discussed, ticket, change)
#   brief.sh journal              the journal's path
#
# The source adapter (config review.brief.source) is a shell command with {{PR}} (the argument,
# quoted) and {{ROOT}} (the team file's root, quoted) filled in, run from that root. It prints one
# JSON object:
#   {repo, number, url, title, body, author, state: open|closed|merged, draft, head, base,
#    diff: "<unified diff>",
#    reviews:  [{author, bot, state, body, at}],
#    threads:  [{path, line, comments: [{author, bot, body, at, url}]}],
#    comments: [{author, bot, body, at}]}
# Unset → gh, for a GitHub PR. The lens command gets {{LOGIN}} (quoted, empty for the person
# themselves) and {{ROOT}}, and prints the lens as text; empty output means none.
#
# Journal: JSON lines at ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/review/
# briefs.jsonl: {at, pr, head, item, kind, outcome, title, note}. It stays on the machine.
#   kind     lens (picked by the lens) · outside (picked outside it, so the lens does not narrow)
#            · clash (where people's reviews agree or disagree) · bold (one change that closes
#            several past problems) · finding (a defect the agent found that no one raised
#            before, verified by a second pass; counted apart from the items) · empty (the brief
#            had nothing for the person; item 0)
#   outcome  discussed (became a review comment or a talk) · ticket · change (the author changed
#            the code) · skipped (no reaction) · not_interesting (the person said so)
#
# Exit: 0 ok · 1 none (no lens, empty journal) · 2 usage or bad input · 3 the source failed
set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
GH="${HI_REVIEW_GH:-gh}"
STATE="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/review"
JOURNAL="$STATE/briefs.jsonl"
KINDS='lens outside clash bold finding empty'
OUTCOMES='discussed ticket change skipped not_interesting'

say() { printf 'brief.sh: %s\n' "$*" >&2; }
need_jq() { command -v jq >/dev/null || { say 'needs jq'; exit 2; }; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
root() { bash "$CONFIG" root 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || pwd -P; }

# {{NAME}} → the value of the env var NAME, for the names given; other text untouched.
fill() { # <name>...
  awk -v names="$*" '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    BEGIN { n = split(names, nm, " ") }
    { for (k = 1; k <= n; k++) $0 = rep($0, "{{" nm[k] "}}", ENVIRON[nm[k]]); print }'
}

one_of() { # <value> <list>
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# --- source -----------------------------------------------------------------------------------

# A GitHub PR through gh, in the adapter's shape. Bots: a Bot account, or a login under review.bots.
gh_source() { # <pr>
  local view diff api n repo bots reviews inline comments
  view=$("$GH" pr view "$1" --json number,title,body,author,url,state,isDraft,headRefOid,baseRefName) || return 3
  diff=$("$GH" pr diff "$1") || return 3
  repo=$(printf '%s' "$view" | jq -r '.url' | sed -n 's#^https://[^/]*/\([^/]*/[^/]*\)/pull/.*#\1#p')
  n=$(printf '%s' "$view" | jq -r .number)
  [ -n "$repo" ] || { say "source: no owner/repo in the PR url"; return 3; }
  api="repos/$repo"
  bots=$(bash "$CONFIG" list .review.bots 2>/dev/null | jq -R . | jq -sc .) || bots='[]'
  reviews=$("$GH" api --paginate "$api/pulls/$n/reviews" | jq -s 'add // []') || return 3
  inline=$("$GH" api --paginate "$api/pulls/$n/comments" | jq -s 'add // []') || return 3
  comments=$("$GH" api --paginate "$api/issues/$n/comments" | jq -s 'add // []') || return 3
  jq -n --argjson v "$view" --arg diff "$diff" --arg repo "$repo" --argjson bots "$bots" \
    --argjson reviews "$reviews" --argjson inline "$inline" --argjson comments "$comments" '
    def who: (.user.login // "");
    def bot: (.user.type == "Bot") or (who | endswith("[bot]")) or (who as $w | $bots | index($w) != null);
    {repo: $repo, number: $v.number, url: $v.url, title: $v.title, body: ($v.body // ""),
     author: $v.author.login, state: ($v.state | ascii_downcase), draft: $v.isDraft,
     head: $v.headRefOid, base: $v.baseRefName, diff: $diff,
     reviews: [$reviews[] | select(.state != "PENDING")
               | {author: who, bot: bot, state, body: (.body // ""), at: .submitted_at}],
     threads: ($inline | group_by(.in_reply_to_id // .id)
               | map({path: .[0].path, line: (.[0].line // .[0].original_line),
                      comments: map({author: who, bot: bot, body, at: .created_at, url: .html_url})})),
     comments: [$comments[] | {author: who, bot: bot, body, at: .created_at}]}'
}

cmd_source() {
  need_jq
  local pr="${1:-}" cmd r out rc slug base err
  [ -n "$pr" ] || { say 'source: <pr> is required (a number, a URL, or what the team adapter takes)'; return 2; }
  r=$(root)
  cmd=$(cd "$r" && bash "$CONFIG" get .review.brief.source 2>/dev/null) || cmd=''
  if [ -n "$cmd" ]; then
    err=$(mktemp) || return 3
    out=$(cd "$r" && sh -c "$(PR=$(q "$pr") ROOT=$(q "$r") fill PR ROOT <<<"$cmd")" 2>"$err"); rc=$?
    [ "$rc" -eq 0 ] || { say "source: the team adapter failed (exit $rc): $(tail -1 "$err")"; rm -f "$err"; return 3; }
    rm -f "$err"
  else
    command -v "$GH" >/dev/null || { say 'source: no review.brief.source and no gh'; return 3; }
    out=$(gh_source "$pr") || { say "source: gh could not read $pr"; return 3; }
  fi
  printf '%s' "$out" | jq -e 'type == "object" and (.number | type == "number") and (.diff | type == "string")' >/dev/null 2>&1 \
    || { say "source: the adapter's output is not a PR object with number and diff"; return 3; }
  slug=$(printf '%s' "$out" | jq -r '"\(.repo // "pr")-\(.number)"' | tr '/ ' '__')
  mkdir -p "$STATE/briefs"
  base="$STATE/briefs/$slug"
  printf '%s' "$out" | jq -r .diff >"$base.diff"
  printf '%s' "$out" | jq 'del(.diff)' >"$base.json"
  printf '%s\t%s\t%s\n' "$base.json" "$base.diff" "$(printf '%s' "$out" | jq -r '
    "\(.repo // "")#\(.number) \(.state // "open")\(if .draft then " draft" else "" end) · \(.title) · by \(.author)"
    + " · \(.reviews // [] | length) reviews, \(.threads // [] | length) threads, \(.comments // [] | length) comments"')"
}

# --- lens -------------------------------------------------------------------------------------

cmd_lens() {
  local login='' r cmd out own err found=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --login) login="${2:-}"; shift 2 ;;
      *) say "lens: unknown flag $1"; return 2 ;;
    esac
  done
  r=$(root)
  cmd=$(cd "$r" && bash "$CONFIG" get .review.brief.lens 2>/dev/null) || cmd=''
  if [ -n "$cmd" ]; then
    err=$(mktemp) || return 2
    # A failing command is said, not taken for "no lens": the brief would quietly run without one.
    out=$(cd "$r" && sh -c "$(LOGIN=$(q "$login") ROOT=$(q "$r") fill LOGIN ROOT <<<"$cmd")" 2>"$err") \
      || { say "lens: the team's command failed: $(tail -1 "$err")"; out=''; }
    rm -f "$err"
    if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
      printf '# source: team\n%s\n' "$out"; found=0
    fi
  fi
  # The person's own lens, only for themselves: it lives in their user file.
  if [ -z "$login" ] && own=$(bash "$CONFIG" get --user .review.lens 2>/dev/null) && [ -n "$own" ]; then
    case "$own" in "~/"*) own="$HOME/${own#"~/"}" ;; esac
    if [ -f "$own" ]; then out=$(cat "$own"); else out=$own; fi
    [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ] && { printf '# source: personal\n%s\n' "$out"; found=0; }
  fi
  [ "$found" -eq 0 ] || say "lens: none${login:+ for $login} (team review.brief.lens, user review.lens)"
  return "$found"
}

# --- journal ----------------------------------------------------------------------------------

cmd_log() {
  need_jq
  local pr='' item='' kind='' outcome='' title='' note='' head=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) pr="${2:-}"; shift 2 ;;
      --item) item="${2:-}"; shift 2 ;;
      --kind) kind="${2:-}"; shift 2 ;;
      --outcome) outcome="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --note) note="${2:-}"; shift 2 ;;
      --head) head="${2:-}"; shift 2 ;;
      *) say "log: unknown flag $1"; return 2 ;;
    esac
  done
  [ -n "$pr" ] || { say 'log: --pr is required'; return 2; }
  case "$item" in ''|*[!0-9]*) say "log: --item must be a number (got [$item])"; return 2 ;; esac
  one_of "$kind" "$KINDS" || { say "log: --kind is one of: $KINDS (got [$kind])"; return 2; }
  one_of "$outcome" "$OUTCOMES" || { say "log: --outcome is one of: $OUTCOMES (got [$outcome])"; return 2; }
  mkdir -p "$STATE"
  jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pr "$pr" --arg head "$head" \
    --argjson item "$item" --arg kind "$kind" --arg outcome "$outcome" --arg title "$title" --arg note "$note" \
    '{at: $at, pr: $pr, head: $head, item: $item, kind: $kind, outcome: $outcome, title: $title, note: $note}' >>"$JOURNAL"
}

cmd_stats() {
  need_jq
  local since=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) since="${2:-}"; shift 2 ;;
      *) say "stats: unknown flag $1"; return 2 ;;
    esac
  done
  [ -s "$JOURNAL" ] || { say "stats: no journal yet ($JOURNAL)"; return 1; }
  # The last word on an item wins: an outcome logged again (skipped, then a ticket) replaces it.
  jq -rs --arg since "$since" '
    map(select(.at >= $since)) | group_by([.pr, .item]) | map(last) as $all
    | def acted: map(select(.outcome == "discussed" or .outcome == "ticket" or .outcome == "change")) | length;
      def share($n; $of): "\($n) of \($of)\(if $of > 0 then " (\($n * 100 / $of | floor)%)" else "" end)";
      ($all | map(select(.kind != "empty" and .kind != "finding"))) as $items
    | ($all | map(select(.kind == "finding"))) as $found
    | "briefs: \($all | map(.pr) | unique | length) PRs, \($items | length) items, \($all | map(select(.kind == "empty")) | length) empty",
      "led somewhere: \(share($items | acted; $items | length))",
      (if ($found | length) > 0 then "findings: \($found | length), acted on: \(share($found | acted; $found | length))" else empty end),
      ($all | map(select(.kind != "empty")) | group_by(.kind)[] | "\(.[0].kind): " + (group_by(.outcome) | map("\(.[0].outcome) \(length)") | join(", ")))
  ' "$JOURNAL"
}

case "${1:-}" in
  source) shift; cmd_source "$@" ;;
  lens) shift; cmd_lens "$@" ;;
  log) shift; cmd_log "$@" ;;
  stats) shift; cmd_stats "$@" ;;
  journal) printf '%s\n' "$JOURNAL" ;;
  *) say 'usage: brief.sh source <pr> | lens [--login L] | log ... | stats [--since D] | journal'; exit 2 ;;
esac
