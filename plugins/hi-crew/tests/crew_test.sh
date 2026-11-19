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

# --- choices: append-only, kept across close
bash "$C" choice ABC-1 '{"question":"q1","took":"option","picked":"A"}' || no 'choice appends'
bash "$C" choice ABC-2 '{"question":"q2","took":"own","reply":"neither: C"}' || no 'choice appends a second'
check 'choices lists every ticket' "$(bash "$C" choices | jq -r '.key + ":" + .took' | tr '\n' ' ')" 'ABC-1:option ABC-2:own '
check 'choices of one ticket, closed or not' "$(bash "$C" choices ABC-1 | jq -r '.question + " " + .picked')" 'q1 A'
check 'a choice carries a time' "$(bash "$C" choices ABC-2 | jq -r '.at | test("^[0-9]{4}-")')" 'true'
if bash "$C" choice ABC-1 '"x"' 2>/dev/null; then no 'non-object choice refused'; else ok 'non-object choice refused'; fi
if bash "$C" choice '../evil' '{}' 2>/dev/null; then no 'bad choice key refused'; else ok 'bad choice key refused'; fi

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
if [ "$2" = reply ]; then
  [ -z "${FAKE_REPLY_FAIL:-}" ] || { echo '{"ok":false,"error":{"code":"dispatch_inactive"}}'; exit 1; }
  printf '%s|%s\n' "$4" "$6" >>"$FAKE_SENT"; echo '{"ok":true,"result":{}}'; exit 0
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

# --- relay: the reply and its choice lines in one step; --gaps: answers sent any other way
export FAKE_SENT="$T/sent"; : >"$FAKE_SENT"
bash "$C" record ABC-2 '{"dispatch":"ctx_b"}'
bash "$C" record ABC-6 '{"run":"run_abc123","dispatch":"ctx_a"}'; bash "$C" close ABC-6
check 'gaps: a reply sent without relay, keyed through closed facts' "$(bash "$C" choices --gaps)" "$(printf 'ABC-6\tmsg_q1\t2026-01-01T10:05:00Z\tAnswered one?')"
lines() { wc -l <"$HIGHNESS_STATE/crew/choices.jsonl" | tr -d ' '; }
n0=$(lines)
printf '{"points":[]}' >"$T/r-bad"
if bash "$C" relay ABC-2 "$T/r-bad" 2>/dev/null; then no 'relay refuses a reply file with no body'; else ok 'relay refuses a reply file with no body'; fi
printf '{"body":"yes","points":[]}' >"$T/r-min"
if bash "$C" relay ABC-2 --id msg_e1 "$T/r-min" 2>/dev/null; then no 'relay refuses an escalation'; else ok 'relay refuses an escalation'; fi
case "$(FAKE_REPLY_FAIL=1 bash "$C" relay ABC-2 "$T/r-min" 2>&1; echo "exit $?")" in
  *'was not sent, nothing recorded'*'exit 2') ok 'relay fails when the reply fails' ;; *) no 'relay fails when the reply fails' ;; esac
check 'relay: nothing sent or recorded on a refusal or a failed send' "$(wc -c <"$FAKE_SENT" | tr -d ' ') $(lines)" "0 $n0"
jq -n '{body: "The person'"'"'s decisions:\n(1) A.\n(2) their own: C.",
  points: [{question: "first", options: [{name: "A", loses: "x", leans_on: "no rule: y"}], took: "option", picked: "A", reply: "A"},
           {question: "second", took: "own", picked: "C", reply: "neither: C"}]}' >"$T/r-two"
bash "$C" relay ABC-2 "$T/r-two" || no 'relay finds the ticket'"'"'s one open ask'
check 'relay: the reply went to that ask, body verbatim' "$(head -1 "$FAKE_SENT")" "msg_q2|$(jq -r .body "$T/r-two" | head -1)"
check 'relay: one choice line per point' "$(( $(lines) - n0 ))" 2
check 'relay: a line carries the point, the ask and what was sent' \
  "$(bash "$C" choices ABC-2 | tail -2 | jq -r '[.key, .question, .took, .picked, .reply, .ask, .run, .dispatch, .asked_at, .ask_body, (.sent | split("\n")[0]), (.options // [] | length | tostring)] | join("|")' | tr '\n' ' ')" \
  "ABC-2|first|option|A|A|msg_q2|run_abc123|ctx_b|2026-01-01T11:00:00Z|Open one? second line|The person's decisions:|1 ABC-2|second|own|C|neither: C|msg_q2|run_abc123|ctx_b|2026-01-01T11:00:00Z|Open one? second line|The person's decisions:|0 "
