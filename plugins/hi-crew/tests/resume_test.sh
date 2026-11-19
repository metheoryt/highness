#!/usr/bin/env bash
# crew.sh resume: a worker lost without reporting gets a new one in its own workspace and Run, on
# the spec copy under a resume note; the refusals start nothing — against a fake Orca.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json"
unset ORCA_TERMINAL_HANDLE
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }
S="$T/state/crew"
mkdir -p "$T/bin" "$T/root" "$S/specs" "$S/handles"

# Fake Orca: worker-start keeps its arguments and its spec, and answers a receipt (or fails with
# FAKE_FAIL); worker-show says live for the dispatches in FAKE_LIVE, else what Orca answered for
# a real lost worker (measured); worker-list has ctx_old, exited, in the workspace; the inbox
# holds the "lost" escalation of ctx_old.
cat >"$T/bin/fakeorca" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "orchestration worker-start")
    printf '%s\n' "$*" >>"$FAKE_LOG"
    while [ $# -gt 0 ]; do [ "$1" = --spec-file ] && cp "$2" "$FAKE_LOG.spec"; shift; done
    [ -z "${FAKE_FAIL:-}" ] || { echo '{"ok":false,"error":{"message":"no such terminal"}}'; exit 1; }
    echo '{"ok":true,"result":{"dispatchId":"ctx_new","taskId":"task_new","runId":"run_aaa111"}}' ;;
  "orchestration worker-show")
    case " ${FAKE_LIVE:-} " in
      *" $4 "*) echo '{"ok":true,"result":{"state":"running","stage":"running"}}' ;;
      *) echo '{"ok":true,"result":{"state":"failed","stage":"process_exited","liveness":"exited"}}' ;;
    esac ;;
  "orchestration worker-list") # newest first: a started ctx_new, then ctx_old
    new=''; [ -s "$FAKE_LOG" ] && new=$(printf '{"dispatchId":"ctx_new","liveness":"exited","workspace":"repo1::%s"},' "$FAKE_WS")
    printf '{"ok":true,"result":{"workers":[%s{"dispatchId":"ctx_old","liveness":"exited","workspace":"repo1::%s"}]}}\n' "$new" "$FAKE_WS" ;;
  "orchestration inbox")
    cat <<'JSON'
{"ok":true,"result":{"messages":[
 {"id":"q_heard","run_id":"run_aaa111","type":"question","thread_id":"q_heard","created_at":"2026-01-01T01:00:00Z","body":"Which flag?\nmore","payload":"{\"dispatchId\":\"ctx_old\"}"},
 {"id":"r_heard","run_id":"run_aaa111","type":"status","thread_id":"q_heard","created_at":"2026-01-01T01:05:00Z","body":"Take B\nand say so","payload":null},
 {"id":"q_open","run_id":"run_aaa111","type":"decision_gate","thread_id":"q_open","created_at":"2026-01-01T00:30:00Z","body":"Deploy?","payload":"{\"dispatchId\":\"ctx_old\"}"},
 {"id":"q_kept","run_id":"run_aaa111","type":"question","thread_id":"q_kept","created_at":"2026-01-01T00:40:00Z","body":"Rename it?","payload":"{\"dispatchId\":\"ctx_old\"}"},
 {"id":"m_lost","run_id":"run_aaa111","type":"escalation","thread_id":null,"created_at":"2026-01-01T02:00:00Z","subject":"Worker lost without reporting","body":"Worker term_x is gone (it was closed in Orca) without sending worker_done","payload":"{\"dispatchId\":\"ctx_old\",\"stopReason\":\"lost\"}"}
]}}
JSON
    ;;
  *) echo '{"ok":false}'; exit 1 ;;
esac
EOF
chmod +x "$T/bin/fakeorca"
export ORCA_CLI_COMMAND="$T/bin/fakeorca" FAKE_LOG="$T/starts" FAKE_WS="$T/ws"

# The PR state comes from crew.pr_state: it prints what $T/prstate holds.
jq -n --arg c "cat $T/prstate" '{crew: {pr_state: $c}}' >"$T/user.json"
echo '{"state":"open"}' >"$T/prstate"

git init -q -b feat/ab-1 "$T/ws" 2>/dev/null || { git init -q "$T/ws" && git -C "$T/ws" checkout -q -b feat/ab-1; }
printf 'THE SPEC BODY\n' >"$S/specs/AB-1.md"
echo term_coord >"$S/handles/run_aaa111"
fresh() { # the facts of a worker lost on dispatch ctx_old
  rm -f "$S/AB-1.json" "$FAKE_LOG" "$FAKE_LOG.spec"
  mkdir -p "$S/unsent"   # a reply relay kept: Orca refused it, the worker was gone
  jq -nc '{key: "AB-1", at: "2026-01-01T00:45:00Z", ask: "q_kept", dispatch: "ctx_old", question: "Rename it?",
           body: "Yes, rename it"}' >"$S/unsent/AB-1.jsonl"
  bash "$C" record AB-1 "$(jq -nc --arg ws "$T/ws" --arg root "$T/root" --arg s "$S/specs/AB-1.md" \
    '{title: "First", workspace: $ws, run: "run_aaa111", dispatch: "ctx_old", task: "task_old",
      agent: "claude", model: "opus", root: $root, spec: $s, pr: "https://forge/pr/1"}')"
}

# --- the lost worker shows as an escalation until it is resumed
fresh
check 'before: the lost escalation is open' "$(bash "$C" asks | cut -f1,2,4)" "$(printf 'm_lost\tescalation\tctx_old')"
check 'before: Orca'"'"'s lost notice does not hide an unheard answer' \
  "$(bash "$C" stranded | jq -r '.what + ":" + .ask' | sort | tr '\n' ' ')" 'unanswered:q_open unheard:q_heard unsent:q_kept '

