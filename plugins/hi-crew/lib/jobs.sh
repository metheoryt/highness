#!/usr/bin/env bash
# jobs.sh — one queue for the recurring background jobs (a nightly memory pass, a weekly digest):
# each runs once its interval has passed and the budget line allows it (highness#37, stage 2 of
# the budget gate in lib/budget.sh).
#
#   jobs.sh tick [--dry-run]      one pass: pick the first due job that fits and start it, detached;
#                                 one line per job says why it runs or waits. The watch runs it
#                                 (crew.sh watch); a box without the watch runs it from one timer.
#   jobs.sh list                  TSV: name, state, last done (epoch or -), due at (epoch), size,
#                                 priority, the last run's 7-day spend (points or -)
#   jobs.sh add <name> <json>     declare or replace a job in the person's own file
#   jobs.sh remove <name>         drop it (its state and runs stay)
#   jobs.sh hours                 the hours the person works, learned (cached a day): "h,h,..."
#   jobs.sh runs                  every run, TSV (see RUNS below)
#
# This is anacron's model: a "weekly" job runs once 7 days passed since its last done run, not at a
# fixed time. A job is an entry of `crew.jobs` in the person's file, read with `config.sh get
# --user` only: an entry runs a command, so a cloned repo's file or an overlay never adds one.
#
#   "crew": {"jobs": {"weekly-digest": {
#       "run": "bash ~/jobs/digest.sh",      required; run with bash -c, in `dir` when set
#       "every": "weekly",                    hourly | daily | weekly | <N>m | <N>h | <N>d (default daily)
#       "size": "short",                      short | long (default short)
#       "when": "1-6",                        preferred local hours, inclusive, "22-2" wraps, "1-3,5";
#                                             "off" = the hours the person does not work (learned);
#                                             default: "off" for a long job, any hour for a short one
#       "priority": 0,                        higher goes first (default 0)
#       "config_dir": "~/.claude",            the account it spends (default: crew.sh account)
#       "retry": "1h"                         after a failed run, wait this long (default 1h)
#   }}}
#
# A tick: (1) a job is due when `every` has passed since its last done run (or it never ran);
# (2) it is in its window when the hour matches `when`, or it has none, or it is overdue by a full
# interval more; (3) the due ones are ordered by priority, then by how overdue; (4) the first that
# fits the budget starts, and nothing else does while one runs (one job at a time per box). Fits:
#   - both windows under the line (`hold.sh mark` on the job's account: budget.sh check, and the
#     flag that stops a running job at the line is written). That line already lets a short job
#     use the leftover of a 5-hour window just before its reset, and only while the 7-day window is
#     under its own line: the weekly reserve gates the fill.
#   - a long job also needs a fresh 5-hour window: none running, or at least
#     crew.queue.long_window_left_min (default 240) minutes of it left, so a long run started near a
#     reset does not spill into the window the person is about to use. Being overdue does not lift
#     this.
#
# The job's contract. It runs with CLAUDE_CONFIG_DIR set to the account the tick measured, and
# HI_HOLD_HOOK holding the PreToolUse hook line its `claude` takes in --settings (`hold.sh hook
# --worker`), so the budget line stops it mid-run too. Exit 0 = done (the interval restarts);
# 75 = not done, try again at the next tick (a lock elsewhere, a stop at the line, its own gate);
# anything else = failed, retried after `retry`.
#
# Off-hours: the person's own prompts in the Claude Code transcripts of the last 28 days
# (<config dir>/projects/**/*.jsonl of ~/.claude and every job's account), counted per local hour;
# an hour with under a tenth of the busiest hour's count is off. Machine-typed prompts (dispatch
# briefs, resumes, continuations) are not counted. With fewer than 100 prompts nothing is learned
# and the default 1-6 is used. crew.queue.off_hours (same syntax as `when`) overrides it.
#
# RUNS: $STATE/jobs/runs.tsv, one line per finished run: name, start, end (epoch), exit code, then
# the 5-hour and 7-day used % before and after. A window that reset during the run reads "-" for
# after. The deltas include the person's own use at the time, so they are an upper bound.
#
# State: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/jobs: <name>.json (last
# done, last failure, running pid), <name>.log (the job's output), jobs.log (each start and end),
# hours.tsv (the learned hours, with the day they were learned).
# Fixtures: HI_NOW (epoch), HI_ACCOUNT (the default account), HI_JOBS_PROJECTS (the transcript
# dirs to learn from, colon-separated), HI_JOBS_FOREGROUND=1 (run the job inline, for tests), and
# budget.sh's. bash 3.2, BSD tools.
set -u
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
STATE="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}"
J="$STATE/jobs"
TEMPFAIL=75