bash "$C" relay ABC-6 --id msg_q1 "$T/r-min" || no 'relay with --id'
check 'relay: no points still leaves one line' "$(bash "$C" choices ABC-6 | jq -r '[.ask, (.took // "null"), .sent] | join("|")')" 'msg_q1|null|yes'
check 'gaps: a relayed answer is no gap' "$(bash "$C" choices --gaps)" ''
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
# From a child clone the umbrella lists: the umbrella's sections, run with {{ROOT}} the umbrella.
printf 'kid\n' >"$S/repos.txt"; mkdir -p "$S/kid" && git -C "$S/kid" init -q
out=$(cd "$S/kid" && bash "$C" sections)
check 'sections: from a child clone, {{ROOT}} is the umbrella' "$(printf '%s\n' "$out" | jq -r 'select(.section == "Tickets" and .group == null) | .title')" "$(cd "$S" && pwd -P) (bot)"
rm -rf "$S/kid" "$S/repos.txt"

# The hi-threads journal, when there is one, comes first as section "threads": this project only.
mkdir -p "$HIGHNESS_STATE/threads"
SP=$(cd "$S" && pwd -P)
jq -n --arg p "$SP" '{threads: [
  {id: "t1", project: $p, title: "Login fix", status: "paused", waits_on: "agent", next: "add a test",
   open_items: ["add a test"], ticket: "AB-1", pr: "", updated: "2020-01-02T00:00:00Z", updated_epoch: 2,
   last_session: "s1", last_cwd: $p},
  {id: "t2", project: $p, title: "Old", status: "done", waits_on: "none", next: "", open_items: [],
   ticket: "", pr: "", updated: "2020-01-01T00:00:00Z", updated_epoch: 1},
  {id: "t3", project: "/elsewhere", title: "Other", status: "active", waits_on: "agent", next: "",
   open_items: [], ticket: "", pr: "", updated: "2020-01-01T00:00:00Z", updated_epoch: 1}]}' \
  >"$HIGHNESS_STATE/threads/threads.json"
out=$(cd "$S" && bash "$C" sections)
check 'sections: open threads of this project first' "$(printf '%s\n' "$out" | head -1 | jq -r '[.section, .group, .title, .resume] | join("|")')" "threads|you|Login fix (AB-1)|cd '$SP' && claude --resume s1"
check 'sections: no done or foreign threads' "$(printf '%s\n' "$out" | jq -r 'select(.section == "threads") | .title' | wc -l | tr -d ' ')" '1'
rm -rf "$HIGHNESS_STATE/threads"

# --- spec (the fake orca: spec asks this session's Run for a pinned root, and must not reach a real one)
export ORCA_CLI_COMMAND="$T/bin/fakeorca"
printf 'Line one of the brief.\nLine & two with {{KEY}} literal.\n' >"$T/brief"
out=$(cd "$T" && bash "$C" spec --key ABC-9 --title 'Do the thing' --brief-file "$T/brief")
case "$out" in *'Ticket ABC-9: Do the thing'*) ok 'spec title' ;; *) no 'spec title' ;; esac
case "$out" in *'Line & two with {{KEY}} literal.'*) ok 'brief copied verbatim' ;; *) no 'brief copied verbatim' ;; esac
case "$out" in *'start with `ABC-9: `'*) ok 'key in commit rule' ;; *) no 'key in commit rule' ;; esac
case "$out" in *'`(agent)`, so people'*) ok 'default marker' ;; *) no 'default marker' ;; esac
case "$out" in *'(none configured'*) ok 'default process' ;; *) no 'default process' ;; esac
case "$out" in *'- Never merge. That is a person'*) ok 'default: never merge' ;; *) no 'default: never merge' ;; esac
case "$out" in *'Merge your own pull request'*) no 'default: no merge-on-green line' ;; *) ok 'default: no merge-on-green line' ;; esac
case "$out" in *"record it, so the coordinator's watch"*"\`HIGHNESS_STATE='$HIGHNESS_STATE' bash '$(cd "$HERE/../lib" && pwd)/crew.sh' record ABC-9 '{\"pr\":\"<the PR url>\"}'\`"*) ok 'spec: the worker records its PR, in this state dir' ;; *) no 'spec: the worker records its PR, in this state dir' ;; esac
case "$out" in *'{{CREW}}'*) no 'spec: {{CREW}} filled' ;; *) ok 'spec: {{CREW}} filled' ;; esac
case "$out" in *'background and wait for its completion notification; never'*'sleep-poll'*) ok 'spec: background test runs, no sleep-poll' ;; *) no 'spec: background test runs, no sleep-poll' ;; esac
# A copy of the spec is kept under the state dir, the same text as printed (highness#85).
check 'spec: a copy is kept for the key' "$(cat "$HIGHNESS_STATE/crew/specs/ABC-9.md" 2>/dev/null)" "$out"
check 'spec: no temp file left' "$(ls "$HIGHNESS_STATE/crew/specs" | tr '\n' ' ')" 'ABC-9.md '
out2=$(cd "$T" && HIGHNESS_STATE="$T/ro" bash -c 'mkdir -p "$HIGHNESS_STATE" && chmod 500 "$HIGHNESS_STATE" && bash "$0" spec --key ABC-9 --title "Do the thing" --brief-file "$1"' "$C" "$T/brief"); rc=$?
chmod 700 "$T/ro" 2>/dev/null
check 'spec: an unwritable state dir still prints the spec' "$rc $(printf '%s' "$out2" | head -1)" '0 Ticket ABC-9: Do the thing'

