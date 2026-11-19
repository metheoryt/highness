#!/usr/bin/env bash
# lib/hold.sh: the flag a pass writes from budget.sh, the hook that stops only autostarted workers,
# and the resume of exactly the sessions it stopped. No network: HI_BUDGET_RESPONSE stands in; wt.sh
# and orca are stubs that log their arguments.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$HERE/../lib/hold.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_CONFIG="$T/user.json" HIGHNESS_STATE="$T/state" HI_BUDGET_REFRESH=0 HI_BUDGET_RESPONSE="$T/live.json"
export HI_NOW=2000000000 HI_WT_SH="$T/wt.sh" HI_ORCA="$T/orca"
echo '{}' >"$HIGHNESS_CONFIG"
A="$T/acct"; W="$T/ws"; mkdir -p "$A" "$W" "$T/state/crew/handles"
W=$(cd "$W" && pwd -P)
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

live() { # <5h %> <7d %>, both windows fresh
  jq -n --argjson now "$HI_NOW" --argjson p5 "$1" --argjson p7 "$2" '
    {five_hour: {utilization: $p5, resets_at: ($now + 18000 | todate)},
     seven_day: {utilization: $p7, resets_at: ($now + 604800 | todate)}}' >"$T/live.json"
}
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/wt.log"\nexit "${WT_RC:-0}"\n' "$T" >"$T/wt.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/orca.log"\n' "$T" >"$T/orca"; chmod +x "$T/orca"
hook() { # [--worker]: the hook as a session in $W on account $A sees it
  printf '{"session_id":"sess-1","cwd":"%s"}' "$W" | CLAUDE_CONFIG_DIR=$A CLAUDE_PROJECT_DIR=$W bash "$H" hook "$@"
}
markers() { ls "$T/state/held" 2>/dev/null | grep -c . ; }

# --- mark: the flag follows the verdict
live 60 10
bash "$H" mark "$A" >/dev/null; check 'over the line: mark exits 1' "$?" 1
[ -f "$A/highness-hold" ] && ok 'over the line: the flag is written' || no 'over the line: no flag'
has 'the flag says why' "$(cat "$A/highness-hold" 2>/dev/null)" 'hold'
live 20 10
bash "$H" mark "$A" >/dev/null; check 'back under: mark exits 0' "$?" 0
[ -f "$A/highness-hold" ] && no 'back under: the flag stays' || ok 'back under: the flag is gone'
HI_BUDGET_RESPONSE=fail bash "$H" mark "$A" >/dev/null
[ -f "$A/highness-hold" ] && ok 'unknown holds, as the start gate does' || no 'unknown: no flag'
rm -f "$A/highness-hold"

