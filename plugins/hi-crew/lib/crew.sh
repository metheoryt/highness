#!/usr/bin/env bash
# crew.sh — hi-crew's facts about the ticket workers it started, and what they wait on.
#
# Facts, not status: one JSON file per ticket under the state dir, written when a worker starts
# and as things become known (PR url, ...). Status ("waiting on you", "ready to merge") is derived
# when the digest reads them, from these facts plus Orca and the forge.
#
#   crew.sh dir                       the state dir
#   crew.sh record <KEY> <json>       merge a JSON object into <KEY>'s facts (creates them)
#   crew.sh get <KEY>                 <KEY>'s facts; exit 1 when there are none
#   crew.sh list                      one JSON object per line, every open ticket
#   crew.sh close <KEY>               move <KEY>'s facts to closed/ (the ticket is settled)
#   crew.sh run                       this session's hi-crew Orca Run: the Run Orca has bound to
#                                     this terminal, when it is one hi-crew made (exit 1: none)
#   crew.sh run <run_id>              register a Run hi-crew made
#   crew.sh runs                      the Runs of the open tickets, one per line. Each coordinator
#                                     session has its own Run, so Orca wakes each for its own
#                                     workers; the digest reads them all
#   crew.sh asks                      what blocks a worker in those Runs, TSV: message id, type
#                                     (question | decision_gate | escalation), run id, dispatch id,
#                                     created_at, first line. A question or gate is open while no
#                                     message carries its id as thread_id and its dispatch is live
#                                     (Orca closes the question of a settled or stopped worker); an
#                                     escalation, while its dispatch has sent no later worker_done.
#   crew.sh reports                   the latest worker_done per dispatch in those Runs, TSV:
#                                     run id, dispatch id, created_at, outcome, subject
#   crew.sh spec --key K --title T [--brief-file F]
#                                     the worker spec for a ticket, from reference/worker-spec.md and
#                                     the config keys crew.process and crew.marker. In crew.process,
#                                     {{ROOT}} becomes the git root of the coordinator's working
#                                     directory: a worker runs in another tree, so the team's files
#                                     must be named by absolute path
#   crew.sh watch                     look at the PR of every open ticket and, when something a
#                                     person should see changed since the last look (merged or
#                                     closed, CI failed, new comments from people), append it to the
#                                     watch events and wake the ticket's coordinator with a status
#                                     message to its Run. The first look at a ticket only records it.
#                                     Run by the Orca automation below, from its precheck, which then
#                                     exits 1 so no agent ever starts
#   crew.sh watch-install [<cron>]    create or update that automation (default every 10 minutes)
#   crew.sh autostart [--dry-run]     start ready tickets that carry the opt-in label into free
#                                     slots, under a coordinator's Run (the watch runs it last; off
#                                     unless crew.autostart.enabled, see "autostart" below).
#                                     --dry-run writes nothing: the slots, then would-start lines
#   crew.sh usage [<config dir>]      the plan usage autostart checks, TSV: window, used percent;
#                                     nothing when unknown
#   crew.sh usage-save                read Claude Code's statusline JSON on stdin and keep its
#                                     rate_limits in <config dir>/highness-usage.json for `usage`
#                                     (call it from your statusline command)
#   crew.sh events [--ack]            watch events no one has seen, TSV: time, key, run, pr, what;
#                                     --ack marks them seen
#   crew.sh prompts                   the open tickets whose worker sits on a permission dialog, an
#                                     MCP server's input dialog or a question form, TSV: key, run,
#                                     since, tool, kind (permission | input | question). The plugin's
#                                     Notification hook marks a session on a dialog (prompt-mark.sh);
#                                     its other hooks keep each session's state (session-state.sh),
#                                     which adds the question forms (AskUserQuestion, ExitPlanMode).
#                                     A worker's session is the one whose cwd is in the ticket's
#                                     `workspace`. The watch wakes the coordinator once per dialog
#   crew.sh states                    what each open ticket's worker is doing, from its own hooks,
#                                     TSV: key, run, state (working | blocked | idle | unknown),
#                                     since, kind, open tool, minutes that tool call has run, minutes
#                                     the turn has run. `unknown`: no hook line to believe (a session
#                                     started before hi-crew was enabled, another agent, two
#                                     sessions in one workspace). A tool call open longer than
#                                     HI_TOOL_STUCK minutes (default 30) is told by the watch once:
#                                     a hung shell keeps a session "working", and only its age shows
#   crew.sh sections                  the team's own digest sections (config agenda.sections), one
#                                     JSON object per line: section, group (you | others | done),
#                                     title, next, url, since; or section and error. See cmd_sections
#   crew.sh orca                      the Orca executable this host should use
#   crew.sh setup-status              what hi-crew needs on this machine and from this person, one
#                                     row per item, name<TAB>state<TAB>detail (/hi:setup renders them):
#                                       orchestration  on | off            Orca's orchestration CLI answers
#                                       orca-skill     ok | missing        Orca's orchestration skill installed
#                                       watch          ok | stale | disabled | missing | unknown
#                                       crew.agent     set | default | unset   (default: set to null on purpose)
#                                       crew.model     set | default | unset
#
# PR state comes from the config key crew.pr_state, read at the ticket's `root` (the coordinator's
# git root, recorded at start): a command that prints one JSON object for a PR,
#   {"state": "open|merged|closed", "draft": bool, "head": sha, "ci": "success|failure|pending|",
#    "people": <count of comments by people>, "people_at": <latest time one was written or edited>}
# with {{PR}}, {{ROOT}} and {{MARKER}} replaced by the shell-quoted PR url, root and crew.marker.
# A comment is a person's when it is not the review bot's and not the workers' own: it does not
# start with the marker, or with the marker extended inside its brackets ("(agent, ...) ..."). Unset, a
# github.com PR is read with gh. The command runs from an automation, outside any terminal, so
# it must find its own credentials; the precheck runs it in a login interactive shell.
#
# State dir: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/crew
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
TEMPLATE="$HERE/../reference/worker-spec.md"
DIR="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/crew"

