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
if [ "$2" = worker-show ]; then
  case " ${FAKE_SETTLED:-} " in
    *" $4 "*) echo '{"ok":true,"result":{"state":"succeeded","stage":"settled"}}' ;;
    *) case " ${FAKE_GONE:-} " in
         *" $4 "*) echo '{"ok":false,"error":{"code":"dispatch_not_found"}}'; exit 1 ;;
         *) echo '{"ok":true,"result":{"state":"running","stage":"running"}}' ;;
       esac ;;
  esac
  exit 0
fi
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
check 'asks: a settled worker'"'"'s question and gate drop out, its escalation stays' "$(FAKE_SETTLED='ctx_b ctx_c' FAKE_GONE=ctx_d bash "$C" asks | cut -f1 | tr '\n' ' ')" 'msg_e1 '
bash "$C" close ABC-4
check 'asks: a closed ticket'"'"'s Run drops out' "$(bash "$C" asks | cut -f1 | tr '\n' ' ')" 'msg_q2 msg_e1 '
unset ORCA_CLI_COMMAND

# --- the team's digest sections
S="$T/secrepo"; mkdir -p "$S/.claude"; git -C "$S" init -q
check 'sections: nothing without agenda.sections' "$(cd "$S" && bash "$C" sections)" ''
cat >"$S/.claude/highness.json" <<'JSON'
{"crew": {"marker": "(bot)"},
 "agenda": {"sections": [
  {"name": "Tickets", "command": "printf '%s\\n' '{\"group\":\"you\",\"title\":\"T-1\",\"next\":\"start\"}' 'noise' ; printf '{\"title\":\"%s %s\"}\\n' {{ROOT}} {{MARKER}}"},
  {"name": "Broken", "command": "echo nope >&2; exit 3"},
  {"name": "Quiet", "command": "true"}
 ]}}
JSON
out=$(cd "$S" && bash "$C" sections)
check 'sections: each object tagged with its section, placeholders filled' "$(printf '%s\n' "$out" | jq -r 'select(.section == "Tickets") | (.group // "-") + " " + .title' | tr '\n' '|')" "you T-1|- $(cd "$S" && git rev-parse --show-toplevel) (bot)|"
check 'sections: a failing source shows as an error' "$(printf '%s\n' "$out" | jq -r 'select(.section == "Broken") | .error')" 'exit 3: nope'
check 'sections: a quiet source gives nothing' "$(printf '%s\n' "$out" | jq -r 'select(.section == "Quiet")' )" ''

# --- spec
printf 'Line one of the brief.\nLine & two with {{KEY}} literal.\n' >"$T/brief"
out=$(cd "$T" && bash "$C" spec --key ABC-9 --title 'Do the thing' --brief-file "$T/brief")
case "$out" in *'Ticket ABC-9: Do the thing'*) ok 'spec title' ;; *) no 'spec title' ;; esac
case "$out" in *'Line & two with {{KEY}} literal.'*) ok 'brief copied verbatim' ;; *) no 'brief copied verbatim' ;; esac
case "$out" in *'start with `ABC-9: `'*) ok 'key in commit rule' ;; *) no 'key in commit rule' ;; esac
case "$out" in *'`(agent)`, so people'*) ok 'default marker' ;; *) no 'default marker' ;; esac
case "$out" in *'(none configured'*) ok 'default process' ;; *) no 'default process' ;; esac
case "$out" in *'Change files with the Edit/Write tools, never with a python/sed/perl heredoc in Bash.'*) ok 'edit-not-heredoc rule' ;; *) no 'edit-not-heredoc rule' ;; esac
# The already-done check comes before the worker takes the ticket or changes anything.
case "$out" in *'check it is not already done (below) before'*'## Already done?'*'## Asking'*) ok 'already-done check, before taking the ticket' ;; *) no 'already-done check, before taking the ticket' ;; esac
case "$out" in *'Only landed work counts'*'An open pull request, or a branch from an earlier attempt at this ticket, is'*) ok 'only landed work counts as done' ;; *) no 'only landed work counts as done' ;; esac
case "$out" in *'**All of it is done:** open no pull request.'*'subject that starts `already done:`'*) ok 'already done: no PR, reported as such' ;; *) no 'already done: no PR, reported as such' ;; esac
case "$out" in *'If you do work that belongs to another open ticket, comment on that ticket'*) ok 'out-of-band work recorded on its ticket' ;; *) no 'out-of-band work recorded on its ticket' ;; esac
# The coordinator recognizes an already-done report by the subject prefix the spec gives.
for s in start agenda; do
  if grep -q '`already done:`' "$HERE/../skills/$s/SKILL.md"; then ok "$s skill reads the already-done subject"; else no "$s skill reads the already-done subject"; fi