die() { printf 'jobs: %s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die 'jq is required'

now() { printf '%s' "${HI_NOW:-$(date +%s)}"; }
log() { mkdir -p "$J" 2>/dev/null && printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$J/jobs.log" 2>/dev/null; :; }
user_file() { printf '%s\n' "${HIGHNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/highness/config.json}"; }
cfg() { bash "$CONFIG" get --user "$1" 2>/dev/null; }
jobs_json() { bash "$CONFIG" get --user '.crew.jobs' 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null || echo '{}'; }
tilde() { case "$1" in ("~") printf '%s' "$HOME" ;; ("~/"*) printf '%s' "$HOME${1#\~}" ;; (*) printf '%s' "$1" ;; esac; }
# Local hour of an epoch, 0-23, through jq (no GNU date -d / BSD date -r split).
hour_of() { jq -n --argjson t "$1" '$t | strflocaltime("%H") | tonumber'; }

# seconds <spec> <default seconds>
seconds() {
  case "$1" in
    hourly) echo 3600 ;; daily) echo 86400 ;; weekly) echo 604800 ;;
    *[0-9]m) n=${1%m}; case "$n" in ''|*[!0-9]*) echo "$2" ;; *) echo $((n * 60)) ;; esac ;;
    *[0-9]h) n=${1%h}; case "$n" in ''|*[!0-9]*) echo "$2" ;; *) echo $((n * 3600)) ;; esac ;;
    *[0-9]d) n=${1%d}; case "$n" in ''|*[!0-9]*) echo "$2" ;; *) echo $((n * 86400)) ;; esac ;;
    *) echo "$2" ;;
  esac
}

# in_hours <hour> <spec: "1-6", "22-2", "1-3,5">; exit 0 when the hour is in it.
in_hours() {
  printf '%s\n' "$2" | tr ',' '\n' | awk -v h="$1" '
    { gsub(/ /, "") } $0 == "" { next }
    /^[0-9]+-[0-9]+$/ { split($0, r, "-"); lo = r[1] + 0; hi = r[2] + 0
      if ((lo <= hi && h >= lo && h <= hi) || (lo > hi && (h >= lo || h <= hi))) { f = 1 } next }
    /^[0-9]+$/ { if ($0 + 0 == h) f = 1 }
    END { exit !f }'
}

# ── learned hours ────────────────────────────────────────────────────────────

# The transcript dirs: HI_JOBS_PROJECTS, else ~/.claude/projects and every job's account's, each once.
project_dirs() {
  if [ -n "${HI_JOBS_PROJECTS:-}" ]; then printf '%s\n' "$HI_JOBS_PROJECTS" | tr ':' '\n'; return; fi
  {
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" "$HOME/.claude/projects"
    jobs_json | jq -r '.[] | .config_dir // empty' | while IFS= read -r d; do printf '%s\n' "$(tilde "$d")/projects"; done
  } | while IFS= read -r d; do [ -d "$d" ] && (cd -P "$d" && pwd -P); done | awk 'NF && !seen[$0]++'
}

