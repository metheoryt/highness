---
name: start
description: Start a worker agent on a ticket — in its own Orca workspace, with a spec built from the ticket and the team's process, under the person's hi-crew Run so its questions reach them — and relay what the worker asks or reports. Use when the user says "start <KEY>", "give <KEY> to an agent", "hand this open PR to a worker", "run these tickets in parallel", or when Orca wakes this session with a hi-crew worker's question or report.
---

# hi-crew:start

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language (no words of theirs yet: `session.language` in their config), Read one file
per call, 2–4 options per question.

One ticket, one worker, one Orca workspace, one branch. The worker carries the ticket to a
reviewed pull request on its own and stops only for a person's decision; this session is its
coordinator and relays those decisions. Merging stays a person's call unless the team sets
`crew.merge` to `on_green`.

Each coordinator session has its own Run, and Orca wakes a session only for the workers of its
Run. So several sessions can each coordinate their own tickets, and `hi-crew:agenda` reads them
all.

```bash
C="${CLAUDE_PLUGIN_ROOT}/lib/crew.sh"     # facts, asks, spec
O=$(bash "$C" orca)                       # the Orca executable for this host
```

`${CLAUDE_PLUGIN_ROOT}` is this plugin's directory; if it is empty, use the "Base directory for
this skill" printed above, two levels up.

Below, `$O` stands for that executable.

## Before the first start

- On a fresh box, `/hi:setup` (the hi plugin) checks and fixes everything below in one pass.
- Orchestration: if `$O orchestration run-current` fails, tell the user to set it up (Orca 1.4.254:
  Settings → Orchestration → Agent Orchestration; older Orca: Settings → Experimental) and stop.
