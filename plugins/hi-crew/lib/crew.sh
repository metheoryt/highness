#!/usr/bin/env bash
# crew.sh — hi-crew's facts about the ticket workers it started, and what they wait on.
#
# Facts, not status: one JSON file per ticket under the state dir, written when a worker starts
# and as things become known (PR url, ...). Status ("waiting on you", "ready to merge") is derived
# when the digest reads them, from these facts plus Orca and the forge.
#
#   crew.sh dir                       the state dir
#   crew.sh record <KEY> <json>       merge a JSON object into <KEY>'s facts (creates them)
#   crew.sh get <KEY>                 <KEY>'s facts; exit 1 when there are none
#   crew.sh list                      one JSON object per line, every open ticket
#   crew.sh close <KEY>               move <KEY>'s facts to closed/ (the ticket is settled)
#   crew.sh run [<run_id>]            print the person's hi-crew Orca Run id (exit 1: none); with an id, store it
#   crew.sh asks                      what blocks a worker in that Run, TSV: message id, type
#                                     (question | decision_gate | escalation), dispatch id,
#                                     created_at, first line. A question or gate is open while no
#                                     message carries its id as thread_id; an escalation, while its
#                                     dispatch has sent no later worker_done.
#   crew.sh reports                   the latest worker_done per dispatch in that Run, TSV:
#                                     dispatch id, created_at, outcome, subject
#   crew.sh spec --key K --title T [--brief-file F]
#                                     the worker spec for a ticket, from reference/worker-spec.md and
#                                     the config keys crew.process and crew.marker
#   crew.sh orca                      the Orca executable this host should use
#
# State dir: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/crew
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
TEMPLATE="$HERE/../reference/worker-spec.md"
DIR="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/crew"

die() { printf 'crew: %s\n' "$*" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die 'jq is required'; }

# A ticket key becomes a file name: letters, digits, dash, underscore, dot only.
keyfile() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*) die "bad ticket key: '$1'" ;;
  esac
  printf '%s/%s.json\n' "$DIR" "$1"
}

# Same rule as the orchestration skill: ORCA_CLI_COMMAND, then orca-ide on Linux outside an Orca
# terminal (bare `orca` there is the GNOME screen reader), else orca.
orca_cmd() {
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then printf '%s\n' "$ORCA_CLI_COMMAND"; return; fi
  if [ "$(uname -s)" = Linux ] && [ -z "${ORCA_TERMINAL_HANDLE:-}" ]; then echo orca-ide; return; fi
  echo orca
}