# --- hook: silent with no flag, stops a worker with one
check 'no flag: the hook says nothing' "$(hook --worker)" ''
check 'no flag: no marker' "$(markers)" 0
live 60 10; bash "$H" mark "$A" >/dev/null
out=$(hook --worker)
check 'a worker over the line: continue false' "$(printf '%s' "$out" | jq -r '.continue')" false
check 'and the call is denied' "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" deny
check 'a marker is left for the resume' "$(markers)" 1
m=$(cat "$T/state/held"/*.json)
check 'the marker names the workspace, session and account' \
  "$(printf '%s' "$m" | jq -r '[.workspace, .session, .config_dir, .via] | join(" ")')" "$W sess-1 $A wt"
rm -rf "$T/state/held"

# --- hook without --worker: only a hi-crew record with autostart true for this dir
check 'a session of the person (no record): untouched' "$(hook)" ''
check 'and no marker' "$(markers)" 0
jq -n --arg w "$W" '{key: "K-1", workspace: $w, dispatch: "d-1", run: "run_1"}' >"$T/state/crew/K-1.json"
check 'a hand-started hi-crew worker (no autostart): untouched' "$(hook)" ''
jq -n --arg w "$W" '{key: "K-1", workspace: $w, dispatch: "d-1", run: "run_1", autostart: true}' >"$T/state/crew/K-1.json"
check 'an autostarted hi-crew worker: stopped' "$(hook | jq -r '.continue')" false
check 'its marker resumes through the crew' "$(jq -r '.via + " " + .key' "$T/state/held"/*.json)" 'crew K-1'
rm -rf "$T/state/held"; rm -f "$T/state/crew/K-1.json"

# --- a stale flag (the watch stopped writing it) lets the call run
touch -t 200001010000 "$A/highness-hold"
check 'a stale flag: the hook says nothing' "$(hook --worker)" ''
bash "$H" mark "$A" >/dev/null

# --- resume: only the stopped sessions, only once their account is back
hook --worker >/dev/null
bash "$H" resume
[ -f "$T/wt.log" ] && no 'still held: resume typed into it' || ok 'still held: resume waits'
check 'and keeps the marker' "$(markers)" 1
live 20 10
check 'pass marks, then resumes' "$(bash "$H" pass "$A")" "resumed	$W"
l=$(cat "$T/wt.log" 2>/dev/null)
has 'through wt.sh dispatch into the workspace' "$l" "dispatch $W --brief"
has 'resuming its own session' "$l" '--resume sess-1'
has 'on its account' "$l" "--config-dir $A"
has 'with the hook again, should it start anew' "$l" 'hook --worker'
check 'the marker is gone' "$(markers)" 0
rm -f "$T/wt.log"

live 60 10; bash "$H" mark "$A" >/dev/null; hook --worker >/dev/null; live 20 10
WT_RC=3 bash "$H" pass "$A" >/dev/null
check 'a session mid-turn: the marker is kept for the next pass' "$(markers)" 1
bash "$H" pass "$A" >/dev/null
check 'the next pass resumes it' "$(markers)" 0
rm -f "$T/wt.log"

jq -n --arg w "$W" '{key: "K-1", workspace: $w, dispatch: "d-1", run: "run_1", autostart: true}' >"$T/state/crew/K-1.json"
echo 'term-9' >"$T/state/crew/handles/run_1"
live 60 10; bash "$H" mark "$A" >/dev/null; hook >/dev/null; live 20 10
bash "$H" pass "$A" >/dev/null
l=$(cat "$T/orca.log" 2>/dev/null)
has 'a hi-crew worker: sent to its dispatch' "$l" 'orchestration send --to dispatch:d-1 --from term-9'
check 'and its marker is gone' "$(markers)" 0
[ -f "$T/wt.log" ] && no 'a hi-crew worker went through wt.sh' || ok 'not through wt.sh'

# --- pass with no dirs: the accounts the workers named, and nothing else
rm -rf "$T/state/accounts" "$T/state/held"; rm -f "$A/highness-hold"
B2="$T/acct2"; mkdir -p "$B2"
live 60 10
bash "$H" pass >/dev/null
[ -f "$A/highness-hold" ] && no 'no worker yet: an account was marked' || ok 'no worker yet: no account is asked'
hook --worker >/dev/null
bash "$H" pass >/dev/null
[ -f "$A/highness-hold" ] && ok 'the account a worker ran on is marked' || no 'the worker account was not marked'
[ -f "$B2/highness-hold" ] && no 'an idle account was marked' || ok 'an idle account is not asked'

# --- repoint: the sessions moved to another account (highness#106); their markers follow it
rm -rf "$T/state/held" "$T/state/accounts" "$T/state/crew"/*.json; rm -f "$T/wt.log" "$A/highness-hold" "$B2/highness-hold"
live 60 10; bash "$H" mark "$A" >/dev/null; hook --worker >/dev/null
check 'a session stopped on the old account' "$(markers)" 1
# The new account under its line, read from its own cache; the old one still over.
jq -n --argjson now "$HI_NOW" '{five_hour: {used_percentage: 10, resets_at: ($now + 18000)},
  seven_day: {used_percentage: 10, resets_at: ($now + 604800)}, updated_at: ($now - 60)}' >"$B2/highness-usage.json"
check 'repoint resumes it on the new account' "$(HI_BUDGET_RESPONSE=fail bash "$H" repoint "$B2")" "resumed	$W"
has 'with the new account as its config dir' "$(cat "$T/wt.log" 2>/dev/null)" "--config-dir $B2"
check 'the marker is gone' "$(markers)" 0
rm -f "$T/wt.log"
live 60 10; bash "$H" mark "$A" >/dev/null; hook --worker >/dev/null
echo '{}' >"$B2/highness-usage.json"
HI_BUDGET_RESPONSE=fail bash "$H" repoint "$B2" >/dev/null
[ -f "$T/wt.log" ] && no 'the new account cannot be read: typed into anyway' || ok 'the new account cannot be read: it waits'
check 'its marker now names the new account' "$(bash "$H" held | cut -f3)" "$B2"
bash "$H" repoint "$T/nope" >/dev/null 2>&1; check 'repoint without a dir: usage' "$?" 2

exit $fail
