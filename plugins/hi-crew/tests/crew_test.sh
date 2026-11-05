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

# --- run id
if bash "$C" run >/dev/null; then no 'no run at first'; else ok 'no run at first'; fi
bash "$C" run run_abc123
check 'run stored' "$(bash "$C" run)" 'run_abc123'
if bash "$C" run notarun 2>/dev/null; then no 'bad run id refused'; else ok 'bad run id refused'; fi

# --- open questions: a fake orca prints a fixed inbox
mkdir -p "$T/bin"
cat >"$T/bin/fakeorca" <<'EOF'
#!/bin/sh
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
 {"id":"msg_g1","run_id":"run_abc123","type":"decision_gate","thread_id":"msg_g1","created_at":"2026-01-01T14:00:00Z","body":"Deploy to prod?","payload":"{\"dispatchId\":\"ctx_d\"}"}
]}}
JSON
EOF
chmod +x "$T/bin/fakeorca"
check 'asks: open question, live escalation and gate of this Run only' "$(ORCA_CLI_COMMAND="$T/bin/fakeorca" bash "$C" asks)" "$(printf 'msg_q2\tquestion\tctx_b\t2026-01-01T11:00:00Z\tOpen one?\nmsg_e1\tescalation\tctx_c\t2026-01-01T13:00:00Z\tStopped: no token\nmsg_g1\tdecision_gate\tctx_d\t2026-01-01T14:00:00Z\tDeploy to prod?')"
check 'reports: latest worker_done per dispatch' "$(ORCA_CLI_COMMAND="$T/bin/fakeorca" bash "$C" reports)" "$(printf 'ctx_a\t2026-01-01T09:30:00Z\tsucceeded\tDone A')"

# --- spec
printf 'Line one of the brief.\nLine & two with {{KEY}} literal.\n' >"$T/brief"
out=$(cd "$T" && bash "$C" spec --key ABC-9 --title 'Do the thing' --brief-file "$T/brief")
case "$out" in *'Ticket ABC-9: Do the thing'*) ok 'spec title' ;; *) no 'spec title' ;; esac
case "$out" in *'Line & two with {{KEY}} literal.'*) ok 'brief copied verbatim' ;; *) no 'brief copied verbatim' ;; esac
case "$out" in *'start with `ABC-9: `'*) ok 'key in commit rule' ;; *) no 'key in commit rule' ;; esac
case "$out" in *'`(agent)`, so people'*) ok 'default marker' ;; *) no 'default marker' ;; esac
case "$out" in *'(none configured'*) ok 'default process' ;; *) no 'default process' ;; esac
printf '{"crew":{"process":"Use the team-task skill.\\nThen the team-pr skill.","marker":"[bot]"}}' >"$HIGHNESS_CONFIG"
out=$(cd "$T" && bash "$C" spec --key ABC-9 --title 'T' --brief-file "$T/brief")
case "$out" in *'Use the team-task skill.'*'Then the team-pr skill.'*) ok 'process from config' ;; *) no 'process from config' ;; esac
case "$out" in *'`[bot]`, so people'*) ok 'marker from config' ;; *) no 'marker from config' ;; esac
left=$(printf '%s\n' "$out" | grep -v 'literal\.$' | grep -c '{{')
check 'no placeholder left' "$left" 0
if bash "$C" spec --key ABC-9 2>/dev/null; then no 'spec needs a title'; else ok 'spec needs a title'; fi

exit $fail
