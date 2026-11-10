#!/usr/bin/env bash
# session-state.sh: each hook payload moves the session's line to working, blocked or idle;
# reading believes a line only while its agent lives and its transcript does not say otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SS="$HERE/../lib/session-state.sh"
T=$(mktemp -d); trap 'kill "$AGENT" 2>/dev/null; rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state"; DIR="$HIGHNESS_STATE/sessions"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
TAB=$(printf '\t')

WS="$T/ws/AB-1"; mkdir -p "$WS/sub" "$T/ws/AB-10"; WS=$(cd "$WS" && pwd -P)
TR="$T/t.jsonl"; : >"$TR"
sleep 600 & AGENT=$!   # a live "claude"
# ev <event> <session> [extra json fields] — the payload shape Claude Code 2.1.319 sends, one
# line: session_id, transcript_path, cwd, then hook_event_name and tool_name, all before
# tool_input and tool_response (measured for SessionStart, UserPromptSubmit, PreToolUse,
# PostToolUse and Stop).
ev() {
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","permission_mode":"default","hook_event_name":"%s"%s}' \
    "$2" "$TR" "${CWD:-$WS/sub}" "$1" "${3:+,$3}" | HI_AGENT_PID="${PID-$AGENT}" bash "$SS" hook
}
field() { cut -f"$2" "$DIR/$1" | sed 's/^-$//'; }   # an empty field is stored as -
get() { bash "$SS" get "$@"; }

out=$(ev SessionStart s-1); rc=$?
check 'hook: exit 0, prints nothing' "$rc|$out" '0|'
check 'SessionStart: idle' "$(field s-1 1)" idle
check 'an empty field is stored as -' "$(cut -f4-6,11 "$DIR/s-1")" "-$TAB-$TAB-$TAB-"
check 'line: pid, cwd, transcript, session' "$(cut -f7-10 "$DIR/s-1")" "$AGENT$TAB$WS/sub$TAB$TR${TAB}s-1"
check 'line: iso is UTC to the second' "$(field s-1 3 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}$')" 1

ev UserPromptSubmit s-1 '"prompt":"fix it"'
check 'UserPromptSubmit: working, the turn starts' "$(field s-1 1)|$([ -n "$(field s-1 4)" ] && echo turn)" 'working|turn'
turn=$(field s-1 4)
ev PreToolUse s-1 '"tool_name":"Bash","tool_input":{"command":"make \"x\""}'
check 'PreToolUse: working, the open tool and its start' "$(field s-1 1)|$(field s-1 5)|$([ -n "$(field s-1 6)" ] && echo since)" 'working|Bash|since'
check 'PreToolUse: the turn carries over' "$(field s-1 4)" "$turn"
ev PostToolUse s-1 '"tool_name":"Bash","tool_response":{"stdout":"ok"}'
check 'PostToolUse: working, no open tool, same turn' "$(field s-1 1)|$(field s-1 5)|$(field s-1 4)" "working||$turn"
ev PreToolUse s-1 '"tool_name":"Bash"'; ev PostToolUseFailure s-1 '"tool_name":"Bash"'
check 'PostToolUseFailure: working, no open tool' "$(field s-1 1)|$(field s-1 5)" 'working|'

ev PreToolUse s-1 '"tool_name":"Bash"'
ev Notification s-1 '"message":"Claude needs your permission","notification_type":"permission_prompt"'
check 'Notification permission_prompt: blocked, kind permission, the tool kept' \
  "$(field s-1 1)|$(field s-1 11)|$(field s-1 5)" 'blocked|permission|Bash'
