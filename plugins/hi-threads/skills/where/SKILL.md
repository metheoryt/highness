---
name: where
description: Only the work threads — for the whole picture with tickets, PRs and agents use /hi-crew:agenda, which shows these threads too. Show where the person's work stands across all their Claude Code sessions on this machine — every open thread (a task, a fix, a question, an idea) with what is left in it, who it waits on and which session to resume it in, most urgent first — then propose where to start and pick it up. Use when the user asks "where was I", "what was I doing", "what's left", "what did we leave unfinished", "what's open", "where are we", "что у нас висит", «на чём остановились», or opens a session not knowing which of their sessions holds what; and the first time, to build the journal from the sessions already on the machine.
---

# /hi-threads:where

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

- **Resume it where it was**: `cd <last_cwd> && claude --resume <last_session>` — give the line
  for the user to run; or continue it here when this session can do it (same repo).
- **Done or dropped**: say so and the journal updates by itself on this turn; no command needed.

## 3. Rules

- The journal is a model's notes, not the truth: when a thread's state matters (a PR merged?
  a ticket closed?) check it in the tracker or forge before acting on it.
- Never edit `threads.json` by hand; a correction the user gives goes in the conversation and the
  next turn's update picks it up.
