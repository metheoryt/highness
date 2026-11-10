#!/usr/bin/env bash
# crew.sh autostart and usage: the off switch, slots, the label gate, no double start, the usage
# check, and the default GitHub candidates — against a fake Orca and fake candidates.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json" HI_ACCOUNT="$T/acct"
S="$T/state/crew"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

mkdir -p "$T/bin" "$T/root" "$T/acct" "$T/ws"
# Fake Orca: worker-start logs its arguments and answers a receipt (or fails when FAKE_FAIL is
# set); the inbox holds one worker_done for dispatch ctx_done; send is a no-op.
cat >"$T/bin/fakeorca" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "orchestration worker-start")
    printf '%s\n' "$*" >>"$FAKE_LOG"
    [ -z "${FAKE_FAIL:-}" ] || { echo '{"ok":false,"error":{"message":"no such terminal"}}'; exit 1; }
    n=$(wc -l <"$FAKE_LOG" | tr -d ' ')
    mkdir -p "$FAKE_WS/w$n"
    printf '{"ok":true,"result":{"dispatchId":"ctx_new%s","taskId":"task_%s","runId":"run_aaa111","workspace":"repo1::%s/w%s"}}\n' "$n" "$n" "$FAKE_WS" "$n" ;;
  "orchestration inbox")
    echo '{"ok":true,"result":{"messages":[{"id":"m1","run_id":"run_aaa111","type":"worker_done","created_at":"2026-01-01T00:00:00Z","subject":"done","payload":"{\"dispatchId\":\"ctx_done\",\"outcome\":\"succeeded\"}"}]}}' ;;
  "orchestration send") printf 'send %s\n' "$*" >>"$FAKE_LOG.send" ;;
  *) echo '{"ok":false}'; exit 1 ;;
esac
EOF
chmod +x "$T/bin/fakeorca"
export ORCA_CLI_COMMAND="$T/bin/fakeorca" FAKE_LOG="$T/starts" FAKE_WS="$T/ws"

# Fake candidates: the command gets the label as $1 and prints the tickets that carry it.
cat >"$T/cands.sh" <<'EOF'
#!/bin/sh
[ "$1" = "${WANT_LABEL:-auto}" ] || exit 0
cat "$CANDS"
EOF
export CANDS="$T/cands"
cat >"$CANDS" <<'EOF'
{"key":"AB-3","title":"Third","url":"https://t/AB-3","created":"2026-01-03"}
{"key":"AB-1","title":"First","url":"https://t/AB-1","created":"2026-01-01"}
{"key":"AB-2","title":"Second","url":"https://t/AB-2","created":"2026-01-02","repo":"id:other"}
EOF

cfg() { # <extra json merged into crew.autostart>
  jq -n --arg root "$T/root" --arg cmd "sh $T/cands.sh {{LABEL}}" --argjson x "$1" \
    '{crew: {autostart: ({enabled: true, root: $root, candidates: $cmd, max_active: 2} + $x)}}' >"$HIGHNESS_CONFIG"
}
reset() { rm -rf "$S" "$T/starts" "$T/starts.send" "$T/acct/highness-usage.json"; mkdir -p "$S/handles"; echo term_1 >"$S/handles/run_aaa111"; }
starts() { [ -f "$T/starts" ] && wc -l <"$T/starts" | tr -d ' ' || echo 0; }
started_keys() { [ -f "$T/starts" ] && sed -n 's/.*--name \([^ ]*\) .*/\1/p' "$T/starts" | tr '\n' ' '; }

