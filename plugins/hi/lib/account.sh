#!/usr/bin/env bash
# lib/account.sh — move live agent sessions to the Claude account Orca has selected.
#
# Orca gives each managed Claude account its own config dir (claude-profiles/<id>/home) and
# links the shared parts of it, `projects/` among them, to ~/.claude. So a session's transcript
# is readable under every account, and `claude --resume <id>` continues it on another one
# (measured, highness#106). After `orca account select` a session already running stays on the
# old account. To move it, this script types `/exit` into its Orca pane and then the same
# `claude --resume <id> …` line. The pane's shell starts `claude` through Orca's wrapper
# function, which reads the selected account (ORCA_CLAUDE_PROFILE_POINTER) at every launch.
# The pane keeps its terminal handle, so a hi-crew worker keeps its Dispatch and a coordinator
# its Run. Measured: a worker moved between its ask and the answer got the answer and reported.
#
#   account.sh target                 the selected account: config dir<TAB>email<TAB>org uuid
#   account.sh sessions               live agent sessions in Orca panes, every account, one per line:
#                                     handle<TAB>session<TAB>status<TAB>config dir<TAB>pid<TAB>cwd
#   account.sh lost <from> <to>       claude.ai connectors <from> has and <to> has not, one per line
#   account.sh move [--only <handle|session>]… [--wait <seconds>] [--dry-run]
#                                     move every session not on the selected account (or only
#                                     the ones named), one result row each:
#                                     result<TAB>handle<TAB>session<TAB>detail
#
# move, per session:
#   - waits until it is idle: its own status file says idle and Orca sees its screen idle.
#     It never types into a running turn, where the keys could answer a permission prompt.
#     Still busy after --wait seconds (default 600): `busy`, and it is left where it is.
#   - relaunches it with its own flags (--plugin-dir, the permission mode, --model…) read from
#     its argv, minus any earlier --resume/--continue/--session-id.
#   - claude.ai connectors are per account. One the new account lacks is named in the row and,
#     through --append-system-prompt, to the session itself, so it does not find out mid-task.
#   - waits until the session runs again under the new account (`moved`); else `unconfirmed`:
#     look at the pane.
# The session that runs this script is moved last, in the background, once its turn has ended:
# `self` names it. A session that is not in an Orca pane, or whose pane has no Orca wrapper,
# cannot be relaunched this way (`skipped`).
# Moving to another organization costs the first turn more: Claude cannot reuse thinking written
# under another organization and rereads the session (measured, Claude Code 2.1.328). `target`
# gives the org; the move says so once.
#
# Exit: 0 every session moved (or nothing to move) · 1 a failure · 2 usage · 3 some still busy.
#
#   account.sh restart-mode           Orca's setting "When you switch accounts while Claude is
#                                     running in terminals": ask, restart or keep (Never restart)
#   account.sh select <id|email>      `orca account select` for Claude, only when that setting is
#                                     keep; else exit 4 and select nothing
#
# Why select is guarded (measured, Orca 1.4.265, highness#106): on a switch, Orca restarts the
# Claude sessions it finds in a NEW pane with a new terminal handle. The chat survives, but a
# hi-crew worker's Dispatch is bound to the old handle: orchestration reports the worker lost
# and fails its Dispatch. Under "Always restart" every switch does that; under "Ask" a switch
# made from the status bar opens a dialog where the workers can be unticked, but a switch made
# anywhere else (the CLI included) counts as "Always restart" and restarts with no dialog. Only
# "Never restart" leaves every session in place for `move`. Orca's restart also does not reach
# every pane: two `orca agent launch` panes stayed on the old account (cause not established),
# so `move` is still the way to finish a switch.
#
# Seams: HI_ORCA (orca.sh), HI_PROC (a /proc-shaped fixture dir: <pid>/environ, <pid>/cmdline,
# <pid>/stat), HI_MOVE_EXIT_WAIT / HI_MOVE_START_WAIT (seconds to wait for the old process to
# end and the new one to appear; default 20 and 90), HI_ACCOUNT_SELF (the pid that counts as
# this session; default the closest claude ancestor), HI_ACCOUNT_DETACH=0 (move this session in
# the foreground, for tests). bash 3.2, BSD tools.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCA_SH="$HERE/orca.sh"
TAB=$(printf '\t')
ORCA=''

say() { printf 'account: %s\n' "$*" >&2; }
die() { say "$*"; exit "${2:-1}"; }

