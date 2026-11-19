#!/usr/bin/env bash
# hold.sh — pause the autostarted workers of an account that crossed the person's reserve, and
# resume them once it is back under the line (highness#36). The start gate is lib/budget.sh; this
# is the same verdict for a worker that is already running.
#
#   hold.sh pass [<config dir>…]   what a watch runs each pass: mark the dirs given and every
#                                  account a worker used in the last hour, then resume
#   hold.sh mark [<config dir>]    budget.sh check; hold → write <dir>/highness-hold, go → remove it
#   hold.sh hook [--worker]        PreToolUse hook: stop this session's turn while its account holds
#   hold.sh resume                 type "continue" into every session the hook stopped whose
#                                  account no longer holds
#   hold.sh held                   the stopped sessions, TSV: workspace, session, config dir, since
#   hold.sh repoint <config dir>   the stopped sessions moved to that account: their markers follow,
#                                  then its budget is checked and they resume (cmd_repoint)
#
# Who is a worker. `--worker` says so: wt.sh dispatch --pretool puts `hold.sh hook --worker` in
# the session's own --settings, so it reaches the autostarted session and nothing else — not a
# session the person resumes there by hand. Without it (the hi-crew plugin's hook, in every
# session) only a hi-crew record with autostart: true for the session's project dir counts.
#
# How it stops. The hook answers {"continue": false}: Claude Code denies that one tool call and
# ends the turn; the session stays open and idle, the work in its tree as it was. Typing into it
# later continues the task (measured on Claude Code 2.1.325). The hook leaves a marker per
# workspace in $STATE/held; resume reads only those, so a session idle for any other reason (an
# open ask) is never typed into.
#
# The hook never reaches the network: it reads the flag a watch pass writes. No flag, or one older
# than HI_HOLD_MAX_AGE_MIN (default 30: the watch stopped writing it), lets the call run, as does
# any error of its own.
#
# State: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/held, log hold.log
# beside it. Fixtures: HI_ORCA (the orca CLI), HI_WT_SH (wt.sh). bash 3.2, BSD tools.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}"
HELD="$STATE/held"
CREW="$STATE/crew"
WT_SH="${HI_WT_SH:-$HERE/../../hi/lib/wt.sh}"
MAXAGE="${HI_HOLD_MAX_AGE_MIN:-30}"
case "$MAXAGE" in ''|*[!0-9]*) MAXAGE=30 ;; esac

