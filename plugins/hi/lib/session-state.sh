#!/usr/bin/env bash
# session-state.sh — what each Claude Code session is doing, from its own hook events.
#
# Edit shared/session-state.sh, then copy it into plugins/hi/lib and plugins/hi-crew/lib
# (tests/config_copies_test.sh checks the copies). hi-crew registers the hooks; hi only reads.
#
# One line per session in ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/sessions/
# <session_id>, tab-separated:
#   state epoch iso turn_epoch tool tool_epoch pid cwd transcript session kind
# An empty field is stored as `-`: bash's read folds runs of tabs, so an empty field would shift
# the rest. `get` prints it empty again.
# state is `working` (UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure), `blocked`
# (Notification permission_prompt or elicitation_dialog; PreToolUse of AskUserQuestion or
# ExitPlanMode, which open a question form) or `idle` (Stop, StopFailure, SessionStart).
# SubagentStop changes nothing: the parent's turn goes on. SessionEnd removes the line.
# kind says which dialog: permission, input (an MCP server's input dialog) or question.
# turn_epoch is when the running turn began; tool and tool_epoch the tool call open now. They
# show a turn or a tool call that has run too long: a hung shell still reads as working, and
# only its age gives it away. pid is the agent's: the hook command passes its own $PPID as
# HI_AGENT_PID, the way Orca's hooks do (a hook command runs in `sh`, whose parent is claude;
# measured on Claude Code 2.1.319).
#
# The hook runs on every tool call, so it stays cheap: no jq, one `head -c` of the payload,
# bash regex for the fields, one `date`, one write.
#
# Reading decides staleness, since no hook fires on every way a turn ends:
#   - a pid that is gone drops the line (a crash, a closed terminal);
#   - with no pid, a line older than HI_STATE_MAX_AGE seconds (default 43200) is not believed;
#   - `working` or `blocked` is not believed when the transcript shows, after the line was
#     written, an interrupt ("[Request interrupted by user…]": Esc fires no Stop), a turn end
#     (turn_duration, stop_hook_summary) or, for `blocked`, a tool result (the dialog was
#     answered; Esc on a permission dialog fires no hook at all, measured on 2.1.316).
# A line that is not believed sends the caller to the screen.
#
#   session-state.sh hook                      hook payload on stdin; never prints, always exit 0
#   session-state.sh get <workspace> [<sid>]   the believed state of the session <sid> when it
#                                              has a line, else of the one session whose cwd is
#                                              <workspace> or under it:
#                                              state<TAB>epoch<TAB>session<TAB>kind<TAB>turn_epoch
#                                              <TAB>tool<TAB>tool_epoch<TAB>iso (exit 0). Exit 1 when
#                                              none is believed, or more than one session works
#                                              there (the caller cannot tell which is its own)
#   session-state.sh list                      every believed line, as stored
set -u
SS_DIR="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/sessions"
SS_TAB=$(printf '\t')

