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
#   threads-read.sh agenda     one JSON line per thread, as hi-crew agenda.sections print, after
#                              a live check of the PRs and tickets the threads name (th_check)
#   threads-read.sh check [--all | --project <dir>] [--ttl S] [--wait]
#                              the live check alone: closes the threads whose work landed
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

# The PR references and ticket keys a thread names, as the jq the check and the agenda share: in
# `pr`, "repo#12" or a PR's URL (…/pull/12, …/merge_requests/12); in `ticket`, a key ("AB-3") or
# an issue reference ("repo#4"). Each goes to the command as the journal holds it.
TR_LINKS='def links: [((.pr // "") | [scan("https?://[A-Za-z0-9_.~:/-]+/(?:pull|merge_requests)/[0-9]+"),
                                     (gsub("https?://[^ ,;]+"; "") | scan("[A-Za-z0-9_./-]+#[0-9]+"))]
                       | unique | .[] | {kind: "pr", id: .}),
                      ((.ticket // "") | [scan("[A-Za-z0-9_./-]+#[0-9]+"),
                                         (gsub("[A-Za-z0-9_./-]+#[0-9]+"; "") | scan("[A-Za-z][A-Za-z0-9_]*-[0-9]+"))]
                       | unique | .[] | {kind: "ticket", id: .})];'

# th_check [--all | --project <dir>] [--ttl S] [--wait]: the live check. A thread is a model's
# notes, so a PR it names may have merged and a ticket closed since the note was written. The check
# asks the forge and the tracker through the team's own commands, from the config at the thread's
# project:
#   threads.check.pr      {{PR}} the reference as the journal holds it ("repo#12", or the PR's URL)
#                         → one JSON object, {"state": "open|merged|closed", ...}
#   threads.check.ticket  {{KEY}} a ticket key or "repo#4" → {"state": "<name>", "resolved": true|false}
# each with {{ROOT}} the project, shell-quoted. A thread whose every PR is merged or closed and
# every ticket resolved is closed in the journal (status done, the reason in its history, an
# event with session "check"); every other thread with links carries what was found in `check`.
# A result is kept for --ttl seconds (default 300) under check/; a command that fails, prints no
# such object or runs past HI_THREADS_CHECK_TIMEOUT seconds (default 20) leaves its link
# unchecked, and a thread with an unchecked link stays open. One check at a time: without --wait
# it gives up when another runs. Prints the ids it closed.
th_check() {
  local all=0 proj='' ttl=300 tries=1 now iso links kind id p cmd memo m key f n=0 res closed
  while [ $# -gt 0 ]; do
    case "$1" in --all) all=1 ;; --project) proj=$2; shift ;; --ttl) ttl=$2; shift ;; --wait) tries=150 ;; esac
    shift
  done
  [ -f "$LEDGER" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ "$all" = 1 ] || [ -n "$proj" ] || proj=$(th_project "$PWD")
  _lock check "$tries" || return 0
  mkdir -p "$TH_DIR/check"
  memo=$(mktemp -d)   # the commands, looked up once per project and kind
  now=$(date +%s)
  if [ "$all" = 1 ]; then links=$(th_list --all --json); else links=$(th_list --project "$proj" --json); fi
  links=$(printf '%s\n' "$links" | jq -r "$TR_LINKS"' .project as $p | links[] | [.kind, .id, $p] | @tsv' 2>/dev/null | sort -u)
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    kind=$(printf '%s' "$key" | cut -f1); id=$(printf '%s' "$key" | cut -f2); p=$(printf '%s' "$key" | cut -f3)
    f="$TH_DIR/check/$(printf '%s' "$p" | cksum | cut -d' ' -f1)-$kind-$(printf '%s' "$id" | tr -c 'A-Za-z0-9_.-' '_').json"
    [ "$(jq -r '.at // 0' "$f" 2>/dev/null || echo 0)" -gt $((now - ttl)) ] && continue
    m="$memo/$(printf '%s' "$p|$kind" | cksum | cut -d' ' -f1)"
    [ -f "$m" ] || { (cd "$p" 2>/dev/null && bash "$TR_HERE/config.sh" get ".threads.check.$kind") >"$m" 2>/dev/null || :; }
    cmd=$(cat "$m")
    [ -n "$cmd" ] && [ -d "$p" ] || continue
    _tr_run "$f" "$p" "$kind" "$id" "$cmd" &
    n=$((n + 1)); [ "$n" -lt "${HI_THREADS_CHECK_JOBS:-8}" ] || { wait; n=0; }
  done <<EOF
