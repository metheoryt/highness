---
name: where
description: Only the work threads — for the whole picture with tickets, PRs and agents use /hi-crew:agenda, which shows these threads too. Show where the person's work stands across all their Claude Code sessions on this machine — every open thread (a task, a fix, a question, an idea) with what is left in it, who it waits on and which session to resume it in, most urgent first — then propose where to start and pick it up. Use when the user asks "where was I", "what was I doing", "what's left", "what did we leave unfinished", "what's open", "where are we", "что у нас висит", «на чём остановились», or opens a session not knowing which of their sessions holds what; and the first time, to build the journal from the sessions already on the machine.
---

# /hi-threads:where

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language (no words of theirs yet: `session.language` in their config), Read one file
per call, 2–4 options per question.

The journal is kept by the plugin's hooks: after every turn in any session on this machine a model
notes which thread the turn belonged to, what was done, what is left and who waits on whom. This
skill reads it.

```bash
TH="${CLAUDE_PLUGIN_ROOT}/lib/threads.sh"
```

`${CLAUDE_PLUGIN_ROOT}` is this plugin's directory; if it is empty, use the "Base directory for
this skill" printed above, two levels up.

## 1. Read

`bash "$TH" list --json`: the open threads of this project (the cwd's repo, or the umbrella of
nested clones it sits in), one JSON object per line, ranked: waiting on the person first, then
left with tails (`paused`), then `active`, `waiting` on others, `idea`. `--all` for every project
on the machine, when the user asks for everything.

Each has `title`, `status`, `waits_on`, `next`, `open_items`, `ticket`, `pr`, `updated`,
`last_session`, `last_cwd`, `history` (the last notes, newest last).

**Empty, or the user asks to build it from old sessions** (first run): offer the backfill once,
saying it reads each past session of this project turn by turn through the model, so it takes a
while and costs tokens. On yes, for each transcript of this project's sessions from the last 14
days (`~/.claude/projects/<the cwd with / replaced by ->/*.jsonl`, and the same for the project's
other checkouts and worktrees), oldest first, in the background:

```bash
bash "$TH" replay <transcript> <session id: the file name without .jsonl> <the session's cwd>
```

The cwd is the transcript's first `cwd` field. Replay posts no ticket comments.

## 2. Show

One short list in the user's language, most urgent first, each thread on one or two lines: its
title, its state in words (waits on you / left unfinished / in work / waits on someone else /
idea), its ticket or PR, and the next step. Under a thread left unfinished, its open items as a
short sublist. Then **where to start**: your pick and why, in one line, from the ranking and from
what the user said in this session.

Do not show ids, paths or session ids unless asked. When the user picks a thread:

- **Continue it here** when this session can do it (same repo).
- **Settle it here, go on there**: when the user settles the thread's open points in this
  session and the work goes on in the thread's own session, relay the decisions to that session;
  do not hand the user a line to run and a message to copy. Write a short brief to a temporary
  file (what was decided, what to do next, in the thread's own terms), then make one call:

  ```bash
  bash "$TH" relay <last_cwd> <last_session> <brief file>
  ```

  It goes through hi's `wt.sh dispatch <worktree> --resume <session>`: first the live session in
  the thread's worktree, then a new terminal there. It prints `<outcome><TAB><detail>`:
  - `sent`: typed into the session running in the thread's worktree. Tell the user in one line
    what was sent; a session they started by hand may ask once there to read the brief.
  - `started`: no session ran there; `claude --resume` started in a new terminal of that
    worktree with the decisions as its first prompt. Say so in one line.
  - `unconfirmed`: typed, but not seen taken. The user looks at that terminal; never send it
    again, a resend can submit it twice.
  - `dialog`: resumed, but it opened on a dialog (folder trust, a permission) that the user
    answers in that terminal. Give no resume line: a second resume runs the session twice.
  - `busy`: a turn or a dialog runs there, or a chat is open; nothing was typed. Say so and
    offer to retry or to paste by hand (the brief's text); do not wait in a loop.
  - `manual`: neither worked (no hi plugin, no Orca or tmux, not a workspace). Only now give the
    resume line (`<detail>`) and the decisions as a paste-ready message.
- **Only reopen it**, with nothing to carry: `cd <last_cwd> && claude --resume <last_session>`
  for the user to run.
- **Done or dropped**: say so and the journal updates by itself on this turn; no command needed.

## 3. Rules

- The journal is a model's notes, not the truth. When the team configures `threads.check.pr` and
  `threads.check.ticket`, the job after each turn (at most every 10 minutes) and the agenda close
  the threads whose PRs merged and tickets closed, and leave what they found in `check`; run
  `bash "$TH" check --wait --ttl 0` for a fresh look. Still check a PR or ticket in the tracker or
  forge before acting on it.
- Never edit `threads.json` by hand; a correction the user gives goes in the conversation and the
  next turn's update picks it up.
