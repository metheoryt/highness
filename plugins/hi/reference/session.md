# Session rules — every hi skill

Every SKILL.md opens with a one-line gist of this file. Read it in full once per session,
before the skill's first reply.

## Language

The chat follows the user, not the skill.

1. **The language of the user's latest message in this session.** A user who writes Russian gets
   Russian, whatever language the skill text is in.
2. **The first message of a session is the skill call itself.** Any word of another language in
   its arguments (`/hi:worktrees что у меня`) sets that language.
3. **Otherwise English.**

It covers everything the agent itself says to the user: prose, tables, footers, and the
`AskUserQuestion` question, option labels and descriptions.

It does not cover:

- **Script output pasted verbatim** (`wt.sh` tables, `repo-setup.sh` rows): paste it as it is,
  never translated. Lines the agent adds around it follow the chat.
- **Fixed tokens**: states, commands, paths, keys.
- **Artifacts**: commits, branches, files written into a repo — English.

## Reading files

A reference, a skill's file or any large file is loaded with the **Read tool, one call per
file**. Never `cat` several files in one Bash call to save calls.

Why: Bash output over the cap (about 30 KB) is not shown. Claude Code saves it to the session's
`tool-results/*.txt` and shows a 2 KB preview, so the agent has to open that file next. Read and
`grep` on it go through. `sed` on it may not: the harness can treat `sed` as a possible write to a
protected `.claude/` path and ask the user — and a dispatched worker then waits on a prompt
nobody watches.

When a tool-results file exists anyway, read it with the Read tool (`offset`/`limit` for a part)
or `grep -n`. Never use `sed`, `awk` or `cat` on it.

## Questions

`AskUserQuestion` takes 2 to 4 options per question. One real option → say it as a line of prose
instead of a question. More than four → split into several questions (up to four per call) or list
them as numbered prose and let the user answer by number.

## Where the scripts are

The skills run the plugin's scripts as `bash "$L/<script>"`, with

    L="${CLAUDE_PLUGIN_ROOT}/lib"

If that placeholder was not filled in (the path does not exist), the launcher knows the root:
`L="$("$HOME/.local/bin/highness" root)/lib"`. Quote `$L`: the path may contain spaces.