$links
EOF
  wait
  rm -rf "$memo"
  res=$(cat "$TH_DIR"/check/*.json 2>/dev/null | jq -s -c --argjson since $((now - ttl - 60)) '
    map(select(.at >= $since) | {key: "\(.kind)|\(.project)|\(.id)", value: .r}) | from_entries' 2>/dev/null)
  [ -n "$res" ] || res='{}'
  iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if ! _lock journal; then _unlock check; return 0; fi
  jq --argjson res "$res" --argjson all "$all" --arg proj "$proj" --argjson now "$now" --arg iso "$iso" "$TR_LINKS"'
    def finished: if .kind == "pr" then (.r.state // "" | ascii_downcase | IN("merged", "closed"))
                  else .r.resolved == true end;
    .threads |= map(
      if (.status | IN("done", "dropped")) or ($all == 0 and .project != $proj) then .
      else .project as $p
      | [links[] | . + {r: $res["\(.kind)|\($p)|\(.id)"]}] as $c
      | if ($c | length) == 0 then .
        else .check = {at: $iso, links: [$c[] | select(.r != null) | {kind, id, state: .r.state} + (if .kind == "ticket" then {resolved: (.r.resolved == true)} else {} end)]}
        | if all($c[]; .r != null and finished) then
            .status = "done" | .waits_on = "none" | .next = "" | .open_items = [] | .updated = $iso | .updated_epoch = $now
            | .history = ((.history // []) + [{at: $iso, session: "check",
                note: ("closed by the live check: " + ([$c[] | "\(.id) \(.r.state)"] | join(", ")))}] | .[-20:])
          else . end
        end
      end)' "$LEDGER" >"$LEDGER.check" 2>/dev/null || { rm -f "$LEDGER.check"; _unlock journal; _unlock check; return 0; }
  closed=$(jq -r -n --slurpfile a "$LEDGER" --slurpfile b "$LEDGER.check" '
    ($a[0].threads | map({key: .id, value: .status}) | from_entries) as $old
    | $b[0].threads[] | select(.status == "done" and ($old[.id] // "") != "done") | .id')
  for id in $closed; do
    jq -c -n --arg at "$iso" --arg id "$id" --arg from "$(jq -r --arg id "$id" '.threads[] | select(.id == $id) | .status' "$LEDGER")" \
      '{at: $at, id: $id, from: $from, to: "done", session: "check"}' >>"$TH_DIR/events.jsonl"
  done
  mv "$LEDGER.check" "$LEDGER"
  _unlock journal
  _unlock check
  [ -z "$closed" ] || printf '%s\n' $closed
}

# One link's command, with a watchdog; the result lands in <file> only when it is a JSON object
# with a state.
_tr_run() { # <file> <project> <kind> <id> <command>
  local line pid dog
  line=$(TR_ROOT=$(_tr_q "$2") TR_PR=$(_tr_q "$4") TR_KEY=$(_tr_q "$4") awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { print rep(rep(rep($0, "{{ROOT}}", ENVIRON["TR_ROOT"]), "{{PR}}", ENVIRON["TR_PR"]), "{{KEY}}", ENVIRON["TR_KEY"]) }' <<EOF
$5
EOF
)
  (cd "$2" && sh -c "$line") </dev/null >"$1.tmp" 2>/dev/null &
  pid=$!
  (sleep "${HI_THREADS_CHECK_TIMEOUT:-20}"; kill "$pid" 2>/dev/null) </dev/null >/dev/null 2>&1 &
  dog=$!
  if wait "$pid"; then
    jq -s -c --argjson at "$(date +%s)" --arg k "$3" --arg id "$4" --arg p "$2" '
      map(select(type == "object" and has("state"))) | first // empty
      | {at: $at, kind: $k, id: $id, project: $p, r: .}' "$1.tmp" 2>/dev/null >"$1.new" \
      && [ -s "$1.new" ] && mv "$1.new" "$1"
  fi
  rm -f "$1.tmp" "$1.new"
  kill "$dog" 2>/dev/null
  return 0
}
_tr_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# One JSON line per thread, in the shape hi-crew's agenda.sections commands print, after a live
# check (th_check --wait, --ttl 60): first the threads the check just closed, group "done"; then
# the open ones. `resume` is the line that reopens the session the thread was last worked in;
# `live` what the check found ("repo#12 merged; AB-3 In Review"); `stale` is true for a thread with
# no PR and no ticket untouched for threads.check.stale_days days (default 3), which a digest
# folds into one count.
th_agenda() {
  local proj closed days
  proj=$(th_project "$PWD")
  closed=$(th_check --project "$proj" --ttl "${HI_THREADS_AGENDA_TTL:-60}" --wait)
  days=$( (cd "$proj" 2>/dev/null && bash "$TR_HERE/config.sh" get '.threads.check.stale_days') 2>/dev/null) || days=''
  case "$days" in ''|*[!0-9]*) days=3 ;; esac
  if [ -n "$closed" ] && [ -f "$LEDGER" ]; then
    jq -c --arg ids "$closed" '($ids | split("\n")) as $ids | .threads[] | select(.id | IN($ids[])) | {
      group: "done",
      title: (.title + (if (.ticket // "") != "" then " (" + .ticket + ")" else "" end)),
      next: (.history[-1].note // ""), id, status, url: (.pr // ""), since: .updated}' "$LEDGER"
  fi
  th_list --project "$proj" --json | jq -c --argjson now "$(date +%s)" --argjson days "$days" '{
    group: (if .waits_on == "person" or .status == "paused" then "you"
            elif .status == "idea" then "later"
            elif .status == "waiting" then "others" else "you" end),
    title: (.title + (if (.ticket // "") != "" then " (" + .ticket + ")" else "" end)),
    next: ((.next // "") + (if (.open_items | length) > 0 then " [+\(.open_items | length) open]" else "" end)),
    id, open_items, status, waits_on,
    live: ([.check.links[]? | "\(.id) \(.state)"] | join("; ")),
    stale: ((.pr // "") == "" and (.ticket // "") == "" and (.updated_epoch // 0) < ($now - $days * 86400)),
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
    check) shift; th_check "$@" ;;
    project) th_project "${2:-$PWD}" ;;
    relay) shift; th_relay "$@" ;;
    *) sed -n '2,20p' "$0" >&2; exit 2 ;;
  esac
fi
