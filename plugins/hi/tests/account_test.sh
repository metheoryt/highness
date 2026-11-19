#!/usr/bin/env bash
# account.sh: finding the sessions to move, and moving them through a stub Orca and a /proc-shaped
# fixture. The stub plays the pane: /exit ends the session's process, and the relaunch line starts
# a new one whose status file lands in the account dir the line's wrapper would pick.
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
ACC="$HERE/../lib/account.sh"

P="$SANDBOX/profiles"; A="$P/a/home"; B="$P/b/home"; SYS="$HOME/.claude"
export HI_PROC="$SANDBOX/proc"
mkdir -p "$A/sessions" "$B/sessions" "$SYS/sessions" "$HI_PROC"
A=$(cd -P "$A" && pwd -P); B=$(cd -P "$B" && pwd -P); SYS=$(cd -P "$SYS" && pwd -P)
LOG="$SANDBOX/orca.log"; : >"$LOG"
export HI_MOVE_EXIT_WAIT=2 HI_MOVE_START_WAIT=2 HI_ACCOUNT_SELF=1

printf '%s\n' '{"claudeAiMcpEverConnected":["claude.ai Gmail","claude.ai Meetings","claude.ai Google Docs"]}' >"$A/.claude.json"
printf '%s\n' '{"claudeAiMcpEverConnected":["claude.ai Gmail"]}' >"$B/.claude.json"

# accounts <active id>: the stub's `orca account list --json`.
accounts() {
  jq -n --arg a "$A" --arg b "$B" --arg s "$SYS" --arg act "$1" '{ok: true, result: {claude: {
    activeAccountId: $act, activeAccountIdsByRuntime: {host: $act},
    accounts: [{id: "ida", email: "a@x", home: $a, organizationUuid: "org-a"},
               {id: "idb", email: "b@x", home: $b, organizationUuid: "org-b"}],
    systemDefaultHome: $s, systemDefaultEmail: "sys@x", systemDefaultOrganizationUuid: "org-s"}}}' \
    >"$SANDBOX/accounts.json"
}

# session <dir> <pid> <sid> <status> <handle> [pointer] [argv…]: a live session in a pane.
session() {
  local d=$1 pid=$2 sid=$3 st=$4 h=$5 ptr=${6-ptr}; shift 6 2>/dev/null || shift $#
  jq -n --argjson p "$pid" --arg s "$sid" --arg st "$st" '{pid: $p, sessionId: $s, status: $st, cwd: "/w", kind: "interactive"}' \
    >"$d/sessions/$pid.json"
  mkdir -p "$HI_PROC/$pid"
  { printf 'ORCA_TERMINAL_HANDLE=%s\0' "$h"; [ -n "$ptr" ] && printf 'ORCA_CLAUDE_PROFILE_POINTER=%s\0' "$ptr"; } >"$HI_PROC/$pid/environ"
  { printf 'claude\0'; for a in "$@"; do printf '%s\0' "$a"; done; } >"$HI_PROC/$pid/cmdline"
  printf '%s (claude) S 1\n' "$pid" >"$HI_PROC/$pid/stat"
}