done
if grep -q 'If this session does work that belongs to an open ticket' "$HERE/../skills/start/SKILL.md"; then ok 'coordinator: out-of-band work rule'; else no 'coordinator: out-of-band work rule'; fi
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
if [ "$2" = worker-show ]; then
  case " ${FAKE_SETTLED:-} " in
    *" $4 "*) echo '{"ok":true,"result":{"state":"succeeded","stage":"settled"}}' ;;
    *) case " ${FAKE_GONE:-} " in
         *" $4 "*) echo '{"ok":false,"error":{"code":"dispatch_not_found"}}'; exit 1 ;;
         *) echo '{"ok":true,"result":{"state":"running","stage":"running"}}' ;;
       esac ;;
  esac
  exit 0
fi
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
echo '{"state":"open","ci":"failure","people":3,"people_at":"2026-01-01T10:00:00Z"}' >"$WR/gone"; mv "$WR/gone" "$WR/state-7.json"
bash "$C" watch
check 'people_at appearing is not an event' "$(bash "$C" events | wc -l | tr -d ' ')" 1
echo '{"state":"open","ci":"failure","people":3,"people_at":"2026-01-01T11:00:00Z"}' >"$WR/state-7.json"; bash "$C" watch
check 'a replaced or edited comment is an event' "$(bash "$C" events | tail -1 | cut -f5)" 'a comment from people was written or edited'
mkdir "$W/state/crew/watch/lock"
echo '{"state":"closed"}' >"$WR/state-7.json"; bash "$C" watch
check 'a running watch is not doubled' "$(bash "$C" events | wc -l | tr -d ' ')" 2
rmdir "$W/state/crew/watch/lock"
# --- a worker on a permission dialog: prompts lists it, the watch tells the coordinator once
mkdir -p "$W/ws2/sub"; WS2=$(cd "$W/ws2" && pwd -P)
bash "$C" record W-2 "{\"workspace\":\"$WS2\"}"
bash "$C" watch; bash "$C" events --ack; : >"$SENT"  # settle the closed PR above
PTR="$W/p.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"2020-01-01T00:00:01.000Z","message":{"content":[{"type":"tool_use","id":"tu_9","name":"Bash"}]}}' >"$PTR"
pnotify() { jq -n -c --arg c "$WS2/sub" --arg tr "$PTR" '{hook_event_name:"Notification",notification_type:"permission_prompt",session_id:"sw2",cwd:$c,transcript_path:$tr}' \
  | bash "$HERE/../lib/prompt-mark.sh" hook; }
check 'prompts: none before the dialog' "$(bash "$C" prompts)" ''
pnotify
check 'prompts: key, run, tool' "$(bash "$C" prompts | cut -f1,2,4)" "$(printf 'W-2\trun_w1\tBash')"
bash "$C" watch
check 'watch: a dialog is an event' "$(bash "$C" events | cut -f2,4,5)" "$(printf 'W-2\t%s\twaits on a permission dialog for Bash' "$WS2")"
case "$(cat "$SENT")" in *'--subject W-2: waits on a permission dialog for Bash'*) ok 'watch: wakes the coordinator about the dialog' ;; *) no "dialog send: $(cat "$SENT")" ;; esac
bash "$C" watch
check 'watch: the same dialog is told once' "$(bash "$C" events | wc -l | tr -d ' ')" 1
printf '%s\n' '{"type":"user","timestamp":"2999-01-01T00:00:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"tu_9"}]}}' >>"$PTR"
check 'prompts: answered, gone' "$(bash "$C" prompts)" ''
printf '%s\n' '{"type":"assistant","timestamp":"2999-01-01T00:00:01.000Z","message":{"content":[{"type":"tool_use","id":"tu_10","name":"Edit"}]}}' >"$PTR"
sleep 1; pnotify; bash "$C" watch
check 'watch: a new dialog is told again' "$(bash "$C" events | wc -l | tr -d ' ')" 2
bash "$C" events --ack
# an MCP server's input dialog is told as one
printf '%s\n' '{"type":"assistant","timestamp":"2999-01-01T00:00:02.000Z","message":{"content":[{"type":"tool_use","id":"tu_11","name":"mcp__docs__ask"}]}}' >"$PTR"
sleep 1
jq -n -c --arg c "$WS2/sub" --arg tr "$PTR" '{hook_event_name:"Notification",notification_type:"elicitation_dialog",session_id:"sw2",cwd:$c,transcript_path:$tr}' \
  | bash "$HERE/../lib/prompt-mark.sh" hook