# --- reentry: SessionStart(compact) points a worker back at its spec (highness#54)
spec_out=$out   # the spec checks below read it again
mkdir -p "$T/ws9/sub" "$T/elsewhere"
bash "$C" record ABC-9 "{\"title\":\"Do the thing\",\"workspace\":\"$T/ws9\",\"spec\":\"$HIGHNESS_STATE/crew/specs/ABC-9.md\",\"pr\":\"https://forge/pr/9\"}"
ctx() { printf '%s' "$1" | jq -r '.hookSpecificOutput | .hookEventName + "|" + .additionalContext'; }
out=$(printf '{"hook_event_name":"SessionStart","source":"compact","cwd":"%s"}' "$T/ws9/sub" | bash "$C" reentry); rc=$?
check 'reentry: exit 0' "$rc" 0
case "$(ctx "$out")" in "SessionStart|hi-crew: this session is the ticket worker for ABC-9 (Do the thing)"*"Re-read it before your next step: $HIGHNESS_STATE/crew/specs/ABC-9.md"*"Your PR: https://forge/pr/9."*) ok 'reentry: names the ticket, the spec and the PR' ;; *) no "reentry: names the ticket, the spec and the PR: [$out]" ;; esac
case "$out" in *'Line one of the brief'*) no 'reentry: the spec is pointed at, not inlined' ;; *) ok 'reentry: the spec is pointed at, not inlined' ;; esac
out=$(printf '{"cwd":"%s"}' "$T/elsewhere" | bash "$C" reentry); rc=$?
check 'reentry: outside a workspace, silence' "$rc|$out" '0|'
out=$(printf '{"cwd":"%s"}' "${T}/ws9x" | bash "$C" reentry)
check 'reentry: a sibling path with the workspace as prefix is not it' "$out" ''
bash "$C" record ABC-9 '{"spec":"/nonexistent/spec.md"}'
case "$(ctx "$(printf '{"cwd":"%s"}' "$T/ws9" | bash "$C" reentry)")" in *'No copy of it was saved'*'first prompt'*) ok 'reentry: a missing spec sends to the first prompt' ;; *) no 'reentry: a missing spec sends to the first prompt' ;; esac
out=$(printf 'not json' | bash "$C" reentry); rc=$?
check 'reentry: a bad payload is silence' "$rc|$out" '0|'
bash "$C" close ABC-9 2>/dev/null
check 'reentry: a closed ticket is silence' "$(printf '{"cwd":"%s"}' "$T/ws9" | bash "$C" reentry)" ''
if jq -e '.hooks.SessionStart[] | select(.matcher == "compact") | .hooks[] | select(.command | test("crew.sh\\\" reentry"))' "$HERE/../hooks/hooks.json" >/dev/null; then ok 'hooks: SessionStart(compact) runs reentry'; else no 'hooks: SessionStart(compact) runs reentry'; fi
out=$spec_out
case "$out" in *'Change files with the Edit/Write tools, never with a python/sed/perl heredoc in Bash.'*) ok 'edit-not-heredoc rule' ;; *) no 'edit-not-heredoc rule' ;; esac
# The already-done check comes before the worker takes the ticket or changes anything.
case "$out" in *'check it is not already done (below) before'*'## Already done?'*'## Asking'*) ok 'already-done check, before taking the ticket' ;; *) no 'already-done check, before taking the ticket' ;; esac
case "$out" in *'Only landed work counts'*'An open pull request, or a branch from an earlier attempt at this ticket, is'*) ok 'only landed work counts as done' ;; *) no 'only landed work counts as done' ;; esac
case "$out" in *'**All of it is done:** open no pull request.'*'subject that starts `already done:`'*) ok 'already done: no PR, reported as such' ;; *) no 'already done: no PR, reported as such' ;; esac
# The ask: research first, options with what each loses and what it leans on, a direction note.
case "$out" in *'Before you ask, do everything you can'*) ok 'ask: research before asking' ;; *) no 'ask: research before asking' ;; esac
case "$out" in *'`loses:`'*'`leans on:`'*'`no rule: '*'what would change your mind'*) ok 'ask: options carry loses and leans on' ;; *) no 'ask: options carry loses and leans on' ;; esac
case "$out" in *'take it; do not ask to be safe'*) ok 'ask: obvious calls are taken' ;; *) no 'ask: obvious calls are taken' ;; esac
case "$out" in *'write your direction in three lines'*'start without waiting'*) ok 'direction note before building' ;; *) no 'direction note before building' ;; esac
# A scope note in a ticket comment binds; a ticket closes only when every item was reproduced (highness#71).
case "$out" in *'comments included'*'A comment from'*'binds like the description'*) ok 'ticket comments bind like the description' ;; *) no 'ticket comments bind like the description' ;; esac
case "$out" in *'"Not covered" heading'*'`Refs #N`, never'*'`Closes #N`'*) ok 'unreproduced items: Not covered and Refs, not Closes' ;; *) no 'unreproduced items: Not covered and Refs, not Closes' ;; esac
case "$out" in *'If you do work that belongs to another open ticket, comment on that ticket'*) ok 'out-of-band work recorded on its ticket' ;; *) no 'out-of-band work recorded on its ticket' ;; esac
# The coordinator recognizes an already-done report by the subject prefix the spec gives.
for s in start agenda; do
  if grep -q '`already done:`' "$HERE/../skills/$s/SKILL.md"; then ok "$s skill reads the already-done subject"; else no "$s skill reads the already-done subject"; fi
