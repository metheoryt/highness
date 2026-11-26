---
name: brief
description: The review entry for a PR where a review bot already runs (without one, /hi-review:review). Prepares the person's review as a brief of 2-4 items for them to decide, picked by their review lens, instead of a list of findings — the bot finds the bugs, the person adds their judgment. Context from zero, per item the agent's own view and recommendation, then the question; where people's reviews agree or clash; a bold idea, if any; apart, at most three defects no one raised, each verified by a second pass. A large diff is read in slices by reviewer subagents, as deep review does. Ends by offering to post the person's review through the review skill's submit, one verdict question, never without their yes. Journals each item's outcome. Use when the user says "brief me on PR <n>", "what should I look at in <PR>", "подготовь выжимку по PR", «что мне посмотреть в PR», "how are my briefs doing", or the team's tooling offers a brief for a PR waiting on their review. Args: <PR number or URL>, or `stats`.
---

# /hi-review:brief

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language (no words of theirs yet: `session.language` in their config); 2–4 options per
question. **This skill posts nothing until the person says yes**: no review, no comment, no label,
until step 8, and there only the one review they chose in its question, their own answer in this
session. The brief is for the person; what they decide reaches the PR only through them.

**Brief or review.** This is the entry for a PR where a review bot already runs: the bot finds the
bugs, the brief brings what only the person's judgment adds. On a repo without a review bot,
`/hi-review:review` (quick, or deep for a large diff) reviews the code itself.

Every shell call starts with

```bash
B="${CLAUDE_PLUGIN_ROOT}/lib/brief.sh"; CFG="${CLAUDE_PLUGIN_ROOT}/lib/config.sh"
R="${CLAUDE_PLUGIN_ROOT}/lib/review.sh"
```

`review.sh` is the review skill's own script: the brief cuts a diff into slices and posts through
it, never through a copy.

`${CLAUDE_PLUGIN_ROOT}` is this plugin's directory; if it is empty, use the "Base directory for
this skill" printed above, two levels up. Run from the team's workspace or a checkout of the PR's
repo, so the team's config applies.

`stats` in the args → `bash "$B" stats` (add `--since <date>` when the person names a period), show
it in two or three plain sentences, and stop.

## 1. The PR

`bash "$B" source <pr>` prints `<json file><TAB><diff file><TAB><summary>`. Exit 3 → surface its
stderr and stop. Merged or closed → say so and stop.

Read the JSON file with the Read tool: the title, the body, the author, and the people's and bots'
`reviews`, `threads` and `comments`.

**The head**, in a checkout of the PR's repo (the current repo, or the team's clone of it; GitHub
and Forgejo both serve `pull/<n>/head`); nothing is checked out:

```bash
H=$(cd <checkout> && bash "$R" head --pr <number> --base-ref <the JSON's base> --repo <the JSON's repo>)
BASE=$(printf '%s' "$H" | cut -f1); HEAD=$(printf '%s' "$H" | cut -f2)
```

A `HEAD` other than the JSON's `head` means a push since: read the PR again. No checkout here, or
the fetch failed → say in one line that the brief runs on the diff file alone, with no slices, no
defects shown and no post; read the diff file and go on.

**The size:** `(cd <checkout> && bash "$R" slices "$BASE" "$HEAD")`, the same cut deep review
uses. One slice → read the diff file with the Read tool, a large one in parts, the hunks that
carry the change first. Several → do not read it whole here: step 3.3 reads it through reviewers.

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
3. **A diff of several slices** (step 1) is read through one `hi-review:reviewer` subagent per
   slice (Agent tool, `subagent_type: "hi-review:reviewer"`), launched, retried and named as
   worker step 3 of `${CLAUDE_PLUGIN_ROOT}/reference/deep.md` says. Each gets `PHASE=review`,
   `PLUGIN=${CLAUDE_PLUGIN_ROOT}`, `WT=<the checkout>`, `BASE_SHA`, `HEAD_SHA`, `INTENT` (1 above),
   `THREADS` (`bash "$R" threads <repo> <number>` for a GitHub PR, else none), `SLICE`, `SLICE_OF`
   and `GIST=yes`. Their `GIST` lines are your reading of the diff: pick the items from them, and
   read only the hunks an item needs yourself (`git diff "$BASE" "$HEAD" -- <path>`). Their
   `FINDINGS` and `UNANCHORED` lines are step 5's candidates. A slice that failed twice is named in
   the brief as `not read: <paths>`.

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
or exposed, a broken contract. On a sliced diff the candidates are the slices' `blocking`
findings instead (step 3.3); their nits and notes are left out. Leave out style, naming and small
things. Drop each one that a review, thread or comment on the PR already raised, open or not: read
them first.

