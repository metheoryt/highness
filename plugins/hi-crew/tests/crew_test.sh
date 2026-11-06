#!/usr/bin/env bash
# crew.sh: facts, the Run id, open questions from a fake Orca inbox, spec rendering.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json"
unset ORCA_CLI_COMMAND
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

# --- facts
bash "$C" record ABC-1 '{"title":"First","dispatch":"ctx_1"}' || no 'record creates'
bash "$C" record ABC-1 '{"pr":"https://forge/pr/1"}' || no 'record merges'
check 'merged facts keep old keys' "$(bash "$C" get ABC-1 | jq -r '.title + " " + .pr + " " + .key')" 'First https://forge/pr/1 ABC-1'
bash "$C" record ABC-2 '{"title":"Second"}'
check 'list shows both' "$(bash "$C" list | jq -r .key | sort | tr '\n' ' ')" 'ABC-1 ABC-2 '
bash "$C" close ABC-1
check 'close removes from list' "$(bash "$C" list | jq -r .key | tr '\n' ' ')" 'ABC-2 '
if bash "$C" get ABC-1 >/dev/null; then no 'closed facts not readable as open'; else ok 'closed facts not readable as open'; fi
if bash "$C" record '../evil' '{}' 2>/dev/null; then no 'bad key refused'; else ok 'bad key refused'; fi
if bash "$C" record ABC-3 '[1]' 2>/dev/null; then no 'non-object refused'; else ok 'non-object refused'; fi

# --- a fake orca: run-current answers $FAKE_CURRENT, inbox prints a fixed inbox
mkdir -p "$T/bin"
cat >"$T/bin/fakeorca" <<'EOF'
#!/bin/sh
if [ "$2" = run-current ]; then
  [ -n "${FAKE_CURRENT:-}" ] || { echo '{"ok":false}'; exit 1; }
  printf '{"ok":true,"result":{"runId":"%s"}}\n' "$FAKE_CURRENT"; exit 0
fi
cat <<'JSON'
{"ok":true,"result":{"messages":[
 {"id":"msg_q1","run_id":"run_abc123","type":"question","thread_id":"msg_q1","created_at":"2026-01-01T10:00:00Z","body":"Answered one?\nmore","payload":"{\"dispatchId\":\"ctx_a\"}"},
 {"id":"msg_r1","run_id":"run_abc123","type":"status","thread_id":"msg_q1","created_at":"2026-01-01T10:05:00Z","body":"yes","payload":null},
 {"id":"msg_q2","run_id":"run_abc123","type":"question","thread_id":"msg_q2","created_at":"2026-01-01T11:00:00Z","body":"Open one?\nsecond line","payload":"{\"dispatchId\":\"ctx_b\"}"},
 {"id":"msg_q3","run_id":"run_other","type":"question","thread_id":"msg_q3","created_at":"2026-01-01T12:00:00Z","body":"Other run","payload":"{}"},
 {"id":"msg_e1","run_id":"run_abc123","type":"escalation","thread_id":null,"created_at":"2026-01-01T13:00:00Z","body":"Stopped: no token","payload":"{\"dispatchId\":\"ctx_c\"}"},
 {"id":"msg_e2","run_id":"run_abc123","type":"escalation","thread_id":null,"created_at":"2026-01-01T09:00:00Z","body":"Stopped early","payload":"{\"dispatchId\":\"ctx_a\"}"},
 {"id":"msg_d1","run_id":"run_abc123","type":"worker_done","thread_id":null,"created_at":"2026-01-01T09:30:00Z","subject":"Done A","body":"x","payload":"{\"dispatchId\":\"ctx_a\",\"outcome\":\"succeeded\"}"},
 {"id":"msg_d0","run_id":"run_abc123","type":"worker_done","thread_id":null,"created_at":"2026-01-01T08:00:00Z","subject":"Older A","body":"x","payload":"{\"dispatchId\":\"ctx_a\",\"outcome\":\"failed\"}"},
 {"id":"msg_g1","run_id":"run_def456","type":"decision_gate","thread_id":"msg_g1","created_at":"2026-01-01T14:00:00Z","body":"Deploy to prod?","payload":"{\"dispatchId\":\"ctx_d\"}"}
]}}
JSON
EOF
chmod +x "$T/bin/fakeorca"
export ORCA_CLI_COMMAND="$T/bin/fakeorca"

