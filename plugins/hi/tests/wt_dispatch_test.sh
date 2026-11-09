#!/usr/bin/env bash
# lib/wt.sh dispatch — Orca terminal, else tmux window in session `hi`, else a printed line.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }
U=11111111-2222-3333-4444-555555555555

mk_repo; cd "$R"
row=$(bash "$WT" create --kind ticket --key AB-101 --name 'AB-101 · Retry lock ordering' \
        --base main --branch task/dev/AB-101-retry 2>/dev/null)
P=$(col "$row" 1)
printf 'Start AB-101.\n' > "$SANDBOX/brief.md"
B="$R/.git/hi/briefs/AB-101-retry-lock-ordering.md"
# The brief and the plugin root are outside the workspace: both are --add-dir, before the
# session flags, since --add-dir takes several values and would swallow the prompt.
export HI_PLUGIN_DIR=/opt/hi
# Neither the plugin root nor the main checkout may be edited (highness#14): --settings denies it.
RP=$(cd "$R" && pwd -P)
AD="--add-dir $R/.git/hi/briefs --add-dir /opt/hi --settings '{\"permissions\":{\"deny\":[\"Edit(//opt/hi/**)\",\"Edit(/$RP/**)\"]}}'"

# tmux: session hi created when absent, one detached window named after the work
echo 1 > "$FX/tmux-has.rc"; reset_log
out=$(bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "tmux: exit 0" 0 "$rc"
assert_eq "tmux: stdout uuid/via/handle" "$U	tmux	hi:AB-101 · Retry lock ordering" "$out"
L=$(logged)
assert_contains "tmux: session created" "$L" "tmux new-session -d -s hi"
assert_contains "tmux: window argv" "$L" "tmux new-window -d -t hi: -n AB-101 · Retry lock ordering -c $P claude $AD --session-id $U --name 'AB-101 · Retry lock ordering' 'Read $B and follow it.'"
assert_eq "brief copied into the store" "Start AB-101." "$(cat "$B")"
assert_eq "record: session" "$U" "$(bash "$WT" rec get --ticket AB-101 session)"
assert_eq "record: dispatched" tmux "$(bash "$WT" rec get --ticket AB-101 dispatched)"
assert_contains "announce: resume command" "$(cat "$SANDBOX/err")" "claude --resume $U"
rm -f "$FX/tmux-has.rc"; reset_log
bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_not_contains "tmux: an existing session is reused" "$(logged)" "new-session"

# no tmux: the command is printed, and the session id is recorded anyway
export HI_TMUX=none; export HI_UUID=AAAAAAAA-2222-3333-4444-555555555555
out=$(bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" 2>/dev/null)
assert_eq "print: first line" "aaaaaaaa-2222-3333-4444-555555555555	print	" "$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "print: second line is the command" \
  "cd $P && claude $AD --session-id aaaaaaaa-2222-3333-4444-555555555555 --name 'AB-101 · Retry lock ordering' 'Read $B and follow it.'" \
  "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "print: session recorded (uuid lowercased)" aaaaaaaa-2222-3333-4444-555555555555 \
  "$(bash "$WT" rec get --ticket AB-101 session)"
export HI_UUID=$U; unset HI_TMUX; export HI_TMUX="$STUB/tmux"

# quoting: an apostrophe in the name
out=$(HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" --name "Max's spike" 2>/dev/null)
assert_contains "quoting: apostrophe" "$(printf '%s\n' "$out" | sed -n 2p)" "--name 'Max'\\''s spike'"

# --config-dir: the session runs on another Claude account, through `env`; recorded,
# and named in the resume line. A missing directory is a usage error.
CD="$SANDBOX/other acct"; mkdir -p "$CD"
out=$(HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" --config-dir "$CD" 2>"$SANDBOX/err")
assert_eq "config-dir: the line starts with env" \
  "cd $P && env CLAUDE_CONFIG_DIR='$CD' claude $AD --session-id $U --name 'AB-101 · Retry lock ordering' 'Read $B and follow it.'" \
  "$(printf '%s\n' "$out" | sed -n 2p)"
assert_eq "config-dir: recorded" "$CD" "$(bash "$WT" rec get --ticket AB-101 config_dir)"
assert_contains "config-dir: the resume line names it" "$(cat "$SANDBOX/err")" "CLAUDE_CONFIG_DIR='$CD' claude --resume $U"
HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" --config-dir "$SANDBOX/nope" >/dev/null 2>&1
assert_status "config-dir: not a directory is 2" 2 "$?"

# Orca: a terminal in the workspace; no tmux
orca_on; reset_log
row=$(bash "$WT" create --kind work --key spike --name 'refund spike' --base main --branch work/spike 2>/dev/null)
OP=$(col "$row" 1); reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>/dev/null); rc=$?
assert_status "orca: exit 0" 0 "$rc"
assert_eq "orca: stdout" "$U	orca	h1" "$out"
assert_contains "orca: terminal create argv" "$(logged)" "orca terminal create --worktree id:R::\\\\wsl.localhost\\d"
assert_contains "orca: title and command" "$(logged)" "--title refund spike --command claude $AD --session-id $U --name 'refund spike'"
assert_not_contains "orca: no tmux" "$(logged)" "tmux "
printf '%s\n' '{"ok":false,"error":{"code":"terminal_failed"}}' > "$FX/term.json"; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>/dev/null)
assert_eq "orca failure: falls back to tmux" tmux "$(col "$(printf '%s\n' "$out" | sed -n 1p)" 2)"
rm -f "$FX/term.json"; orca_off

# A background gortex track (setup's gortex-track.pid) never holds dispatch: the
# launched line waits for it itself, through await-track.sh, bounded by HI_TRACK_WAIT.
G=$(git -C "$P" rev-parse --absolute-git-dir)
AW="$(cd "$HERE/../lib" && pwd)/await-track.sh"
sleep 5 & sp=$!; echo "$sp" > "$G/gortex-track.pid"
t0=$(date +%s)
out=$(HI_TMUX=none HI_TRACK_WAIT=600 bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err")
assert_status "track: dispatch still succeeds" 0 "$?"
assert_eq "track: dispatch returns at once" yes "$([ $(( $(date +%s) - t0 )) -lt 3 ] && echo yes || echo no)"
assert_eq "track: the line waits first, then starts claude" \
  "cd $P && bash $AW $G 600 claude $AD --session-id $U --name 'AB-101 · Retry lock ordering' 'Read $B and follow it.'" \
  "$(printf '%s\n' "$out" | sed -n 2p)"
assert_contains "track: says where the wait went" "$(cat "$SANDBOX/err")" "the session starts when it is done"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; rm -f "$G/gortex-track.pid"
echo 99999999 > "$G/gortex-track.pid"
out=$(HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err")
assert_not_contains "track: a stale pid file is no wait" "$(printf '%s\n' "$out" | sed -n 2p)" "await-track"
rm -f "$G/gortex-track.pid"
printf 'boom\nexit 1\n' > "$G/gortex-track.log"
bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" >/dev/null 2>"$SANDBOX/err"
assert_contains "track: a failed track is said" "$(cat "$SANDBOX/err")" "gortex track exited 1"
printf 'exit 0\n' > "$G/gortex-track.log"
bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" >/dev/null 2>"$SANDBOX/err"
assert_not_contains "track: a finished good track is silent" "$(cat "$SANDBOX/err")" "gortex"
rm -f "$G/gortex-track.log"

# await-track.sh itself: waits while the track runs, then execs the command; bounded.
sleep 2 & sp=$!; echo "$sp" > "$G/gortex-track.pid"
t0=$(date +%s)
out=$(HI_TRACK_POLL=1 bash "$AW" "$G" 60 printf '%s|' ran 'two words')
assert_eq "await: execs the command, words intact" "ran|two words|" "$(printf '%s\n' "$out" | tail -1)"
assert_eq "await: waited for the track" yes "$([ $(( $(date +%s) - t0 )) -ge 1 ] && echo yes || echo no)"
assert_contains "await: says it waits" "$out" "still indexing"
assert_contains "await: says when done" "$out" "indexing done"
sleep 30 & sp=$!; echo "$sp" > "$G/gortex-track.pid"
out=$(HI_TRACK_POLL=1 bash "$AW" "$G" 1 echo started)
assert_contains "await: past the bound it starts anyway" "$out" "starting anyway"
assert_eq "await: and runs the command" started "$(printf '%s\n' "$out" | tail -1)"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; rm -f "$G/gortex-track.pid"
printf 'exit 2\n' > "$G/gortex-track.log"
out=$(bash "$AW" "$G" 5 echo started)
assert_contains "await: a failed track is said" "$out" "gortex track exited 2"
rm -f "$G/gortex-track.log"
bash "$AW" "$G" >/dev/null 2>&1; assert_status "await: no command is 2" 2 "$?"

# A live agent session in the workspace: the brief goes to it, never a second session.
orca_on
bash "$WT" rec set --work spike session 99999999-2222-3333-4444-555555555555 >/dev/null 2>&1
UOP=$(printf '%s%s' '\\wsl.localhost\d' "$(printf '%s' "$OP" | tr '/' '\\')")
jq -n --arg p "$UOP" '{ok:true,result:{terminals:[
  {handle:"sh1",connected:true,writable:true,worktreePath:$p,title:"shell",agentIdentity:""},
  {handle:"cl1",connected:true,writable:true,worktreePath:$p,title:"claude",agentIdentity:"claude"}]}}' > "$FX/terms.json"
reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
OB="$R/.git/hi/briefs/${OP##*/}.md"
assert_status "live: exit 0" 0 "$rc"
assert_eq "live: stdout names the recorded session and the terminal" "99999999-2222-3333-4444-555555555555	send	cl1" "$out"
assert_contains "live: the brief is sent to the agent terminal" "$(logged)" "orca terminal send --terminal cl1 --text Read $OB and follow it. --enter"
assert_not_contains "live: no new terminal" "$(logged)" "terminal create"
assert_eq "live: the recorded session is kept" 99999999-2222-3333-4444-555555555555 "$(bash "$WT" rec get --work spike session)"
assert_eq "live: dispatched=send" send "$(bash "$WT" rec get --work spike dispatched)"
reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" --resume 99999999-2222-3333-4444-555555555555 2>/dev/null)
assert_eq "live + --resume: sent, not resumed twice" send "$(col "$out" 2)"
assert_not_contains "live + --resume: no new terminal" "$(logged)" "terminal create"
printf '%s\n' '{"ok":false,"error":{"code":"timeout"}}' > "$FX/wait.json"; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "busy: refused with 3" 3 "$rc"
assert_eq "busy: stdout" "99999999-2222-3333-4444-555555555555	busy	" "$out"
assert_not_contains "busy: nothing typed into it" "$(logged)" "terminal send"
assert_not_contains "busy: no new terminal" "$(logged)" "terminal create"
assert_contains "busy: says why" "$(cat "$SANDBOX/err")" "mid-turn"
# Orca's status says idle, but the terminal does not go tui-idle: never typed into
jq -n --arg p "$UOP" '{ok:true,result:{terminals:[
  {handle:"cl1",connected:true,writable:true,worktreePath:$p,title:"claude",agentIdentity:"claude",tabId:"T",leafId:"L"}]}}' > "$FX/terms.json"
