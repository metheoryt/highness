---
name: meet
description: Seed a person's working preferences from their own past Claude Code sessions on this machine — count their corrections, rejected tool calls, permission denials, repeated asks and the skills they use over the last 60 days (every Claude profile Orca uses included), read a sample in full, draft preference lines each backed by evidence (session, date, a short quote of their own words), and write only the lines they accept, through hi-crew's prefs.sh, into the store `preferences` names. Candidate team rules are shown apart and become a pull request only on a yes. Nothing leaves the machine. Long and token-hungry: run it only when the person asks. Use when the user says "meet me", "learn my preferences", "seed my preferences from my sessions", «познакомься со мной», or accepts /hi:setup's offer.
---

# /hi:meet

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language (no words of theirs yet: `session.language` in their config), Read one file
per call, 2–4 options per question.

`L="${CLAUDE_PLUGIN_ROOT}/lib"` (if that path does not exist: `L="$("$HOME/.local/bin/highness" root)/lib"`).
`M="$L/meet.sh"`. The script counts, extracts and checks; you read, draft and ask. Run `bash "$M"`
with no arguments for its full usage.

What stays fixed through every step:

- **Only this person's own sessions, only on this machine.** Nothing is posted, sent or copied
  anywhere: not the counts, not the draft, not a quote. The one exception is a team-rule pull
  request the person says yes to (step 7), and it carries no quote of theirs.
- **Their own words only.** Quote only what `meet.sh list` or `meet.sh show` prints as theirs (a
  `person:` turn, a rejection's words). Never quote the agent, a pasted document, a tool's output.
- **No secrets, no one else's personal data.** The script masks paths, addresses, URLs, handles
  and anything shaped like a token; it cannot mask a name. Never quote a line that names another
  person, a customer, or a private detail about anyone: pick another quote or drop the line.
- **Nothing is written without a yes, line by line.** A line the person declines is gone; a
  declined draft writes nothing at all.

## 1. Before reading anything

Say in two lines what this does and costs: it reads the person's own Claude Code sessions of the
last 60 days on this machine (`bash "$M" sources` lists the config dirs, every profile Orca uses
included), it takes a while and spends tokens, and nothing leaves the machine. Ask whether to go
on and over how many days (60 unless they say). A no ends here.

Then find the writer and the store:

    P=$(bash "$M" prefs)        # hi-crew's prefs.sh; fails without hi-crew: say so and stop
    bash "$P" paths             # the person's existing preference files
    bash "$P" targets           # where lines may go

When `paths` lists files, the person already keeps preferences there (their own store, perhaps
fed by a harvest of their own): this run writes into those files, never a second store. Read their
headings (`grep -n '^#' <file>`) and skim what they already say, so the draft neither repeats a
line nor contradicts one without saying so. With no files, lines go to the last `targets` entry,
the default file.

## 2. Count

    bash "$M" scan --days <N>

It prints `kind<TAB>count<TAB>sessions<TAB>projects`. Show it as a short table. Zero sessions: say
so (nothing in the window, or every session was headless or a worker's) and stop.

## 3. Read the evidence

In this order, each printed newest first:

    bash "$M" list rejection     # tool calls the person refused, with their words when they gave any
    bash "$M" list correction    # a turn that opens with "no", "don't", "stop", or follows an interrupt
    bash "$M" list denial        # tool calls their own rules or prompts denied
    bash "$M" list repeat        # the same ask in two or more sessions
    bash "$M" list skill         # what they run, typed or by the agent
    bash "$M" sample             # the sessions worth reading in full

Then read each sampled session in full with `bash "$M" show <session>`: what the agent did just
before each correction and rejection is what the preference is about. A count alone is not a
preference; a pattern the person states or enforces in several places is.

## 4. Draft

Write the draft to `"$(bash "$M" dir)/draft.md"`, never into a repo:

    # hi:meet draft — <date>, <N> days

    ## Preferences

    1. <one rule, in the person's terms>
       - <session> <YYYY-MM-DD> "<short quote of their own words>"
       - <session> <YYYY-MM-DD> "<another>"

    ## Team rule candidates

    1. <a rule the whole team would want>
       - <session> <YYYY-MM-DD> "<quote>"

- A line is general: how they work, not what one task needed. One rule per line, in the language
  of the file it will go to (the person's own language for a new file).
- Each line has one to three evidence lines: the 8-character session id and a date exactly as
  `list` prints them, and a verbatim quote of at most 120 characters (a part of a turn is fine).
  Prefer evidence from more than one session.
- Team rule candidates: only what showed up in several projects and serves a team rather than one
  person's taste. None is fine; leave the section empty.
- Leave out what their existing files already say.

    bash "$M" check "$(bash "$M" dir)/draft.md"

must print nothing. Each line it prints is a problem in the draft (no evidence, a quote that is not
theirs, a quote the scrub would mask, a session or date that does not match): fix the draft and run
it again. Never show the person a draft that fails the check.

## 5. Review, line by line

Show the preferences one at a time, or in short batches, each with its evidence and the file (and
heading) it would go to. For each: **keep**, **reword** (they give the words; the evidence stays),
or **drop**. Apply rewordings to the draft and re-run `check`. Do not argue a dropped line back.

## 6. Write only what was kept

Per target file (and heading), with the kept numbers:

    bash "$M" accept "$(bash "$M" dir)/draft.md" <numbers> >"$(bash "$M" dir)/lines"
    bash "$P" diff <file> "$(bash "$M" dir)/lines" [--under '<heading>']

Show the diff; on their yes, and only then, `bash "$P" write` with the same arguments. Each line
carries a `<!-- hi:meet <session> <date> -->` tag, so a later reader can trace it; the quotes stay
in the draft. Nothing kept (`accept … none` prints nothing): say that nothing was written, and
write nothing. The person's own sync carries the file from there: never copy it anywhere else.

## 7. Team rule candidates, apart

Show them after the preferences, as a separate list: these would bind the team, not the person.
For each the person wants to propose:

    bash "$M" rule "$(bash "$M" dir)/draft.md" <n> --root <the team repo>

prints a pull request body with counts only (no quote, no session id, no path). Its `target:` is
the team's rules file (`crew.team_rules` in the team's settings). Reword the rule in the team's
terms, scrub it of host, company and people's names, show it, and on the person's yes open it as a
draft pull request to that repo from a fresh workspace off its trunk (`/hi:worktrees`, never the
main checkout), adding the rule line to that file. `target: none`: offer it as an issue in that
repo instead. No yes, no pull request.

## 8. Close

`bash "$M" clean` removes the cache and the draft (their words, collected). Say how many lines were
written and where, how many were dropped, and what was proposed to the team, if anything.
