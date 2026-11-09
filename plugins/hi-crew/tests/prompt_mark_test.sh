#!/usr/bin/env bash
# prompt-mark.sh: a Notification(permission_prompt) marks the session; the marker is believed
# only while the transcript still has the tool call unanswered and no turn end after it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM="$HERE/../lib/prompt-mark.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state"; DIR="$HIGHNESS_STATE/prompts"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }
TAB=$(printf '\t')

WS="$T/ws/AB-1"; mkdir -p "$WS/sub"; WS=$(cd "$WS" && pwd -P)
TR="$T/t.jsonl"
prompt='{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"fix it"}}'
use1='{"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Read"}]}}'
res1='{"type":"user","timestamp":"2020-01-01T00:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1"}]}}'
use2='{"type":"assistant","timestamp":"2020-01-01T00:00:03.000Z","message":{"content":[{"type":"tool_use","id":"tu_2","name":"Bash"}]}}'
put() { printf '%s\n' "$@" >"$TR"; }
notify() { # <session> [notification_type] [cwd]
  jq -n -c --arg s "$1" --arg t "${2:-permission_prompt}" --arg c "${3:-$WS/sub}" --arg tr "$TR" \
    '{hook_event_name: "Notification", notification_type: $t, session_id: $s, cwd: $c,
      transcript_path: $tr, message: "Claude needs your permission"}' | bash "$PM" hook
}
stop() { jq -n -c --arg s "$1" '{hook_event_name: "Stop", session_id: $s}' | bash "$PM" hook; }
later() { # <end | result id>: a record stamped after any marker written now
  case "$1" in
    end) printf '{"type":"system","subtype":"turn_duration","timestamp":"2999-01-01T00:00:00.000Z"}' ;;
    result) printf '{"type":"user","timestamp":"2999-01-01T00:00:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"%s"}]}}' "$2" ;;
  esac
}

# A dialog on the second tool call: the marker names the cwd and that tool.
put "$prompt" "$use1" "$res1" "$use2"
out=$(notify s-1); rc=$?
check 'hook: exit 0, prints nothing' "$rc|$out" '0|'
check 'marker: one file per session' "$(ls "$DIR")" 's-1.json'
check 'marker: cwd and the unanswered tool' "$(jq -r '[.cwd, .tool_id, .tool] | join("|")' "$DIR/s-1.json")" "$WS/sub|tu_2|Bash"
row=$(bash "$PM" list)
check 'list: cwd, tool, session' "$(printf '%s' "$row" | cut -f1,3,4)" "$WS/sub${TAB}Bash${TAB}s-1"
check 'list: since is UTC' "$(printf '%s' "$row" | cut -f2 | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\.000Z$')" 1
out=$(bash "$PM" check "$WS/"); rc=$?
check 'check: a session under the workspace, exit 0 and the tool' "$rc|$(printf '%s' "$out" | cut -f2)" '0|Bash'
mkdir -p "$T/ws/AB-10"
bash "$PM" check "$T/ws/AB-1" >/dev/null && ok 'check: the workspace itself' || no 'check: the workspace itself'
bash "$PM" check "$T/ws/AB-10" >/dev/null && no 'check: a sibling with the same prefix is not a match' || ok 'check: a sibling with the same prefix is not a match'

# Answered: the tool result lands (approve), so the marker is dropped on read.
put "$prompt" "$use1" "$res1" "$use2" "$(later result tu_2)"
bash "$PM" check "$WS" >/dev/null; check 'answered: check exit 1' "$?" 1
check 'answered: the marker is removed' "$(ls "$DIR")" ''

# Esc (deny) fires no Stop: the turn end in the transcript retires the marker.
put "$prompt" "$use1" "$res1" "$use2"; notify s-1
printf '%s\n' "$(later end)" >>"$TR"
check 'denied, turn over: not listed' "$(bash "$PM" list)" ''

# Stop removes the session's marker; another session's stays.
put "$prompt" "$use1" "$res1" "$use2"; notify s-1; notify s-2
stop s-1
check 'stop: only that session goes' "$(ls "$DIR")" 's-2.json'
rm -f "$DIR"/*.json

# Not a permission dialog, a bad session id, junk or no input: nothing written, exit 0.
notify s-3 idle_prompt; r1=$?
notify '../x'; notify ''
printf 'not json' | bash "$PM" hook; r2=$?
bash "$PM" hook </dev/null; r3=$?
check 'odd input: exit 0' "$r1$r2$r3" 000
check 'odd input: no marker' "$(ls "$DIR" 2>/dev/null)" ''

# No tool call found at hook time: no tool named, and any later tool result retires it.
put "$prompt"; notify s-4
check 'no pending tool: empty tool' "$(bash "$PM" list | cut -f3)" ''
printf '%s\n' "$use2" "$(later result tu_2)" >>"$TR"
check 'no tool id: a later result retires it' "$(bash "$PM" list)" ''

# An MCP server's input dialog (elicitation_dialog) holds its tool call open the same way:
# marked as kind input; a permission marker is kind permission.
put "$prompt" "$use1" "$res1" "$use2"; notify s-6 elicitation_dialog
check 'elicitation: listed with kind input' "$(bash "$PM" list | cut -f3,5)" "Bash${TAB}input"
check 'elicitation: check gives the kind' "$(bash "$PM" check "$WS" | cut -f2,3)" "Bash${TAB}input"
stop s-6; notify s-7
check 'permission: kind permission' "$(bash "$PM" check "$WS" | cut -f3)" permission
stop s-7

# A transcript that is gone: the marker is dropped.
put "$prompt" "$use2"; notify s-5; rm -f "$TR"
check 'no transcript: not listed, removed' "$(bash "$PM" list)$(ls "$DIR")" ''

bash "$PM" check </dev/null >/dev/null 2>&1; check 'check without a path: exit 2' "$?" 2

J="$HERE/../hooks/hooks.json"
check 'hooks.json: Notification permission_prompt and elicitation_dialog, one entry each, run prompt-mark.sh' \
  "$(jq -r '[.hooks.Notification[] | .matcher + " " + .hooks[0].command] | join(";")' "$J")" \
  'permission_prompt bash "${CLAUDE_PLUGIN_ROOT}/lib/prompt-mark.sh" hook;elicitation_dialog bash "${CLAUDE_PLUGIN_ROOT}/lib/prompt-mark.sh" hook'
check 'hooks.json: Stop runs prompt-mark.sh' "$(jq -r '.hooks.Stop[0].hooks[0].command' "$J")" \
  'bash "${CLAUDE_PLUGIN_ROOT}/lib/prompt-mark.sh" hook'
exit $fail
