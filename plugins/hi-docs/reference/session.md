# Session rules — every hi-docs skill

Every SKILL.md opens with a one-paragraph gist of this file. Read it in full once per session,
before the skill's first reply.

## Language

The chat follows the user, not the skill.

1. **The language of the user's latest message in this session.** A user who writes Russian gets
   Russian, whatever language the skill text is in.
2. **The first message of a session is the skill call itself.** Any word of another language in
   its arguments (`/hi-docs:write-doc черновик спеки`) sets that language.
3. **Otherwise English.**

It covers everything the agent itself says to the user: prose, reports, and the `AskUserQuestion`
question, option labels and descriptions.

It does not cover:

- **Fixed tokens**: commands, paths, keys, script output pasted verbatim.
- **Artifacts**: the document being written, cut files, commits, files written into a repo —
  English, unless the user or the team's conventions set another language for them.
- **Outward text** (a ticket comment, a PR review, a chat message to a colleague): the language of
  the place it lands, never the chat's by default.

## Reading files

A reference, a skill's file or any large file is loaded with the **Read tool, one call per
file**. Never `cat` several files in one Bash call to save calls.

Why: Bash output over the cap (about 30 KB) is not shown. Claude Code saves it to the session's
`tool-results/*.txt` and shows a short preview, so the agent has to open that file next. Read and
`grep` on it go through; `sed` on it may not: the harness can treat `sed` as a possible write to a
protected `.claude/` path and ask the user, and an unattended agent then waits on that prompt.

When a tool-results file exists anyway, read it with the Read tool (`offset`/`limit` for a part)
or `grep -n`. Never use `sed`, `awk` or `cat` on it.

## Questions

`AskUserQuestion` takes 2 to 4 options per question. One real option → say it as a line of prose
instead of a question. More than four → split into several questions (up to four per call) or list
them as numbered prose and let the user answer by number.
