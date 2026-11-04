---
name: reader-test
description: Test a document, page, spec, PR description or ticket text on a fresh reader before a real person reads it — a sub-agent with no context from this conversation answers the questions the real reader will have, using the text alone, and reports where it got lost, what it had to guess, and what the text assumes. Use before handing any document to a reviewer, after restructuring a document, when the user asks "is this readable / understandable", or as the last step of /hi-docs:write-doc.
---

# /hi-docs:reader-test

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language, artifacts in English unless the user set otherwise, 2–4 options per question.

The author cannot see their own gaps: every undefined term reads as obvious to the person who
invented it. A reader with none of the author's context finds those gaps in minutes. This skill runs
that reader as a sub-agent and turns what it reports into fixes.

## 1. Set up

- **The text under test** is exactly what the real reader will get: the rendered page or the file,
  one page per run. A multi-page document is tested page by page, the overview first; a sub-page
  test also receives the overview, since the real reader comes from there.
- **The reader profile**, one or two sentences, from the document's declared reader: what they know
  ("has worked on this service for three years") and what they do not ("has not seen this
  investigation"). Never pass the author's notes, evidence files or this conversation.
- **Five to eight questions** the real reader will try to answer, written by you before the run:
  - the point: "What are the three most important findings?";
  - the action: "What are you asked to decide, and what changes with each answer?";
  - lookups: "Which problem affects the most users?", "Is X a confirmed bug or an open question?";
  - one question whose honest answer is "the text does not say", to catch confident guessing.
  Write down the answer you expect for each, from the source of truth, before dispatching.

## 2. Run the reader

Dispatch one sub-agent per page (in parallel when there are several), with a prompt that holds only:
the reader profile, the text, the questions, and these instructions:

> Answer each question using only this text. For every answer give: the answer; the passage it rests
> on; whether you had to guess or infer, and what. Then list:
> 1. every term, abbreviation or identifier you met before it was explained, with where, sorted
>    into (a) terms someone with the stated background would already know, and (b) terms this text
>    itself coined or uses in its own sense;
> 2. every place you had to re-read or jump elsewhere to follow;
> 3. anything that seems to contradict something else in the text;
> 4. what the text assumes you already know;
> 5. how long the page took you to understand, and where you would have stopped reading.
> Be blunt. Do not suggest rewrites; report what happened to you as a reader.

The reader is read-only: it reads the text it is given, nothing else, and never edits or posts.

## 3. Score and fix

- Compare each answer with the one you expected. A wrong answer, a guess, or "found it only after
  jumping" is a defect in the text, never in the reader.
- **Calibrate to the reader.** For an expert reader, only group (b) terms are defects: a fresh
  sub-agent does not know the codebase, and "fixing" group (a) would turn the document into a
  beginner's tour the real reader does not need. For a newcomer, both groups count.
- Group the findings: ungrounded terms; buried point; contradictions; missing information; length.
- Fix in the source of truth with the smallest edit that removes the named defect. Do not restyle
  passages nobody stumbled on.
- Re-run on the pages you changed, with fresh questions where the old ones were answered. Stop when
  a run surfaces no new defect of the first three kinds, or after three rounds — then report what is
  still unresolved instead of looping.

## 4. Report to the user

Per page: questions answered correctly out of the total, the defects found and fixed, anything left
open, and the reader's estimate of reading time. Keep it short; the fixed text is the deliverable.