done
# A thread's decisions go to its own session first; the resume line only when that failed.
case "$(cat "$HERE/../skills/agenda/SKILL.md")" in *'threads-read.sh" relay'*'`sent`'*'`started`'*'`manual`'*) ok 'agenda: relay to the thread, then a new terminal, then the resume line' ;; *) no 'agenda: relay to the thread, then a new terminal, then the resume line' ;; esac
case "$(cat "$HERE/../skills/agenda/SKILL.md")" in *'`busy`'*'do not wait'*) ok 'agenda: a busy thread session is said, not waited out' ;; *) no 'agenda: a busy thread session is said, not waited out' ;; esac
# A held autostart is read in step 1, before the "nothing on the person" stop: a hold starts no
# ticket, so the agenda of a box whose autostart is stuck has none (highness#59).
case "$(sed -n '/^## 1\. Gather/,/^2\. /p' "$HERE/../skills/agenda/SKILL.md")" in
  *'bash "$C" held'*'no held autostart: say there is'*) ok 'agenda: a held autostart is read before the empty stop' ;;
  *) no 'agenda: a held autostart is read before the empty stop' ;;
esac
if grep -q 'a held autostart' "$HERE/../skills/agenda/SKILL.md"; then ok 'agenda: the held line is shown'; else no 'agenda: the held line is shown'; fi
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
# crew.merge: on_green swaps the merge line for one, and only one; anything else is refused.
printf '{"crew":{"merge":"on_green"}}' >"$HIGHNESS_CONFIG"
out=$(cd "$T" && bash "$C" spec --key ABC-9 --title 'T')
case "$out" in *'- Merge your own pull request once it is ready for review and its checks pass'*) ok 'on_green: merge line' ;; *) no 'on_green: merge line' ;; esac
case "$out" in *'Never merge'*) no 'on_green: no never-merge line' ;; *) ok 'on_green: no never-merge line' ;; esac
case "$out" in *'Never resolve review threads, never force-push'*) ok 'on_green: threads and force-push rules kept' ;; *) no 'on_green: threads and force-push rules kept' ;; esac
printf '{"crew":{"merge":"always"}}' >"$HIGHNESS_CONFIG"
if (cd "$T" && bash "$C" spec --key ABC-9 --title 'T' >/dev/null 2>&1); then no 'unknown crew.merge refused'; else ok 'unknown crew.merge refused'; fi
printf '{}' >"$HIGHNESS_CONFIG"