# --- this session's Run
if bash "$C" run >/dev/null; then no 'no run when Orca binds none'; else ok 'no run when Orca binds none'; fi
if FAKE_CURRENT=run_abc123 bash "$C" run >/dev/null; then no 'a Run hi-crew did not make is not ours'; else ok 'a Run hi-crew did not make is not ours'; fi
bash "$C" run run_abc123; bash "$C" run run_def456; bash "$C" run run_abc123
check 'registry keeps each Run once' "$(wc -l <"$HIGHNESS_STATE/crew/run" | tr -d ' ')" 2
check 'run: the Run bound to this session' "$(FAKE_CURRENT=run_def456 bash "$C" run)" 'run_def456'
if bash "$C" run notarun 2>/dev/null; then no 'bad run id refused'; else ok 'bad run id refused'; fi

# --- asks and reports across the open tickets' Runs
check 'asks: nothing without open tickets in a Run' "$(bash "$C" asks)" ''
bash "$C" record ABC-2 '{"run":"run_abc123"}'
bash "$C" record ABC-4 '{"run":"run_def456"}'
check 'runs: the open tickets'"'"' Runs' "$(bash "$C" runs | tr '\n' ' ')" 'run_abc123 run_def456 '
check 'asks: open question, live escalation and gate of the open tickets'"'"' Runs only' "$(bash "$C" asks)" "$(printf 'msg_q2\tquestion\trun_abc123\tctx_b\t2026-01-01T11:00:00Z\tOpen one?\nmsg_e1\tescalation\trun_abc123\tctx_c\t2026-01-01T13:00:00Z\tStopped: no token\nmsg_g1\tdecision_gate\trun_def456\tctx_d\t2026-01-01T14:00:00Z\tDeploy to prod?')"
check 'reports: latest worker_done per dispatch' "$(bash "$C" reports)" "$(printf 'run_abc123\tctx_a\t2026-01-01T09:30:00Z\tsucceeded\tDone A')"
bash "$C" close ABC-4
check 'asks: a closed ticket'"'"'s Run drops out' "$(bash "$C" asks | cut -f1 | tr '\n' ' ')" 'msg_q2 msg_e1 '
unset ORCA_CLI_COMMAND

# --- spec
printf 'Line one of the brief.\nLine & two with {{KEY}} literal.\n' >"$T/brief"
out=$(cd "$T" && bash "$C" spec --key ABC-9 --title 'Do the thing' --brief-file "$T/brief")
case "$out" in *'Ticket ABC-9: Do the thing'*) ok 'spec title' ;; *) no 'spec title' ;; esac
case "$out" in *'Line & two with {{KEY}} literal.'*) ok 'brief copied verbatim' ;; *) no 'brief copied verbatim' ;; esac
case "$out" in *'start with `ABC-9: `'*) ok 'key in commit rule' ;; *) no 'key in commit rule' ;; esac
case "$out" in *'`(agent)`, so people'*) ok 'default marker' ;; *) no 'default marker' ;; esac
case "$out" in *'(none configured'*) ok 'default process' ;; *) no 'default process' ;; esac
printf '{"crew":{"process":"Use the team-task skill.\\nThen the team-pr skill at {{ROOT}}/pr.py.","marker":"[bot]"}}' >"$HIGHNESS_CONFIG"
out=$(cd "$T" && bash "$C" spec --key ABC-9 --title 'T' --brief-file "$T/brief")
case "$out" in *'Use the team-task skill.'*'Then the team-pr skill at '*) ok 'process from config' ;; *) no 'process from config' ;; esac
case "$out" in *'`[bot]`, so people'*) ok 'marker from config' ;; *) no 'marker from config' ;; esac
mkdir -p "$T/repo" && git -C "$T/repo" init -q && R=$(cd "$T/repo" && git rev-parse --show-toplevel)
out=$(cd "$T/repo" && bash "$C" spec --key ABC-9 --title 'T')
case "$out" in *"team-pr skill at $R/pr.py."*) ok '{{ROOT}} in process is the coordinator git root' ;; *) no '{{ROOT}} in process is the coordinator git root' ;; esac
left=$(printf '%s\n' "$out" | grep -v 'literal\.$' | grep -c '{{')
check 'no placeholder left' "$left" 0
if bash "$C" spec --key ABC-9 2>/dev/null; then no 'spec needs a title'; else ok 'spec needs a title'; fi