check 'prompts: an input dialog has kind input' "$(bash "$C" prompts | cut -f4,5)" "$(printf 'mcp__docs__ask\tinput')"
bash "$C" watch
check 'watch: an input dialog is said as one' "$(bash "$C" events | cut -f5)" 'waits on an MCP input dialog for mcp__docs__ask'
bash "$C" events --ack
# The hook line (session-state.sh) adds question forms, and says what each worker is doing.
rm -f "$HIGHNESS_STATE/prompts/"*.json; : >"$PTR"
sleep 300 & LIVE=$!
sev() { # <event> [extra json] — a hook payload for the W-2 worker's session
  printf '{"session_id":"sw2","transcript_path":"%s","cwd":"%s/sub","hook_event_name":"%s"%s}' "$PTR" "$WS2" "$1" "${2:+,$2}" \
    | HI_AGENT_PID=$LIVE bash "$HERE/../lib/session-state.sh" hook; }
check 'states: no hook line, unknown' "$(bash "$C" states | grep '^W-2' | cut -f3)" unknown
sev UserPromptSubmit; sev PreToolUse '"tool_name":"Bash"'
check 'states: working, the open tool, 0 min' "$(bash "$C" states | grep '^W-2' | cut -f2-3,6,7,8)" "$(printf 'run_w1\tworking\tBash\t0\t0')"
check 'prompts: a working worker is not listed' "$(bash "$C" prompts)" ''
sev PreToolUse '"tool_name":"AskUserQuestion"'
check 'prompts: a question form, kind question' "$(bash "$C" prompts | cut -f1,4,5)" "$(printf 'W-2\tAskUserQuestion\tquestion')"
check 'prompts: since is UTC' "$(bash "$C" prompts | cut -f3 | grep -cE '^[0-9-]{10}T[0-9:]{8}Z$')" 1
check 'states: blocked, kind question' "$(bash "$C" states | grep '^W-2' | cut -f3,5)" "$(printf 'blocked\tquestion')"
bash "$C" watch
check 'watch: a question form is said as one' "$(bash "$C" events | cut -f5)" 'waits on a question form for AskUserQuestion'
bash "$C" events --ack
# A tool call open longer than HI_TOOL_STUCK minutes is told once.
sev PostToolUse; sev PreToolUse '"tool_name":"Bash"'
HI_TOOL_STUCK=0 bash "$C" watch
check 'watch: a long tool call is told' "$(bash "$C" events | cut -f2,5)" "$(printf 'W-2\thas had one Bash call open for 0 min — a hung command?')"
HI_TOOL_STUCK=0 bash "$C" watch
check 'watch: the same call is told once' "$(bash "$C" events | wc -l | tr -d ' ')" 1
bash "$C" watch; bash "$C" events --ack
sev Stop
check 'states: idle after Stop' "$(bash "$C" states | grep '^W-2' | cut -f3,6)" "$(printf 'idle\t')"
kill "$LIVE" 2>/dev/null
check 'states: the agent gone, unknown' "$(sleep 0.2; bash "$C" states | grep '^W-2' | cut -f3)" unknown

# --- gh_state: the default for github.com, with the same marker rule
cat >"$W/bin/gh" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"state":"OPEN","isDraft":false,"headRefOid":"abc","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"}],
 "comments":[{"author":{"login":"me"},"body":"(agent, per the user) done","updatedAt":"2026-01-03T00:00:00Z"},
             {"author":{"login":"me"},"body":"(agents disagree here","updatedAt":"2026-01-02T00:00:00Z"},
             {"author":{"login":"ci[bot]"},"body":"coverage","updatedAt":"2026-01-04T00:00:00Z"}],
 "reviews":[{"author":{"login":"rev"},"body":"> (agent) x\n\nwhy?","submittedAt":"2026-01-01T00:00:00Z"},{"author":{"login":"rev"},"body":""},{"author":{"login":"me"},"body":"draft note","state":"PENDING","submittedAt":"2026-01-05T00:00:00Z"}]}
JSON
EOF
chmod +x "$W/bin/gh"
GS=$(PATH="$W/bin:$PATH" bash -c 'eval "$(sed -n "/^gh_state()/,/^}/p" "$1")"; gh_state x "(agent)"' _ "$C")
check 'gh_state' "$GS" '{"state":"open","draft":false,"head":"abc","ci":"failure","people_at":"2026-01-02T00:00:00Z","people":2}'