cat >"$SHIM/orca" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LOG"
case "$1 $2" in
  "account list") cat "$SANDBOX/accounts.json" ;;
  "terminal wait") printf '{"ok":%s}\n' "$(cat "$SANDBOX/tui-idle" 2>/dev/null || echo true)" ;;
  "terminal send")
    h=''; t=''
    while [ $# -gt 0 ]; do case "$1" in --terminal) h=$2; shift 2 ;; --text) t=$2; shift 2 ;; *) shift ;; esac; done
    pid=$(grep -l "ORCA_TERMINAL_HANDLE=$h" "$HI_PROC"/*/environ 2>/dev/null | head -1 | xargs -n1 dirname 2>/dev/null | xargs -n1 basename 2>/dev/null)
    case "$t" in
      /exit) [ -f "$SANDBOX/stuck" ] || { [ -n "$pid" ] && rm -rf "$HI_PROC/$pid"; } ;;
      "claude --resume "*)
        [ -f "$SANDBOX/nostart" ] && { echo '{"ok":true}'; exit 0; }
        sid=$(printf '%s' "$t" | cut -d' ' -f3); np=$((RANDOM + 50000))
        to=$(jq -r '.result.claude as $c | [$c.accounts[] | select(.id == $c.activeAccountId)][0].home' "$SANDBOX/accounts.json")
        mkdir -p "$HI_PROC/$np"; printf 'ORCA_TERMINAL_HANDLE=%s\0' "$h" >"$HI_PROC/$np/environ"
        printf '{"pid":%s,"sessionId":"%s","status":"idle","kind":"interactive"}\n' "$np" "$sid" >"$to/sessions/$np.json" ;;
    esac
    echo '{"ok":true}' ;;
esac
S
chmod +x "$SHIM/orca"
export HI_ORCA="$SHIM/orca" LOG SANDBOX

echo '== target and sessions'
accounts idb
assert_eq 'target is the selected account' "$B	b@x	org-b" "$(bash "$ACC" target)"
accounts system
assert_eq 'system selected: the system default dir' "$SYS	sys@x	org-s" "$(bash "$ACC" target)"
accounts idb
session "$A" 101 s-one idle term_1 ptr --plugin-dir /x/agent-view --dangerously-skip-permissions --resume old-id --model haiku
session "$A" 102 s-two busy term_2 ptr
session "$B" 103 s-three idle term_3 ptr
mkdir -p "$HI_PROC/104"; printf 'X=1\0' >"$HI_PROC/104/environ"
printf '{"pid":104,"sessionId":"s-nopane","status":"idle"}\n' >"$A/sessions/104.json"
printf '{"pid":105,"sessionId":"s-dead","status":"idle"}\n' >"$A/sessions/105.json"
printf '{"pid":106,"sessionId":"s-print","status":"idle","kind":"print"}\n' >"$A/sessions/106.json"
out=$(bash "$ACC" sessions)
assert_eq 'three live sessions in panes' 3 "$(printf '%s\n' "$out" | awk 'NF' | wc -l | tr -d ' ')"
assert_contains 'a row: handle, session, status, dir, pid' "$out" "term_1	s-one	idle	$A	101	/w"
assert_not_contains 'a session outside a pane is not listed' "$out" s-nopane
assert_not_contains 'a dead pid is not listed' "$out" s-dead
assert_not_contains 'a headless session is not listed' "$out" s-print

echo '== lost'
assert_eq 'connectors the new account lacks' "Meetings
Google Docs" "$(bash "$ACC" lost "$A" "$B")"
assert_eq 'nothing lost the other way' '' "$(bash "$ACC" lost "$B" "$A")"

echo '== move --dry-run'
out=$(bash "$ACC" move --dry-run --only term_1)
assert_contains 'the relaunch keeps its flags' "$out" "would-move	term_1	s-one	claude --resume s-one --plugin-dir /x/agent-view --dangerously-skip-permissions --model haiku"
assert_not_contains 'an earlier --resume is dropped' "$out" old-id
assert_contains 'the lost connectors reach the session' "$out" "--append-system-prompt 'This session moved from the Claude account a@x to b@x. The claude.ai connectors Meetings, Google Docs are not available"
session "$A" 110 s-again idle term_again ptr --model haiku --append-system-prompt 'This session moved from the Claude account x to a@x.' --append-system-prompt 'keep me'
out=$(bash "$ACC" move --dry-run --only term_again)
assert_eq 'a second move drops the earlier note, keeps another prompt' 1 "$(printf '%s' "$out" | grep -o 'This session moved' | wc -l | tr -d ' ')"
assert_contains 'the other appended prompt stays' "$out" "--append-system-prompt 'keep me'"
rm -rf "$HI_PROC/110" "$A/sessions/110.json"
assert_not_contains 'a session already on the target is left' "$(bash "$ACC" move --dry-run)" term_3
assert_eq 'dry-run types nothing' '' "$(grep 'terminal send' "$LOG")"

echo '== move'
: >"$LOG"
out=$(bash "$ACC" move --only s-one --wait 0 2>"$SANDBOX/err"); rc=$?
assert_status 'moved: exit 0' 0 "$rc"
assert_contains 'a moved row with the lost connectors' "$out" "moved	term_1	s-one	b@x; lost connectors: Meetings, Google Docs"
assert_contains '/exit typed first' "$(grep 'terminal send' "$LOG" | head -1)" '--text /exit'
assert_contains 'then the relaunch line' "$(grep 'terminal send' "$LOG" | sed -n 2p)" '--text claude --resume s-one'
assert_contains 'the organization note' "$(cat "$SANDBOX/err")" 'thinking written under another one'

echo '== busy is never typed into'
: >"$LOG"
out=$(bash "$ACC" move --only term_2 --wait 0); rc=$?
assert_status 'still busy: exit 3' 3 "$rc"
assert_contains 'a busy row' "$out" "busy	term_2	s-two"
assert_eq 'nothing typed into a busy session' '' "$(grep 'terminal send' "$LOG")"
# Idle by its status file, but the screen is not: still busy.
session "$A" 107 s-four idle term_4 ptr
echo false >"$SANDBOX/tui-idle"
out=$(bash "$ACC" move --only term_4 --wait 0); rc=$?
assert_status 'a screen not idle: exit 3' 3 "$rc"
rm -f "$SANDBOX/tui-idle"

echo '== failures'
session "$A" 108 s-five idle term_5 ''
out=$(bash "$ACC" move --only term_5 --wait 0); rc=$?
assert_status 'no Orca wrapper: exit 1' 1 "$rc"
assert_contains 'skipped with the reason' "$out" "skipped	term_5	s-five	its pane has no Orca claude wrapper"
touch "$SANDBOX/stuck"
out=$(bash "$ACC" move --only term_4 --wait 0); rc=$?
rm -f "$SANDBOX/stuck"
assert_status 'did not exit: exit 1' 1 "$rc"
assert_contains 'failed, no relaunch typed' "$out" "failed	term_4	s-four	the session did not exit"
session "$A" 109 s-six idle term_6 ptr
touch "$SANDBOX/nostart"
out=$(bash "$ACC" move --only term_6 --wait 0); rc=$?
rm -f "$SANDBOX/nostart"
assert_status 'not seen starting: exit 1' 1 "$rc"
assert_contains 'unconfirmed: look at the pane' "$out" "unconfirmed	term_6	s-six"

echo '== this session moves last'
rm -f "$A"/sessions/*.json; rm -rf "${HI_PROC:?}"/*
session "$A" 201 s-self idle term_self ptr
session "$A" 202 s-other idle term_other ptr
: >"$LOG"
out=$(HI_ACCOUNT_SELF=201 HI_ACCOUNT_DETACH=0 bash "$ACC" move --wait 0)
assert_eq 'the other session first, this one last' "term_other
term_self" "$(printf '%s\n' "$out" | cut -f2)"
rm -f "$B"/sessions/*.json
session "$A" 203 s-self2 idle term_self2 ptr
out=$(HI_ACCOUNT_SELF=203 bash "$ACC" move --dry-run)
assert_contains 'dry-run names this session as self' "$out" "self	term_self2	s-self2"

echo '== a busy session holds back no idle one'
rm -f "$A"/sessions/*.json "$B"/sessions/*.json; rm -rf "${HI_PROC:?}"/*
session "$A" 301 s-busy busy term_busy ptr
session "$A" 302 s-idle idle term_idle ptr
session "$A" 303 s-dialog waiting term_dialog ptr
out=$(HI_MOVE_ROUND=1 bash "$ACC" move --wait 2 2>/dev/null)
assert_eq 'the idle one moved first; the busy and the one on a dialog reported at the deadline' "moved	term_idle
busy	term_busy
busy	term_dialog" "$(printf '%s\n' "$out" | cut -f1-2)"
# A session that turns idle during the wait moves in a later round.
rm -f "$B"/sessions/*.json
session "$A" 304 s-later busy term_later ptr
( sleep 1; jq '.status = "idle"' "$A/sessions/304.json" >"$A/sessions/304.t" && mv "$A/sessions/304.t" "$A/sessions/304.json" ) &
out=$(HI_MOVE_ROUND=1 bash "$ACC" move --only term_later --wait 10 2>/dev/null); wait
assert_contains 'turned idle: moved in a later round' "$out" "moved	term_later"

echo '== nothing to move'
rm -f "$A"/sessions/*.json
assert_status 'every session on the target: exit 0' 0 "$(bash "$ACC" move >/dev/null 2>&1; echo $?)"

assert_summary