usage() {
  cat >&2 <<'U'
usage: account.sh target | sessions | lost <from dir> <to dir>
       account.sh move [--only <handle|session>]… [--wait <seconds>] [--dry-run]
       account.sh restart-mode | select <id|email>
U
  exit 2
}

ORCA_STATE_NAME=account
. "$HERE/orca-state.sh"

# Orca's default, when the setting was never changed, is ask.
cmd_restart_mode() {
  local doc m
  doc=$(orca_state_doc settings) || return 1
  m=$(printf '%s\n' "$doc" | jq -r '.claudeAccountSwitchRunningSessions // "ask"' 2>/dev/null) \
    || { say "cannot read Orca's settings"; return 1; }
  case "$m" in
    ask|restart|keep) printf '%s\n' "$m" ;;
    *) say "unknown value of Orca's account-switch setting: $m"; return 1 ;;
  esac
}

cmd_select() {
  [ $# = 1 ] && [ -n "$1" ] || usage
  local m
  m=$(cmd_restart_mode) || die "cannot tell whether Orca would restart the sessions; nothing selected"
  if [ "$m" != keep ]; then
    say "Orca's \"When you switch accounts while Claude is running in terminals\" is $(
      [ "$m" = restart ] && echo '"Always restart"' || echo '"Ask"'): a switch from here restarts every Claude session in a new pane, and each hi-crew worker loses its Dispatch. Nothing selected. Either set it to \"Never restart\" (Orca Settings → Accounts) and run this again, or switch in Orca's status bar and untick the workers in its dialog; then move the rest with account.sh move"
    exit 4
  fi
  "$ORCA" account select --agent claude --account "$1" --json </dev/null >/dev/null \
    || die "orca account select --account $1 failed"
  cmd_target
}

need() {
  command -v jq >/dev/null 2>&1 || die 'jq is required'
  ORCA=$(bash "$ORCA_SH" resolve 2>/dev/null) || ORCA=''
  [ -n "$ORCA" ] || die 'Orca is not available here: accounts are switched through Orca'
}

phys() { (cd -P "$1" 2>/dev/null && pwd -P) || printf '%s' "${1%/}"; }

