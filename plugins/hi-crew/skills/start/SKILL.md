---
name: start
description: Start a worker agent on a ticket — in its own Orca workspace, with a spec built from the ticket and the team's process, under the person's hi-crew Run so its questions reach them — and relay what the worker asks or reports. Use when the user says "start <KEY>", "give <KEY> to an agent", "run these tickets in parallel", or when Orca wakes this session with a hi-crew worker's question or report.
---

# hi-crew:start

One ticket, one worker, one Orca workspace, one branch. The worker carries the ticket to a
reviewed pull request on its own and stops only for a person's decision; this session is its
coordinator and relays those decisions. Merging stays a person's call.

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

- Orchestration is experimental in Orca: if `$O orchestration run-current` says it is off, tell the
  user to turn it on (Orca Settings → Experimental → Orchestration) and stop.
- `jq` must be installed (`crew.sh` needs it).
- Team settings come from `.claude/highness.json` at the git root of **this session's working
  directory** (a team commits it), or the user's `highness/config.json`. In a workspace that holds
  several clones, run hi-crew from the workspace root, where the team's file is, not from inside a
  clone:

  | key | what | when unset |
  |---|---|---|
  | `crew.process` | the team's process text appended to every spec: how to take and comment a ticket, open a PR, run the review loop. `{{ROOT}}` in it becomes the absolute path of this session's git root: the worker runs in another tree, where the team's skills may not be loaded, so name its scripts by that path | a generic line |
  | `crew.agent` | Orca agent id for workers | `claude` |
  | `crew.model` | provider model id for workers | say so to the user once; Orca then uses the agent's own default, which differs per person |
  | `crew.marker` | the prefix workers put on everything they post under the person's account | `(agent)` |
  | `crew.pr_state` | a command that prints one PR's state as JSON, for the watch (below); `{{PR}}`, `{{ROOT}}`, `{{MARKER}}` become the shell-quoted PR url, this git root and the marker. It runs outside any terminal, so it finds its own credentials | `gh` for a github.com PR; other forges go unwatched |

  Read them with `bash "${CLAUDE_PLUGIN_ROOT}/lib/config.sh" get '.crew.<key>'`.
- **The watch.** Workers report on their own, but nobody tells the person when a PR is merged,
  CI fails or a person comments while the worker is idle. `bash "$C" watch-install` sets up an
  Orca automation, "hi-crew watch", that looks at every open ticket's PR every 10 minutes and
  wakes the ticket's coordinator session when one of those happens. Its precheck does the work
  and always exits 1, so no agent run ever starts and the automation costs no tokens; Orca's run
  history shows each look as skipped. Run it once per machine, and again after a highness update
  if the automation's history shows errors. Say in one line that you set it up.

## Start a ticket

1. **Already running?** `bash "$C" get <KEY>`. Open facts mean a worker exists: show them and stop,
   unless the user asks for a second attempt (then start with `--retry-of <dispatch>`). One start
   per ticket and attempt.
2. **Read the ticket** with the team's tracker tool (the process text names it) or what the session
   has: its title, and a brief of three to six lines (what, why, constraints, links). Do not paste
   the whole ticket: the worker reads it itself.
3. **Pick the repo** the work belongs to. Ask the user only when the ticket does not say. It must be
   an Orca project: `$O repo list --json`; add a missing clone with `$O repo add --path <path> --json`.
4. **This session's Run.** `bash "$C" run` prints it when this session already has one; use it.
   None yet: `$O orchestration run-create --objective "hi-crew" --json`, then
   `bash "$C" run <run_id>` to register it. Never `run-use` another session's Run to start a
   ticket: Orca would stop waking that session for its workers.
5. **Spec:** write the brief to a file in the scratchpad, then
   `bash "$C" spec --key <KEY> --title '<title>' --brief-file <file> > <spec-file>`. Read it once
   before starting.
6. **Start:**
   ```bash
   $O orchestration worker-start --spec-file <spec-file> --task-title '<KEY>: <title>' \
     --worktree new-top-level --repo id:<repo-id> --name <KEY>-<short-slug> \
     --base-branch origin/<trunk> --agent <crew.agent> [--model <crew.model>] --json
   ```
   If it fails, do not rerun it: read `failedStage` and load
   `$O skills get orchestration --reference references/recovery-and-cleanup.md`.
7. **Record the facts** from the receipt, with the branch read from the workspace
   (`git -C <workspace path> branch --show-current`; the digest finds the PR by it):
   `bash "$C" record <KEY> '{"title":…,"repo":…,"workspace":…,"branch":…,"dispatch":…,"task":…,"run":…,"agent":…,"model":…,"root":…}'`,
   where `root` is this session's git root (`git rev-parse --show-toplevel`): the watch reads the
   team's settings there.
8. Tell the user in one or two lines: the ticket, the workspace, what the worker will do, that its
   questions come here. Then **end your turn**. Never poll; Orca wakes you.

Several tickets: run steps 1–7 for each, then end the turn once.

## When Orca wakes you

`$O orchestration check --run "$(bash "$C" run)"` and handle the whole batch.

- **A question** (`ask`) or a **decision gate**: the worker stops for a person's decision. Never answer it yourself, even
  when the answer looks obvious: show it to the user in plain words, point by point, with your own
  read, and ask for their decision. Then relay it:
  `$O orchestration reply --id <message_id> --body "<the user's decisions>"`. Say that they are the
  user's.
- **`worker_done`**: show the outcome, the PR link, what is left for a person. Record what became
  known (`bash "$C" record <KEY> '{"pr":"<url>","head":"<sha>"}'`).
  A subject starting `already done:` means the worker found the work landed already and opened
  no PR: show its evidence, and offer to close the ticket (if the worker left it open) and
  `bash "$C" close <KEY>`.
- **A `status` from the watch** (body starts `hi-crew watch:`; the subject is `<KEY>: <what>`):
  a PR merged or closed, CI failed, or people commented. Then `bash "$C" events --ack`, and
  handle it as `hi-crew:agenda` does: merged or closed → offer to close the facts; CI failed or
  a person's comment → read it, show it with your read, and send the worker a round only on the
  user's decision.
- **An escalation** (stopped without `worker_done`): tell the user; steer with
  `$O orchestration send --to dispatch:<id>` only on their say.
- **The user wants another round** (a person's new review comments, a change of mind): send it to
  the same worker, `$O orchestration send --to dispatch:<last dispatch> --subject … --body …`. It
  arrives as a follow-up Task in the same workspace and chat; record the new dispatch id.

When the ticket is settled (PR merged or closed), `bash "$C" close <KEY>` and offer to release the
workspace.

## Work done outside a worker

If this session does work that belongs to an open ticket, its own or another one, comment on that
ticket before the session ends: what was done and the commit, starting with the marker. A ticket
whose work is done but not recorded stays open, and the next worker started on it does the work
again. Workers follow the same rule (their spec says so) and check, before building, that their
ticket is not already done.
