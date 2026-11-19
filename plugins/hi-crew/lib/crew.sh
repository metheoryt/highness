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
#   crew.sh close <KEY>               move <KEY>'s facts to closed/ (the ticket is settled) and
#                                     drop the watch's notes on it
#   crew.sh choice <KEY> <json>       append one answered ask to choices.jsonl: the options with
#                                     their loses:/leans on: lines, what the person took ("option",
#                                     "own" or "reframed"), their reply verbatim. Kept across close,
#                                     so a person's choices can be read back over many tickets
#   crew.sh relay <KEY> [--id <message_id>] [--action <action_id>] <reply-file>
#                                     THE way to answer a worker's question or decision gate: sends
#                                     the reply (orchestration reply) and appends its choices in the
#                                     same step. --id may be left out when <KEY> has one open ask.
#                                     --action: the person said yes to the worker's prepared action;
#                                     it runs once here and the worker hears its outcome.
#                                     The reply file and the record are described at cmd_relay
#   crew.sh action <KEY> <script-file>
#   crew.sh action-show <KEY> [<id>]  a step that needs a person's yes, prepared by the worker as
#                                     exact commands pinned to its HEAD; the coordinator shows it
#                                     verbatim and runs it with relay --action (lib/action.sh)
#   crew.sh stranded                  answers no worker will act on (the worker is gone, or a reply
#                                     Orca refused), one JSON object per line, with the live session
#                                     in the workspace if any; the agenda asks "resume it?"
#   crew.sh resume <KEY>              a worker lost without reporting (a usage limit, an account
#                                     switch): start a new one in its recorded workspace and Run,
#                                     on the spec copy under a "resuming" note, and record its
#                                     dispatch and task, and the noted spec as `resumed_spec`
#                                     (<state dir>/specs/<KEY>.resumed.md). Refuses when the workspace is gone, the
#                                     PR is merged or closed, or the worker is still live (cmd_resume)
#   crew.sh choices [<KEY>]           the recorded choices, one JSON object per line
#   crew.sh choices --gaps            answers to hi-crew asks with no choice line (sent without
#                                     relay), TSV: key, ask id, answered at, the ask's first line
#
# A choice line (choices.jsonl; stable, read back over many tickets, e.g. to learn a person's
# preferences): key, at, question, options [{name, loses, leans_on}], took (option | own |
# reframed | null), picked, reply (the person's words, verbatim). relay adds ask (the message id),
# run, dispatch, asked_at, ask_body (the ask verbatim: its options are usually prose in it) and
# sent (the body relayed). New fields may be added; these keep their names and meaning.
#   crew.sh run                       this session's hi-crew Orca Run: the Run Orca has bound to
#                                     this terminal, when it is one hi-crew made (exit 1: none)
#   crew.sh run <run_id>              register a Run hi-crew made, and pin its coordinator root
#                                     (below) from the cwd, once
#   crew.sh root [<dir>]              this session's coordinator root: where the team's settings,
#                                     {{ROOT}} and the tracker are read for its tickets. Pinned per
#                                     Run when the Run is registered, so a later cd into a clone does
#                                     not move it; <dir> re-pins it. With no pin: the directory whose
#                                     team file applies (an umbrella, from a child clone it lists:
#                                     config.sh root), else the git toplevel, else the cwd
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
#   crew.sh spec --key K --title T [--brief-file F] [--root R]
#                                     the worker spec for a ticket, from reference/worker-spec.md and
#                                     the config keys crew.process and crew.marker, read at R (default:
#                                     `crew.sh root`). In crew.process, {{ROOT}} becomes R, the
#                                     coordinator root: a worker runs in another tree, so the team's files
#                                     must be named by absolute path. {{TRACKER}} becomes the
#                                     tracker adapter reading its config there (`{{TRACKER}} read
#                                     {{KEY}}`, `move`, `comment`: lib/tracker.sh), {{KEY}} the key.
#                                     crew.merge sets the merge line: "never" (default) leaves
#                                     merging to a person; "on_green" has the worker merge its own
#                                     PR once ready and green, unless its brief says otherwise.
#                                     {{CREW}} in the template becomes this crew.sh as a command,
#                                     for the worker's own `record <KEY> '{"pr":…}'`.
#                                     The person's preference files (prefs.sh paths) are cited in
#                                     the Asking part by path, never inlined; none, no line.
#                                     A copy is kept at <state dir>/specs/<KEY>.md (the last spec
#                                     built for K): record it as the facts' `spec`, so the retro
#                                     and `reentry` can point at it
#   crew.sh reentry                   SessionStart(compact) hook, payload on stdin: in the session
#                                     of an open ticket's worker (its cwd in the ticket's
#                                     `workspace`), one context line naming the ticket and its spec
#                                     (the facts' `resumed_spec` after a resume, else `spec`)
#                                     to re-read; anywhere else nothing. Never fails a start
#   crew.sh branch --key K --title T [--type X] [--slug S] [--root R]
#                                     the worker's branch name from the team's crew.branch template,
#                                     read at R (default: `crew.sh root`); exit 1, printing nothing,
#                                     when crew.branch is unset (Orca then names the branch from
#                                     worker-start --name, as before). Placeholders: {{KEY}}, {{SLUG}}
#                                     (S, else the title: lowercase ASCII words joined by "-", at
#                                     most 5 words and 40 characters, "work" when none), {{TYPE}} (X,
#                                     default feat), {{OWNER}} (crew.owner, the person's own name in
#                                     branches, from their file). A placeholder with no value, an
#                                     unknown one, or a result git refuses as a branch name: exit 2
#   crew.sh workspace --repo SEL --name N --branch B --base REF
#                                     create a top-level Orca workspace on branch B (no name prefix;
#                                     Orca adds a numeric suffix when B is taken, so read the branch
#                                     back from the workspace), and print its path. The repo's setup
#                                     runs per its Orca policy in a terminal of its own, and this
#                                     returns without waiting for it. Start the worker in it with
#                                     worker-start --worktree path:<path> --keep-open (a worker in
#                                     an existing workspace otherwise closes when it reports).
#                                     worker-start has no branch option
#   crew.sh watch                    look at the PR of every open ticket and, when something changed
#                                     since the last look, append it to the watch events and wake
#                                     whoever handles it. The worker itself, by a round sent to its
#                                     Dispatch: CI failed, new findings from review bots, and an
#                                     approval when crew.merge is on_green. The coordinator, by a
#                                     status message to its Run: merged or closed, new comments from
#                                     people, an approval otherwise, and a worker event no Dispatch
#                                     took. Bots' plain comments, a bot review with no findings, the
#                                     workers' own comments, labels and cross-references wake no one.
#                                     The first look at a ticket only records it.
#                                     A ticket with no `pr` yet gets its PR looked up with gh by the
#                                     workspace's branch, and recorded when found (the worker records
#                                     it itself at its draft-PR step: {{CREW}} in the spec)
#                                     Run by the Orca automation below, from its precheck, which then
#                                     exits 1 so no agent ever starts
#   crew.sh watch-install [<cron>]    create or update that automation (default every 10 minutes)
#   crew.sh autostart [--dry-run]     start ready tickets that carry the opt-in label into free
#                                     slots, under a coordinator's Run (the watch runs it last; off
#                                     unless crew.autostart.enabled, see "autostart" below).
#                                     --dry-run writes nothing: the slots, then would-start lines
#   crew.sh usage [<config dir>]      the plan usage autostart checks, TSV: window, used percent;
#                                     nothing when unknown
#   crew.sh account                   the config dir autostart checks the budget of: Orca's active
#                                     account, else the profile home claude-profiles/selected-host
#                                     names, else crew.budget.config_dir, else the profile home with
#                                     the freshest highness-usage.json (see as_account)
#   crew.sh held                      "autostart held <N> h: <reason>" while every pass has stopped
#                                     short of starting for over an hour (the budget, no coordinator,
#                                     no root); nothing otherwise. The agenda shows it
#   crew.sh usage-save                read Claude Code's statusline JSON on stdin and keep its
#                                     rate_limits in <config dir>/highness-usage.json for `usage`
#                                     (call it from your statusline command)
#   crew.sh events [--ack]            watch events no one has seen, TSV: time, key, run, pr, what,
#                                     woken (worker | coordinator; empty on older lines);
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
#                                     JSON object per line: section, group (you | others | later | done),
#                                     title, next, url, since; or section and error. See cmd_sections
#   crew.sh orca                      the Orca executable this host should use
#   crew.sh setup-status              what hi-crew needs on this machine and from this person, one
#                                     row per item, name<TAB>state<TAB>detail (/hi:setup renders them):
#                                       orchestration  on | off            Orca's orchestration CLI answers
#                                       orca-skill     ok | missing        Orca's orchestration skill installed
#                                       watch          ok | stale | disabled | missing | unknown
#                                       crew.agent     set | default | unset   (default: set to null on purpose)
#                                       crew.model     set | default | unset
#                                       preferences    ok | missing        a preference file exists
#                                                                          (prefs.sh paths)
#
# PR state comes from the config key crew.pr_state, read at the ticket's `root` (the coordinator
# root, recorded at start): a command that prints one JSON object for a PR,
#   {"state": "open|merged|closed", "draft": bool, "head": sha, "ci": "success|failure|pending|",
#    "people": <count of comments by people>, "people_at": <latest time one was written or edited>,
#    "findings": <count of review bots' findings>, "approvals": [<logins of people who approve>]}
# with {{PR}}, {{ROOT}}, {{MARKER}} and {{BOTS}} replaced by the shell-quoted PR url, root,
# crew.marker and the JSON array of logins that are not people. findings and approvals are
# optional: a state without them never fires their events.
# Not people: a [bot] login, a forge Bot account, the forge Actions users (github-actions,
# forgejo-actions, gitea-actions) and every login in crew.bots (a list; a team's AI reviewer or
# gatekeeper on a normal account goes there). A comment is a person's when its author is a person
# and it is not the workers' own: it does not start with the marker, or with the marker extended
# inside its brackets ("(agent, ...) ..."); an approval's text counts as the approval, not as a
# comment. A finding is a not-a-person's inline review comment, or its review requesting changes.
# Unset, a github.com PR is read with gh. The command runs from an automation, outside any
# terminal, so it must find its own credentials; the precheck runs it in a login interactive shell.
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
  jq -e '.retro_at' "$f" >/dev/null 2>&1 || printf 'crew: %s closed without a retro (lib/retro.sh, reference/retro.md)\n' "$1" >&2
  mkdir -p "$DIR/closed"
  mv "$f" "$DIR/closed/$1.$(date -u +%Y%m%dT%H%M%SZ).json" || exit 1
  # The watch's notes on it (last PR state, the dialog and tool call told), so a ticket opened
  # again under the same key starts from a first look. Named one by one: a glob on "<KEY>.*"
  # would also take a key that extends this one ("A-1" and "A-1.2").
  rm -f "$DIR/watch/$1.json" "$DIR/watch/$1.prompt" "$DIR/watch/$1.tool"
}