- `jq` must be installed (`crew.sh` needs it).
- Team settings come from `.claude/highness.json` (a team commits it) at the **coordinator root**,
  or the user's `highness/config.json`. The coordinator root is pinned once per session, when its
  Run is registered (step 4), from where the session stands then: the git root, or, from a clone
  with no team file of its own, the umbrella above it whose `repos.txt` lists that clone. A later
  `cd` into a clone does not move it. `bash "$C" root` prints it; `bash "$C" root <dir>` re-pins
  it. Keys:

  | key | what | when unset |
  |---|---|---|
  | `crew.process` | the team's process text appended to every spec: how to take and comment a ticket, open a PR, run the review loop. `{{ROOT}}` in it becomes the absolute path of the coordinator root: the worker runs in another tree, where the team's skills may not be loaded, so name its scripts by that path | a generic line |
  | `crew.merge` | `on_green`: the worker merges its own PR once it is ready and its checks pass (a brief that says merging is the person's call still wins). For repos where the person has decided agents merge | `never`: merging is a person's call |
  | `crew.agent` | Orca agent id for workers | `claude` |
  | `crew.model` | provider model id for workers | say so to the user once; Orca then uses the agent's own default, which differs per person |
  | `crew.branch` | the worker's branch name, for a team whose forge accepts only its own scheme: `{{KEY}}`, `{{SLUG}}` (a short slug of the title), `{{TYPE}}` (`feat`, `fix`, … from the ticket; default `feat`), `{{OWNER}}` (`crew.owner`). Example: `{{TYPE}}/{{OWNER}}/{{KEY}}-{{SLUG}}` | Orca names the branch from `--name` |
  | `crew.owner` | the person's own name in branch names, for `{{OWNER}}`; set it in the person's own file, not the team's | a template with `{{OWNER}}` refuses to start |
  | `crew.marker` | the prefix workers put on everything they post under the person's account | `(agent)` |
  | `crew.pr_state` | a command that prints one PR's state as JSON, for the watch (below; the fields are in `lib/crew.sh`'s header); `{{PR}}`, `{{ROOT}}`, `{{MARKER}}`, `{{BOTS}}`, `{{FINDING_PATTERNS}}`, `{{BOT_IGNORE_PATTERNS}}`, `{{BOT_SUMMONS}}` become the shell-quoted PR url, the coordinator root, the marker, the JSON array of logins that are not people, the JSON arrays of `crew.finding_patterns` and `crew.bot_ignore_patterns`, and the bot summons patterns (the defaults and `crew.bot_summons`). A team's own command must apply the last three and print `findings`, `bot_comments`, `approvals` and `rerequested`, or those events never fire. It runs outside any terminal, so it finds its own credentials | `gh` for a github.com PR; other forges go unwatched |
  | `crew.bots` | logins that are not people, added to the forge Actions users (`github-actions`, `forgejo-actions`, `gitea-actions`) and any `[bot]` or Bot account: a team's AI reviewer or gatekeeper on a normal account. A GitHub App bot (CodeRabbit, Bugbot, Codex) is a Bot account and needs no entry. The agenda counts none of their activity as review activity. Their inline comments and change requests are findings, sent to the worker; so is a plain comment of a `crew.bots` login, unless `crew.bot_ignore_patterns` matches it (a forge Actions user's or an App's plain comment wakes no one). A review they re-request from a person, and an approval that stops counting, still reach the coordinator. Set per repo in the user file's `repos.<owner/repo>` or `repos.<owner>` for a repo that cannot carry one | the Actions users only |
  | `crew.finding_patterns` | regexes (jq syntax) for a review bot that puts some findings only in its review body, with no inline comment: a not-a-person's review whose body matches one counts as a finding and wakes the worker. Name the marker of the bot's findings sections, which its summary-only reviews lack (for CodeRabbit: `Outside diff range comments`, `Nitpick comments`, `Additional comments`). A changed list fires nothing for the reviews already there | none: a review body is never a finding |
  | `crew.bot_summons` | regexes (jq syntax, matched case-insensitively against the whole trimmed comment) for a comment that only summons a review bot: posted by the login gh is signed in as (the workers'), it wakes no one; another login's summons is a person's comment. A team's own `crew.pr_state` gets them as `{{BOT_SUMMONS}}` and decides authorship itself. A worker cannot mark a summons with `crew.marker`, since CodeRabbit runs a command only when it is alone on its line. Add a bot whose handle or commands differ | CodeRabbit's `review`, `full review`, `pause`, `resume`, `resolve`, `summary`, `help` and `configuration` (as `@coderabbitai` or `@coderabbit`, with flags), and a bare `@codex review` |
  | `crew.bot_ignore_patterns` | regexes (jq syntax) for the known noise among `crew.bots` logins' plain comments, which otherwise all go to the worker: nobody knows which bots will come or what they will report, so an unknown bot's word reaches the worker and the team silences what it knows (an "all clear" header, `Auto-assigned reviewers`). A changed list fires nothing for the comments already there | none: every plain comment of a `crew.bots` login goes to the worker |

  Read them at that root: `(cd "$(bash "$C" root)" && bash "${CLAUDE_PLUGIN_ROOT}/lib/config.sh" get '.crew.<key>')`.
- **The watch.** Workers report on their own, but nobody tells the person when a PR is merged,
  CI fails or a person comments while the worker is idle. `bash "$C" watch-install` sets up an
  Orca automation, "hi-crew watch", that looks at every open ticket's PR every 10 minutes and
  wakes the ticket's coordinator session when one of those happens. Its precheck does the work
  and always exits 1, so no agent run ever starts and the automation costs no tokens; Orca's run
  history shows each look as skipped. Run it once per machine, and again after a highness update
  if the automation's history shows errors. Say in one line that you set it up.
- **Autostart** (off unless the person turns it on in their own config). The watch can also start
  ready tickets that carry an opt-in label, up to `crew.autostart.max_active` at a time, under the
  Run of the coordinator session that last asked for its Run on this machine: that session gets
  their questions. Keys and rules: `bash "$C"` (the `autostart` part of its help);
  `bash "$C" autostart --dry-run` shows the free slots and what would start. A slot frees when
  the worker's PR is merged or closed, or, with no PR, when the worker has reported. Each ticket is
  tried once. Before a start the watch asks `lib/budget.sh check` whether the account may
  spend: the person keeps a reserve of each plan window (`crew.budget.*`, 50% of a fresh window),
  shrinking toward its reset. Over it, or with no figure, nothing starts, and an autostarted
  worker already running is paused at its next tool call until the account is back under the
  line (`lib/hold.sh`; `bash lib/hold.sh held` lists the paused ones).

## Start a ticket

1. **Already running?** `bash "$C" get <KEY>`. Open facts mean a worker exists: show them and stop,
   unless the user asks for a second attempt (then start with `--retry-of <dispatch>`). One start
   per ticket and attempt. A worker lost without reporting (a usage limit, an account switch) is
   not a second attempt: `bash "$C" resume <KEY>` continues it in its own pane and chat when they
   are still there, else in its own workspace. A ticket that already has an open PR, driven by a
   session outside hi-crew: hand it over (below) instead.
2. **Read the ticket** with the team's tracker tool (the process text names it) or what the session
   has: its title, and a brief of three to six lines (what, why, constraints, links). Do not paste
   the whole ticket: the worker reads it itself.
3. **Pick the repo** the work belongs to. Ask the user only when the ticket does not say. It must be
   an Orca project: `$O repo list --json`; add a missing clone with `$O repo add --path <path> --json`.
4. **This session's Run.** `bash "$C" run` prints it when this session already has one; use it.
   None yet: `$O orchestration run-create --objective "hi-crew" --json`, then
   `bash "$C" run <run_id>` to register it; that also pins the coordinator root from the cwd, so
   register it from the umbrella or the repo whose team file applies. Never `run-use` another session's Run to start a
   ticket: Orca would stop waking that session for its workers.
5. **Spec:** write the brief to a file in the scratchpad, then
   `bash "$C" spec --key <KEY> --title '<title>' --brief-file <file> --root "$(bash "$C" root)" > <spec-file>`
   (it reads the team's settings at the coordinator root, and keeps a copy at
   `$(bash "$C" dir)/specs/<KEY>.md`). Always pass `--root`: the cwd of a shell is not the
   coordinator root (a scratch directory has no team file). When no team file and no
   `crew.process` apply at that root, `spec` fails (exit 2) rather than build a spec without the
   team's rules: fix the root (step 4 pins it), or, when that root has no team on purpose, pass
   `--no-profile` and say so to the user. Read the spec once before starting: a
   `Team process (none configured…)` there means the worker gets no team process.
6. **Start.** First the team's branch name:
   `bash "$C" branch --key <KEY> --title '<title>' [--type <feat|fix|…, from the ticket>] [--slug '<short slug>']`.
   - It prints nothing (exit 1): no `crew.branch`, so Orca names the branch:
     ```bash
     $O orchestration worker-start --spec-file <spec-file> --task-title '<KEY>: <title>' \
       --worktree new-top-level --repo id:<repo-id> --name <KEY>-<short-slug> \
       --base-branch origin/<trunk> --agent <crew.agent> [--model <crew.model>] --json
     ```
   - It prints a name: worker-start cannot name a branch, so create the workspace on it first,
     then start the worker there (`--keep-open`, or the worker closes when it reports):
     ```bash
     bash "$C" workspace --repo id:<repo-id> --name <KEY> --branch <name> --base origin/<trunk>
     $O orchestration worker-start --spec-file <spec-file> --task-title '<KEY>: <title>' \
       --worktree path:<the printed path> --keep-open --agent <crew.agent> [--model <crew.model>] --json
     ```
     The workspace is the printed path, not the receipt's. In a repo whose Orca setup policy is
     wait-for-setup, `workspace` waits for the setup to finish (up to 9 minutes: give that Bash
     call a 600000 ms timeout), since Orca holds back only an agent it starts with the workspace.
     Exit 3: the workspace exists but its setup still runs; append what it printed on stderr to
     the spec file (it tells the worker to wait for the setup), then start.
   - Exit 2 (a placeholder with no value, a bad template): show the error and stop.

   If worker-start fails, do not rerun it: read `failedStage` and load
   `$O skills get orchestration --reference references/recovery-and-cleanup.md`.
7. **Record the facts** from the receipt, with the branch read from the workspace
   (`git -C <workspace path> branch --show-current`: Orca adds a suffix when the name is taken;
   until the worker records its PR, the digest and the watch find the PR by it):
   `bash "$C" record <KEY> '{"title":…,"repo":…,"workspace":…,"branch":…,"dispatch":…,"task":…,"run":…,"agent":…,"model":…,"root":…,"spec":…}'`,
   where `root` is the coordinator root (`bash "$C" root`), never re-derived from the cwd: the watch
   reads the team's settings there; `spec` is the copy step 5 kept. After a compaction the
   worker's session is pointed back at it (`crew.sh reentry`), and the retro reads it.
   When the ticket must wait for another pull request to merge first (its links name one, a note
   on merge order, the same migration number taken twice), add `"waits_on":["<PR url>",…]`: the
   watch tells the worker once each one merges or closes, so no one has to ask a person when it
   did. The worker records more itself; a later record replaces the whole list.
8. Tell the user in one or two lines: the ticket, the workspace, what the worker will do, that its
   questions come here. Then **end your turn**. Never poll; Orca wakes you.

Several tickets: run steps 1–7 for each, then end the turn once.

## Hand over an open PR

A ticket whose PR is already open (in review, waiting on QA), driven so far by another session:
an older session outside hi-crew, a person, a worker whose facts were closed. Never build its
spec by hand from the fresh-ticket template, whose take, already-done and draft-PR steps do not
fit; one command does the whole start:

1. `bash "$C" get <KEY>`: open facts mean hi-crew already has a worker on it (a lost one is
   `resume`, step 1 above). Close the old session first if it still runs in the PR's workspace: two
   sessions in one workspace confuse each other and the watch.
2. This session's Run, as step 4 above.
3. A brief, only when there is something to add: the team's per-ticket notes (which base the PR
   targets, the merge path, what QA waits for) and the agenda's next step for it. The PR and the
   ticket the worker reads itself.
