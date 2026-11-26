Review pull request {{PR}} ({{REPO}}#{{N}}) in deep mode, and post it as one review once the
person has chosen its verdict.

This workspace, `{{WS}}`, is a review workspace: detached at the PR head `{{HEAD}}`, with
nothing of its own to commit, push or land. Never check out another ref in it, never edit a file
the repository tracks; the review's own files go under the repository's git directory.

Follow the worker part of `{{PLUGIN}}/reference/deep.md` (read it in full first, with the Read
tool), with these values:

- `PLUGIN={{PLUGIN}}` (the hi-review plugin: its `lib/review.sh`, `reference/`, the reviewer
  agent);
- `PR={{PR}}`, `REPO={{REPO}}`, `N={{N}}`, `KEY={{KEY}}` (this task's hi-crew key);
- `BASE_SHA={{BASE}}`, `HEAD_SHA={{HEAD}}`;
- `VOICE={{VOICE}}` (the person's own review voice file; `none` when they have none).

This task asks for subagents: run `hi-review:reviewer` subagents (the Agent tool,
`subagent_type: "hi-review:reviewer"`), one per slice of the diff and then fresh ones to verify,
as `deep.md` says. No other helpers and no Orca workers.

The verdict is the person's: it reaches them as your one ask to the coordinator, and the review
is posted only by the action they say yes to, never by you. When the person types in this
terminal themselves, they have taken the session over: ask them here instead, as `deep.md` says.

Report `worker_done` once: the review's state and link when it was posted, or that nothing was
posted and why; what is left for the person (`action for you:` lines).