jq -n --arg p "$UOP" '{ok:true,result:{worktrees:[{path:$p,agents:[{paneKey:"T:L",state:"done",programStatus:{state:"idle"}}]}]}}' > "$FX/ps.json"
reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>/dev/null); rc=$?
assert_status "status idle, wait times out: refused with 3" 3 "$rc"
assert_not_contains "status idle, wait times out: nothing typed" "$(logged)" "terminal send"
rm -f "$FX/ps.json"
jq -n --arg p "$UOP" '{ok:true,result:{terminals:[
  {handle:"sh1",connected:true,writable:true,worktreePath:$p,title:"shell",agentIdentity:""},
  {handle:"cl1",connected:true,writable:true,worktreePath:$p,title:"claude",agentIdentity:"claude"}]}}' > "$FX/terms.json"
rm -f "$FX/wait.json"
printf '%s\n' '{"ok":false,"error":{"code":"terminal_gone"}}' > "$FX/send.json"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>"$SANDBOX/err"
assert_status "send failure: 1" 1 "$?"
assert_not_contains "send failure: no second session" "$(logged)" "terminal create"
rm -f "$FX/send.json"
# Accepted is not taken (highness#14): `dispatched` only once Orca saw the turn start or the
# rendered screen shows the brief left the composer. Otherwise exit 5, via=unconfirmed, the
# screen tail on stderr — and never a second send.
printf '%s\n' '{"ok":true,"result":{"send":{"accepted":false,"refusedReason":"agent_prompt_blocked"}}}' > "$FX/send.json"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "send refused (accepted:false): 1" 1 "$?"
printf '%s\n' '{"ok":true,"result":{"send":{"handle":"cl1","accepted":true,"prompt":{"requestId":"unsupported-old-host","stages":["input_accepted"],"provider":"old-host","observation":"unsupported"}}}}' > "$FX/send.json"
RULE='────────────────────'
# screen [-N] <source> <rows…>: what `terminal read --screen` renders (-N: on its Nth call only)
screen() { local f="$FX/read.json"; case "$1" in -*) f="$FX/read.${1#-}.json"; shift ;; esac
  jq -n --arg src "$1" '{ok:true,result:{terminal:{handle:"cl1",status:"running",source:$src,tail:$ARGS.positional}}}' --args "${@:2}" > "$f"; }