cmd_record() {
  [ $# -eq 2 ] || die 'usage: record <KEY> <json>'
  need_jq
  local f tmp now
  f=$(keyfile "$1") || exit 2
  printf '%s' "$2" | jq -e 'type == "object"' >/dev/null 2>&1 || die 'record: the second argument must be a JSON object'
  mkdir -p "$DIR"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp="$f.tmp.$$"
  if [ -f "$f" ]; then
    jq --argjson add "$2" --arg now "$now" '. + $add + {updated_at: $now}' "$f" >"$tmp"
  else
    jq -n --argjson add "$2" --arg key "$1" --arg now "$now" '{key: $key, created_at: $now} + $add + {updated_at: $now}' >"$tmp"
  fi && mv "$tmp" "$f" || { rm -f "$tmp"; die "record: could not write $f"; }
}

cmd_get() {
  [ $# -eq 1 ] || die 'usage: get <KEY>'
  local f; f=$(keyfile "$1") || exit 2
  [ -f "$f" ] || return 1
  cat "$f"
}

cmd_list() {
  need_jq
  local f
  for f in "$DIR"/*.json; do
    [ -f "$f" ] && jq -c . "$f"
  done
  return 0
}

cmd_close() {
  [ $# -eq 1 ] || die 'usage: close <KEY>'
  local f; f=$(keyfile "$1") || exit 2
  [ -f "$f" ] || die "no open facts for $1"
  mkdir -p "$DIR/closed"
  mv "$f" "$DIR/closed/$1.$(date -u +%Y%m%dT%H%M%SZ).json"
}

cmd_run() {
  if [ $# -eq 1 ]; then
    case "$1" in run_*) ;; *) die "not a Run id: '$1'" ;; esac
    mkdir -p "$DIR" && printf '%s\n' "$1" >"$DIR/run"
    return
  fi
  [ -s "$DIR/run" ] || return 1
  head -n 1 "$DIR/run"
}

inbox() {
  local run orca
  run=$(cmd_run) || die 'no hi-crew Run yet (start a ticket first)'
  orca=$(orca_cmd)
  "$orca" orchestration inbox --limit 500 --json --full 2>/dev/null \
    | jq -c --arg run "$run" '(.result.messages // []) | map(select(.run_id == $run))
        | map(. + {dispatch: ((.payload // "{}" | fromjson? // {}) .dispatchId // "")})'
}

cmd_asks() {
  need_jq
  local m; m=$(inbox) || exit $?
  printf '%s' "$m" | jq -r '
    . as $m
    | [ $m[] | select(.thread_id != null and .thread_id != .id) | .thread_id ] as $answered
    | $m[]
    | select(.type == "question" or .type == "decision_gate" or .type == "escalation")
    | select(.id as $id | $answered | index($id) | not)
    | select(.type != "escalation" or
        (. as $e | [ $m[] | select(.type == "worker_done" and .dispatch == $e.dispatch
                                   and .created_at > $e.created_at) ] | length == 0))
    | [ .id, .type, .dispatch, .created_at, ((.body // .subject // "") | split("\n")[0]) ] | @tsv'
}

cmd_reports() {
  need_jq
  local m; m=$(inbox) || exit $?
  printf '%s' "$m" | jq -r '
    [ .[] | select(.type == "worker_done") ] | group_by(.dispatch)[] | max_by(.created_at)
    | [ .dispatch, .created_at, ((.payload // "{}" | fromjson? // {}) .outcome // ""), (.subject // "") ] | @tsv'
}

cmd_spec() {
  local key='' title='' brief_file='' brief='' process marker
  while [ $# -gt 0 ]; do
    case "$1" in
      --key) key=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --brief-file) brief_file=${2:-}; shift 2 ;;
      *) die "spec: unknown argument '$1'" ;;
    esac
  done
  [ -n "$key" ] && [ -n "$title" ] || die 'usage: spec --key K --title T [--brief-file F]'
  keyfile "$key" >/dev/null || exit 2
  [ -f "$TEMPLATE" ] || die "missing $TEMPLATE"
  if [ -n "$brief_file" ]; then
    [ -f "$brief_file" ] || die "no brief file: $brief_file"
    brief=$(cat "$brief_file")
  fi
  process=$(bash "$CONFIG" get '.crew.process') || process='(none configured: use the tracker and forge tools you have, and say in the PR how you checked the work)'
  marker=$(bash "$CONFIG" get '.crew.marker') || marker='(agent)'
  # Placeholders are replaced in a fixed order by awk with literal strings (no regex, no &).
  KEY=$key TITLE=$title BRIEF=$brief PROCESS=$process MARKER=$marker awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { line = $0
      line = rep(line, "{{KEY}}", ENVIRON["KEY"])
      line = rep(line, "{{TITLE}}", ENVIRON["TITLE"])
      line = rep(line, "{{MARKER}}", ENVIRON["MARKER"])
      if (line == "{{BRIEF}}") { print ENVIRON["BRIEF"]; next }
      if (line == "{{PROCESS}}") { print ENVIRON["PROCESS"]; next }
      print line }' "$TEMPLATE"
}

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  dir) printf '%s\n' "$DIR" ;;
  record) cmd_record "$@" ;;
  get) cmd_get "$@" ;;
  list) cmd_list ;;
  close) cmd_close "$@" ;;
  run) cmd_run "$@" ;;
  asks) cmd_asks ;;
  reports) cmd_reports ;;
  spec) cmd_spec "$@" ;;
  orca) orca_cmd ;;
  *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; [ -z "$sub" ] || exit 2 ;;
esac