Nothing reaches the person unverified. What is left goes to a second pass:

1. A fresh `hi-review:reviewer` subagent (Agent tool, `subagent_type: "hi-review:reviewer"`),
   never one of step 3.3's resumed, with `PHASE=verify`, `PLUGIN=${CLAUDE_PLUGIN_ROOT}`,
   `WT=<the checkout>`, `BASE_SHA` and `HEAD_SHA` from step 1's `H`, `INTENT` (step 3's text) and
   the defects as `FINDINGS_IN`, one per line: `<path>:<line> | blocking | <what goes wrong and the
   fix>`. Over about ten defects, batches of about ten, all launched in one message.
2. `CONFIRMED` stays; `WEAKENED` and `REFUTED` drop; `REMEDY` replaces the fix. No defects to check → no pass.

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
want filed. Show it. Filing the tickets is the person's, through their own tools.

### Posting it

Offered only when all of these hold: the PR is on github.com (the JSON's `url`), `gh` is
authenticated, step 1 got the head, and the person answers this session's `AskUserQuestion`
themselves (a session whose answers are relayed, such as a hi-crew worker, never posts a brief).
Otherwise say in one line that the draft is theirs to post (the team's own tools) and stop.

Every call below runs in the checkout, with
`D="$(git rev-parse --path-format=absolute --git-common-dir)/hi-review"; mkdir -p "$D"` and
`ME=$(gh api user --jq .login)`. These are the review skill's steps 7–9
(`skills/review/SKILL.md`) on the brief's draft:

1. **Anchors.** Each comment: `bash "$R" anchor "$BASE" "$HEAD" <path> <line|start-end> [LEFT]`.
   Exit 1 → it folds into the body as `<path>:<line>: <comment>`, since GitHub rejects the whole
   review for one comment off the diff. Exit 3 → say the error; no post.
2. **Their pending review.** `bash "$R" pending <repo> <number> "$ME" > "$D/<number>.pending.seen.json"`
   (exit 1: none; remove the file). Its comments are part of what will be posted, as the review
   skill's step 7.3 says: each through the anchor check, an outdated one folded into the body, a
   draft comment that repeats one of theirs dropped. Posting replaces that pending review, so a
   comment left out here would be lost.
3. **Show and ask.** Render the comments as cards (`${CLAUDE_PLUGIN_ROOT}/reference/cards.md`)
   with the body under them: exactly what would be posted. Then one `AskUserQuestion`, its first
   option the verdict that follows from what the person decided, marked recommended:
   **Approve** / **Request changes** / **Comment** / **Terminal only** (nothing posted). The
   person's own PR (the author is `ME`) → **Comment** / **Terminal only**: GitHub refuses the
   others there; with nothing to post on it, say so in one line and ask nothing. Otherwise no body
   and no comments → **Bare approve** / **Terminal only**. The answer is
   the yes: no second question. Edits ("drop 2", "softer on 3") → render again and ask again.
4. **Build.** The body to `$D/<number>.body.md` and the comments to `$D/<number>.comments.json`
   with the Write tool (the review skill's step 9.2 shape), then
   `bash "$R" payload --event <APPROVE|REQUEST_CHANGES|COMMENT> --body-file … --comments-file … > "$D/<number>.payload.json"`
   (a bare approve: `--event APPROVE` alone). Exit 2 → fix what its stderr names, build again.
5. **Post**, once:

   ```bash
   bash "$R" submit <repo> <number> "$D/<number>.payload.json" --head "$HEAD" --login "$ME" \
     [--seen-pending "$D/<number>.pending.seen.json"]
   ```

   `--seen-pending` only when that file exists. It posts only what the cards showed: exit 4 when
   the PR's head moved (say so; nothing is posted, and a brief of the new head starts at step 1)
   or the pending review is not the one shown (back to 2, show again, ask again). Exit 3 → say what
   failed and that `$D/<number>.payload.json` holds everything; never retry silently. Exit 0 →
   the review's state and `html_url` last on screen, and the files in `$D` for this PR deleted.

## Writes

- **Local, no confirmation:** the PR's JSON and diff under the state dir, the journal lines, the
  PR's head fetched to `refs/hi-review/<n>` in a checkout of its repo, the payload files under
  its git directory.
- **GitHub, only on the person's yes in this session:** one review with the verdict they chose,
  through `review.sh submit`, which replaces their own pending review when they had one.
- **Nowhere else.** No reply in anyone's thread, no label, no ticket, no lens edit.
