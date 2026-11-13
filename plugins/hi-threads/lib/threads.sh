#!/usr/bin/env bash
# threads.sh — a per-machine journal of work threads, brought up to date after every Claude turn.
#
# A thread is one outcome the person works toward. After each turn the Stop hook starts a
# detached job that reads the session's transcript from its cursor, cuts it down (digest.jq),
# gives it with the project's open threads to a model (prompt.md) and applies the changes the
# model returns. Every session on the machine writes the one journal, so any session can read
# what the others did and left.
#
# State, under ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/threads/:
#   threads.json        {"threads": [ … ]}, written only under the `journal` lock
#   cursors/<session>   the transcript byte offset read so far
#   events.jsonl        one line per status change: at, id, from, to, session
#   log                 the jobs' stderr
#
# Config (highness config.sh): threads.enabled (default true), threads.model (default sonnet),
# threads.comment.lang (en or ru), and threads.comment.commands, read from the user file only
# (see _comments).
#
#   threads.sh hook-stop                Stop hook: payload on stdin; starts the job, prints nothing
#   threads.sh hook-start               SessionStart hook: the project's top open threads as context
#   threads.sh process <transcript> <session> <cwd>
#                                       read from the cursor to the end, update the journal
#   threads.sh replay <transcript> <session> <cwd>
#                                       the same, one turn at a time from byte 0 (backfill, measuring)
#   threads.sh sessions [--days N]      this project's transcripts, oldest first (default 14 days)
#   threads.sh backfill [--days N]      replay each of them that has no cursor yet
#   threads.sh digest <transcript> [<from>]   the cut-down text from byte <from>
#   threads.sh list [--all | --project <dir>] [--json]   ranked threads (default: the cwd's project)
#   threads.sh agenda                   the open threads as hi-crew agenda section lines (JSON)
#   threads.sh project [<dir>]          the project a directory belongs to
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TH_DIR="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/threads"
LEDGER="$TH_DIR/threads.json"
CHUNK_MAX=${HI_THREADS_CHUNK_MAX:-60000}

_cfg() { bash "$HERE/config.sh" get "$1" 2>/dev/null; }
_log() { mkdir -p "$TH_DIR" && printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$TH_DIR/log"; }

# The project: the nearest directory with a repos.txt above the main checkout (an umbrella of
# nested clones), else the main checkout, else the directory itself.
th_project() {
  local d="${1:-$PWD}" common main up
  d=$(cd "$d" 2>/dev/null && pwd -P) || { printf '%s\n' "$1"; return 0; }
  common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=''
  case "$common" in
    */.git) main=${common%/.git} ;;
    '') main=$d ;;
    *) main=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || main=$d ;;
  esac
  up=$main
  while [ -n "$up" ] && [ "$up" != / ]; do
    [ -f "$up/repos.txt" ] && { printf '%s\n' "$up"; return 0; }
    up=$(dirname "$up")
  done
  printf '%s\n' "$main"
}

_repo() { # the main checkout of a directory, or empty
  local c
  c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  case "$c" in */.git) printf '%s\n' "${c%/.git}" ;; *) git -C "$1" rev-parse --show-toplevel 2>/dev/null ;; esac
}