ev Notification s-1 '"notification_type":"elicitation_dialog"'
check 'Notification elicitation_dialog: blocked, kind input' "$(field s-1 1)|$(field s-1 11)" 'blocked|input'
ev Notification s-1 '"notification_type":"idle_prompt"'
check 'another Notification: no change' "$(field s-1 1)|$(field s-1 11)" 'blocked|input'
ev PreToolUse s-1 '"tool_name":"AskUserQuestion","tool_input":{"questions":[]}'
check 'PreToolUse AskUserQuestion: blocked, kind question' "$(field s-1 1)|$(field s-1 11)|$(field s-1 5)" 'blocked|question|AskUserQuestion'
ev PreToolUse s-1 '"tool_name":"ExitPlanMode"'
check 'PreToolUse ExitPlanMode: blocked, kind question' "$(field s-1 1)|$(field s-1 11)" 'blocked|question'
ev PostToolUse s-1 '"tool_name":"ExitPlanMode"'
check 'the answer (PostToolUse): working again, no kind' "$(field s-1 1)|$(field s-1 11)" 'working|'

ev SubagentStop s-1
check 'SubagentStop: the parent stays working' "$(field s-1 1)" working
ev Stop s-1
check 'Stop: idle, the turn closed' "$(field s-1 1)|$(field s-1 4)|$(field s-1 5)" 'idle||'
ev UserPromptSubmit s-1; ev StopFailure s-1
check 'StopFailure: idle' "$(field s-1 1)" idle
ev SessionEnd s-1
check 'SessionEnd: the line goes' "$(ls "$DIR")" ''

# What the hook refuses: a bad session id, no or a relative cwd, a cwd with an escape, junk.
ev Stop '../x'; ev Stop ''; CWD=rel ev Stop s-2; CWD='/a\"b' ev Stop s-3
printf 'not json' | bash "$SS" hook; r1=$?; bash "$SS" hook </dev/null; r2=$?
check 'odd input: exit 0, nothing written' "$r1$r2|$(ls "$DIR")" '00|'

# A large payload is read only in part; the fields come first. And the hook is quick.
big=$(head -c 300000 /dev/zero | tr '\0' a)
printf '{"session_id":"s-4","transcript_path":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Read","tool_response":{"file":"%s"}}' \
  "$TR" "$WS" "$big" | HI_AGENT_PID=$AGENT bash "$SS" hook
