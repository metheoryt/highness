# The close-step retro

The coordinator runs this in its own session when a ticket is settled (its PR merged or closed,
or the worker reported `already done:`), before `crew.sh close <KEY>`. It takes a few minutes of
the coordinator's own turn: no headless job, no timer, no other account. Its purpose is to find
what made this ticket cost more than it should have, and to file it where it gets fixed.

```bash
RT="${CLAUDE_PLUGIN_ROOT}/lib/retro.sh"
```

## 1. Read

`bash "$RT" gather <KEY>` prints one bundle: the facts, where the spec, PR and ticket are, the
worker's transcript and the signals in it (failed tool calls, asks, interrupts, stalls), the
denial log's lines for that session, and the ticket's choice records. A part it cannot find says
so; go on without it.

Then read what it points at: the PR (body, review threads, CI) and the ticket with its comments,
with the forge and tracker tools the team uses. Open the transcript only around the signals: it
is long, and the signals say where to look.

Look only at what cost time or went wrong:

- **stalls**: a long gap, a dialog nobody answered, a session that sat idle;
- **permission denies**: a guard rule or the harness refused a command (the denial log, `error`
  signals naming a hook);
- **retries**: the same command run again and again, a tool that failed the same way twice;
- **asks**: a question to the person that the spec, the ticket or the code already answered;
- **dropped scope**: something the ticket asked for that the PR does not do and does not say so;
- **mistakes**: a review finding that was right, a revert, a fix-up commit for the worker's own bug.

A ticket that went smoothly has no findings. That is the usual outcome; do not invent one.

## 2. Pick at most 3 findings

Each finding is one of three kinds, by where its fix lives:

| kind | what | goes to |
|---|---|---|
| `tool` | a tool's fault: a script that failed, a guard rule that denied a safe command, a dialog a tool should have kept away | an issue in that tool's repo (set `repo`: `owner/repo`) |
| `brief` | a gap in the worker spec: the worker lacked a rule or a fact it needed, or followed one that misled it | an issue against the worker spec (hi-crew's own repo) |
| `decision` | a process question only a person can settle: who decides, what the rule should be | a `needs-decision` item in the team's tracker |

Keep the three that cost the most. Before writing one, search the open issues (or the team's
tracker) for it; when one already says it, set `"dup": "<its key or URL>"` and it is not filed
again. The filing also skips an open issue with the same title.

A finding is **measured facts only**: the step, the command, the exact error, what worked instead,
the commit or message it is in. Never a person's words, never a judgment of a person. Before
filing anywhere public, drop host names, home paths (the script turns `$HOME` into `~`), company
and people's names, and anything from a private repo.

Write them as a JSON array to a file in the scratchpad:

```json
[{"kind": "tool", "repo": "owner/tool", "title": "<what fails, in the tool's words>",
  "body": "Step: …\nCommand: …\nError: …\nWhat worked: …\nSeen in: <ticket key>, <commit or PR>"}]
```

`bash "$RT" file <KEY> <file>` files each one and prints `kind<TAB>title<TAB>result` per finding.
Where they go is `crew.retro_sink` in the team's settings (a command that files one finding,
see `lib/retro.sh`); unset, GitHub issues. A `failed:` result is shown to the person; the
retro goes on.

## 3. Preferences

The `choices` part of the bundle is what the person decided on this ticket. Some of it is worth
keeping as a line in their own preferences, so the next worker reads it before asking again.
`P="${CLAUDE_PLUGIN_ROOT}/lib/prefs.sh"`.

1. `bash "$P" propose <KEY>` prints raw candidate lines, grouped under the file each fits best
   (the one the picked option leans on, else the person's first preference file, else the
   default `highness/preferences.md`). Keep only those that say something general about how the
   person works; a choice that only fits this ticket is not a preference. Reword each as a rule
   in the person's terms, one line, ending with the ticket key. None worth keeping: skip to 3.
2. Write the lines to a scratchpad file and show `bash "$P" diff <file> <lines> [--under
   '<heading>']` to the person. On their yes, and only then, `bash "$P" write` with the same
   arguments; it writes only to a file `prefs.sh targets` lists. The person's own sync carries
   it from there: never copy it anywhere else.
3. `bash "$P" repeats` lists a choice made the same way on two or more tickets. For one that
   would serve the whole team (not one person's taste), `bash "$P" draft-rule <basis> <value>`
   drafts a team rule as a pull request body: reword its rule line in the team's terms first.
   Its `target:` is the team's rules file (`crew.team_rules` in the team's settings, a path in
   the coordinator root's repo). Show the draft; on the person's yes, open it as a draft PR to
   that repo from a fresh worktree off its trunk (never the main checkout), adding the rule line
   to that file. `target: none`: offer the draft as an issue in that repo instead. The team
   accepts or rejects it in review; nothing becomes a team rule without that.

These lines and drafts never go into the retro comment or the filed findings: the person's
replies are theirs, and the draft carries none of them verbatim.

## 4. Comment, then close

`bash "$RT" comment <KEY> [<note file>]` posts the retro comment on the ticket: its first line is
`<!-- hi:retro -->` (so a later readout can count retros), then the marker and what was filed, or
"no findings". The note, one to three lines, says what went well or badly in a sentence when that
is worth keeping; leave it out otherwise. Then `bash "$C" close <KEY>`; it warns when a ticket is
closed without a retro.

Tell the person in one or two lines: the ticket, the findings and where they went, or that there
were none.