# Prompt counts per local hour, "hour<TAB>count", from the transcripts of the last 28 days.
hour_counts() {
  project_dirs | while IFS= read -r d; do
    find "$d" -name '*.jsonl' -mtime -28 -type f -exec grep -h '"type":"user"' {} + 2>/dev/null
  done | jq -r '
    def machine: test("^(<|Caveat: The messages below|This session is being continued|You hit the usage limit|Please carry out this task from|You have [0-9]+ (new )?orchestration|Your task ID is|You are working inside Orca|=== TASK ===|The plan budget is back)");
    select(.type == "user" and (.isMeta | not) and ((.entrypoint // "cli") == "cli")
      and (.message.content | type) == "string" and ((.message.content | machine) | not)
      and (.timestamp | type) == "string")
    | .timestamp | sub("\\.[0-9]+"; "") | fromdateiso8601 | strflocaltime("%H") | tonumber' 2>/dev/null \
    | sort -n | uniq -c | awk '{ print $2 "\t" $1 }'
}

# The work hours, "h,h,…" (empty when too little is known), cached in hours.tsv for a day.
cmd_hours() {
  local day c
  day=$(jq -n --argjson t "$(now)" '$t | strflocaltime("%Y-%m-%d")')
  if [ -f "$J/hours.tsv" ] && [ "$(head -1 "$J/hours.tsv" | cut -f1)" = "$day" ]; then
    head -1 "$J/hours.tsv" | cut -f2; return 0
  fi
  c=$(hour_counts | awk -F'\t' '{ n[$1] = $2; t += $2; if ($2 > m) m = $2 }
    END { if (t < 100) exit; s = ""; for (h = 0; h < 24; h++) if (n[h] >= m / 10) s = s (s == "" ? "" : ",") h; print s }')
  mkdir -p "$J" && printf '%s\t%s\n' "$day" "$c" >"$J/hours.tsv"
  printf '%s\n' "$c"
}

# The off-hours spec: crew.queue.off_hours, else every hour not learned as work, else 1-6.
off_hours() {
  local o w
  o=$(cfg '.crew.queue.off_hours') && [ -n "$o" ] && { printf '%s\n' "$o"; return; }
  w=$(cmd_hours)
  [ -n "$w" ] || { echo 1-6; return; }
  awk -v w="$w" 'BEGIN { n = split(w, a, ","); for (i = 1; i <= n; i++) on[a[i] + 0] = 1
    s = ""; for (h = 0; h < 24; h++) if (!on[h]) s = s (s == "" ? "" : ",") h; print (s == "" ? "-1" : s) }'
}

# ── state ────────────────────────────────────────────────────────────────────

st() { jq -r "$2 // empty" "$J/$1.json" 2>/dev/null; }
st_set() { # <name> <jq update>
  local f="$J/$1.json" tmp
  mkdir -p "$J"; [ -f "$f" ] || echo '{}' >"$f"
  tmp="$f.tmp.$$"
  jq -c "$2" "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
}
# running <name>: its recorded pid is alive.
running() { local p; p=$(st "$1" .pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# load <name>: the job's fields into JEVERY (seconds) JSIZE JWHEN JPRIO JACCT JRETRY (seconds) JRUN
# JDIR; exit 1 when no such job. One jq per field: an empty field must not shift the others.
load() {
  local j
  j=$(jobs_json | jq -c --arg n "$1" '.[$n] // empty | select(type == "object")')
  [ -n "$j" ] || return 1
  JEVERY=$(seconds "$(printf '%s' "$j" | jq -r '.every // "daily"')" 86400)
  JSIZE=$(printf '%s' "$j" | jq -r 'if .size == "long" then "long" else "short" end')
  JWHEN=$(printf '%s' "$j" | jq -r '.when // "" | tostring')
  JPRIO=$(printf '%s' "$j" | jq -r '.priority // 0 | if type == "number" then floor else 0 end')
  JACCT=$(printf '%s' "$j" | jq -r '.config_dir // ""')
  JRETRY=$(seconds "$(printf '%s' "$j" | jq -r '.retry // "1h"')" 3600)
  JRUN=$(printf '%s' "$j" | jq -r '.run // "" | tostring')
  JDIR=$(printf '%s' "$j" | jq -r '.dir // ""')
}

# due_at <name> (after load): when it is due, epoch; 0 = never ran.
due_at() {
  local last fail due
  last=$(st "$1" .last_ok); fail=$(st "$1" .failed_at)
  if [ -n "$last" ]; then due=$((last + JEVERY)); else due=0; fi
  if [ -n "$fail" ] && [ $((fail + JRETRY)) -gt "$due" ]; then due=$((fail + JRETRY)); fi
  printf '%s\n' "$due"
}

account() { local d=$1; [ -n "$d" ] || d=${HI_ACCOUNT:-$(bash "$HERE/crew.sh" account 2>/dev/null)}; tilde "${d%/}"; }

# used % per window for runs.tsv: "5h<TAB>reset5<TAB>7d<TAB>reset7", "-" for each unknown.
usage() {
  bash "$HERE/budget.sh" show "$1" 2>/dev/null | awk -F'\t' '
    $1 == "five_hour" { u5 = $2; r5 = $4 } $1 == "seven_day" { u7 = $2; r7 = $4 }
    END { printf "%s\t%s\t%s\t%s\n", (u5 == "" ? "-" : u5), (r5 == "" ? "-" : r5), (u7 == "" ? "-" : u7), (r7 == "" ? "-" : r7) }'
}

# ── the run (the detached part) ──────────────────────────────────────────────

cmd_exec() { # <name> <config dir>
  local name=$1 d=$2 rc start end b a b5 r5 b7 r7 a5 ar5 a7 ar7 T
  T=$(printf '\t')
  load "$name" || return 2
  start=$(now); b=$(usage "$d")
  IFS=$T read -r b5 r5 b7 r7 <<EOF
$b
EOF
  log "start	$name	$d"
  rc=0
  (
    [ -z "$JDIR" ] || cd "$(tilde "$JDIR")" || exit 2
    CLAUDE_CONFIG_DIR="$d" HI_HOLD_HOOK="bash $(printf '%q' "$HERE/hold.sh") hook --worker" HI_JOB="$name" \
      exec bash -c "$JRUN" </dev/null
  ) >>"$J/$name.log" 2>&1 || rc=$?
  end=$(now); a=$(usage "$d")
  IFS=$T read -r a5 ar5 a7 ar7 <<EOF
$a
EOF
  # A window that reset during the run says nothing about the run: its after reads "-".
  [ "$ar5" = "$r5" ] || a5=-; [ "$ar7" = "$r7" ] || a7=-
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$start" "$end" "$rc" "$b5" "$a5" "$b7" "$a7" >>"$J/runs.tsv"
  case "$rc" in
    0) st_set "$name" ".last_ok = $end | del(.pid, .failed_at, .rc)" ;;
    "$TEMPFAIL") st_set "$name" ".last_try = $end | del(.pid)" ;;
    *) st_set "$name" ".failed_at = $end | .rc = $rc | del(.pid)" ;;
  esac
  log "end	$name	rc=$rc"
  return 0
}

start() { # <name> <config dir>
  mkdir -p "$J"
  if [ "${HI_JOBS_FOREGROUND:-}" = 1 ]; then
    st_set "$1" ".started = $(now) | .pid = $$"; cmd_exec "$1" "$2"; return
  fi
  # Detached, in its own session where setsid exists: the watch runs inside a precheck with a
  # timeout, and a long job outlives it.
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$HERE/jobs.sh" exec "$1" "$2" </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$HERE/jobs.sh" exec "$1" "$2" </dev/null >/dev/null 2>&1 &
  fi
  st_set "$1" ".started = $(now) | .pid = $!"
}

# ── the tick ─────────────────────────────────────────────────────────────────

names() { jobs_json | jq -r 'keys[] | select(test("^[A-Za-z0-9_.-]+$"))'; }

# budget_ok <config dir>: hold.sh mark, once per account per tick (budget.sh check, and the flag
# that stops a running job at the line).
CHECKED=''
budget_ok() {
  case "$CHECKED" in *"|$1=go|"*) return 0 ;; *"|$1=hold|"*) return 1 ;; esac
  if bash "$HERE/hold.sh" mark "$1" >/dev/null 2>&1; then CHECKED="$CHECKED|$1=go|"; return 0; fi
  CHECKED="$CHECKED|$1=hold|"; return 1
}

