# Cards: how a drafted review is shown before anything is posted

Read by `/hi-review:review` before rendering. The person reads every card, then answers one
question; what they see is exactly what would be posted.

## Drafted-finding card

One per finding that survived the verify pass:

````
💬 <n>. <basename(path)>:<line> · <severity>

```diff
<curated context>
```

> <the comment, verbatim>
````

- **Numbered**, so the person can say "drop 2" or "softer on 3".
- **Curated context, not a raw hunk:** the anchored line plus what it takes to judge the comment
  (the definition it calls, the sibling branch it contradicts) from the same file at the head,
  with the uninteresting spans collapsed to one `⋯ (<n> lines)` line. The anchored line keeps its
  `+`/`-`, or gets a leading `>` when it is context.
- **At most ~20 lines per card**, trimmed for a phone screen.
- **The comment verbatim**, in the voice of `voice.md`. A ` ```suggestion ` block renders inside
  the quote.
- A finding the verify pass weakened carries its new severity; one it corrected carries the
  corrected fix. A refuted finding is not shown.
- Separate consecutive cards with a `---` rule.

## Existing-draft card

Each inline comment of the person's own pending review gets a card marked `(your draft)`, with one
advisory line after the quote:

`````
💬 <n>. <basename(path)>:<line> (your draft)

```diff
<curated context, as above>
```

> <the person's comment, verbatim>

_<assessment>_
`````

- **Assessment:** `✓ solid — keeping` · `⚠ already raised in @<x>'s thread` · `⚠ line no longer
  in the diff (outdated)` · `⚠ thin — consider expanding or dropping`. An obviously fine comment
  needs none.
- **"Already raised" means raised and fixed at the head.** A thread resolved without the fix
  covers nothing; when it cannot be checked, write `⚠ raised in @<x>'s thread — not verified
  against the head`.
- **Advisory only:** the person's comments are never edited; they act on the flagged ones.

## Lines above the cards

In this order, each only when it has something to say:

1. `intent: <where it came from>` — or `intent: unavailable — <why>; findings are spec-blind`.
2. `graph: <base checkout | unavailable — diff-only> (<why>)` when the review did not have the
   head's graph.
3. `CI: failing — <check>: <reason>` or `CI: pending` — before any finding, never as a footnote.
4. `skipped on a thread (unchecked): <file>:<line> — <theme>`.
5. `action for you: <what>, <where>`.