dir_of() { local d=${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}; printf '%s' "${d%/}"; }
log() { mkdir -p "$STATE" 2>/dev/null && printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$STATE/hold.log" 2>/dev/null; :; }

# held <dir>: the dir's flag is there and fresh.
held() {
  local f="$1/highness-hold"
  [ -f "$f" ] && [ -z "$(find "$f" -mmin +"$MAXAGE" 2>/dev/null)" ]
}

cmd_mark() {
  local d r tmp
  d=$(dir_of "${1:-}")
  if r=$(bash "$HERE/budget.sh" check "$d" 2>&1); then
    if [ -f "$d/highness-hold" ]; then rm -f "$d/highness-hold"; log "clear	$d	$r"; fi
    printf '%s\n' "$r"; return 0
  fi
  [ -d "$d" ] || { printf '%s\n' "$r"; return 1; }
  tmp="$d/highness-hold.tmp.$$"
  [ -f "$d/highness-hold" ] || log "hold	$d	$r"
  printf '%s\n' "$r" >"$tmp" && mv "$tmp" "$d/highness-hold" || rm -f "$tmp"
  printf '%s\n' "$r"; return 1
}

# key_for <project dir>: the hi-crew key autostarted into it, else exit 1.
key_for() {
  local f
  command -v jq >/dev/null 2>&1 || return 1
  for f in $(grep -lF "\"$1\"" "$CREW"/*.json 2>/dev/null); do
    jq -re --arg p "$1" 'select(.autostart == true and .workspace == $p) | .key' "$f" 2>/dev/null && return 0
  done
  return 1
}

cmd_hook() {
  local worker='' d pd in sid key=''
  [ "${1:-}" = --worker ] && worker=1
  d=$(dir_of)
  # A worker names its account for the passes to check (accounts/, the last hour's count).
  if [ -n "$worker" ]; then
    mkdir -p "$STATE/accounts" 2>/dev/null && printf '%s\n' "$d" >"$STATE/accounts/$(printf '%s' "$d" | cksum | cut -d' ' -f1)" 2>/dev/null
  fi
  held "$d" || return 0
  in=$(cat 2>/dev/null) || in=''
  pd=${CLAUDE_PROJECT_DIR:-}
  [ -n "$pd" ] || pd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null) || pd=''
  [ -n "$pd" ] || pd=$PWD
  pd=$(cd "$pd" 2>/dev/null && pwd -P) || return 0
  if [ -z "$worker" ]; then key=$(key_for "$pd") || return 0; fi
  sid=$(printf '%s' "$in" | jq -r '.session_id // empty' 2>/dev/null) || sid=''
  mkdir -p "$HELD" 2>/dev/null || return 0
  jq -cn --arg w "$pd" --arg s "$sid" --arg d "$d" --arg k "$key" --arg r "$(head -1 "$d/highness-hold" 2>/dev/null)" \
    --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg via "$([ -n "$worker" ] && echo wt || echo crew)" \
    '{workspace: $w, session: $s, config_dir: $d, key: $k, via: $via, since: $t, reason: $r}' \
    >"$HELD/$(printf '%s' "$pd" | cksum | cut -d' ' -f1).json" 2>/dev/null || return 0
  log "stopped	$pd	${sid:-no session id}"
  jq -cn --arg r "$(head -1 "$d/highness-hold" 2>/dev/null)" '{
    continue: false,
    stopReason: ("Paused by the plan budget (hi-crew): " + $r + ". The watch resumes this session when the account is back under its line."),
    hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
      permissionDecisionReason: "Paused by the plan budget: the account is over the reserve its owner keeps for their own sessions. Stop here; you will be told to continue."}}'
}

RESUME_TEXT='The plan budget is back under its line (hi-crew paused you at the reserve). Continue the task where you stopped; nothing was lost.'

# resume_wt <marker json>: type into the session through wt.sh dispatch (a live idle session gets
# it; one that has exited is resumed, with the hook again).
resume_wt() {
  local w s d brief rc=0
  w=$(printf '%s' "$1" | jq -r .workspace); s=$(printf '%s' "$1" | jq -r '.session // ""'); d=$(printf '%s' "$1" | jq -r .config_dir)
  [ -d "$w" ] || return 2
  brief=$(mktemp "${TMPDIR:-/tmp}/hi-hold.XXXXXX") || return 1
  printf '%s\n' "$RESUME_TEXT" >"$brief"
  bash "$WT_SH" dispatch "$w" --brief "$brief" ${s:+--resume "$s"} --config-dir "$d" \
    --pretool "bash $(printf '%q' "$HERE/hold.sh") hook --worker" >/dev/null 2>&1 </dev/null || rc=$?
  rm -f "$brief"
  # 5: typed, but its taking was not seen — a second send could submit it twice
  case "$rc" in 0|5) return 0 ;; *) return 1 ;; esac
}

# resume_crew <marker json>: a hi-crew worker gets it through its dispatch, sent from its Run's
# coordinator terminal (crew.sh event's way).
resume_crew() {
  local k f dis run handle
  k=$(printf '%s' "$1" | jq -r .key)
  f=$(bash "$HERE/crew.sh" get "$k" 2>/dev/null) || return 2
  dis=$(printf '%s' "$f" | jq -r '.dispatch // empty'); run=$(printf '%s' "$f" | jq -r '.run // empty')
  handle=$(cat "$CREW/handles/$run" 2>/dev/null) || handle=''
  [ -n "$dis" ] && [ -n "$handle" ] || return 1
  "${HI_ORCA:-orca}" orchestration send --to "dispatch:$dis" --from "$handle" --type status \
    --subject "$k: plan budget back under its line" --body "$RESUME_TEXT" >/dev/null 2>&1 </dev/null
}

cmd_resume() {
  local m j d via rc
  command -v jq >/dev/null 2>&1 || return 0
  for m in "$HELD"/*.json; do
    [ -f "$m" ] || continue
    j=$(cat "$m"); d=$(printf '%s' "$j" | jq -r '.config_dir // empty' 2>/dev/null) || continue
    [ -n "$d" ] || { rm -f "$m"; continue; }
    held "$d" && continue
    via=$(printf '%s' "$j" | jq -r '.via // "wt"')
    rc=0
    if [ "$via" = crew ]; then resume_crew "$j" || rc=$?; else resume_wt "$j" || rc=$?; fi
    case "$rc" in
      0) rm -f "$m"; log "resumed	$(printf '%s' "$j" | jq -r .workspace)"; printf 'resumed\t%s\n' "$(printf '%s' "$j" | jq -r .workspace)" ;;
      2) rm -f "$m"; log "gone	$(printf '%s' "$j" | jq -r .workspace)" ;;
      *) log "resume-failed	$(printf '%s' "$j" | jq -r .workspace)	kept for the next pass" ;;
    esac
  done
  return 0
}

# repoint <config dir>: after the sessions moved to another account (hi's /hi:account), every
# stopped session waits on that account now: rewrite the markers to it, check its budget, and
# resume what it allows. Without this a marker keeps the old account, so the resume waits for the
# old account's window, and a relaunch would go back to it (highness#106).
cmd_repoint() {
  local d m tmp
  [ $# -eq 1 ] && [ -d "$1" ] || { printf 'usage: hold.sh repoint <config dir>\n' >&2; return 2; }
  command -v jq >/dev/null 2>&1 || return 0
  d=$(dir_of "$1")
  for m in "$HELD"/*.json; do
    [ -f "$m" ] || continue
    tmp="$m.tmp.$$"
    jq --arg d "$d" '.config_dir = $d' "$m" >"$tmp" 2>/dev/null && mv "$tmp" "$m" || rm -f "$tmp"
  done
  log "repoint	$d"
  cmd_mark "$d" >/dev/null || :
  cmd_resume
}

cmd_held() {
  local m
  for m in "$HELD"/*.json; do
    [ -f "$m" ] || continue
    jq -r '[.workspace, .session, .config_dir, .since] | @tsv' "$m" 2>/dev/null
  done
  return 0
}

# pass: the dirs given, every account a worker ran a tool on in the last hour (the hook's
# accounts/), and every account a stopped session waits on — each checked once. Only those: an
# account nothing runs on is not asked (a stale token there would cost a refresh each pass).
cmd_pass() {
  local d f
  {
    for d in "$@"; do printf '%s\n' "$(dir_of "$d")"; done
    for f in $(find "$STATE/accounts" -type f -mmin -60 2>/dev/null); do head -1 "$f"; done
    cmd_held | cut -f3
  } | awk 'NF && !seen[$0]++' | while IFS= read -r d; do cmd_mark "$d" >/dev/null || :; done
  cmd_resume
}

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  pass) cmd_pass "$@" ;;
  mark) cmd_mark "$@" ;;
  hook) cmd_hook "$@"; exit 0 ;;
  resume) cmd_resume ;;
  held) cmd_held ;;
  repoint) cmd_repoint "$@" ;;
  *) printf 'usage: hold.sh pass|mark|hook|resume|held|repoint <config dir>\n' >&2; exit 2 ;;
esac