# --- an umbrella: a spec built from a child clone carries the umbrella's process, merge and root
U="$T/umb"; mkdir -p "$U/.claude" && git -C "$U" init -q
printf '{"crew":{"process":"Umbrella process at {{ROOT}}/tools.","merge":"on_green","marker":"[u]"}}' >"$U/.claude/highness.json"
printf 'kid git@github.com:someone/kid.git\n' >"$U/repos.txt"
mkdir -p "$U/kid" "$U/stray" && git -C "$U/kid" init -q && git -C "$U/stray" init -q
UP=$(cd "$U" && pwd -P)
out=$(cd "$U/kid" && bash "$C" spec --key ABC-9 --title 'T')
case "$out" in *"Umbrella process at $UP/tools."*) ok 'umbrella: a child clone spec has its process, {{ROOT}} the umbrella' ;; *) no 'umbrella: a child clone spec has its process, {{ROOT}} the umbrella' ;; esac
case "$out" in *'- Merge your own pull request once it is ready'*) ok "umbrella: a child clone spec has its merge line" ;; *) no "umbrella: a child clone spec has its merge line" ;; esac
case "$out" in *'`[u]`, so people'*) ok 'umbrella: a child clone spec has its marker' ;; *) no 'umbrella: a child clone spec has its marker' ;; esac
case "$out" in *'(none configured'*) no 'umbrella: no "none configured" from a child clone' ;; *) ok 'umbrella: no "none configured" from a child clone' ;; esac
out=$(cd "$U/stray" && bash "$C" spec --key ABC-9 --title 'T')
case "$out" in *'(none configured'*) ok 'umbrella: an unlisted clone gets no process' ;; *) no 'umbrella: an unlisted clone gets no process' ;; esac
out=$(cd "$T" && bash "$C" spec --key ABC-9 --title 'T' --root "$U")
case "$out" in *"Umbrella process at $U/tools."*) ok 'spec --root reads the settings there' ;; *) no 'spec --root reads the settings there' ;; esac
# The root is pinned when the Run is registered; a later cd into a clone does not move it.
(cd "$U" && bash "$C" run run_umb1)
check 'root: pinned at the Run registration' "$(cd "$U/stray" && FAKE_CURRENT=run_umb1 bash "$C" root)" "$UP"
out=$(cd "$U/stray" && FAKE_CURRENT=run_umb1 bash "$C" spec --key ABC-9 --title 'T')
case "$out" in *"Umbrella process at $UP/tools."*) ok 'spec: the pinned root wins over the cwd' ;; *) no 'spec: the pinned root wins over the cwd' ;; esac
(cd "$U/stray" && bash "$C" run run_umb1)
check 'root: a second registration keeps the first pin' "$(FAKE_CURRENT=run_umb1 bash "$C" root)" "$UP"
check 'root: with no Run, derived from the cwd' "$(cd "$U/kid" && bash "$C" root)" "$UP"
check 'root: <dir> re-pins it' "$(FAKE_CURRENT=run_umb1 bash "$C" root "$U/stray")" "$(cd "$U/stray" && pwd -P)"
if bash "$C" root "$U" 2>/dev/null; then no 'root <dir>: refused with no Run'; else ok 'root <dir>: refused with no Run'; fi
unset ORCA_CLI_COMMAND

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
if [ "$2" = worker-list ]; then
  if [ -n "${FAKE_WORKERS:-}" ]; then printf '%s\n' "$FAKE_WORKERS"; else echo '{"ok":true,"result":{"workers":[]}}'; fi
  exit 0
fi
printf '%s\n' "$*" >>"$SENT"
case "$*" in
  *'--to dispatch:'*) if [ -n "${FAKE_SEND_FAIL:-}" ]; then echo '{"ok":false,"error":{"code":"dispatch_inactive"}}'; exit 1; fi
                      echo '{"ok":true}' ;;
esac
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
check 'a worker event with no Dispatch wakes the coordinator' "$(grep 'CI failed on bbbbbbbb' "$W/state/crew/watch/events" | cut -f5,6)" "$(printf 'CI failed on bbbbbbbb\tcoordinator')"
# --- who is woken: the worker by a round to its Dispatch, the coordinator when a person is needed
mkdir -p "$W/ws5"; WS5=$(cd "$W/ws5" && pwd -P)
bash "$C" watch; bash "$C" events --ack; : >"$SENT"  # settle the closed PR above
export FAKE_WORKERS="$(jq -nc --arg ws "ws-id::$WS5" '{ok:true,result:{workers:[
  {dispatchId:"ctx_other",liveness:"live",workspace:"ws-id::/elsewhere"},
  {dispatchId:"ctx_old",liveness:"exited",workspace:$ws},
  {dispatchId:"ctx_new",liveness:"live",workspace:$ws}]}}')"
