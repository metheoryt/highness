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

# No open ticket at all (an empty crew dir): reentry is silent and exits 0. It used to die on an
# unset `row` under `set -u`, which failed every compaction's SessionStart hook on that box.
err=$(printf '{"cwd":"%s"}' "$T" | bash "$C" reentry 2>&1 >/dev/null); rc=$?
check 'reentry with no open tickets: exit 0, nothing on stderr' "$rc|$err" '0|'
check 'reentry with no open tickets: no context' "$(printf '{"cwd":"%s"}' "$T" | bash "$C" reentry 2>/dev/null)" ''

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
      *) if [ -n "${FAKE_PANE:-}" ]; then
           printf '{"ok":true,"result":{"state":"failed","stage":"process_exited","liveness":"exited","terminal":"%s","terminalState":"retained"}}\n' "$FAKE_PANE"
         else echo '{"ok":true,"result":{"state":"failed","stage":"process_exited","liveness":"exited"}}'; fi ;;
    esac ;;
  "terminal show")
    # A closed pane still answers ok, disconnected (measured); a vanished one is not found.
    case "${FAKE_PANE_GONE:-}" in
      closed) echo '{"ok":true,"result":{"terminal":{"status":null,"connected":false}}}' ;;
      ?*) echo '{"ok":false,"error":{"code":"terminal_not_found"}}'; exit 1 ;;
      *) # FAKE_CUT: a preview cut inside an emoji, a lone surrogate jq 1.8 rejects outright.
         cut=''; [ -z "${FAKE_CUT:-}" ] || cut=',"preview":"cut \ud83d"'
         if [ -n "${FAKE_DIALOG:-}" ]; then
           echo '{"ok":true,"result":{"terminal":{"status":null,"connected":true,"writable":true'"$cut"',"agentWait":{"kind":"permission"}}}}'
         else echo '{"ok":true,"result":{"terminal":{"status":null,"connected":true,"writable":true'"$cut"',"agentWait":null}}}'; fi ;;
    esac ;;
  "terminal send") # the relaunch line; FAKE_START: the session then runs in that pane
    printf '%s\n' "$*" >>"$FAKE_LOG.send"
    if [ -n "${FAKE_START:-}" ]; then
      mkdir -p "$FAKE_PROC/4242" "$FAKE_CFG/sessions"
      printf 'ORCA_TERMINAL_HANDLE=%s\0' "$FAKE_PANE" >"$FAKE_PROC/4242/environ"
      echo '{"pid":4242,"sessionId":"sid1"}' >"$FAKE_CFG/sessions/4242.json"
    fi
    echo '{"ok":true}' ;;
  "terminal wait") echo '{"ok":true}' ;;
  "terminal list") # FAKE_TL: the file it answers; none: the call fails
    if [ -f "${FAKE_TL:-/nonexistent}" ]; then cat "$FAKE_TL"; else echo '{"ok":false}'; exit 1; fi ;;
  "worktree ps") # FAKE_PS_STATE: the pane's agent with that programStatus state
    if [ -n "${FAKE_PS_STATE:-}" ]; then
      printf '{"ok":true,"result":{"worktrees":[{"path":"%s","agents":[{"address":"%s","state":"waiting","programStatus":{"state":"%s"},"agentWait":{"source":"hook"}}]}]}}\n' "$FAKE_WS" "$FAKE_PANE" "$FAKE_PS_STATE"
    else echo '{"ok":true,"result":{"worktrees":[]}}'; fi ;;
  "terminal create") # a new pane, term_new, only with FAKE_CREATE; FAKE_START: the session runs there
    printf '%s\n' "$*" >>"$FAKE_LOG.create"
    [ -n "${FAKE_CREATE:-}" ] || { echo '{"ok":false,"error":{"code":"no_worktree"}}'; exit 1; }
    if [ -n "${FAKE_START:-}" ]; then
      mkdir -p "$FAKE_PROC/4343" "$FAKE_CFG/sessions"
      printf 'ORCA_TERMINAL_HANDLE=term_new\0' >"$FAKE_PROC/4343/environ"
      echo '{"pid":4343,"sessionId":"sid1"}' >"$FAKE_CFG/sessions/4343.json"
    fi
    echo '{"ok":true,"result":{"terminal":{"handle":"term_new"}}}' ;;
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
# highness#98: compact re-entry points the new worker at the spec it got, note included; `spec`
# stays the original copy (the retro reads it, the next resume builds on it).
noted=$(bash "$C" get AB-1 | jq -r '.resumed_spec // empty')
check 'resume: records the noted spec' "$noted" "$S/specs/AB-1.resumed.md"
check 'resume: the noted copy is what the worker got' "$(cat "$noted" 2>/dev/null)" "$spec"
check 'resume: spec stays the original copy' "$(bash "$C" get AB-1 | jq -r .spec)" "$S/specs/AB-1.md"
ctx=$(printf '{"hook_event_name":"SessionStart","source":"compact","cwd":"%s"}' "$T/ws" | bash "$C" reentry \
  | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
has 'reentry after resume: names the noted spec' "$ctx" "Re-read it before your next step: $S/specs/AB-1.resumed.md Your PR"
# A fresh start later records its own dispatch onto the open facts: its worker got no note.
bash "$C" record AB-1 '{"dispatch":"ctx_fresh","task":"task_fresh"}'
ctx=$(printf '{"cwd":"%s"}' "$T/ws" | bash "$C" reentry | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)
has 'reentry after a fresh start: back to the original spec' "$ctx" "Re-read it before your next step: $S/specs/AB-1.md Your PR"
bash "$C" record AB-1 '{"dispatch":"ctx_new","task":"task_new"}'

# --- a second resume carries the earlier ones
bash "$C" resume AB-1 >/dev/null 2>&1
check 'resume again: both replaced dispatches kept' "$(bash "$C" get AB-1 | jq -r '.resumed | join(",")')" 'ctx_old,ctx_new'
check 'resume again: one note, on the original copy' "$(grep -c '^## Resuming AB-1' "$S/specs/AB-1.resumed.md")" 1

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

# --- orphaned: an Orca restart left the workspace with only orphaned terminals, no agent
printf '{"ok":true,"result":{"terminals":[
  {"handle":"t_sh","worktreePath":"%s","connected":true,"writable":true,"agentIdentity":null,"orphaned":true,"preview":"cut \\ud83d"}
]}}' "$T/ws" >"$T/tl.orphan"
printf '{"ok":true,"result":{"terminals":[
  {"handle":"t_sh","worktreePath":"%s","connected":true,"writable":true,"agentIdentity":null,"orphaned":true},
  {"handle":"t_ag","worktreePath":"%s","connected":true,"writable":true,"agentIdentity":"claude","orphaned":true}
]}}' "$T/ws" "$T/ws" >"$T/tl.alive"
fresh
check 'orphaned: a worker Orca counts running is listed live' \
  "$(FAKE_TL="$T/tl.orphan" FAKE_LIVE=ctx_old bash "$C" orphaned)" "$(printf 'AB-1\t%s\tctx_old\tlive' "$T/ws")"
