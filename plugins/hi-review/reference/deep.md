# Deep mode — a review worker under the person's coordinator session

Read by `/hi-review:review` when the args say `deep`, by the worker that review starts, and by a
coordinator Orca wakes for that worker (the worker's hi-crew facts name this file as `guide`).
`/hi-review:brief` reads a large diff through the same slices: worker step 3 below.

Deep mode is the quick review (`skills/review/SKILL.md`) moved into its own session and workspace:

- **its own workspace:** a review workspace from hi's `wt.sh create --kind review`, detached at the
  PR head, so the reviewers read the head as files, and the person can open the session in Orca
  to watch it or take it over;
- **slices:** the diff is cut into slices (`review.sh slices`) and each goes to its own reviewer
  subagent, so a large diff is read in full rather than skimmed by one context;
- **the person stays where they are:** the worker is a hi-crew worker under the session that
  started it. Its one question, the verdict, is an Orca ask to that session; the post is a
  prepared hi-crew action that runs only on the person's yes, given there.

The machinery is hi-crew's (`crew.sh dispatch`, `relay`, `action`, `resume`); this file is only
what is review-specific. Below, `$PLUGIN` is the hi-review plugin directory, and

```bash
R="$PLUGIN/lib/review.sh"
C="${HI_CREW_SH:-$PLUGIN/../hi-crew/lib/crew.sh}"   # hi-crew, installed beside hi-review
W="${HI_WT_SH:-$PLUGIN/../hi/lib/wt.sh}"            # hi, installed beside hi-review
D="$(git rev-parse --path-format=absolute --git-common-dir)/hi-review"   # the review's files
```

`$D` is in the repository's git directory, shared by the main checkout and every workspace, so
the coordinator reads what the worker wrote there.

## Coordinator: start the review

From `/hi-review:review <pr> deep`, in the person's session (it becomes, or already is, a hi-crew
coordinator).

1. **What it needs.** `[ -f "$C" ] && [ -f "$W" ]`, else say
   `deep mode needs the hi-crew and hi plugins beside hi-review` and ask once whether to run quick
   instead (Run quick / Stop). `O=$(bash "$C" orca)`; `$O orchestration run-current` fails →
   say Orca orchestration is off (Settings → Orchestration) and ask the same.