# A mkdir lock; a lock older than two minutes is a dead job's and is taken over.
_lock() { # <name> [tries]
  local l="$TH_DIR/$1.lock" n=${2:-300}
  mkdir -p "$TH_DIR"
  while ! mkdir "$l" 2>/dev/null; do
    if [ -n "$(find "$l" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rm -rf "$l"; continue; fi
    n=$((n - 1)); [ "$n" -gt 0 ] || return 1
    sleep 0.2
  done
}
_unlock() { rmdir "$TH_DIR/$1.lock" 2>/dev/null; }

# Complete lines of <transcript> from byte <from> into <out>; prints the new cursor.
_chunk() { # <transcript> <from> <out>
  local size
  tail -c +"$(($2 + 1))" "$1" >"$3" 2>/dev/null || : >"$3"
  if [ -s "$3" ] && [ "$(tail -c 1 "$3" | od -An -c | tr -d ' ')" != '\n' ]; then
    sed '$d' "$3" >"$3.t" && mv "$3.t" "$3"   # the last line is still being written
  fi
  size=$(wc -c <"$3" | tr -d ' ')
  printf '%s\n' "$(($2 + size))"
}

th_digest() { # <transcript> [<from>]
  local t; t=$(mktemp)
  _chunk "$1" "${2:-0}" "$t" >/dev/null
  jq -r -f "$HERE/digest.jq" "$t" 2>/dev/null
  rm -f "$t"
}

# The model's reply on stdout: a JSON object with `ops`. Input file on $1.
_model() {
  local model out
  model=${HI_THREADS_MODEL:-$(_cfg .threads.model)}; model=${model:-sonnet}
  out=$(cd "$TH_DIR" && HI_THREADS_INNER=1 claude -p --model "$model" --no-session-persistence \
        --tools '' --strict-mcp-config --settings '{"disableAllHooks":true}' \
        --system-prompt "$(cat "$HERE/prompt.md")" <"$1" 2>>"$TH_DIR/log") || return 1
  printf '%s\n' "$out" | sed '/^```/d' | jq -c 'select(type == "object" and (.ops | type) == "array")' 2>/dev/null | tail -1
}

# The threads the model sees: the project's open ones, and the ones closed in the last two days.
_context() { # <project> <session>
  [ -f "$LEDGER" ] || { echo '[]'; return 0; }
  jq -c --arg p "$1" --arg s "$2" --argjson now "$(date +%s)" '
    [.threads[] | select(.project == $p)
     | select((.status | IN("done", "dropped") | not) or ($now - .updated_epoch < 172800))
     | {id, title, status, next, open_items, waits_on, ticket, pr, updated,
        this_session: (.sessions | index($s) != null)}]' "$LEDGER"
}

_apply() { # <ops-json> <session> <cwd> <project>
  local repo now iso
  repo=$(_repo "$3"); now=$(date +%s); iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  _lock journal || { _log "apply: journal lock busy, dropped ops for $2"; return 1; }
  [ -f "$LEDGER" ] || echo '{"threads":[]}' >"$LEDGER"
  jq --argjson ops "$1" --arg s "$2" --arg cwd "$3" --arg p "$4" --arg repo "$repo" \
     --argjson now "$now" --arg iso "$iso" '
    def fields: with_entries(select(.key | IN("title","status","next","open_items","waits_on","ticket","pr")))
                | with_entries(select(.value != null and .value != ""));
    def touch($o): .updated = $iso | .updated_epoch = $now | .last_session = $s | .last_cwd = $cwd
      | .sessions = ((.sessions // []) + [$s] | unique)
      | .repos = ((.repos // []) + (if $repo == "" then [] else [$repo] end) | unique)
      | .history = ((.history // []) + [{at: $iso, session: $s, note: ($o.note // "")}] | .[-20:]);
    reduce ($ops.ops | to_entries[]) as $e (.;
      $e.value as $o
      | if $o.op == "create" then
          .threads += [({id: ("t" + ($now | tostring) + "-" + ($e.key | tostring)), project: $p,
                         created: $iso, status: "active", open_items: [], waits_on: "none",
                         ticket: "", pr: "", next: "", title: ""} + ($o | fields) | touch($o))]
        elif ($o.op == "update" or $o.op == "close") and ($o.id | type) == "string" then
          .threads |= map(if .id == $o.id then
                            (. + ($o | fields)
                             | if $o.op == "close" then .status = ($o.status // "done") else . end
                             | touch($o))
                          else . end)
        else . end)' "$LEDGER" >"$LEDGER.new" 2>>"$TH_DIR/log" || { rm -f "$LEDGER.new"; _unlock journal; return 1; }
  # one event per status change, for whatever acts on a thread going quiet or closing
  jq -c -n --slurpfile a "$LEDGER" --slurpfile b "$LEDGER.new" --arg s "$2" --arg iso "$iso" '
    ($a[0].threads | map({key: .id, value: .status}) | from_entries) as $old
    | $b[0].threads[] | select(.status != ($old[.id] // "new"))
    | {at: $iso, id, from: ($old[.id] // "new"), to: .status, session: $s}' >>"$TH_DIR/events.jsonl" 2>/dev/null
  mv "$LEDGER.new" "$LEDGER"
  _unlock journal
  _comments "$iso"
}

# Secrets never leave in a comment: token-shaped strings are masked.
_scrub() {
  sed -E -e 's/(gh[pousr]_|github_pat_|glpat-|sk-|xox[abp]-|perm:|AKIA)[A-Za-z0-9_.=:-]+/\1***/g' \
         -e 's/[A-Za-z0-9_+\/=-]{40,}/***/g'
}

# A thread that went quiet (paused) or closed since the last comment gets one in its ticket.
# threads.comment.commands (user config only: it runs code) is a list of
#   {"match": "<regex on the ticket key>", "project": "<regex on the project dir>", "command": "…"}
# (either regex may be left out); the first match runs, with the ticket key in HI_THREAD_TICKET, the project in
# HI_THREAD_PROJECT and the comment on stdin. threads.comment.lang: en (default) or ru.
_comments() { # <iso of the apply>
  local cmds lang ids id th key cmd text
  [ -z "${HI_THREADS_NO_COMMENT:-}" ] || return 0   # replay and backfill: history is not news
  cmds=$(bash "$HERE/config.sh" get --user .threads.comment.commands 2>/dev/null) || return 0
  lang=$(_cfg .threads.comment.lang); lang=${lang:-en}
  ids=$(jq -r --arg iso "$1" 'select(.at == $iso and (.to | IN("paused", "done", "dropped"))) | .id' \
        "$TH_DIR/events.jsonl" 2>/dev/null | sort -u)
  for id in $ids; do
    th=$(jq -c --arg id "$id" '.threads[] | select(.id == $id)' "$LEDGER")
    key=$(printf '%s' "$th" | jq -r '.ticket // ""')
    [ -n "$key" ] || continue
    cmd=$(printf '%s' "$cmds" | jq -r --arg k "$key" --arg p "$(printf '%s' "$th" | jq -r .project)" \
          '[.[] | select((.match // "") as $m | $k | test($m))
                | select((.project // "") as $r | $p | test($r))][0].command // empty' 2>/dev/null)
    [ -n "$cmd" ] || continue
    text=$(printf '%s' "$th" | jq -r --arg lang "$lang" '
      (if $lang == "ru" then {paused: "на паузе", done: "сделано", dropped: "отказались",
                              did: "Что сделано", left: "Осталось", next: "Дальше",
                              head: "Журнал агента"}
       else {paused: "paused", done: "done", dropped: "dropped", did: "Done so far",
             left: "Left", next: "Next", head: "Agent journal"} end) as $w
      | (.commented_epoch // 0) as $c
      | "\($w.head): «\(.title)» — \($w[.status])."
        + ([.history[] | select((.at | fromdateiso8601) > $c) | .note | select(. != "")] as $n
           | if ($n | length) > 0 then "\n\n\($w.did):\n" + ($n | map("- " + .) | join("\n")) else "" end)
        + (if (.open_items | length) > 0 and .status == "paused"
           then "\n\n\($w.left):\n" + (.open_items | map("- " + .) | join("\n")) else "" end)
        + (if (.next // "") != "" and .status == "paused" then "\n\n\($w.next): \(.next)" else "" end)' | _scrub)
    if printf '%s\n' "$text" | (cd "$TH_DIR" && HI_THREAD_TICKET=$key HI_THREAD_PROJECT=$(printf '%s' "$th" | jq -r .project) \
         sh -c "$cmd") >>"$TH_DIR/log" 2>&1; then
      _lock journal && {
        jq --arg id "$id" --argjson now "$(date +%s)" \
          '.threads |= map(if .id == $id then .commented_epoch = $now else . end)' "$LEDGER" >"$LEDGER.new" \
          && mv "$LEDGER.new" "$LEDGER"
        _unlock journal; }
    else _log "comment: command failed for $key"; fi
  done
}

# Give one digest to the model and apply its ops. Splits a digest larger than CHUNK_MAX.
_update() { # <digest-file> <session> <cwd> <project>
  local in parts p ops
  [ -s "$1" ] || return 0
  parts=$(mktemp -d)
  awk -v max="$CHUNK_MAX" -v dir="$parts" '
    { if (size > 0 && size + length($0) > max) { n++; size = 0 } ; f = sprintf("%s/%04d", dir, n);
      print > f; size += length($0) + 1 }' "$1"
  for p in "$parts"/*; do
    in=$(mktemp)
    { printf 'THREADS:\n%s\n\nSESSION: %s in %s\n\nACTIVITY:\n' "$(_context "$4" "$2")" "$2" "$3"; cat "$p"; } >"$in"
    if ops=$(_model "$in") && [ -n "$ops" ]; then _apply "$ops" "$2" "$3" "$4"
    else _log "model: no usable reply for $2"; rm -f "$in"; rm -rf "$parts"; return 1; fi
    rm -f "$in"
  done
  rm -rf "$parts"
}

th_process() { # <transcript> <session> <cwd>
  local tr=$1 sid=$2 cwd=$3 cur new chunk dig proj
  [ -f "$tr" ] || return 0
  mkdir -p "$TH_DIR/cursors"
  _lock "s-$sid" 1 || return 0   # a job for this session is running; it loops until the end
  proj=$(th_project "$cwd")
  while :; do
    cur=$(cat "$TH_DIR/cursors/$sid" 2>/dev/null); cur=${cur:-0}
    chunk=$(mktemp); dig=$(mktemp)
    new=$(_chunk "$tr" "$cur" "$chunk")
    [ "$new" -gt "$cur" ] || { rm -f "$chunk" "$dig"; break; }
    jq -r -f "$HERE/digest.jq" "$chunk" >"$dig" 2>/dev/null
    if _update "$dig" "$sid" "$cwd" "$proj"; then echo "$new" >"$TH_DIR/cursors/$sid"
    else rm -f "$chunk" "$dig"; break; fi
    rm -f "$chunk" "$dig"
  done
  _unlock "s-$sid"
}

# Byte offsets where a person's prompt starts: the turn boundaries.
_turns() { # <transcript>
  awk '{ if ($0 ~ /^\{"type":"user"/ || $0 ~ /"type":"user"/) {
           if ($0 ~ /"isMeta":true/ || $0 ~ /"tool_result"/ || $0 ~ /"isSidechain":true/) {} else print off + 0 }
         off += length($0) + 1 }' "$1"
}

th_replay() { # <transcript> <session> <cwd>
  local tr=$1 sid=$2 cwd=$3 proj b prev=0 chunk dig t
  proj=$(th_project "$cwd"); mkdir -p "$TH_DIR"
  export HI_THREADS_NO_COMMENT=1
  t=$(mktemp); LC_ALL=C _turns "$tr" >"$t"; echo "$(wc -c <"$tr" | tr -d ' ')" >>"$t"
  while IFS= read -r b; do
    [ "$b" -gt "$prev" ] || continue
    chunk=$(mktemp); dig=$(mktemp)
    tail -c +"$((prev + 1))" "$tr" | head -c "$((b - prev))" >"$chunk"
    jq -r -f "$HERE/digest.jq" "$chunk" >"$dig" 2>/dev/null
    _update "$dig" "$sid" "$cwd" "$proj" || _log "replay: turn at $prev failed"
    rm -f "$chunk" "$dig"; prev=$b
  done <"$t"
  rm -f "$t"
  mkdir -p "$TH_DIR/cursors"; echo "$prev" >"$TH_DIR/cursors/$sid"
}

# This project's sessions on the machine, oldest first: <transcript><TAB><session><TAB><cwd>.
th_sessions() { # [--days N]
  local days=14 proj f cwd
  [ "${1:-}" = --days ] && days=$2
  proj=$(th_project "$PWD")
  find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/" -mindepth 2 -maxdepth 2 -name '*.jsonl' \
       -mtime -"$days" 2>/dev/null |
  while IFS= read -r f; do
    grep -m1 -q '"entrypoint":"sdk-cli"' "$f" 2>/dev/null && continue
    cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" 2>/dev/null | sed 's/^"cwd":"//; s/"$//')
    [ -n "$cwd" ] && [ -d "$cwd" ] || continue
    [ "$(th_project "$cwd")" = "$proj" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")" "$f" "$(basename "$f" .jsonl)" "$cwd"
  done | sort -n | cut -f2-
}

# Replay every session of this project that has no cursor yet.
th_backfill() { # [--days N]
  local f sid cwd
  th_sessions "$@" | while IFS="$(printf '\t')" read -r f sid cwd; do
    [ -f "$TH_DIR/cursors/$sid" ] && continue
    _log "backfill: $sid"
    th_replay "$f" "$sid" "$cwd"
  done
}

# Ranked: waits on the person, then left with tails, then active, waiting on others, ideas.
th_list() {
  local scope=project proj='' json=0
  while [ $# -gt 0 ]; do
    case "$1" in --all) scope=all ;; --project) proj=$2; shift ;; --json) json=1 ;; esac; shift
  done
  [ -f "$LEDGER" ] || return 0
  [ -n "$proj" ] || proj=$(th_project "$PWD")
  jq -c --arg p "$proj" --arg scope "$scope" '
    def rank: if .waits_on == "person" and .status != "idea" then 0
              elif .status == "paused" then 1 elif .status == "active" then 2
              elif .status == "waiting" then 3 elif .status == "idea" then 4 else 9 end;
    [.threads[] | select($scope == "all" or .project == $p)
     | select(.status | IN("done", "dropped") | not)]
    | sort_by(rank, -(.updated_epoch // 0)) | .[]' "$LEDGER" |
  if [ "$json" = 1 ]; then cat
  else jq -r '[.status, .waits_on, .updated[:10], (.ticket // ""), .title, .next] | @tsv'
  fi
}

# One JSON line per open thread, in the shape hi-crew's agenda.sections commands print.
th_agenda() {
  th_list --json | jq -c '{section: "threads",
    group: (if .waits_on == "person" or .status == "paused" then "you"
            elif .status == "idea" then "later"
            elif .status == "waiting" then "others" else "you" end),
    title: (.title + (if (.ticket // "") != "" then " (" + .ticket + ")" else "" end)),
    next: ((.next // "") + (if (.open_items | length) > 0 then " [+\(.open_items | length) open]" else "" end)),
    url: (.pr // ""), since: .updated}'
}

th_hook_stop() {
  local in tr sid cwd
  [ -z "${HI_THREADS_INNER:-}" ] || { cat >/dev/null; return 0; }
  in=$(cat)
  [ "$(_cfg '.threads.enabled | select(. == false) | "off"')" = off ] && return 0
  tr=$(printf '%s' "$in" | jq -r '.transcript_path // empty' 2>/dev/null)
  sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null)
  cwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)
  case "$sid" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  [ -f "$tr" ] && [ -d "$cwd" ] || return 0
  # headless runs (claude -p: reviewers, judges, nightly jobs) are not the person's work
  case "${CLAUDE_CODE_ENTRYPOINT:-$(grep -m1 -o '"entrypoint":"[^"]*"' "$tr" 2>/dev/null)}" in
    *sdk-cli*) return 0 ;;
  esac
  mkdir -p "$TH_DIR"
  (cd "$cwd" && nohup bash "$HERE/threads.sh" process "$tr" "$sid" "$cwd" </dev/null >>"$TH_DIR/log" 2>&1 &)
  return 0
}

th_hook_start() {
  local top n
  cat >/dev/null 2>&1
  [ -z "${HI_THREADS_INNER:-}" ] || return 0
  [ "$(_cfg '.threads.enabled | select(. == false) | "off"')" = off ] && return 0
  top=$(th_list --json 2>/dev/null | head -5 | jq -r '
    "- [\(.status)\(if .waits_on == "person" then ", waits on you" else "" end)] \(.title)"
    + (if (.ticket // "") != "" then " (\(.ticket))" else "" end)
    + (if (.next // "") != "" then " — next: \(.next)" else "" end)' | cut -c1-300)
  [ -n "$top" ] || return 0
  n=$(th_list --json 2>/dev/null | wc -l | tr -d ' ')
  jq -n -c --arg m "Open work threads in this project, from all sessions on this machine (top 5 of $n, most urgent first; /hi-threads:where shows all):
$top" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
}

cmd=${1:-}; [ $# -gt 0 ] && shift
case "$cmd" in
  hook-stop) th_hook_stop ;;
  hook-start) th_hook_start ;;
  process) th_process "$@" ;;
  replay) th_replay "$@" ;;
  sessions) th_sessions "$@" ;;
  backfill) th_backfill "$@" ;;
  digest) th_digest "$@" ;;
  list) th_list "$@" ;;
  agenda) th_agenda ;;
  project) th_project "${1:-$PWD}" ;;
  *) sed -n '2,28p' "$0" >&2; exit 2 ;;
esac
