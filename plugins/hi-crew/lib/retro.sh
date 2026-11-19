#!/usr/bin/env bash
# retro.sh — the short retro the coordinator runs on a ticket before `crew.sh close <KEY>`.
#
# The coordinator runs it in its own session (no headless job, no timer, no other account);
# reference/retro.md is the procedure. This script does the mechanical parts:
#
#   retro.sh gather <KEY>                 what to read, as one bounded bundle: the ticket's facts,
#                                         its spec, PR and ticket, the worker's transcript and the
#                                         signals in it (tool errors, asks, interrupts, stalls),
#                                         the denial log's lines for its session, the ticket's
#                                         choice records. Each part says "none" or "not found"
#                                         on its own: a missing part never stops the retro
#   retro.sh file <KEY> <findings.json>   file at most 3 findings, a JSON array of
#                                         {"kind": "tool|brief|decision", "title", "body",
#                                          "repo"?, "dup"?}. Each is filed once: deduplicated
#                                         against open items, else created. One line per finding,
#                                         kind<TAB>title<TAB>result, where result is the created
#                                         key or URL, "dup <key>", or "failed: <why>" (exit 1)
#   retro.sh comment <KEY> [<note file>]  post the retro comment on the ticket: its first line is
#                                         `<!-- hi:retro -->` (so a readout can count retros), then
#                                         the marker, what was filed (or "no findings") and the
#                                         note. Records retro_at in the facts; `crew.sh close` warns
#                                         when it is missing
#
# Where findings go: the config command crew.retro_sink, read at the ticket's root, with
# {{KIND}} {{TITLE}} {{BODY_FILE}} {{TICKET}} {{ROOT}} replaced by shell-quoted values. It prints
# the created key or URL, or `dup <key>` when an open item already says it (its last output line
# counts). Unset: GitHub issues through gh, deduplicated by title against the open issues, in
#   - the finding's own "repo" (owner/repo: a tool fault goes to the tool's repo);
#   - for kind "brief" (a gap in the worker spec), the repo this plugin came from;
#   - else the root's own repo. Kind "decision" gets the label needs-decision when the repo has it.
# A finding with "dup" set (the coordinator found the open item itself) is not filed again.
# Bodies are measured facts, never a person's words; $HOME in them becomes ~ before filing.
#
# The denial log: JSON lines at ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/
# denials.jsonl (HI_RETRO_DENIALS overrides), one object per denial with at least "session" or
# "cwd"; the retro keeps the lines of the worker's session or workspace. Absent: "no denial log".
#
# Proposed preference lines and team-rule drafts from the choice records (the `choices` part of
# the bundle) are lib/prefs.sh's; this script only hands those records over.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
CREW="$HERE/crew.sh"
STATE="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}"
DIR="$STATE/crew"
MAX=3
LINES=${HI_RETRO_LINES:-20}            # at most this many lines per kind of signal
STALL=${HI_RETRO_STALL_MIN:-15}        # a gap of this many minutes in the transcript is a stall

