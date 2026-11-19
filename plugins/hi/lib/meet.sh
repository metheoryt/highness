#!/usr/bin/env bash
# meet.sh — what a person's own past Claude Code sessions say about how they work: the counting
# and the evidence behind /hi:meet's draft. Read-only against the sessions; it writes only its own
# cache (and nothing at all leaves the machine). The lines a person accepts are written by
# hi-crew's prefs.sh, never here.
#
#   meet.sh prefs                    the path of hi-crew's prefs.sh (fails without hi-crew)
#   meet.sh dir                      the cache dir (the draft goes there too)
#   meet.sh sources                  the Claude Code config dirs read, one per line: CLAUDE_CONFIG_DIR,
#                                    ~/.claude and every config dir Orca uses (setup.sh config-dirs)
#   meet.sh scan [--days N]          read <dir>/projects/*/*.jsonl of the last N days (default 60),
#                                    keep the person's own turns, write the cache, print `counts`
#   meet.sh counts                   kind<TAB>count<TAB>sessions<TAB>projects, one row per kind:
#                                    sessions, said, correction, rejection, denial, interrupt,
#                                    repeat, skill
#   meet.sh list <kind> [--limit N]  the evidence, newest first (default 40 rows), TSV:
#                                    correction|rejection|denial|interrupt|said:
#                                      session, date, project, detail, quote
#                                    repeat:  sessions, first date, last date, sessions (ids), quote
#                                    skill:   skill, typed, by the agent, sessions
#   meet.sh sample [--n N]           the sessions worth reading in full (default 6), most
#                                    corrections and rejections first, one per project before a
#                                    second: session, date, project, score, turns
#   meet.sh show <session>           one session condensed: the person's turns, the agent's text
#                                    (cut short) and one line per tool call, marked when rejected
#   meet.sh check <draft>            every numbered line of the draft has evidence, and each
#                                    evidence line names a scanned session, one of its dates and a
#                                    quote of the person's own words in it that the scrub leaves as
#                                    is; exit 1 with one line per problem
#   meet.sh accept <draft> <numbers> [--section preferences|team]
#                                    the accepted lines of a section (default preferences), for
#                                    `prefs.sh diff|write`: the rule, then a source tag
#                                    `<!-- hi:meet <session> <date> -->`. <numbers> is `1,3`,
#                                    `all` or `none`; nothing accepted prints nothing
#   meet.sh rule <draft> <n> [--root R]
#                                    a team-rule candidate as a pull request body: `target: <file>`
#                                    (crew.team_rules read at R, default the cwd) or `target: none`,
#                                    then the rule and counts. No quote, no session id, no path
#   meet.sh clean                    remove the cache
#
# The person's own words: an interactive session's (entrypoint cli) user turns typed by a human
# (`origin.kind` human when present), not meta, not a subagent's, not a compaction summary, a
# command's output, an Orca relay or a dispatched worker's brief; <pasted_content> and
# <system-reminder> blocks are cut out first. Sessions that ran /hi:meet itself are left out.
# Every quote goes through scrub: home paths, emails, URLs, @handles, phone numbers, IP
# addresses and anything shaped like a token or a key are masked. Other people's names cannot be
# masked by pattern: /hi:meet's draft never quotes them.
#
# Cache: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/meet, mode 0700.
# Seams: HI_MEET_DIRS (newline-separated config dirs, replacing the discovery), HI_PREFS (the
# prefs.sh to use), HI_CLAUDE (the claude binary).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/meet"
EV="$DIR/events.jsonl"

