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
#   crew.sh release <KEY>             remove <KEY>'s workspace, only once its PR shows merged (asked
#                                     now; open and closed facts alike): through hi's wt.sh
#                                     remove-if-safe, which refuses a dirty or unpushed tree or a
#                                     busy agent. Not merged, no PR, or unreadable: refused, exit 3
#   crew.sh choice <KEY> <json>       append one answered ask to choices.jsonl: the options with
#                                     their loses:/leans on: lines, what the person took ("option",
#                                     "own" or "reframed"), their reply verbatim. Kept across close,
#                                     so a person's choices can be read back over many tickets
#   crew.sh relay <KEY> [--id <message_id>] [--action <action_id>] [--again] <reply-file>
#                                     THE way to answer a worker's question or decision gate: sends
#                                     the reply (orchestration reply) and appends its choices in the
#                                     same step. --id may be left out when <KEY> has one open ask.
#                                     Safe to repeat: an ask already answered is not sent again
#                                     ("already relayed <when>", exit 0); --again sends a second
#                                     answer (the person changed their mind), recorded as superseding.
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
#                                     switch): when its Orca pane is still open and its Claude
#                                     session can be found, that session gets a new Dispatch in
#                                     the pane, relaunched there first (`claude --resume`) when it
#                                     is no longer running; it keeps its chat (`resumed_in`: the
#                                     pane, `session`). Otherwise a new worker in its recorded
#                                     workspace and Run, on the spec copy under a "resuming" note,
#                                     the noted spec recorded as `resumed_spec` (<state dir>/specs/
#                                     <KEY>.resumed.md, for that dispatch: `resumed_for`). Either
#                                     way the new dispatch and task are recorded. Refuses when the
#                                     workspace is gone, the PR is merged or closed, or the worker
#                                     is still live (cmd_resume)
#   crew.sh adopt <KEY> --pr <url> [--title T] [--workspace P] [--repo SEL] [--brief-file F]
#                 [--background X]... [--root R]
#                                     hand an open github.com PR that another session drove to a
#                                     new worker under this session's Run, in the follow-up phase:
#                                     its spec is `spec --handover` (below), its workspace the one
#                                     given, else the PR repo's Orca workspace on the PR branch
#                                     (never the main checkout), else a new one created on that
#                                     branch from its remote (--repo: the Orca repo, when the PR's
#                                     repo has no workspace to infer it from). The facts, pr and
#                                     head included, are recorded before worker-start, so the watch
#                                     follows the PR from its first pass; then dispatch and task.
#                                     --brief-file: the team's per-ticket notes (the merge path,
#                                     which base the PR targets). --background: a previous
#                                     session's journal or chat, named in the spec as background
#                                     only. Title: T, else the tracker's, else the PR's. Refuses,
#                                     starting nothing: open facts for <KEY> (but those of an adopt
#                                     whose worker-start failed: run it again), no Run, a PR that
#                                     is not open or comes from a fork. Prints the receipt
#   crew.sh choices [<KEY>]           the recorded choices, one JSON object per line, each with
#                                     as_recommended derived (below)
#   crew.sh choices --gaps            answers to hi-crew asks with no choice line (sent without
#                                     relay), TSV: key, ask id, answered at, the ask's first line
#
# A choice line (choices.jsonl; stable, read back over many tickets, e.g. to learn a person's
# preferences): key, at, question, options [{name, loses, leans_on}], took (option | own |
# reframed | null), picked, reply (the person's words, verbatim), recommended (the option name
# the asker recommended, null when the ask made no recommendation; absent on lines written
# before it was recorded). relay adds ask (the message id), run, dispatch, asked_at, ask_body
# (the ask verbatim: its options are usually prose in it) and sent (the body relayed); a line
# relay --again wrote adds supersedes (the `at` of the answer it replaces); covered (true) marks a
# point one shared reply answered, not a reply of its own (cmd_relay). Lines written before
# replies were split may bundle several points in one line. New
# fields may be added; these keep their names and meaning. `choices` adds as_recommended, not
# stored: true when the person took the recommended option, false when they took another one,
# their own or reframed the question, null when there was no recommendation (or none recorded)
# or no decision (took null).
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
#                                     Orca's "Worker stopped without reporting" (the worker only
#                                     ended a turn) folds into the Dispatch's open ask, and with no
#                                     open ask shows only once the worker's terminal is gone.
#   crew.sh reports                   the latest worker_done per dispatch in those Runs, TSV:
#                                     run id, dispatch id, created_at, outcome, subject
#   crew.sh spec --key K --title T [--brief-file F] [--root R] [--no-profile]
#                                     the worker spec for a ticket, from reference/worker-spec.md and
#                                     the config keys crew.process and crew.marker, read at R (default:
#                                     `crew.sh root`). No crew.process and no team file at R is
#                                     refused (exit 2: R is most likely the wrong directory), unless
#                                     --no-profile: then the process is a generic line. A team file
#                                     with no crew.process gets that line too. In crew.process, {{ROOT}} becomes R, the
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
#   crew.sh spec ... --handover --pr URL [--workspace P] [--background X]...
#                                     the spec for a ticket whose open PR a worker takes over
#                                     (`adopt` builds it): the template's {{#HANDOVER}} blocks
#                                     replace its {{#FRESH}} ones (take the ticket, the already-done
#                                     check, open a draft PR, the ready gate) with "where it stands",
#                                     read from the PR with gh (state, draft or ready, base, CI,
#                                     review decision, open review threads), the ticket's status
#                                     from the tracker and the workspace P against the PR head,
#                                     and the follow-up phase: answer the threads, keep CI green,
#                                     merge the base in on a conflict, wait for QA. No second PR;
#                                     the ticket's status and draft/ready stay as they are. Each
#                                     X (a journal, a chat) is listed as background only
#   crew.sh reentry                   SessionStart(compact) hook, payload on stdin: in the session
#                                     of an open ticket's worker (its cwd in the ticket's
#                                     `workspace`), one context line naming the ticket and its spec
#                                     (the facts' `resumed_spec` while its worker is the recorded
#                                     dispatch, else `spec`)
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
#   crew.sh workspace --repo SEL --name N --branch B --base REF [--pr N] [--setup-timeout S]
#                                     create a top-level Orca workspace on branch B (no name prefix;
#                                     Orca adds a numeric suffix when B is taken, so read the branch
#                                     back from the workspace), and print its path. The repo's setup
#                                     runs per its Orca policy in a terminal of its own. When that
#                                     policy is wait-for-setup (the repo's hook settings or its
#                                     orca.yaml), this waits for the setup to finish, at most S
#                                     seconds (default 540; 0 does not wait): Orca gates only an
#                                     agent it starts with the workspace, never this create. Still
#                                     running then: the path is printed all the same, the spec
#                                     paragraph telling the worker to wait for it goes to stderr,
#                                     exit 3; add it to the spec before the start. Start the worker in it with
#                                     worker-start --worktree path:<path> --keep-open (a worker in
#                                     an existing workspace otherwise closes when it reports).
#                                     worker-start has no branch option
#   crew.sh watch                    look at the PR of every open ticket and, when something changed
#                                     since the last look, append it to the watch events and wake
#                                     whoever handles it. The worker itself, by a round sent to its
#                                     Dispatch: CI failed, new findings from review bots, a crew.bots
#                                     login's new plain comment (unless crew.bot_ignore_patterns
#                                     matches it), and an approval when crew.merge is on_green. The coordinator, by a
#                                     status message to its Run: merged or closed, new comments from
#                                     people, an approval otherwise, an approval that no longer
#                                     counts, a review re-requested from a person who reviewed
#                                     (whoever asked, a bot included), and a worker event no
#                                     Dispatch took. Bots' plain comments, a bot review with no findings, the
#                                     workers' own comments, labels and cross-references wake no one.
#                                     The first look at a ticket only records it.
#                                     A PR the ticket waits on (the facts' `waits_on`, a list of PR
#                                     urls, recorded at start or by the worker) that merges or
#                                     closes is told once, from any look, the first included: to the
#                                     worker as a round, else the coordinator.
#                                     A ticket with no `pr` yet gets its PR looked up with gh by the
#                                     workspace's branch, and recorded when found (the worker records
#                                     it itself at its draft-PR step: {{CREW}} in the spec)
#                                     A ticket's Orca workspace follows its PR: the PR linked on it
#                                     (a github.com PR on a workspace of the same repo, a GitLab
#                                     MR), and its board column moved through hi's wt.sh board
#                                     (a column set by hand stays): merged → Done; else the
#                                     tracker's done → Done, testing → QA, in_review → In review,
#                                     when the root configures a tracker; else a draft PR → In
#                                     progress, a ready one → In review. A PR closed unmerged, a
#                                     tracker that did not answer, moves nothing; with no PR yet
#                                     only the tracker moves it. No workspace, or no hi plugin: nothing
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
#                                     title, next, url, since; or section and error. See cmd_sections.
#                                     Then the built-in forge sections (lib/forge.sh): the person's
#                                     PRs no worker owns, and the reviews waiting on them
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
#    "findings": <count of review bots' findings>, "bot_comments": <count of crew.bots' plain comments
#    not ignored>, "approvals": [<logins of people who approve>],
#    "rerequested": [<logins of people asked to review again>]}
# with {{PR}}, {{ROOT}}, {{MARKER}}, {{BOTS}}, {{FINDING_PATTERNS}}, {{BOT_IGNORE_PATTERNS}} and
# {{BOT_SUMMONS}} replaced by the shell-quoted PR url, root, crew.marker, the JSON array of logins
# that are not people, the JSON arrays of crew.finding_patterns and crew.bot_ignore_patterns, and
# the JSON array of bot summons patterns (the defaults and crew.bot_summons). findings,
# bot_comments, approvals and rerequested are optional: a state
# without them never fires their events. An approval counts while its reviewer is not asked to
# review again; a login leaving `approvals` is "no longer counts", and a new one in `rerequested`
# (a person with an earlier review on the PR who is asked again) is a re-request. A first
# request, such as a gatekeeper assigning reviewers, is neither.
# Not people: a [bot] login, a forge Bot account, the forge Actions users (github-actions,
# forgejo-actions, gitea-actions) and every login in crew.bots (a list; a team's AI reviewer or
# gatekeeper on a normal account goes there). A comment is a person's when its author is a person
# and it is not the workers' own: it does not start with the marker, or with the marker extended
# inside its brackets ("(agent, ...) ..."), after any leading @mentions ("@bot (agent) ..." is
# the worker's, "> (agent)" quoted by a person is not); an approval's text counts as the approval, not as a
# comment. Nor is the workers' bot summons a person's: a comment by the login gh is signed in as
# that is only a command to a review bot ("@coderabbitai review", "@codex review"; the defaults
# plus crew.bot_summons, regexes matched against the whole comment), which the worker cannot mark
# because the bot then ignores it. Another login's summons is a person's.
# A finding is a not-a-person's inline review comment, its review requesting changes, or
# its review whose body matches one of crew.finding_patterns (a list of regexes, empty by default):
# a review bot that puts some findings only in the review body ("outside the diff" sections) is
# named by the marker those sections carry, which its summary-only reviews lack. An invalid
# pattern matches nothing. A change to the list fires no findings on the next pass.
# A plain comment (not a review, not inline) by a crew.bots login goes to the worker unless its
# body matches one of crew.bot_ignore_patterns (a list of regexes, empty by default): no one knows
# which bots will come or what they will say, so an unknown bot's word reaches the worker and the
# team silences the noise it knows (an "all clear", "Auto-assigned reviewers"). The forge Actions
# users and Bot accounts (Apps) are not on it: their plain comments are CI summaries rewritten on
# every push, and an App's review findings already come as findings. A change to the list fires
# nothing on the next pass.
# Unset, a github.com PR is read with gh. The command runs from an automation, outside any
# terminal, so it must find its own credentials; the precheck runs it in a login interactive shell.
#
# State dir: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/crew
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
TEMPLATE="$HERE/../reference/worker-spec.md"
DIR="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/crew"
# hi's wt.sh (the hi plugin beside this one): the board column and a workspace's removal go
# through it, so its rules hold here too (a hand move on the board wins; nothing unsafe is removed).
WT_SH="${HI_WT_SH:-$HERE/../../hi/lib/wt.sh}"
# The facts' `workspace` as a path (jq). /hi-crew:start records what worker-start answered,
# Orca's worktree id "<repo id>::<path>"; autostart records the bare path. Both read as the path.
WS_PATH='.workspace // empty | sub("^[^/]*::"; "")'

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
  rm -f "$DIR/watch/$1.json" "$DIR/watch/$1.prompt" "$DIR/watch/$1.tool" "$DIR/watch/$1.waits" \
    "$DIR/watch/$1.linked" "$DIR/watch/$1.board"
}

