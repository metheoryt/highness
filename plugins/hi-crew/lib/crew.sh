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
#                                     message carries its id as thread_id; an escalation, while its
#                                     dispatch has sent no later worker_done.
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
    | [ .id, .type, .run_id, .dispatch, .created_at, ((.body // .subject // "") | split("\n")[0]) ] | @tsv'
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
  line=$(PR=$(q "$pr") ROOT=$(q "$root") MARKER=$(q "$marker") awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { print rep(rep(rep($0, "{{PR}}", ENVIRON["PR"]), "{{ROOT}}", ENVIRON["ROOT"]), "{{MARKER}}", ENVIRON["MARKER"]) }' <<<"$cmd")
  (cd "$root" && sh -c "$line") 2>/dev/null
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
          "$(case "$kind" in input) echo 'waits on an MCP input dialog' ;; question) echo 'waits on a question form' ;;
               *) echo 'waits on a permission dialog' ;; esac)${tool:+ for $tool}"
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
    "$O" automations edit "$id" --trigger "$every" --precheck "$pre" --precheck-timeout 300 --enabled --json >/dev/null \
      || die 'could not update the watch automation'
    echo "updated: $WATCH_NAME ($id), $every"
  else
    "$O" automations create --name "$WATCH_NAME" --trigger "$every" --provider "$agent" \
      --prompt 'Nothing to do: hi-crew watch runs in the precheck, which never lets a run start. Stop.' \
      --precheck "$pre" --precheck-timeout 300 --enabled --json >/dev/null \
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
    elif ! printf '%s' "$a" | jq -e --arg s "$self" '(.precheck // "") | contains($s)' >/dev/null 2>&1; then
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
  events) cmd_events "$@" ;;
  prompts) cmd_prompts ;;
  states) cmd_states ;;
  orca) orca_cmd ;;
  setup-status) cmd_setup_status ;;
  *) sed -n '2,77p' "$0" | sed 's/^# \{0,1\}//'; [ -z "$sub" ] || exit 2 ;;
esac