die() { printf 'retro: %s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die 'jq is required'

# One shell word: 'it''s' -> 'it'\''s'.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The ticket's facts, open or the latest closed copy.
facts() { # <KEY>
  bash "$CREW" get "$1" 2>/dev/null && return 0
  local f; f=$(ls -1 "$DIR/closed/$1".*.json 2>/dev/null | tail -1)
  [ -n "$f" ] && cat "$f"
}
fact() { printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty | if type == "string" then . else tojson end'; }

# owner/repo of a checkout's github.com origin; nothing for any other forge.
gh_slug() { # <dir>
  local u; u=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
  case "$u" in *github.com[:/]*) ;; *) return 1 ;; esac
  u=${u%/}; u=${u%.git}; u=${u#*github.com}; u=${u#[:/]}
  case "$u" in */*) printf '%s\n' "$u" ;; *) return 1 ;; esac
}

# --- gather

# The worker's transcript: the facts' own `transcript`, else the session line whose cwd is the
# workspace, else the newest transcript Claude Code keeps for that directory in a known config dir.
transcript() { # <facts json>
  local t ws f slug d
  t=$(fact "$1" transcript); [ -n "$t" ] && [ -f "$t" ] && { printf '%s\n' "$t"; return 0; }
  ws=$(fact "$1" workspace); [ -n "$ws" ] || return 1
  for f in "$STATE"/sessions/*; do
    [ -f "$f" ] || continue
    t=$(awk -F'\t' -v ws="$ws" '$8 == ws || index($8, ws "/") == 1 { print $9; exit }' "$f")
    [ -n "$t" ] && [ "$t" != - ] && [ -f "$t" ] && { printf '%s\n' "$t"; return 0; }
  done
  slug=$(printf '%s' "$ws" | sed 's|[/.]|-|g')
  for d in ${HI_RETRO_CONFIG_DIRS:-"${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude" "${XDG_CONFIG_HOME:-$HOME/.config}"/orca/claude-profiles/*/home}; do
    [ -n "$d" ] && [ -d "$d/projects/$slug" ] || continue
    t=$(ls -1t "$d/projects/$slug"/*.jsonl 2>/dev/null | head -1)
    [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
  done
  return 1
}

# The signals of a transcript, TSV: kind, time, tool, what, detail. Kinds: error (a tool call that
# failed: a denied or failed command), ask (a question to a person), interrupt, stall (a gap of
# $STALL minutes or more between two entries).
signals() { # <transcript>
  jq -rs --argjson stall "$STALL" --argjson n "$LINES" '
    def short($k): tostring | gsub("[\\s]+"; " ") | .[0:$k];
    def text: if type == "array" then map(.text? // "") | join(" ") else tostring end;
    def epoch: (. // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch null);
    ([ .[] | select(.type == "assistant") | .message.content[]? | select(type == "object" and .type == "tool_use")
       | {key: .id, value: {name, what: ((.input.command // .input.file_path // .input.question // .input) | short(160))}} ]
     | from_entries) as $use
    | ([ .[] | select(.type == "user") | .timestamp as $ts | .message.content[]?
         | select(type == "object" and .type == "tool_result" and .is_error == true)
         | ($use[.tool_use_id] // {name: "?", what: ""}) as $u
         | ["error", ($ts // ""), $u.name, $u.what, (.content | text | short(240))] ] | .[0:$n][]),
      ([ $use[] | select(.name == "AskUserQuestion" or (.name == "Bash" and (.what | test("orchestration (ask|send .*escalation)"))))
         | ["ask", "", .name, .what, ""] ] | .[0:$n][]),
      ([ .[] | select(.type == "user") | .timestamp as $ts | (.message.content | text)
         | select(test("\\[Request interrupted")) | ["interrupt", ($ts // ""), "", "", short(120)] ] | .[0:$n][]),
      ([ .[] | select(.timestamp != null) | {ts: .timestamp, e: (.timestamp | epoch)} | select(.e != null) ]
       | [ range(1; length) as $i | .[$i - 1] as $a | .[$i] as $b
           | select(($b.e - $a.e) >= $stall * 60)
           | ["stall", $a.ts, "", "", "\((($b.e - $a.e) / 60) | floor) min until \($b.ts)"] ] | .[0:$n][])
    | @tsv' "$1" 2>/dev/null
}

denials() { # <facts json> <session id or empty>
  local log="${HI_RETRO_DENIALS:-$STATE/denials.jsonl}" ws
  [ -f "$log" ] || { echo "no denial log at $log"; return 0; }
  ws=$(fact "$1" workspace)
  jq -c --arg s "$2" --arg ws "$ws" '
    select(($s != "" and (.session // "") == $s)
           or ($ws != "" and ((.cwd // "") == $ws or ((.cwd // "") | startswith($ws + "/")))))' "$log" 2>/dev/null \
    | head -n "$LINES" | grep . || echo none
}

cmd_gather() {
  [ $# -eq 1 ] || die 'usage: gather <KEY>'
  local f t sid
  f=$(facts "$1") || die "no facts for $1"
  printf '# retro bundle: %s\n\n## facts\n%s\n\n' "$1" "$(printf '%s' "$f" | jq -c .)"
  # The facts' `spec` (recorded at start), else the copy crew.sh spec keeps for the key.
  printf '## spec\n%s\n\n' "$(t=$(fact "$f" spec); [ -n "$t" ] || t="$(bash "$CREW" dir)/specs/$1.md"
    [ -f "$t" ] && echo "$t" || echo 'not recorded: rebuild it with crew.sh spec, or read the worker'"'"'s first prompt in the transcript')"
  printf '## pr\n%s\n\n' "$(t=$(fact "$f" pr); [ -n "$t" ] && echo "$t (read its body, review threads and CI)" || echo none)"
  printf '## ticket\n%s (read it with its comments)\n\n' "$1"
  if t=$(transcript "$f"); then
    sid=$(basename "$t" .jsonl)
    printf '## transcript\n%s\n\n## signals (kind, time, tool, what, detail)\n' "$t"
    signals "$t" | grep . || echo none
  else
    sid=''
    printf '## transcript\nnot found\n\n## signals\nnone (no transcript)\n'
  fi
  printf '\n## denials\n'; denials "$f" "$sid"
  printf '\n## choices\n'; bash "$CREW" choices "$1" 2>/dev/null | grep . || echo none
}

# --- file

# stdin with the sink's placeholders replaced by $KIND $TITLE $BODY_FILE $TICKET $ROOT.
fill() {
  awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { s = $0
      s = rep(s, "{{KIND}}", ENVIRON["KIND"]); s = rep(s, "{{TITLE}}", ENVIRON["TITLE"])
      s = rep(s, "{{BODY_FILE}}", ENVIRON["BODY_FILE"]); s = rep(s, "{{TICKET}}", ENVIRON["TICKET"])
      print rep(s, "{{ROOT}}", ENVIRON["ROOT"]) }'
}


# The default sink: an open GitHub issue with the same title is a dup; else create one.
gh_file() { # <repo> <kind> <title> <body file>
  local hit url
  hit=$(gh issue list -R "$1" --state open --search "$3 in:title" --json title,url --limit 30 2>/dev/null \
    | jq -r --arg t "$3" '
        def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
        ($t | norm) as $n | .[] | select((.title | norm) == $n) | .url' | head -1)
  [ -n "$hit" ] && { printf 'dup %s\n' "$hit"; return 0; }
  if [ "$2" = decision ]; then
    url=$(gh issue create -R "$1" --title "$3" --body-file "$4" --label needs-decision 2>/dev/null) \
      || url=$(gh issue create -R "$1" --title "$3" --body-file "$4" 2>&1) || { printf 'failed: %s\n' "$(printf '%s' "$url" | tail -1)"; return 1; }
  else
    url=$(gh issue create -R "$1" --title "$3" --body-file "$4" 2>&1) || { printf 'failed: %s\n' "$(printf '%s' "$url" | tail -1)"; return 1; }
  fi
  printf '%s\n' "$url" | tail -1
}

cmd_file() {
  [ $# -eq 2 ] || die 'usage: file <KEY> <findings.json>'
  local key=$1 f root sink n i x kind title repo dup body res line out rc fail=0 results='[]'
  f=$(facts "$key") || die "no facts for $key"
  [ -f "$2" ] || die "no findings file: $2"
  jq -e 'type == "array"' "$2" >/dev/null 2>&1 || die 'findings: not a JSON array'
  n=$(jq length "$2")
  [ "$n" -le "$MAX" ] || die "findings: $n given, at most $MAX: keep the ones that cost the most"
  jq -e 'all(.[]; (.kind | IN("tool", "brief", "decision")) and ((.title // "") != "") and ((.body // "") != ""))' "$2" >/dev/null 2>&1 \
    || die 'findings: each needs kind (tool | brief | decision), title and body'
  root=$(fact "$f" root); [ -n "$root" ] && [ -d "$root" ] || root=$(pwd -P)
  sink=$(cd "$root" && bash "$CONFIG" get '.crew.retro_sink' 2>/dev/null) || sink=''
  body=$(mktemp "${TMPDIR:-/tmp}/hi-retro.XXXXXX") || die 'no temp file'
  BODY_TMP=$body; trap 'rm -f "$BODY_TMP"' EXIT
  i=0
  while [ "$i" -lt "$n" ]; do
    x=$(jq -c ".[$i]" "$2"); i=$((i + 1))
    kind=$(fact "$x" kind); title=$(fact "$x" title); repo=$(fact "$x" repo); dup=$(fact "$x" dup)
    fact "$x" body | awk -v h="$HOME" 'h != "" { while ((p = index($0, h)) > 0) $0 = substr($0, 1, p - 1) "~" substr($0, p + length(h)) } { print }' >"$body"
    if [ -n "$dup" ]; then res="dup $dup"
    elif [ -n "$sink" ]; then
      line=$(printf '%s\n' "$sink" | KIND=$(q "$kind") TITLE=$(q "$title") BODY_FILE=$(q "$body") TICKET=$(q "$key") ROOT=$(q "$root") fill)
      out=$(cd "$root" && sh -c "$line" 2>&1); rc=$?
      res=$(printf '%s\n' "$out" | grep . | tail -1)
      if [ "$rc" -ne 0 ] || [ -z "$res" ]; then res="failed: crew.retro_sink exit $rc${res:+: $res}"; fi
    else
      if [ -z "$repo" ] && [ "$kind" = brief ]; then repo=${HI_RETRO_SPEC_REPO:-$(gh_slug "$HERE/..")}; fi
      [ -n "$repo" ] || repo=$(gh_slug "$root") || repo=''
      if [ -z "$repo" ]; then res='failed: no GitHub repo to file in (set crew.retro_sink, or give the finding a repo)'
      else res=$(gh_file "$repo" "$kind" "$title" "$body"); fi
    fi
    case "$res" in failed:*) fail=1 ;; esac
    printf '%s\t%s\t%s\n' "$kind" "$title" "$res"
    results=$(printf '%s' "$results" | jq -c --arg k "$kind" --arg t "$title" --arg r "$res" '. + [{kind: $k, title: $t, result: $r}]')
  done
  bash "$CREW" get "$key" >/dev/null 2>&1 && bash "$CREW" record "$key" "{\"retro_findings\": $results}"
  return "$fail"
}

# --- comment

cmd_comment() {
  [ $# -ge 1 ] && [ $# -le 2 ] || die 'usage: comment <KEY> [<note file>]'
  local key=$1 f root marker list repo n msg rc
  f=$(facts "$key") || die "no facts for $key"
  root=$(fact "$f" root); [ -n "$root" ] && [ -d "$root" ] || root=$(pwd -P)
  marker=$(cd "$root" && bash "$CONFIG" get '.crew.marker' 2>/dev/null) || marker='(agent)'
  list=$(printf '%s' "$f" | jq -r '(.retro_findings // [])[] | "- \(.kind): \(.title) — \(.result)"')
  msg=$(
    echo '<!-- hi:retro -->'
    if [ -n "$list" ]; then printf '%s Retro of %s: what was filed.\n\n%s\n' "$marker" "$key" "$list"
    else printf '%s Retro of %s: no findings.\n' "$marker" "$key"; fi
    if [ $# -eq 2 ] && [ -s "$2" ]; then echo; cat "$2"; fi
  )
  if (cd "$root" && bash "$CONFIG" get '.tracker.kind' >/dev/null 2>&1); then
    printf '%s\n' "$msg" | bash "$HERE/tracker.sh" --root "$root" comment "$key"; rc=$?
  else
    repo=$(fact "$f" repo); n=${key##*-}
    case "$repo" in */*) ;; *) die "comment: no tracker configured at $root and the facts name no owner/repo" ;; esac
    case "$n" in ''|*[!0-9]*) die "comment: '$key' is not <repo>-<number>" ;; esac
    printf '%s\n' "$msg" | gh issue comment "$n" -R "$repo" --body-file -; rc=$?
  fi
  [ "$rc" -eq 0 ] || die "comment: posting on $key failed (exit $rc)"
  bash "$CREW" get "$key" >/dev/null 2>&1 && bash "$CREW" record "$key" "{\"retro_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
  return 0
}

case "${1:-}" in
  gather) shift; cmd_gather "$@" ;;
  file) shift; cmd_file "$@" ;;
  comment) shift; cmd_comment "$@" ;;
  *) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
