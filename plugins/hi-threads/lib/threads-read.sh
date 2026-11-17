#!/usr/bin/env bash
# threads-read.sh — read the hi-threads journal: the project a directory belongs to, the open
# threads ranked, and the same as agenda section lines.
#
# Edit shared/threads-read.sh, then copy it into plugins/hi-threads/lib and plugins/hi-crew/lib
# (tests/config_copies_test.sh checks the copies). hi-threads writes the journal and sources this
# file; hi-crew's agenda reads it, so the digest shows the threads when hi-threads is installed,
# and both relay a thread's decisions to the thread's own session.
#
# The journal: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/threads/threads.json
#
#   threads-read.sh list [--all | --project <dir>] [--json]   ranked open threads (default: the
#                                                             cwd's project)
#   threads-read.sh agenda     one JSON line per open thread, as hi-crew agenda.sections print
#   threads-read.sh project [<dir>]
#   threads-read.sh relay <cwd> <session> <brief file>   give a thread's own session the brief
set -uo pipefail
TR_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    session: (.last_session // ""), cwd: (.last_cwd // ""),
    resume: (if (.last_session // "") != "" and (.last_cwd // "") != ""
             then "cd \(.last_cwd | @sh) && claude --resume \(.last_session)" else "" end)}'
}

# th_relay <cwd> <session> <brief file>: give a thread's own session the brief (the decisions the
# person settled elsewhere) through hi's `wt.sh dispatch <worktree> --resume <session>`, the path
# hi-crew's hold.sh takes to resume a paused session: typed into the live idle agent of that
# worktree, else `claude --resume <session>` in a new terminal there, the brief its first prompt.
# One call, never a retry or a wait. One line on stdout, <outcome><TAB><detail>:
#   sent <terminal>         typed into the live session                              exit 0
#   started <terminal>      resumed in a new terminal of the worktree                exit 0
#   unconfirmed <terminal>  typed, but not seen taken: look there, never resend      exit 0
#   dialog <terminal>       resumed, but it waits on a dialog: answer it there       exit 0
#   busy busy|chat          a turn or a dialog runs there, or a chat: nothing typed  exit 3
#   manual <resume line>    neither worked: the line to run, and the brief to paste  exit 1
# wt.sh's own words go to stderr. HI_WT_SH: wt.sh (default: the hi plugin beside this one).
th_relay() {
  local cwd="${1:-}" sid="${2:-}" brief="${3:-}" wt root out='' rc=0 via handle manual
  [ -n "$cwd" ] && [ -n "$sid" ] && [ -f "$brief" ] || { echo 'relay: <cwd> <session> <brief file>' >&2; return 2; }
  manual="cd $(jq -rn --arg c "$cwd" '$c | @sh') && claude --resume $sid"
  wt="${HI_WT_SH:-$TR_HERE/../../hi/lib/wt.sh}"
  if [ ! -f "$wt" ]; then
    echo "relay: no hi plugin beside this one ($wt) — nothing started" >&2; rc=1
  elif ! root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
    echo "relay: $cwd is not a git work tree — nothing started" >&2; rc=1
  else
    out=$(bash "$wt" dispatch "$root" --resume "$sid" --brief "$brief" </dev/null) || rc=$?
  fi
  via=$(printf '%s\n' "$out" | head -1 | cut -f2); handle=$(printf '%s\n' "$out" | head -1 | cut -f3)
  # 0 with `print`: no Orca and no tmux, so dispatch only printed a line — nothing started.
  case "$rc:$via" in
    0:send) printf 'sent\t%s\n' "$handle" ;;
    0:orca|0:tmux) printf 'started\t%s\n' "$handle" ;;
    5:*) printf 'unconfirmed\t%s\n' "$handle" ;;
    6:*) printf 'dialog\t%s\n' "$handle" ;;
    3:*) printf 'busy\t%s\n' "${via:-busy}"; return 3 ;;
    *) printf 'manual\t%s\n' "$manual"; return 1 ;;
  esac
}

# Run directly (hi-crew); sourced by threads.sh, which dispatches itself.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    list) shift; th_list "$@" ;;
    agenda) th_agenda ;;
    project) th_project "${2:-$PWD}" ;;
    relay) shift; th_relay "$@" ;;
    *) sed -n '2,17p' "$0" >&2; exit 2 ;;
  esac
fi