# --- resume
out=$(bash "$C" resume AB-1 2>&1); rc=$?
check 'resume: exit 0' "$rc" 0
has 'resume: prints the receipt' "$out" '"dispatchId":"ctx_new"'
args=$(cat "$FAKE_LOG" 2>/dev/null)
has 'resume: in the recorded workspace, kept open' "$args" "--worktree path:$T/ws --keep-open"
has 'resume: the recorded agent and model' "$args" '--agent claude --model opus'
has 'resume: in the recorded Run, from its coordinator' "$args" '--run run_aaa111 --from term_coord'
has 'resume: a task of its own, named resumed' "$args" '--task-title AB-1: First (resumed)'
case "$args" in *--retry-of*|*"--task "*) no 'resume: a new Task, not a retry';; *) ok 'resume: a new Task, not a retry';; esac
spec=$(cat "$FAKE_LOG.spec" 2>/dev/null)
check 'resume: the note comes first' "$(printf '%s\n' "$spec" | head -1)" '## Resuming AB-1: read this first'
has 'resume: the note names the lost dispatch' "$spec" 'Dispatch ctx_old'
has 'resume: the note names the branch' "$spec" 'on the branch `feat/ab-1`'
has 'resume: the note names the PR' "$spec" 'https://forge/pr/1'
has 'resume: no second PR' "$spec" 'do not open a'
has 'resume: an unheard answer, verbatim' "$spec" "$(printf -- '- It asked: Which flag?\n  The person answered (it never reached that worker; act on it):\n\n  > Take B\n  > and say so')"
has 'resume: a kept reply, verbatim' "$spec" "$(printf -- '- It asked: Rename it?\n  The person answered (it never reached that worker; act on it):\n\n  > Yes, rename it')"
has 'resume: an unanswered ask, to ask again' "$spec" "$(printf -- '- It asked: Deploy?\n  No answer came before it stopped.')"
check 'after: stranded retired' "$(bash "$C" stranded)" ''
check 'resume: the spec copy follows, whole' "$(printf '%s\n' "$spec" | tail -1)" 'THE SPEC BODY'
check 'resume: the copy itself is unchanged' "$(cat "$S/specs/AB-1.md")" 'THE SPEC BODY'
check 'resume: records the new dispatch and task, keeps the old one' \
  "$(bash "$C" get AB-1 | jq -r '[.dispatch, .task, (.resumed | join(",")), .pr, (.resumed_at | test("^[0-9]{4}-") | tostring)] | join("|")')" \
  'ctx_new|task_new|ctx_old|https://forge/pr/1|true'
check 'after: the lost escalation is handled' "$(bash "$C" asks)" ''

# --- a second resume carries the earlier ones
bash "$C" resume AB-1 >/dev/null 2>&1
check 'resume again: both replaced dispatches kept' "$(bash "$C" get AB-1 | jq -r '.resumed | join(",")')" 'ctx_old,ctx_new'

# --- the coordinator's own terminal wins over the kept handle
fresh
ORCA_TERMINAL_HANDLE=term_here bash "$C" resume AB-1 >/dev/null 2>&1
has 'resume: --from this terminal when it has one' "$(cat "$FAKE_LOG")" '--from term_here'

# --- refusals: nothing starts, nothing is recorded
refused() { # <name> <want in the error> [env...]
  local name=$1 want=$2 err; shift 2
  fresh
  err=$(env "$@" bash "$C" resume AB-1 2>&1) && no "$name: exit 0"
  has "$name: says why" "$err" "$want"
  if [ -s "$FAKE_LOG" ]; then no "$name: started nothing"; else ok "$name: started nothing"; fi
  check "$name: facts unchanged" "$(bash "$C" get AB-1 | jq -r .dispatch)" ctx_old
}
echo '{"state":"merged"}' >"$T/prstate"
refused 'merged PR' 'PR is merged'
echo '{"state":"closed"}' >"$T/prstate"
refused 'closed PR' 'PR is closed'
echo '{"state":"open"}' >"$T/prstate"
refused 'live worker' 'not settled' FAKE_LIVE=ctx_old
fresh
err=$(FAKE_FAIL=1 bash "$C" resume AB-1 2>&1) && no 'failed start: exit 0'
has 'failed start: says do not rerun' "$err" 'do not rerun it'
check 'failed start: facts unchanged' "$(bash "$C" get AB-1 | jq -r .dispatch)" ctx_old
rm -f "$FAKE_LOG"

fresh; mv "$T/ws" "$T/ws.away"
err=$(bash "$C" resume AB-1 2>&1) && no 'workspace gone: exit 0'
has 'workspace gone: says so' "$err" 'workspace is gone'
[ -s "$FAKE_LOG" ] && no 'workspace gone: started nothing' || ok 'workspace gone: started nothing'
mv "$T/ws.away" "$T/ws"

fresh; mv "$S/specs/AB-1.md" "$T/spec.away"
err=$(bash "$C" resume AB-1 2>&1) && no 'no spec copy: exit 0'
has 'no spec copy: says so' "$err" 'no spec copy'
mv "$T/spec.away" "$S/specs/AB-1.md"

err=$(bash "$C" resume AB-9 2>&1) && no 'no facts: exit 0'
has 'no facts: says so' "$err" 'no open facts for AB-9'

# --- an unreadable PR state warns and resumes
fresh; echo 'not json' >"$T/prstate"
err=$(bash "$C" resume AB-1 2>&1 >/dev/null); rc=$?
check 'unknown PR state: resumes' "$rc" 0
has 'unknown PR state: warns' "$err" 'could not read the state'

exit $fail