check 'orphaned: a settled one, lost' "$(FAKE_TL="$T/tl.orphan" bash "$C" orphaned | cut -f4)" lost
check 'orphaned: an orphaned agent terminal still runs its session: not listed' \
  "$(FAKE_TL="$T/tl.alive" FAKE_LIVE=ctx_old bash "$C" orphaned)" ''
check 'orphaned: no terminal list, nothing' "$(FAKE_LIVE=ctx_old bash "$C" orphaned; echo "rc=$?")" 'rc=0'
check 'orphaned: no hi plugin, nothing' "$(HI_ORCA_SH="$T/none" FAKE_TL="$T/tl.orphan" bash "$C" orphaned; echo "rc=$?")" 'rc=0'
refused 'live worker, an orphaned agent terminal still runs' 'not settled' FAKE_LIVE=ctx_old FAKE_TL="$T/tl.alive"
fresh
err=$(FAKE_TL="$T/tl.orphan" FAKE_LIVE=ctx_old bash "$C" resume AB-1 2>&1 >/dev/null); rc=$?
check 'orphaned live worker: resume goes ahead' "$rc" 0
has 'orphaned live worker: says why' "$err" 'only orphaned terminals and no agent'
has 'orphaned live worker: a worker started' "$(cat "$FAKE_LOG" 2>/dev/null)" 'orchestration worker-start'
rm -f "$FAKE_LOG"
fresh
err=$(FAKE_FAIL=1 bash "$C" resume AB-1 2>&1) && no 'failed start: exit 0'
has 'failed start: says do not rerun' "$err" 'do not rerun it'
check 'failed start: facts unchanged' "$(bash "$C" get AB-1 | jq -r .dispatch)" ctx_old
check 'failed start: no noted spec recorded' "$(bash "$C" get AB-1 | jq -r '.resumed_spec // empty')" ''
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
echo '{"state":"open"}' >"$T/prstate"

