---
name: brief
description: Prepare a person's review of a pull request as a brief of 2-4 items for them to decide, picked by their own review lens (what they look at in a review), instead of a list of findings — a team's review bot already finds the bugs, and a person's review adds what only their judgment adds. Context from zero, then per item what happens, the agent's own view and recommendation, then the question; where people's reviews agree or clash; an optional bold idea that closes several past problems; below them, apart, at most three defects no one raised yet, each verified by a second pass before it is shown. Records what became of every item in a local journal, so a team can measure what the briefs changed. Use when the user says "brief me on PR <n>", "what should I look at in <PR>", "подготовь выжимку по PR", «что мне посмотреть в PR», "how are my briefs doing", or the team's tooling offers a brief for a PR waiting on their review. Args: <PR number or URL>, or `stats`.
---

# /hi-review:brief

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language (no words of theirs yet: `session.language` in their config); 2–4 options per
question. **This skill posts nothing**: no review, no comment, no label. The brief is for the person;
what they decide reaches the PR only through them.

Every shell call starts with

```bash
B="${CLAUDE_PLUGIN_ROOT}/lib/brief.sh"; CFG="${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
```

`${CLAUDE_PLUGIN_ROOT}` is this plugin's directory; if it is empty, use the "Base directory for
this skill" printed above, two levels up. Run from the team's workspace or a checkout of the PR's
repo, so the team's config applies.

`stats` in the args → `bash "$B" stats` (add `--since <date>` when the person names a period), show
it in two or three plain sentences, and stop.

## 1. The PR

`bash "$B" source <pr>` prints `<json file><TAB><diff file><TAB><summary>`. Exit 3 → surface its
stderr and stop. Merged or closed → say so and stop.

Read the JSON file with the Read tool: the title, the body, the author, and the people's and bots'
`reviews`, `threads` and `comments`. Read the diff file the same way; a large one in parts, the
hunks that carry the change first.

## 2. The lens

`bash "$B" lens` prints the person's lens: what they look at in a review, what they know outside
the code, what they leave to others. It may carry two parts (`# source: team`, the one the team
keeps for them, and `# source: personal`, their own notes); both are theirs.

- Exit 1 (no lens) → say once, in a line, that the brief runs without a lens and where one is kept
  (the team's place for it, or `review.lens` in their own highness config: text or a path to a
  file). Then pick by what only a person can judge: how the change fits the intent, the design
  choices that are costly to reverse, the product rules.
- For each person other than the author who already reviewed or commented, `bash "$B" lens --login
  <login>` may give their lens. Use it to understand where they stand, never to speak for them.

## 3. Context

1. **Intent**: the PR body and the tickets it names. `bash "$CFG" get .review.intent` may print a
   text the team wrote on where its specs and tickets live; follow it with the tools this session
   has.
2. **Past problems**: what the touched code has been through, from what this session can reach:
   `git log` on the touched paths, the tracker the intent text names, earlier review threads. Look
   for this only to judge whether a bold idea (below) holds.

## 4. Pick the items

2 to 4 items, each something the person decides or a view they would want to give. A defect is
never an item: defects go to step 5, apart, so the person's attention goes to the items first.

- **lens**: what the lens says the person looks at, in this PR.
- **outside**: about one brief in four, one item outside the lens, marked as such, so the lens
  does not narrow to what it already holds.
- **clash**: when people's reviews or comments on the PR agree or pull apart, where and why. A
  disagreement between people is always an item.
- **bold** (optional, at most one): one change that closes this case and at least two past problems
  you can cite by link or key (a ticket, a review finding, a commit). Without two citations, no
  bold item.

Leave out small things, style and optimizations, and costly rare cases that can be handled when
they actually happen. An idea that reaches beyond this PR is offered as a ticket, never as a
reason to hold the merge. Nothing for the person in this PR → the brief is one line saying so.

## 5. What no one raised