bash "$C" record W-5 "{\"pr\":\"https://forge/pr/5\",\"run\":\"run_w1\",\"root\":\"$WR\",\"workspace\":\"$WS5\",\"dispatch\":\"ctx_old\"}"
st5() { printf '%s\n' "$1" >"$WR/state-5.json"; bash "$C" watch; }
st5 '{"state":"open","ci":"pending","head":"c1","people":0}'
st5 '{"state":"open","ci":"pending","head":"c1","people":0,"findings":4,"approvals":["lead"]}'
check 'findings and approvals appearing are no event' "$(bash "$C" events)$(cat "$SENT")" ''
st5 '{"state":"open","ci":"failure","head":"c1c1c1c1c1","people":0,"findings":4,"approvals":["lead"]}'
check 'CI failure wakes the worker' "$(bash "$C" events | cut -f2,5,6)" "$(printf 'W-5\tCI failed on c1c1c1c1\tworker')"
case "$(cat "$SENT")" in *'send --to dispatch:ctx_new --from term_coord --type status --subject W-5: CI failed on c1c1c1c1'*) ok 'a round to the live Dispatch in its workspace' ;; *) no "worker round: $(cat "$SENT")" ;; esac
check 'the coordinator is not woken for it' "$(grep -c 'run:run_w1' "$SENT")" 0
check 'the Dispatch found is recorded' "$(bash "$C" get W-5 | jq -r .dispatch)" ctx_new
st5 '{"state":"open","ci":"failure","head":"c1c1c1c1c1","people":0,"findings":4,"approvals":["lead"]}'
check 'the same failure is told once' "$(bash "$C" events | wc -l | tr -d ' ')" 1
st5 '{"state":"open","ci":"failure","head":"c2c2c2c2c2","people":0,"findings":4,"approvals":["lead"]}'
check 'a failure on a new head is told again' "$(bash "$C" events | tail -1 | cut -f5)" 'CI failed on c2c2c2c2'
st5 '{"state":"open","ci":"success","head":"c3","people":0,"findings":6,"approvals":["lead"]}'
check 'review bot findings wake the worker' "$(bash "$C" events | tail -1 | cut -f5,6)" "$(printf '2 new finding(s) from review bots\tworker')"
bash "$C" events --ack; : >"$SENT"
st5 '{"state":"open","ci":"success","head":"c3","people":0,"findings":6,"approvals":["lead","rev"]}'
check 'an approval wakes the coordinator' "$(bash "$C" events | cut -f5,6)" "$(printf 'approved by rev\tcoordinator')"
case "$(cat "$SENT")" in *'send --to run:run_w1 --from term_coord --type status --subject W-5: approved by rev'*) ok 'the approval goes to the Run' ;; *) no "approval send: $(cat "$SENT")" ;; esac
# The author's own label change, a cross-reference, a resolve: none is in the state, so it stays.
st5 '{"state":"open","ci":"success","head":"c3","people":0,"findings":6,"approvals":["lead","rev"]}'
check 'an approval is told once' "$(bash "$C" events | wc -l | tr -d ' ')" 1
cp "$WR/.claude/highness.json" "$W/cfg.bak"
jq '.crew.merge = "on_green"' "$W/cfg.bak" >"$WR/.claude/highness.json"
st5 '{"state":"open","ci":"success","head":"c3","people":0,"findings":6,"approvals":["lead","new"]}'
check 'on_green: an approval wakes the worker, who merges' "$(bash "$C" events | tail -1 | cut -f5,6)" "$(printf 'approved by new\tworker')"
mv "$W/cfg.bak" "$WR/.claude/highness.json"
bash "$C" events --ack; : >"$SENT"
FAKE_SEND_FAIL=1 st5 '{"state":"open","ci":"failure","head":"c4c4c4c4c4","people":0,"findings":6,"approvals":["lead","new"]}'
check 'a refused round wakes the coordinator instead' "$(bash "$C" events | cut -f5,6)" "$(printf 'CI failed on c4c4c4c4\tcoordinator')"
check 'refused round: the coordinator got it' "$(grep -c 'send --to run:run_w1 .*W-5: CI failed on c4c4c4c4' "$SENT")" 1
unset FAKE_WORKERS
bash "$C" close W-5 2>/dev/null; bash "$C" events --ack; : >"$SENT"
# --- no `pr` in the facts: the watch finds the PR by the workspace's branch, and records it
mkdir -p "$W/bin3" "$W/ws3"; git -C "$W/ws3" init -q; git -C "$W/ws3" checkout -q -b feat-3
WS3=$(cd "$W/ws3" && pwd -P)
cat >"$W/bin3/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$PWD $*" >>"$GH_LOG"
[ "$1 $2" = "pr list" ] || exit 1
case " $* " in
  *' --head feat-3 '*) echo '[{"number":8,"url":"https://forge/pr/8"},{"number":9,"url":"https://forge/pr/9"}]' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$W/bin3/gh"; export GH_LOG="$W/gh.log"; : >"$GH_LOG"
bash "$C" events --ack
echo '{"state":"open","ci":"pending","people":0}' >"$WR/state-9.json"
bash "$C" record W-3 "{\"run\":\"run_w1\",\"root\":\"$WR\",\"workspace\":\"$WS3\",\"branch\":\"old-name\"}"
PATH="$W/bin3:$PATH" bash "$C" watch
check 'watch: a PR found by branch is recorded' "$(bash "$C" get W-3 | jq -r .pr)" https://forge/pr/9
check 'watch: asked from the workspace, by the branch checked out there' \
  "$(grep -c "^$WS3 pr list --head feat-3 " "$GH_LOG")" 1