die() { printf 'meet: %s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die 'jq is required'

# The masks, shared by every jq program here. Order matters: URLs and emails before handles,
# key=value before the bare token shapes.
SCRUB='
def scrub:
  (if $home != "" then split($home) | join("~") | split($home | gsub("[/.]"; "-")) | join("~") else . end)
  | gsub("(?<a>/(home|Users))/[^/\\s]+"; "~")
  | gsub("[A-Za-z][A-Za-z0-9+.-]*://[^\\s<>\"'"'"'`)]+"; "<url>")
  | gsub("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"; "<email>")
  | gsub("(?<k>(?i)(password|passwd|pwd|token|secret|api[_-]?key|authorization))(?<s>\\s*[:=]\\s*)[^\\s,;]+"; "\(.k)\(.s)<secret>")
  | gsub("(?<k>(?i)bearer)\\s+[A-Za-z0-9._~+/-]{8,}=*"; "\(.k) <secret>")
  | gsub("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]+"; "<secret>")
  | gsub("(ghp|gho|ghs|ghu|github_pat|glpat|xox[abprs]|sk|pk|rk)[-_][A-Za-z0-9_-]{8,}"; "<secret>")
  | gsub("AKIA[0-9A-Z]{12,}"; "<secret>")
  | gsub("(?<![A-Za-z0-9+/_=-])(?=[A-Za-z0-9+/_=-]*[A-Z])(?=[A-Za-z0-9+/_=-]*[a-z])(?=[A-Za-z0-9+/_=-]*[0-9])[A-Za-z0-9+/_=-]{24,}"; "<secret>")
  | gsub("\\b[0-9a-fA-F]{16,}\\b"; "<hex>")
  | gsub("\\b[0-9]{1,3}(\\.[0-9]{1,3}){3}\\b"; "<ip>")
  | gsub("\\+[0-9][0-9 ()-]{7,}[0-9]|\\b[0-9]{10,}\\b"; "<phone>")
  | gsub("(?<![A-Za-z0-9])@[A-Za-z0-9_][A-Za-z0-9_.-]*"; "@<name>");
def one: gsub("[\\s]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
def cut($n): if length > $n then .[0:$n] + "…" else . end;
'

# --- sources

sources() {
  if [ -n "${HI_MEET_DIRS:-}" ]; then printf '%s\n' "$HI_MEET_DIRS"
  else
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && printf '%s\n' "$CLAUDE_CONFIG_DIR"
    printf '%s\n' "$HOME/.claude"
    bash "$HERE/setup.sh" config-dirs 2>/dev/null
  fi | awk 'NF' | while IFS= read -r d; do
    [ -d "$d/projects" ] || continue
    printf '%s\t%s\n' "$(cd -P "$d/projects" 2>/dev/null && pwd -P)" "$d"
  done | awk -F'\t' '$1 != "" && !seen[$1]++ { print $2 }'
}

# --- scan

# One JSON row per line of a transcript that can matter, raw (not yet the person's words).
EXTRACT='
def body: if type == "string" then . elif type == "array" then map(select(type == "object" and .type == "text") | .text // "") | join("\n") else "" end;
def result: if type == "array" then map(if type == "object" then (.text // "") else tostring end) | join("\n") elif type == "string" then . else "" end;
fromjson? // empty
| select(type == "object" and (.sessionId // "") != "" and ((.timestamp // "") | tostring) >= $cut)
| . as $l
| (if .type == "user" then
     if (.message.content | type) == "array" and any(.message.content[]; type == "object" and .type == "tool_result") then
       .message.content[] | select(type == "object" and .type == "tool_result")
       | (.content | result) as $c
       | if ($c | test("doesn.t want to proceed with this tool use")) then
           {t: "rej", id: (.tool_use_id // ""), fb: (($c | capture("the user said:\\s*(?<x>[\\s\\S]*)$") | .x) // "")}
         elif (($l.permissionDecision // {}) | type) == "object" and $l.permissionDecision.decision == "reject" then
           {t: "den", id: (.tool_use_id // ""), src: ($l.permissionDecision.source // "" | tostring),
            why: ($l.permissionDecision.reasonType // $l.permissionDecision.reasonCode // "" | tostring),
            rule: ($l.permissionDecision.ruleSource // "" | tostring), fb: ($c | split("\n") | first // "")}
         else empty end
     else
       {t: "u", raw: (.message.content | body),
        meta: (.isMeta == true or .isSidechain == true or .isCompactSummary == true or .isVisibleInTranscriptOnly == true),
        origin: ((.origin // {}) | if type == "object" then (.kind // "") else "" end)}
     end
   elif .type == "assistant" and .isSidechain != true and ((.message.content // null) | type) == "array" then
     .message.content[] | select(type == "object")
     | if .type == "text" then {t: "a", text: ((.text // "")[0:400])}
       elif .type == "tool_use" then {t: "tu", id: (.id // ""), name: (.name // ""),
                                      skill: (if .name == "Skill" then (.input.skill // "" | tostring) else "" end)}
       else empty end
   else empty end)
| . + {s: $l.sessionId, u: ($l.uuid // "" | tostring), at: ($l.timestamp | tostring), cwd: ($l.cwd // "" | tostring), ep: ($l.entrypoint // "" | tostring), n: input_line_number}
'

# Rows of every session -> the events: one JSON object per line, in session order.
EVENTS='
def clean: gsub("<pasted_content[^>]*>[\\s\\S]*?</pasted_content[^>]*>"; " ")
  | gsub("<system-reminder>[\\s\\S]*?</system-reminder>"; " ") | one;
def machine: test("^(<|Caveat: The messages below|This session is being continued|You hit the usage limit|Please carry out this task from|You have [0-9]+ (new )?orchestration|Your task ID is|You are working inside Orca|=== TASK ===)");
# A session Orca dispatched as a worker: its turns are the coordinator'"'"'s, not the person'"'"'s.
def worker: test("You are (working inside Orca|a dispatched worker)|Your task ID is: ");
def interrupt: test("^\\[Request interrupted by user");
def correction: test("^(no|nope|nah|wrong|stop|wait|undo|revert|again|actually|instead|not (that|this|what|like|yet|now)|don.?t|do not|never|why (did|do|are|is|would)|i (said|told|asked|meant)|that.?s (not|wrong)|нет|неа|не (надо|нужно|так|то|делай|трогай|стоит)|стоп|стой|подожди|погоди|зачем|почему (ты|вы)|я же|я (сказал|просил|говорил)|опять|снова|неправильно|неверно|вместо|отмени|откати|верни|никогда)([\\s,.!:;?)]|$)"; "i");
def project: (.cwd | split("/") | map(select(. != "")) | last // "") | scrub;
[ .[] | select(.ep == "cli" or .ep == "") ]
| (map(select(.t == "tu")) | map({key: .id, value: .name}) | from_entries) as $tools
# A resumed or forked session copies earlier turns under their own uuid: keep each turn once.
| (map(select(.t == "u" and .u != "")) | group_by(.u) | map(sort_by(.at) | first))
  + map(select(.t != "u" or .u == ""))
| group_by(.s)
| map(sort_by(.n))
| map(select(any(.[]; .t == "u" and (.raw | test("<command-name>/?hi:meet</command-name>") or worker)) | not))
| .[]
| . as $rows
| ($rows | map(select(.cwd != "")) | first // $rows[0] | project) as $proj
| [ $rows[]
    | if .t == "u" then
        (.raw | [scan("<command-name>/?([^<\\s]+)</command-name>") | .[0]]) as $typed
        | if ($typed | length) > 0 then $typed[] as $k | {kind: "skill", detail: $k, by: "typed", n, at, s}
          elif .meta or (.origin != "" and .origin != "human") then empty
          else (.raw | clean) as $x
            | if $x == "" then empty
              elif ($x | interrupt) then {kind: "interrupt", n, at, s, quote: ""}
              elif ($x | machine) then empty
              else {kind: "said", n, at, s, quote: $x} end
          end
      elif .t == "rej" then {kind: "rejection", n, at, s, detail: ($tools[.id] // ""), quote: (.fb | clean)}
      elif .t == "den" then
        if (.src | test("^user")) or .why == "rule" or .rule != "" then
          {kind: "denial", n, at, s, detail: ($tools[.id] // "") + " (" + .src + (if .why != "" then ":" + .why else "" end) + ")", quote: (.fb | one)}
        else empty end
      elif .t == "tu" and .skill != "" then {kind: "skill", detail: .skill, by: "agent", n, at, s}
      elif .t == "tu" then {kind: "tool", n, at, s, detail: .name, id}
      elif .t == "a" then {kind: "assistant", n, at, s, quote: (.text | one)}
      else empty end ]
| . as $ev
# The person turn right after an interrupt or a rejection is a correction too; so is one that
# opens with a negation or a redirect, unless it is the session opener.
| (reduce range(0; $ev | length) as $i ({out: [], prev: "", first: true};
    $ev[$i] as $e
    | if $e.kind == "said" then
        .out += [$e + (if .first then {} elif .prev == "interrupt" or .prev == "rejection" then {corr: ("after " + .prev)}
                       elif ($e.quote | correction) then {corr: "opens with a correction"} else {} end)]
        | .prev = "said" | .first = false
      elif $e.kind == "interrupt" or $e.kind == "rejection" then .out += [$e] | .prev = $e.kind
      else .out += [$e] end) | .out)
| .[]
| . + {project: $proj, date: .at[0:10], quote: ((.quote // "") | scrub | cut(400))}
| if .corr then (del(.corr) , (. + {kind: "correction", detail: .corr} | del(.corr))) else . end
'

cmd_scan() {
  local days=60 cut src f seen tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days=${2:-}; shift 2 ;;
      *) die "usage: scan [--days N]" ;;
    esac
  done
  case "$days" in ''|*[!0-9]*) die "scan: --days wants a number, got '$days'" ;; esac
  cut=$(jq -nr --argjson d "$days" '(now - $d * 86400) | todate')
  (umask 077; mkdir -p "$DIR") || die "cannot create $DIR"
  chmod 700 "$DIR" 2>/dev/null
  tmp="$DIR/rows.jsonl.$$"
  : >"$tmp"; : >"$DIR/files.tsv.$$"
  sources >"$DIR/sources.$$"
  while IFS= read -r src; do
    find -H "$src/projects" -mindepth 2 -maxdepth 2 -name '*.jsonl' -mtime "-$((days + 1))" 2>/dev/null
  done <"$DIR/sources.$$" >"$DIR/found.$$"
  # A session reached through two config dirs is read once (the first dir in `sources` order).
  awk '{ b = $0; sub(/.*\//, "", b); sub(/\.jsonl$/, "", b) } !seen[b]++ { print b "\t" $0 }' "$DIR/found.$$" >"$DIR/files.tsv.$$"
  rm -f "$DIR/sources.$$" "$DIR/found.$$"
  while IFS='	' read -r seen f; do
    grep -E '"type":[ ]?"(user|assistant)"' "$f" 2>/dev/null \
      | jq -cR --arg cut "$cut" "$EXTRACT" 2>/dev/null >>"$tmp"
  done <"$DIR/files.tsv.$$"
  if ! jq -cs --arg home "$HOME" "$SCRUB $EVENTS" "$tmp" >"$EV.$$" 2>"$DIR/err.$$"; then
    rm -f "$tmp" "$EV.$$" "$DIR/files.tsv.$$"; die "scan: $(head -1 "$DIR/err.$$")"
  fi
  rm -f "$tmp" "$DIR/err.$$"
  mv "$EV.$$" "$EV" && mv "$DIR/files.tsv.$$" "$DIR/files.tsv"
  printf '%s\t%s\n' "$days" "$cut" >"$DIR/window"
  cmd_counts
}

need_cache() { [ -f "$EV" ] || die 'no scan yet: meet.sh scan'; }

# --- counts / list

cmd_counts() {
  need_cache
  jq -rs '
    def norm: ascii_downcase | gsub("[^[:alnum:]]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    def row($k; $xs): [$k, ($xs | length), ($xs | map(.s) | unique | length), ($xs | map(.project) | unique | length)] | @tsv;
    (map(select(.kind == "said"))) as $said
    | ($said | map(select((.quote | norm | length) >= 15)) | group_by(.quote | norm)
       | map(select((map(.s) | unique | length) >= 2))) as $rep
    | row("sessions"; $said | unique_by(.s)),
      row("said"; $said),
      (("correction", "rejection", "denial", "interrupt") as $k | row($k; map(select(.kind == $k)))),
      ([ "repeat", ($rep | length), ($rep | map(.[].s) | unique | length), ($rep | map(.[].project) | unique | length) ] | @tsv),
      row("skill"; map(select(.kind == "skill")))' "$EV"
}

cmd_list() {
  local kind=${1:-} limit=40
  [ -n "$kind" ] || die 'usage: list <kind> [--limit N]'
  shift
  case "${1:-}" in --limit) limit=${2:-}; shift 2 ;; esac
  case "$limit" in ''|*[!0-9]*) die "list: --limit wants a number" ;; esac
  need_cache
  case "$kind" in
    correction|rejection|denial|interrupt|said)
      jq -rs --arg k "$kind" --argjson n "$limit" '
        map(select(.kind == $k)) | sort_by(.at) | reverse | .[0:$n][]
        | [.s[0:8], .date, .project, (.detail // ""), ((.quote // "") | gsub("[\\t\\n]"; " ") | .[0:200])] | @tsv' "$EV" ;;
    repeat)
      jq -rs --argjson n "$limit" '
        def norm: ascii_downcase | gsub("[^[:alnum:]]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
        map(select(.kind == "said" and ((.quote | norm | length) >= 15)))
        | group_by(.quote | norm)
        | map(select((map(.s) | unique | length) >= 2))
        | sort_by(-(map(.s) | unique | length)) | .[0:$n][]
        | [(map(.s) | unique | length), (map(.date) | min), (map(.date) | max),
           (map(.s[0:8]) | unique | .[0:6] | join(",")), (.[0].quote | gsub("[\\t\\n]"; " ") | .[0:200])] | @tsv' "$EV" ;;
    skill)
      jq -rs --argjson n "$limit" '
        map(select(.kind == "skill")) | group_by(.detail)
        | sort_by(-length) | .[0:$n][]
        | [.[0].detail, (map(select(.by == "typed")) | length), (map(select(.by == "agent")) | length), (map(.s) | unique | length)] | @tsv' "$EV" ;;
    *) die "list: unknown kind '$kind'" ;;
  esac
}

cmd_sample() {
  local n=6
  case "${1:-}" in --n) n=${2:-}; shift 2 ;; esac
  case "$n" in ''|*[!0-9]*) die 'sample: --n wants a number' ;; esac
  need_cache
  jq -rs --argjson n "$n" '
    group_by(.s)
    | map({s: .[0].s, date: (map(.date) | max), project: .[0].project,
           turns: (map(select(.kind == "said")) | length),
           score: ((map(select(.kind == "correction")) | length) * 2
                   + (map(select(.kind == "rejection" or .kind == "denial")) | length) * 3
                   + (map(select(.kind == "interrupt")) | length))})
    | map(select(.turns >= 2 and .score > 0))
    | sort_by(-.score, .date)
    | group_by(.project) | map(to_entries | map(.value + {rank: .key})) | add // []
    | sort_by(.rank, -.score) | .[0:$n][]
    | [.s[0:8], .date, .project, .score, .turns] | @tsv' "$EV"
}

cmd_show() {
  local s=${1:-}
  [ -n "$s" ] || die 'usage: show <session>'
  case "$s" in *[!0-9a-fA-F-]*) die "show: not a session id: $s" ;; esac
  need_cache
  jq -rs --arg s "$s" '
    map(select(.s | startswith($s))) as $e
    | if ($e | map(.s) | unique | length) > 1 then "meet: \($s) names more than one session\n" | halt_error(2)
      elif ($e | length) == 0 then "meet: no scanned session \($s)\n" | halt_error(2) else . end
    | ($e[0] | "# session \(.s[0:8]) · \(.project) · \(.date)"),
      ($e[] | select(.kind != "correction")
       | if .kind == "said" then "person: " + .quote
         elif .kind == "assistant" then "  agent: " + (.quote | .[0:240])
         elif .kind == "tool" then "  tool: " + .detail
         elif .kind == "rejection" then "  REJECTED by the person: " + .detail + (if .quote != "" then " — " + .quote else "" end)
         elif .kind == "denial" then "  DENIED: " + .detail
         elif .kind == "interrupt" then "  (the person interrupted)"
         elif .kind == "skill" then "  skill: " + .detail + " (" + .by + ")"
         else empty end)' "$EV"
}

# --- the draft

# A draft's numbered lines as JSON: {section, num, text, ev: [{s, date, quote}]}. A section is
# `## Preferences` or `## Team rule candidates`; a line is `<n>. <text>`, its evidence the
# indented `- <session> <YYYY-MM-DD> "<quote>"` lines under it.
parse_draft() {
  awk '
    function flush() { if (num != "") print sec "\t" num "\t" text "\t" ev; num = ""; ev = "" }
    /^## / { flush(); h = tolower($0); sec = (h ~ /team/) ? "team" : (h ~ /prefer/) ? "preferences" : "other"; next }
    /^[0-9]+\. / { flush(); num = $1; sub(/\.$/, "", num); text = $0; sub(/^[0-9]+\. +/, "", text); next }
    /^[ \t]+- / && num != "" { l = $0; sub(/^[ \t]+- +/, "", l); gsub(/\t/, " ", l); ev = ev (ev == "" ? "" : "\037") l; next }
    END { flush() }' "$1" \
  | jq -Rc 'split("\t") | {section: .[0], num: (.[1] | tonumber), text: .[2],
      ev: ((.[3] // "") | split("\u001f") | map(select(. != "")
             | (capture("^(?<s>[0-9a-fA-F-]{6,}) +(?<date>[0-9]{4}-[0-9]{2}-[0-9]{2}) +[^\"]*\"(?<quote>.*)\" *$") // {bad: .})))}'
}

cmd_check() {
  local draft=${1:-}
  [ -f "$draft" ] || die 'usage: check <draft>'
  need_cache
  parse_draft "$draft" | jq -rs --slurpfile ev "$EV" --arg home "$HOME" "$SCRUB"'
    def norm: gsub("[\\s]+"; " ") | ltrimstr(" ") | rtrimstr(" ") | ltrimstr("…") | rtrimstr("…");
    ($ev | map(select(.kind == "said" or .kind == "rejection" or .kind == "correction"))) as $words
    | if length == 0 then "the draft has no numbered line" else
      .[] | . as $l | "\($l.section) \($l.num)" as $at
      | if ($l.ev | length) == 0 then "\($at): no evidence line (- <session> <YYYY-MM-DD> \"<quote>\")"
        else $l.ev[]
          | if .bad then "\($at): evidence not in the form - <session> <YYYY-MM-DD> \"<quote>\": \(.bad)"
            else . as $e
              | ($ev | map(select(.s | startswith($e.s)))) as $in
              | if ($in | length) == 0 then "\($at): no scanned session \($e.s)"
                elif ($in | map(.date) | index($e.date)) == null then "\($at): session \($e.s) has no turn on \($e.date)"
                elif ($e.quote | norm) == "" then "\($at): empty quote"
                elif ($e.quote | length) > 160 then "\($at): quote longer than 160 characters"
                elif ($e.quote | scrub) != $e.quote then "\($at): quote carries something the scrub masks (a path, an address, a token, a name handle)"
                elif ([ $words[] | select((.s | startswith($e.s)) and (.quote | norm | contains($e.quote | norm))) ] | length) == 0
                  then "\($at): not the person'"'"'s own words in session \($e.s): \($e.quote)"
                else empty end
            end
        end
      end' | awk 'NF { print; bad = 1 } END { exit bad }'
}

cmd_accept() {
  local draft='' nums='' section=preferences
  while [ $# -gt 0 ]; do
    case "$1" in
      --section) section=${2:-}; shift 2 ;;
      -*) die "unknown argument '$1'" ;;
      *) if [ -z "$draft" ]; then draft=$1; elif [ -z "$nums" ]; then nums=$1; else die 'usage: accept <draft> <numbers> [--section preferences|team]'; fi; shift ;;
    esac
  done
  [ -f "$draft" ] && [ -n "$nums" ] || die 'usage: accept <draft> <numbers|all|none> [--section preferences|team]'
  case "$section" in preferences|team) ;; *) die "accept: --section is preferences or team" ;; esac
  case "$nums" in all|none) ;; *[!0-9,]*) die "accept: numbers are like 1,3 (or all, none), not '$nums'" ;; esac
  [ "$nums" = none ] && return 0
  parse_draft "$draft" | jq -rs --arg sec "$section" --arg nums "$nums" '
    (if $nums == "all" then null else ($nums | split(",") | map(select(. != "") | tonumber)) end) as $want
    | map(select(.section == $sec and ($want == null or (.num as $n | $want | index($n)) != null)))
    | .[] | .text + ((.ev | map(select(.s)) | first) as $e
                     | if $e then " <!-- hi:meet \($e.s[0:8]) \($e.date) -->" else "" end)'
}

