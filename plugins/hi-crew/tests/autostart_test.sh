#!/usr/bin/env bash
# crew.sh autostart and usage: the off switch, slots, the label gate, no double start, the usage
# check, and the default GitHub candidates — against a fake Orca and fake candidates.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json" HI_ACCOUNT="$T/acct" HI_ORCA_PROFILES="$T/profiles"
export HI_WT_SH="$T/no-wt.sh"  # the watch's board moves never reach the real Orca through wt.sh
# The plan usage: a live answer under every line unless a test says otherwise (lib/budget.sh).
export HI_BUDGET_REFRESH=0 HI_BUDGET_RESPONSE="$T/live.json"
live() { # <5h %> <7d %> → the usage endpoint's answer, 5h resetting in 4 h, 7d in 6 days
  jq -n --argjson p5 "$1" --argjson p7 "$2" --argjson now "$(date +%s)" '
    def iso: todate | sub("Z$"; ".214621+00:00");
    {five_hour: {utilization: $p5, resets_at: ($now + 14400 | iso)},
     seven_day: {utilization: $p7, resets_at: ($now + 518400 | iso)}}' >"$T/live.json"; }
command -v jq >/dev/null && live 20 20
S="$T/state/crew"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

mkdir -p "$T/bin" "$T/root/.claude" "$T/acct" "$T/ws"
# The coordinator root is a team's: spec refuses a root with no profile (highness#108).
git -C "$T/root" init -q && echo '{"crew": {"process": "Team process."}}' >"$T/root/.claude/highness.json"
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
  "orchestration worker-stop") printf '%s\n' "$*" >>"$FAKE_LOG.stop"
    [ -z "${FAKE_STOP_FAIL:-}" ] || { echo '{"ok":false,"error":{"message":"stop_unknown"}}'; exit 1; }
    echo '{"ok":true,"result":{"processAction":"closed_agent_terminal"}}' ;;
  "account list") if [ -n "${FAKE_ACCOUNTS:-}" ]; then cat "$FAKE_ACCOUNTS"
    else echo '{"ok":true,"result":{"activeAccountId":null,"accounts":[]}}'; fi ;;
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

# --- usage: lib/budget.sh decides (its own rules are budget_test.sh)
now=$(date +%s)
usage() { jq -n --argjson now "$now" --argjson p5 "$1" --argjson p7 "$2" --argjson upd "${3:-$now}" \
  '{five_hour: {used_percentage: $p5, resets_at: ($now + 3600)}, seven_day: {used_percentage: $p7, resets_at: ($now + 86400)}, updated_at: $upd}' \
  >"$T/acct/highness-usage.json"; }
reset; cfg '{}'; usage 40 60
check 'usage: both windows read from the cache' "$(bash "$C" usage "$T/acct" | tr '\t\n' ': ')" 'five_hour:40 seven_day:60 '
reset; cfg '{}'; live 20 20
bash "$C" autostart >/dev/null
check 'usage under the line: starts' "$(starts)" 2
reset; cfg '{}'; live 20 70
out=$(bash "$C" autostart)
has 'usage over: one skip line naming the window' "$out" '7d 70% (agents up to 57%, resets in '
has 'usage over: marks the window' "$out" ') over on '
has 'usage over: says it holds' "$out" 'hold; nothing started'
check 'usage over: nothing starts' "$(starts)" 0
reset; cfg '{}'; live 20 70; jq '.crew.budget = {seven_day_reserve: 20}' "$HIGHNESS_CONFIG" >"$T/c" && mv "$T/c" "$HIGHNESS_CONFIG"
bash "$C" autostart >/dev/null
check 'usage: the reserve is configurable' "$(starts)" 2
reset; cfg '{}'
HI_BUDGET_RESPONSE=fail bash "$C" autostart >/dev/null
check 'usage unknown: holds' "$(starts)" 0
reset; cfg '{}'; usage 10 10
HI_BUDGET_RESPONSE=fail bash "$C" autostart >/dev/null
check 'usage: the endpoint down, a fresh cache decides' "$(starts)" 2
reset; cfg '{}'; usage 10 10 $((now - 7200))
HI_BUDGET_RESPONSE=fail bash "$C" autostart >/dev/null
check 'usage: a stale cache is unknown, holds' "$(starts)" 0
reset; cfg '{}'; jq '.crew.budget = {on_unknown: "go"}' "$HIGHNESS_CONFIG" >"$T/c" && mv "$T/c" "$HIGHNESS_CONFIG"
HI_BUDGET_RESPONSE=fail bash "$C" autostart >/dev/null
check 'usage unknown with on_unknown go: starts' "$(starts)" 2
reset; cfg '{}'
jq -n --argjson now "$now" '{five_hour: {used_percentage: 99, resets_at: ($now - 10)}, updated_at: $now}' >"$T/acct/highness-usage.json"
check 'usage: a window already reset is unknown' "$(bash "$C" usage "$T/acct")" ''
live 20 20