4. `bash "$C" adopt <KEY> --pr <url> [--brief-file <file>] [--background <journal or chat>]...`
   It reads the PR (state, draft or ready, base, CI, open review threads) and the ticket's status,
   writes them into the spec as "where it stands", and replaces the fresh-ticket steps with the
   follow-up phase: answer review threads, keep CI green, merge the base in on a conflict, wait
   for QA. No second PR; the ticket's status and draft/ready stay as they are. The workspace is
   the PR repo's Orca workspace on the PR branch when there is one (pass `--workspace <path>` to
   pick it yourself), else a new one created on that branch. It records the facts, PR and head
   included, before the worker starts, so the watch follows the PR from its first pass, then the
   dispatch and task. `--background` names a previous session's journal or chat as background
   only. `--title` overrides the tracker's title; `--repo id:<repo-id>` is needed only when no
   Orca workspace of the PR's repo exists to infer it from.
   It refuses, starting nothing, a PR that is merged, closed or from a fork, and a key with open
   facts. If worker-start fails, read `failedStage` as in step 6, then run the same `adopt` again:
   it takes over the facts it recorded.
5. Tell the user in one or two lines, as step 8, and end your turn.

## When Orca wakes you

`$O orchestration check --run "$(bash "$C" run)"` and handle the whole batch.