# _ss_field <json> <key>: a string field's value, unescaped only when it needs no unescaping;
# a value with a backslash is refused (empty), so a path is never half-decoded.
_ss_field() {
  local re="\"$2\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]*)\""
  [[ $1 =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
}

ss_hook() {
  local in ev sid f st kind='' tool='' cwd tr now iso turn='' otool='' otep='' tep='' x
  in=$(head -c 16384 2>/dev/null)
  cat >/dev/null 2>&1   # drain the rest: claude may still be writing a large tool_response
  ev=$(_ss_field "$in" hook_event_name); sid=$(_ss_field "$in" session_id)
  case "$sid" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  f="$SS_DIR/$sid"
  case "$ev" in
    UserPromptSubmit|PostToolUse|PostToolUseFailure) st=working ;;
    PreToolUse)
      tool=$(_ss_field "$in" tool_name)
      case "$tool" in AskUserQuestion|ExitPlanMode) st=blocked; kind=question ;; *) st=working ;; esac ;;
    Notification)
      case "$(_ss_field "$in" notification_type)" in
        permission_prompt) st=blocked; kind=permission ;;
        elicitation_dialog) st=blocked; kind=input ;;
        *) return 0 ;;
      esac ;;
    Stop|StopFailure|SessionStart) st=idle ;;
    SessionEnd) rm -f "$f" 2>/dev/null; return 0 ;;
    *) return 0 ;;
  esac
  cwd=$(_ss_field "$in" cwd); tr=$(_ss_field "$in" transcript_path)
  case "$cwd" in /*) ;; *) return 0 ;; esac
  case "$cwd$tr" in *"$SS_TAB"*) return 0 ;; esac
  now=$(date -u '+%s %Y-%m-%dT%H:%M:%S' 2>/dev/null) || return 0
  iso=${now#* }; now=${now%% *}
  # The turn and the open tool call carry over from the previous line.
  if [ -f "$f" ]; then
    IFS="$SS_TAB" read -r x x x turn otool otep x <"$f" 2>/dev/null || :
    [ "$turn" = - ] && turn=''; [ "$otool" = - ] && otool=''; [ "$otep" = - ] && otep=''
  fi
  case "$ev" in
    UserPromptSubmit) turn=$now ;;
    PreToolUse) tep=$now; [ -n "$turn" ] || turn=$now ;;
    PostToolUse|PostToolUseFailure) tool='' ;;
    Notification) tool=$otool; tep=$otep ;;
    *) turn='' ;;
  esac
  [ -d "$SS_DIR" ] || mkdir -p "$SS_DIR" 2>/dev/null || return 0
  x=${HI_AGENT_PID:-}
  case "$x" in *[!0-9]*) x='' ;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "$now" "$iso" "${turn:--}" "${tool:--}" "${tep:--}" \
    "${x:--}" "$cwd" "${tr:--}" "$sid" "${kind:--}" >"$f" 2>/dev/null
  return 0
}

# _ss_ended <transcript> <iso> <state>: exit 0 when the transcript shows, at or after <iso>
# (UTC, to the second), that the turn ended or was interrupted, or (blocked) a tool result.
_ss_ended() {
  local pat='Request interrupted by user|"subtype":"(turn_duration|stop_hook_summary)"'
  [ "$3" = blocked ] && pat="$pat|\"type\":\"tool_result\""
  [ -f "$1" ] || return 1
  tail -n 200 "$1" 2>/dev/null | grep -E "$pat" 2>/dev/null |
    sed -n 's/.*"timestamp":"\([0-9T:-]\{19\}\)[^"]*".*/\1/p' |
    awk -v s="$2" '$0 >= s { f = 1 } END { exit !f }'
}

# _ss_believed <file>: print the line when it is believed; drop it when its agent is gone.
_ss_believed() {
  local line st ep iso pid tr x
  line=$(cat "$1" 2>/dev/null) || return 1
  IFS="$SS_TAB" read -r st ep iso x x x pid x tr x <<EOF
$line
EOF
  case "$st" in working|blocked|idle) ;; *) return 1 ;; esac
  if [ "$pid" != - ]; then
    kill -0 "$pid" 2>/dev/null || { rm -f "$1" 2>/dev/null; return 1; }
  else
    [ $(( $(date -u +%s) - ${ep:-0} )) -le "${HI_STATE_MAX_AGE:-43200}" ] || return 1
  fi
  if [ "$st" != idle ] && _ss_ended "$tr" "$iso" "$st"; then return 1; fi
  printf '%s\n' "$line"
}

ss_list() {
  local f
  for f in "$SS_DIR"/*; do [ -f "$f" ] && _ss_believed "$f"; done
  return 0
}

ss_get() {
  local ws="${1:-}" sid="${2:-}" real line hits n
  [ -n "$ws" ] || { echo 'session-state.sh get: <workspace> is required' >&2; return 2; }
  ws=${ws%/}; real=$(cd "$ws" 2>/dev/null && pwd -P) || return 1
  if [ -n "$sid" ] && [ -f "$SS_DIR/$sid" ]; then
    case "$sid" in *[!A-Za-z0-9_-]*) ;; *) line=$(_ss_believed "$SS_DIR/$sid") ;; esac
  fi
  if [ -z "${line:-}" ]; then
    hits=$(ss_list | awk -F'\t' -v a="$ws" -v b="$real" \
      '$8 == a || $8 == b || index($8, a "/") == 1 || index($8, b "/") == 1')
    n=$(printf '%s' "$hits" | grep -c .)
    [ "$n" = 1 ] || return 1
    line=$hits
  fi
  printf '%s\n' "$line" | awk -F'\t' -v OFS='\t' '{ for (i = 1; i <= NF; i++) if ($i == "-") $i = ""
                                                     print $1, $2, $10, $11, $4, $5, $6, $3 }'
}

case "${1:-}" in
  hook) ss_hook; exit 0 ;;
  get) shift; ss_get "$@"; exit $? ;;
  list) ss_list; exit 0 ;;
  *) echo 'usage: session-state.sh hook | get <workspace> [<session>] | list' >&2; exit 2 ;;
esac