# --- watch: a fake PR state command and an orca that records what it sends
W="$T/w"; mkdir -p "$W/bin" "$W/root"; git -C "$W/root" init -q
WR=$(cd "$W/root" && git rev-parse --show-toplevel)
export HIGHNESS_STATE="$W/state"
cat >"$W/bin/orca" <<'EOF'
#!/bin/sh
if [ "$2" = run-current ]; then printf '{"ok":true,"result":{"runId":"run_w1"}}\n'; exit 0; fi
printf '%s\n' "$*" >>"$SENT"
EOF
chmod +x "$W/bin/orca"
export ORCA_CLI_COMMAND="$W/bin/orca" SENT="$W/sent"; : >"$SENT"
printf '{"crew":{"pr_state":"cat {{ROOT}}/state-$(basename {{PR}}).json","marker":"[bot]"}}' >"$W/root/.claude-tmp"
mkdir -p "$W/root/.claude" && mv "$W/root/.claude-tmp" "$W/root/.claude/highness.json"
ORCA_TERMINAL_HANDLE=term_coord bash "$C" run run_w1
check 'run keeps the coordinator terminal' "$(cat "$W/state/crew/handles/run_w1")" term_coord
bash "$C" record W-1 "{\"pr\":\"https://forge/pr/7\",\"run\":\"run_w1\",\"root\":\"$WR\"}"
bash "$C" record W-2 "{\"run\":\"run_w1\",\"root\":\"$WR\"}"
echo '{"state":"open","ci":"pending","people":1,"head":"aaaaaaaaaa"}' >"$WR/state-7.json"
bash "$C" watch
check 'first look only records' "$(bash "$C" events)$(cat "$SENT")" ''
bash "$C" watch
check 'no change, no event' "$(bash "$C" events)" ''
echo '{"state":"open","ci":"failure","people":3,"head":"bbbbbbbbbb"}' >"$WR/state-7.json"
bash "$C" watch
check 'events: CI failure and new comments' "$(bash "$C" events | cut -f2,3,4,5)" "$(printf 'W-1\trun_w1\thttps://forge/pr/7\tCI failed on bbbbbbbb\nW-1\trun_w1\thttps://forge/pr/7\t2 new comment(s) from people')"
case "$(cat "$SENT")" in *'send --to run:run_w1 --from term_coord --type status --subject W-1: CI failed on bbbbbbbb'*) ok 'wakes the coordinator from its terminal' ;; *) no "wakes the coordinator: $(cat "$SENT")" ;; esac
check 'one message per event' "$(wc -l <"$SENT" | tr -d ' ')" 2
bash "$C" events --ack
check 'ack hides seen events' "$(bash "$C" events)" ''
echo '{"state":"merged","ci":"failure","people":3}' >"$WR/state-7.json"
bash "$C" watch
check 'merge is an event' "$(bash "$C" events | cut -f5)" 'PR merged'
mv "$WR/state-7.json" "$WR/gone"; bash "$C" watch
check 'a failing state command changes nothing' "$(bash "$C" events | wc -l | tr -d ' ')" 1
mkdir "$W/state/crew/watch/lock"; mv "$WR/gone" "$WR/state-7.json"
echo '{"state":"closed"}' >"$WR/state-7.json"; bash "$C" watch
check 'a running watch is not doubled' "$(bash "$C" events | wc -l | tr -d ' ')" 1
rmdir "$W/state/crew/watch/lock"
QR=$(bash -c 'source /dev/stdin <<<"$(sed -n "/^q()/p" "$1")"; q "it'"'"'s a b"' _ "$C")
check 'q quotes one shell word' "$(eval "printf %s $QR")" "it's a b"
unset ORCA_CLI_COMMAND

exit $fail