# $DIR/run lists every Run hi-crew made, one per line (it once held a single shared Run).
# The watch has no terminal of its own, and Orca sends only from one; it sends from the terminal
# of the Run's coordinator, kept fresh in $DIR/handles/<run> each time the coordinator asks for its
# Run here.
keep_handle() {
  [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || return 0
  mkdir -p "$DIR/handles" && printf '%s\n' "$ORCA_TERMINAL_HANDLE" >"$DIR/handles/$1"
}

cmd_choice() {
  [ $# -eq 2 ] || die 'usage: choice <KEY> <json>'
  need_jq
  keyfile "$1" >/dev/null || exit 2
  printf '%s' "$2" | jq -e 'type == "object"' >/dev/null 2>&1 || die 'choice: the second argument must be a JSON object'
  mkdir -p "$DIR"
  jq -nc --argjson add "$2" --arg key "$1" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{key: $key, at: $now} + $add' >>"$DIR/choices.jsonl" || die "choice: could not write $DIR/choices.jsonl"
}

# relay <KEY> [--id <message_id>] <reply-file>: answer a worker's question or decision gate and
# record the person's choices in one step. The reply file is JSON:
#   {"body": "<the text sent to the worker>",
#    "points": [{"question":…, "options":[{"name":…,"loses":…,"leans_on":…}],
#                "took":"option"|"own"|"reframed", "picked":…, "reply":"<their words, verbatim>"}]}
# Everything is checked before the reply goes out, so a refusal sends nothing. Each point becomes
# one choices.jsonl line, with the ask's id, Run, Dispatch, time and verbatim text added; an
# empty "points" still writes one line (took null), so a relayed reply never shows as a gap.
# --action <id>: the person said yes to the worker's prepared action (lib/action.sh). It runs
# once, here, before the reply goes out, and the reply starts with its outcome; the body follows
# as the person's words. A reply Orca refuses (the worker is gone) is kept for `stranded`, and its
# choice lines are still written, marked undelivered: the person decided all the same.
cmd_relay() {
  local key='' id='' file='' aid='' ask reply recs out body outcome
  local usage='usage: relay <KEY> [--id <message_id>] [--action <action_id>] <reply-file>'
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --action) aid=${2:-}; [ -n "$aid" ] || die "$usage"; shift 2 ;;
      -*) die "relay: unknown argument '$1'" ;;
      *) if [ -z "$key" ]; then key=$1; elif [ -z "$file" ]; then file=$1; else die "$usage"; fi; shift ;;
    esac
  done
  [ -n "$key" ] && [ -n "$file" ] || die "$usage"
  need_jq
  keyfile "$key" >/dev/null || exit 2
  [ -f "$file" ] || die "relay: no reply file: $file"
  reply=$(jq -ce 'select(type == "object" and (.body | type) == "string" and .body != ""
                         and ((.points // []) | type) == "array" and all((.points // [])[]; type == "object"))' "$file" 2>/dev/null) \
    || die 'relay: the reply file must be a JSON object with a non-empty "body" and a "points" array of objects'
  if [ -z "$id" ]; then
    local d ids
    d=$(cmd_get "$key" 2>/dev/null | jq -r '.dispatch // empty')
    [ -n "$d" ] || die "relay: no dispatch recorded for $key; pass --id <message_id>"
    ids=$(cmd_asks | awk -F'\t' -v d="$d" '($2 == "question" || $2 == "decision_gate") && $4 == d { print $1 }')
    [ -n "$ids" ] || die "relay: $key has no open question; pass --id <message_id>"
    [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" -eq 1 ] \
      || die "relay: $key has several open questions ($(printf '%s' "$ids" | tr '\n' ' ')); pass --id"
    id=$ids
  fi
  ask=$(inbox | jq -ce --arg id "$id" 'map(select(.id == $id)) | first
        | select(.type == "question" or .type == "decision_gate")') \
    || die "relay: $id is not a question or decision gate in a hi-crew Run"
  mkdir -p "$DIR" && [ -w "$DIR" ] || die "relay: cannot write $DIR"
  body=$(printf '%s' "$reply" | jq -r .body)
  if [ -n "$aid" ]; then
    out=$(act_meta "$key" "$aid")
    [ -f "$out" ] || die "relay: $key has no action $aid; nothing sent"
    [ "$(jq -r .status "$out")" = prepared ] \
      || die "relay: action $aid was run already ($(jq -r .status "$out")); nothing sent. The worker prepares a new one"
    outcome=$(act_run "$key" "$aid") || die "relay: action $aid was not run; nothing sent"
    body="$outcome

The person's reply, for context (the step above is done; do not run it yourself):
$body"
  fi
  recs=$(jq -nc --argjson r "$reply" --argjson a "$ask" --arg key "$key" --arg sent "$body" --arg aid "$aid" \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ($a.payload // "{}" | fromjson? // {}) as $p
    | {key: $key, at: $now, ask: $a.id, run: $a.run_id, dispatch: $a.dispatch, asked_at: $a.created_at,
       ask_body: ($a.body // $p.question // ""), sent: $sent}
      + (if $aid != "" then {action: $aid} else {} end) as $base
    | (if ($r.points // []) == [] then [{question: null, took: null}] else $r.points end)[]
    | {key: $key, at: $now, question: null}
      + (if (($p.options // []) | length) > 0 then {options: $p.options} else {} end)
      + . + $base') || die 'relay: could not build the choice lines'
  out=$("$(orca_cmd)" orchestration reply --id "$id" --body "$body" --json 2>&1)
  if ! printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1; then
    keep_unsent "$key" "$(jq -nc --arg key "$key" --argjson a "$ask" --arg body "$body" --arg err "$out" --arg aid "$aid" \
      --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{key: $key, at: $now, ask: $a.id, dispatch: $a.dispatch,
        question: (($a.body // $a.subject // "") | split("\n")[0]), body: $body, error: $err}
        + (if $aid != "" then {action: $aid} else {} end)')"
    printf '%s\n' "$recs" | jq -c '. + {undelivered: true}' >>"$DIR/choices.jsonl"
    [ -z "$aid" ] || act_set "$(act_meta "$key" "$aid")" '{"delivered": false}'
    die "relay: the reply was not sent (kept: crew.sh stranded shows it, to send by a new round)${aid:+; action $aid DID run, its outcome is in the kept reply}: $out"
  fi
  [ -z "$aid" ] || act_set "$(act_meta "$key" "$aid")" '{"delivered": true}'
  printf '%s\n' "$recs" >>"$DIR/choices.jsonl" && return 0
  printf 'crew: relay: the reply WAS sent, but %s/choices.jsonl could not be written; record each line with crew.sh choice %s <line>:\n%s\n' \
    "$DIR" "$key" "$recs" >&2
  exit 2
}

# choices --gaps: the answers to hi-crew asks that no choice line names (sent without relay), TSV:
# key (- when no facts name the dispatch), ask id, answered at, the ask's first line. Lines
# recorded before relay existed carry no ask id, so their asks show here too.
choice_gaps() {
  local keys m seen
  [ -s "$DIR/run" ] || return 0
  seen=$(jq -sc 'map(.ask // empty)' "$DIR/choices.jsonl" 2>/dev/null) || seen='[]'
  [ -n "$seen" ] || seen='[]'
  keys=$(cat "$DIR"/*.json "$DIR"/closed/*.json 2>/dev/null | jq -sc 'map(select(.dispatch) | {(.dispatch): .key}) | add // {}')
  # Every Run hi-crew made, not only the open tickets' ones: a closed ticket's gap still counts.
  m=$(inbox "$(jq -Rsc 'split("\n") | map(select(. != ""))' "$DIR/run")") || return 1
  printf '%s' "$m" | jq -r --argjson keys "$keys" --argjson seen "$seen" '
    . as $m
    | $m[] | select(.type == "question" or .type == "decision_gate")
    | . as $q
    | ([ $m[] | select(.thread_id == $q.id and .id != $q.id) | .created_at ] | min) as $ans
    | select($ans != null and ($seen | index($q.id) | not))
    | [ ($keys[$q.dispatch] // "-"), $q.id, $ans, (($q.body // $q.subject // "") | split("\n")[0]) ] | @tsv'
}

cmd_choices() {
  if [ "${1:-}" = --gaps ]; then [ $# -eq 1 ] || die 'usage: choices --gaps'; need_jq; choice_gaps; return; fi
  [ $# -le 1 ] || die 'usage: choices [<KEY>] | choices --gaps'
  need_jq
  [ -f "$DIR/choices.jsonl" ] || return 0
  if [ $# -eq 1 ]; then
    keyfile "$1" >/dev/null || exit 2
    jq -c --arg key "$1" 'select(.key == $key)' "$DIR/choices.jsonl"
  else
    jq -c . "$DIR/choices.jsonl"
  fi
}

cmd_run() {
  if [ $# -eq 1 ]; then
    case "$1" in run_*) ;; *) die "not a Run id: '$1'" ;; esac
    mkdir -p "$DIR"
    grep -qxF "$1" "$DIR/run" 2>/dev/null || printf '%s\n' "$1" >>"$DIR/run"
    keep_handle "$1"
    pin_root "$1"
    return
  fi
  need_jq
  local cur
  cur=$("$(orca_cmd)" orchestration run-current --json 2>/dev/null | jq -r '.result.runId // empty') || return 1
  [ -n "$cur" ] && grep -qxF "$cur" "$DIR/run" 2>/dev/null || return 1
  keep_handle "$cur"
  printf '%s\n' "$cur"
}

# The coordinator root, derived from the cwd: the directory whose team file applies (the umbrella,
# from a child clone it lists: config.sh root), else the git toplevel, else the cwd.
derive_root() {
  bash "$CONFIG" root 2>/dev/null || git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

# $DIR/roots/<run>: the root pinned for a Run, written once when the Run is registered, so a
# coordinator that later cd's into a clone keeps reading the team's settings where it started.
pin_root() { # <run> [<dir>]
  local r
  if [ $# -eq 2 ]; then r=$(cd "$2" 2>/dev/null && pwd -P) || die "root: not a directory: '$2'"
  else [ -s "$DIR/roots/$1" ] && return 0; r=$(derive_root); fi
  mkdir -p "$DIR/roots" && printf '%s\n' "$r" >"$DIR/roots/$1"
}

cmd_root() {
  local run
  if [ $# -eq 1 ]; then
    run=$(cmd_run) || die 'root: this session has no hi-crew Run yet (crew.sh run <run_id> first)'
    pin_root "$run" "$1"; cat "$DIR/roots/$run"; return
  fi
  [ $# -eq 0 ] || die 'usage: root [<dir>]'
  if run=$(cmd_run 2>/dev/null) && [ -s "$DIR/roots/$run" ]; then cat "$DIR/roots/$run"; return; fi
  derive_root
}

cmd_runs() {
  need_jq
  cmd_list | jq -r '.run // empty' | sort -u
}

inbox() { # [<runs json array>] (default: the open tickets' Runs)
  local runs=${1:-}
  [ -n "$runs" ] || runs=$(cmd_runs | jq -Rsc 'split("\n") | map(select(. != ""))')
  [ "$runs" != '[]' ] || { echo '[]'; return; }
  "$(orca_cmd)" orchestration inbox --limit 500 --json --full 2>/dev/null \
    | jq -c --argjson runs "$runs" '(.result.messages // []) | map(select(.run_id as $r | $runs | index($r)))
        | map(. + {dispatch: ((.payload // "{}" | fromjson? // {}) .dispatchId // "")})'
}

cmd_asks() {
  need_jq
  local m resumed; m=$(inbox) || exit $?
  # The Dispatches `resume` replaced: their escalation (the worker lost) is handled.
  resumed=$(cmd_list | jq -sc 'map(.resumed // []) | add // []') || resumed='[]'
  printf '%s' "$m" | jq -r --argjson resumed "$resumed" '
    . as $m
    | [ $m[] | select(.thread_id != null and .thread_id != .id) | .thread_id ] as $answered
    | $m[]
    | select(.type == "question" or .type == "decision_gate" or .type == "escalation")
    | select(.id as $id | $answered | index($id) | not)
    | select(.type != "escalation" or
        (. as $e | [ $m[] | select(.type == "worker_done" and .dispatch == $e.dispatch
                                   and .created_at > $e.created_at) ] | length == 0
                   and ($resumed | index($e.dispatch) | not)))
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
  local key='' title='' brief_file='' brief='' process marker merge crew root='' prefs copy
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root=${2:-}; shift 2 ;;
      --key) key=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --brief-file) brief_file=${2:-}; shift 2 ;;
      *) die "spec: unknown argument '$1'" ;;
    esac
  done
  [ -n "$key" ] && [ -n "$title" ] || die 'usage: spec --key K --title T [--brief-file F] [--root R]'
  keyfile "$key" >/dev/null || exit 2
  [ -f "$TEMPLATE" ] || die "missing $TEMPLATE"
  if [ -n "$brief_file" ]; then
    [ -f "$brief_file" ] || die "no brief file: $brief_file"
    brief=$(cat "$brief_file")
  fi
  [ -n "$root" ] || root=$(cmd_root)
  [ -d "$root" ] || die "spec: the root is not a directory: '$root'"
  process=$(cd "$root" && bash "$CONFIG" get '.crew.process') || process='(none configured: use the tracker and forge tools you have, and say in the PR how you checked the work)'
  marker=$(cd "$root" && bash "$CONFIG" get '.crew.marker') || marker='(agent)'
  merge=$(cd "$root" && bash "$CONFIG" get '.crew.merge') || merge=never
  case "$merge" in
    never) merge="Never merge. That is a person's call." ;;
    on_green) merge="Merge your own pull request once it is ready for review and its checks pass, the way the team's process below says. If your brief says merging is the person's call, it is: then never merge." ;;
    *) die "crew.merge '$merge' is not never or on_green" ;;
  esac
  # The person's preference files, cited by path (never inlined: such stores can be large).
  prefs=$(bash "$HERE/prefs.sh" paths 2>/dev/null | awk '
    NR == 1 { print "- The person'"'"'s own preferences are in these files; read the headings that bear on" }
    NR == 1 { print "  the question, and cite one by file and heading in `leans on:`:" }
    { print "  - `" $0 "`" }')
  # {{CREW}}: this crew.sh as one command, so the worker records facts (its PR) where the watch
  # reads them; a state dir set by HIGHNESS_STATE is carried, since the worker's shell may not have it.
  crew="bash $(q "$HERE/crew.sh")"
  [ -z "${HIGHNESS_STATE:-}" ] || crew="HIGHNESS_STATE=$(q "$HIGHNESS_STATE") $crew"
  # The copy the facts' `spec` names: written beside the output, never in its way (a state dir
  # that cannot be written still prints the spec).
  copy="$DIR/specs/$key.md"
  mkdir -p "$DIR/specs" 2>/dev/null
  # Placeholders are replaced in a fixed order by awk with literal strings (no regex, no &).
  PREFS=$prefs KEY=$key TITLE=$title BRIEF=$brief PROCESS=$process MARKER=$marker MERGE=$merge CREW=$crew ROOT=$root TRACKER=$(tracker_cmd "$root") awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { line = $0
      line = rep(line, "{{KEY}}", ENVIRON["KEY"])
      line = rep(line, "{{TITLE}}", ENVIRON["TITLE"])
      line = rep(line, "{{MARKER}}", ENVIRON["MARKER"])
      line = rep(line, "{{MERGE}}", ENVIRON["MERGE"])
      line = rep(line, "{{CREW}}", ENVIRON["CREW"])
      if (line == "{{BRIEF}}") { print ENVIRON["BRIEF"]; next }
      if (line == "{{PREFERENCES}}") { if (ENVIRON["PREFS"] != "") print ENVIRON["PREFS"]; next }
      if (line == "{{PROCESS}}") {
        print rep(rep(rep(ENVIRON["PROCESS"], "{{ROOT}}", ENVIRON["ROOT"]), "{{TRACKER}}", ENVIRON["TRACKER"]), "{{KEY}}", ENVIRON["KEY"])
        next }
      print line }' "$TEMPLATE" | tee "$copy.tmp.$$" 2>/dev/null
  local rc=${PIPESTATUS[0]}   # awk's: a copy that could not be written does not fail the spec
  if [ "$rc" -eq 0 ] && [ -f "$copy.tmp.$$" ]; then mv -f "$copy.tmp.$$" "$copy" 2>/dev/null; else rm -f "$copy.tmp.$$" 2>/dev/null; fi
  return "$rc"
}

# SessionStart(compact): a compaction keeps what happened, not the spec's rules (asking, merging,
# markers, the team process), and nothing else points the worker back at them. In an open
# ticket's workspace this prints one context line naming the spec to re-read (after a resume, the
# copy with the resume note: `resumed_spec`); the spec itself is
# never inlined (it is long). Every error is silence: a session start must never fail on it.
cmd_reentry() {
  local in cwd real f row key title spec pr msg
  in=$(head -c 16384 2>/dev/null); cat >/dev/null 2>&1
  command -v jq >/dev/null 2>&1 || return 0
  cwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$cwd" ] || cwd=$PWD
  real=$(cd "$cwd" 2>/dev/null && pwd -P) || real=$cwd
  for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    row=$(jq -r --arg a "$cwd" --arg b "$real" '
      (.workspace // "") as $w | select($w != "")
      | select([$a, $b] | any(. == $w or startswith($w + "/")))
      | [.key, (.title // ""), (.resumed_spec // .spec // ""), (.pr // "")] | @tsv' "$f" 2>/dev/null) || continue
    [ -n "$row" ] && break
  done
  [ -n "$row" ] || return 0
  IFS="$(printf '\t')" read -r key title spec pr <<EOF
$row
EOF
  [ -n "$spec" ] || spec="$DIR/specs/$key.md"
  if [ -f "$spec" ]; then
    msg="hi-crew: this session is the ticket worker for $key${title:+ ($title)}, and the compaction kept only a summary of your spec: the ticket, the rules on asking, merging and markers, the team process. Re-read it before your next step: $spec"
  else
    msg="hi-crew: this session is the ticket worker for $key${title:+ ($title)}, and the compaction kept only a summary of your spec: the ticket, the rules on asking, merging and markers, the team process. No copy of it was saved; re-read it from the first prompt of this session's transcript before your next step."
  fi
  [ -z "$pr" ] || msg="$msg Your PR: $pr."
  jq -n -c --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}' 2>/dev/null
  return 0
}

# A slug from free text: lowercase ASCII words joined by "-", at most 5 words and 40 characters.
# Bytes outside [a-z0-9] split words (LC_ALL=C), so a title with no ASCII words gives "work".
slugify() {
  local s
  s=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//' |
      cut -d- -f1-5 | cut -c1-40 | sed 's/-$//')
  printf '%s\n' "${s:-work}"
}

cmd_branch() {
  local key='' title='' type='' slug='' root='' tpl owner='' name
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root=${2:-}; shift 2 ;;
      --key) key=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --type) type=${2:-}; shift 2 ;;
      --slug) slug=${2:-}; shift 2 ;;
      *) die "branch: unknown argument '$1'" ;;
    esac
  done
  [ -n "$key" ] && [ -n "$title" ] || die 'usage: branch --key K --title T [--type X] [--slug S] [--root R]'
  keyfile "$key" >/dev/null || exit 2
  [ -n "$root" ] || root=$(cmd_root)
  [ -d "$root" ] || die "branch: the root is not a directory: '$root'"
  tpl=$(cd "$root" && bash "$CONFIG" get '.crew.branch') || return 1
  [ -n "$tpl" ] || return 1
  case "$tpl" in
    *'{{OWNER}}'*) owner=$(cd "$root" && bash "$CONFIG" get '.crew.owner') || owner=''
      [ -n "$owner" ] || die "branch: crew.branch '$tpl' uses {{OWNER}}: set crew.owner (your name in branches) in your own highness config" ;;
  esac
  slug=$(slugify "${slug:-$title}")
  name=$(KEY=$key SLUG=$slug TYPE=${type:-feat} OWNER=$owner awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { print rep(rep(rep(rep($0, "{{KEY}}", ENVIRON["KEY"]), "{{SLUG}}", ENVIRON["SLUG"]), "{{TYPE}}", ENVIRON["TYPE"]), "{{OWNER}}", ENVIRON["OWNER"]) }' <<<"$tpl")
  case "$name" in *'{{'*'}}'*) die "branch: crew.branch '$tpl' has a placeholder other than {{KEY}}, {{SLUG}}, {{TYPE}}, {{OWNER}}" ;; esac
  git check-ref-format --branch "$name" >/dev/null 2>&1 || die "branch: '$name' (from crew.branch '$tpl') is not a valid branch name"
  printf '%s\n' "$name"
}

cmd_workspace() {
  need_jq
  local repo='' name='' branch='' base='' out path err
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=${2:-}; shift 2 ;;
      --name) name=${2:-}; shift 2 ;;
      --branch) branch=${2:-}; shift 2 ;;
      --base) base=${2:-}; shift 2 ;;
      *) die "workspace: unknown argument '$1'" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$name" ] && [ -n "$branch" ] && [ -n "$base" ] \
    || die 'usage: workspace --repo SEL --name N --branch B --base REF'
  out=$("$(orca_cmd)" worktree create --repo "$repo" --name "$name" --branch "$branch" --base-branch "$base" \
    --no-parent --json 2>&1)
  path=$(printf '%s' "$out" | jq -r 'select(.ok == true) | .result.worktree.path // empty' 2>/dev/null) || path=''
  if [ -z "$path" ]; then
    err=$(first_err "$out"); [ -n "$err" ] || err=$(printf '%s\n' "$out" | head -1)
    die "workspace: orca worktree create failed: ${err:-no path in its answer}"
  fi
  printf '%s\n' "$path"
}

# One shell word: 'it''s' -> 'it'\''s'.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The PR state of a github.com PR when the team set no crew.pr_state. Inline review comments come
# from the REST API (gh pr view has none); when that call fails the whole state fails, so a
# missing list never reads as findings gone and then back.
gh_state() { # <pr url> <marker> <bots json array>
  local view api inline
  view=$(gh pr view "$1" --json state,isDraft,headRefOid,statusCheckRollup,comments,reviews,latestReviews 2>/dev/null) || return 1
  api=$(printf '%s\n' "$1" | sed -n 's#^https://github\.com/\([^/]*\)/\([^/]*\)/pull/\([0-9][0-9]*\).*#repos/\1/\2/pulls/\3/comments#p')
  inline='[]'
  if [ -n "$api" ]; then
    inline=$(gh api --paginate "$api" 2>/dev/null) || return 1
    inline=$(printf '%s' "$inline" | jq -sc 'add // []') || return 1
  fi
  printf '%s' "$view" | jq -c --arg m "$2" --argjson bots "${3:-[]}" --argjson inline "$inline" '
    # Not a person: a [bot] login, a forge Bot account, or a login on the bots list.
    def bot($l; $t): ($l | test("\\[bot\\]$")) or $t == "Bot" or any($bots[]; . == $l);
    def own: (.body // "") as $b | ($b | startswith($m))
             or (($m | endswith(")")) and ($b | startswith(($m | rtrimstr(")")) + ",")));
    ([.comments[]? | {who: (.author.login // ""), at: (.updatedAt // .createdAt // ""), body}]
     + [.reviews[]? | select(.state != "PENDING")
        | {who: (.author.login // ""), at: (.submittedAt // ""), body, state}]
     + [$inline[]? | {who: (.user.login // ""), type: (.user.type // ""), at: (.updated_at // .created_at // ""), body,
                      inline: true}]
     | map(. + {bot: bot(.who; .type // "")})) as $all
    # A person: what they wrote, apart from an approval (its own event) and the workers own words.
    | [$all[] | select((.bot | not) and (own | not) and (.body // "") != "" and .state != "APPROVED")] as $people
    # A review bot finding: its inline comment, or its review that requests changes. Its plain
    # comments (a CI summary rewritten on every push) and a review with neither find nothing.
    | [$all[] | select(.bot and (.inline or .state == "CHANGES_REQUESTED"))] as $found
    | { state: (.state | ascii_downcase), draft: .isDraft, head: .headRefOid,
        ci: ([.statusCheckRollup[]? | (.conclusion // .state // "" | ascii_upcase)] as $c
             | if ($c | length) == 0 then ""
               elif any($c[]; . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT") then "failure"
               elif all($c[]; . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "success"
               else "pending" end),
        people_at: ($people | map(.at) | max // ""),
        people: ($people | length),
        findings: ($found | length),
        approvals: ([.latestReviews[]? | select(.state == "APPROVED") | .author.login // ""
                     | select(. != "" and (bot(.; "") | not))] | unique) }'
}

# What changed between two PR states, one line each: who is woken (worker | coordinator), TAB,
# what. The worker gets what is its own to handle (a CI failure, review bots' findings, and an
# approval when it merges its own PR); the coordinator what needs a person. A field the earlier
# state lacks is no event, so a state command that does not report it never fires one.
changes() { # <before> <after> <approval goes to: worker | coordinator>
  jq -rn --argjson a "$1" --argjson b "$2" --arg ap "${3:-coordinator}" '
    if ($b.state // "") != ($a.state // "") and (($b.state // "") | test("^(merged|closed)$"))
      then "coordinator\tPR \($b.state)" else empty end,
    # A failure on a new head is a new failure, even when the poll missed the pending between.
    if ($b.ci // "") == "failure"
       and (($a.ci // "") != "failure" or (($b.head // "") != "" and ($b.head // "") != ($a.head // "")))
      then "worker\tCI failed on \(($b.head // "")[0:8])" else empty end,
    if ($b.people // 0) > ($a.people // 0)
      then "coordinator\t\(($b.people // 0) - ($a.people // 0)) new comment(s) from people"
    elif ($a | has("people_at")) and ($b.people_at // "") > $a.people_at
      then "coordinator\ta comment from people was written or edited" else empty end,
    if ($a | has("findings")) and ($b.findings // 0) > $a.findings
      then "worker\t\(($b.findings // 0) - $a.findings) new finding(s) from review bots" else empty end,
    if ($a | has("approvals")) then
      (($b.approvals // []) - $a.approvals) as $new
      | if ($new | length) > 0 then "\($ap)\tapproved by \($new | join(", "))" else empty end
    else empty end'
}

# The coordinator root of a ticket's facts: its recorded `root`, else derived from the cwd.
facts_root() { # <facts json>
  local root
  root=$(printf '%s' "$1" | jq -r '.root // empty')
  [ -n "$root" ] && [ -d "$root" ] || root=$(derive_root)
  printf '%s\n' "$root"
}

# The logins that are not people, as a JSON array: the forge Actions users (whose CI jobs write
# and rewrite summary comments), then crew.bots from every config source at <root>. A [bot]
# login and a forge Bot account are never people either (gh_state).
BOTS_DEFAULT='github-actions forgejo-actions gitea-actions'
bots_json() { # <root>
  { printf '%s\n' $BOTS_DEFAULT; (cd "$1" && bash "$CONFIG" list '.crew.bots') 2>/dev/null; } \
    | jq -Rsc 'split("\n") | map(select(. != "")) | unique'
}

pr_state() { # <facts json>
  local pr root cmd marker line bots
  pr=$(printf '%s' "$1" | jq -r '.pr // empty')
  root=$(facts_root "$1")
  cmd=$(cd "$root" && bash "$CONFIG" get '.crew.pr_state') || cmd=''
  marker=$(cd "$root" && bash "$CONFIG" get '.crew.marker') || marker='(agent)'
  bots=$(bots_json "$root")
  if [ -z "$cmd" ]; then
    case "$pr" in https://github.com/*) gh_state "$pr" "$marker" "$bots"; return ;; *) return 1 ;; esac
  fi
  line=$(PR=$(q "$pr") ROOT=$(q "$root") MARKER=$(q "$marker") BOTS=$(q "$bots") fill <<<"$cmd")
  (cd "$root" && sh -c "$line") 2>/dev/null
}

# The worker's Dispatch to wake for these facts: a follow-up round gets a new Dispatch in the same
# workspace, so it is looked up in the Run by the workspace (a live one first, then the newest
# Orca lists), else the recorded `dispatch`. Exit 1 when there is none.
worker_dispatch() { # <facts json>
  local ws run d found
  ws=$(printf '%s' "$1" | jq -r '.workspace // empty')
  run=$(printf '%s' "$1" | jq -r '.run // empty')
  d=$(printf '%s' "$1" | jq -r '.dispatch // empty')
  if [ -n "$ws" ] && [ -n "$run" ]; then
    found=$("$(orca_cmd)" orchestration worker-list --run "$run" --limit 100 --json 2>/dev/null | jq -r --arg ws "$ws" '
      [.result.workers[]? | select((.workspace // "") | sub("^[^:]*::"; "") == $ws)]
      | (map(select(.liveness == "live")) + .) | .[0].dispatchId // empty' 2>/dev/null) || found=''
    [ -n "$found" ] && d=$found
  fi
  [ -n "$d" ] || return 1
  printf '%s\n' "$d"
}

# The PR of facts that have none recorded, found by the workspace's branch: the branch checked
# out there now (a worker may have renamed it), else the recorded `branch`. Asked with gh from the
# workspace, so it reaches the workspace's own forge repo; the newest PR from that branch, any
# state. Prints its url; exit 1 when there is none or gh cannot tell.
find_pr() { # <facts json>
  local ws branch
  ws=$(printf '%s' "$1" | jq -r '.workspace // empty')
  [ -n "$ws" ] && [ -d "$ws" ] || return 1
  branch=$(git -C "$ws" branch --show-current 2>/dev/null) || branch=''
  [ -n "$branch" ] || branch=$(printf '%s' "$1" | jq -r '.branch // empty')
  [ -n "$branch" ] || return 1
  (cd "$ws" && gh pr list --head "$branch" --state all --limit 20 --json number,url 2>/dev/null) \
    | jq -er 'max_by(.number) | .url // empty' 2>/dev/null
}

# stdin with {{PR}}, {{ROOT}}, {{MARKER}}, {{TRACKER}} and {{BOTS}} replaced by $PR, $ROOT,
# $MARKER, $TRACKER and $BOTS (each may be unset).
fill() {
  awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { print rep(rep(rep(rep(rep($0, "{{PR}}", ENVIRON["PR"]), "{{ROOT}}", ENVIRON["ROOT"]), "{{MARKER}}", ENVIRON["MARKER"]), "{{TRACKER}}", ENVIRON["TRACKER"]), "{{BOTS}}", ENVIRON["BOTS"]) }'
}

# The tracker adapter (lib/tracker.sh) as one shell command reading its config at <root>: what
# {{TRACKER}} becomes in agenda.sections, the autostart candidates and crew.process.
tracker_cmd() { printf 'bash %s --root %s' "$(q "$HERE/tracker.sh")" "$(q "$1")"; }

# The team's own digest sections (config agenda.sections), so the digest covers more than the
# workers without hi knowing the team's tracker or forge. Each section is {"name", "command"}; the
# command runs from the team file's root (derive_root: an umbrella, from a child clone it lists)
# with {{ROOT}}, {{MARKER}} and {{TRACKER}} filled in, and prints
# one JSON object per line: {"group": "you|others|later|done", "title", "next", "url", "since"}
# (all but title optional). `{{TRACKER}} sections` is the person's tickets from the configured
# tracker (lib/tracker.sh).
# The open threads of the hi-threads journal come first, as section "threads" (with open_items,
# status, waits_on and resume besides the usual fields), when the journal exists.
# Out: the same objects with "section" added; other lines are skipped. A section whose command fails
# gives one line with "error" set instead, so a broken source shows rather than vanishes.
cmd_sections() {
  need_jq
  local root secs n i name cmd line out rc
  root=$(derive_root)
  # The person's open work threads from the hi-threads journal, when that plugin keeps one here.
  bash "$HERE/threads-read.sh" agenda 2>/dev/null | jq -c '{section: "threads"} + .' 2>/dev/null
  secs=$(cd "$root" && bash "$CONFIG" get '.agenda.sections') || secs=''
  [ -n "$secs" ] && [ "$secs" != null ] || return 0
  n=$(printf '%s' "$secs" | jq 'if type == "array" then length else 0 end' 2>/dev/null) || n=0
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    name=$(printf '%s' "$secs" | jq -r ".[$i].name // \"section $i\"")
    cmd=$(printf '%s' "$secs" | jq -r ".[$i].command // empty")
    i=$((i + 1))
    [ -n "$cmd" ] || continue
    line=$(ROOT=$(q "$root") TRACKER=$(tracker_cmd "$root") MARKER=$(q "$(cd "$root" && bash "$CONFIG" get '.crew.marker' 2>/dev/null || echo '(agent)')") fill <<<"$cmd")
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
  local w="$DIR/watch" lock="$DIR/watch/lock" t key pr run now snap what hit since tool kind hs ap to
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
    # No PR recorded yet (the worker records it at its draft-PR step): look it up by the branch,
    # and record what is found, so the digest and later passes read it from the facts.
    if [ -z "$pr" ]; then
      pr=$(find_pr "$t") || continue
      (cmd_record "$key" "$(jq -cn --arg pr "$pr" '{pr: $pr}')") || continue
      t=$(printf '%s' "$t" | jq -c --arg pr "$pr" '.pr = $pr')
    fi
    now=$(pr_state "$t") && printf '%s' "$now" | jq -e 'type == "object"' >/dev/null 2>&1 || continue
    snap="$w/$key.json"
    if [ -f "$snap" ]; then
      # An approval is the worker's when it merges its own PR (crew.merge on_green), else a person's.
      ap=coordinator
      [ "$(cd "$(facts_root "$t")" && bash "$CONFIG" get '.crew.merge' 2>/dev/null)" = on_green ] && ap=worker
      # A note from before v2 counted people another way (approval texts in, inline comments out):
      # its people count is taken from now, so the switch neither fires nor swallows a comment.
      changes "$(jq -c --argjson b "$now" 'if .v == 2 then . else . + ($b | {people, people_at} | with_entries(select(.value != null))) end' "$snap")" \
          "$now" "$ap" | while IFS="$(printf '\t')" read -r to what; do
        if [ "$to" = worker ]; then event "$key" "$run" "$pr" "$what" "$t"; else event "$key" "$run" "$pr" "$what"; fi
      done
    fi
    printf '%s' "$now" | jq -c '. + {v: 2}' >"$snap"
  done
  # The budget hold (lib/hold.sh): pause the autostarted workers of an account over the person's
  # reserve, resume them when it is back. Before the slot count, which returns early exactly when
  # every slot holds a running worker. Only with autostart on, or while a worker is held.
  if [ "$(as_get enabled)" = true ] || [ -n "$(bash "$HERE/hold.sh" held)" ]; then
    bash "$HERE/hold.sh" pass "${HI_ACCOUNT:-$(as_account)}" >/dev/null 2>&1 || :
  fi
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

# Append one watch event and wake the ticket's coordinator with it, or, given the ticket's facts,
# its worker: a round to the worker's Dispatch, which a working worker reads when its turn ends
# and a finished one gets as a follow-up Task. When no Dispatch is found or Orca refuses the send,
# the coordinator is woken instead. The events line ends with who was woken: worker | coordinator.
event() { # <key> <run> <pr or workspace> <what> [<facts json>]
  local w="$DIR/watch" handle d out to=coordinator
  mkdir -p "$w"
  handle=$(cat "$DIR/handles/$2" 2>/dev/null) || handle=''
  if [ $# -ge 5 ] && [ -n "$handle" ] && d=$(worker_dispatch "$5"); then
    out=$("$(orca_cmd)" orchestration send --to "dispatch:$d" --from "$handle" --type status --subject "$1: $4" \
      --body "hi-crew watch: $4 on $3. This is yours to handle, as your spec says: read it on the PR and act on it. Ask the coordinator only when a person must decide." \
      --json 2>/dev/null) || out=''
    if printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1; then
      to=worker
      [ "$d" = "$(printf '%s' "$5" | jq -r '.dispatch // empty')" ] || (cmd_record "$1" "$(jq -cn --arg d "$d" '{dispatch: $d}')")
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "$4" "$to" >>"$w/events"
  [ "$to" = coordinator ] || return 0
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

# The physical path of an existing file: every symlink on the way resolved (the file's own too),
# without readlink -f, which BSD lacks. Fails when the file or its directory does not exist.
phys() { # <file>
  local f=$1 d l n=0
  while :; do
    d=$(cd -P "$(dirname "$f")" 2>/dev/null && pwd -P) || return 1
    f="$d/$(basename "$f")"
    [ -L "$f" ] || break
    n=$((n + 1)); [ "$n" -le 40 ] || return 1
    l=$(readlink "$f") || return 1
    case "$l" in /*) f=$l ;; *) f="$d/$l" ;; esac
  done
  [ -f "$f" ] || return 1
  printf '%s\n' "$f"
}

# The plugin cache path carries the version and moves with each update; the marketplace clone
# beside it does not, so the automation names that copy when there is one. The path is physical:
# a profile that reaches the plugin through a symlink (skills/hi-crew -> a checkout), or several
# profiles linking the same checkout, all name the same file, so the watch reads the same from each.
stable_self() {
  local s="$HERE/crew.sh" p
  case "$HERE" in
    */plugins/cache/*/lib)
      local base=${HERE%%/plugins/cache/*} rest=${HERE#*/plugins/cache/} m
      m="$base/plugins/marketplaces/${rest%%/*}/plugins/hi-crew/lib/crew.sh"
      [ -f "$m" ] && s=$m ;;
  esac
  p=$(phys "$s") && s=$p
  printf '%s\n' "$s"
}

# The crew.sh a watch precheck runs: `bash "<path>" watch`, or the unquoted `bash <path> watch`.
precheck_self() { # <precheck command>
  local s
  s=$(printf '%s\n' "$1" | sed -n 's/.*bash "\([^"]*\)" watch.*/\1/p' | head -1)
  [ -n "$s" ] || s=$(printf '%s\n' "$1" | sed -n 's/.*bash \([^ "'"'"']*\) watch.*/\1/p' | head -1)
  [ -n "$s" ] && printf '%s\n' "$s"
}

# Whether a precheck runs this crew.sh: the same text, or a path that resolves to the same file.
precheck_runs() { # <precheck command> <self>
  local s a b
  case "$1" in *"$2"*) return 0 ;; esac
  s=$(precheck_self "$1") || return 1
  a=$(phys "$s") || return 1
  b=$(phys "$2") || return 1
  [ "$a" = "$b" ]
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
    elif ! precheck_runs "$(printf '%s' "$a" | jq -r '.precheck | if type == "object" then .command else . end // ""')" "$self"; then
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
  # The person's preference files (prefs.sh): none yet is when /hi:setup offers /hi:meet.
  v=$(bash "$HERE/prefs.sh" paths 2>/dev/null | awk 'NF { n++; if (n == 1) f = $0 } END { if (n) printf "%s%s", f, (n > 1 ? " (+" n - 1 " more)" : "") }')
  if [ -n "$v" ]; then printf 'preferences\tok\t%s\n' "$v"
  else printf 'preferences\tmissing\tnone of the files prefs.sh targets exists: %s\n' "$(bash "$HERE/prefs.sh" targets 2>/dev/null | tail -1)"; fi
  # The tracker answers with the person's credential, when the repo (or the person) configures one.
  if bash "$CONFIG" get '.tracker.kind' >/dev/null 2>&1; then
    if out=$(bash "$HERE/tracker.sh" status 2>&1); then
      printf 'tracker\tok\t%s\n' "$(printf '%s' "$out" | tail -1)"
    else
      case $? in 1) k=no-token ;; 2) k=rejected ;; 4) k=config ;; *) k=error ;; esac
      printf 'tracker\t%s\t%s\n' "$k" "$(printf '%s' "$out" | tail -1 | sed 's/^tracker: //')"
    fi
  fi
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
#                                the label: {"key", "title", "url", "repo"?, "created"?, "type"?}
#                                ("type" fills crew.branch's {{TYPE}}); {{LABEL}} and {{ROOT}} become the shell-quoted label and root, {{TRACKER}}
#                                the tracker adapter. Unset: with tracker.kind set at the root,
#                                the adapter's ready tickets (role todo) with the label; else the
#                                root's GitHub issues with the label, keyed <repo name>-<number>
#   crew.autostart.label         the opt-in label (default "auto")
#   crew.autostart.max_active    slots (default 3)
#   crew.autostart.repo          Orca repo selector or path for a candidate without "repo"
#                                (default: the root). A bare path is relative to the root
#   crew.autostart.base          base branch (default origin/main)
#   crew.autostart.run           the Run the started workers join (default: the hi-crew Run whose
#                                coordinator last asked for it here; its terminal sends the start)
#   (usage)                      nothing starts while lib/budget.sh holds the account: the
#                                person's reserve of each plan window, crew.budget.* (budget.sh)
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
  [ "$1 $2" != 'skip -' ] || as_hold "$3"
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" | tee -a "$AS_DIR/log"
}

# A pass that stopped short of the candidates (a skip of the whole pass: the budget, no
# coordinator, no root) keeps $AS_DIR/held: since<TAB>reason, since kept from the first such pass.
# A pass that gets past them, or autostart turned off, removes it. `crew.sh held` reads it.
as_hold() { # <reason>
  local since
  since=$(cut -f1 "$AS_DIR/held" 2>/dev/null | head -1)
  case "$since" in (''|*[!0-9]*) since=${HI_NOW:-$(date +%s)} ;; esac
  printf '%s\t%s\n' "$since" "$1" >"$AS_DIR/held.$$" && mv "$AS_DIR/held.$$" "$AS_DIR/held"
}
as_unhold() { [ -n "${AS_DRY:-}" ] || rm -f "$AS_DIR/held"; }

# held: "autostart held <N> h: <reason>" once a hold has lasted over an hour; nothing otherwise.
# The agenda shows it: a hold makes no event, and starts nothing to look at.
cmd_held() {
  local since='' reason='' now
  [ -f "$AS_DIR/held" ] || return 0
  IFS="$(printf '\t')" read -r since reason <"$AS_DIR/held"
  case "$since" in (''|*[!0-9]*) return 0 ;; esac
  now=${HI_NOW:-$(date +%s)}
  [ $((now - since)) -gt 3600 ] || return 0
  printf 'autostart held %s h: %s\n' $(((now - since) / 3600)) "$reason"
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
  if [ -z "$cmd" ] && (cd "$1" && bash "$CONFIG" get '.tracker.kind' >/dev/null 2>&1); then
    bash "$HERE/tracker.sh" --root "$1" candidates "$2" 2>/dev/null \
      | jq -c 'select(type == "object" and (.key | type) == "string")' || return 1
  elif [ -z "$cmd" ]; then
    name=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || return 1
    name=${name%/}; name=${name%.git}; name=${name##*/}; name=${name##*:}
    (cd "$1" && gh issue list --label "$2" --state open --limit 100 --json number,title,url,createdAt) 2>/dev/null \
      | jq -c --arg p "$name" '.[] | {key: "\($p)-\(.number)", title, url, created: .createdAt}' || return 1
  else
    line=$(LABEL=$(q "$2") ROOT=$(q "$1") TRACKER=$(tracker_cmd "$1") awk '
      function rep(s, ph, val,   out, i) {
        out = ""
        while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
        return out s
      }
      { print rep(rep(rep($0, "{{LABEL}}", ENVIRON["LABEL"]), "{{ROOT}}", ENVIRON["ROOT"]), "{{TRACKER}}", ENVIRON["TRACKER"]) }' <<<"$cmd")
    (cd "$1" && sh -c "$line") 2>/dev/null | jq -c 'select(type == "object" and (.key | type) == "string")' || return 1
  fi | jq -sc 'sort_by(.created // "", .key)[]'
}

# The dirs that hold Orca's Claude profiles (<dir>/<id>/home), one per line, those that exist:
# HI_ORCA_PROFILES when set (it alone); else the parents of the homes `account list` names, of
# CLAUDE_CONFIG_DIR when it is one, and Orca's data dir on Linux and macOS.
as_profiles() { # <account list json>
  local p
  if [ -n "${HI_ORCA_PROFILES:-}" ]; then [ -d "$HI_ORCA_PROFILES" ] && printf '%s\n' "$HI_ORCA_PROFILES"; return 0; fi
  {
    printf '%s' "$1" | jq -r '(.result.claude // .result // {}) | (.accounts // [])[] | .home // empty' 2>/dev/null
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-}"
  } | while IFS= read -r p; do
    case "${p%/}" in (*/claude-profiles/*/home) p=${p%/}; p=${p%/home}; printf '%s\n' "${p%/*}" ;; esac
  done
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/orca/claude-profiles" \
    "$HOME/Library/Application Support/orca/claude-profiles" "$HOME/Library/Application Support/Orca/claude-profiles"
} 2>/dev/null

# The config dir the next worker runs on — the account whose plan the budget check reads:
#   1. Orca's active Claude account (`account list`);
#   2. else the profile home Orca launches on, named by <profiles>/selected-host (a path or an id);
#   3. else crew.budget.config_dir from the person's own file;
#   4. else the profile home (or CLAUDE_CONFIG_DIR) whose highness-usage.json is the freshest;
#   5. else CLAUDE_CONFIG_DIR, or ~/.claude.
# With an empty account list Orca still launches on a profile home, never on ~/.claude; that
# dir's usage cache is frozen, and every pass would hold (highness#59).
as_account() {
  local list profiles h p s d best='' bt=0 t
  list=$("$(orca_cmd)" account list --agent claude --json 2>/dev/null) || list=''
  h=$(printf '%s' "$list" | jq -r '(.result.claude // .result // {}) as $c
    | ($c.accounts // [])[] | select(.id == $c.activeAccountId) | .home // empty' 2>/dev/null | head -1) || h=''
  [ -n "$h" ] && [ -d "$h" ] && { printf '%s\n' "${h%/}"; return; }
  profiles=$(as_profiles "$list" | awk 'NF && !seen[$0]++' | while IFS= read -r p; do [ -d "$p" ] && printf '%s\n' "$p"; done)
  while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$p/selected-host" ] || continue
    s=$(tr -d '\r\n' <"$p/selected-host" 2>/dev/null)
    case "$s" in ('') continue ;; (/*) h=$s ;; (*/*) continue ;; (*) h="$p/$s/home" ;; esac
    [ -d "$h" ] && { printf '%s\n' "${h%/}"; return; }
  done <<EOF
$profiles
EOF
  h=$(bash "$CONFIG" get --user '.crew.budget.config_dir' 2>/dev/null) || h=''
  case "$h" in ("~"|"~/"*) h="$HOME${h#\~}" ;; esac
  [ -n "$h" ] && [ -d "$h" ] && { printf '%s\n' "${h%/}"; return; }
  while IFS= read -r d; do
    [ -n "$d" ] && [ -f "$d/highness-usage.json" ] || continue
    t=$(jq -r '.updated_at // 0 | floor' "$d/highness-usage.json" 2>/dev/null) || t=0
    case "$t" in (''|*[!0-9]*) t=0 ;; esac
    [ "$t" -gt "$bt" ] && { bt=$t; best=$d; }
  done <<EOF
$(printf '%s\n' "$profiles" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    for d in "$p"/*/home; do [ -d "$d" ] && printf '%s\n' "$d"; done
  done
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
EOF
  [ -n "$best" ] && { printf '%s\n' "${best%/}"; return; }
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

# Prints one line saying how the usage stands; exit 1 when it holds the pass (lib/budget.sh).
as_usage() {
  local acc
  acc=${HI_ACCOUNT:-$(as_account)}
  bash "$HERE/budget.sh" check "$acc"
}

as_start() { # <candidate json> <root> <run> <handle> <dry>
  local c=$1 root=$2 run=$3 handle=$4 key title url repo base agent model label sf bf out ws path branch err
  local named='' wpath='' place
  key=$(printf '%s' "$c" | jq -r .key); title=$(printf '%s' "$c" | jq -r '.title // .key')
  url=$(printf '%s' "$c" | jq -r '.url // ""')
  repo=$(printf '%s' "$c" | jq -r '.repo // empty'); [ -n "$repo" ] || repo=$(as_get repo) || repo=$root
  case "$repo" in (id:*|name:*|path:*) ;; (/*) repo="path:$repo" ;; (*) repo="path:$root/$repo" ;; esac
  base=$(as_get base) || base=origin/main
  label=$(as_get label) || label=auto
  # The team's branch template (crew.branch), when it has one: exit 1 is unset, 2 an error.
  named=$(bash "$HERE/crew.sh" branch --key "$key" --title "$title" --root "$root" \
    --type "$(printf '%s' "$c" | jq -r '.type // empty')" 2>&1)
  case $? in
    0) ;;
    1) named='' ;;
    *) as_log failed "$key" "$(printf '%s\n' "$named" | sed 's/^crew: //' | head -1)"; return 1 ;;
  esac
  if [ -n "$5" ]; then as_log would-start "$key" "$repo from $base${named:+ as $named}: $title"; return 0; fi
  mkdir -p "$AS_DIR/tried" && date -u +%Y-%m-%dT%H:%M:%SZ >"$AS_DIR/tried/$key"
  if [ -n "$named" ]; then
    # worker-start has no branch option: create the workspace on the branch, then start in it.
    wpath=$(cd "$root" && bash "$HERE/crew.sh" workspace --repo "$repo" --name "$key" --branch "$named" --base "$base" 2>&1) || {
      as_log failed "$key" "$(printf '%s\n' "$wpath" | sed 's/^crew: //' | head -1); not retried (rm $AS_DIR/tried/$key to retry)"
      return 1; }
    place=(--worktree "path:$wpath" --keep-open)
  else
    place=(--worktree new-top-level --repo "$repo" --name "$key" --base-branch "$base")
  fi
  agent=$(cd "$root" && bash "$CONFIG" get '.crew.agent') || agent=claude
  model=$(cd "$root" && bash "$CONFIG" get '.crew.model') || model=''
  bf=$(mktemp "${TMPDIR:-/tmp}/hi-crew-brief.XXXXXX") && sf="$bf.spec" || return 1
  printf 'Started by hi-crew autostart: the ticket carries the label `%s`, and no person has read it\nbefore this start. Read the ticket yourself%s; when it is not clear enough to act on, ask.\n' \
    "$label" "${url:+ ($url)}" >"$bf"
  (cd "$root" && bash "$HERE/crew.sh" spec --key "$key" --title "$title" --brief-file "$bf" --root "$root") >"$sf" \
    || { rm -f "$bf" "$sf"; as_log failed "$key" "could not build the spec"; return 1; }
  out=$(cd "$root" && "$(orca_cmd)" orchestration worker-start --spec-file "$sf" --task-title "$key: $title" \
    "${place[@]}" --agent "$agent" \
    ${model:+--model "$model"} --run "$run" --from "$handle" --timeout-ms 90000 --json 2>&1)
  local rc=$?
  rm -f "$bf" "$sf"
  if [ $rc -ne 0 ] || [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    err=$(first_err "$out"); [ -n "$err" ] || err=$(printf '%s\n' "$out" | head -1)
    as_log failed "$key" "worker-start: ${err:-exit $rc}${wpath:+ (its workspace $wpath was created)}; not retried (rm $AS_DIR/tried/$key to retry)"
    return 1
  fi
  ws=$(printf '%s' "$out" | jq -r '.result.workspace // empty')
  path=${ws#*::}; [ -z "$wpath" ] || path=$wpath
  branch=$(git -C "$path" branch --show-current 2>/dev/null) || branch=''
  bash "$HERE/crew.sh" record "$key" "$(printf '%s' "$out" | jq -c --arg t "$title" --arg r "$repo" --arg p "$path" \
      --arg b "$branch" --arg root "$root" --arg a "$agent" --arg m "$model" --arg u "$url" --arg s "$DIR/specs/$key.md" '
      {title: $t, repo: $r, workspace: $p, branch: $b, dispatch: .result.dispatchId, task: .result.taskId,
       run: .result.runId, agent: $a, model: $m, root: $root, url: $u, spec: $s, autostart: true}')" \
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
    [ -n "$dry" ] || { as_unhold; return 0; }
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
  [ "$free" -gt 0 ] || { as_unhold; return 0; }
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
  as_unhold
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

# resume <KEY>: start a new worker on <KEY> in its recorded workspace and Run, after the last one
# was lost without reporting (a usage limit, an account switch, a closed session). Orca's own
# retry does not fit: --retry-of needs --task, and a Task's spec cannot carry the note below,
# while `claude --resume` cannot follow a session into another Claude profile. So this is a new
# Task: the spec copy (the facts' `spec`) under a note that says the work so far is in the
# workspace, then the new dispatch and task recorded, the old dispatch kept in `resumed` (asks
# drops its "lost" escalation). Refuses, starting nothing: no facts, no workspace, no spec copy,
# a merged or closed PR, or a worker on it Orca still counts live. Prints the receipt.
cmd_resume() {
  [ $# -eq 1 ] || die 'usage: resume <KEY>'
  need_jq
  local key=$1 facts ws run spec root pr state d agent model handle title branch sf out rc m asked noted
  facts=$(cmd_get "$key") || die "resume: no open facts for $key"
  ws=$(printf '%s' "$facts" | jq -r '.workspace // empty')
  run=$(printf '%s' "$facts" | jq -r '.run // empty')
  [ -n "$ws" ] && [ -d "$ws" ] || die "resume: $key's workspace is gone (${ws:-none recorded}); start it afresh with /hi-crew:start"
  [ -n "$run" ] || die "resume: no Run recorded for $key"
  spec=$(printf '%s' "$facts" | jq -r '.spec // empty'); [ -n "$spec" ] || spec="$DIR/specs/$key.md"
  [ -f "$spec" ] || die "resume: no spec copy for $key ($spec); build one with crew.sh spec and record it as \"spec\""
  pr=$(printf '%s' "$facts" | jq -r '.pr // empty')
  [ -n "$pr" ] || { pr=$(find_pr "$facts") || pr=''; }
  if [ -n "$pr" ]; then
    state=$(pr_state "$(printf '%s' "$facts" | jq -c --arg p "$pr" '.pr = $p')" | jq -r '.state // empty' 2>/dev/null) || state=''
    case "$state" in
      merged|closed) die "resume: $key's PR is $state ($pr): nothing to resume" ;;
      '') printf 'crew: resume: could not read the state of %s; resuming anyway\n' "$pr" >&2 ;;
    esac
  fi
  if d=$(worker_dispatch "$facts") && dispatch_live "$d"; then
    die "resume: $key's worker $d is not settled in Orca (orchestration worker-show --dispatch $d); a lost one is"
  fi
  [ -n "$d" ] || d=$(printf '%s' "$facts" | jq -r '.dispatch // empty')
  root=$(facts_root "$facts")
  agent=$(printf '%s' "$facts" | jq -r '.agent // empty')
  [ -n "$agent" ] || agent=$(cd "$root" && bash "$CONFIG" get '.crew.agent') || agent=claude
  model=$(printf '%s' "$facts" | jq -r '.model // empty')
  title=$(printf '%s' "$facts" | jq -r '.title // empty'); [ -n "$title" ] || title=$key
  branch=$(git -C "$ws" branch --show-current 2>/dev/null) || branch=''
  handle=${ORCA_TERMINAL_HANDLE:-$(cat "$DIR/handles/$run" 2>/dev/null)}
  # The earlier worker's stranded asks: recording the new dispatch retires them from `stranded`,
  # so they go into the note, the person's answer verbatim where there is one.
  # The inbox goes through a file: as an argument it can pass the kernel's limit on one.
  m=$(mktemp "${TMPDIR:-/tmp}/hi-crew-inbox.XXXXXX") || die 'resume: no temp file'
  inbox >"$m" 2>/dev/null && [ -s "$m" ] || echo '[]' >"$m"
  asked=$(cmd_stranded 2>/dev/null | jq -rs --arg k "$key" --slurpfile mm "$m" '
    $mm[0] as $m
    | map(select(.key == $k)) | unique_by(.ask)[]
    | (if .what == "unsent" then .body
       elif .what == "unheard" then (.ask as $a | [$m[] | select(.thread_id == $a and .id != $a)] | min_by(.created_at) | .body // "")
       else "" end) as $ans
    | "- It asked: \(.question)\n"
      + (if $ans != "" then "  The person answered (it never reached that worker; act on it):\n\n"
                          + ($ans | split("\n") | map("  > " + .) | join("\n")) + "\n"
         else "  No answer came before it stopped. Ask again if it still stands.\n" end)') || asked=''
  rm -f "$m"
  sf=$(mktemp "${TMPDIR:-/tmp}/hi-crew-resume.XXXXXX") || die 'resume: no temp file'
  {
    printf '## Resuming %s: read this first\n\n' "$key"
    printf 'An earlier worker on this ticket stopped without reporting%s: a usage limit, an account\n' "${d:+ (Dispatch $d)}"
    printf 'switch or a closed session. Its chat is gone, but its work is here, in this workspace%s.\n\n' "${branch:+ on the branch \`$branch\`}"
    printf 'Before anything else, find where it stopped:\n\n'
    printf -- '- `git status`, `git stash list` and `git log --oneline -20`: what it committed, and what it left\n'
    printf '  uncommitted. Uncommitted changes are its work in progress: keep them and build on them.\n'
    if [ -n "$pr" ]; then
      printf -- '- Its pull request, %s: the description, the comments, the review threads and CI.\n' "$pr"
    else
      printf -- '- Its pull request, if it opened one: look it up on the forge by the branch.\n'
    fi
    printf -- '- The ticket'"'"'s comments since it started: what it posted, and what people answered.\n\n'
    [ -z "$asked" ] || printf 'Its questions to the coordinator that it never acted on:\n\n%s\n\n' "$asked"
    printf 'Then continue from there, under the spec below. That pull request is yours: do not open a\n'
    printf 'second one, and do not redo committed work. The spec'"'"'s "Already done?" check is about this\n'
    printf 'ticket landing elsewhere, not about the earlier worker'"'"'s progress here.\n\n---\n\n'
    cat "$spec"
  } >"$sf"
  out=$(cd "$root" && "$(orca_cmd)" orchestration worker-start --spec-file "$sf" --task-title "$key: $title (resumed)" \
    --worktree "path:$ws" --keep-open --agent "$agent" ${model:+--model "$model"} --run "$run" \
    ${handle:+--from "$handle"} --json 2>&1)
  rc=$?
  if [ $rc -ne 0 ] || [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    rm -f "$sf"
    die "resume: worker-start failed; do not rerun it, read failedStage (orca skills get orchestration --reference references/recovery-and-cleanup.md): $out"
  fi
  # The spec the new worker got, note included, is what `reentry` points it back at after a
  # compaction; `spec` stays the original (the retro reads it, the next resume builds on it).
  noted="$DIR/specs/$key.resumed.md"
  mkdir -p "$DIR/specs" 2>/dev/null
  mv -f "$sf" "$noted" 2>/dev/null || { rm -f "$sf"; noted=''; }
  (cmd_record "$key" "$(printf '%s' "$out" | jq -c --argjson f "$facts" --arg d "$d" --arg pr "$pr" --arg n "$noted" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {dispatch: .result.dispatchId, task: .result.taskId, resumed_at: $now,
     resumed: (($f.resumed // []) + (if $d != "" then [$d] else [] end))}
    + (if $n != "" then {resumed_spec: $n} else {} end)
    + (if $pr != "" and ($f.pr // "") == "" then {pr: $pr} else {} end)')") \
    || die "resume: the worker started, but its facts were not recorded; record its dispatch and task by hand: $out"
  printf '%s\n' "$out"
}

. "$HERE/action.sh"

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  dir) printf '%s\n' "$DIR" ;;
  action) cmd_action "$@" ;;
  action-show) cmd_action_show "$@" ;;
  stranded) cmd_stranded ;;
  resume) cmd_resume "$@" ;;
  record) cmd_record "$@" ;;
  get) cmd_get "$@" ;;
  list) cmd_list ;;
  close) cmd_close "$@" ;;
  choice) cmd_choice "$@" ;;
  choices) cmd_choices "$@" ;;
  relay) cmd_relay "$@" ;;
  run) cmd_run "$@" ;;
  root) cmd_root "$@" ;;
  runs) cmd_runs ;;
  asks) cmd_asks ;;
  reports) cmd_reports ;;
  spec) cmd_spec "$@" ;;
  reentry) cmd_reentry; exit 0 ;;
  branch) cmd_branch "$@" ;;
  workspace) cmd_workspace "$@" ;;
  watch) cmd_watch ;;
  watch-install) cmd_watch_install "$@" ;;
  autostart) cmd_autostart "$@" ;;
  usage) cmd_usage "$@" ;;
  account) need_jq; as_account ;;
  held) cmd_held ;;
  usage-save) cmd_usage_save ;;
  events) cmd_events "$@" ;;
  prompts) cmd_prompts ;;
  states) cmd_states ;;
  sections) cmd_sections ;;
  orca) orca_cmd ;;
  setup-status) cmd_setup_status ;;
  *) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; [ -z "$sub" ] || exit 2 ;;
esac