check 'a 300 KB payload: written' "$(field s-4 1)" working
rm -f "$DIR"/*

# --- get: the believed state for a workspace ---
ev UserPromptSubmit s-1; ev PreToolUse s-1 '"tool_name":"Bash"'
out=$(get "$WS"); rc=$?
check 'get: a session under the workspace, exit 0' "$rc|$(printf '%s' "$out" | cut -f1,3,4,6)" "0|working${TAB}s-1${TAB}${TAB}Bash"
check 'get: eight fields, the last the UTC time' "$(printf '%s' "$out" | awk -F'\t' '{ print NF }')|$(printf '%s' "$out" | cut -f8 | grep -c T)" '8|1'
get "$T/ws/AB-10" >/dev/null; check 'get: a sibling with the same prefix is not a match' "$?" 1
get "$WS/" >/dev/null; check 'get: a trailing slash is the same workspace' "$?" 0
CWD=$WS ev Stop s-2
get "$WS" >/dev/null; check 'get: two sessions there and no id: exit 1 (the screen decides)' "$?" 1
check 'get <ws> <sid>: that session' "$(get "$WS" s-2 | cut -f1,3)" "idle${TAB}s-2"
check 'get <ws> <unknown sid>: back to the cwd match, still two' "$(get "$WS" s-9; echo "rc=$?")" 'rc=1'
rm -f "$DIR/s-2"

# A dead agent drops the line.
PID='12x' ev Stop s-7
check 'a pid that is not a number is not stored' "$(field s-7 7)" ''
rm -f "$DIR/s-7"
PID=999999 ev Stop s-5; CWD=$T/ws/AB-10 PID=999999 ev Stop s-5
get "$T/ws/AB-10" >/dev/null; check 'dead pid: not believed' "$?" 1
check 'dead pid: the line is removed' "$(ls "$DIR")" 's-1'
# No pid: believed while young.
CWD=$T/ws/AB-10 PID='' ev Stop s-6
check 'no pid, young: believed' "$(get "$T/ws/AB-10" | cut -f1)" idle
HI_STATE_MAX_AGE=-1 get "$T/ws/AB-10" >/dev/null; check 'no pid, older than HI_STATE_MAX_AGE: not believed' "$?" 1
rm -f "$DIR/s-6"

# The transcript overrules a stale working or blocked line.
later() { printf '{"type":"%s","timestamp":"2999-01-01T00:00:00.000Z",%s}\n' "$1" "$2" >>"$TR"; }
earlier() { printf '{"type":"%s","timestamp":"2000-01-01T00:00:00.000Z",%s}\n' "$1" "$2" >>"$TR"; }
earlier user '"message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}'
earlier system '"subtype":"turn_duration"'
check 'working, older interrupt and turn end: believed' "$(get "$WS" | cut -f1)" working
later user '"message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}'
get "$WS" >/dev/null; check 'working, then Esc (interrupt in the transcript): not believed' "$?" 1
: >"$TR"; ev UserPromptSubmit s-1; later system '"subtype":"turn_duration","durationMs":5'
get "$WS" >/dev/null; check 'working, then a turn end with no Stop: not believed' "$?" 1
: >"$TR"; ev PreToolUse s-1 '"tool_name":"Bash"'; later user '"message":{"content":[{"type":"tool_result","tool_use_id":"x"}]}'
check 'working, then a tool result: still working' "$(get "$WS" | cut -f1)" working
: >"$TR"; earlier user '"message":{"content":[{"type":"tool_result","tool_use_id":"x"}]}'
ev Notification s-1 '"notification_type":"permission_prompt"'
check 'blocked, older tool result: believed' "$(get "$WS" | cut -f1,4)" "blocked${TAB}permission"
: >"$TR"; ev Notification s-1 '"notification_type":"permission_prompt"'
later user '"message":{"content":[{"type":"tool_result","tool_use_id":"x"}]}'
get "$WS" >/dev/null; check 'blocked, then a tool result (answered): not believed' "$?" 1
: >"$TR"; ev Notification s-1 '"notification_type":"permission_prompt"'; later system '"subtype":"turn_duration"'
get "$WS" >/dev/null; check 'blocked, then a turn end (Esc on the dialog): not believed' "$?" 1
: >"$TR"; ev Stop s-1; later user '"message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}'
check 'idle is never overruled by the transcript' "$(get "$WS" | cut -f1)" idle
check 'list: the believed lines as stored' "$(bash "$SS" list | cut -f1,10)" "idle${TAB}s-1"

bash "$SS" get </dev/null >/dev/null 2>&1; check 'get without a path: exit 2' "$?" 2
bash "$SS" nope </dev/null >/dev/null 2>&1; check 'unknown command: exit 2' "$?" 2

# hooks.json: every event the state needs runs session-state.sh with the agent pid.
J="$HERE/../hooks/hooks.json"
cmd='HI_AGENT_PID=$PPID bash "${CLAUDE_PLUGIN_ROOT}/lib/session-state.sh" hook'
for e in UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure Stop StopFailure SessionStart SessionEnd; do
  check "hooks.json: $e runs session-state.sh" "$(jq -r --arg e "$e" --arg c "$cmd" '[.hooks[$e][]?.hooks[]? | select(.command == $c)] | length' "$J")" 1
done
check 'hooks.json: both Notification matchers run session-state.sh' \
  "$(jq -r --arg c "$cmd" '[.hooks.Notification[] | select(any(.hooks[]; .command == $c)) | .matcher] | join(" ")' "$J")" \
  'permission_prompt elicitation_dialog'
check 'hooks.json: no SubagentStop hook' "$(jq -r '.hooks | has("SubagentStop")' "$J")" false
exit $fail