cmd_rule() {
  local draft='' num='' root='' target
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root=${2:-}; shift 2 ;;
      -*) die "unknown argument '$1'" ;;
      *) if [ -z "$draft" ]; then draft=$1; elif [ -z "$num" ]; then num=$1; else die 'usage: rule <draft> <n> [--root R]'; fi; shift ;;
    esac
  done
  [ -f "$draft" ] && [ -n "$num" ] || die 'usage: rule <draft> <n> [--root R]'
  case "$num" in *[!0-9]*) die "rule: <n> is a number" ;; esac
  need_cache
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd -P)
  target=$(cd "$root" 2>/dev/null && bash "$HERE/config.sh" get '.crew.team_rules' 2>/dev/null) || target=''
  printf 'target: %s\n\n' "${target:-none}"
  parse_draft "$draft" | jq -rs --argjson n "$num" --slurpfile ev "$EV" --arg home "$HOME" "$SCRUB"'
    (map(select(.section == "team" and .num == $n)) | first) as $l
    | if $l == null then "meet: no team rule candidate \($n) in the draft\n" | halt_error(2) else . end
    | ($l.ev | map(select(.s)) | map(.s) | unique) as $ids
    | ($ev | map(select(.s as $s | any($ids[]; . as $i | $s | startswith($i))))) as $in
    | "## Proposed team rule", "",
      "- " + ($l.text | scrub), "",
      "## Why", "",
      "One person kept asking for this in their own Claude Code sessions: \($ids | length) sessions across \($in | map(.project) | unique | length) projects, \($in | map(.date) | min // "?") to \($in | map(.date) | max // "?") (counted by /hi:meet on their machine). Their words stay with them; written here, it becomes the team'"'"'s rule only if the team agrees in review."'
}