# --- highness#110: the lost worker's pane is still open: its own session gets the new Dispatch
# there, relaunched first when it no longer runs. Its transcript is found by the lost Dispatch's
# id in a typed prompt; a tool result that merely mentions the id does not count.
export HI_CLAUDE_DIRS="$T/cfg
$T/cfg2" HI_PROC="$T/proc" FAKE_CFG="$T/cfg" FAKE_PROC="$T/proc"
# The account workers run on (crew.sh account) is $T/cfg; $T/cfg2 is another one.
mkdir -p "$T/cfg" "$T/cfg2" "$T/profiles"
export HI_ORCA_PROFILES="$T/profiles"
jq --arg d "$T/cfg" '.crew.budget.config_dir = $d' "$T/user.json" >"$T/user.json.new" && mv "$T/user.json.new" "$T/user.json"
slug=$(printf '%s' "$T/ws" | sed 's/[^A-Za-z0-9]/-/g')
P="$T/cfg/projects/$slug"
mkdir -p "$P" "$T/av"
transcripts() {
  rm -rf "$P"/*.jsonl "$T/cfg/sessions" "$T/cfg2/sessions" "$T/proc"
  jq -nc '{type: "user", permissionMode: "bypassPermissions", message: {role: "user",
           content: "You are a dispatched worker...\n --task-id task_old --dispatch-id ctx_old --outcome succeeded"}}' >"$P/sid1.jsonl"
  jq -nc '{type: "assistant", message: {model: "opus", content: [{type: "text", text: "ok"}]}}' >>"$P/sid1.jsonl"
  jq -nc '{type: "user", permissionMode: "default", message: {role: "user",
           content: [{type: "tool_result", content: "saw --dispatch-id ctx_old in a log"}]}}' >"$P/sid0.jsonl"
}
running() { # <pid> <session> <pane> [<config dir>]: a live claude of that session in that pane
  local cfg=${4:-$T/cfg}
  mkdir -p "$T/proc/$1" "$cfg/sessions"
  printf 'ORCA_TERMINAL_HANDLE=%s\0' "$3" >"$T/proc/$1/environ"
  jq -nc --argjson p "$1" --arg s "$2" '{pid: $p, sessionId: $s}' >"$cfg/sessions/$1.json"
}
inpane() { # <env...>: resume AB-1 on fresh facts; sets out, rc
  fresh; transcripts; rm -f "$FAKE_LOG.send" "$FAKE_LOG.create"
  out=$(env FAKE_PANE=term_pane ORCA_CLAUDE_AGENT_VIEW_PLUGIN_DIR="$T/av" "$@" bash "$C" resume AB-1 2>&1); rc=$?
}
fellback() { # <name>: a new worker in the workspace, nothing typed into the pane
  has "$1: falls back to a new worker" "$(cat "$FAKE_LOG" 2>/dev/null)" "--worktree path:$T/ws"
  [ -s "$FAKE_LOG.send" ] && no "$1: typed nothing" || ok "$1: typed nothing"
}

# The pane is back at a shell prompt: relaunch, then the Dispatch.
inpane FAKE_START=1
check 'pane: exit 0' "$rc" 0
check 'pane: relaunches its own session, with its permission mode, model and the agent-view plugin' \
  "$(cat "$FAKE_LOG.send" 2>/dev/null)" \
  "terminal send --terminal term_pane --text claude --resume sid1 --plugin-dir '$T/av' --dangerously-skip-permissions --model 'opus' --enter --json"
args=$(cat "$FAKE_LOG" 2>/dev/null)
has 'pane: the new Dispatch goes into that pane' "$args" '--terminal term_pane --run run_aaa111 --from term_coord'
case "$args" in *--worktree*|*--agent*|*--model*) no 'pane: no new agent launch';; *) ok 'pane: no new agent launch';; esac
spec=$(cat "$FAKE_LOG.spec" 2>/dev/null)
has 'pane: the note says the chat is kept' "$spec" 'this
is the same Claude session'
has 'pane: the note names the lost Dispatch' "$spec" 'AB-1 (ctx_old) was lost'
has 'pane: a kept reply, verbatim' "$spec" '  > Yes, rename it'
case "$spec" in *'THE SPEC BODY'*) no 'pane: the spec is not sent again';; *) ok 'pane: the spec is not sent again';; esac
has 'pane: says which way it went' "$out" 'in its own pane, its chat kept'
check 'pane: records the new dispatch, the pane and the session, keeps the old one' \
  "$(bash "$C" get AB-1 | jq -r '[.dispatch, .task, (.resumed | join(",")), .resumed_in, .session, (.resumed_spec // "-")] | join("|")')" \
  'ctx_new|task_new|ctx_old|term_pane|sid1|-'
check 'pane: the lost escalation is handled' "$(bash "$C" asks)" ''

# The session still runs in its pane (the Dispatch failed under it): only the Dispatch.
fresh; transcripts; rm -f "$FAKE_LOG.send"; running 4242 sid1 term_pane
out=$(FAKE_PANE=term_pane bash "$C" resume AB-1 2>&1); rc=$?
check 'alive in pane: exit 0' "$rc" 0
[ -s "$FAKE_LOG.send" ] && no 'alive in pane: no relaunch' || ok 'alive in pane: no relaunch'
has 'alive in pane: the Dispatch goes into that pane' "$(cat "$FAKE_LOG")" '--terminal term_pane'

# Still running in its pane, but on another account than workers run on: move it first.
fresh; transcripts; rm -f "$FAKE_LOG.send"; running 4242 sid1 term_pane "$T/cfg2"
err=$(FAKE_PANE=term_pane bash "$C" resume AB-1 2>&1) && no 'other account: exit 0'
has 'other account: says move it first' "$err" 'move it first'
[ -s "$FAKE_LOG" ] && no 'other account: started nothing' || ok 'other account: started nothing'
check 'other account: facts unchanged' "$(bash "$C" get AB-1 | jq -r .dispatch)" ctx_old

# A dialog open in the pane: the Dispatch would answer it.
fresh; transcripts; rm -f "$FAKE_LOG.send"; running 4242 sid1 term_pane
err=$(FAKE_PANE=term_pane FAKE_DIALOG=1 bash "$C" resume AB-1 2>&1) && no 'dialog: exit 0'
has 'dialog: says answer it there' "$err" 'waits on a dialog'
[ -s "$FAKE_LOG" ] && no 'dialog: started nothing' || ok 'dialog: started nothing'
# The same dialog, its pane's preview cut inside an emoji: it used to read as no dialog, and the
# Dispatch was typed into it.
fresh; transcripts; rm -f "$FAKE_LOG.send"; running 4242 sid1 term_pane
err=$(FAKE_PANE=term_pane FAKE_DIALOG=1 FAKE_CUT=1 bash "$C" resume AB-1 2>&1) && no 'dialog, cut preview: exit 0'
has 'dialog, cut preview: still seen' "$err" 'waits on a dialog'
[ -s "$FAKE_LOG" ] && no 'dialog, cut preview: started nothing' || ok 'dialog, cut preview: started nothing'
# The dialog still blocked by `worktree ps`: refused as well.
fresh; transcripts; rm -f "$FAKE_LOG.send"; running 4242 sid1 term_pane
err=$(FAKE_PANE=term_pane FAKE_DIALOG=1 FAKE_PS_STATE=blocked bash "$C" resume AB-1 2>&1) && no 'dialog, ps blocked: exit 0'
has 'dialog, ps blocked: says answer it there' "$err" 'waits on a dialog'
[ -s "$FAKE_LOG" ] && no 'dialog, ps blocked: started nothing' || ok 'dialog, ps blocked: started nothing'
# A dialog dismissed with Esc (highness#171): Orca keeps agentWait until the next hook, and only
# programStatus drops to idle. No dialog is on screen: the Dispatch goes in.
fresh; transcripts; rm -f "$FAKE_LOG.send"; running 4242 sid1 term_pane
out=$(FAKE_PANE=term_pane FAKE_DIALOG=1 FAKE_PS_STATE=idle bash "$C" resume AB-1 2>&1); rc=$?
check 'stale agentWait after Esc: exit 0' "$rc" 0
has 'stale agentWait after Esc: the Dispatch goes into that pane' "$(cat "$FAKE_LOG" 2>/dev/null)" '--terminal term_pane'

# Fallbacks to a new worker: today's behaviour.
fresh; transcripts; rm -f "$FAKE_LOG.send"; running 4242 sid1 term_other
FAKE_PANE=term_pane bash "$C" resume AB-1 >/dev/null 2>&1
fellback 'session runs in another pane'
fresh; transcripts; rm -f "$FAKE_LOG.send"; running 5151 sid9 term_pane
FAKE_PANE=term_pane bash "$C" resume AB-1 >/dev/null 2>&1
fellback 'another session runs in the pane'
# Its pane gone and no new terminal to be had (Orca refused the create): a new worker.
inpane FAKE_START=1 FAKE_PANE_GONE=1
fellback 'pane gone, no new terminal'
has 'pane gone, no new terminal: it asked for one' "$(cat "$FAKE_LOG.create" 2>/dev/null)" "--worktree path:$T/ws"
inpane FAKE_START=1 FAKE_PANE_GONE=closed
fellback 'pane closed (Orca still answers for it, disconnected), no new terminal'

# --- highness#67: its pane closed, the session is resumed in a new terminal of its workspace,
# on the account workers run on, instead of a new worker that starts over on the whole spec.
inpane FAKE_START=1 FAKE_PANE_GONE=closed FAKE_CREATE=1
check 'new terminal: exit 0' "$rc" 0
check 'new terminal: in its workspace, kept open, its own session relaunched on the workers'"'"' account' \
  "$(cat "$FAKE_LOG.create" 2>/dev/null)" \
  "terminal create --worktree path:$T/ws --keep-open --title AB-1 (resumed) --command CLAUDE_CONFIG_DIR='$T/cfg' claude --resume sid1 --plugin-dir '$T/av' --dangerously-skip-permissions --model 'opus' --json"
[ -s "$FAKE_LOG.send" ] && no 'new terminal: typed nothing into a pane' || ok 'new terminal: typed nothing into a pane'
args=$(cat "$FAKE_LOG" 2>/dev/null)
has 'new terminal: the new Dispatch goes into it' "$args" '--terminal term_new --run run_aaa111 --from term_coord'
case "$args" in *--worktree*|*--agent*) no 'new terminal: no new agent launch';; *) ok 'new terminal: no new agent launch';; esac
case "$(cat "$FAKE_LOG.spec" 2>/dev/null)" in *'THE SPEC BODY'*) no 'new terminal: the spec is not sent again';; *) ok 'new terminal: the spec is not sent again';; esac
has 'new terminal: says which way it went' "$out" 'in a new terminal of its workspace, its chat kept'
check 'new terminal: records the new dispatch, the pane and the session' \
  "$(bash "$C" get AB-1 | jq -r '[.dispatch, (.resumed | join(",")), .resumed_in, .session] | join("|")')" 'ctx_new|ctx_old|term_new|sid1'

# Opened, but the session never seen running there: stop, start nothing beside it.
inpane FAKE_PANE_GONE=closed FAKE_CREATE=1 HI_RESUME_START_WAIT=1
[ "$rc" != 0 ] && ok 'new terminal, unconfirmed: exit non-zero' || no 'new terminal, unconfirmed: exit non-zero'
has 'new terminal, unconfirmed: says look at the pane' "$out" "pane term_new"
[ -s "$FAKE_LOG" ] && no 'new terminal, unconfirmed: started nothing' || ok 'new terminal, unconfirmed: started nothing'

# Its pane gone, but the session runs in another Orca pane (Orca's restart reopened it there, or
# the unconfirmed start above came up late): the Dispatch goes there, nothing opened or typed.
fresh; transcripts; rm -f "$FAKE_LOG.send" "$FAKE_LOG.create"; running 4242 sid1 term_moved
out=$(FAKE_PANE=term_pane FAKE_PANE_GONE=1 FAKE_CREATE=1 bash "$C" resume AB-1 2>&1); rc=$?
check 'runs in a new pane: exit 0' "$rc" 0
has 'runs in a new pane: the Dispatch goes there' "$(cat "$FAKE_LOG" 2>/dev/null)" '--terminal term_moved'
[ -s "$FAKE_LOG.create" ] || [ -s "$FAKE_LOG.send" ] && no 'runs in a new pane: opened and typed nothing' || ok 'runs in a new pane: opened and typed nothing'
has 'runs in a new pane: says which way it went' "$out" 'in the pane it runs in now'

# Its pane gone and the session runs outside Orca (no terminal handle): a new worker, nothing typed.
fresh; transcripts; rm -f "$FAKE_LOG.send" "$FAKE_LOG.create"; running 4242 sid1 ''
FAKE_PANE=term_pane FAKE_PANE_GONE=1 FAKE_CREATE=1 bash "$C" resume AB-1 >/dev/null 2>&1
fellback 'runs outside Orca'
[ -s "$FAKE_LOG.create" ] && no 'runs outside Orca: opened nothing' || ok 'runs outside Orca: opened nothing'
fresh; transcripts; rm -f "$FAKE_LOG.send" "$P/sid1.jsonl"
out=$(FAKE_PANE=term_pane FAKE_START=1 bash "$C" resume AB-1 2>&1)
fellback 'no session found (a tool result naming the Dispatch is not its prompt)'
has 'no session found: says it starts a new worker' "$out" 'starting a new worker'

# Relaunched, but never seen running: stop, start nothing beside it.
inpane HI_RESUME_START_WAIT=1
[ "$rc" != 0 ] && ok 'unconfirmed relaunch: exit non-zero' || no 'unconfirmed relaunch: exit non-zero'
has 'unconfirmed relaunch: says look at the pane' "$out" 'look at the pane'
[ -s "$FAKE_LOG" ] && no 'unconfirmed relaunch: started nothing' || ok 'unconfirmed relaunch: started nothing'
check 'unconfirmed relaunch: facts unchanged' "$(bash "$C" get AB-1 | jq -r .dispatch)" ctx_old

# Orca counts the worker running and sees no agent in its orphaned workspace, but a Claude still
# runs in one of its terminals: refuse, start nothing beside it.
fresh; rm -rf "$T/proc" "$T/cfg/sessions" "$FAKE_LOG"; running 6161 sid7 t_sh
err=$(FAKE_TL="$T/tl.orphan" FAKE_LIVE=ctx_old bash "$C" resume AB-1 2>&1) && no 'orphaned, a Claude still runs: exit 0'
has 'orphaned, a Claude still runs: says so' "$err" 'still runs in one of them'
[ -s "$FAKE_LOG" ] && no 'orphaned, a Claude still runs: started nothing' || ok 'orphaned, a Claude still runs: started nothing'
check 'orphaned, a Claude still runs: facts unchanged' "$(bash "$C" get AB-1 | jq -r .dispatch)" ctx_old
rm -rf "$T/proc/6161" "$T/cfg/sessions/6161.json"

exit $fail