A message from the dispatch of facts with a `kind` and a `guide` (a worker `crew.sh dispatch`
started for another plugin, such as a deep review): read that guide file and handle the message
as it says. Its answers still go through `relay`, below; it has no ticket and no PR of its own,
so no retro.

- **A question** (`ask`) or a **decision gate**: the worker stops for a person's decision. Never answer it yourself, even
  when the answer looks obvious: show it to the user in plain words, point by point, with your own
  read, and ask for their decision. Then relay it with one command, and only this one: it sends
  the reply and records the user's choices in the same step, so they can be read back across
  tickets. Never answer a worker with `orchestration reply` directly; `bash "$C" choices --gaps`
  lists every answer sent that way. Write a reply file:
  `{"body":"<the user's decisions, said to be the user's>","points":[{"question":…,"options":[{"name":…,"loses":…,"leans_on":…}],"recommended":<option name>|null,"took":"option"|"own"|"reframed","picked":…,"reply":"<their words, verbatim>"}]}`,
  one point per point the ask named, then `bash "$C" relay <KEY> --id <message_id> <reply-file>`.
  When one reply answers several points ("yes, send it" closing five), never bundle them into one
  point: list every point with its `question`, `options` and `recommended`, and put the reply
  verbatim once, top level, as `"reply"`. Each point with no `reply` of its own is covered by it
  and takes its recommended option. Give a point its own `took`, `picked` and `reply` only where
  the person answered it otherwise ("yes, but for the third C"); a blanket "no" or "neither" is
  no shared yes, so give those points their own answer. Relay refuses a covered point that has
  nothing recommended to take.
  `recommended` is the option the worker recommended in its ask, by its `name` there (the one
  `picked` holds when they take it), and null when the ask recommended none; `bash "$C" choices`
  then reads each answer as taken as recommended or against it.
  `took` is `own` when they wrote an option of their own and `reframed` when they rejected the
  question's framing; those say the most about what the options missed. Relay prints
  `relayed <KEY> <choice> → <dispatch>` when it sent. It is safe to repeat: the same answer can
  reach you twice (a resumed session gets the user's message again), and relay for an ask already
  answered sends nothing and prints `already relayed <when>`; tell the user it was sent then, and
  do not send it another way. Only when the user deliberately changes an answer already sent,
  relay again with `--again`: the worker gets the second answer, recorded as superseding the
  first. If relay says the reply
  was sent but not recorded, record each line it prints with `bash "$C" choice <KEY> '<line>'`.
  If it says the reply was not sent (the worker is gone), it kept it: offer the round below
  (`bash "$C" stranded` shows the kept body).
- **A question that names an action** (the worker prepared a step only a person's yes allows):
  `bash "$C" action-show <KEY> <id>` and show the user its script verbatim, with the pinned head,
  next to the question. On a yes, relay with `--action <id>`: the script runs once in the
  workspace, here, and the worker hears its outcome first. Write the body as the user's words for
  context, never as an instruction to run the step. On a no, relay without `--action`.
- **`worker_done`**: show the outcome, the PR link, what is left for a person. Record what became
  known (`bash "$C" record <KEY> '{"pr":"<url>","head":"<sha>"}'`).
  A subject starting `already done:` means the worker found the work landed already and opened
  no PR: show its evidence, and offer to close the ticket (if the worker left it open) and
  `bash "$C" close <KEY>`.
- **A `status` from the watch** (body starts `hi-crew watch:`; the subject is `<KEY>: <what>`):
  a PR merged or closed, people commented, a person approved it, an approval stopped counting, or
  a review was re-requested from a person (by anyone, a bot included). A CI failure and review
  bots' findings and comments go to the worker itself as a round (and an approval too, when crew.merge is
  `on_green`), and so does a PR the ticket waits on (`waits_on`) merging or closing; they reach
  you only when no worker Dispatch took them. A waited-on PR merging or closing (`a PR it waits on
  was …`) is not the ticket settling: never close its facts or run its retro for it; tell the
  user, and offer a round to the worker to rebase and carry on. Then
  `bash "$C" events --ack`, and handle it as `hi-crew:agenda` does: the ticket's own PR merged or
  closed → offer to close the facts; a person's comment, an approval, or a worker event that fell back to you →
  read it, show it with your read, and send the worker a round only on the user's decision.
- **An escalation** (stopped without `worker_done`): tell the user; steer with
  `$O orchestration send --to dispatch:<id>` only on their say. Orca's "Worker stopped without
  reporting" (`stopReason` `finished`: the worker only ended a turn) is not a lost worker when
  that Dispatch has an open ask (`bash "$C" asks` lists the ask and drops the notice): fold it
  into the ask, do not raise it on its own. With no open ask, it is news only once the worker's
  terminal is gone (`asks` lists it then).
- **The user wants another round** (a person's new review comments, a change of mind): send it to
  the same worker, `$O orchestration send --to dispatch:<last dispatch> --subject … --body …`. It
  arrives as a follow-up Task in the same workspace and chat; record the new dispatch id. Never a
  new `worker-start` for a round: that is a second worker on the whole spec. The body is only
  the delta: what the person decided, what to change, how to reply. The worker has its spec and
  its chat, so do not restate them (same branch, same PR, no force-push, the review loop).

When the ticket is settled (PR merged or closed), run the short retro in this session first
(`reference/retro.md`, `lib/retro.sh`), then `bash "$C" close <KEY>` and offer to release the
workspace.

## Work done outside a worker

If this session does work that belongs to an open ticket, its own or another one, comment on that
ticket before the session ends: what was done and the commit, starting with the marker. A ticket
whose work is done but not recorded stays open, and the next worker started on it does the work
again. Workers follow the same rule (their spec says so) and check, before building, that their
ticket is not already done.