die() { printf 'crew: %s\n' "$*" >&2; exit 2; }
need_jq() { command -v jq >/dev/null 2>&1 || die 'jq is required'; }

# A ticket key becomes a file name: letters, digits, dash, underscore, dot only.
keyfile() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*) die "bad ticket key: '$1'" ;;
  esac
  printf '%s/%s.json\n' "$DIR" "$1"
}

# Same rule as the orchestration skill: ORCA_CLI_COMMAND, then orca-ide on Linux outside an Orca
# terminal (bare `orca` there is the GNOME screen reader), else orca.
orca_cmd() {
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then printf '%s\n' "$ORCA_CLI_COMMAND"; return; fi
  if [ "$(uname -s)" = Linux ] && [ -z "${ORCA_TERMINAL_HANDLE:-}" ]; then echo orca-ide; return; fi
  echo orca
}

cmd_record() {
  [ $# -eq 2 ] || die 'usage: record <KEY> <json>'
  need_jq
  local f tmp now
  f=$(keyfile "$1") || exit 2
  printf '%s' "$2" | jq -e 'type == "object"' >/dev/null 2>&1 || die 'record: the second argument must be a JSON object'
  mkdir -p "$DIR"
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  tmp="$f.tmp.$$"
  if [ -f "$f" ]; then
    jq --argjson add "$2" --arg now "$now" '. + $add + {updated_at: $now}' "$f" >"$tmp"
  else
    jq -n --argjson add "$2" --arg key "$1" --arg now "$now" '{key: $key, created_at: $now} + $add + {updated_at: $now}' >"$tmp"
  fi && mv "$tmp" "$f" || { rm -f "$tmp"; die "record: could not write $f"; }
}

cmd_get() {
  [ $# -eq 1 ] || die 'usage: get <KEY>'
  local f; f=$(keyfile "$1") || exit 2
  [ -f "$f" ] || return 1
  cat "$f"
}

cmd_list() {
  need_jq
  local f
  for f in "$DIR"/*.json; do
    [ -f "$f" ] && jq -c . "$f"
  done
  return 0
}

cmd_close() {
  [ $# -eq 1 ] || die 'usage: close <KEY>'
  local f; f=$(keyfile "$1") || exit 2
  [ -f "$f" ] || die "no open facts for $1"
  mkdir -p "$DIR/closed"
  mv "$f" "$DIR/closed/$1.$(date -u +%Y%m%dT%H%M%SZ).json"
}

# $DIR/run lists every Run hi-crew made, one per line (it once held a single shared Run).
# The watch has no terminal of its own, and Orca sends only from one; it sends from the terminal
# of the Run's coordinator, kept fresh in $DIR/handles/<run> each time the coordinator asks for its
# Run here.
keep_handle() {
  [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || return 0
  mkdir -p "$DIR/handles" && printf '%s\n' "$ORCA_TERMINAL_HANDLE" >"$DIR/handles/$1"
}

cmd_run() {
  if [ $# -eq 1 ]; then
    case "$1" in run_*) ;; *) die "not a Run id: '$1'" ;; esac
    mkdir -p "$DIR"
    grep -qxF "$1" "$DIR/run" 2>/dev/null || printf '%s\n' "$1" >>"$DIR/run"
    keep_handle "$1"
    return
  fi
  need_jq
  local cur
  cur=$("$(orca_cmd)" orchestration run-current --json 2>/dev/null | jq -r '.result.runId // empty') || return 1
  [ -n "$cur" ] && grep -qxF "$cur" "$DIR/run" 2>/dev/null || return 1
  keep_handle "$cur"
  printf '%s\n' "$cur"
}

cmd_runs() {
  need_jq
  cmd_list | jq -r '.run // empty' | sort -u
}

inbox() {
  local runs
  runs=$(cmd_runs | jq -Rsc 'split("\n") | map(select(. != ""))')
  [ "$runs" != '[]' ] || { echo '[]'; return; }
  "$(orca_cmd)" orchestration inbox --limit 500 --json --full 2>/dev/null \
    | jq -c --argjson runs "$runs" '(.result.messages // []) | map(select(.run_id as $r | $runs | index($r)))
        | map(. + {dispatch: ((.payload // "{}" | fromjson? // {}) .dispatchId // "")})'
}

cmd_asks() {
  need_jq
  local m; m=$(inbox) || exit $?
  printf '%s' "$m" | jq -r '
    . as $m
    | [ $m[] | select(.thread_id != null and .thread_id != .id) | .thread_id ] as $answered
    | $m[]
    | select(.type == "question" or .type == "decision_gate" or .type == "escalation")
    | select(.id as $id | $answered | index($id) | not)
    | select(.type != "escalation" or
        (. as $e | [ $m[] | select(.type == "worker_done" and .dispatch == $e.dispatch
                                   and .created_at > $e.created_at) ] | length == 0))
    | [ .id, .type, .run_id, .dispatch, .created_at, ((.body // .subject // "") | split("\n")[0]) ] | @tsv' \
    | while IFS=$'\t' read -r id type rest; do
        d=$(printf '%s' "$rest" | cut -f2)
        case "$type" in question|decision_gate) dispatch_live "$d" || continue ;; esac
        printf '%s\t%s\t%s\n' "$id" "$type" "$rest"
      done
}

# Whether a worker Dispatch can still take an answer. Orca closes a question whose Dispatch is
# inactive (reply: dispatch_inactive), so asks drops it: a settled, stopped or vanished worker
# asks nothing any more. A Dispatch Orca cannot be asked about (no id, an error other than
# not-found) counts as live, so a question is never hidden on a guess.
dispatch_live() {
  [ -n "$1" ] || return 0
  local out
  out=$("$(orca_cmd)" orchestration worker-show --dispatch "$1" --json 2>/dev/null)
  printf '%s' "$out" | jq -e '
    if .ok == false then (.error.code // "") != "dispatch_not_found"
    else (.result.stage // "") as $s | (.result.state // "") as $t
      | ($s | test("^(settled|terminal_missing)$") | not)
        and ($t | test("^(succeeded|failed|cancelled|canceled|abandoned|stopped)$") | not)
    end' >/dev/null 2>&1
  [ $? -ne 1 ]   # 1 is jq's false; no output or unreadable JSON leaves it live
}

cmd_reports() {
  need_jq
  local m; m=$(inbox) || exit $?
  printf '%s' "$m" | jq -r '
    [ .[] | select(.type == "worker_done") ] | group_by(.dispatch)[] | max_by(.created_at)
    | [ .run_id, .dispatch, .created_at, ((.payload // "{}" | fromjson? // {}) .outcome // ""), (.subject // "") ] | @tsv'
}

cmd_spec() {
  local key='' title='' brief_file='' brief='' process marker root
  while [ $# -gt 0 ]; do
    case "$1" in
      --key) key=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --brief-file) brief_file=${2:-}; shift 2 ;;
      *) die "spec: unknown argument '$1'" ;;
    esac
  done
  [ -n "$key" ] && [ -n "$title" ] || die 'usage: spec --key K --title T [--brief-file F]'
  keyfile "$key" >/dev/null || exit 2
  [ -f "$TEMPLATE" ] || die "missing $TEMPLATE"
  if [ -n "$brief_file" ]; then
    [ -f "$brief_file" ] || die "no brief file: $brief_file"
    brief=$(cat "$brief_file")
  fi
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$(pwd)
  process=$(bash "$CONFIG" get '.crew.process') || process='(none configured: use the tracker and forge tools you have, and say in the PR how you checked the work)'
  marker=$(bash "$CONFIG" get '.crew.marker') || marker='(agent)'
  # Placeholders are replaced in a fixed order by awk with literal strings (no regex, no &).
  KEY=$key TITLE=$title BRIEF=$brief PROCESS=$process MARKER=$marker ROOT=$root awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { line = $0
      line = rep(line, "{{KEY}}", ENVIRON["KEY"])
      line = rep(line, "{{TITLE}}", ENVIRON["TITLE"])
      line = rep(line, "{{MARKER}}", ENVIRON["MARKER"])
      if (line == "{{BRIEF}}") { print ENVIRON["BRIEF"]; next }
      if (line == "{{PROCESS}}") { print rep(ENVIRON["PROCESS"], "{{ROOT}}", ENVIRON["ROOT"]); next }
      print line }' "$TEMPLATE"
}

# One shell word: 'it''s' -> 'it'\''s'.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The PR state of a github.com PR when the team set no crew.pr_state.
gh_state() {
  gh pr view "$1" --json state,isDraft,headRefOid,statusCheckRollup,comments,reviews 2>/dev/null \
    | jq -c --arg m "$2" '
      def mine: (.author.login // "" | test("\\[bot\\]$|^github-actions$"))
        or ((.body // "") as $b | ($b | startswith($m))
            or (($m | endswith(")")) and ($b | startswith(($m | rtrimstr(")")) + ","))));
      { state: (.state | ascii_downcase), draft: .isDraft, head: .headRefOid,
        ci: ([.statusCheckRollup[]? | (.conclusion // .state // "" | ascii_upcase)] as $c
             | if ($c | length) == 0 then ""
               elif any($c[]; . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT") then "failure"
               elif all($c[]; . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "success"
               else "pending" end),
        people_at: ([.comments[]?, (.reviews[]? | select((.body // "") != "" and .state != "PENDING"))] | map(select(mine | not))
                    | map(.updatedAt // .submittedAt // .createdAt // "") | max // ""),
        people: ([.comments[]?, (.reviews[]? | select((.body // "") != "" and .state != "PENDING"))] | map(select(mine | not)) | length) }'
}

# What a person should hear about, between two PR states.
changes() {
  jq -rn --argjson a "$1" --argjson b "$2" '
    if ($b.state // "") != ($a.state // "") and (($b.state // "") | test("^(merged|closed)$"))
      then "PR \($b.state)" else empty end,
    if ($b.ci // "") != ($a.ci // "") and ($b.ci // "") == "failure"
      then "CI failed on \(($b.head // "")[0:8])" else empty end,
    if ($b.people // 0) > ($a.people // 0)
      then "\(($b.people // 0) - ($a.people // 0)) new comment(s) from people"
    elif ($a | has("people_at")) and ($b.people_at // "") > $a.people_at
      then "a comment from people was written or edited" else empty end'
}

pr_state() { # <facts json>
  local pr root cmd marker line
  pr=$(printf '%s' "$1" | jq -r '.pr // empty')
  root=$(printf '%s' "$1" | jq -r '.root // empty')
  [ -n "$root" ] && [ -d "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  cmd=$(cd "$root" && bash "$CONFIG" get '.crew.pr_state') || cmd=''
  marker=$(cd "$root" && bash "$CONFIG" get '.crew.marker') || marker='(agent)'
  if [ -z "$cmd" ]; then
    case "$pr" in https://github.com/*) gh_state "$pr" "$marker"; return ;; *) return 1 ;; esac
  fi
  line=$(PR=$(q "$pr") ROOT=$(q "$root") MARKER=$(q "$marker") fill <<<"$cmd")
  (cd "$root" && sh -c "$line") 2>/dev/null
}

# stdin with {{PR}}, {{ROOT}} and {{MARKER}} replaced by $PR, $ROOT and $MARKER (each may be unset).
fill() {
  awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { print rep(rep(rep($0, "{{PR}}", ENVIRON["PR"]), "{{ROOT}}", ENVIRON["ROOT"]), "{{MARKER}}", ENVIRON["MARKER"]) }'
}

# The team's own digest sections (config agenda.sections), so the digest covers more than the
# workers without hi knowing the team's tracker or forge. Each section is {"name", "command"}; the
# command runs from this git root with {{ROOT}} and {{MARKER}} filled in, and prints one JSON object
# per line: {"group": "you|others|done", "title", "next", "url", "since"} (all but title optional).
# Out: the same objects with "section" added; other lines are skipped. A section whose command fails
# gives one line with "error" set instead, so a broken source shows rather than vanishes.
cmd_sections() {
  need_jq
  local root secs n i name cmd line out rc
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  secs=$(cd "$root" && bash "$CONFIG" get '.agenda.sections') || secs=''
  [ -n "$secs" ] && [ "$secs" != null ] || return 0
  n=$(printf '%s' "$secs" | jq 'if type == "array" then length else 0 end' 2>/dev/null) || n=0
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    name=$(printf '%s' "$secs" | jq -r ".[$i].name // \"section $i\"")
    cmd=$(printf '%s' "$secs" | jq -r ".[$i].command // empty")
    i=$((i + 1))
    [ -n "$cmd" ] || continue
    line=$(ROOT=$(q "$root") MARKER=$(q "$(cd "$root" && bash "$CONFIG" get '.crew.marker' 2>/dev/null || echo '(agent)')") fill <<<"$cmd")
    out=$(cd "$root" && sh -c "$line" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      jq -cn --arg s "$name" --arg e "$(printf '%s' "$out" | tail -1)" --argjson rc "$rc" \
        '{section: $s, error: "exit \($rc): \($e)"}'
      continue
    fi
    printf '%s\n' "$out" | jq -Rc --arg s "$name" 'fromjson? | select(type == "object") | {section: $s} + .'
  done
}

cmd_watch() {
  need_jq
  local w="$DIR/watch" lock="$DIR/watch/lock" t key pr run now snap what hit since tool kind hs
  mkdir -p "$w"
  if ! mkdir "$lock" 2>/dev/null; then
    [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ] || return 0  # another watch runs
    rm -rf "$lock"; mkdir "$lock" || return 0
  fi
  trap "rmdir '$lock' 2>/dev/null" EXIT
  cmd_list | while IFS= read -r t; do
    key=$(printf '%s' "$t" | jq -r .key); pr=$(printf '%s' "$t" | jq -r '.pr // empty')
    run=$(printf '%s' "$t" | jq -r '.run // empty')
    # A dialog is told once: its `since` is kept until the next one.
    if hit=$(on_prompt "$t"); then
      since=$(printf '%s' "$hit" | cut -f1); tool=$(printf '%s' "$hit" | cut -f2); kind=$(printf '%s' "$hit" | cut -f3)
      if [ "$(cat "$w/$key.prompt" 2>/dev/null)" != "$since" ]; then
        printf '%s\n' "$since" >"$w/$key.prompt"
        event "$key" "$run" "${pr:-$(printf '%s' "$t" | jq -r '.workspace')}" \
          "$(case "$kind" in (input) echo 'waits on an MCP input dialog' ;; (question) echo 'waits on a question form' ;;
               (*) echo 'waits on a permission dialog' ;; esac)${tool:+ for $tool}"
      fi
    fi
    # A tool call open too long: told once per call. Stillness never says "hung"; age does.
    if hs=$(hook_state "$t") && [ "$(printf '%s' "$hs" | cut -f1)" = working ]; then
      tool=$(printf '%s' "$hs" | cut -f6); since=$(printf '%s' "$hs" | cut -f7)
      if [ -n "$tool" ] && [ -n "$since" ] && [ $(( $(date +%s) - since )) -ge $(( ${HI_TOOL_STUCK:-30} * 60 )) ] \
         && [ "$(cat "$w/$key.tool" 2>/dev/null)" != "$since" ]; then
        printf '%s\n' "$since" >"$w/$key.tool"
        event "$key" "$run" "${pr:-$(printf '%s' "$t" | jq -r '.workspace')}" \
          "has had one $tool call open for $(( ($(date +%s) - since) / 60 )) min — a hung command?"
      fi
    fi
    [ -n "$pr" ] || continue
    now=$(pr_state "$t") && printf '%s' "$now" | jq -e 'type == "object"' >/dev/null 2>&1 || continue
    snap="$w/$key.json"
    if [ -f "$snap" ]; then
      changes "$(cat "$snap")" "$now" | while IFS= read -r what; do event "$key" "$run" "$pr" "$what"; done
    fi
    printf '%s\n' "$now" >"$snap"
  done
  # Last, with the PR states just read: start labelled tickets into free slots (off by default).
  cmd_autostart >/dev/null 2>&1 || :
}

PROMPT_MARK="$HERE/prompt-mark.sh"

SESSION_STATE="$HERE/session-state.sh"

# The hook line of the worker of these facts (session-state.sh get); exit 1 when none is believed.
hook_state() { # <facts json>
  local ws
  ws=$(printf '%s' "$1" | jq -r '.workspace // empty')
  [ -n "$ws" ] && [ -d "$ws" ] || return 1
  bash "$SESSION_STATE" get "$ws"
}

# since<TAB>tool<TAB>kind when the worker of these facts sits on a dialog; exit 1 otherwise.
# prompt-mark first (it names the tool waiting on a permission); then the hook line, which also
# knows question forms.
on_prompt() { # <facts json>
  local ws hs
  ws=$(printf '%s' "$1" | jq -r '.workspace // empty')
  [ -n "$ws" ] && [ -d "$ws" ] || return 1
  bash "$PROMPT_MARK" check "$ws" && return 0
  hs=$(hook_state "$1") || return 1
  [ "$(printf '%s' "$hs" | cut -f1)" = blocked ] || return 1
  printf '%s\n' "$hs" | awk -F'\t' -v OFS='\t' '{ print $8 "Z", $6, $4 }'
}

cmd_states() {
  need_jq
  local t hs now
  now=$(date +%s)
  cmd_list | while IFS= read -r t; do
    hs=$(hook_state "$t") || hs=''
    printf '%s\t%s\t' "$(printf '%s' "$t" | jq -r .key)" "$(printf '%s' "$t" | jq -r '.run // ""')"
    if [ -z "$hs" ]; then printf 'unknown\t\t\t\t\t\n'; continue; fi
    printf '%s\n' "$hs" | awk -F'\t' -v OFS='\t' -v now="$now" '
      function mins(e) { return e == "" ? "" : int((now - e) / 60) }
      { print $1, $8 "Z", $4, $6, ($6 == "" ? "" : mins($7)), mins($5) }'
  done
  return 0
}

cmd_prompts() {
  need_jq
  local t hit
  cmd_list | while IFS= read -r t; do
    hit=$(on_prompt "$t") || continue
    printf '%s\t%s\t%s\n' "$(printf '%s' "$t" | jq -r .key)" "$(printf '%s' "$t" | jq -r '.run // ""')" "$hit"
  done
  return 0
}

# Append one watch event and wake the ticket's coordinator with it.
event() { # <key> <run> <pr or workspace> <what>
  local w="$DIR/watch" handle
  mkdir -p "$w"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" >>"$w/events"
  handle=$(cat "$DIR/handles/$2" 2>/dev/null) || handle=''
  [ -n "$2" ] && [ -n "$handle" ] || return 0
  "$(orca_cmd)" orchestration send --to "run:$2" --from "$handle" --type status \
    --subject "$1: $4" --body "hi-crew watch: $4 on $3" >/dev/null 2>&1 || :
}

cmd_events() {
  local w="$DIR/watch" seen total
  seen=$(cat "$w/seen" 2>/dev/null) || seen=0
  total=0; [ -f "$w/events" ] && total=$(wc -l <"$w/events" | tr -d ' ')
  if [ "${1:-}" = --ack ]; then mkdir -p "$w" && printf '%s\n' "$total" >"$w/seen"; return; fi
  [ "$total" -gt "$seen" ] && tail -n "$((total - seen))" "$w/events"
  return 0
}

# The plugin cache path carries the version and moves with each update; the marketplace clone
# beside it does not, so the automation names that copy when there is one.
stable_self() {
  case "$HERE" in
    */plugins/cache/*/lib)
      local base=${HERE%%/plugins/cache/*} rest=${HERE#*/plugins/cache/} s
      s="$base/plugins/marketplaces/${rest%%/*}/plugins/hi-crew/lib/crew.sh"
      [ -f "$s" ] && { printf '%s\n' "$s"; return; } ;;
  esac
  printf '%s\n' "$HERE/crew.sh"
}

WATCH_NAME='hi-crew watch'

cmd_watch_install() {
  need_jq
  local every=${1:-'*/10 * * * *'} O self pre agent id
  O=$(orca_cmd); self=$(stable_self)
  case "$self" in *\'*|*\"*) die "cannot quote the path $self" ;; esac
  pre="${SHELL:-/bin/sh} -lic 'bash \"$self\" watch' </dev/null >/dev/null 2>&1; exit 1"
  agent=$(bash "$CONFIG" get '.crew.agent') || agent=claude
  id=$("$O" automations list --json 2>/dev/null \
    | jq -r --arg n "$WATCH_NAME" '[.result.automations[]? | select(.name == $n) | .id][0] // empty')
  if [ -n "$id" ]; then
    "$O" automations edit "$id" --trigger "$every" --precheck "$pre" --precheck-timeout 600 --enabled --json >/dev/null \
      || die 'could not update the watch automation'
    echo "updated: $WATCH_NAME ($id), $every"
  else
    "$O" automations create --name "$WATCH_NAME" --trigger "$every" --provider "$agent" \
      --prompt 'Nothing to do: hi-crew watch runs in the precheck, which never lets a run start. Stop.' \
      --precheck "$pre" --precheck-timeout 600 --enabled --json >/dev/null \
      || die 'could not create the watch automation'
    echo "created: $WATCH_NAME, $every"
  fi
}

# One line of an Orca error, for a status row's detail.
first_err() { printf '%s' "$1" | jq -r '.error.message // .error // empty' 2>/dev/null | head -1; }

cmd_setup_status() {
  need_jq
  local O out msg self a k v
  O=$(orca_cmd)
  if ! command -v "$O" >/dev/null 2>&1; then
    printf 'orchestration\toff\tno Orca CLI (%s) on PATH\n' "$O"
  elif out=$("$O" orchestration run-list --json 2>&1) && [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
    printf 'orchestration\ton\t%s orchestration answers\n' "$O"
  else
    msg=$(first_err "$out"); [ -n "$msg" ] || msg=$(printf '%s\n' "$out" | head -1)
    printf 'orchestration\toff\t%s\n' "${msg:-orchestration run-list failed}"
  fi
  if out=$("$O" skills installed --json 2>/dev/null) \
     && printf '%s' "$out" | jq -e '[.result.skills[]? | select(.name == "orchestration")] | length > 0' >/dev/null 2>&1; then
    printf 'orca-skill\tok\torchestration\n'
  elif [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
    printf 'orca-skill\tmissing\tOrca'"'"'s orchestration skill is not installed for the agents\n'
  else
    printf 'orca-skill\tunknown\t%s skills installed failed\n' "$O"
  fi
  self=$(stable_self)
  if ! out=$("$O" automations list --json 2>/dev/null) || [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    printf 'watch\tunknown\t%s automations list failed\n' "$O"
  else
    a=$(printf '%s' "$out" | jq -c --arg n "$WATCH_NAME" '[.result.automations[]? | select(.name == $n)][0] // empty')
    if [ -z "$a" ]; then
      printf 'watch\tmissing\tno "%s" automation\n' "$WATCH_NAME"
    elif [ "$(printf '%s' "$a" | jq -r '.enabled')" != true ]; then
      printf 'watch\tdisabled\t"%s" is turned off\n' "$WATCH_NAME"
    elif ! printf '%s' "$a" | jq -e --arg s "$self" '(.precheck | if type == "object" then .command else . end // "") | contains($s)' >/dev/null 2>&1; then
      printf 'watch\tstale\tits precheck does not run %s\n' "$self"
    else
      printf 'watch\tok\t%s\n' "$(printf '%s' "$a" | jq -r '.rrule // ""')"
    fi
  fi
  for k in agent model; do
    if v=$(bash "$CONFIG" get ".crew.$k"); then
      printf 'crew.%s\tset\t%s\n' "$k" "$v"
    elif a=$(bash "$CONFIG" has ".crew.$k"); then
      printf 'crew.%s\tdefault\tnull in %s: left to the default on purpose\n' "$k" "$a"
    elif [ "$k" = agent ]; then
      printf 'crew.agent\tunset\tworkers run claude\n'
    else
      printf 'crew.model\tunset\tworkers get the agent'"'"'s own default, which differs per person\n'
    fi
  done
}

# ---- autostart: the watch starts labelled tickets itself (off unless the person turns it on) ----
#
# Every key is read from the user's own config (--user): the candidates key runs a command, and
# turning on agents that start themselves is one person's decision, not something a cloned repo
# may make for them.
#   crew.autostart.enabled       true to turn it on (default off)
#   crew.autostart.root          the coordinator's git root (a ~ is expanded): the team's crew
#                                settings are read there, the candidates command runs there, and
#                                it is the `root` of each started ticket's facts. Required
#   crew.autostart.candidates    a command printing one JSON object per ready ticket that carries
#                                the label: {"key", "title", "url", "repo"?, "created"?}; {{LABEL}}
#                                and {{ROOT}} become the shell-quoted label and root. Unset: the
#                                root's GitHub issues with the label, keyed <repo name>-<number>
#   crew.autostart.label         the opt-in label (default "auto")
#   crew.autostart.max_active    slots (default 3)
#   crew.autostart.repo          Orca repo selector or path for a candidate without "repo"
#                                (default: the root). A bare path is relative to the root
#   crew.autostart.base          base branch (default origin/main)
#   crew.autostart.run           the Run the started workers join (default: the hi-crew Run whose
#                                coordinator last asked for it here; its terminal sends the start)
#   crew.autostart.max_usage_pct the plan usage at or over which nothing starts (default 80)
#   crew.autostart.usage_max_age_min  how old a usage figure may be (default 30)
#
# A slot is busy while an open ticket's worker may still work: its PR is not merged or closed,
# and, with no PR, its dispatch has sent no worker_done. A merged PR frees the slot even when the
# ticket stays open. A ticket is tried once: autostart/tried/<KEY> is written before the start
# and never cleared, so a failed start, or a ticket whose facts were closed but which keeps the
# label, is not picked again (delete the file to let it try again). One log line per start or
# skip, in autostart/log and on stdout.
AS_DIR="$DIR/autostart"

as_get() { bash "$CONFIG" get --user ".crew.autostart.$1"; }

as_log() { # <kind> <key> <detail>
  if [ -n "${AS_DRY:-}" ]; then printf '%s\t%s\t%s\n' "$1" "$2" "$3"; return; fi
  mkdir -p "$AS_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" | tee -a "$AS_DIR/log"
}

as_num() { case "$1" in ''|*[!0-9.]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# The keys that hold a slot, one per line.
as_busy() {
  local done t key pr d st
  done=$(cmd_reports 2>/dev/null | cut -f2) || done=''
  cmd_list | while IFS= read -r t; do
    key=$(printf '%s' "$t" | jq -r .key); pr=$(printf '%s' "$t" | jq -r '.pr // empty')
    d=$(printf '%s' "$t" | jq -r '.dispatch // empty')
    if [ -n "$pr" ]; then
      st=$(jq -r '.state // empty' "$DIR/watch/$key.json" 2>/dev/null) || st=''
      case "$st" in (merged|closed) continue ;; esac
    elif [ -n "$d" ] && printf '%s\n' "$done" | grep -qxF "$d"; then
      continue
    fi
    printf '%s\n' "$key"
  done
}

# Ready tickets, one JSON object per line, oldest first.
as_candidates() { # <root> <label>
  local cmd line name
  cmd=$(as_get candidates) || cmd=''
  if [ -z "$cmd" ]; then
    name=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
    name=${name%/}; name=${name%.git}; name=${name##*/}; name=${name##*:}
    (cd "$1" && gh issue list --label "$2" --state open --limit 100 --json number,title,url,createdAt) 2>/dev/null \
      | jq -c --arg p "$name" '.[] | {key: "\($p)-\(.number)", title, url, created: .createdAt}' || return 1
  else
    line=$(LABEL=$(q "$2") ROOT=$(q "$1") awk '
      function rep(s, ph, val,   out, i) {
        out = ""
        while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
        return out s
      }
      { print rep(rep($0, "{{LABEL}}", ENVIRON["LABEL"]), "{{ROOT}}", ENVIRON["ROOT"]) }' <<<"$cmd")
    (cd "$1" && sh -c "$line") 2>/dev/null | jq -c 'select(type == "object" and (.key | type) == "string")' || return 1
  fi | jq -sc 'sort_by(.created // "", .key)[]'
}

# The config dir the next worker runs on: Orca's selected Claude account, else the person's own.
as_account() {
  local h
  h=$("$(orca_cmd)" account list --agent claude --json 2>/dev/null | jq -r '
    .result.claude as $c | ($c.accounts // [])[] | select(.id == $c.activeAccountId) | .home // empty' 2>/dev/null | head -1) || h=''
  [ -n "$h" ] && [ -d "$h" ] && { printf '%s\n' "$h"; return; }
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

# usage-save: keep the rate_limits Claude Code gives a statusline, for autostart's usage check.
cmd_usage_save() {
  need_jq
  local d=${CLAUDE_CONFIG_DIR:-$HOME/.claude} f tmp
  f="$d/highness-usage.json"; tmp="$f.tmp.$$"
  jq -ce --argjson now "$(date +%s)" '.rate_limits | select(type == "object" and length > 0) | . + {updated_at: $now}' \
    >"$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
  return 0
}

# usage <config dir>: "<window>\t<pct>" for each fresh window, nothing when the figure is unknown
# (no file, bad JSON, older than usage_max_age_min, or a window already reset).
cmd_usage() {
  need_jq
  local age
  age=$(as_num "$(as_get usage_max_age_min)" 30)
  jq -r --argjson now "${HI_NOW:-$(date +%s)}" --argjson age "$(awk -v a="$age" 'BEGIN { print int(a * 60) }')" '
    select(type == "object" and (.updated_at | type) == "number" and ($now - .updated_at) <= $age)
    | to_entries[] | select((.value | type) == "object")
    | select((.value.used_percentage | type) == "number" and (.value.resets_at | type) == "number" and .value.resets_at > $now)
    | "\(.key)\t\(.value.used_percentage)"' "${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}/highness-usage.json" 2>/dev/null
  return 0
}

# Prints one line saying how the usage stands; exit 1 when it holds the pass.
as_usage() {
  local max acc u over
  max=$(as_num "$(as_get max_usage_pct)" 80)
  acc=${HI_ACCOUNT:-$(as_account)}
  u=$(cmd_usage "$acc")
  [ -n "$u" ] || { printf 'usage unknown on %s\n' "$acc"; return 0; }
  over=$(printf '%s\n' "$u" | awk -F'\t' -v m="$max" '$2 + 0 >= m + 0 { printf "%s%s at %s%%", (n++ ? ", " : ""), $1, $2 }')
  if [ -n "$over" ]; then printf '%s on %s (max %s%%)\n' "$over" "$acc" "$max"; return 1; fi
  printf 'usage under %s%% on %s\n' "$max" "$acc"
}

as_start() { # <candidate json> <root> <run> <handle> <dry>
  local c=$1 root=$2 run=$3 handle=$4 key title url repo base agent model label sf bf out ws path branch err
  key=$(printf '%s' "$c" | jq -r .key); title=$(printf '%s' "$c" | jq -r '.title // .key')
  url=$(printf '%s' "$c" | jq -r '.url // ""')
  repo=$(printf '%s' "$c" | jq -r '.repo // empty'); [ -n "$repo" ] || repo=$(as_get repo) || repo=$root
  case "$repo" in (id:*|name:*|path:*) ;; (/*) repo="path:$repo" ;; (*) repo="path:$root/$repo" ;; esac
  base=$(as_get base) || base=origin/main
  label=$(as_get label) || label=auto
  if [ -n "$5" ]; then as_log would-start "$key" "$repo from $base: $title"; return 0; fi
  mkdir -p "$AS_DIR/tried" && date -u +%Y-%m-%dT%H:%M:%SZ >"$AS_DIR/tried/$key"
  agent=$(cd "$root" && bash "$CONFIG" get '.crew.agent') || agent=claude
  model=$(cd "$root" && bash "$CONFIG" get '.crew.model') || model=''
  bf=$(mktemp "${TMPDIR:-/tmp}/hi-crew-brief.XXXXXX") && sf="$bf.spec" || return 1
  printf 'Started by hi-crew autostart: the ticket carries the label `%s`, and no person has read it\nbefore this start. Read the ticket yourself%s; when it is not clear enough to act on, ask.\n' \
    "$label" "${url:+ ($url)}" >"$bf"
  (cd "$root" && bash "$HERE/crew.sh" spec --key "$key" --title "$title" --brief-file "$bf") >"$sf" \
    || { rm -f "$bf" "$sf"; as_log failed "$key" "could not build the spec"; return 1; }
  out=$(cd "$root" && "$(orca_cmd)" orchestration worker-start --spec-file "$sf" --task-title "$key: $title" \
    --worktree new-top-level --repo "$repo" --name "$key" --base-branch "$base" --agent "$agent" \
    ${model:+--model "$model"} --run "$run" --from "$handle" --timeout-ms 90000 --json 2>&1)
  local rc=$?
  rm -f "$bf" "$sf"
  if [ $rc -ne 0 ] || [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    err=$(first_err "$out"); [ -n "$err" ] || err=$(printf '%s\n' "$out" | head -1)
    as_log failed "$key" "worker-start: ${err:-exit $rc}; not retried (rm $AS_DIR/tried/$key to retry)"
    return 1
  fi
  ws=$(printf '%s' "$out" | jq -r '.result.workspace // empty')
  path=${ws#*::}
  branch=$(git -C "$path" branch --show-current 2>/dev/null) || branch=''
  bash "$HERE/crew.sh" record "$key" "$(printf '%s' "$out" | jq -c --arg t "$title" --arg r "$repo" --arg p "$path" \
      --arg b "$branch" --arg root "$root" --arg a "$agent" --arg m "$model" --arg u "$url" '
      {title: $t, repo: $r, workspace: $p, branch: $b, dispatch: .result.dispatchId, task: .result.taskId,
       run: .result.runId, agent: $a, model: $m, root: $root, url: $u, autostart: true}')" \
    || as_log failed "$key" "started, but its facts were not recorded"
  event "$key" "$run" "${url:-$path}" "started by autostart in $path"
  as_log started "$key" "$path"
}

cmd_autostart() {
  need_jq
  local dry='' root label max run handle busy nbusy free cands c key why n=0
  [ "${1:-}" = --dry-run ] && dry=1
  AS_DRY=$dry
  if [ "$(as_get enabled)" != true ]; then
    [ -n "$dry" ] || return 0
    echo 'crew: autostart is off (crew.autostart.enabled is not true); showing what it would do' >&2
  fi
  root=$(as_get root) || { as_log skip - 'crew.autostart.root is not set'; return 0; }
  case "$root" in ("~"|"~/"*) root="$HOME${root#\~}" ;; esac
  [ -d "$root" ] || { as_log skip - "crew.autostart.root $root is not a directory"; return 0; }
  label=$(as_get label) || label=auto
  max=$(as_num "$(as_get max_active)" 3)
  busy=$(as_busy | awk 'NF')
  nbusy=0; [ -z "$busy" ] || nbusy=$(printf '%s\n' "$busy" | wc -l | tr -d ' ')
  free=$(( ${max%.*} - nbusy ))
  [ -z "$dry" ] || printf 'slots\t%s free of %s\tbusy: %s\n' "$free" "${max%.*}" "$(printf '%s' "$busy" | paste -sd, -)"
  [ "$free" -gt 0 ] || return 0
  run=$(as_get run) || run=$(ls -t "$DIR/handles" 2>/dev/null | head -1)
  handle=$(cat "$DIR/handles/$run" 2>/dev/null) || handle=''
  if [ -z "$run" ] || [ -z "$handle" ]; then
    as_log skip - "no coordinator to start under${run:+ (Run $run has no terminal here)}: open a session and run /hi-crew:start or /hi-crew:agenda once"
    [ -n "$dry" ] || return 0
  fi
  if why=$(as_usage); then
    [ -z "$dry" ] || as_log usage - "$why"
  else
    as_log skip - "$why; nothing started"
    [ -n "$dry" ] || return 0
  fi
  cands=$(as_candidates "$root" "$label") || { as_log skip - "the candidates command failed in $root"; return 0; }
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$n" -lt "$free" ] || break
    key=$(printf '%s' "$c" | jq -r .key)
    case "$key" in (''|*[!A-Za-z0-9._-]*|.*) as_log skip "$key" 'not a valid ticket key'; continue ;; esac
    if [ -f "$DIR/$key.json" ]; then continue; fi
    if [ -f "$AS_DIR/tried/$key" ]; then continue; fi
    as_start "$c" "$root" "$run" "$handle" "$dry" && n=$((n + 1))
  done <<EOF
$cands
EOF
  return 0
}

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  dir) printf '%s\n' "$DIR" ;;
  record) cmd_record "$@" ;;
  get) cmd_get "$@" ;;
  list) cmd_list ;;
  close) cmd_close "$@" ;;
  run) cmd_run "$@" ;;
  runs) cmd_runs ;;
  asks) cmd_asks ;;
  reports) cmd_reports ;;
  spec) cmd_spec "$@" ;;
  watch) cmd_watch ;;
  watch-install) cmd_watch_install "$@" ;;
  autostart) cmd_autostart "$@" ;;
  usage) cmd_usage "$@" ;;
  usage-save) cmd_usage_save ;;
  events) cmd_events "$@" ;;
  prompts) cmd_prompts ;;
  states) cmd_states ;;
  sections) cmd_sections ;;
  orca) orca_cmd ;;
  setup-status) cmd_setup_status ;;
  *) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; [ -z "$sub" ] || exit 2 ;;
esac