# --- a held autostart: kept with its first time, shown after an hour, cleared by a pass that goes
reset; cfg '{}'
HI_BUDGET_RESPONSE=fail bash "$C" autostart >/dev/null
check 'hold: the marker keeps the reason' "$(cut -f2 "$S/autostart/held")" "usage unknown on $T/acct; hold; nothing started"
since=$(cut -f1 "$S/autostart/held")
check 'hold: under an hour, the agenda line is quiet' "$(bash "$C" held)" ''
HI_NOW=$((since + 7300)) HI_BUDGET_RESPONSE=fail bash "$C" autostart >/dev/null
check 'hold: a later pass keeps the first time' "$(cut -f1 "$S/autostart/held")" "$since"
check 'hold: over an hour, the agenda line' "$(HI_NOW=$((since + 7300)) bash "$C" held)" \
  "autostart held 2 h: usage unknown on $T/acct; hold; nothing started"
rm -f "$S/handles/run_aaa111"
bash "$C" autostart >/dev/null
has 'hold: no coordinator is a hold too' "$(cut -f2 "$S/autostart/held")" 'no coordinator to start under'
echo term_1 >"$S/handles/run_aaa111"
HI_BUDGET_RESPONSE=fail bash "$C" autostart --dry-run >/dev/null 2>&1
has 'hold: a dry run writes nothing' "$(cut -f2 "$S/autostart/held")" 'no coordinator to start under'
bash "$C" autostart >/dev/null
check 'hold: a pass that starts clears it' "$(ls "$S/autostart/held" 2>/dev/null; bash "$C" held)" ''
HI_BUDGET_RESPONSE=fail bash "$C" autostart >/dev/null; cfg '{"enabled": false}'
bash "$C" autostart >/dev/null
check 'hold: autostart turned off clears it' "$(ls "$S/autostart/held" 2>/dev/null)" ''