QR=$(bash -c 'source /dev/stdin <<<"$(sed -n "/^q()/p" "$1")"; q "it'"'"'s a b"' _ "$C")
check 'q quotes one shell word' "$(eval "printf %s $QR")" "it's a b"
unset ORCA_CLI_COMMAND

# --- setup-status: what /hi:setup shows for hi-crew (#25)
cat >"$T/bin/setuporca" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "orchestration run-list") [ -n "${FAKE_ORCH_OFF:-}" ] && { echo '{"ok":false,"error":{"message":"orchestration is not enabled"}}'; exit 1; }
                            echo '{"ok":true,"result":{"runs":[]}}' ;;
  "skills installed") if [ -n "${FAKE_NO_SKILL:-}" ]; then echo '{"ok":true,"result":{"skills":[{"name":"other"}]}}'
                      else echo '{"ok":true,"result":{"skills":[{"name":"orchestration"}]}}'; fi ;;
  "automations list") printf '%s\n' "${FAKE_AUTOS:-{\"ok\":true,\"result\":{\"automations\":[]}}}" ;;
esac
EOF
chmod +x "$T/bin/setuporca"
ss() { ORCA_CLI_COMMAND="$T/bin/setuporca" bash "$C" setup-status; }
r() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n { print $2 }'; }
rm -f "$HIGHNESS_CONFIG"
out=$(ss)
check 'setup-status: orchestration on' "$(r "$out" orchestration)" on
check 'setup-status: orca skill ok' "$(r "$out" orca-skill)" ok
check 'setup-status: no automation → watch missing' "$(r "$out" watch)" missing
check 'setup-status: crew.agent unset' "$(r "$out" crew.agent)" unset
check 'setup-status: crew.model unset' "$(r "$out" crew.model)" unset
out=$(FAKE_ORCH_OFF=1 FAKE_NO_SKILL=1 ss)
check 'setup-status: orchestration off' "$(r "$out" orchestration)" off
case "$out" in *'orchestration is not enabled'*) ok "setup-status: off carries Orca's message" ;; *) no "setup-status: off carries Orca's message" ;; esac
check 'setup-status: orca skill missing' "$(r "$out" orca-skill)" missing
SELF="$(cd "$HERE/../lib" && pwd)/crew.sh"
out=$(FAKE_AUTOS="$(jq -nc --arg p "sh -lic 'bash \"$SELF\" watch'" '{ok:true,result:{automations:[{name:"hi-crew watch",enabled:true,rrule:"*/10 * * * *",precheck:$p}]}}')" ss)
check 'setup-status: watch runs this crew.sh → ok' "$(r "$out" watch)" ok
# Orca 1.4.256 lists the precheck as {command, timeoutSeconds}, not a string.
out=$(FAKE_AUTOS="$(jq -nc --arg p "sh -lic 'bash \"$SELF\" watch'" '{ok:true,result:{automations:[{name:"hi-crew watch",enabled:true,rrule:"*/10 * * * *",precheck:{command:$p,timeoutSeconds:600}}]}}')" ss)
check 'setup-status: watch precheck as an object → ok' "$(r "$out" watch)" ok
out=$(FAKE_AUTOS='{"ok":true,"result":{"automations":[{"name":"hi-crew watch","enabled":true,"precheck":{"command":"bash /gone/crew.sh watch","timeoutSeconds":600}}]}}' ss)
check 'setup-status: watch precheck object, another crew.sh → stale' "$(r "$out" watch)" stale
out=$(FAKE_AUTOS='{"ok":true,"result":{"automations":[{"name":"hi-crew watch","enabled":true,"precheck":"bash /gone/crew.sh watch"}]}}' ss)
check 'setup-status: watch runs another crew.sh → stale' "$(r "$out" watch)" stale
out=$(FAKE_AUTOS='{"ok":true,"result":{"automations":[{"name":"hi-crew watch","enabled":false,"precheck":""}]}}' ss)
check 'setup-status: watch turned off → disabled' "$(r "$out" watch)" disabled
printf '{"crew":{"agent":"codex","model":null}}\n' >"$HIGHNESS_CONFIG"
out=$(ss)
check 'setup-status: crew.agent set' "$(r "$out" crew.agent)" set
check 'setup-status: crew.model null → default on purpose' "$(r "$out" crew.model)" default
rm -f "$HIGHNESS_CONFIG"

exit $fail