# --- the off switch
reset; echo '{}' >"$HIGHNESS_CONFIG"
check 'off: prints nothing' "$(bash "$C" autostart)" ''
check 'off: starts nothing' "$(starts)" 0
cfg '{"enabled": false}'
bash "$C" autostart >/dev/null
check 'enabled false: starts nothing' "$(starts)" 0
has 'off: a dry run still shows what it would do' "$(bash "$C" autostart --dry-run 2>/dev/null)" "would-start	AB-1"
check 'dry run: starts nothing and keeps no log' "$(starts) $(ls "$S/autostart" 2>/dev/null | wc -l | tr -d ' ')" '0 0'
# The settings are the user's own: a repo file cannot turn autostart on.
reset; echo '{}' >"$HIGHNESS_CONFIG"
mkdir -p "$T/clone/.claude"; git -C "$T/clone" init -q
jq -n --arg root "$T/root" '{crew: {autostart: {enabled: true, root: $root}}}' >"$T/clone/.claude/highness.json"
(cd "$T/clone" && bash "$C" autostart >/dev/null)
check 'a repo file cannot turn it on' "$(starts)" 0

# --- starts oldest first, into the free slots, under the coordinator's Run
reset; cfg '{}'
out=$(bash "$C" autostart)
check 'two slots: the two oldest start' "$(started_keys)" 'AB-1 AB-2 '
has 'start: under the Run, from its terminal' "$(head -1 "$T/starts")" '--run run_aaa111 --from term_1'
has 'start: a new top-level workspace from origin/main' "$(head -1 "$T/starts")" '--worktree new-top-level --repo path:'"$T/root"' --name AB-1 --base-branch origin/main --agent claude'
has 'start: a candidate'"'"'s repo wins' "$(sed -n 2p "$T/starts")" '--repo id:other'
check 'facts recorded' "$(bash "$C" get AB-1 | jq -r '[.dispatch, .run, .workspace, .root, .autostart] | map(tostring) | join(" ")')" "ctx_new1 run_aaa111 $T/ws/w1 $T/root true"
has 'one log line per start' "$out" "started	AB-1	$T/ws/w1"
has 'the coordinator hears of it' "$(cat "$T/starts.send")" '--to run:run_aaa111 --from term_1'

# --- no double start
bash "$C" autostart >/dev/null
check 'full slots: nothing more starts' "$(starts)" 2
cfg '{"max_active": 5}'
bash "$C" autostart >/dev/null
check 'open facts or a tried marker: never started twice' "$(started_keys)" 'AB-1 AB-2 AB-3 '
bash "$C" close AB-1; cfg '{"max_active": 9}'
bash "$C" autostart >/dev/null
check 'a closed ticket that keeps the label is not started again' "$(starts)" 3

# --- slots: a merged PR or a worker that reported with no PR frees one
reset; cfg '{"max_active": 3}'
mkdir -p "$S/watch"
bash "$C" record X-1 '{"pr":"https://f/pr/1","dispatch":"ctx_x1","run":"run_aaa111"}'; echo '{"state":"open"}' >"$S/watch/X-1.json"
bash "$C" record X-2 '{"pr":"https://f/pr/2","dispatch":"ctx_x2","run":"run_aaa111"}'; echo '{"state":"merged"}' >"$S/watch/X-2.json"
bash "$C" record X-3 '{"dispatch":"ctx_done","run":"run_aaa111"}'
bash "$C" record X-4 '{"dispatch":"ctx_running","run":"run_aaa111"}'
has 'slots: open PR and a running worker are busy; merged and reported are free' "$(bash "$C" autostart --dry-run)" "slots	1 free of 3	busy: X-1,X-4"
bash "$C" autostart >/dev/null
check 'slots: one start into the one free slot' "$(started_keys)" 'AB-1 '

# --- the label gate
reset; cfg '{"label": "agent-go"}'
bash "$C" autostart >/dev/null
check 'label: the command is asked for the configured label' "$(starts)" 0
WANT_LABEL=agent-go bash "$C" autostart >/dev/null
check 'label: tickets with it start' "$(starts)" 2

# --- no coordinator, a failing start
reset; rm -f "$S/handles/run_aaa111"; cfg '{}'
has 'no coordinator terminal: one skip line' "$(bash "$C" autostart)" 'skip	-	no coordinator'
check 'no coordinator: nothing starts' "$(starts)" 0
reset; cfg '{}'
out=$(FAKE_FAIL=1 bash "$C" autostart)
has 'failed start: logged with the reason' "$out" 'failed	AB-1	worker-start: no such terminal'
check 'failed start: no facts' "$(bash "$C" get AB-1 >/dev/null 2>&1 && echo yes || echo no)" no
bash "$C" autostart >/dev/null
check 'failed start: not retried' "$(started_keys)" 'AB-1 AB-2 AB-3 '

