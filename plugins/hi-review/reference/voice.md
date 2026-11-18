# Voice for review findings

Read by the reviewer subagent before drafting and by `/hi-review:review` before rendering. It
applies to every finding and to the review body, whoever drafted them.

The review is posted under the person's own account, as their review. **The person's own voice
comes first:** when `review.voice` in their personal config names a file, it is read after this
one and wins where the two differ (their register, their language for reviews, a sign-off they
want or forbid). This file is the default for everyone else.

## A. Lean

One point per comment: one sentence, two at most. The anchored lines carry the where; the comment
carries why this line is flagged. Do not restate the code, explain the language, link docs or open
with a preamble. Deep reasoning: post the conclusion and offer to expand.

## B. A view, and one fix

Prefer observations and questions over imperatives; the author decides whether to act. When you
may be missing context, say so. No inflated praise, no padding, no thanks-for-the-PR opener.

- **Name one fix, never a menu.** The softness is about whether to act, never about what to do.
  "Could do X or Y, your call" hands the deciding back to the author.
- **A fix needs its constraints in hand**: rollout order, what the spec requires, a caller that
  relies on the current shape. Without them, state the defect and its consequence, name the
  missing constraint as a fact someone can check ("does any caller rely on the short return?"),
  and stop.
- **Directness tracks severity.** `nit`/`note`: soft, often a question. `blocking` judgment call:
  a clear opinion. `blocking` with an obvious fix: say it directly, with the fix.
- A `nit:` or `optional:` prefix goes only on skippable comments; blocking ones carry no label.

| Instead of | Prefer |
|---|---|
| "Extract this into a helper." | "This mirrors the block in `X`. Reads cleaner pulled out." |
| "Could pull it out, or leave it with a comment, your call." | "Reads cleaner pulled out." |
| "Add a null check." | "Is `user` guaranteed here? Looks like it can be undefined on the early return." |

## C. Suggestions show the shape

When the fix fits entirely inside the anchored lines and drops in as is, add a ` ```suggestion `
block framed as illustrative ("maybe something like:"). Not when it spills past the anchor or
touches other sites, where a one-click apply would half-edit the file: describe those in prose.

## D. The summary body

One sentence: the honest overall read, with any finding that has no line to anchor to folded in.
The shape is `2 things, the rest is good`: a count and a verdict, in numerals. No file lists, no
severity tallies, no headings.

## E. Housekeeping is the person's action

A stale thread to resolve, a label, a re-request, a leftover file to delete: none of these is a
comment to the author. Each is listed in the preview as `action for you: <what>, <where>`.

## F. Never a reply

Findings are the person's own review. A drafted reply into someone else's thread is not part of a
review. A point the code still has at the head is raised as a new finding, even on a line with a
resolved thread.

## G. Form

- No self-reference ("I reviewed", "as an AI"), no narration of the process, no tool name or
  generated-by trailer unless the person's voice file asks for one.
- One paragraph is one line in the source: no hard line breaks; GitHub wraps it.
- No em-dash clause-joins: two clauses are two sentences.
- Never cite a commit sha in prose; say what changed.
