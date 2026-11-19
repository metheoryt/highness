# Session rules — every hi-review skill

Every SKILL.md opens with a one-paragraph gist of this file. Read it in full once per session,
before the skill's first reply.

## Language

The chat follows the user, not the skill.

1. **The language of the user's latest message in this session that has words of theirs.** A user
   who writes Russian gets Russian, whatever language the skill text is in.
2. **The first message of a session is the skill call itself.** Any word of another language in
   its arguments sets that language.
3. **No words of the user's yet** (`/hi-review:review 123` as the first message; a PR number, URL
   or mode is not a word): `session.language` from the user's own config, when it is set —
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/config.sh" get --user .session.language`, a language name such
   as `Russian`.
4. **Otherwise English.**

It covers everything the agent itself says to the user: prose, reports, and the `AskUserQuestion`
question, option labels and descriptions.

It does not cover:

- **Fixed tokens**: commands, paths, keys, script output pasted verbatim.
- **The review itself** (its body and inline comments): the language of the pull request — its
  title, body and existing threads — never the chat's by default. The person's voice file
  (`review.voice`) may say otherwise.

## Reading files

A reference, a skill's file or any large file is loaded with the **Read tool, one call per
file**. Never `cat` several files in one Bash call to save calls.

Why: Bash output over the cap (about 30 KB) is not shown. Claude Code saves it to the session's
`tool-results/*.txt` and shows a short preview, so the agent has to open that file next. Read and
`grep` on it go through; `sed` on it may not: the harness can treat `sed` as a possible write to a
protected `.claude/` path and ask the user, and an unattended agent then waits on that prompt.

## Questions

`AskUserQuestion` takes 2 to 4 options per question. One real option → say it as a line of prose
instead of a question. More than four → split into several questions (up to four per call) or list
them as numbered prose and let the user answer by number.

## Nothing reaches GitHub unasked

The only write to GitHub is the review the person chose in the verdict question, and the deletion
of their own pending review it replaces. No reply in anyone's thread, no label, no re-request, no
resolved thread: those are the person's, listed as `action for you:` lines.
