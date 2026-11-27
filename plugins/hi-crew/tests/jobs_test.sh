#!/usr/bin/env bash
# lib/jobs.sh: the queue of recurring background jobs — due by interval, in its hours, ordered by
# priority, started only under the budget line, a long one only in a fresh 5-hour window; the exit
# contract (0 done, 75 again next tick, else retry later); the hours learned from transcripts.
# No network: HI_BUDGET_RESPONSE stands in for the usage endpoint; jobs run inline.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JS="$HERE/../lib/jobs.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# 2000000000 is 03:33 UTC.
export LC_ALL=C TZ=UTC HIGHNESS_CONFIG="$T/user.json" HIGHNESS_STATE="$T/state" HI_BUDGET_REFRESH=0 \
  HI_BUDGET_RESPONSE="$T/live.json" HI_NOW=2000000000 HI_ACCOUNT="$T/acct" HI_JOBS_FOREGROUND=1 \
  HI_JOBS_PROJECTS="$T/projects"
mkdir -p "$T/acct" "$T/projects" "$T/out"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

# <5h %> <5h seconds left | null> <7d %> <7d seconds left | null>
live() {
  jq -n --argjson now "$HI_NOW" --argjson p5 "$1" --argjson l5 "$2" --argjson p7 "$3" --argjson l7 "$4" '
    def iso: if . == null then null else todate | sub("Z$"; ".214621+00:00") end;
    {five_hour: {utilization: $p5, resets_at: (if $l5 == null then null else $now + $l5 end | iso)},
     seven_day: {utilization: $p7, resets_at: (if $l7 == null then null else $now + $l7 end | iso)},
     extra_usage: {is_enabled: false}}' >"$T/live.json"
}
reset() { rm -rf "$T/state" "$T/acct/highness-hold" "$T/out"/*; echo '{}' >"$HIGHNESS_CONFIG"; }
add() { bash "$JS" add "$1" "$2" >/dev/null; }
tick() { bash "$JS" tick "$@"; }
line() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n { print $2 }'; }
ran() { [ -f "$T/out/$1" ] && echo yes || echo no; }

live 10 18000 10 604800

# --- nothing declared: nothing happens
reset
check 'no jobs: the tick says nothing' "$(tick)" ''

# --- add / remove write the person's file
add a '{"run": "touch '"$T"'/out/a", "every": "daily"}'
check 'add writes crew.jobs.<name>' "$(jq -r '.crew.jobs.a.every' "$HIGHNESS_CONFIG")" daily
bash "$JS" add 'bad name' '{"run": "x"}' >/dev/null 2>&1 && no 'a name with a space is refused' || ok 'a name with a space is refused'
bash "$JS" add b '{"every": "daily"}' >/dev/null 2>&1 && no 'a job without run is refused' || ok 'a job without run is refused'
bash "$JS" remove a >/dev/null
check 'remove drops it' "$(jq -c '.crew.jobs' "$HIGHNESS_CONFIG")" '{}'

# --- a repo's file never declares a job (it runs a command)
reset
mkdir -p "$T/repo/.claude"; git -C "$T/repo" init -q
echo '{"crew": {"jobs": {"evil": {"run": "touch '"$T"'/out/evil"}}}}' >"$T/repo/.claude/highness.json"
(cd "$T/repo" && bash "$JS" tick >/dev/null)
check 'a job in the repo file does not run' "$(ran evil)" no

# --- due by interval; the exit contract
reset
add a '{"run": "touch '"$T"'/out/a; exit 0", "every": "daily"}'
out=$(tick)
check 'a job that never ran starts' "$(line "$out" a)" started
check '... and ran' "$(ran a)" yes
check '... its done run is recorded' "$(jq -r .last_ok "$T/state/jobs/a.json")" 2000000000
check '... and a runs line with both windows' "$(cut -f1,4,5,7 "$T/state/jobs/runs.tsv")" "$(printf 'a\t0\t10\t10')"
rm -f "$T/out/a"
out=$(HI_NOW=2000003600 tick)
has 'an hour later it is not due' "$out" "$(printf 'a\twait\tnot due for')"
check '... and did not run' "$(ran a)" no
out=$(HI_NOW=2000086400 tick)
check 'a day later it is due again' "$(line "$out" a)" started

reset
add t '{"run": "touch '"$T"'/out/t; exit 75"}'
tick >/dev/null
check 'exit 75 is not done' "$(jq -r '.last_ok // "none"' "$T/state/jobs/t.json")" none
check '... it starts again at the next tick' "$(line "$(HI_NOW=2000000600 tick)" t)" started

reset
add f '{"run": "exit 3", "retry": "2h"}'
tick >/dev/null
check 'a failed run is kept with its code' "$(jq -r .rc "$T/state/jobs/f.json")" 3
has '... and waits its retry' "$(HI_NOW=2000003600 tick)" 'not due for 60 min'
check '... then runs again' "$(line "$(HI_NOW=2000007200 tick)" f)" started
check 'list shows a job and its state' "$(bash "$JS" list | cut -f1,2,5)" "$(printf 'f\twaiting, failed\tshort')"

# --- the job's environment
reset
add e '{"run": "printf \"%s|%s|%s\" \"$CLAUDE_CONFIG_DIR\" \"$HI_JOB\" \"$HI_HOLD_HOOK\" >'"$T"'/out/e"}'
tick >/dev/null
has 'the job spends the account the tick measured' "$(cat "$T/out/e")" "$T/acct|e|"
has '... and gets the hold hook for its claude' "$(cat "$T/out/e")" 'hold.sh hook --worker'
reset
mkdir -p "$T/other"
add c '{"run": "printf %s \"$CLAUDE_CONFIG_DIR\" >'"$T"'/out/c", "config_dir": "'"$T"'/other/"}'
tick >/dev/null
check 'a job names its own account' "$(cat "$T/out/c")" "$T/other"

# --- hours
reset
add w '{"run": "touch '"$T"'/out/w", "every": "daily", "when": "8-18"}'
has 'due outside its hours: waits' "$(tick)" 'outside its hours (8-18)'
check 'in its hours: starts' "$(line "$(HI_NOW=$((2000000000 + 6 * 3600)) tick)" w)" started
reset
echo '{"crew": {"jobs": {"w": {"run": "touch '"$T"'/out/w", "every": "daily", "when": "8-18"}}}}' >"$HIGHNESS_CONFIG"
mkdir -p "$T/state/jobs"; echo '{"last_ok": '$((2000000000 - 2 * 86400))'}' >"$T/state/jobs/w.json"
check 'overdue by a full interval: starts outside its hours' "$(line "$(tick)" w)" started
reset
add x '{"run": "touch '"$T"'/out/x", "when": "22-4"}'
check 'a window that wraps midnight holds 03:00' "$(line "$(tick)" x)" started

# --- priority, then how overdue
reset
add lo '{"run": "touch '"$T"'/out/lo", "priority": 1}'
add hi '{"run": "touch '"$T"'/out/hi", "priority": 5}'
tick >/dev/null
check 'the higher priority starts first' "$(ran hi)/$(ran lo)" yes/no
check '... one job per tick' "$(line "$(HI_NOW=2000000060 tick)" lo)" started
reset
add p '{"run": "touch '"$T"'/out/p"}'; add q '{"run": "touch '"$T"'/out/q"}'
mkdir -p "$T/state/jobs"
echo '{"last_ok": '$((2000000000 - 86400 - 60))'}' >"$T/state/jobs/p.json"
echo '{"last_ok": '$((2000000000 - 86400 - 7200))'}' >"$T/state/jobs/q.json"
tick >/dev/null
check 'same priority: the more overdue first' "$(ran q)/$(ran p)" yes/no

# --- one at a time
reset
add r '{"run": "touch '"$T"'/out/r"}'
mkdir -p "$T/state/jobs"; echo '{"pid": '$$'}' >"$T/state/jobs/busy.json"
add busy '{"run": "true", "every": "weekly"}'
out=$(tick)
check 'while one runs nothing else starts' "$(ran r)" no
has '... and it says which runs' "$out" "$(printf 'busy\trunning')"

# --- the budget line
reset
add s '{"run": "touch '"$T"'/out/s"}'
live 60 18000 10 604800
has 'over the 5-hour line: waits' "$(tick)" 'over the budget line'
check '... and the hold flag is written for a running job to stop' "$([ -f "$T/acct/highness-hold" ] && echo yes)" yes
live 85 600 10 604800
check 'ten minutes before the reset a short job fills the leftover' "$(line "$(tick)" s)" started
reset
add s '{"run": "touch '"$T"'/out/s"}'
live 85 600 80 302400
has '... but not when the week is over its line' "$(tick)" 'over the budget line'

# --- a long job: only in a fresh 5-hour window, only in off-hours
reset
echo '{"crew": {"queue": {"off_hours": "1-6"}, "jobs": {"L": {"run": "touch '"$T"'/out/L", "size": "long"}}}}' >"$HIGHNESS_CONFIG"
live 10 7200 10 604800
has 'long, 2 h left in the window: waits' "$(tick)" 'the 5-hour window has 120 min left, a start needs 240'
live 10 17000 10 604800
check 'long, the window just began: starts' "$(line "$(tick)" L)" started
reset
echo '{"crew": {"queue": {"off_hours": "1-6"}, "jobs": {"L": {"run": "touch '"$T"'/out/L", "size": "long"}}}}' >"$HIGHNESS_CONFIG"
live 0 null 10 604800
check 'long, no window running: starts' "$(line "$(tick)" L)" started
reset
echo '{"crew": {"queue": {"off_hours": "1-2"}, "jobs": {"L": {"run": "touch '"$T"'/out/L", "size": "long"}}}}' >"$HIGHNESS_CONFIG"
has 'long, outside the off-hours: waits' "$(tick)" 'outside its hours (1-2)'
reset
echo '{"crew": {"queue": {"off_hours": "1-6", "long_window_left_min": 60}, "jobs": {"L": {"run": "touch '"$T"'/out/L", "size": "long"}}}}' >"$HIGHNESS_CONFIG"
live 10 7200 10 604800
check 'long_window_left_min is the person'"'"'s' "$(line "$(tick)" L)" started

# --- dry run
reset
add d '{"run": "touch '"$T"'/out/d"}'
live 10 18000 10 604800
check '--dry-run says what would start' "$(line "$(tick --dry-run)" d)" 'would start'
check '... and starts nothing' "$(ran d)" no

# --- detached: the tick returns at once, the job outlives the tick's process group
reset
add bg '{"run": "sleep 2; touch '"$T"'/out/bg"}'
s=$(date +%s)
if command -v setsid >/dev/null 2>&1; then
  # The tick in a group of its own, killed when it returns: how a precheck's timeout ends it.
  setsid bash -c 'echo $$ >"$1/tick.pgid"; HI_JOBS_FOREGROUND= bash "$2" tick >/dev/null' _ "$T" "$JS"
  kill -TERM -- "-$(cat "$T/tick.pgid")" 2>/dev/null || :
else
  HI_JOBS_FOREGROUND= bash "$JS" tick >/dev/null
fi
check 'a detached start returns at once' "$([ $(( $(date +%s) - s )) -lt 2 ] && echo yes)" yes
check '... and list says it runs' "$(bash "$JS" list | cut -f2)" running
i=0; while ! jq -e .last_ok "$T/state/jobs/bg.json" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
check '... it finished after the tick'"'"'s group was killed' "$(ran bg)" yes
check '... and is recorded done' "$(jq -r '.last_ok // "none"' "$T/state/jobs/bg.json")" 2000000000

# --- the learned hours
reset
mkdir -p "$T/projects/p"
{
  # 150 of the person's prompts at 10:00-14:59 UTC, 2 at 03:00; machine prompts at 04:00.
  i=0; while [ $i -lt 150 ]; do
    printf '{"type":"user","entrypoint":"cli","timestamp":"2033-05-17T%02d:%02d:00.123Z","message":{"role":"user","content":"do the thing"}}\n' $((10 + i % 5)) $((i % 60))
    i=$((i + 1)); done
  i=0; while [ $i -lt 2 ]; do printf '{"type":"user","entrypoint":"cli","timestamp":"2033-05-17T03:0%d:00.5Z","message":{"role":"user","content":"late"}}\n' $i; i=$((i + 1)); done
  i=0; while [ $i -lt 60 ]; do printf '{"type":"user","entrypoint":"cli","timestamp":"2033-05-17T04:%02d:00Z","message":{"role":"user","content":"Please carry out this task from my Orca coordinator"}}\n' $i; i=$((i + 1)); done
  i=0; while [ $i -lt 60 ]; do printf '{"type":"user","entrypoint":"sdk-cli","timestamp":"2033-05-17T05:%02d:00Z","message":{"role":"user","content":"a headless run"}}\n' $i; i=$((i + 1)); done
  printf '{"type":"user","timestamp":"2033-05-17T06:00:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x"}]}}\n'
} >"$T/projects/p/s.jsonl"
check 'work hours: the busy ones, not machine prompts or headless runs' "$(bash "$JS" hours)" '10,11,12,13,14'
add n '{"run": "touch '"$T"'/out/n", "when": "off"}'
check '"off" = the hours not worked' "$(line "$(tick)" n)" started
echo '{"crew": {"jobs": {"n": {"run": "true", "when": "off"}}}}' >"$HIGHNESS_CONFIG"
rm -rf "$T/state"; mkdir -p "$T/state/jobs"
has 'at 11:00 an off-hours job waits' "$(HI_NOW=$((2000000000 + 8 * 3600)) tick)" 'outside its hours'
rm -rf "$T/state" "$T/projects/p"
check 'too few prompts: nothing learned' "$(bash "$JS" hours)" ''
echo '{"crew": {"jobs": {"n": {"run": "true", "when": "off"}}}}' >"$HIGHNESS_CONFIG"
rm -rf "$T/state"
check '... and the default 1-6 holds 03:00' "$(line "$(tick)" n)" started

exit "$fail"
