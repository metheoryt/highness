---
name: review
description: Review a GitHub pull request and submit it as one review, from the current session with no workspace (quick mode). A read-only reviewer subagent drafts the findings, a second reviewer pass tries to break each one before any card is shown, one question picks the verdict, and the review is posted with that verdict in a single call. Use when the user wants to review a PR, names a PR number or URL to review, or asks for a quick review. Args: <PR number or URL> [quick].
---

# /hi-review:review

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language (no words of theirs yet: `session.language` in their config), the review
itself in the PR's; 2–4 options per question; nothing reaches GitHub but the one review the person
chose.

One invocation reviews one PR. Every shell call starts with

```bash
L="${CLAUDE_PLUGIN_ROOT}/lib"; R="$L/review.sh"; CFG="$L/config.sh"
```

`${CLAUDE_PLUGIN_ROOT}` is this plugin's directory; if it is empty, use the "Base directory for
this skill" printed above, two levels up. Every call runs from a checkout of the PR's repo.

## 1. Load

1. `command -v gh >/dev/null && gh auth status >/dev/null 2>&1 && command -v jq >/dev/null`, else
   say `needs gh (authenticated: gh auth login) and jq` and stop.
2. The PR: a number, or a URL (owner/repo from it). This checkout must be that repo
   (`gh repo view --json nameWithOwner -q .nameWithOwner`); otherwise say
   `run /hi-review:review from a checkout of <owner/repo>` and stop. `<o>/<r>` below is that value.
3. `gh pr view <n> --json number,title,body,author,headRefName,baseRefName,headRefOid,state,closingIssuesReferences`
   and `ME=$(gh api user --jq .login)`. Merged or closed → say so and stop.
4. **The mode.** Quick is the only mode this version serves, and the default.
   - The author is `ME`, or `own` is in the args → say `own mode (checking your own PR) is not
     built yet` and stop. GitHub refuses an approve or a request for changes on one's own PR, and
     own mode posts nothing; a quick review would end in a post that cannot be made.
   - `deep` or `delta` in the args → say `<mode> is not built yet; quick reviews in this session`
     and ask once whether to run quick instead (Run quick / Stop).
5. Read in full, with the Read tool, one call per file: `${CLAUDE_PLUGIN_ROOT}/reference/voice.md`
   and `${CLAUDE_PLUGIN_ROOT}/reference/cards.md`. Then the person's own voice:
   `V=$(bash "$CFG" get --user .review.voice)` — set → Read that file too (a leading `~/` is the
   home directory), and keep its path as `VOICE` for the reviewer; unset → the default voice alone.

## 2. Head and range

```bash
H=$(bash "$R" head --pr <n> --base-ref <baseRefName> --repo <o>/<r>) || { surface its stderr; stop; }
BASE=$(printf '%s' "$H" | cut -f1); HEAD=$(printf '%s' "$H" | cut -f2)
```