2. **The PR.** Steps 1.1–1.4 and 1.6 of the skill (gh, the repo, the PR, `ME`, brief or review,
   the own-PR stop, the voice files; `V` is the person's voice file or empty).
3. **One worker per PR.** `KEY=$(bash "$R" key <o>/<r> <n>)`. `bash "$C" get "$KEY"` with open
   facts → a worker already reviews it: show its workspace and stop. One lost without reporting
   (a usage limit, an account switch) continues with `bash "$C" resume "$KEY"`, never a second
   start.
4. **Head.** Step 2 of the skill: `BASE` and `HEAD`.
5. **The workspace.**
   `bash "$W" create --kind review --key <n> --name "review #<n> · <title>" --detach "$HEAD"`;
   its stdout is one TSV row, the path first: `WS`. A review workspace of this PR that already
   exists is moved to the new head when it is clean; close the earlier review worker's pane there
   first (`$O terminal list`), since two sessions in one workspace confuse each other and the
   watch. A failure → surface its stderr and stop.
6. **This session's Run.** `bash "$C" run` prints it; none yet →
   `$O orchestration run-create --objective "hi-crew" --json`, then `bash "$C" run <run_id>`.
7. **The task** (every path absolute: the worker may not have this plugin loaded):
   `bash "$R" task --pr-url <url> --key "$KEY" --base "$BASE" --head "$HEAD" --workspace "$WS"`
   plus `--voice "$V"` when set, into `$D/<n>.task.md`.
8. **Start.**

   ```bash
   bash "$C" dispatch "$KEY" --kind review --title "review #<n> · <title>" --workspace "$WS" \
     --task-file "$D/<n>.task.md" --guide "$PLUGIN/reference/deep.md" \
     --facts '{"review_pr":"<url>","head":"<HEAD>"}'
   ```

   It fails → show the error; `worker-start failed` keeps the facts, so the same command runs
   again after reading `failedStage` (hi-crew:start step 6).
9. Tell the person in two lines: the workspace, that the worker's question comes back here, and
   that they can open the workspace in Orca to watch or take the session over. Then end the turn.
   Never poll: Orca wakes this session.

## Coordinator: when Orca wakes you

`$O orchestration check --run "$(bash "$C" run)"`; a message from the dispatch of facts with
`kind: "review"` is handled here, every other one as `/hi-crew:start` says.

- **The verdict ask.** It names the cards file and one action per verdict.
  1. Read the cards file in full with the Read tool and show it verbatim: those cards are what
     would be posted.
  2. `bash "$C" action-show "$KEY" <id>` for each action the ask names: each must be one
     `review.sh submit` of that verdict's payload in the worker's workspace. One that is anything
     else is not offered; say so.
  3. One `AskUserQuestion`, as step 8.2 of the skill: the ask's verdicts, its recommendation
     first and marked recommended, and **Terminal only**. Edits ("drop 2", "softer on 3") come as
     the free-text answer.
  4. Relay the answer with hi-crew's relay, the only way a worker is answered
     (`bash "$C" relay "$KEY" --id <message_id> [--action <id>] <reply-file>`, reply file as
     `/hi-crew:start` describes, one point: the verdict). A verdict → `--action` with that
     verdict's id: the post runs once, here, and the worker hears its outcome. Terminal only or
     edits → no `--action`, the body says which: the worker posts nothing, or re-renders and asks
     again.
- **`worker_done`.** Show the review's state and link, or why nothing was posted, and the
  `action for you:` lines. Then `bash "$C" close "$KEY"` (a review has no retro: ignore its note
  about one) and offer to remove the workspace, or keep it for a review of the PR's next head
  (step 5 moves it there). A review workspace holds nothing of its own, but `remove-if-safe`
  refuses it while the PR is open: on the person's yes this turn, `bash "$W" remove "$WS"`.

## Worker

The task names `PLUGIN`, `PR`, `REPO`, `N`, `KEY`, `BASE_SHA`, `HEAD_SHA` and `VOICE`. The cwd
is the review workspace.

1. **Check the tree.** `git rev-parse HEAD` must be `HEAD_SHA`; otherwise report `worker_done`
   with outcome `failed`: the workspace is not at the head the review was started for.
   `ME=$(gh api user --jq .login)`. Read in full, with the Read tool, one call per file:
   `$PLUGIN/reference/voice.md`, `$PLUGIN/reference/cards.md`, and `VOICE` unless it is `none`.
2. **Intent and gather:** steps 3 and 4 of the skill, with `gh pr view <N> --repo <REPO>` for the
   PR's body and closing issues. The graph: this workspace's own gortex view when it is indexed,
   else none (`graph: unavailable` is the reviewer's to say).
3. **Slices.** `bash "$R" slices "$BASE_SHA" "$HEAD_SHA"`. One slice → one reviewer, as step 5 of
   the skill. Several → one `hi-review:reviewer` subagent per slice with `PHASE=review`, all
   launched in one message (at most six at a time; more go in waves of six), each given step 5's
   inputs (`WT` is this workspace) plus `SLICE` (that slice's paths, one per line) and
   `SLICE_OF` (`<i> of <k>`). A reply of `NEED_CONTEXT`, `NEED_PERMISSION` or `GIT_ERROR` → that
   slice is retried once; failing again, it is named in the cards as `not reviewed: <paths>`
   and no APPROVE is recommended.
4. **One draft.** Join the slices' `FINDINGS`, `UNANCHORED` and `SKIPPED` lines. Two findings on
   one anchor become one: the more severe, with the other's point folded in. The proposed verdict
   is the strictest of the slices' (REQUEST_CHANGES, then COMMENT, then APPROVE).
5. **Verify and check:** steps 6 and 7 of the skill, the verify subagents fresh, never a drafting
   one resumed. Then keep the person's pending review as the cards will show it:
   `bash "$R" pending <REPO> <N> "$ME" > "$D/<N>.pending.seen.json"` (exit 1: none; remove the
   file).
6. **Cards.** Render as step 8.1 of the skill into `$D/<N>.cards.md`, with the Write tool: the
   lines above the cards, the cards, the body, and what each verdict would post.
7. **Payloads.** The body and comments files as step 9.2 of the skill, then one payload per
   verdict offered: `$D/<N>.<EVENT>.json` for `APPROVE`, `REQUEST_CHANGES` and `COMMENT` (with no
   findings and no draft: a bare `APPROVE` and a body-only `COMMENT`). Exit 2 → fix and build
   again.
8. **One action per payload.** Write a script with the Write tool:

   ```bash
   bash '<PLUGIN>/lib/review.sh' submit '<REPO>' <N> '<D>/<N>.<EVENT>.json' \
     --head <HEAD_SHA> --login '<ME>' --sha256 <the payload's sha256> \
     [--seen-pending '<D>/<N>.pending.seen.json']
   ```

   (`--seen-pending` only when that file exists; the sha256 from `sha256sum`, or `shasum -a 256`
   on macOS), and store it as the spec's action rule says; keep each printed id. `submit` posts
   only what the cards showed: the PR's head moved, the payload changed, or the person's pending
   review is not the one the cards showed → exit 4, nothing posted.
9. **The one ask**, then end your turn:

   ```
   Review of <REPO>#<N>: <b> blocking, <o> other findings. Cards (show them to the person
   verbatim): <D>/<N>.cards.md
   - Approve — action <id>. loses: <…>. leans on: <…>
   - Request changes — action <id>. loses: <…>. leans on: <…>
   - Comment — action <id>. loses: <…>. leans on: <…>
   - Terminal only — no action: nothing is posted.
   Recommended: <verdict>, because <one line>. Would change my mind: <…>.
   Edits ("drop 2", "softer on 3") come back as a reply with no action.
   ```

   Only the verdicts step 7 built. The ask's text is English (the coordinator speaks the person's
   language to them); the cards are in the PR's language.
10. **The answer.**
    - The action applied: its output ends with `{id, state, html_url}`. Delete `$D/<N>.*` and
      report `worker_done`, outcome `succeeded`, with the state and the link.
    - It failed with exit 4: the head moved → report `worker_done` (succeeded, nothing posted):
      a new review of the new head is needed. The pending review changed → back to step 5's last
      line and on: new cards, new actions, a new ask. An action left unanswered is never run.
    - It failed otherwise, or was refused → say why in a new ask with new actions, or report it.
    - Edits → apply them to the cards, then steps 6–9 again.
    - Terminal only → `worker_done`, outcome `succeeded`: nothing posted; `$D/<N>.cards.md`
      stays for the person.
11. **Taken over.** A message the person types in this terminal (not one Orca delivers) means
    they are here: ask them the verdict with `AskUserQuestion`, as step 8 of the skill, and on
    their answer run step 8's `submit` command yourself. Their answer typed here is their own,
    not a relayed one. Then report `worker_done` as above.
