---
name: agenda
description: Where the person's work stands and what waits on them, in one list, most urgent first — the threads they left unfinished in any session on this machine (from the hi-threads journal), the hi-crew ticket workers' open questions, people's new comments on their PRs, PRs ready to merge, and the team's own sections (their tickets, their PRs, reviews waiting on them) — then propose where to start and work through it, resuming a thread or relaying answers to the workers. The way to start the day or a new session. Use when the user asks "where was I", "where did we stop", "what's on me", "what's left", "agenda", "what are the agents waiting on", «на чём остановились», «что у меня», «с чего начать», «что висит», or opens a new session and wants to pick up their work or the workers started from another one.
---

# hi-crew:agenda

A digest the person pulls. Nothing here is pushed to them except what blocks a worker.

```bash
C="${CLAUDE_PLUGIN_ROOT}/lib/crew.sh"
O=$(bash "$C" orca)
```

`${CLAUDE_PLUGIN_ROOT}` is this plugin's directory; if it is empty, use the "Base directory for
this skill" printed above, two levels up.

## 1. Gather

1. `bash "$C" list`: one line per open ticket (facts: key, title, repo, workspace, dispatch, pr…).
   **The team's sections**: `bash "$C" sections` — what the team set under `agenda.sections` in
   `.claude/highness.json` (its tracker and forge: the person's tickets, PRs, reviews waiting),
   one JSON object per line: `section`, `group` (`you` waits on the person, `others` waits on
   someone else, `later` not started yet, `done`), `title`, `next`, `url`, `since`; or `section` and `error` when that
   source failed (say so in one line, do not guess its content). A ticket the workers already
   carry shows once, under the worker.
   **Threads** come first among the sections, as section `threads`, when the hi-threads plugin
   keeps a journal on this machine: the work the person left in any session of this project, with
   `status`, `waits_on`, `open_items` (what is left), `session` and `cwd` (the session it was
   last worked in, and where) and `resume` (the line that reopens that session). A thread that names a ticket a worker carries shows once,
   under the worker.
   The journal is a model's notes, so the threads come checked: before printing them the section
   asks the forge and the tracker what became of each PR and ticket a thread names (the team's
   commands `threads.check.pr` and `threads.check.ticket`). A thread whose PRs all merged or closed
   and whose tickets are all resolved is closed in the journal and comes first, group `done`, its
   `next` saying why. An open one carries `live`, what the check found ("repo#12 merged; AB-3 In
   Review"): when it contradicts `next` (the PR to merge is merged), word the item from `live`.
   `stale` is a thread with no PR and no ticket left untouched for days: nothing can check it.
   A thread whose PR or ticket a team section also lists shows once, by the section's line (it is
   live), with the thread's open items under it.
   **A held autostart**: `bash "$C" held` — one line, "autostart held <N> h: <reason>", when
   autostart has started nothing for over an hour because every pass stopped short (the budget,
   no coordinator, no root); nothing otherwise. A hold starts no worker and makes no event, so this
   line is the only place it shows. `bash "$C" account` names the config dir whose budget it reads.
   No open tickets: skip steps 2–6. No tickets, no sections and no held autostart: say there is
   nothing on the person and stop.
2. **What blocks a worker**: `bash "$C" asks` — open questions, decision gates, and escalations
   (a worker that stopped without reporting), across the Runs of all open tickets, each with its
   Run. `$O orchestration inbox --limit 100 --full --json` gives the full text.
   **Workers on a dialog**: `bash "$C" prompts` (TSV: key, run, since, tool, kind — `permission`, `input` for an MCP server's input dialog, or `question` for a question form). Such a
   worker waits for someone to click in its terminal and sends no question, so nothing else shows
   it; the person answers it there (`$O terminal list`, or the worker's workspace in Orca).
3. **Last reports**: `bash "$C" reports` — the latest `worker_done` per dispatch. A report no
   session handled lands here; record what it names (`pr`, `head`).
4. **What the watch saw**: `bash "$C" events` — PRs merged or closed, CI failures, people's
   new comments, workers left on a dialog, a tool call open too long (a hung command?), since anyone last looked (TSV: time, key, run, pr, what). When it is empty and
   `$O automations list --json` has no "hi-crew watch", offer `bash "$C" watch-install` once.
5. **Workers**: `bash "$C" states` first — each worker's state from its own hooks (TSV: key,
   run, state, since, kind, open tool, minutes that tool has run, minutes the turn has run;
   `unknown` when its session has no hook line). Then `$O orchestration worker-list --run <run>
   --json` for each of `bash "$C" runs` — which are working, idle, finished — for the `unknown` ones
   and for finished.
6. **Each ticket's PR** (`pr` in the facts; when missing, find it by the `branch` on the forge, and record it): read its state with the team's forge tool (the `crew.process` text
   says which): open, draft or ready, merged or closed; review rounds; CI; and comments from people
   since the worker's last report. A comment is a person's when it is not the review bot's and does
   not start with the workers' marker (`crew.marker`, default `(agent)`): workers post under the
   person's own account, so the author login alone does not tell.

## 2. Show

One short list, most urgent first, each item with its next step in words:

1. **Waiting on you** — a held autostart's line as it came (its reason says what to fix: the
   budget, a coordinator session to open), open questions and gates (with the worker's proposals), workers on a
   dialog (since when, which tool), stopped workers, people's new comments on a
   PR, PRs whose review loop finished and that wait for a person to resolve threads and merge;
   then the sections' `you` items, by section. A thread left unfinished (`paused`) carries its
   open items as a short sublist; no ids, paths or session ids unless asked. The `stale` threads
   only as one count ("and 37 old notes with no PR or ticket"), with an offer to go through them.
2. **Running** — what each worker is doing, from its last report; then the sections' `others`
   items (waiting on a reviewer, a bot, a teammate), one line each. The `later` items only as a
   count per section ("and 12 not started"), listed when the person asks.
3. **Done since last time** — merged or closed, and reports whose subject starts `already done:`
   (the worker found the work landed and opened no PR; show its evidence); propose closing the
   facts. The sections' `done` items go here too, the threads the check just closed among them.

Then `bash "$C" events --ack`, propose where to start, and go one topic at a time.

## 3. Work through it

Replying or sending needs the worker's Run bound to this session. When it is another session's
(`bash "$C" run` prints something else, or nothing), `$O orchestration run-use --id <run>` first,
and say in one line that Orca now wakes this session, not the other one, for that Run's workers.

- **A question**: show it point by point with your read; get the user's decisions; relay with
  `$O orchestration reply --id <message_id> --body "…"`, marked as the user's.
  Then record each decided point with `bash "$C" choice <KEY> '{…}'`, as `hi-crew:start` says.
- **A person's comment on a PR**: show it with your read; on the user's decision, send the worker a
  round: `$O orchestration send --to dispatch:<dispatch> --subject … --body …`, saying what to
  change and how to reply. Record the new dispatch id from the receipt.
- **Ready to merge**: that is the person's own step; give the link.
- **A thread**: its open items say what is left. The journal is a model's notes: check a PR or
  ticket state before acting on it. Continue it here when this session can (same repo).
  Otherwise, once the user has settled its open points here, relay the decisions to the thread's
  own session; do not hand the user its `resume` line and a message to copy. Write a short brief
  to a temporary file (what was decided, what to do next, in the thread's own terms), then make
  one call with the row's `cwd` and `session`:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/lib/threads-read.sh" relay <cwd> <session> <brief file>
  ```

  It goes through hi's `wt.sh dispatch <worktree> --resume <session>`, as the budget hold's
  resume does: first the live session in the thread's worktree, then a new terminal there. It
  prints `<outcome><TAB><detail>`:
  - `sent`: typed into the session running in the thread's worktree. Tell the user in one line
    what was sent; a session they started by hand may ask once there to read the brief.
  - `started`: no session ran there; `claude --resume` started in a new terminal of that
    worktree with the decisions as its first prompt. Say so in one line.
  - `unconfirmed`: typed, but not seen taken. The user looks at that terminal; never send it
    again, a resend can submit it twice.
  - `dialog`: resumed, but it opened on a dialog (folder trust, a permission) that the user
    answers in that terminal. Give no `resume` line: a second resume runs the session twice.
  - `busy`: a turn or a dialog runs there, or a chat is open; nothing was typed. Say so and
    offer to retry or to paste by hand (the brief's text); do not wait in a loop.
  - `manual`: neither worked (no hi plugin, no Orca or tmux, not a workspace). Only now give the
    `resume` line (`<detail>`) and the decisions as a paste-ready message.

  With nothing to carry, the `resume` line alone reopens it.
- **A section item**: its `next` says what to do; do it with the team's own tools (the item's
  `url`, the skill the team's process names). Starting a ticket on a worker is `/hi-crew:start`.
- **Merged or closed**: run the retro (`reference/retro.md`), then `bash "$C" close <KEY>`; offer
  to release the workspace.

End your turn when the topics are done; Orca wakes this session when a worker reports.
