#!/usr/bin/env bash
# threads-read.sh — read the hi-threads journal: the project a directory belongs to, the open
# threads ranked, and the same as agenda section lines.
#
# Edit shared/threads-read.sh, then copy it into plugins/hi-threads/lib and plugins/hi-crew/lib
# (tests/config_copies_test.sh checks the copies). hi-threads writes the journal and sources this
# file; hi-crew's agenda only reads, so the digest shows the threads when hi-threads is installed.
#
# The journal: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/threads/threads.json
#
#   threads-read.sh list [--all | --project <dir>] [--json]   ranked open threads (default: the
#                                                             cwd's project)
#   threads-read.sh agenda     one JSON line per open thread, as hi-crew agenda.sections print
#   threads-read.sh project [<dir>]
set -uo pipefail
TH_DIR="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/threads"
LEDGER="$TH_DIR/threads.json"

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

# One JSON line per open thread, in the shape hi-crew's agenda.sections commands print; `resume`
# is the line that reopens the session the thread was last worked in.
th_agenda() {
  th_list --json | jq -c '{
    group: (if .waits_on == "person" or .status == "paused" then "you"
            elif .status == "idea" then "later"
            elif .status == "waiting" then "others" else "you" end),
    title: (.title + (if (.ticket // "") != "" then " (" + .ticket + ")" else "" end)),
    next: ((.next // "") + (if (.open_items | length) > 0 then " [+\(.open_items | length) open]" else "" end)),
    open_items, status, waits_on,
    url: (.pr // ""), since: .updated,
    resume: (if (.last_session // "") != "" and (.last_cwd // "") != ""
             then "cd \(.last_cwd | @sh) && claude --resume \(.last_session)" else "" end)}'
}

# Run directly (hi-crew); sourced by threads.sh, which dispatches itself.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    list) shift; th_list "$@" ;;
    agenda) th_agenda ;;
    project) th_project "${2:-$PWD}" ;;
    *) sed -n '2,16p' "$0" >&2; exit 2 ;;
  esac
fi