# Minutes left in the 5-hour window, or "fresh" when none runs; empty when unknown.
window_left() { # <config dir> <now>
  bash "$HERE/budget.sh" show "$1" 2>/dev/null | awk -F'\t' -v now="$2" '$1 == "five_hour" {
    if ($4 == "-" || $4 <= now) print "fresh"; else print int(($4 - now) / 60) }'
}

cmd_tick() {
  local dry='' e n h d due late when rows lwl left T lock="$J/tick.lock" prio
  T=$(printf '\t')
  [ "${1:-}" = --dry-run ] && dry=1
  [ -n "$(names)" ] || return 0
  mkdir -p "$J"
  if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || return 0
    rm -rf "$lock"; mkdir "$lock" || return 0
  fi
  trap "rmdir '$lock' 2>/dev/null" EXIT
  n=$(now); h=$(hour_of "$n")
  # One job at a time: while one runs, keep its account's flag fresh (the hook stops it at the
  # line) and start nothing.
  for e in $(names); do
    running "$e" || continue
    load "$e" || continue
    d=$(account "$JACCT")
    if budget_ok "$d"; then printf '%s\trunning\ton %s\n' "$e" "$d"; else printf '%s\trunning\ton %s, over the budget line: its hook stops it\n' "$e" "$d"; fi
    return 0
  done
  # The due ones in their hours, as priority<TAB>lateness<TAB>name; the others say why they wait.
  rows=''
  for e in $(names); do
    load "$e" || continue
    [ -n "$JRUN" ] || { printf '%s\tskip\tno run command\n' "$e"; continue; }
    due=$(due_at "$e")
    [ "$n" -ge "$due" ] || { printf '%s\twait\tnot due for %s min\n' "$e" $(( (due - n + 59) / 60 )); continue; }
    late=$((n - due)); [ "$due" -gt 0 ] || late=0  # never ran: due, not overdue
    when=$JWHEN; [ -n "$when" ] || { [ "$JSIZE" = long ] && when=off; }
    [ "$when" = off ] && when=$(off_hours)
    if [ -n "$when" ] && ! in_hours "$h" "$when" && [ "$late" -lt "$JEVERY" ]; then
      printf '%s\twait\tdue, outside its hours (%s)\n' "$e" "$when"; continue
    fi
    rows="$rows$JPRIO$T$late$T$e
"
  done
  rows=$(printf '%s' "$rows" | sort -t "$T" -k1,1nr -k2,2nr)
  lwl=$(cfg '.crew.queue.long_window_left_min'); case "$lwl" in ''|*[!0-9]*) lwl=240 ;; esac
  while IFS=$T read -r prio late e; do
    [ -n "$e" ] || continue
    load "$e" || continue
    d=$(account "$JACCT")
    budget_ok "$d" || { printf '%s\twait\tdue, over the budget line on %s\n' "$e" "$d"; continue; }
    if [ "$JSIZE" = long ]; then
      left=$(window_left "$d" "$n")
      if [ "$left" != fresh ] && { [ -z "$left" ] || [ "$left" -lt "$lwl" ]; }; then
        printf '%s\twait\tlong: the 5-hour window has %s min left, a start needs %s\n' "$e" "${left:-?}" "$lwl"; continue
      fi
    fi
    if [ -n "$dry" ]; then printf '%s\twould start\ton %s\n' "$e" "$d"; return 0; fi
    start "$e" "$d"
    printf '%s\tstarted\ton %s\n' "$e" "$d"
    return 0
  done <<EOF