`HEAD` is the PR head under the private ref `refs/hi-review/<n>`; `BASE` its merge-base with the
base branch, so the diff is the one GitHub shows. Both come from the remote that names `<o>/<r>`
(a fork checkout's `upstream`), else `origin`. Nothing is checked out. Say the size in one line
(`git diff --shortstat "$BASE" "$HEAD"`).

## 3. Intent

What the change was asked to do, before any finding:

1. The PR body, and each issue in `closingIssuesReferences`
   (`gh issue view <number> --repo <owner/repo of the issue> --json title,body`).
2. The team's own source, when it set one: `bash "$CFG" get .review.intent` prints a text the
   team wrote (where its specs live, how a ticket key maps to them, which tool reads them).
   Follow it with the tools this session has; a source it names that this session cannot reach
   is a miss, said in step 4.
3. A handful of lines: what the change is for, what the spec settled, the non-goals.
4. Nothing found, or a source unreachable: one line, `intent: unavailable — <why>; findings are
   spec-blind`. Never stop on it, and never skip it silently.

## 4. Gather

1. **CI** on the head: `gh pr checks <n>` → `CI: passing`, `CI: failing — <name>: <reason>; …`
   or `CI: pending`. The reason is the failing step's command and cause in a few words, from the
   check's log when it is an Actions job (`gh run view --job <id> --log-failed`); otherwise the
   check's name alone.
2. **Threads:** `bash "$R" threads <o>/<r> <n>` — one JSON object per thread, each comment marked
   `bot` (a `[bot]` login, or one the team lists under `review.bots`). A stderr line that the read
   was cut, or a thread with `truncated: true`, is said above the cards.
3. **The graph at the head**, when the `mcp__gortex__*` tools are present: this checkout's graph
   id from `mcp__gortex__workspace` (operation `info`, the `graph-…` id) gives
   `VIEW={kind: "commit", value: "<HEAD>", graph_id: "<id>"}`. Gortex absent or not answering →
   no `VIEW`; the reviewer says `graph: unavailable` itself.

## 5. Draft

One `hi-review:reviewer` subagent (Agent tool, `subagent_type: "hi-review:reviewer"`) with
`PHASE=review`, `PLUGIN=${CLAUDE_PLUGIN_ROOT}`, `WT=$(git rev-parse --show-toplevel)`,
`BASE_SHA=$BASE`, `HEAD_SHA=$HEAD`, `INTENT` (step 3's lines, or the miss line), `CI`, `THREADS`,
`VIEW` and `VOICE` when set. A `NEED_CONTEXT`, `NEED_PERMISSION` or `GIT_ERROR` reply → surface
it and stop. Keep its `graph:` line, if any, for the cards.

## 6. Verify

Nothing reaches a card unverified. A **second, fresh** `hi-review:reviewer` subagent — a new
Agent call, never the drafting one resumed, so it does not defend its own draft — with
`PHASE=verify`, the same `PLUGIN`, `WT`, `BASE_SHA`, `HEAD_SHA`, `INTENT`, `VIEW` and `VOICE`, and
every finding and `UNANCHORED` line as `FINDINGS_IN`. Over about ten findings, split them into
batches of about ten, all launched in one message.

Apply its lines: `REFUTED` → drop; `WEAKENED` → re-label; `REMEDY` → replace the fix. A batch
that failed or never answered → its `blocking` findings drop to `note`, each saying it was not
verified. No findings → no verify pass.

## 7. Before any card

1. **Intent:** a finding the spec settled → drop; one contradicting it → a question about the spec.
2. **Anchors:** every anchored finding must be one GitHub accepts:
   `bash "$R" anchor "$BASE" "$HEAD" <path> <line|start-end> [LEFT]` (`LEFT` for a `(base)`
   anchor). Exit 1 → the finding has no anchor and folds into the body. Exit 3 → surface the
   error and stop.
3. **The person's own pending review:** `bash "$R" pending <o>/<r> <n> "$ME"` (exit 1: none). Its
   comments become `(your draft)` cards, part of what will be posted, and a new finding that
   repeats one is dropped. Each goes through the same anchor check (its `side`, `start_line`):
   one with no `line`, or a line no longer in the diff, is outdated — its card says
   `⚠ line no longer in the diff (outdated) — goes into the body`, and its text folds into the
   body as `<path>: <comment>`, so posting never drops it and GitHub never rejects the review
   for it.

## 8. Cards and the one question

1. Render, in this order (`cards.md`): the lines above the cards; the cards; the review body (one
   sentence, `voice.md` §D, with every unanchored finding folded in); then the exact payload each
   answer would post. All in this turn.
2. One `AskUserQuestion`, its text naming the number of blocking findings. The reviewer's
   proposed verdict is the first option, marked recommended. With findings or a draft:
   - **Approve**: submitted as an approval, with the body and the comments;
   - **Request changes**: submitted as a request for changes;
   - **Comment**: submitted as a comment review;
   - **Terminal only**: nothing is posted.
   With no findings and no draft: **Bare approve** (an approval with no body and no comments) /
   **Comment** (a body-only review) / **Terminal only**.
3. The answer is the approval to post: no second question, no command for the person to run.
   Edits ("drop 2", "softer on 3") → re-render the changed cards and ask again.

## 9. Post

1. Re-run step 7.3 right before the write. A pending review appeared or changed → re-render and
   ask again.
2. The payload, in the repo's git directory (never in the tree):

   ```bash
   D="$(git rev-parse --path-format=absolute --git-common-dir)/hi-review"; mkdir -p "$D"
   ```

   Write the body to `$D/<n>.body.md` and the comments to `$D/<n>.comments.json` (a JSON array of
   `{path, line, side, body}`, plus `start_line` for a span; `side` is `LEFT` for a `(base)`
   anchor) with the Write tool, then

   ```bash
   bash "$R" payload --event <APPROVE|REQUEST_CHANGES|COMMENT> --body-file "$D/<n>.body.md" \
     --comments-file "$D/<n>.comments.json" > "$D/<n>.payload.json"
   ```

   A bare approve passes `--event APPROVE` alone. Exit 2 → its stderr names what GitHub would
   reject; fix it and build again.
3. The person's pending review exists → its comments are already in the payload. Keep it first,
   `bash "$R" pending <o>/<r> <n> "$ME" > "$D/<n>.pending.json"`, then delete it (GitHub holds one
   pending review per person per PR, so it must go before the post):
   `bash "$R" delete-pending <o>/<r> <n> <id>`.
4. `bash "$R" post <o>/<r> <n> "$D/<n>.payload.json"`: one call that creates and submits the
   review with its verdict. Never a pending draft left behind, never a second call to submit it.
   It fails → put the person's draft back when there was one
   (`bash "$R" restore-pending <o>/<r> <n> "$D/<n>.pending.json"`), say what failed and that
   `$D/<n>.payload.json` holds everything; never retry silently.
5. Report the state and the `html_url` as the last thing on screen. Delete the files in `$D` for
   this PR once the state is `APPROVED`, `CHANGES_REQUESTED` or `COMMENTED`.

## Writes

- **GitHub:** one POST of the review with the chosen verdict, and a DELETE of the person's own
  pending review when one exists. Never a reply in anyone's thread, never a label.
- **Local, no confirmation:** the ref `refs/hi-review/<n>`, the payload files under the git
  directory.
- **Shown first, then on the answer:** the post.