reads_reset() { rm -f "$FX"/read.*json "$FX/read.n"; }
reset_log; reads_reset
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "unobserved, no screen: exit 5" 5 "$rc"
assert_eq "unobserved, no screen: via=unconfirmed" "99999999-2222-3333-4444-555555555555	unconfirmed	cl1" "$out"
assert_eq "unobserved: recorded as unconfirmed, not send" unconfirmed "$(bash "$WT" rec get --work spike dispatched)"
assert_eq "unobserved: typed once, never resent" 1 "$(grep -c 'terminal send' "$WT_TEST_LOG")"
assert_not_contains "unobserved: no second session" "$(logged)" "terminal create"
assert_contains "unobserved: says what Orca saw" "$(cat "$SANDBOX/err")" "input_accepted, unsupported"
assert_contains "unobserved: says to look first" "$(cat "$SANDBOX/err")" "Look at that terminal before sending again"
# a swallowed Enter: the brief still sits in the composer, wrapped over two rows
HALF=$(printf 'Read %s and follow it.' "$OB" | cut -c1-20); REST=$(printf 'Read %s and follow it.' "$OB" | cut -c21-)
reads_reset
screen screen "earlier output" "$RULE" "❯ $HALF" "  $REST" "$RULE" "  ⏵⏵ bypass permissions on"; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "brief in the composer: exit 5" 5 "$rc"
assert_eq "brief in the composer: unconfirmed" unconfirmed "$(col "$out" 2)"
assert_contains "brief in the composer: the screen tail is shown" "$(cat "$SANDBOX/err")" "bypass permissions on"
assert_contains "the screen is read rendered" "$(logged)" "orca terminal read --terminal cl1 --screen --json"
# the brief left the composer and shows above it, where it was not before the send: taken
reads_reset
screen -1 screen "earlier output" "$RULE" "❯ " "$RULE"
screen screen "❯ Read $OB and follow it." "✽ Thinking… (2s)" "$RULE" "❯ " "$RULE"; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>/dev/null); rc=$?
assert_status "brief above the composer: exit 0" 0 "$rc"
assert_eq "brief above the composer: send" send "$(col "$out" 2)"
assert_eq "brief above the composer: recorded send" send "$(bash "$WT" rec get --work spike dispatched)"
# every dispatch types the same line: an earlier dispatch's echo already on screen is not this one
reads_reset
screen screen "❯ Read $OB and follow it." "  Done." "$RULE" "❯ " "$RULE"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "an earlier dispatch's echo only: exit 5" 5 "$?"
reads_reset
screen -1 screen "❯ Read $OB and follow it." "  Done." "$RULE" "❯ " "$RULE"
screen screen "❯ Read $OB and follow it." "  Done." "❯ Read $OB and follow it." "✽ Thinking…" "$RULE" "❯ " "$RULE"
reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "a second echo below the earlier one: exit 0" 0 "$?"
reads_reset
# Orca says idle, but the screen shows a dialog (herdr's Claude manifest shapes, highness#24):
# never typed into, refused like a busy session.
screen screen "earlier output" "$RULE" " Bash command" "   rm -rf build" "" " Do you want to proceed?" \
  " ❯ 1. Yes" "   2. Yes, and don't ask again for rm commands" "   3. No, and tell Claude what to do differently (esc)" \
  "" " Esc to cancel · Tab to amend · ctrl+e to explain"; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "permission dialog on screen: refused with 3" 3 "$rc"
