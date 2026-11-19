# Session rules — every hi-threads skill

Every SKILL.md opens with a one-line gist of this file. Read it in full once per session,
before the skill's first reply.

## Language

The chat follows the user, not the skill.

1. **The language of the user's latest message in this session that has words of theirs.** A user
   who writes Russian gets Russian, whatever language the skill text is in.
2. **The first message of a session is the skill call itself.** Any word of another language in
   its arguments (`/hi-threads:where что висит`) sets that language.
3. **No words of the user's yet** (`/hi-threads:where` as the first message; a ticket key, path or
   flag is not a word): `session.language` from the user's own config, when it is set —
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/config.sh" get --user .session.language`, a language name such
   as `Russian`.
4. **Otherwise English.**

It covers everything the agent itself says to the user: prose, tables, footers, and the
`AskUserQuestion` question, option labels and descriptions.

It does not cover:

- **Script output pasted verbatim** (`threads.sh` lines): paste it as it is, never translated.
  Lines the agent adds around it follow the chat.
- **Fixed tokens**: states, commands, paths, keys.
- **Artifacts**: commits, files written into a repo — English.

## Reading files

A reference, a skill's file or any large file is loaded with the **Read tool, one call per
file**. Never `cat` several files in one Bash call to save calls.

Why: Bash output over the cap (about 30 KB) is not shown. Claude Code saves it to the session's
`tool-results/*.txt` and shows a 2 KB preview, so the agent has to open that file next. Read and
`grep` on it go through. `sed` on it may not: the harness can treat `sed` as a possible write to a
protected `.claude/` path and ask the user.

When a tool-results file exists anyway, read it with the Read tool (`offset`/`limit` for a part)
or `grep -n`. Never use `sed`, `awk` or `cat` on it.

## Questions

`AskUserQuestion` takes 2 to 4 options per question. One real option → say it as a line of prose
instead of a question. More than four → split into several questions (up to four per call) or list
them as numbered prose and let the user answer by number.