cmd_clean() { rm -rf "$DIR"; }

# hi-crew's prefs.sh, the one writer of preference lines: HI_PREFS, a hi-crew beside this hi (a
# checkout, a skills-dir link), else the hi-crew `claude plugin list` reports enabled.
cmd_prefs() {
  local p
  for p in "${HI_PREFS:-}" "$HERE/../../hi-crew/lib/prefs.sh"; do
    [ -n "$p" ] && [ -f "$p" ] && { (cd "$(dirname "$p")" && printf '%s/prefs.sh\n' "$(pwd -P)"); return 0; }
  done
  p=$("${HI_CLAUDE:-claude}" plugin list --json 2>/dev/null \
      | jq -r '[.[]? | select((.id // "") | startswith("hi-crew@")) | select(.enabled != false) | .installPath // empty] | first // empty' 2>/dev/null)
  [ -n "$p" ] && [ -f "$p/lib/prefs.sh" ] && { printf '%s/lib/prefs.sh\n' "$p"; return 0; }
  die 'no hi-crew here: its prefs.sh writes the lines (install hi-crew@highness)'
}

case "${1:-}" in
  dir) printf '%s\n' "$DIR" ;;
  prefs) cmd_prefs ;;
  sources) sources ;;
  scan) shift; cmd_scan "$@" ;;
  counts) cmd_counts ;;
  list) shift; cmd_list "$@" ;;
  sample) shift; cmd_sample "$@" ;;
  show) shift; cmd_show "$@" ;;
  check) shift; cmd_check "$@" ;;
  accept) shift; cmd_accept "$@" ;;
  rule) shift; cmd_rule "$@" ;;
  clean) cmd_clean ;;
  *) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