assert_eq "permission dialog on screen: busy" busy "$(col "$out" 2)"
assert_not_contains "permission dialog on screen: nothing typed" "$(logged)" "terminal send"
assert_contains "permission dialog on screen: says why" "$(cat "$SANDBOX/err")" "shows a dialog"
assert_contains "permission dialog on screen: shows it" "$(cat "$SANDBOX/err")" "Do you want to proceed?"
screen screen "earlier output" "$RULE" " Which approach?" " ❯ 1. Small" "   2. Large" "" \
  " Enter to select · ↑/↓ to navigate · Esc to cancel"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "question form on screen: refused with 3" 3 "$?"
assert_not_contains "question form on screen: nothing typed" "$(logged)" "terminal send"
screen screen "earlier output" "$RULE" ' MCP server "docs" requests your input' " ❯ Accept" "   Decline" " Esc to cancel"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "MCP input dialog on screen: refused with 3" 3 "$?"
screen screen "✻ Musing… (12s · ↑ 1.2k tokens)" "$RULE" "❯ " "$RULE" "  ⏵⏵ accept edits on (shift+tab to cycle) · esc to interrupt"; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "a turn running on screen: refused with 3" 3 "$rc"
assert_not_contains "a turn running on screen: nothing typed" "$(logged)" "terminal send"
assert_contains "a turn running on screen: says mid-turn" "$(cat "$SANDBOX/err")" "mid-turn"
# a dialog's footer words in the output above the composer are not a dialog
screen -1 screen "  it printed: Enter to confirm · Esc to cancel" "$RULE" "❯ " "$RULE" "  ? for shortcuts"
screen screen "  it printed: Enter to confirm · Esc to cancel" "$RULE" "❯ " "$RULE" "  ? for shortcuts"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "dialog words above the composer: typed (then unconfirmed, 5)" 5 "$?"
assert_contains "dialog words above the composer: typed" "$(logged)" "terminal send"
reads_reset
# After the send, a turn running or a dialog open is the turn start, with or without the echo
screen -1 screen "earlier output" "$RULE" "❯ " "$RULE" "  ? for shortcuts"
screen screen "earlier output" "✻ Musing… (3s · esc to interrupt)" "$RULE" "❯ " "$RULE" "  ⏵⏵ accept edits on · esc to interrupt"; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>/dev/null); rc=$?
assert_status "working after the send, no echo: exit 0" 0 "$rc"
assert_eq "working after the send: recorded send" send "$(bash "$WT" rec get --work spike dispatched)"
reads_reset
screen -1 screen "earlier output" "$RULE" "❯ " "$RULE" "  ? for shortcuts"
screen screen "earlier output" "$RULE" " Bash command" "   make test" " Do you want to proceed?" " ❯ 1. Yes" "   2. No" " Esc to cancel"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>"$SANDBOX/err"
assert_status "a dialog after the send: exit 0" 0 "$?"
assert_contains "a dialog after the send: says to look" "$(cat "$SANDBOX/err")" "opened a dialog at once"
reads_reset
# the brief still in the composer is not taken, even with a turn showing (highness#14)
screen -1 screen "earlier output" "$RULE" "❯ " "$RULE" "  ? for shortcuts"
screen screen "✻ Musing… (3s · esc to interrupt)" "$RULE" "❯ Read $OB and follow it." "$RULE" "  ⏵⏵ accept edits on · esc to interrupt"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "brief in the composer with a turn showing: exit 5" 5 "$?"
reads_reset
# an accumulated stream is no rendered screen: it cannot tell the composer apart
reads_reset; screen stream "❯ Read $OB and follow it." "$RULE" "❯ " "$RULE"; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "stream, not screen: exit 5" 5 "$?"
# no composer box on screen (another TUI): not confirmed by the screen
reads_reset; screen screen "❯ Read $OB and follow it."; reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "no composer box: exit 5" 5 "$?"
rm -f "$FX/send.json"; reads_reset
# Orca saw the turn start: the screen is read only once, before the send
reset_log
bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "turn_started: exit 0" 0 "$?"
assert_eq "turn_started: no screen read after the send" 1 "$(grep -c 'terminal read' "$WT_TEST_LOG")"
# A host that can observe delivery is asked to wait for the turn start; one that cannot is not
# (its CLI refuses --wait-submit and sends nothing).
assert_not_contains "no prompt-delivery capability: no --wait-submit" "$(logged)" "--wait-submit"
jq '.result.runtime.capabilities = ["terminal.prompt-delivery.v1"]' "$FX/status.json" > "$FX/st.json" && mv "$FX/st.json" "$FX/status.json"
reset_log
HI_SEND_WAIT=7 bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_contains "prompt-delivery capability: --wait-submit" "$(logged)" "--enter --wait-submit 7 --json"
orca_on
jq -n --arg p "$UOP" '{ok:true,result:{terminals:[{handle:"sh1",connected:true,writable:true,worktreePath:$p,title:"shell",agentIdentity:""}]}}' > "$FX/terms.json"
reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>/dev/null)
assert_eq "shell only: a new session" "$U	orca	h1" "$out"
rm -f "$FX/terms.json"
# a chat agent: no terminal to type into, so no send and never a second session
chatps() { jq -n --arg p "$UOP" --arg s "$1" '{ok:true,result:{worktrees:[{path:$p,agents:[
  {paneKey:"structured-agent-session-claude_1:tab",state:$s}]}]}}' > "$FX/ps.json"; }