check 'watch: the found PR gets its first look' "$(jq -r .state "$W/state/crew/watch/W-3.json")" open
check 'watch: a first look at a found PR is no event' "$(bash "$C" events | cut -f2 | grep -c '^W-3$')" 0
PATH="$W/bin3:$PATH" bash "$C" watch
check 'watch: a recorded PR is not looked up again' "$(grep -c 'pr list' "$GH_LOG")" 1
git -C "$W/ws3" checkout -q -b no-pr-yet
bash "$C" record W-4 "{\"run\":\"run_w1\",\"root\":\"$WR\",\"workspace\":\"$WS3\"}"
PATH="$W/bin3:$PATH" bash "$C" watch
check 'watch: no PR on the branch, none recorded' "$(bash "$C" get W-4 | jq -r '.pr // "none"')" none
bash "$C" close W-4
# --- close drops the watch's notes on the ticket, and only on it
: >"$W/state/crew/watch/W-3.prompt"; : >"$W/state/crew/watch/W-3.tool"; : >"$W/state/crew/watch/W-3.1.json"
bash "$C" close W-3
check 'close: the watch notes are gone' "$(ls "$W/state/crew/watch" | grep -c '^W-3\.[a-z]')" 0
check 'close: a longer key keeps its notes' "$(ls "$W/state/crew/watch" | grep -c '^W-3\.1\.json$')" 1
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
check 'gh_state' "$GS" '{"state":"open","draft":false,"head":"abc","ci":"failure","people_at":"2026-01-02T00:00:00Z","people":2,"findings":0,"approvals":[]}'
# Bots on normal accounts (crew.bots), the forge Actions user, review bots' findings, approvals.
cat >"$W/bin/gh" <<'EOF'
#!/bin/sh
if [ "$1" = api ]; then
  case "$*" in *'repos/o/r/pulls/3/comments'*) ;; *) exit 1 ;; esac
  # --paginate prints one array per page
  echo '[{"user":{"login":"reviewer-x[bot]","type":"Bot"},"body":"nit: rename","updated_at":"2026-01-10T00:00:00Z"}]'
  echo '[{"user":{"login":"rev","type":"User"},"body":"rename?","updated_at":"2026-01-03T12:00:00Z"},
         {"user":{"login":"me","type":"User"},"body":"(agent) renamed","updated_at":"2026-01-11T00:00:00Z"}]'
  exit 0
fi
cat <<'JSON'
{"state":"OPEN","isDraft":true,"headRefOid":"abc","statusCheckRollup":[],
 "comments":[{"author":{"login":"me"},"body":"(agents disagree here","updatedAt":"2026-01-02T00:00:00Z"},
             {"author":{"login":"forgejo-actions"},"body":"summary, rewritten on push","updatedAt":"2026-01-06T00:00:00Z"},
             {"author":{"login":"gatekeeper"},"body":"ok to merge","updatedAt":"2026-01-07T00:00:00Z"}],
 "reviews":[{"author":{"login":"rev"},"body":"why?","state":"COMMENTED","submittedAt":"2026-01-01T00:00:00Z"},
            {"author":{"login":"rev"},"body":"LGTM","state":"APPROVED","submittedAt":"2026-01-08T00:00:00Z"},
            {"author":{"login":"gatekeeper"},"body":"fix the tests","state":"CHANGES_REQUESTED","submittedAt":"2026-01-09T00:00:00Z"},
            {"author":{"login":"reviewer-x"},"body":"Reviewed 3 files, no comments","state":"COMMENTED","submittedAt":"2026-01-09T00:00:00Z"}],
 "latestReviews":[{"author":{"login":"rev"},"state":"APPROVED"},{"author":{"login":"lead"},"state":"APPROVED"},
                  {"author":{"login":"gatekeeper"},"state":"CHANGES_REQUESTED"},{"author":{"login":"merge-bot[bot]"},"state":"APPROVED"}]}
