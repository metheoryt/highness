# Review methodology

Read by the `hi-review:reviewer` subagent, in both of its phases. Heuristics, not a checklist:
skip what a change does not warrant.

## Intent first

What the change was asked to do — the PR body, the issues it closes, the team's spec — is read
before drafting, never after. Settled by the spec → not a finding. Silent → review normally.
Apparently contradicting the spec → a question about the spec, not a defect. No intent available
→ review anyway and say so once, as a `note`.

## Read the head, not the checkout

The range is diffed by sha: `git diff <BASE> <HEAD>`, whatever is checked out. When the checkout
is not at the head (a quick review runs from wherever the person is, usually the trunk), the files
on disk are not the PR's. Read every file as `git show <HEAD>:<path>`, never with Read or `cat`,
or a thread looks fixed and a "both paths" claim is checked against code the PR never had.
Nothing is ever checked out: the tree is the person's.

## The graph walk (when a code graph is available)

For each meaningfully changed symbol:

1. **Who is affected:** callers and usages. Wide reach earns more scrutiny; look for callers that
   rely on the old contract.
2. **Where the value goes:** when it can reach a sink (auth, SQL, shell, network,
   serialization), trace it there.
3. **What is already known:** recorded invariants about the changed code — the graph's memory,
   the repo's own notes. A recorded invariant wins unless the diff deliberately supersedes it.

With gortex, a quick review queries the PR head through a commit view of the checkout's graph
(`VIEW`). An answer with no resolved commit means the view is not served: fall back to the
checkout's graph and say the callers are the trunk's, so a caller the PR adds is missed. No graph
at all → say so first, review the diff with `git grep` at the head (`git grep <pattern> <HEAD>`),
and never imply depth you did not have.

## Claims

- **An asymmetry is a claim about code the diff did not touch.** Before "A filters this and B
  does not", read B. Cannot see it → drop the finding, or ask about the one side you read.
- **A resolved or outdated thread is a click, not a fix.** Check the condition at the head before
  dropping a finding a thread covers. Fixed → drop it. Still live → it is your finding, with one
  clause saying a resolved thread covered it. Not checkable from code → a `SKIPPED:` line.
- **A finding whose consequence you cannot state is not a finding.** Name what goes wrong, for
  whom, on which input.

## Tests

The test gate is CI on the head commit (`gh pr checks`). A failing or pending check is reported
before the findings, never as a footnote, and a missing result never reads as passing. The
reviewer never runs a test suite itself.

## Severity and verdict

- `blocking`: correctness, security, data loss, a caller the change breaks, a widened taint path.
- `nit`: style, naming, small clarity. Never blocks.
- `note`: an observation, or an optional suggestion.

Proposed verdict: any `blocking` → Request changes; only `nit`/`note` → Comment; nothing of
substance → Approve. It is a proposal; the person decides.

## Verifying a finding

A second pass, by a reviewer that did not draft the finding, tries to break it before the person
sees it. For each finding, look for what would make it wrong:

- the line it anchors to says something else at the head;
- the "missing" check, caller or test exists elsewhere (read it, at the head);
- the input that triggers it cannot reach this code;
- the spec settles the behaviour it calls a defect;
- its proposed fix is itself wrong (a caller relies on the current shape, the fix breaks the
  rollout order).

A pass that confirms everything has done nothing. Confirm only what survived a real attempt.