chatps done; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "idle chat: refused with 3" 3 "$rc"
assert_eq "idle chat: stdout names the recorded session" "$U	chat	" "$out"
assert_not_contains "idle chat: nothing sent" "$(logged)" "terminal send"
assert_not_contains "idle chat: no new terminal" "$(logged)" "terminal create"
assert_contains "idle chat: says what to paste" "$(cat "$SANDBOX/err")" "Read $OB and follow it."
chatps working; reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "working chat: refused with 3" 3 "$rc"
assert_eq "working chat: busy" busy "$(col "$out" 2)"
assert_not_contains "working chat: no new terminal" "$(logged)" "terminal create"
rm -f "$FX/ps.json"; orca_off

# the plugin root defaults to the hi plugin directory wt.sh runs from, physical
out=$(HI_PLUGIN_DIR= HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" 2>/dev/null)
assert_contains "plugin root: default is wt.sh's plugin root" "$(printf '%s\n' "$out" | sed -n 2p)" \
  "--add-dir $(cd "$HERE/.." && pwd -P) --settings"
assert_contains "plugin root: edits under it are denied" "$(printf '%s\n' "$out" | sed -n 2p)" \
  "Edit(/$(cd "$HERE/.." && pwd -P)/**)"
# a workspace inside a denied dir keeps it editable: the deny would block the worker's own tree
PD=$(cd "$P/.." && pwd -P)
out=$(HI_PLUGIN_DIR="$PD" HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" 2>/dev/null)
assert_not_contains "a dir holding the workspace is not denied" "$(printf '%s\n' "$out" | sed -n 2p)" "Edit(/$PD/**)"
assert_contains "the main checkout is still denied" "$(printf '%s\n' "$out" | sed -n 2p)" "Edit(/$RP/**)"

# guards
bash "$WT" dispatch "$P" >/dev/null 2>&1;                               assert_status "no --brief: 2" 2 "$?"
bash "$WT" dispatch "$P" --brief "$SANDBOX/none.md" >/dev/null 2>&1;    assert_status "missing brief file: 2" 2 "$?"
bash "$WT" dispatch "$SANDBOX" --brief "$SANDBOX/brief.md" >/dev/null 2>&1; assert_status "not a workspace: 1" 1 "$?"
bash "$WT" dispatch "$R" --brief "$SANDBOX/brief.md" >/dev/null 2>&1;   assert_status "main checkout: 1" 1 "$?"
bash "$WT" dispatch '' --brief "$SANDBOX/brief.md" >/dev/null 2>&1;     assert_status "empty path: 2" 2 "$?"
assert_summary