_q() {
  case "$1" in
    ''|*[!A-Za-z0-9._/:@=+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- processes (Linux /proc; macOS ps) ---------------------------------------------------------

alive() {
  if [ -n "${HI_PROC:-}" ]; then [ -d "$HI_PROC/$1" ]; else kill -0 "$1" 2>/dev/null; fi
}

# penv <pid> <NAME>: that process's environment value, or nothing.
penv() {
  local p=${HI_PROC:-/proc}
  if [ -r "$p/$1/environ" ]; then
    tr '\0' '\n' <"$p/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -1
  elif [ -z "${HI_PROC:-}" ]; then
    # macOS: `ps -E` appends the environment of one's own processes to the command.
    ps -E -ww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
  fi
}

# pargv <pid>: its argv, one argument per line. macOS has only the space-joined command line,
# so an argument with a space in it splits there.
pargv() {
  local p=${HI_PROC:-/proc}
  if [ -r "$p/$1/cmdline" ]; then
    tr '\0' '\n' <"$p/$1/cmdline"
  elif [ -z "${HI_PROC:-}" ]; then
    ps -ww -o args= -p "$1" 2>/dev/null | tr ' ' '\n' | awk 'NF'
  fi
}

ppid_of() {
  local p=${HI_PROC:-/proc}
  if [ -r "$p/$1/stat" ]; then
    sed 's/.*) //' "$p/$1/stat" | cut -d' ' -f2
  elif [ -z "${HI_PROC:-}" ]; then
    ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
  fi
}

# --- accounts ----------------------------------------------------------------------------------

ACCOUNTS=''
accounts_json() {
  [ -n "$ACCOUNTS" ] && { printf '%s' "$ACCOUNTS"; return 0; }
  ACCOUNTS=$("$ORCA" account list --json 2>/dev/null </dev/null | jq -c '.result.claude // empty' 2>/dev/null)
  [ -n "$ACCOUNTS" ] || return 1
  printf '%s' "$ACCOUNTS"
}

# Every config dir an account of Orca's runs from: each managed account's home, and the system one.
config_dirs() {
  accounts_json | jq -r '(.accounts[]?.home), .systemDefaultHome | strings' 2>/dev/null
}

cmd_target() {
  local j
  j=$(accounts_json) || die 'cannot read `orca account list --json`'
  printf '%s' "$j" | jq -r '
    (.activeAccountIdsByRuntime.host // .activeAccountId // "system") as $id
    | ([.accounts[]? | select(.id == $id)] | first) as $a
    | if $a then [$a.home, ($a.email // ""), ($a.organizationUuid // "")]
      else [.systemDefaultHome, (.systemDefaultEmail // ""), (.systemDefaultOrganizationUuid // "")] end
    | select(.[0] != null) | @tsv'
}

# org <config dir>: the organization uuid Orca records for the account at that dir.
org_of() {
  local d; d=$(phys "$1")
  accounts_json | jq -r --arg d "$d" '
    ([.accounts[]? | select(.home == $d)] | first | .organizationUuid)
    // (if .systemDefaultHome == $d then .systemDefaultOrganizationUuid else null end) // ""'
}

email_of() {
  local d; d=$(phys "$1")
  accounts_json | jq -r --arg d "$d" '
    ([.accounts[]? | select(.home == $d)] | first | .email)
    // (if .systemDefaultHome == $d then .systemDefaultEmail else null end) // $d'
}

cmd_lost() {
  [ $# -eq 2 ] || usage
  jq -rn --slurpfile a <(cat "$1/.claude.json" 2>/dev/null || echo '{}') \
         --slurpfile b <(cat "$2/.claude.json" 2>/dev/null || echo '{}') '
    (($a[0].claudeAiMcpEverConnected // []) - ($b[0].claudeAiMcpEverConnected // []))[]
    | sub("^claude\\.ai "; "")'
}

# --- sessions ----------------------------------------------------------------------------------

# One row per live interactive session in an Orca pane:
# handle, session, status, config dir, pid, cwd.
cmd_sessions() {
  local d f row pid h
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d/sessions" ] || continue
    d=$(phys "$d")
    for f in "$d"/sessions/*.json; do
      [ -f "$f" ] || continue
      row=$(jq -r 'select((.kind // "interactive") == "interactive" and (.sessionId | type) == "string")
                   | [.pid, .sessionId, (.status // "unknown"), (.cwd // "")] | @tsv' "$f" 2>/dev/null) || continue
      [ -n "$row" ] || continue
      pid=$(printf '%s' "$row" | cut -f1)
      alive "$pid" || continue
      h=$(penv "$pid" ORCA_TERMINAL_HANDLE)
      [ -n "$h" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$(printf '%s' "$row" | cut -f2)" \
        "$(printf '%s' "$row" | cut -f3)" "$d" "$pid" "$(printf '%s' "$row" | cut -f4)"
    done
  done <<EOF
$(config_dirs)
EOF
}

# status <config dir> <pid>: what the session's own status file says now.
status_of() { jq -r '.status // "unknown"' "$1/sessions/$2.json" 2>/dev/null || printf gone; }

# The pid of this session: the closest ancestor among the session pids given on stdin.
self_pid() {
  local pids p n=0
  pids=$(cat)
  if [ -n "${HI_ACCOUNT_SELF:-}" ]; then printf '%s' "$HI_ACCOUNT_SELF"; return 0; fi
  p=$$
  while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ] && [ $n -lt 32 ]; do
    case "$NL$pids$NL" in *"$NL$p$NL"*) printf '%s' "$p"; return 0 ;; esac
    p=$(ppid_of "$p"); n=$((n + 1))
  done
  return 1
}
NL='
'

# relaunch_args <pid>: the session's flags, without arg0, any earlier resume and the note of an
# earlier move, one per line.
relaunch_args() {
  pargv "$1" | awk '
    NR == 1 { next }
    skip { skip = 0; next }
    asp { asp = 0; if (index($0, "This session moved from the Claude account") == 1) next
          print "--append-system-prompt"; print; next }
    $0 == "--append-system-prompt" { asp = 1; next }
    $0 == "--resume" || $0 == "-r" || $0 == "--session-id" { skip = 1; next }
    $0 ~ /^--resume=/ || $0 ~ /^--session-id=/ { next }
    $0 == "--continue" || $0 == "-c" || $0 == "--fork-session" { next }
    { print }'
}

# idle_wait <handle> <config dir> <pid> <deadline epoch>: exit 0 once the session is idle.
idle_wait() {
  local st
  while :; do
    st=$(status_of "$2" "$3")
    if [ "$st" = idle ] && [ "$("$ORCA" terminal wait --terminal "$1" --for tui-idle --timeout-ms 3000 --json 2>/dev/null </dev/null |
          jq -r '.ok // false' 2>/dev/null)" = true ]; then
      # Read once more: a turn may have started between the two looks.
      [ "$(status_of "$2" "$3")" = idle ] && return 0
    fi
    [ "$(date +%s)" -lt "$4" ] || return 1
    sleep 2
  done
}

# started <config dir> <session>: the pid of a live process of that session under that dir.
started() {
  local f pid
  for f in "$1"/sessions/*.json; do
    [ -f "$f" ] || continue
    pid=$(jq -r --arg s "$2" 'select(.sessionId == $s) | .pid' "$f" 2>/dev/null)
    [ -n "$pid" ] && alive "$pid" && { printf '%s' "$pid"; return 0; }
  done
  return 1
}

# move_one <handle> <session> <from dir> <pid> <to dir> <deadline> <dry>: prints one result row.
move_one() {
  local h=$1 sid=$2 from=$3 pid=$4 to=$5 deadline=$6 dry=$7 lost note line a i
  if [ -z "$(penv "$pid" ORCA_CLAUDE_PROFILE_POINTER)" ]; then
    printf 'skipped\t%s\t%s\tits pane has no Orca claude wrapper: restart it there by hand\n' "$h" "$sid"
    return 1
  fi
  lost=$(cmd_lost "$from" "$to" | paste -sd, - | sed 's/,/, /g')
  line="claude --resume $sid"
  while IFS= read -r a; do
    [ -n "$a" ] && line="$line $(_q "$a")"
  done <<EOF
$(relaunch_args "$pid")
EOF
  if [ -n "$lost" ]; then
    note="This session moved from the Claude account $(email_of "$from") to $(email_of "$to"). The claude.ai connectors $lost are not available on this account; say so if a task needs one."
    line="$line --append-system-prompt $(_q "$note")"
  fi
  if [ "$dry" = 1 ]; then
    printf 'would-move\t%s\t%s\t%s\n' "$h" "$sid" "$line"
    return 0
  fi
  if ! idle_wait "$h" "$from" "$pid" "$deadline"; then
    printf 'busy\t%s\t%s\tstill mid-turn; run the move again once it is idle\n' "$h" "$sid"
    return 3
  fi
  "$ORCA" terminal send --terminal "$h" --text /exit --enter --json >/dev/null 2>&1 </dev/null \
    || { printf 'failed\t%s\t%s\tcould not type /exit\n' "$h" "$sid"; return 1; }
  i=0
  while alive "$pid" && [ $i -lt "${HI_MOVE_EXIT_WAIT:-20}" ]; do sleep 1; i=$((i + 1)); done
  if alive "$pid"; then
    printf 'failed\t%s\t%s\tthe session did not exit after /exit; look at the pane\n' "$h" "$sid"
    return 1
  fi
  "$ORCA" terminal send --terminal "$h" --text "$line" --enter --json >/dev/null 2>&1 </dev/null \
    || { printf 'failed\t%s\t%s\texited, but the relaunch line was not typed: run in the pane: %s\n' "$h" "$sid" "$line"; return 1; }
  i=0
  while ! started "$to" "$sid" >/dev/null && [ $i -lt "${HI_MOVE_START_WAIT:-90}" ]; do sleep 1; i=$((i + 1)); done
  if started "$to" "$sid" >/dev/null; then
    printf 'moved\t%s\t%s\t%s%s\n' "$h" "$sid" "$(email_of "$to")" "${lost:+; lost connectors: $lost}"
    return 0
  fi
  printf 'unconfirmed\t%s\t%s\trelaunched, but not seen running on %s: look at the pane (a dialog?)\n' "$h" "$sid" "$(email_of "$to")"
  return 1
}

cmd_move() {
  local only='' wait=600 dry=0 to org rows row h sid from pid self='' selfrow='' rc=0 r deadline orgs_differ=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --only) only="$only$NL${2:-}"; shift 2 ;;
      --wait) wait=${2:-}; shift 2 ;;
      --dry-run) dry=1; shift ;;
      *) usage ;;
    esac
  done
  case "$wait" in ''|*[!0-9]*) usage ;; esac
  to=$(cmd_target | cut -f1) || to=''
  [ -n "$to" ] && [ -d "$to" ] || die 'cannot tell which account Orca has selected'
  to=$(phys "$to"); org=$(org_of "$to")
  rows=$(cmd_sessions | awk -F'\t' -v to="$to" '$4 != to')
  if [ -n "$only" ]; then
    # Through the environment: a newline in an `awk -v` value is an error in BSD awk.
    rows=$(printf '%s\n' "$rows" | ONLY="$only" awk -F'\t' '
      BEGIN { n = split(ENVIRON["ONLY"], o, "\n"); for (i = 1; i <= n; i++) if (o[i] != "") want[o[i]] = 1 }
      ($1 in want) || ($2 in want)')
  fi
  [ -n "$rows" ] || { say "nothing to move: every session is on $(email_of "$to")"; return 0; }
  self=$(printf '%s\n' "$rows" | cut -f5 | self_pid) || self=''
  deadline=$(($(date +%s) + wait))
  # Rounds: each round moves every session idle at that moment, so a busy one never holds back
  # an idle one behind it. A busy one waits for a later round, and is reported only when the
  # deadline has passed.
  local pending=$rows next out last=0
  while [ -n "$pending" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || last=1
    next=''
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      h=$(printf '%s' "$row" | cut -f1); sid=$(printf '%s' "$row" | cut -f2)
      from=$(printf '%s' "$row" | cut -f4); pid=$(printf '%s' "$row" | cut -f5)
      if [ -n "$self" ] && [ "$pid" = "$self" ]; then selfrow=$row; continue; fi
      out=$(move_one "$h" "$sid" "$from" "$pid" "$to" 0 "$dry"); r=$?
      if [ "$r" = 3 ] && [ "$last" = 0 ]; then next="$next$row$NL"; continue; fi
      printf '%s\n' "$out"
      case "$r" in 0) [ "$(org_of "$from")" = "$org" ] || orgs_differ=1 ;; 3) [ "$rc" = 1 ] || rc=3 ;; *) rc=1 ;; esac
    done <<EOF
$pending
EOF
    pending=$next
    [ -z "$pending" ] || sleep "${HI_MOVE_ROUND:-5}"
  done
  if [ -n "$selfrow" ]; then
    h=$(printf '%s' "$selfrow" | cut -f1); sid=$(printf '%s' "$selfrow" | cut -f2)
    if [ "$dry" = 1 ]; then
      printf 'self\t%s\t%s\tthis session; it would move once its turn ends\n' "$h" "$sid"
    elif [ "${HI_ACCOUNT_DETACH:-1}" = 0 ]; then
      move_one "$h" "$sid" "$(printf '%s' "$selfrow" | cut -f4)" "$self" "$to" "$deadline" 0 || rc=1
    else
      # The move waits for this turn to end, so it runs on after this script: detached from the
      # session's process group, which /exit takes down.
      local log="${XDG_STATE_HOME:-$HOME/.local/state}/highness/account-move.log"
      mkdir -p "$(dirname "$log")" 2>/dev/null
      if command -v setsid >/dev/null 2>&1; then
        HI_ACCOUNT_SELF='-' setsid nohup bash "$0" move --only "$h" --wait "$wait" >>"$log" 2>&1 </dev/null &
      else
        HI_ACCOUNT_SELF='-' nohup bash "$0" move --only "$h" --wait "$wait" >>"$log" 2>&1 </dev/null &
      fi
      printf 'self\t%s\t%s\tthis session moves once its turn ends (log: %s)\n' "$h" "$sid" "$log"
    fi
  fi
  [ "$orgs_differ" = 0 ] || [ "$dry" = 1 ] || say "the first turn of a session moved to another organization rereads its chat: Claude cannot reuse thinking written under another one, so that turn is slower and costs more"
  return "$rc"
}

[ $# -ge 1 ] || usage
verb=$1; shift
case "$verb" in
  target)   need; cmd_target ;;
  sessions) need; cmd_sessions ;;
  lost)     command -v jq >/dev/null 2>&1 || die 'jq is required'; cmd_lost "$@" ;;
  move)     need; cmd_move "$@" ;;
  restart-mode) command -v jq >/dev/null 2>&1 || die 'jq is required'; cmd_restart_mode ;;
  select)   need; cmd_select "$@" ;;
  *) usage ;;
esac