$rows
EOF
  return 0
}

# ── the list and the person's file ───────────────────────────────────────────

cmd_list() {
  local e last fail due state sp
  for e in $(names); do
    load "$e" || continue
    last=$(st "$e" .last_ok); fail=$(st "$e" .failed_at); due=$(due_at "$e")
    state=waiting; [ "$(now)" -ge "$due" ] && state=due
    [ -z "$fail" ] || state="$state, failed"
    running "$e" && state=running
    sp=$(awk -F'\t' -v n="$e" '$1 == n && $7 != "-" && $8 != "-" { s = $8 - $7 } END { if (s == "") print "-"; else printf "%g\n", s }' "$J/runs.tsv" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$e" "$state" "${last:--}" "$due" "$JSIZE" "$JPRIO" "${sp:--}"
  done
}

cmd_add() { # <name> <json>
  local u tmp
  [ $# -eq 2 ] || die 'usage: jobs.sh add <name> <json>'
  case "$1" in ''|*[!A-Za-z0-9_.-]*) die "a job name is letters, digits, . _ -: $1" ;; esac
  printf '%s' "$2" | jq -e 'type == "object" and (.run | type) == "string" and .run != ""' >/dev/null 2>&1 \
    || die 'a job is a JSON object with a "run" command'
  u=$(user_file); mkdir -p "$(dirname "$u")"; [ -s "$u" ] || echo '{}' >"$u"
  tmp="$u.tmp.$$"
  jq --arg n "$1" --argjson j "$2" '.crew.jobs[$n] = $j' "$u" >"$tmp" && mv "$tmp" "$u" || { rm -f "$tmp"; die "could not write $u"; }
  echo "added: $1"
}

cmd_remove() {
  local u tmp
  [ $# -eq 1 ] || die 'usage: jobs.sh remove <name>'
  u=$(user_file); [ -f "$u" ] || return 0
  tmp="$u.tmp.$$"
  jq --arg n "$1" 'if .crew.jobs then .crew.jobs |= del(.[$n]) else . end' "$u" >"$tmp" && mv "$tmp" "$u" || rm -f "$tmp"
  echo "removed: $1"
}

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  tick) cmd_tick "$@" ;;
  list) cmd_list ;;
  add) cmd_add "$@" ;;
  remove) cmd_remove "$@" ;;
  hours) cmd_hours ;;
  runs) cat "$J/runs.tsv" 2>/dev/null; : ;;
  exec) cmd_exec "$@" ;;
  *) die 'usage: jobs.sh tick [--dry-run] | list | add <name> <json> | remove <name> | hours | runs' ;;
esac
