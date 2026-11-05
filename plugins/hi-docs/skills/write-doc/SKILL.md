---
name: write-doc
description: Write or restructure a document that teammates must read and act on — a domain model, design doc, spec, investigation report, findings list, or a long wiki page — so it reads in short sittings, from the general to the particular, with the point first and only the important things emphasised. Use when drafting such a document, when the user says a document is too long, too dense or "written for the author", when splitting a page into sub-pages, or before handing a document to a reviewer. Pair with /hi-docs:reader-test before anyone reads it.
---

# /hi-docs:write-doc

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language, artifacts in English unless the user set otherwise, 2–4 options per question.

A document is for a reader with a job to do and limited time. Every rule below serves one test: **can
the named reader get what they need in one sitting, without decoding anything first?**

## 0. Load the user's own calls first

If the user keeps notes on how they write documents (a memory file or a personal guide they point
you to), read them in full before composing. Their recorded calls win over this skill wherever the
two differ; do not paraphrase them here, they drift.

Then load the team's writing conventions, if the team set any:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/config.sh" get .docs.conventions
```

Exit 1 or empty output → none, go on. Otherwise it prints a file path; `~/` is the home
directory, and a relative path resolves against the git toplevel (`git rev-parse --show-toplevel`).
The key may come from the repo's own `.claude/highness.json` or from the user's config, per repo
(`repos.<owner>` overlays, for a team repo that cannot carry the file). If that file is readable, Read it in
full; if not, say so in one line and go on. A team convention there for a kind of document (a
decision-record skeleton, say) wins for the team's documents of that kind; the user's calls and
this skill still govern everything else.

## 1. Declare before writing

Write this down in your working notes (not in the document) and settle it with the user in chat:

`Reader: <a named person or role> | Knows already: <what they bring> | Must do after reading: <the verb> | Not covered: <what this deliberately leaves out>`

- **The reader's prior knowledge decides the depth.** An expert in the code needs findings and
  questions, not a tour of the basics; a newcomer needs the model first. When two readers differ,
  the overview serves the broader one and the sub-pages go deeper.
- **"Must do" is a verb**: decide, answer the questions, fix, approve. The document is built around
  that act; everything that does not help it is a sub-page or an appendix.

## 2. Shape: overview plus sub-pages

- **Overview first, one screen.** What this is and why it exists (two sentences), how to read it
  (which page for which need, with reading time), the 3–5 findings that matter most in plain words
  with their numbers, and what the reader is asked to do. No evidence links on the overview beyond
  what a finding needs.
- **Sub-pages of 10–15 minutes each**, roughly 150–300 lines of rendered prose. One topic per page;
  the page title names the topic, not the section number. Past ~800 lines of prose, a document must
  be split.
- **General to particular**, at every level: document, page, section, item. Model before rules,
  rules before exceptions, the claim before its evidence.
- **Order by what the reader acts on.** Within a list of findings, sort by impact (money, users,
  data loss) before identifier order; group confirmed problems apart from open questions apart from
  settled items, and keep settled items short.
- **One fact, one home.** A fact lives on one page; the others link to it. A summary routes, it
  never restates details that can drift.

## 3. Grounding: never lean on what the reader has not met

A concept, term or identifier is usable only after the reader walked in knowing it or met it on an
earlier line. This is the most common defect in a document written by its investigator.

- **An identifier never stands alone.** `D3` means nothing on first contact; write
  "a retry after a timeout never charges the card twice (D3)". The plain claim carries the
  meaning, the ID is the handle for tickets and cross-references.
- **Questions to the reader must be answerable from the question itself**: state the situation, the
  options, and what each answer changes. Do not make the reader scroll to understand what is asked.
- **Define a term at first use and keep it**: one term per concept, the whole document through.
  More than about five project-specific terms earn a short glossary on the model page.

## 4. Each item: claim, impact, evidence

Every finding, rule or question uses the same shape, in this order:

1. **The claim in one plain sentence**: what happens, or what should happen. No code names in it.
2. **Why it matters**: who or what is hurt, with a number (users, rows, money, frequency) and its
   date. An adjective is replaced by a number wherever one exists.
3. **Status**: ticket or "no ticket", proven how (failing test, production data, code read).
4. **Evidence last, on one line**: links, file paths, test names. Inline citations every few words
   bury the claim; they go to the end of the item.

Code identifiers (functions, settings, tables) belong in the evidence line or in a section meant for
the person who will fix it — never in the claim sentence.

## 5. Emphasis is earned

- **Bold marks at most one phrase per item**: the claim or the number that changes a decision. A
  list where every item starts bold has no emphasis left. Item labels go in plain text or a table.
- **A callout panel (info / warning / decision) is for the few things the reader must not miss**:
  the key findings on the overview, a decision that is pending, a hazard. Two or three per page at
  most.
- **Tables** only when items share two or more properties and the reader compares across them (a
  service × state × impact table, yes; a two-column table of prose, no).
- **Headings name the content** ("Refunds mark the wrong payment"), never promise it ("Why this
  matters"). Sentence case.

## 6. Sentences

- One claim per sentence; about 20 words on average, 35 at most. Active voice with a named actor.
- Plain verbs and concrete nouns; numbers over adjectives; label an estimate as an estimate.
- Cut the machine tells: no "it is important to note", no closing summary sentences, no rhetorical
  triads, no "not X but Y" framing, no inflated adjectives (crucial, robust, comprehensive), no
  bold-lead bullets down a whole list, no emoji furniture, no assistant residue ("here is an
  overview").
- Read each paragraph as if saying it to a colleague; rewrite what you would not say aloud.
- The document's language is the one the user set for artifacts; the chat stays in the user's.

## 7. Truth while rewriting

- **A restructure never adds or drops a fact, number, date, name or source.** Before replacing a
  version, diff the set of IDs, numbers and links between old and new; every loss is deliberate,
  named to the user and quoted in the cut file.
- **What a rewrite removes goes to a cut file.** Restructuring or shortening an existing document,
  quote every removed passage in a side file (`<stem>.cut.md` in the scratchpad, or next to the
  draft; never committed unless the user asks), each with a one-line reason: repeats a fact kept
  elsewhere, detail the diff will show, history. Rewording needs no entry; dropping a fact from a
  sentence does.
- **The fact diff closes before handing over.** List every decision, contract, invariant and
  reviewer-thread request in the source (the doc PR's review threads, a wiki page's inline
  comments); each one is in the new text or in the cut file. A fact in neither is a defect:
  restore it. A decision turned into an open question, or the reverse, is a change of meaning, not
  a restructure: restore it or ask the user.
- **Every claim about code is checked against the code, in the text you wrote.** For a document that
  describes code, read each statement of what the code, CI, a migration or a tool does against the
  code at the ref the document describes, and note `path:line` in your working notes. Rewording a
  true claim can make it false, and a sentence added to explain a step is a new claim ("CI fails
  without the migration" is checked, not assumed). A wrong description of current behaviour → fix
  the text; a rule or target the code breaks stays, per the last bullet here. Unverifiable → mark
  it `[unverified: …]` or drop it.
- Never fill a gap with a plausible guess. Mark it `[source wanted: …]` or ask.
- Describe the current state, not the document's history: no "resolved in the review of …", no
  "the earlier draft said X", no "was Q3", no SHAs in prose except the one snapshot the document was
  checked against, stated once in the overview. A settled item is stated as a current fact ("by
  design", "fixed by …"), not as the story of how it was settled.
- **Identifiers referenced from outside (tickets, tests, other docs) stay stable**, gaps and all;
  never renumber them. Lists that nothing outside references (the questions to the reader) are
  numbered 1..N with no gaps.
- When code breaks a stated rule, the rule stands and the violation is listed; never rewrite the
  rule to match the bug.

## 8. Wiki delivery (Confluence and similar)

- Keep one source of truth. When the page is generated from a repo file, say so in one line at the
  top and regenerate from the file; never let the two drift.
- Sub-pages are children of the overview page; their titles read well out of context in search.
- Links the reader cannot open (a private repo, a local path) are dead links: render them as plain
  text with one line saying who to ask, or publish the material.
- **Once a reviewer comments inline, stop full-body republishing**: a full replace can orphan
  inline comments. Edit the affected blocks only, and tell the user which copy is now authoritative.
- Create in a personal or draft location first; mentioning or sharing with the reader is the user's
  call.

## 9. Before handing it over

1. Run the checklist: overview fits one screen; every ID is glossed at first use; every item opens
   with its claim; no page over ~15 minutes; emphasis budget respected; the fact diff closes against
   the cut file; every claim about code checked in the final text.
2. **The team's own check.** When the conventions of section 0 name a check to run on this kind
   of document before review (a skill or script that compares a design doc with the code, say),
   run it the way they say, before the reader-test. Fix or list each thing it finds. When they
   name a check that is not available in this session, or that needs something missing yet (a
   PR), skip it and say so in one line. A full rewrite such a check proposes is a proposal: merge
   it through this skill's rules, never adopt it wholesale.
3. Run `/hi-docs:reader-test` on the overview and each sub-page, last.
4. Report to the user: page links, reading time per page, the cut file's path, claims the code
   contradicted or left unverified, what the team's check and the reader-test found and what was
   fixed, what is still open.

Sources this skill was synthesised from: anthropics/skills `doc-coauthoring` (reader testing);
riekelt/technical-writer `technical-writing`, `documenting-legacy-codebases`,
`reviewing-technical-prose` (conclusion-first, one fact one home, banned constructions, truth rules);
mattpocock/skills `writing-shape` and `writing-beats` (grounding).
