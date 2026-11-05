---
name: agenda
description: Show what the hi-crew ticket workers wait on the person for — their open questions, people's new comments on their PRs, PRs ready to merge — and what is still running, most urgent first; then work through it, relaying the person's answers to the workers. Use when the user asks "what are the agents waiting on", "agenda", "what's up with my tickets", "crew status", or opens a new session and wants to pick up the workers started from another one.
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
   Empty: say there are no hi-crew workers and stop.
2. **Take the Run**: `$O orchestration run-use --id "$(bash "$C" run)"`. Only the session holding
   the Run can answer questions, and Orca wakes only that session; say in one line that this
   session now holds it.
3. **What blocks a worker**: `bash "$C" asks` — open questions, decision gates, and escalations
   (a worker that stopped without reporting). `$O orchestration inbox --limit 100 --full --json`
   gives the full text.
4. **Last reports**: `bash "$C" reports` — the latest `worker_done` per dispatch. A report the
   previous session never handled lands here; record what it names (`pr`, `head`).
5. **Workers**: `$O orchestration worker-list --run <run> --json` — which are working, idle,
   finished.
6. **Each ticket's PR** (`pr` in the facts; when missing, find it by the `branch` on the forge, and record it): read its state with the team's forge tool (the `crew.process` text
   says which): open, draft or ready, merged or closed; review rounds; CI; and comments from people
   since the worker's last report. A comment is a person's when it is not the review bot's and does
   not start with the workers' marker (`crew.marker`, default `(agent)`): workers post under the
   person's own account, so the author login alone does not tell.

## 2. Show

One short list, most urgent first, each item with its next step in words:

1. **Waiting on you** — open questions and gates (with the worker's proposals), stopped workers, people's new comments on a
   PR, PRs whose review loop finished and that wait for a person to resolve threads and merge.
2. **Running** — what each worker is doing, from its last report.
3. **Done since last time** — merged or closed; propose closing the facts.

Then propose where to start, and go one topic at a time.

## 3. Work through it

- **A question**: show it point by point with your read; get the user's decisions; relay with
  `$O orchestration reply --id <message_id> --body "…"`, marked as the user's.
- **A person's comment on a PR**: show it with your read; on the user's decision, send the worker a
  round: `$O orchestration send --to dispatch:<dispatch> --subject … --body …`, saying what to
  change and how to reply. Record the new dispatch id from the receipt.
- **Ready to merge**: that is the person's own step; give the link.
- **Merged or closed**: `bash "$C" close <KEY>`; offer to release the workspace.

End your turn when the topics are done; Orca wakes this session when a worker reports.