JSON
EOF
GS=$(PATH="$W/bin:$PATH" bash -c 'eval "$(sed -n "/^gh_state()/,/^}/p" "$1")"; gh_state https://github.com/o/r/pull/3 "(agent)" "[\"forgejo-actions\",\"gatekeeper\",\"reviewer-x\"]"' _ "$C")
check 'gh_state: bots, findings, approvals' "$GS" '{"state":"open","draft":true,"head":"abc","ci":"","people_at":"2026-01-03T12:00:00Z","people":3,"findings":2,"approvals":["lead","rev"]}'
GS=$(PATH="$W/bin:$PATH" bash -c 'eval "$(sed -n "/^gh_state()/,/^}/p" "$1")"; gh_state https://github.com/o/r/pull/4 "(agent)" "[]"' _ "$C")
check 'gh_state: no inline comments, no state' "$GS" ''
check 'crew.bots adds to the Actions users' "$(cd "$WR" && HIGHNESS_CONFIG="$W/bots.json" bash -c 'printf "{\"crew\":{\"bots\":[\"gatekeeper\"]}}" >"$HIGHNESS_CONFIG"; eval "$(sed -n "/^BOTS_DEFAULT=/p;/^bots_json()/,/^}/p" "$1")"; CONFIG="$2"; bots_json .' _ "$C" "$(cd "$HERE/../lib" && pwd)/config.sh")" '["forgejo-actions","gatekeeper","gitea-actions","github-actions"]'

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
  "automations list") if [ -n "${FAKE_AUTOS:-}" ]; then printf '%s\n' "$FAKE_AUTOS"
                      else echo '{"ok":true,"result":{"automations":[]}}'; fi ;;
  "automations create"|"automations edit")
    while [ $# -gt 0 ]; do [ "$1" = --precheck ] && printf '%s\n' "$2" >"$FAKE_PRE_LOG"; shift; done
    echo '{"ok":true}' ;;
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
check 'setup-status: no preference file → preferences missing' "$(r "$out" preferences)" missing
mkdir -p "$T/store"; echo '# Mine' >"$T/store/values.md"
echo '{"preferences": "'"$T"'/store"}' >"$HIGHNESS_CONFIG"
check 'setup-status: an existing store → preferences ok' "$(r "$(ss)" preferences)" ok
rm -f "$HIGHNESS_CONFIG"
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

# --- the watch through symlinks (#34): a profile's skills/hi-crew linking a checkout, and two
# profiles linking the same one. Expected paths are physical: mktemp's dir may itself be a link.
PLUG=$(cd -P "$HERE/.." && pwd -P)
PSELF="$PLUG/lib/crew.sh"
mkdir -p "$T/profile-a/skills" "$T/profile-b/skills" "$T/copy/lib"
ln -s "$PLUG" "$T/profile-a/skills/hi-crew"
ln -s "$PLUG" "$T/profile-b/skills/hi-crew"
autos() { jq -nc --arg p "$1" '{ok:true,result:{automations:[{name:"hi-crew watch",enabled:true,rrule:"*/10 * * * *",precheck:{command:$p,timeoutSeconds:600}}]}}'; }
ssv() { ORCA_CLI_COMMAND="$T/bin/setuporca" bash "$1/lib/crew.sh" setup-status; }
out=$(FAKE_AUTOS="$(autos "sh -lic 'bash \"$PSELF\" watch'")" ssv "$T/profile-a/skills/hi-crew")
check 'watch via a linked profile, precheck names the checkout → ok' "$(r "$out" watch)" ok
out=$(FAKE_AUTOS="$(autos "sh -lic 'bash \"$T/profile-a/skills/hi-crew/lib/crew.sh\" watch'")" ssv "$PLUG")
check 'watch from the checkout, precheck names a linked profile → ok' "$(r "$out" watch)" ok
out=$(FAKE_AUTOS="$(autos "bash $T/profile-b/skills/hi-crew/lib/crew.sh watch")" ssv "$T/profile-a/skills/hi-crew")
check 'watch: unquoted precheck path via another profile → ok' "$(r "$out" watch)" ok
cp "$PLUG/lib/crew.sh" "$T/copy/lib/crew.sh"
out=$(FAKE_AUTOS="$(autos "sh -lic 'bash \"$T/copy/lib/crew.sh\" watch'")" ssv "$T/profile-a/skills/hi-crew")
check 'watch: a copy of crew.sh elsewhere → stale' "$(r "$out" watch)" stale
export FAKE_PRE_LOG="$T/pre.log"
rm -f "$FAKE_PRE_LOG"
ORCA_CLI_COMMAND="$T/bin/setuporca" bash "$T/profile-a/skills/hi-crew/lib/crew.sh" watch-install >/dev/null
PRE=$(cat "$FAKE_PRE_LOG" 2>/dev/null) || PRE=''
case "$PRE" in *"bash \"$PSELF\" watch"*) ok 'watch-install from a linked profile writes the physical path' ;; *) no "watch-install writes the physical path: got [$PRE]" ;; esac
case "$PRE" in *profile-a*) no 'watch-install names the profile it ran under' ;; *) ok 'watch-install names no profile' ;; esac
out=$(FAKE_AUTOS="$(autos "$PRE")" ssv "$T/profile-b/skills/hi-crew")
check 'watch installed from one profile reads ok from another' "$(r "$out" watch)" ok
rm -f "$FAKE_PRE_LOG"
ORCA_CLI_COMMAND="$T/bin/setuporca" bash "$T/profile-b/skills/hi-crew/lib/crew.sh" watch-install >/dev/null
check 'watch-install writes the same precheck from either profile' "$(cat "$FAKE_PRE_LOG" 2>/dev/null)" "$PRE"
unset FAKE_PRE_LOG
printf '{"crew":{"agent":"codex","model":null}}\n' >"$HIGHNESS_CONFIG"
out=$(ss)
check 'setup-status: crew.agent set' "$(r "$out" crew.agent)" set
check 'setup-status: crew.model null → default on purpose' "$(r "$out" crew.model)" default
rm -f "$HIGHNESS_CONFIG"

exit $fail