# --- usage: under, over, unknown
now=$(date +%s)
usage() { jq -n --argjson now "$now" --argjson p5 "$1" --argjson p7 "$2" --argjson upd "${3:-$now}" \
  '{five_hour: {used_percentage: $p5, resets_at: ($now + 3600)}, seven_day: {used_percentage: $p7, resets_at: ($now + 86400)}, updated_at: $upd}' \
  >"$T/acct/highness-usage.json"; }
reset; cfg '{}'; usage 40 60
check 'usage: both windows read' "$(bash "$C" usage "$T/acct" | tr '\t\n' ': ')" 'five_hour:40 seven_day:60 '
bash "$C" autostart >/dev/null
check 'usage under the threshold: starts' "$(starts)" 2
reset; cfg '{}'; usage 40 85
out=$(bash "$C" autostart)
has 'usage over: one skip line naming the window' "$out" 'seven_day at 85% on '"$T/acct"' (max 80%); nothing started'
check 'usage over: nothing starts' "$(starts)" 0
reset; cfg '{"max_usage_pct": 90}'; usage 40 85
bash "$C" autostart >/dev/null
check 'usage: the threshold is configurable' "$(starts)" 2
reset; cfg '{}'; usage 95 95 $((now - 7200))
bash "$C" autostart >/dev/null
check 'usage stale: unknown, never blocks' "$(starts)" 2
reset; cfg '{}'; echo 'not json' >"$T/acct/highness-usage.json"
bash "$C" autostart >/dev/null
check 'usage unreadable: unknown, never blocks' "$(starts)" 2
reset; cfg '{}'
jq -n --argjson now "$now" '{five_hour: {used_percentage: 99, resets_at: ($now - 10)}, updated_at: $now}' >"$T/acct/highness-usage.json"
check 'usage: a window already reset is unknown' "$(bash "$C" usage "$T/acct")" ''

# --- usage-save keeps the statusline's rate_limits
rm -f "$T/acct/highness-usage.json"
echo '{"model":{},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1}}}' | CLAUDE_CONFIG_DIR="$T/acct" bash "$C" usage-save
check 'usage-save writes the cache' "$(jq -r '.five_hour.used_percentage, (.updated_at | type)' "$T/acct/highness-usage.json" | tr '\n' ' ')" '12 number '
echo '{"model":{}}' | CLAUDE_CONFIG_DIR="$T/acct" bash "$C" usage-save
check 'usage-save: a session without rate_limits keeps the last figure' "$(jq -r '.five_hour.used_percentage' "$T/acct/highness-usage.json")" 12

# --- the watch runs autostart last
reset; cfg '{}'
bash "$C" watch >/dev/null 2>&1
check 'watch: starts labelled tickets' "$(starts)" 2

# --- default candidates: the root's GitHub issues with the label
reset
git -C "$T/root" init -q && git -C "$T/root" remote add origin git@github.com:acme/widgets.git
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$GH_LOG"
echo '[{"number":7,"title":"Seven","url":"https://github.com/acme/widgets/issues/7","createdAt":"2026-01-01T00:00:00Z"}]'
EOF
chmod +x "$T/bin/gh"
jq -n --arg root "$T/root" '{crew: {autostart: {enabled: true, root: $root}}}' >"$HIGHNESS_CONFIG"
PATH="$T/bin:$PATH" GH_LOG="$T/ghlog" bash "$C" autostart >/dev/null
check 'default candidates: keyed <repo>-<number>' "$(started_keys)" 'widgets-7 '
has 'default candidates: gh asked for the label' "$(cat "$T/ghlog")" '--label auto --state open'

exit $fail