# The facts of <KEY>: open, else the newest closed copy. Exit 1 when there are none.
facts_any() { # <KEY>
  local f c
  f=$(keyfile "$1") || exit 2
  [ -f "$f" ] && { cat "$f"; return 0; }
  # closed/<KEY>.<UTC stamp>.json: the stamp starts with a digit, so "A-1" does not take "A-1.2".
  c=$(ls "$DIR/closed/$1".[0-9]*.json 2>/dev/null | sort | tail -1)
  [ -n "$c" ] && [ -f "$c" ] || return 1
  cat "$c"
}

# release <KEY>: remove the ticket's workspace, only once its PR shows merged. The state is asked
# now (wait_state), not taken from the watch's last look; anything but merged refuses (exit 3),
# a PR closed unmerged included: its work is in no trunk. Merged, the removal is hi's
# `wt.sh remove-if-safe`, which still refuses a dirty or unpushed tree, a busy agent, a head past
# the merged one (its `unsafe` lines, exit 3). Works on open and closed facts alike, so the agenda
# can offer it before or after `close`. A workspace already gone: said, exit 0.
cmd_release() {
  [ $# -eq 1 ] || die 'usage: release <KEY>'
  need_jq
  local t ws pr st rc
  t=$(facts_any "$1") || die "no facts for $1"
  ws=$(printf '%s' "$t" | jq -r "$WS_PATH")
  pr=$(printf '%s' "$t" | jq -r '.pr // empty')
  [ -n "$ws" ] || die "$1 has no workspace recorded"
  if [ ! -d "$ws" ]; then printf 'crew: %s: its workspace %s is already gone\n' "$1" "$ws" >&2; return 0; fi
  [ -n "$pr" ] || { printf 'crew: %s has no PR recorded: its workspace stays (removed only once its PR merged)\n' "$1" >&2; return 3; }
  st=$(wait_state "$t" "$pr" </dev/null) || { printf 'crew: %s: cannot read the state of %s: its workspace stays\n' "$1" "$pr" >&2; return 3; }
  [ "$st" = merged ] || { printf 'crew: %s: %s is %s, not merged: its workspace stays\n' "$1" "$pr" "$st" >&2; return 3; }
  [ -f "$WT_SH" ] || die "release needs hi's wt.sh (the hi plugin), not found at $WT_SH"
  bash "$WT_SH" --repo "$ws" remove-if-safe "$ws" </dev/null; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$(keyfile "$1")" ] && (cmd_record "$1" "$(jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{released_at: $at}')")
  return "$rc"
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

# relayed_last <KEY> <jq filter> <value>: the filter's output ($v is <value>) for the last of
# <KEY>'s delivered answers to an ask, empty when none matches. A line marked undelivered (Orca
# refused the reply) is no answer the worker got; one recorded by hand with `choice` after relay
# said "sent but not recorded" carries the ask id and counts.
relayed_last() {
  [ -f "$DIR/choices.jsonl" ] || return 0
  jq -r --arg key "$1" --arg v "$3" "select(.key == \$key and (.ask // \"\") != \"\" and (.undelivered | not)) | $2" \
    "$DIR/choices.jsonl" 2>/dev/null | tail -1
}

# relay <KEY> [--id <message_id>] [--action <action_id>] [--again] <reply-file>: answer a worker's question or decision gate and
# record the person's choices in one step. The reply file is JSON:
#   {"body": "<the text sent to the worker>",
#    "points": [{"question":…, "options":[{"name":…,"loses":…,"leans_on":…}],
#                "recommended":<option name>|null,
#                "took":"option"|"own"|"reframed", "picked":…, "reply":"<their words, verbatim>"}],
#    "reply": "<the person's words, verbatim, when one reply answers several points>"}
# Everything is checked before the reply goes out, so a refusal sends nothing. Each point becomes
# one choices.jsonl line, with the ask's id, Run, Dispatch, time and verbatim text added, and
# recommended null when the point leaves it out; an empty "points" still writes one line (took
# null), so a relayed reply never shows as a gap.
# One reply for several points ("yes, send it" closing five): "points" lists every point the ask
# named and the top-level "reply" covers each point with no "reply" of its own: took defaults to
# "option", picked to the point's recommended, reply is the shared one, and the line is marked
# covered (true). A point the person answered otherwise carries its own took/picked/reply and is
# kept as given. A covered point that ends up taking an option with nothing to pick (no picked, no
# recommended) refuses the relay.
# --action <id>: the person said yes to the worker's prepared action (lib/action.sh). It runs
# once, here, before the reply goes out, and the reply starts with its outcome; the body follows
# as the person's words. A reply Orca refuses (the worker is gone) is kept for `stranded`, and its
# choice lines are still written, marked undelivered: the person decided all the same.
# Idempotent per ask: a coordinator can be handed one answer twice (its session resumed again,
# say). When an answer to this ask is already delivered, relay sends, runs and writes nothing,
# prints "already relayed <when>" and exits 0. An undelivered line does not count, so a retry
# after a refused send still goes out. --again sends all the same, for the person's deliberate
# second answer; its lines carry supersedes, the `at` of the answer they replace.
# On success it prints one line: relayed <KEY> <what was picked> → <dispatch>.
cmd_relay() {
  local key='' id='' file='' aid='' again='' ask reply recs out body outcome prev
  local usage='usage: relay <KEY> [--id <message_id>] [--action <action_id>] [--again] <reply-file>'
  while [ $# -gt 0 ]; do
    case "$1" in
      --id) id=${2:-}; shift 2 ;;
      --action) aid=${2:-}; [ -n "$aid" ] || die "$usage"; shift 2 ;;
      --again) again=1; shift ;;
      -*) die "relay: unknown argument '$1'" ;;
      *) if [ -z "$key" ]; then key=$1; elif [ -z "$file" ]; then file=$1; else die "$usage"; fi; shift ;;
    esac
  done
  [ -n "$key" ] && [ -n "$file" ] || die "$usage"
  need_jq
  keyfile "$key" >/dev/null || exit 2
  [ -f "$file" ] || die "relay: no reply file: $file"
  reply=$(jq -ce 'select(type == "object" and (.body | type) == "string" and .body != ""
                         and ((.points // []) | type) == "array" and all((.points // [])[]; type == "object")
                         and ((.reply // "") | type) == "string")' "$file" 2>/dev/null) \
    || die 'relay: the reply file must be a JSON object with a non-empty "body", a "points" array of objects and, if any, a string "reply"'
  # A point the shared reply covers takes its recommended option; with none, the reply picks nothing.
  out=$(printf '%s' "$reply" | jq -r 'select((.reply // "") != "") | (.points // []) | to_entries[]
        | select((.value | has("reply") | not) and (.value.took // "option") == "option"
                 and (.value.picked // .value.recommended) == null)
        | "point \(.key + 1) (\(.value.question // "no question"))"' | paste -sd ' ' -)
  [ -z "$out" ] || die "relay: the shared reply covers $out, which names no recommended option to take; give it its own took/picked/reply. Nothing sent"
  if [ -z "$id" ]; then
    local d ids
    d=$(cmd_get "$key" 2>/dev/null | jq -r '.dispatch // empty')
    [ -n "$d" ] || die "relay: no dispatch recorded for $key; pass --id <message_id>"
    ids=$(cmd_asks | awk -F'\t' -v d="$d" '($2 == "question" || $2 == "decision_gate") && $4 == d { print $1 }')
    if [ -z "$ids" ] && [ -z "$again" ]; then
      # An answered ask leaves the open ones: a repeat with no --id finds none. The last answer
      # this Dispatch was delivered says it is a repeat, not a mistake.
      prev=$(relayed_last "$key" 'select(.dispatch == $v) | "\(.at) (\(.ask))"' "$d")
      [ -z "$prev" ] || { printf 'already relayed %s; %s has no open question\n' "$prev" "$key"; return 0; }
    fi
    [ -n "$ids" ] || die "relay: $key has no open question; pass --id <message_id>"
    [ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" -eq 1 ] \
      || die "relay: $key has several open questions ($(printf '%s' "$ids" | tr '\n' ' ')); pass --id"
    id=$ids
  fi
  ask=$(inbox | jq -ce --arg id "$id" 'map(select(.id == $id)) | first
        | select(.type == "question" or .type == "decision_gate")') \
    || die "relay: $id is not a question or decision gate in a hi-crew Run"
  prev=$(relayed_last "$key" 'select(.ask == $v) | .at' "$id")
  if [ -n "$prev" ] && [ -z "$again" ]; then
    printf 'already relayed %s (%s %s); nothing sent. --again sends a second answer\n' "$prev" "$key" "$id"
    return 0
  fi
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
      --arg prev "$prev" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    ($a.payload // "{}" | fromjson? // {}) as $p
    | {key: $key, at: $now, ask: $a.id, run: $a.run_id, dispatch: $a.dispatch, asked_at: $a.created_at,
       ask_body: ($a.body // $p.question // ""), sent: $sent}
      + (if $aid != "" then {action: $aid} else {} end)
      + (if $prev != "" then {supersedes: $prev} else {} end) as $base
    | (if ($r.points // []) == [] then [{question: null, took: null}]
       elif ($r.reply // "") == "" then $r.points
       else $r.points | map(if has("reply") then .
         else {took: "option"} + . | {picked: .recommended} + . + {reply: $r.reply, covered: true} end) end)[]
    | {key: $key, at: $now, question: null, recommended: null}
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
  if printf '%s\n' "$recs" >>"$DIR/choices.jsonl"; then
    printf 'relayed %s %s → %s\n' "$key" \
      "$(printf '%s\n' "$recs" | jq -rs 'if .[0].question == null and .[0].took == null and length == 1 then "(no points)"
        else map(.picked // .took // "?" | tostring) | join(", ") end')$([ -z "$prev" ] || printf ' (again, supersedes %s)' "$prev")" \
      "$(printf '%s' "$ask" | jq -r '.dispatch // "?"')"
    return 0
  fi
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
  [ $# -eq 0 ] || keyfile "$1" >/dev/null || exit 2
  jq -c --arg key "${1:-}" "select(\$key == \"\" or .key == \$key) | $CHOICE_AS_RECOMMENDED" "$DIR/choices.jsonl"
}

# as_recommended, derived when read (see the choice line above). Names compare trimmed and
# case-blind, so "Option A" picked against a recommended "option a" still counts as taken.
CHOICE_AS_RECOMMENDED='def nm: tostring | ascii_downcase | sub("^\\s+"; "") | sub("\\s+$"; "");
  . + {as_recommended: (if .recommended == null or .took == null then null
    else (.took == "option" and .picked != null and (.picked | nm) == (.recommended | nm)) end)}'

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
  local m resumed rows open line d; m=$(inbox) || exit $?
  # The Dispatches `resume` replaced: their escalation (the worker lost) is handled.
  resumed=$(cmd_list | jq -sc 'map(.resumed // []) | add // []') || resumed='[]'
  # Each row: id, type, run, dispatch, created_at, stopReason, terminal handle, first line.
  rows=$(printf '%s' "$m" | jq -r --argjson resumed "$resumed" '
    . as $m
    | [ $m[] | select(.thread_id != null and .thread_id != .id) | .thread_id ] as $answered
    | $m[]
    | select(.type == "question" or .type == "decision_gate" or .type == "escalation")
    | select(.id as $id | $answered | index($id) | not)
    | select(.type != "escalation" or
        (. as $e | [ $m[] | select(.type == "worker_done" and .dispatch == $e.dispatch
                                   and .created_at > $e.created_at) ] | length == 0
                   and ($resumed | index($e.dispatch) | not)))
    | (.payload // "{}" | fromjson? // {}) as $p
    | [ .id, .type, .run_id, .dispatch, .created_at, ($p.stopReason // ""), ($p.handle // ""),
        ((.body // .subject // "") | split("\n")[0]) ] | @tsv' \
    | while IFS= read -r line; do
        case "$(printf '%s' "$line" | cut -f2)" in
          question|decision_gate) dispatch_live "$(printf '%s' "$line" | cut -f4)" || continue ;;
        esac
        printf '%s\n' "$line"
      done)
  [ -n "$rows" ] || return 0
  # Orca's "Worker stopped without reporting" (stopReason finished) only says the worker ended a
  # turn with no worker_done. A worker that asked does exactly that, by design, and so does one
  # back at its prompt after a watch round: that notice folds into its open ask, and with no open
  # ask it is listed only once the worker's terminal is gone (highness#125). Every other stop
  # (lost, exited, errored, a usage limit) is listed as it came.
  open=$(printf '%s\n' "$rows" | awk -F'\t' '($2 == "question" || $2 == "decision_gate") && $4 != "" { print $4 }')
  printf '%s\n' "$rows" | while IFS= read -r line; do
    if [ "$(printf '%s' "$line" | cut -f2,6)" = "$(printf 'escalation\tfinished')" ]; then
      d=$(printf '%s' "$line" | cut -f4)
      [ -n "$d" ] && printf '%s\n' "$open" | grep -qxF -- "$d" && continue
      terminal_open "$(printf '%s' "$line" | cut -f7)" && continue
    fi
    printf '%s\n' "$line" | cut -f1-5,8
  done
}

# Whether a worker's terminal is still open in Orca. No handle, a stale one (the terminal was
# closed) or no answer is not proven open, so a notice that depends on it stays listed.
terminal_open() {
  [ -n "$1" ] || return 1
  "$(orca_cmd)" terminal show --terminal "$1" --json 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1
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
  local key='' title='' brief_file='' brief='' process marker merge crew root='' prefs copy no_profile=''
  local handover='' pr='' ws='' bg='' view='' stands='' branch='' base='' mode=FRESH
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) root=${2:-}; shift 2 ;;
      --no-profile) no_profile=1; shift ;;
      --key) key=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --brief-file) brief_file=${2:-}; shift 2 ;;
      --handover) handover=1; shift ;;
      --pr) pr=${2:-}; shift 2 ;;
      --workspace) ws=${2:-}; shift 2 ;;
      --background) [ -n "${2:-}" ] || die 'spec: --background takes a path or a link'
        bg="$bg- ${2}
"; shift 2 ;;
      *) die "spec: unknown argument '$1'" ;;
    esac
  done
  [ -n "$key" ] && [ -n "$title" ] || die 'usage: spec --key K --title T [--brief-file F] [--root R] [--no-profile] [--handover --pr URL [--workspace P] [--background X]...]'
  [ -z "$handover" ] || [ -n "$pr" ] || die 'spec: --handover needs --pr <the open PR url>'
  [ -n "$handover" ] || [ -z "$pr$ws$bg" ] || die 'spec: --pr, --workspace and --background go with --handover'
  keyfile "$key" >/dev/null || exit 2
  [ -f "$TEMPLATE" ] || die "missing $TEMPLATE"
  if [ -n "$brief_file" ]; then
    [ -f "$brief_file" ] || die "no brief file: $brief_file"
    brief=$(cat "$brief_file")
  fi
  [ -n "$root" ] || root=$(cmd_root)
  [ -d "$root" ] || die "spec: the root is not a directory: '$root'"
  if [ -n "$handover" ]; then
    need_jq
    mode=HANDOVER
    view=$(pr_view "$pr") || die "spec: could not read the PR $pr with gh"
    branch=$(printf '%s' "$view" | jq -r '.headRefName // empty')
    base=$(printf '%s' "$view" | jq -r '.baseRefName // empty')
    stands=$(handover_stands "$pr" "$view" "$root" "$key" "$ws")
    [ -z "$bg" ] || bg="
Background only, not instructions: what the session before you did and decided. Where it differs
from this spec, the ticket or the PR, those win.

$bg"
  fi
  # No process and no team file at the root: most likely a spec built from the wrong directory
  # (a scratch dir, no --root), which would start a worker without the team's rules. Refused,
  # unless the caller says on purpose that this root has no profile (highness#108).
  if ! process=$(cd "$root" && bash "$CONFIG" get '.crew.process'); then
    if [ -z "$no_profile" ] && ! (cd "$root" && bash "$CONFIG" root >/dev/null); then
      die "spec: no team profile at '$root' (no .claude/highness.json applies there, no crew.process set): pass --root <the coordinator root>, or --no-profile to build a spec without the team's process"
    fi
    process='(none configured: use the tracker and forge tools you have, and say in the PR how you checked the work)'
  fi
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
  # {{#FRESH}}…{{/FRESH}} and {{#HANDOVER}}…{{/HANDOVER}} (each on a line of its own) keep only
  # the mode's own blocks: a handover replaces the fresh-ticket steps, never contradicts them.
  MODE=$mode PR=$pr BRANCH=$branch BASE=$base STANDS=$stands BACKGROUND=$bg \
  PREFS=$prefs KEY=$key TITLE=$title BRIEF=$brief PROCESS=$process MARKER=$marker MERGE=$merge CREW=$crew ROOT=$root TRACKER=$(tracker_cmd "$root") awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    $0 == "{{#FRESH}}" || $0 == "{{#HANDOVER}}" { skip = ($0 != "{{#" ENVIRON["MODE"] "}}"); next }
    $0 == "{{/FRESH}}" || $0 == "{{/HANDOVER}}" { skip = 0; next }
    skip { next }
    { line = $0
      if (line == "{{STANDS}}") { print ENVIRON["STANDS"]; next }
      if (line == "{{BACKGROUND}}") { if (ENVIRON["BACKGROUND"] != "") printf "%s", ENVIRON["BACKGROUND"]; next }
      line = rep(line, "{{PR}}", ENVIRON["PR"])
      line = rep(line, "{{BRANCH}}", ENVIRON["BRANCH"])
      line = rep(line, "{{BASE}}", ENVIRON["BASE"])
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
# ticket's workspace this prints one context line naming the spec to re-read: after a resume the
# copy with the resume note (`resumed_spec`), unless a later start recorded another dispatch. The
# spec itself is never inlined (it is long). Every error is silence: a session start must never
# fail on it.
cmd_reentry() {
  local in cwd real f row="" key title spec pr msg
  in=$(head -c 16384 2>/dev/null); cat >/dev/null 2>&1
  command -v jq >/dev/null 2>&1 || return 0
  cwd=$(printf '%s' "$in" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$cwd" ] || cwd=$PWD
  real=$(cd "$cwd" 2>/dev/null && pwd -P) || real=$cwd
  for f in "$DIR"/*.json; do
    [ -f "$f" ] || continue
    row=$(jq -r --arg a "$cwd" --arg b "$real" '
      (.workspace // "" | sub("^[^/]*::"; "")) as $w | select($w != "")
      | select([$a, $b] | any(. == $w or startswith($w + "/")))
      | (if (.resumed_spec // "") != "" and .resumed_for == .dispatch then .resumed_spec else (.spec // "") end) as $s
      | [.key, (.title // ""), $s, (.pr // "")] | @tsv' "$f" 2>/dev/null) || continue
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
  local repo='' name='' branch='' base='' timeout=540 out path err prn=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --setup-timeout) timeout=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --name) name=${2:-}; shift 2 ;;
      --branch) branch=${2:-}; shift 2 ;;
      --base) base=${2:-}; shift 2 ;;
      --pr) prn=${2:-}; shift 2 ;;
      *) die "workspace: unknown argument '$1'" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$name" ] && [ -n "$branch" ] && [ -n "$base" ] \
    || die 'usage: workspace --repo SEL --name N --branch B --base REF [--pr N] [--setup-timeout S]'
  case "$timeout" in ''|*[!0-9]*) die "workspace: --setup-timeout takes seconds, not '$timeout'" ;; esac
  case "$prn" in *[!0-9]*) die "workspace: --pr takes a PR number, not '$prn'" ;; esac
  out=$("$(orca_cmd)" worktree create --repo "$repo" --name "$name" --branch "$branch" --base-branch "$base" \
    ${prn:+--pr "$prn"} --no-parent --json 2>&1)
  path=$(printf '%s' "$out" | jq -r 'select(.ok == true) | .result.worktree.path // empty' 2>/dev/null) || path=''
  if [ -z "$path" ]; then
    err=$(first_err "$out"); [ -n "$err" ] || err=$(printf '%s\n' "$out" | head -1)
    die "workspace: orca worktree create failed: ${err:-no path in its answer}"
  fi
  # A wait-for-setup repo: Orca gates only an agent it starts itself, never this plain create.
  ws_wait_setup "$repo" "$path" "$timeout" || {
    printf '%s\n' "$path"
    setup_note "$(ws_runner "$path")" >&2
    exit 3
  }
  printf '%s\n' "$path"
}

# The setup runner Orca writes for a workspace (<git dir>/orca/setup-runner.sh), absolute.
ws_runner() {
  local r
  r=$(git -C "$1" rev-parse --git-path orca/setup-runner.sh 2>/dev/null) || return 0
  case "$r" in /*) ;; *) r="$1/$r" ;; esac
  printf '%s\n' "$r"
}

# Whether Orca's policy for the repo is wait-for-setup: the repo's own hook settings or a committed
# orca.yaml (Orca waits when either says so).
ws_policy_waits() { # <repo selector> <workspace path>
  local p
  p=$("$(orca_cmd)" repo show --repo "$1" --json 2>/dev/null \
    | jq -r '.result | (.repo // .) | .hookSettings.setupAgentStartupPolicy // empty' 2>/dev/null) || p=''
  [ "$p" = wait-for-setup ] && return 0
  [ -f "$2/orca.yaml" ] && grep -Eq "^setupAgentStartupPolicy:[[:space:]]*[\"']?wait-for-setup" "$2/orca.yaml"
}

# Whether the runner's command shows in one of the workspace's terminals: Orca types it there.
ws_runner_typed() { # <workspace path> <runner>
  local h
  for h in $("$(orca_cmd)" terminal list --worktree "path:$1" --json 2>/dev/null \
    | jq -r '.result.terminals[]?.handle // empty' 2>/dev/null); do
    "$(orca_cmd)" terminal read --terminal "$h" --json 2>/dev/null \
      | jq -r '.result.terminal.tail[]? // empty' 2>/dev/null | grep -Fq "$2" && return 0
  done
  return 1
}

ws_runner_running() { ps -A -o args= 2>/dev/null | grep -F "$1" | grep -Fvq 'grep -F'; }

# Wait until the workspace's Orca setup is done, when its repo's policy is wait-for-setup and Orca
# wrote a runner (none: setup is off for it). Orca reports nothing for a plain create, so: done is
# the runner seen (a process running it, or its command typed in a terminal) and then no process
# running it on two looks in a row. Exit 1 when it still runs after <timeout> seconds.
ws_wait_setup() { # <repo selector> <workspace path> <timeout seconds>
  local runner seen='' gone=0 deadline
  [ "${3:-0}" -gt 0 ] 2>/dev/null || return 0
  runner=$(ws_runner "$2"); [ -n "$runner" ] && [ -f "$runner" ] || return 0
  ws_policy_waits "$1" "$2" || return 0
  deadline=$(($(date +%s) + $3))
  while :; do
    if ws_runner_running "$runner"; then
      seen=1; gone=0
    else
      [ -n "$seen" ] || ! ws_runner_typed "$2" "$runner" || seen=1
      [ -z "$seen" ] || gone=$((gone + 1))
      [ "$gone" -lt 2 ] || return 0
    fi
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep "${HI_CREW_SETUP_POLL:-1}"
  done
}

# The spec paragraph for a worker started while its workspace's setup still runs.
setup_note() { # <runner>
  cat <<EOF

## Workspace setup still running

This workspace's Orca setup (the repo waits for it before work starts) was still running when you
were started. Before you install, build, test or commit anything, wait until it is done: this
prints nothing once it is (run it again until then; do not sleep-poll in the foreground, use a
background wait):

    ps -A -o args= | grep -F $(q "$1") | grep -Fv 'grep -F'

Its output is in the workspace's Setup terminal. If it failed, say so to the coordinator before
you go on.
EOF
}

# One shell word: 'it''s' -> 'it'\''s'.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The PR state of a github.com PR when the team set no crew.pr_state. Inline review comments come
# from the REST API (gh pr view has none). gh pr view reads comments and reviews through GraphQL,
# whose author is a bare login: "coderabbitai", never "coderabbitai[bot]", and no type. So the
# Bot accounts among the authors of comments and reviews are read through REST too (user.type),
# by login without the [bot] suffix. When a REST call fails the whole state fails, so a missing
# list never reads as findings gone and then back, or a bot's comment as a person's.
gh_state() { # <pr url> <marker> <bots json array> [<finding patterns json array>] [<bot ignore patterns json array>] [<summons json array>]
  local view api n inline typed page me
  view=$(gh pr view "$1" --json state,isDraft,headRefOid,statusCheckRollup,comments,reviews,latestReviews,reviewRequests 2>/dev/null) || return 1
  # The login the workers post under: only its summons are theirs. Unknown, every summons counts.
  me=$(gh api user -q .login 2>/dev/null) || me=''
  api=$(printf '%s\n' "$1" | sed -n 's#^https://github\.com/\([^/]*\)/\([^/]*\)/pull/\([0-9][0-9]*\).*#repos/\1/\2 \3#p')
  inline='[]' typed='[]'
  if [ -n "$api" ]; then
    n=${api#* } api=${api% *}
    inline=$(gh api --paginate "$api/pulls/$n/comments" 2>/dev/null) || return 1
    inline=$(printf '%s' "$inline" | jq -sc 'add // []') || return 1
    typed=''
    for page in "issues/$n/comments" "pulls/$n/reviews"; do
      page=$(gh api --paginate "$api/$page" 2>/dev/null) || return 1
      typed="$typed$page"
    done
    typed=$(printf '%s' "$typed" | jq -sc '[add // [] | .[] | .user | select(.type == "Bot") | .login // "" | sub("\\[bot\\]$"; "")] | unique') || return 1
  fi
  printf '%s' "$view" | jq -c --arg m "$2" --argjson bots "${3:-[]}" --argjson pats "${4:-[]}" \
      --argjson ignore "${5:-[]}" --argjson summons "${6:-[]}" --arg me "$me" --argjson inline "$inline" --argjson typed "$typed" '
    # Not a person: a [bot] login, a forge Bot account (by type, or by login when the source
    # has no type), or a login on the bots list.
    def bot($l; $t): ($l | test("\\[bot\\]$")) or $t == "Bot" or any($bots[], $typed[]; . == $l);
    # Leading @mentions go first: a worker answering a review bot addresses it ("@bot (agent) ...").
    def own: (.body // "" | sub("^(\\s*@\\S+)*\\s*"; "")) as $b | ($b | startswith($m))
             or (($m | endswith(")")) and ($b | startswith(($m | rtrimstr(")")) + ",")));
    ([.comments[]? | {who: (.author.login // ""), at: (.updatedAt // .createdAt // ""), body}]
     + [.reviews[]? | select(.state != "PENDING")
        | {who: (.author.login // ""), at: (.submittedAt // ""), body, state}]
     + [$inline[]? | {who: (.user.login // ""), type: (.user.type // ""), at: (.updated_at // .created_at // ""), body,
                      inline: true}]
     | map(. + {bot: bot(.who; .type // "")})) as $all
    # A workers bot summons: a comment by the login gh posts under that is only a command to a
    # review bot ("@coderabbitai review"), which a worker cannot mark (the bot then ignores the
    # command). An invalid pattern matches nothing; anything more than the command, or a summons
    # by another login, is a comment from people.
    | def summons: (.body // "" | gsub("^\\s+|\\s+$"; "")) as $b
                   | $me != "" and .who == $me
                     and any($summons[]; . as $p | try ($b | test("^(?:" + $p + ")$"; "i")) catch false);
    # A person: what they wrote, apart from an approval (its own event), the workers own words and
    # a bot summons.
      [$all[] | select((.bot | not) and (own | not) and (summons | not) and (.body // "") != ""
                       and .state != "APPROVED")] as $people
    # A review bot finding: its inline comment, its review that requests changes, or its review
    # whose body matches a finding pattern (an invalid one matches nothing). Its plain comments (a
    # CI summary rewritten on every push) and a review with none of these find nothing.
    | def body_finding: (.body // "") as $b | any($pats[]; . as $p | try ($b | test($p)) catch false);
      [$all[] | select(.bot and (.inline or .state == "CHANGES_REQUESTED"
                                 or (.state != null and body_finding)))] as $found
    # A named bot (a crew.bots login, not a forge Actions user or App) writing a plain comment:
    # the worker reads it unless it matches a crew.bot_ignore_patterns (known noise). An unknown
    # bot is not known to be noise.
    | ($bots - ["github-actions", "forgejo-actions", "gitea-actions"] - $typed) as $named
    | def ignored: (.body // "") as $b | any($ignore[]; . as $p | try ($b | test($p)) catch false);
      [$all[] | select(.state == null and (.inline | not) and (.body // "") != ""
                       and (.who as $l | $named | index($l)) and (ignored | not))] as $said
    # Re-requested: a person asked to review again, after a review of theirs. A first request (a
    # gatekeeper assigning reviewers) is not one, and a re-requested approval does not count.
    | [.reviewRequests[]? | .login // empty | select(. != "" and (bot(.; "") | not))] as $asked
    | [$asked[] | select(. as $l | any($all[]; .state != null and .who == $l))] as $again
    | { state: (.state | ascii_downcase), draft: .isDraft, head: .headRefOid,
        ci: ([.statusCheckRollup[]? | (.conclusion // .state // "" | ascii_upcase)] as $c
             | if ($c | length) == 0 then ""
               elif any($c[]; . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT") then "failure"
               elif all($c[]; . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "success"
               else "pending" end),
        people_at: ($people | map(.at) | max // ""),
        people: ($people | length),
        findings: ($found | length),
        bot_comments: ($said | length),
        approvals: ([.latestReviews[]? | select(.state == "APPROVED") | .author.login // ""
                     | select(. != "" and (bot(.; "") | not) and (. as $l | $asked | index($l) | not))] | unique),
        rerequested: ($again | unique) }'
}

# A github.com PR as a handover reads it: one JSON object from gh pr view. Exit 1 when it is not a
# github.com PR url or gh cannot read it.
pr_view() { # <pr url>
  case "$1" in https://github.com/*/*/pull/[0-9]*) ;; *) return 1 ;; esac
  gh pr view "$1" --json number,title,url,state,isDraft,headRefName,headRefOid,baseRefName,isCrossRepository,reviewDecision,mergeable,statusCheckRollup 2>/dev/null
}

# "Where it stands" for a handover spec, one bullet per line: the PR (state, draft or ready, base,
# head), CI, the review decision and the open review threads (a GraphQL read: gh pr view has no
# threads), the ticket's status from the team's tracker, and the workspace against the PR head.
# What cannot be read says so; it never fails the spec.
handover_stands() { # <pr url> <pr view json> <root> <key> [<workspace>]
  local api o r n threads t ws=${5:-} head cur ahead behind
  printf '%s' "$2" | jq -r '
    "- The PR: \(.state | ascii_downcase), \(if .isDraft then "a draft" else "ready for review" end), base `\(.baseRefName)`, head `\(.headRefName)` at \(.headRefOid[0:8])\(if .mergeable == "CONFLICTING" then "; it conflicts with its base" else "" end).",
    ([.statusCheckRollup[]? | {n: (.name // .context // "?"), c: (.conclusion // .state // "" | ascii_upcase)}] as $c
     | [$c[] | select(.c | test("^(FAILURE|ERROR|CANCELLED|TIMED_OUT)$")) | .n] as $bad
     | "- CI: " + (if ($c | length) == 0 then "no checks reported"
                   elif ($bad | length) > 0 then "failing (\($bad | join(", ")))"
                   elif all($c[]; .c | test("^(SUCCESS|NEUTRAL|SKIPPED)$")) then "green"
                   else "pending" end) + "."),
    "- Review decision: \(.reviewDecision // "" | if . == "" then "none yet" else ascii_downcase | gsub("_"; " ") end)."'
  api=$(printf '%s\n' "$1" | sed -n 's#^https://github\.com/\([^/]*\)/\([^/]*\)/pull/\([0-9][0-9]*\).*#\1 \2 \3#p')
  o=${api%% *}; r=${api#* }; r=${r%% *}; n=${api##* }
  threads=$(gh api graphql -f o="$o" -f r="$r" -F n="$n" -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved isOutdated path line comments(first:1){nodes{author{login} body}}}}}}}' 2>/dev/null \
    | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved | not)] as $o
      | "- Open review threads: \($o | length)\(if ($o | length) > 0 then ":" else "." end)",
        ($o[0:15][] | "  - `\(.path)\(if .line then ":\(.line)" else "" end)`\(if .isOutdated then " (outdated)" else "" end), \(.comments.nodes[0].author.login // "?"): \(.comments.nodes[0].body // "" | split("\n")[0] | .[0:120])"),
        (if ($o | length) > 15 then "  - … and \(($o | length) - 15) more on the PR" else empty end)' 2>/dev/null) || threads=''
  [ -n "$threads" ] || threads='- Open review threads: could not be read; read them on the PR.'
  printf '%s\n' "$threads"
  t=$(bash "$HERE/tracker.sh" --root "$3" read "$4" 2>/dev/null | jq -r '"\(.status // "?")\(if .role then " (\(.role))" else "" end)"' 2>/dev/null) || t=''
  printf -- '- The ticket: %s.\n' "${t:-status unknown (no tracker answered); read it yourself}"
  [ -n "$ws" ] || return 0
  head=$(printf '%s' "$2" | jq -r '.headRefOid')
  cur=$(git -C "$ws" rev-parse HEAD 2>/dev/null) || cur=''
  if [ -z "$cur" ]; then printf -- '- This workspace: %s (not a git checkout?).\n' "$ws"
  elif [ "$cur" = "$head" ]; then printf -- '- This workspace: %s, at the PR head.\n' "$ws"
  else
    ahead=$(git -C "$ws" rev-list --count "$head..HEAD" 2>/dev/null) || ahead='?'
    behind=$(git -C "$ws" rev-list --count "HEAD..$head" 2>/dev/null) || behind='?'
    printf -- '- This workspace: %s, at %s: %s commit(s) not on the PR, %s on the PR not here. Bring it level with the PR (pull, or push what is yours) before anything else.\n' "$ws" "${cur%"${cur#????????}"}" "$ahead" "$behind"
  fi
  [ -z "$(git -C "$ws" status --porcelain 2>/dev/null)" ] || printf -- '  It has uncommitted changes: the session before you left them; read them before you build on them.\n'
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
    if ($a | has("bot_comments")) and ($b.bot_comments // 0) > $a.bot_comments
      then "worker\t\(($b.bot_comments // 0) - $a.bot_comments) new comment(s) from review bots" else empty end,
    if ($a | has("approvals")) then
      (($b.approvals // []) - $a.approvals) as $new
      | if ($new | length) > 0 then "\($ap)\tapproved by \($new | join(", "))" else empty end
    else empty end,
    # An approval that stops counting, and a review asked again, are news for a person, whoever asked
    # (a gatekeeper bot on new commits, a dismissal on push, the reviewer changing their verdict).
    (($b.rerequested // []) as $again
     | (if ($a | has("approvals")) and ($b | has("approvals")) then $a.approvals - $b.approvals else [] end) as $lost
     | [$lost[] | select(. as $l | $again | index($l))] as $lostAgain
     | (if ($lostAgain | length) > 0
          then "coordinator\treview re-requested from \($lostAgain | join(", ")): their approval no longer counts"
        else empty end),
       (($lost - $lostAgain) | if length > 0 then "coordinator\tapproval by \(join(", ")) no longer counts" else empty end),
       (if ($a | has("rerequested")) then ($again - $a.rerequested - $lost)
          | if length > 0 then "coordinator\treview re-requested from \(join(", "))" else empty end
        else empty end))'
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

# What a whole comment that only summons a review bot looks like, as regexes (jq syntax, matched
# against the whole trimmed comment, case-insensitive): CodeRabbit's commands (it runs one only
# when it is alone on its line, so it cannot carry the marker) and Codex's bare review request.
# crew.bot_summons adds a team's own.
SUMMONS_DEFAULT='@coderabbit(ai)?[ \t]+(full[ \t]+review|review|pause|resume|resolve|summary|help|configuration)([ \t]+--[^ \t]+)*
@codex[ \t]+review'
summons_json() { # <root>
  { printf '%s\n' "$SUMMONS_DEFAULT"; (cd "$1" && bash "$CONFIG" list '.crew.bot_summons') 2>/dev/null; } \
    | jq -Rsc 'split("\n") | map(select(. != "")) | unique'
}

# crew.finding_patterns (or the key given) from every config source at <root>, as a sorted JSON
# array of regexes.
patterns_json() { # <root> [<key>]
  (cd "$1" && bash "$CONFIG" list ".crew.${2:-finding_patterns}") 2>/dev/null \
    | jq -Rsc 'split("\n") | map(select(. != "")) | unique'
}

pr_state() { # <facts json>
  local pr root cmd marker line bots pats ign sum
  pr=$(printf '%s' "$1" | jq -r '.pr // empty')
  root=$(facts_root "$1")
  cmd=$(cd "$root" && bash "$CONFIG" get '.crew.pr_state') || cmd=''
  marker=$(cd "$root" && bash "$CONFIG" get '.crew.marker') || marker='(agent)'
  bots=$(bots_json "$root")
  pats=$(patterns_json "$root")
  ign=$(patterns_json "$root" bot_ignore_patterns)
  sum=$(summons_json "$root")
  if [ -z "$cmd" ]; then
    case "$pr" in https://github.com/*) gh_state "$pr" "$marker" "$bots" "$pats" "$ign" "$sum"; return ;; *) return 1 ;; esac
  fi
  line=$(PR=$(q "$pr") ROOT=$(q "$root") MARKER=$(q "$marker") BOTS=$(q "$bots") FINDING_PATTERNS=$(q "$pats") \
    BOT_IGNORE_PATTERNS=$(q "$ign") BOT_SUMMONS=$(q "$sum") fill <<<"$cmd")
  (cd "$root" && sh -c "$line") 2>/dev/null
}

# The state (open | merged | closed) of a PR a ticket waits on: crew.pr_state at the ticket's root
# with {{PR}} that PR, else, for a github.com PR, gh asked for the state alone (the full gh_state
# reads every comment, which a waited-on PR's state does not need). Exit 1 when it cannot tell.
wait_state() { # <facts json> <pr url>
  local cmd s
  cmd=$(cd "$(facts_root "$1")" && bash "$CONFIG" get '.crew.pr_state') || cmd=''
  if [ -n "$cmd" ]; then
    s=$(pr_state "$(printf '%s' "$1" | jq -c --arg pr "$2" '.pr = $pr')" | jq -r '.state // empty' 2>/dev/null)
  else
    case "$2" in https://github.com/*) ;; *) return 1 ;; esac
    s=$(gh pr view "$2" --json state --jq '.state | ascii_downcase' 2>/dev/null)
  fi
  [ -n "$s" ] || return 1
  printf '%s\n' "$s"
}

# The worker's Dispatch to wake for these facts: a follow-up round gets a new Dispatch in the same
# workspace, so it is looked up in the Run by the workspace (a live one first, then the newest
# Orca lists), else the recorded `dispatch`. Exit 1 when there is none.
worker_dispatch() { # <facts json>
  local ws run d found
  ws=$(printf '%s' "$1" | jq -r "$WS_PATH")
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
  ws=$(printf '%s' "$1" | jq -r "$WS_PATH")
  [ -n "$ws" ] && [ -d "$ws" ] || return 1
  branch=$(git -C "$ws" branch --show-current 2>/dev/null) || branch=''
  [ -n "$branch" ] || branch=$(printf '%s' "$1" | jq -r '.branch // empty')
  [ -n "$branch" ] || return 1
  (cd "$ws" && gh pr list --head "$branch" --state all --limit 20 --json number,url 2>/dev/null) \
    | jq -er 'max_by(.number) | .url // empty' 2>/dev/null
}

# stdin with {{PR}}, {{ROOT}}, {{MARKER}}, {{TRACKER}}, {{BOTS}}, {{FINDING_PATTERNS}} and
# {{BOT_IGNORE_PATTERNS}} replaced by the variables of those names (each may be unset).
fill() {
  awk '
    function rep(s, ph, val,   out, i) {
      out = ""
      while ((i = index(s, ph)) > 0) { out = out substr(s, 1, i - 1) val; s = substr(s, i + length(ph)) }
      return out s
    }
    { print rep(rep(rep(rep(rep(rep(rep(rep($0, "{{PR}}", ENVIRON["PR"]), "{{ROOT}}", ENVIRON["ROOT"]), "{{MARKER}}", ENVIRON["MARKER"]), "{{TRACKER}}", ENVIRON["TRACKER"]), "{{BOTS}}", ENVIRON["BOTS"]), "{{FINDING_PATTERNS}}", ENVIRON["FINDING_PATTERNS"]), "{{BOT_IGNORE_PATTERNS}}", ENVIRON["BOT_IGNORE_PATTERNS"]), "{{BOT_SUMMONS}}", ENVIRON["BOT_SUMMONS"]) }'
}

# The tracker adapter (lib/tracker.sh) as one shell command reading its config at <root>: what
# {{TRACKER}} becomes in agenda.sections, the autostart candidates and crew.process.
tracker_cmd() { printf 'bash %s --root %s' "$(q "$HERE/tracker.sh")" "$(q "$1")"; }

# The Orca board column a ticket's workspace belongs in (a wt.sh board column), from its PR state
# and, when the ticket's root configures a tracker, the ticket's role there: a merged PR is done;
# else the tracker's done, testing (qa) or in_review; else an open PR, draft (active) or ready
# (in_review). Exit 1 when neither says (a PR closed unmerged or none, no tracker role to go by)
# or the tracker did not answer: the workspace stays where it is. The tracker is read only while
# the PR is unmerged, and a key the tracker does not take (a GitHub tracker's keys are <repo>-<n>)
# reads as no role.
board_column() { # <facts json> <pr state json>
  local st root role
  st=$(printf '%s' "$2" | jq -r '.state // ""')
  [ "$st" = merged ] && { echo done; return 0; }
  root=$(facts_root "$1")
  if (cd "$root" && bash "$CONFIG" get '.tracker.kind') >/dev/null 2>&1; then
    role=$(bash "${HI_TRACKER_SH:-$HERE/tracker.sh}" --root "$root" read "$(printf '%s' "$1" | jq -r .key)" 2>/dev/null </dev/null)
    case $? in
      0) role=$(printf '%s' "$role" | jq -r '.role // empty' 2>/dev/null) || role='' ;;
      3|4) role='' ;;   # a key this tracker does not take, a config it refuses: go by the PR
      *) return 1 ;;    # the tracker did not answer: no move this pass, or QA would flap to In review
    esac
    case "$role" in
      done) echo done; return 0 ;;
      testing) echo qa; return 0 ;;
      in_review) echo in_review; return 0 ;;
    esac
  fi
  [ "$st" = open ] || return 1
  if [ "$(printf '%s' "$2" | jq -r '.draft // false')" = true ]; then echo active; else echo in_review; fi
}

# Link the PR on the workspace in Orca: a github.com PR by its number (only on a workspace of that
# same repo, since a bare number on another repo's workspace links someone else's PR), a GitLab
# merge request by its url (Orca checks it against the workspace's project). Exit 0 when it is
# linked or cannot be (another forge, another repo), 1 when Orca did not answer: try again later.
ws_link() { # <workspace> <pr url>
  local O js n repo flag val
  O=$(orca_cmd)
  case "$2" in
    https://github.com/*/pull/[0-9]*)
      n=$(printf '%s\n' "$2" | sed -n 's#^https://github\.com/\([^/]*/[^/]*\)/pull/\([0-9][0-9]*\).*#\1 \2#p')
      [ -n "$n" ] || return 0
      repo=${n% *}; n=${n#* }
      js=$("$O" worktree show --worktree "path:$1" --json 2>/dev/null </dev/null) || return 1
      printf '%s' "$js" | jq -e '.ok == true' >/dev/null 2>&1 || return 1
      printf '%s' "$js" | jq -e --arg p "github:$repo" \
        '(.result.worktree.projectId // "" | ascii_downcase) == ($p | ascii_downcase)' >/dev/null 2>&1 || return 0
      [ "$(printf '%s' "$js" | jq -r '.result.worktree.linkedPR // empty')" = "$n" ] && return 0
      flag=--pr val=$n ;;
    https://*/-/merge_requests/[0-9]*) flag=--gitlab-mr val=$2 ;;
    *) return 0 ;;
  esac
  "$O" worktree set --worktree "path:$1" "$flag" "$val" --json 2>/dev/null </dev/null | jq -e '.ok == true' >/dev/null 2>&1
}

# Keep a ticket's Orca workspace in step with its PR, from the watch: the PR linked once, and the
# board column (board_column) moved through hi's `wt.sh board`, which keeps a column the person
# set by hand. Each is asked of Orca only when it changed since the last pass (notes
# watch/<KEY>.linked and watch/<KEY>.board): every Orca call costs seconds. A move Orca or wt.sh
# could not make is tried again next pass. No workspace, or no hi plugin: nothing.
ws_sync() { # <facts json> <pr state json>
  local w="$DIR/watch" key ws pr col out
  key=$(printf '%s' "$1" | jq -r .key)
  ws=$(printf '%s' "$1" | jq -r "$WS_PATH")
  pr=$(printf '%s' "$1" | jq -r '.pr // empty')
  [ -n "$ws" ] && [ -d "$ws" ] || return 0
  if [ -n "$pr" ] && [ "$(cat "$w/$key.linked" 2>/dev/null)" != "$pr" ] && ws_link "$ws" "$pr"; then
    printf '%s\n' "$pr" >"$w/$key.linked"
  fi
  col=$(board_column "$1" "$2") || return 0
  [ "$(cat "$w/$key.board" 2>/dev/null)" = "$col" ] && return 0
  [ -f "$WT_SH" ] || return 0
  out=$(bash "$WT_SH" --repo "$ws" board "$ws" "$col" 2>/dev/null </dev/null) || out=''
  case "$(printf '%s' "$out" | cut -f1)" in
    moved|same|kept) printf '%s\n' "$col" >"$w/$key.board" ;;
  esac
  return 0
}

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
  local root secs n i name cmd line out rc team=''
  root=$(derive_root)
  # The person's open work threads from the hi-threads journal, when that plugin keeps one here.
  bash "$HERE/threads-read.sh" agenda 2>/dev/null | jq -c '{section: "threads"} + .' 2>/dev/null
  secs=$(cd "$root" && bash "$CONFIG" get '.agenda.sections') || secs=''
  [ -n "$secs" ] && [ "$secs" != null ] || secs='[]'
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
    out=$(printf '%s\n' "$out" | jq -Rc --arg s "$name" 'fromjson? | select(type == "object") | {section: $s} + .')
    [ -n "$out" ] && printf '%s\n' "$out" && team="$team$out"$'\n'
  done
  # The built-in forge sections (lib/forge.sh): what the team's sections and the workers' PRs
  # already show is not listed again.
  { printf '%s' "$team"; cmd_list | jq -c 'select(.pr) | {url: .pr}'; } | bash "$HERE/forge.sh" --root "$root" sections
}

cmd_watch() {
  need_jq
  local w="$DIR/watch" lock="$DIR/watch/lock" t key pr run now snap what hit since tool kind hs ap to fp ip wp ws
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
    # The PRs the ticket waits on (`waits_on`, a list of PR urls): each one that merges or closes is
    # told once, to the worker as a round, else the coordinator. Before the ticket's own PR, which
    # a ticket waiting on another may not have yet.
    printf '%s' "$t" | jq -r '.waits_on // [] | if type == "array" then .[] else . end | strings | select(. != "")' \
      | while IFS= read -r wp; do
        grep -qxF "$wp" "$w/$key.waits" 2>/dev/null && continue
        ws=$(wait_state "$t" "$wp" </dev/null) || continue
        case "$ws" in merged|closed) ;; *) continue ;; esac
        printf '%s\n' "$wp" >>"$w/$key.waits"
        event "$key" "$run" "$wp" "a PR it waits on was $ws" "$t"
      done
    # No PR recorded yet (the worker records it at its draft-PR step): look it up by the branch,
    # and record what is found, so the digest and later passes read it from the facts.
    if [ -z "$pr" ]; then
      # No PR yet: the board can still follow the tracker (a ticket done without one).
      pr=$(find_pr "$t") || { ws_sync "$t" '{}' </dev/null; continue; }
      (cmd_record "$key" "$(jq -cn --arg pr "$pr" '{pr: $pr}')") || continue
      t=$(printf '%s' "$t" | jq -c --arg pr "$pr" '.pr = $pr')
    fi
    now=$(pr_state "$t") && printf '%s' "$now" | jq -e 'type == "object"' >/dev/null 2>&1 || continue
    # The Orca workspace follows the PR: linked, and in its board column (done once merged), in
    # this same pass: once the agenda closes the ticket the watch never looks at it again.
    ws_sync "$t" "$now" </dev/null
    fp=$(patterns_json "$(facts_root "$t")"); [ -n "$fp" ] || fp='[]'
    ip=$(patterns_json "$(facts_root "$t")" bot_ignore_patterns); [ -n "$ip" ] || ip='[]'
    snap="$w/$key.json"
    if [ -f "$snap" ]; then
      # An approval is the worker's when it merges its own PR (crew.merge on_green), else a person's.
      ap=coordinator
      [ "$(cd "$(facts_root "$t")" && bash "$CONFIG" get '.crew.merge' 2>/dev/null)" = on_green ] && ap=worker
      # A note from before v2 counted people another way (approval texts in, inline comments out):
      # its people count is taken from now, so the switch neither fires nor swallows a comment.
      # A changed crew.finding_patterns recounts the findings already there: taken from now too.
      # So does a changed crew.bot_ignore_patterns with the bots' comments.
      changes "$(jq -c --argjson b "$now" --argjson fp "$fp" --argjson ip "$ip" '
          (if .v == 2 then . else . + ($b | {people, people_at} | with_entries(select(.value != null))) end)
          | if (.fp // []) == $fp then . else . + ($b | {findings} | with_entries(select(.value != null))) end
          | if (.ip // []) == $ip then . else . + ($b | {bot_comments} | with_entries(select(.value != null))) end' "$snap")" \
          "$now" "$ap" | while IFS="$(printf '\t')" read -r to what; do
        if [ "$to" = worker ]; then event "$key" "$run" "$pr" "$what" "$t"; else event "$key" "$run" "$pr" "$what"; fi
      done
    fi
    printf '%s' "$now" | jq -c --argjson fp "$fp" --argjson ip "$ip" '. + {v: 2, fp: $fp, ip: $ip}' >"$snap"
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
  ws=$(printf '%s' "$1" | jq -r "$WS_PATH")
  [ -n "$ws" ] && [ -d "$ws" ] || return 1
  bash "$SESSION_STATE" get "$ws"
}

# since<TAB>tool<TAB>kind when the worker of these facts sits on a dialog; exit 1 otherwise.
# prompt-mark first (it names the tool waiting on a permission); then the hook line, which also
# knows question forms.
on_prompt() { # <facts json>
  local ws hs
  ws=$(printf '%s' "$1" | jq -r "$WS_PATH")
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
  local named='' wpath='' place setup_err=''
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
    # A wait-for-setup repo's setup is waited for at most 120 s here, not to hold the watch's pass;
    # still running then (exit 3), the spec tells the worker to wait for it.
    setup_err=$(mktemp "${TMPDIR:-/tmp}/hi-crew-ws.XXXXXX") || return 1
    wpath=$(cd "$root" && bash "$HERE/crew.sh" workspace --repo "$repo" --name "$key" --branch "$named" --base "$base" \
      --setup-timeout "${HI_CREW_AUTOSTART_SETUP_TIMEOUT:-120}" 2>"$setup_err")
    case $? in
      0) : >"$setup_err" ;;
      3) wpath=$(printf '%s\n' "$wpath" | head -1) ;;
      *) as_log failed "$key" "$(sed 's/^crew: //' "$setup_err" | head -1); not retried (rm $AS_DIR/tried/$key to retry)"
        rm -f "$setup_err"; return 1 ;;
    esac
    place=(--worktree "path:$wpath" --keep-open)
  else
    place=(--worktree new-top-level --repo "$repo" --name "$key" --base-branch "$base")
  fi
  agent=$(cd "$root" && bash "$CONFIG" get '.crew.agent') || agent=claude
  model=$(cd "$root" && bash "$CONFIG" get '.crew.model') || model=''
  bf=$(mktemp "${TMPDIR:-/tmp}/hi-crew-brief.XXXXXX") && sf="$bf.spec" || return 1
  printf 'Started by hi-crew autostart: the ticket carries the label `%s`, and no person has read it\nbefore this start. Read the ticket yourself%s; when it is not clear enough to act on, ask.\n' \
    "$label" "${url:+ ($url)}" >"$bf"
  [ -z "$setup_err" ] || { cat "$setup_err" >>"$bf"; rm -f "$setup_err"; }
  err=$( (cd "$root" && bash "$HERE/crew.sh" spec --key "$key" --title "$title" --brief-file "$bf" --root "$root") 2>&1 >"$sf") \
    || { rm -f "$bf" "$sf"; as_log failed "$key" "could not build the spec${err:+: $(printf '%s\n' "$err" | sed 's/^crew: //' | head -1)}"; return 1; }
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

# --- resume in the lost worker's own pane (highness#110) ---------------------------------------
# Measured on Orca 1.4.271: a worker whose Claude exits (/exit, a crash) has its Dispatch failed
# at once (stage process_exited) while its pane stays open (terminalState retained). Typing
# `claude --resume <session> …` into that pane continues the session with its chat, on whichever
# account Orca has selected (every account's config dir links projects/ to ~/.claude/projects),
# and `orchestration worker-start --terminal <pane>` from the coordinator gives it a new Task and
# Dispatch there: its ask and worker_done reach the coordinator again. Orca refuses --terminal
# from a worker, so only the coordinator can do this.

# Every Claude config dir a worker may have run under, one per line: HI_CLAUDE_DIRS when set
# (newline-separated, tests), else each Orca profile's account homes, this session's, ~/.claude.
claude_dirs() {
  local p d
  if [ -n "${HI_CLAUDE_DIRS:-}" ]; then printf '%s\n' "$HI_CLAUDE_DIRS"; return 0; fi
  as_profiles "$("$(orca_cmd)" account list --agent claude --json 2>/dev/null)" | awk 'NF && !seen[$0]++' \
    | while IFS= read -r p; do for d in "$p"/*/home; do [ -d "$d" ] && printf '%s\n' "$d"; done; done
  printf '%s\n' "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"
}

# session_of <workspace> <dispatch>…: the Claude session that worked the first of these Dispatches
# found. Orca types a Dispatch's preamble into the worker as a prompt, so the transcript whose
# typed prompt (a user message whose content is a string, not a tool result) carries
# `--dispatch-id <it>` is that worker's. Transcripts sit under projects/<the workspace with every
# character but a letter or digit turned into '-'>/<session>.jsonl.
session_of() {
  local ws=$1 d dir slug f seen='' pd
  shift
  slug=$(printf '%s' "$ws" | sed 's/[^A-Za-z0-9]/-/g')
  for d in "$@"; do
    [ -n "$d" ] || continue
    while IFS= read -r dir; do
      [ -n "$dir" ] && [ -d "$dir/projects/$slug" ] || continue
      pd=$(cd -P "$dir/projects/$slug" 2>/dev/null && pwd -P) || continue
      case "$NL$seen$NL" in *"$NL$pd$NL"*) continue ;; esac
      seen="$seen$NL$pd"
      f=$(grep -lF -e "--dispatch-id $d" "$pd"/*.jsonl 2>/dev/null | while IFS= read -r f; do
        jq -e --arg n "--dispatch-id $d" 'select(.type == "user" and (.message.content | type) == "string"
            and (.message.content | contains($n)))' "$f" >/dev/null 2>&1 && { printf '%s\n' "$f"; break; }
      done)
      [ -n "$f" ] && { basename "$f" .jsonl; return 0; }
    done <<EOF
$(claude_dirs)
EOF
  done
  return 1
}
NL='
'

# The transcript of a session (any config dir), for the flags it ran with.
transcript_of() { # <workspace> <session>
  local slug dir
  slug=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -f "$dir/projects/$slug/$2.jsonl" ] && { printf '%s\n' "$dir/projects/$slug/$2.jsonl"; return 0; }
  done <<EOF
$(claude_dirs)
EOF
  return 1
}

# Processes: HI_PROC is a /proc-shaped fixture dir for tests (<pid>/environ); macOS has `ps -E`.
proc_alive() { if [ -n "${HI_PROC:-}" ]; then [ -d "$HI_PROC/$1" ]; else kill -0 "$1" 2>/dev/null; fi; }
proc_env() { # <pid> <NAME>
  local p=${HI_PROC:-/proc}
  if [ -r "$p/$1/environ" ]; then
    tr '\0' '\n' <"$p/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -1
  elif [ -z "${HI_PROC:-}" ]; then
    ps -E -ww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1
  fi
}

# Live Claude sessions, one per line: pid<TAB>session<TAB>terminal handle (empty outside Orca)
# <TAB>config dir (physical). Claude Code keeps sessions/<pid>.json in its config dir while the
# process runs.
live_sessions() {
  local dir f row pid seen=''
  while IFS= read -r dir; do
    [ -n "$dir" ] && [ -d "$dir/sessions" ] || continue
    dir=$(cd -P "$dir" 2>/dev/null && pwd -P) || continue
    case "$NL$seen$NL" in *"$NL$dir$NL"*) continue ;; esac
    seen="$seen$NL$dir"
    for f in "$dir"/sessions/*.json; do
      [ -f "$f" ] || continue
      row=$(jq -r 'select((.sessionId | type) == "string") | [.pid, .sessionId] | @tsv' "$f" 2>/dev/null) || continue
      pid=${row%%"$TAB"*}
      [ -n "$row" ] && proc_alive "$pid" || continue
      printf '%s\t%s\t%s\n' "$row" "$(proc_env "$pid" ORCA_TERMINAL_HANDLE)" "$dir"
    done
  done <<EOF
$(claude_dirs)
EOF
}
TAB=$(printf '\t')

# lost_pane <dispatch>: the terminal handle of a lost worker's pane, when Orca still has it open.
lost_pane() {
  local h
  [ -n "$1" ] || return 1
  h=$("$(orca_cmd)" orchestration worker-show --dispatch "$1" --json 2>/dev/null \
    | jq -r 'select(.ok == true) | .result | select((.terminalState // "") == "retained") | .terminal // empty' 2>/dev/null)
  [ -n "$h" ] || return 1
  # A closed pane still answers ok, with connected false (measured, Orca 1.4.271).
  "$(orca_cmd)" terminal show --terminal "$h" --json 2>/dev/null \
    | jq -e '.ok == true and .result.terminal.connected == true and .result.terminal.writable != false
             and ((.result.terminal.status // "running") == "running")' >/dev/null 2>&1 || return 1
  printf '%s\n' "$h"
}

# The line that relaunches a session in its pane: the permission mode it last ran in (from its
# transcript), the model recorded for the worker, and Orca's agent-view plugin dir, which Orca
# passes every agent it launches (ORCA_CLAUDE_AGENT_VIEW_PLUGIN_DIR in this session).
relaunch_line() { # <transcript> <session> <model>
  local mode line="claude --resume $2" av=${ORCA_CLAUDE_AGENT_VIEW_PLUGIN_DIR:-}
  [ -n "$av" ] && [ -d "$av" ] && line="$line --plugin-dir $(q "$av")"
  mode=$(jq -r 'select(.type == "user" and (.permissionMode | type) == "string") | .permissionMode' "$1" 2>/dev/null | tail -1)
  case "$mode" in
    bypassPermissions) line="$line --dangerously-skip-permissions" ;;
    ''|default) ;;
    *[!A-Za-z]*) ;;
    *) line="$line --permission-mode $mode" ;;
  esac
  [ -n "$3" ] && line="$line --model $(q "$3")"
  printf '%s\n' "$line"
}

# resume_in_pane <key> <facts> <lost dispatch> <coordinator handle> <asked> <dispatch>…: give the
# lost worker's own session a new Dispatch in its own pane, relaunching it there first when it no
# longer runs. Prints the receipt and records the facts; exit 0. Exit 1, having changed nothing:
# no open pane, no session found, the session runs elsewhere, or another one runs in the pane;
# the caller falls back to a new worker. Dies when it relaunched the session but could not see it
# start: a dialog may be open there, and a second worker must not start beside it.
resume_in_pane() {
  local key=$1 facts=$2 d=$3 handle=$4 asked=$5 ws run pane sid row s pid h dir cd acct line tr model title sf out rc i
  shift 5
  ws=$(printf '%s' "$facts" | jq -r "$WS_PATH")
  run=$(printf '%s' "$facts" | jq -r '.run // empty')
  pane=$(lost_pane "$d") || return 1
  sid=$(session_of "$ws" "$@") || return 1
  pid='' cd=''
  while IFS="$TAB" read -r row s h dir; do
    [ -n "$row" ] || continue
    if [ "$s" = "$sid" ]; then
      [ "$h" = "$pane" ] || return 1   # it runs, but in another pane
      pid=$row cd=$dir
    elif [ "$h" = "$pane" ]; then
      return 1                          # another session runs in that pane
    fi
  done <<EOF
$(live_sessions)
EOF
  # Still running, but on an account other than the one workers run on (the switch left it, or
  # its limit is why it stopped): a Dispatch typed into it would stop the same way. A new worker
  # beside a live session is no answer either.
  if [ -n "$pid" ]; then
    acct=$(as_account 2>/dev/null) && acct=$(cd -P "$acct" 2>/dev/null && pwd -P) || acct=''
    [ -z "$acct" ] || [ "$acct" = "$cd" ] \
      || die "resume: $key's session still runs in its pane $pane, but on the account at $cd, not $acct which workers run on: move it first (hi's /hi:account, or account.sh move --only $pane), then run resume again"
  fi
  if [ -z "$pid" ]; then
    tr=$(transcript_of "$ws" "$sid") || return 1
    model=$(printf '%s' "$facts" | jq -r '.model // empty')
    line=$(relaunch_line "$tr" "$sid" "$model")
    "$(orca_cmd)" terminal send --terminal "$pane" --text "$line" --enter --json >/dev/null 2>&1 </dev/null || return 1
    i=0
    until live_sessions | awk -F'\t' -v s="$sid" -v h="$pane" '$2 == s && $3 == h { f = 1 } END { exit !f }'; do
      i=$((i + 1))
      [ "$i" -le "${HI_RESUME_START_WAIT:-90}" ] \
        || die "resume: typed \`$line\` into $key's pane $pane, but its session was not seen running: look at the pane (a dialog?), then run resume again"
      sleep 1
    done
    "$(orca_cmd)" terminal wait --terminal "$pane" --for tui-idle --timeout-ms 30000 --json >/dev/null 2>&1 </dev/null
  fi
  # A dialog open in the pane would take the new Dispatch's text as its answer.
  if "$(orca_cmd)" terminal show --terminal "$pane" --json 2>/dev/null | jq -e '(.result.terminal.agentWait // null) != null' >/dev/null 2>&1; then
    die "resume: $key's session in its pane $pane waits on a dialog: answer it there, then run resume again"
  fi
  title=$(printf '%s' "$facts" | jq -r '.title // empty'); [ -n "$title" ] || title=$key
  sf=$(mktemp "${TMPDIR:-/tmp}/hi-crew-resume.XXXXXX") || die 'resume: no temp file'
  {
    printf '## Resumed in your own session: read this first\n\n'
    printf 'Your Dispatch on %s%s was lost (a usage limit, an account switch or an exit), but this\n' "$key" "${d:+ ($d)}"
    printf 'is the same Claude session: your chat, your spec and your work so far are above. Orca gave you\n'
    printf 'a new Task and Dispatch: from now on use the Task ID and Dispatch ID in this message for every\n'
    printf 'ask, escalation and worker_done, never the earlier ones. Your spec still binds.\n\n'
    [ -z "$asked" ] || printf 'Questions you asked under the lost Dispatch whose answer never reached you:\n\n%s\n\n' "$asked"
    printf 'Continue where you stopped.\n'
  } >"$sf"
  out=$(cd "$(facts_root "$facts")" && "$(orca_cmd)" orchestration worker-start --spec-file "$sf" \
    --task-title "$key: $title (resumed)" --terminal "$pane" --run "$run" ${handle:+--from "$handle"} --json 2>&1)
  rc=$?
  rm -f "$sf"
  if [ $rc -ne 0 ] || [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    die "resume: $key's session runs again in its pane $pane, but the new Dispatch failed; do not rerun it, read failedStage (orca skills get orchestration --reference references/recovery-and-cleanup.md): $out"
  fi
  (cmd_record "$key" "$(printf '%s' "$out" | jq -c --argjson f "$facts" --arg d "$d" --arg p "$pane" --arg s "$sid" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {dispatch: .result.dispatchId, task: .result.taskId, resumed_at: $now, resumed_in: $p, session: $s,
     resumed: (($f.resumed // []) + (if $d != "" then [$d] else [] end))}')") \
    || die "resume: the worker has a new Dispatch, but its facts were not recorded; record its dispatch and task by hand: $out"
  printf '%s\n' "$out"
  return 0
}

# resume <KEY>: get a worker going again on <KEY> after the last one was lost without reporting
# (a usage limit, an account switch, a closed session). First in its own pane, keeping its chat
# (resume_in_pane). When that cannot be done, a new worker in its recorded workspace and Run.
# Orca's own retry does not fit there: --retry-of needs --task, and a Task's spec cannot carry
# the note below. So it is a new Task: the spec copy (the facts' `spec`) under a note that says
# the work so far is in the workspace. Either way the new dispatch and task are recorded and the
# old dispatch kept in `resumed` (asks drops its "lost" escalation). Refuses, starting nothing: no
# facts, no workspace, no spec copy, a merged or closed PR, or a worker on it Orca still counts
# live. Prints the receipt; a line on stderr says which way it went.
cmd_resume() {
  [ $# -eq 1 ] || die 'usage: resume <KEY>'
  need_jq
  local key=$1 facts ws run spec root pr state d agent model handle title branch sf out rc m asked noted
  facts=$(cmd_get "$key") || die "resume: no open facts for $key"
  ws=$(printf '%s' "$facts" | jq -r "$WS_PATH")
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
  # Its own pane and session first: the worker keeps its chat. The Dispatches to look its session
  # up by: the lost one, then the facts' latest and the ones earlier resumes replaced.
  if resume_in_pane "$key" "$facts" "$d" "$handle" "$asked" "$d" \
      $(printf '%s' "$facts" | jq -r '(.dispatch // empty), ((.resumed // []) | reverse | .[])'); then
    printf 'crew: resume: %s got a new Dispatch in its own pane, its chat kept\n' "$key" >&2
    return 0
  fi
  printf 'crew: resume: %s: no open pane with its session; starting a new worker in its workspace\n' "$key" >&2
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
    if printf '%s' "$facts" | jq -e '.handover == true' >/dev/null 2>&1; then
      printf 'second one, and do not redo committed work. The "where it stands" in the spec is as it was\n'
      printf 'when the earlier worker started: read the PR again for what is open now.\n\n---\n\n'
    else
      printf 'second one, and do not redo committed work. The spec'"'"'s "Already done?" check is about this\n'
      printf 'ticket landing elsewhere, not about the earlier worker'"'"'s progress here.\n\n---\n\n'
    fi
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
    + (if $n != "" then {resumed_spec: $n, resumed_for: .result.dispatchId} else {} end)
    + (if $pr != "" and ($f.pr // "") == "" then {pr: $pr} else {} end)')") \
    || die "resume: the worker started, but its facts were not recorded; record its dispatch and task by hand: $out"
  printf '%s\n' "$out"
}

# adopt <KEY> --pr <url>: hand an open PR that another session drove (outside hi-crew, or a worker
# whose facts were closed) to a new worker, in the follow-up phase. See the header for the rules.
# The facts (pr and head included) are recorded before worker-start, so the watch follows the PR
# from its first pass and a failed start can be run again: open facts from an adopt whose worker
# never started are taken over, any other open facts refuse.
cmd_adopt() {
  need_jq
  local key='' pr='' title='' ws='' repo='' brief_file='' root='' bgs=() facts view state o r n run handle
  local branch head row rows sel cur bf sf setup_err wout agent model out rc spec_args
  [ $# -gt 0 ] && case "$1" in -*) ;; *) key=$1; shift ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) pr=${2:-}; shift 2 ;;
      --title) title=${2:-}; shift 2 ;;
      --workspace) ws=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --brief-file) brief_file=${2:-}; shift 2 ;;
      --background) bgs+=(--background "${2:-}"); shift 2 ;;
      --root) root=${2:-}; shift 2 ;;
      *) die "adopt: unknown argument '$1'" ;;
    esac
  done
  [ -n "$key" ] && [ -n "$pr" ] || die 'usage: adopt <KEY> --pr <url> [--title T] [--workspace P] [--repo SEL] [--brief-file F] [--background X]... [--root R]'
  keyfile "$key" >/dev/null || exit 2
  [ -z "$brief_file" ] || [ -f "$brief_file" ] || die "adopt: no brief file: $brief_file"
  if facts=$(cmd_get "$key"); then
    printf '%s' "$facts" | jq -e '.handover == true and (.dispatch // "") == ""' >/dev/null 2>&1 \
      || die "adopt: $key has open facts (crew.sh get $key): a worker was started on it; a lost one continues with crew.sh resume $key"
  fi
  case "$pr" in https://github.com/*/*/pull/[0-9]*) ;; *) die "adopt: '$pr' is not a github.com pull request url (other forges are not covered yet)" ;; esac
  run=$(cmd_run) || die 'adopt: this session has no hi-crew Run yet (crew.sh run <run_id>, /hi-crew:start step 4)'
  handle=${ORCA_TERMINAL_HANDLE:-$(cat "$DIR/handles/$run" 2>/dev/null)}
  [ -n "$root" ] || root=$(cmd_root)
  [ -d "$root" ] || die "adopt: the root is not a directory: '$root'"
  view=$(pr_view "$pr") || die "adopt: could not read $pr with gh"
  state=$(printf '%s' "$view" | jq -r '.state // "" | ascii_downcase')
  [ "$state" = open ] || die "adopt: $pr is ${state:-in an unknown state}, not open: nothing to hand over"
  printf '%s' "$view" | jq -e '.isCrossRepository != true' >/dev/null \
    || die "adopt: $pr comes from a fork: its branch is pushed elsewhere, which a worker here cannot (not covered)"
  branch=$(printf '%s' "$view" | jq -r '.headRefName')
  head=$(printf '%s' "$view" | jq -r '.headRefOid')
  pr=$(printf '%s' "$view" | jq -r '.url // empty' | grep . || printf '%s' "$pr")
  n=${pr##*/pull/}; n=${n%%[!0-9]*}
  o=$(printf '%s\n' "$pr" | sed -n 's#^https://github\.com/\([^/]*\)/\([^/]*\)/pull/.*#\1/\2#p' | tr '[:upper:]' '[:lower:]')
  [ -n "$title" ] || title=$(bash "$HERE/tracker.sh" --root "$root" read "$key" 2>/dev/null | jq -r '.title // empty' 2>/dev/null)
  [ -n "$title" ] || title=$(printf '%s' "$view" | jq -r '.title // empty')
  [ -n "$title" ] || title=$key
  # The workspace: the one given, else an Orca workspace of the PR's repo on its branch (never the
  # main checkout), else a new one created on the branch from its remote.
  if [ -z "$ws" ]; then
    rows=$("$(orca_cmd)" worktree list --limit 10000 --json 2>/dev/null) || rows=''
    printf '%s' "$rows" | jq -e '.ok == true' >/dev/null 2>&1 \
      || printf 'crew: adopt: orca worktree list did not answer; looking for no existing workspace\n' >&2
    printf '%s' "$rows" | jq -e '.result.truncated != true' >/dev/null 2>&1 \
      || printf 'crew: adopt: orca listed only part of the workspaces; pass --workspace if the PR has one\n' >&2
    rows=$(printf '%s' "$rows" | jq -c --arg p "github:$o" '
      [.result.worktrees[]? | select((.projectId // "" | ascii_downcase) == $p and (.isArchived | not))]' 2>/dev/null) || rows='[]'
    [ -n "$rows" ] || rows='[]'
    row=$(printf '%s' "$rows" | jq -c --arg b "refs/heads/$branch" '[.[] | select(.branch == $b and (.isMainWorktree | not))] | .[0] // empty')
    if [ -n "$row" ]; then
      ws=$(printf '%s' "$row" | jq -r .path)
      [ -n "$repo" ] || repo="id:$(printf '%s' "$row" | jq -r .repoId)"
    else
      row=$(printf '%s' "$rows" | jq -c 'sort_by(.isMainWorktree | not) | .[0] // empty')
      [ -n "$repo" ] || { [ -n "$row" ] && repo="id:$(printf '%s' "$row" | jq -r .repoId)"; } \
        || die "adopt: no Orca project for github.com/$o and no workspace on $branch: add the clone (orca repo add --path <clone>) or pass --repo"
      [ -z "$row" ] || git -C "$(printf '%s' "$row" | jq -r .path)" fetch -q origin "$branch" 2>/dev/null \
        || printf 'crew: adopt: could not fetch %s; creating from what the clone has\n' "$branch" >&2
      setup_err=$(mktemp "${TMPDIR:-/tmp}/hi-crew-ws.XXXXXX") || die 'adopt: no temp file'
      wout=$(cd "$root" && bash "$HERE/crew.sh" workspace --repo "$repo" --name "$key" --branch "$branch" \
        --base "origin/$branch" --pr "$n" 2>"$setup_err")
      case $? in
        0) : >"$setup_err" ;;
        3) ;;
        *) cat "$setup_err" >&2; rm -f "$setup_err"; die "adopt: could not create a workspace on $branch" ;;
      esac
      ws=$(printf '%s\n' "$wout" | head -1)
      # Orca suffixes a branch name taken by a local branch: switch to the PR's own branch.
      cur=$(git -C "$ws" branch --show-current 2>/dev/null) || cur=''
      if [ "$cur" != "$branch" ]; then
        git -C "$ws" checkout -q "$branch" 2>/dev/null && git -C "$ws" branch -q -D "$cur" 2>/dev/null
        cur=$(git -C "$ws" branch --show-current 2>/dev/null) || cur=''
        [ "$cur" = "$branch" ] || { rm -f "$setup_err"; die "adopt: the new workspace $ws is on '$cur', not the PR's branch $branch; check it out there, then run adopt again with --workspace $ws"; }
        git -C "$ws" merge-base --is-ancestor HEAD "$head" 2>/dev/null && git -C "$ws" merge -q --ff-only "$head" 2>/dev/null
      fi
    fi
  fi
  [ -d "$ws" ] || die "adopt: the workspace is not a directory: '$ws'"
  ws=$(cd "$ws" && pwd -P)
  cur=$(git -C "$ws" branch --show-current 2>/dev/null) || cur=''
  [ "$cur" = "$branch" ] || die "adopt: $ws is on '${cur:-no branch}', not the PR's branch $branch"
  [ -n "$repo" ] || repo="path:$ws"
  # The spec: the brief (the team's per-ticket notes) and a setup still running, then the handover.
  bf=$(mktemp "${TMPDIR:-/tmp}/hi-crew-brief.XXXXXX") && sf="$bf.spec" || die 'adopt: no temp file'
  { [ -z "$brief_file" ] || cat "$brief_file"; [ -z "${setup_err:-}" ] || cat "$setup_err"; } >"$bf"
  rm -f "${setup_err:-}"
  spec_args=(--key "$key" --title "$title" --brief-file "$bf" --root "$root" --handover --pr "$pr" --workspace "$ws")
  [ ${#bgs[@]} -eq 0 ] || spec_args+=("${bgs[@]}")
  (cmd_spec "${spec_args[@]}") >"$sf" || { rm -f "$bf" "$sf"; die 'adopt: could not build the spec'; }
  rm -f "$bf"
  agent=$(cd "$root" && bash "$CONFIG" get '.crew.agent') || agent=claude
  model=$(cd "$root" && bash "$CONFIG" get '.crew.model') || model=''
  (cmd_record "$key" "$(jq -nc --arg t "$title" --arg r "$repo" --arg w "$ws" --arg b "$branch" --arg pr "$pr" --arg h "$head" \
      --arg root "$root" --arg s "$DIR/specs/$key.md" --arg run "$run" --arg a "$agent" --arg m "$model" '
      {title: $t, repo: $r, workspace: $w, branch: $b, pr: $pr, head: $h, root: $root, spec: $s, run: $run,
       agent: $a, model: $m, handover: true}')") || { rm -f "$sf"; die 'adopt: could not record the facts; nothing started'; }
  out=$(cd "$root" && "$(orca_cmd)" orchestration worker-start --spec-file "$sf" --task-title "$key: $title (handover)" \
    --worktree "path:$ws" --keep-open --agent "$agent" ${model:+--model "$model"} --run "$run" \
    ${handle:+--from "$handle"} --json 2>&1)
  rc=$?
  rm -f "$sf"
  if [ $rc -ne 0 ] || [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    die "adopt: worker-start failed; its facts are recorded, so after reading failedStage (orca skills get orchestration --reference references/recovery-and-cleanup.md) run the same adopt again: $out"
  fi
  (cmd_record "$key" "$(printf '%s' "$out" | jq -c '{dispatch: .result.dispatchId, task: .result.taskId}')") \
    || die "adopt: the worker started, but its dispatch was not recorded; record it by hand: $out"
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
  adopt) cmd_adopt "$@" ;;
  record) cmd_record "$@" ;;
  get) cmd_get "$@" ;;
  list) cmd_list ;;
  close) cmd_close "$@" ;;
  release) cmd_release "$@" ;;
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