# --- the account: Orca's active one, else the profile Orca launches on (selected-host), else
# crew.budget.config_dir, else the freshest usage cache among the profile homes
P="$T/profiles"; mkdir -p "$P/p-one/home" "$P/p-two/home" "$T/own"
acct() { (unset HI_ACCOUNT; CLAUDE_CONFIG_DIR="$T/own" bash "$C" account); }
export FAKE_ACCOUNTS="$T/accounts.json"
jq -n --arg h "$P/p-two/home" '{ok: true, result: {activeAccountId: "p-two", accounts: [{id: "p-one", home: "/nowhere"}, {id: "p-two", home: $h}]}}' >"$FAKE_ACCOUNTS"
check 'account: Orca'"'"'s active account (the flat result Orca prints)' "$(acct)" "$P/p-two/home"
jq '{ok, result: {claude: .result}}' "$FAKE_ACCOUNTS" >"$T/c" && mv "$T/c" "$FAKE_ACCOUNTS"
check 'account: an active account nested under result.claude' "$(acct)" "$P/p-two/home"
echo '{"ok":true,"result":{"activeAccountId":null,"accounts":[]}}' >"$FAKE_ACCOUNTS"
printf '%s' "$P/p-one/home" >"$P/selected-host"
check 'account: empty list, selected-host names a home (no newline)' "$(acct)" "$P/p-one/home"
echo p-two >"$P/selected-host"
check 'account: empty list, selected-host names an id' "$(acct)" "$P/p-two/home"
reset; cfg '{}'
jq -n --argjson now "$now" '{five_hour: {used_percentage: 5, resets_at: ($now + 3600)}, seven_day: {used_percentage: 5, resets_at: ($now + 86400)}, updated_at: $now}' >"$P/p-two/home/highness-usage.json"
(unset HI_ACCOUNT; CLAUDE_CONFIG_DIR="$T/own" HI_BUDGET_RESPONSE=fail bash "$C" autostart >/dev/null)
check 'account: autostart reads the budget of the selected profile and starts' "$(starts)" 2
echo /nowhere >"$P/selected-host"
jq --arg d "$T/own" '.crew.budget.config_dir = $d' "$HIGHNESS_CONFIG" >"$T/c" && mv "$T/c" "$HIGHNESS_CONFIG"
check 'account: selected-host names no dir; crew.budget.config_dir' "$(acct)" "$T/own"
cfg '{}'
jq -n --argjson t "$((now - 60))" '{updated_at: $t}' >"$P/p-one/home/highness-usage.json"
check 'account: then the freshest usage cache' "$(acct)" "$P/p-two/home"
jq -n --argjson t "$((now + 60))" '{updated_at: $t}' >"$P/p-one/home/highness-usage.json"
check 'account: the freshest wins' "$(acct)" "$P/p-one/home"
rm -f "$P"/*/home/highness-usage.json "$P/selected-host"
check 'account: nothing known, the config dir' "$(acct)" "$T/own"
unset FAKE_ACCOUNTS

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

# --- with tracker.kind at the root, the default candidates come from the tracker adapter
reset
mkdir -p "$T/root/.claude"
echo '{"tracker": {"kind": "github", "statuses": {"in-progress": "active"}}}' >"$T/root/.claude/highness.json"
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$GH_LOG"
echo '[{"number":8,"title":"Eight","url":"https://github.com/acme/widgets/issues/8","state":"OPEN","labels":[{"name":"auto"}],"createdAt":"2026-01-01T00:00:00Z"},
       {"number":9,"title":"Nine","url":"https://github.com/acme/widgets/issues/9","state":"OPEN","labels":[{"name":"auto"},{"name":"in-progress"}],"createdAt":"2026-01-01T00:00:00Z"}]'
EOF
# No take here (its own section below): this fake gh answers the list to every call.
jq -n --arg root "$T/root" '{crew: {autostart: {enabled: true, root: $root, take: false}}}' >"$HIGHNESS_CONFIG"
PATH="$T/bin:$PATH" GH_LOG="$T/ghlog" bash "$C" autostart >/dev/null
check 'tracker candidates: only the ready ones' "$(started_keys)" 'widgets-8 '
has 'tracker candidates: the adapter asked for the label' "$(cat "$T/ghlog")" 'issue list -R acme/widgets --label auto --state open'

# --- the take (highness#40): the ticket is locked right after worker-start, before the worker reads it
# Fake gh for one issue, #8: list answers it with its labels, view with the labels in $GH_LABELS,
# edit keeps the labels it leaves (role labels only: in-progress), comment logs its body.
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GH_LOG"
labels=$(cat "$GH_LABELS")
case "$1 $2" in
  "issue list") printf '[{"number":8,"title":"Eight","url":"https://github.com/acme/widgets/issues/8","state":"OPEN","labels":%s,"createdAt":"2026-01-01T00:00:00Z"}]\n' "$labels" ;;
  "issue view") printf '{"number":8,"title":"Eight","url":"https://github.com/acme/widgets/issues/8","state":"OPEN","labels":%s}\n' "$labels" ;;
  "issue edit") case "$*" in
      *"--add-label in-progress"*) echo '[{"name":"auto"},{"name":"in-progress"}]' >"$GH_LABELS" ;;
      *"--remove-label in-progress"*) echo '[{"name":"auto"}]' >"$GH_LABELS" ;;
    esac ;;
  "issue comment") [ -z "${GH_COMMENT_FAIL:-}" ] || { echo 'HTTP 502' >&2; exit 1; }
    cat >>"$GH_LOG.comment" ;;
esac
EOF
chmod +x "$T/bin/gh"
echo '{"crew": {"process": "Team process."}, "tracker": {"kind": "github", "statuses": {"in-progress": "active"}}}' >"$T/root/.claude/highness.json"
treset() { reset; rm -f "$T/ghlog" "$T/ghlog.comment" "$T/starts.stop" "$T/took"; echo '[{"name":"auto"}]' >"$T/labels"; }
tcfg() { jq -n --arg root "$T/root" --argjson x "$1" '{crew: {autostart: ({enabled: true, root: $root, max_active: 1} + $x)}}' >"$HIGHNESS_CONFIG"; }
trun() { PATH="$T/bin:$PATH" GH_LOG="$T/ghlog" GH_LABELS="$T/labels" bash "$C" "$@"; }

treset; tcfg '{}'
out=$(trun autostart)
has 'take: the ticket moves to active' "$(cat "$T/ghlog")" 'issue edit 8 -R acme/widgets --add-label in-progress'
check 'take: the lock comment names the workspace by its name and the dispatch' "$(cat "$T/ghlog.comment")" \
  '(agent) hi-crew took this ticket for workspace w1, dispatch ctx_new1.'
check 'take: recorded in the facts' "$(bash "$C" get widgets-8 | jq -r '.taken_by')" default
has 'take: then logged as started' "$out" 'started	widgets-8'
has 'take: the spec says the ticket is already taken' "$(cat "$S/specs/widgets-8.md")" 'The ticket is already taken'
check 'take: the spec drops the take step' "$(grep -c 'Then take it per the team process' "$S/specs/widgets-8.md")" 0
check 'take: the ticket is no longer a candidate anywhere' \
  "$(PATH="$T/bin:$PATH" GH_LOG="$T/ghlog" GH_LABELS="$T/labels" bash "$HERE/../lib/tracker.sh" --root "$T/root" candidates auto)" ''
check 'take: the worker is not stopped' "$([ -f "$T/starts.stop" ] && echo stopped || echo running)" running
out=$(trun take widgets-8)
has 'take again: nothing done' "$out" 'widgets-8 was taken at'
check 'take again: no second lock comment' "$(grep -o 'hi-crew took this ticket' "$T/ghlog.comment" | wc -l | tr -d ' ')" 1

# a failed lock comment: the move is undone, the worker stopped, its facts closed, the coordinator told
treset; tcfg '{}'
out=$(GH_COMMENT_FAIL=1 trun autostart 2>&1)
has 'comment fails: logged as failed' "$out" 'failed	widgets-8	could not take the ticket (the lock comment failed'
has 'comment fails: moved back to the role it had' "$out" 'moved back to todo'
has 'comment fails: the move is undone' "$(tail -1 "$T/ghlog")" 'issue edit 8 -R acme/widgets --remove-label in-progress'
has 'comment fails: its worker is stopped' "$(cat "$T/starts.stop")" 'worker-stop --dispatch ctx_new1'
check 'comment fails: its facts are closed' "$(bash "$C" get widgets-8 >/dev/null 2>&1 && echo open || echo closed)" closed
has 'comment fails: a watch event for the agenda' "$(cut -f2,5 "$S/watch/events")" 'widgets-8	could not take the ticket'
has 'comment fails: the coordinator hears of it' "$(cat "$T/starts.send")" 'could not take the ticket'
trun autostart >/dev/null 2>&1
check 'comment fails: not retried' "$(starts)" 1

# taken by someone else after the candidates were read: --exclusive refuses it, nothing is moved
treset; tcfg '{}'
bash "$C" record widgets-8 '{"dispatch":"ctx_x","run":"run_aaa111","root":"'"$T/root"'","workspace":"'"$T/ws/w9"'"}'
echo '[{"name":"auto"},{"name":"in-progress"}]' >"$T/labels"
out=$(trun take widgets-8 --exclusive 2>&1); rc=$?
check 'taken elsewhere: exit 2' "$rc" 2
has 'taken elsewhere: says why' "$out" 'no longer ready (role active)'
check 'taken elsewhere: nothing moved or commented' "$(grep -c 'issue edit\|issue comment' "$T/ghlog")" 0

# a stop Orca cannot confirm keeps the facts open
treset; tcfg '{}'
out=$(GH_COMMENT_FAIL=1 FAKE_STOP_FAIL=1 trun autostart 2>&1)
check 'stop unconfirmed: the facts stay open' "$(bash "$C" get widgets-8 >/dev/null 2>&1 && echo open || echo closed)" open
has 'stop unconfirmed: the event says so' "$(cat "$S/watch/events")" 'stopping its worker was not confirmed'

# the person's own take command, its placeholders shell-quoted; a failing one fails the take
treset; tcfg '{"take": "printf \"%s|%s|%s|%s\\n\" {{KEY}} {{DISPATCH}} {{WORKSPACE}} {{MARKER}} >'"$T"'/took"}'
trun autostart >/dev/null
check 'custom take: run with the placeholders' "$(cat "$T/took")" \
  "widgets-8|ctx_new1|$T/ws/w1|(agent) hi-crew took this ticket for workspace w1, dispatch ctx_new1."
check 'custom take: the tracker is not moved' "$(grep -c 'issue edit' "$T/ghlog")" 0
check 'custom take: recorded' "$(bash "$C" get widgets-8 | jq -r '.taken_by')" custom
# Another coordinator root (a manual start there): the command is not its own, and no tracker there.
mkdir -p "$T/other/.claude"; git -C "$T/other" init -q
echo '{"crew": {"process": "Other process."}}' >"$T/other/.claude/highness.json"
check 'custom take: not for another root' "$(trun take --configured "$T/other" && echo yes || echo no)" no
trun spec --key O-1 --title O --root "$T/other" >/dev/null
check 'custom take: another root'"'"'s spec keeps the worker'"'"'s take step' \
  "$(grep -c 'Then take it per the team process' "$S/specs/O-1.md")" 1
treset; tcfg '{"take": "exit 4"}'
has 'custom take fails: logged' "$(trun autostart 2>&1)" 'crew.autostart.take exited 4'
has 'custom take fails: its worker is stopped' "$(cat "$T/starts.stop")" 'worker-stop --dispatch ctx_new1'

# a repo file cannot set the take command (it runs shell); false turns the default off
treset; tcfg '{}'
echo '{"crew": {"process": "Team process.", "autostart": {"take": "touch '"$T"'/took"}}, "tracker": {"kind": "github", "statuses": {"in-progress": "active"}}}' >"$T/root/.claude/highness.json"
trun autostart >/dev/null
check 'a repo file: its take command is not run' "$([ -f "$T/took" ] && echo ran || echo no)" no
has 'a repo file: the default take runs' "$(cat "$T/ghlog")" 'issue edit 8'
treset; tcfg '{"take": false}'
trun autostart >/dev/null
check 'take false: no move' "$(grep -c 'issue edit\|issue comment' "$T/ghlog")" 0
check 'take false: not recorded' "$(bash "$C" get widgets-8 | jq -r '.taken // "none"')" none
grep -q 'Then take it per the team process' "$S/specs/widgets-8.md" && ok 'take false: the worker takes it' || no 'take false: the worker takes it'
check 'take --configured: off' "$(trun take --configured "$T/root" && echo yes || echo no)" no
tcfg '{}'
check 'take --configured: the default' "$(trun take --configured "$T/root" && echo yes || echo no)" yes
check 'take --configured: no tracker, no take' "$(trun take --configured "$T/clone" && echo yes || echo no)" no
rm -f "$T/root/.claude/highness.json"

# --- a root with no team profile starts nothing, and the log says why (highness#108)
reset; cfg '{}'
out=$(bash "$C" autostart 2>&1)
check 'no profile: starts nothing' "$(starts)" 0
has 'no profile: the log names the reason' "$out" 'could not build the spec: spec: no team profile at'

exit $fail