While reading the diff, note the defects that matter: wrong behaviour, a security hole, data lost
or exposed, a broken contract. Leave out style, naming and small things. Drop each one that a
review, thread or comment on the PR already raised, open or not: read them first.

Nothing reaches the person unverified. What is left goes to a second pass:

1. The head, in a checkout of the PR's repo (the current repo, or the team's clone of it; GitHub
   and Forgejo both serve `pull/<n>/head`); nothing is checked out:
   ```bash
   H=$(cd <checkout> && bash "${CLAUDE_PLUGIN_ROOT}/lib/review.sh" head --pr <number> --base-ref <base> --repo <repo>)
   ```
   Its `BASE<TAB>HEAD`; a `HEAD` other than the JSON's `head` means a push since: read the PR
   again (step 1).
2. One fresh `hi-review:reviewer` subagent (Agent tool, `subagent_type: "hi-review:reviewer"`)
   with `PHASE=verify`, `PLUGIN=${CLAUDE_PLUGIN_ROOT}`, `WT=<that checkout>`, `BASE_SHA` and
   `HEAD_SHA` from `H`, `INTENT` (step 3's text) and the defects as `FINDINGS_IN`, one per line:
   `<path>:<line> | blocking | <what goes wrong and the fix>`.
3. `CONFIRMED` stays; `WEAKENED` and `REFUTED` drop; `REMEDY` replaces the fix. No defects to check → no pass.

No checkout with the head, or the pass failed → no defects shown, and the brief says so in one
line. At most three, the most serious first. None is the common case: the team's review bot hunts
the bugs, and this step only catches what it missed.

## 6. The brief

In the chat's language, plain words, no identifiers the person did not use:

1. **Context from zero**, three to five lines: what this system is, what the PR changes and why,
   as if the person had never seen it.
2. **The items**, numbered. Each: what happens (with the file and lines when it helps), how it fits
   the intent of the system, **your own view and recommendation**, then the question to the person.
   An `outside` item says it is outside their lens; a `clash` item names who holds which view.
3. **What no one raised**, after the items and set apart, only when step 5 kept any: one line
   each, numbered after the items, with the file and line, what goes wrong and the fix.
4. One closing line: answer by number, or skip any.

## 7. The answers and the journal

Talk each item through as the person wants. Log an item's outcome as soon as it is clear, one call
each:

```bash
bash "$B" log --pr '<repo>#<number>' --head <head> --item <n> --kind <lens|outside|clash|bold|finding> \
  --outcome <discussed|ticket|change|skipped|not_interesting> --title '<the item in a few words>'
```

- `discussed`: it became a point of their review or a talk with the author; `ticket`: a ticket was
  filed from it; `change`: the author is to change the code for it; `not_interesting`: the person
  said it does not interest them; `skipped`: no reaction. An outcome logged again for the same item
  replaces the earlier one.
- A defect from step 5 logs `--kind finding` under its own number; `stats` counts findings apart
  from the items, so the lens's effect stays measurable on its own.
- A brief with no items logs `--item 0 --kind empty --outcome skipped`, findings or not.
- Before the session moves on, every item without an outcome is logged `skipped`.

What the person says about what they care about in a review is a candidate line for their lens:
quote it back in one line and say where the lens lives. Never write the lens yourself.

## 8. The review

From the person's answers, draft their review in the PR's language and their voice
(`bash "$CFG" get --user .review.voice`, a file, when set): one comment per point they decided to
make and per defect they kept, anchored to the file and line where it applies, and tickets they
want filed. Show it. Posting
it, filing the tickets and any verdict are the person's: they say so, and the team's own tools or
`/hi-review:review` do it.

## Writes

- **Local, no confirmation:** the PR's JSON and diff under the state dir, the journal lines, the
  PR's head fetched to `refs/hi-review/<n>` in a checkout of its repo.
- **Nowhere else.** No review, comment, label, ticket or lens edit from this skill.
