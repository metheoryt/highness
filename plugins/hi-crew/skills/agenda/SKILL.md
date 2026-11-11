---
name: agenda
description: Show what waits on the person — the hi-crew ticket workers' open questions, people's new comments on their PRs, PRs ready to merge, and the team's own sections (their tickets, their PRs, reviews waiting on them) when the team configured them — and what is still running, most urgent first; then work through it, relaying the person's answers to the workers. Use when the user asks "what are the agents waiting on", "agenda", "what's on me", "what's up with my tickets", "crew status", or opens a new session and wants to pick up the workers started from another one.
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
   No open tickets: skip steps 2–6. No tickets and no sections: say there is nothing on the
   person from hi-crew and stop.
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

1. **Waiting on you** — open questions and gates (with the worker's proposals), workers on a
   dialog (since when, which tool), stopped workers, people's new comments on a
   PR, PRs whose review loop finished and that wait for a person to resolve threads and merge;
   then the sections' `you` items, by section.
2. **Running** — what each worker is doing, from its last report; then the sections' `others`
   items (waiting on a reviewer, a bot, a teammate), one line each. The `later` items only as a
   count per section ("and 12 not started"), listed when the person asks.
3. **Done since last time** — merged or closed, and reports whose subject starts `already done:`
   (the worker found the work landed and opened no PR; show its evidence); propose closing the
   facts. The sections' `done` items go here too.

Then `bash "$C" events --ack`, propose where to start, and go one topic at a time.

## 3. Work through it

Replying or sending needs the worker's Run bound to this session. When it is another session's
(`bash "$C" run` prints something else, or nothing), `$O orchestration run-use --id <run>` first,
and say in one line that Orca now wakes this session, not the other one, for that Run's workers.

- **A question**: show it point by point with your read; get the user's decisions; relay with
  `$O orchestration reply --id <message_id> --body "…"`, marked as the user's.
- **A person's comment on a PR**: show it with your read; on the user's decision, send the worker a
  round: `$O orchestration send --to dispatch:<dispatch> --subject … --body …`, saying what to
  change and how to reply. Record the new dispatch id from the receipt.
- **Ready to merge**: that is the person's own step; give the link.
- **A section item**: its `next` says what to do; do it with the team's own tools (the item's
  `url`, the skill the team's process names). Starting a ticket on a worker is `/hi-crew:start`.
- **Merged or closed**: `bash "$C" close <KEY>`; offer to release the workspace.

End your turn when the topics are done; Orca wakes this session when a worker reports.
