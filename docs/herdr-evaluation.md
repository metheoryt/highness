# herdr for hi-crew: status rules and a migration assessment

Issue #24. This page compares herdr's agent-status detection with hi-crew's own checks (part 1),
and asks whether hi-crew should run its workers on herdr instead of Orca terminals (part 2). It
ends with a recommendation. The migration itself is the owner's decision.

**Sources.** Shallow clones of the public `herdrdev/herdr` (TUI 0.9.5, commit `ee5bfb5`),
`herdrdev/herdr-core` (`hc` 0.1.19, commit `5b14636`) and `herdrdev/herdr-app` repos, read on
2026-11-09: the detection manifests, the integration hook scripts, the docs (agents, agent
automation, integrations, socket API, plugins, and core's security and API docs) and the OpenRPC
schema. Nothing was installed or run. Every claim about herdr's behavior comes from those files,
not from using it.

## Two premises the issue gets wrong

- **herdr TUI has worktrees.** Its socket API has `worktree.list`, `worktree.create`,
  `worktree.open` and `worktree.remove` (git worktrees opened as herdr workspaces, never deleting
  the branch). It has no lineage, no task model and no isolation. herdr-core has no worktrees.
- **hi-crew already has a child-to-parent channel.** Workers report through Orca orchestration:
  `ask` (question or decision gate), `escalation` and `worker_done` with an outcome, all read by
  `crew.sh asks` and `crew.sh reports`. GitHub and the watch carry what happens on the PR, not
  whether the worker finished.

## Part 1: status detection

### How herdr decides

For Claude Code and Codex, herdr reads the live bottom of the pane and matches it against a
per-agent TOML manifest. Each rule has a state (`working`, `blocked`, `idle`, or `unknown` with
"skip this update"), a priority and a screen region (`osc_title`, `bottom_non_empty_lines(N)`,
`after_last_horizontal_rule`, `prompt_box_body`, `whole_recent`, and others). The highest-priority
match wins. If no rule matches, the agent counts as `idle`. herdr's docs say outright that this
fallback can let automation type into a dialog it did not recognise.

An integration that reports state through herdr's socket (`pane.report_agent`) replaces screen
detection while it reports. **The Claude Code and Codex integrations report no state.** The
Claude hook (`herdr-agent-state.sh`, integration v11) sends `pane.report_agent_session` on
`SessionStart` only, so herdr can resume the session after a restart. State for both agents comes
from the screen alone.

Claude Code manifest `2026.10.11.1`, by priority:

| State | Rule | What it matches |
| --- | --- | --- |
| working | `osc_title_working` (1100) | terminal title starts with a braille or half-circle spinner |
| unknown | `transcript_viewer` (1000) | the ctrl+o transcript view (no update) |
| blocked | `live_blocked_form`, `dynamic_workflow_prompt`, `mcp_elicitation_prompt` (980) | below the last rule: `esc to cancel` with `enter to confirm`, or `enter to select` with a navigate hint; "run a dynamic workflow?"; "MCP server … requests your input" with Accept/Decline |
| working | `btw_overlay_working` (975), `live_turn_working` (970), background agents/MCP tasks (965) | bottom 12 lines: a mode line (`⏸`/`⏵`) ending `esc to interrupt`, or a spinner line `✻ Verb… (12s ·` |
| idle | `live_prompt_box` (950) | `❯` in the prompt box, with no dialog hint |
| blocked | `bash_permission_prompt` (850), `generic_permission_prompt` (840) | "do you want to proceed?" with numbered Yes/No options |
| blocked | `legacy_no_prompt_blocker` (300) | looser phrases ("do you want to", "waiting for permission", …) |
| idle | `osc_title_idle`, `osc_progress_idle` (250) | title starts with `✳`; OSC 9;4 progress cleared |

The Codex manifest has the same structure. It adds a title signal (`Action Required` means
blocked), the trust-folder and update dialogs at startup, `allow command?`, `[y/n]`, and a
working rule keyed on the live elapsed timer `(12s • esc to interrupt)`.

`herdr agent prompt --wait` refuses an agent that is already `blocked` (`agent_blocked`, nothing
sent). After sending, it waits up to five seconds to see `working` or `blocked`, and returns
`agent_prompt_stalled` if it sees neither.

### Against hi-crew's checks

| Our check | What it did | Verdict | Change in this PR |
| --- | --- | --- | --- |
| Idle check before typing (`_live_agent`: Orca's `programStatus`, then a 2 s `tui-idle` wait) | Typed only into a terminal Orca called idle. A dialog on screen was invisible to it. | Stricter than herdr: no "no rule matched, so idle" fallback. It still trusted Orca's idle completely. | `dispatch` reads the screen it already reads for the echo check. If herdr's blocked shapes or a live turn appear there, it refuses with exit 3 (`via=busy`), says which, and prints the screen tail. |
| Dispatch confirmation (`_send_taken`: Orca's `turn_started`, or one more echo of the brief outside the composer) | Missed a turn whose echo scrolled off or was redrawn, and reported it `unconfirmed`. | herdr's rule (working or blocked after the send) is the better signal. | A turn running, or a dialog open, after the send counts as taken. The screen showed neither before the send, since dispatch now refuses those. A dialog right after the send is reported. |
| Permission-dialog marker (`prompt-mark.sh`: `Notification` hook plus transcript) | Saw permission prompts from Claude's own event and checked the pending tool call in the transcript. | Better than herdr's screen rules for permission prompts. It does not depend on how Claude draws the dialog, and survives UI changes that herdr fixes by re-shipping manifests. | The hook also matches `elicitation_dialog`, Claude's notification for an MCP server's input dialog: herdr's `mcp_elicitation_prompt`. The marker records its kind, and the watch says "waits on an MCP input dialog". |

Choices made in the port:

- **Only rules that fail safe.** A false "blocked" or "working" before the send costs one refused
  dispatch. A false "working" after the send could mark an untaken brief as taken. So the working
  rules are herdr's anchored forms (mode line or spinner line), not a bare search for
  "esc to interrupt".
- **Cut to what BSD awk can match.** herdr's Unicode ranges (`\x{2800}-\x{28FF}`) and the OSC title
  rules are left out. Orca's screen read returns rendered rows, not the title.
- **The legacy and weak rules are left out.** "do you want to" plus "yes" anywhere on screen also
  matches ordinary output.
- **`elicitation_dialog` is unmeasured.** The notification type is in the Claude Code 2.1.319
  CLI, but its payload was not captured. A marker without a transcript is never believed, so an
  unexpected payload stays silent.
- **Codex rules are not ported.** `wt.sh dispatch` starts only Claude sessions, and the rules
  are Claude's: on a Codex terminal they mostly match nothing, which leaves the old behavior.
  hi-crew workers default to `claude` (`crew.agent`). A Codex worker gets no dialog marker at all,
  because the marker is a Claude hook. The Codex manifest's `Action Required` title and its
  `allow command?` and `[y/n]` shapes are where that gap would start.

**Upkeep.** herdr pushes manifest updates from herdr.dev because Claude's UI drifts. The 2.1.228
spinner change is noted in the manifest. Our copy will drift the same way, but each rule fails
back to the behavior before #24: a missed dialog falls back to Orca's verdict, and a missed turn
falls back to the echo count.

## Part 2: would migrating make sense?

### What maps

Every Orca call hi and hi-crew make today:

| Orca call (hi / hi-crew) | herdr TUI | herdr-core (`hc`) |
| --- | --- | --- |
| `terminal list` (agents in a workspace) | `agent list`, `pane list` | `hc ls` |
| `worktree ps` agent status (idle/done/busy) | `agent get`: idle/working/blocked/done/unknown, from the screen for Claude | **missing** for Claude: status only from OSC 7501 |
| `terminal wait --for tui-idle` | `agent wait --until idle` | `hc wait` (needs a status) |
| `terminal read --screen` | `agent read --source visible` | `hc read` |
| `terminal send --enter [--wait-submit]` | `agent prompt [--wait]`, refuses on blocked | `hc send --if idle` (needs a status) |
| `terminal create` (new agent session in a workspace) | `workspace create --cwd`, then `agent start --kind claude -- <args>` | `hc run --bg --cwd … claude …` |
| `terminal close` | `pane close` | `hc kill` |
| `worktree create/rm/list/current/show/set` (Orca workspace, parent, comment) | `worktree create/open/remove/list`: **no parent, no comment** | **missing** |
| `repo list` (repo selector) | not needed (by cwd) | not needed |
| `status --json` (runtime capabilities) | `api schema`, `server status` | `hc schema`, `hc server status` |
| `automations create/edit/list` (the 10-minute watch) | **missing**: plugins have event and startup hooks, no schedule | **missing** |
| `orchestration run-create/worker-start/ask/reply/send/check/inbox/worker-list` | **missing** | partial: children `hc send` notes to the parent, `hc wait --children all`; no typed messages (question, gate, escalation, done with outcome), no Run, no inbox |
| Workspace board columns (`board.sh`, "Needs me") | partial: sidebar rolls blocked/working/done up to the workspace; workspace metadata tokens can carry a label; no columns | **missing** |

### What stays ours

Worktree records and lineage, the GitHub Issues queue, `land` and `hi-guard` touch git, GitHub and
Claude Code hooks. None of them touches Orca.

`/hi:worktrees` already has a plain-git path, used when there is no Orca. Listing, create, land
and remove run on it unchanged under herdr. **Dispatch does not.** Its no-Orca path opens a tmux
window, and herdr cannot see an agent behind tmux inside its pane. Dispatch would need a third
branch that calls `herdr agent start` and `agent prompt`, beside Orca and tmux.

### What we would lose

- Orca's editor, diff and review UI, and running the coordinator from inside the IDE.
- The board, with person-defined columns like "Needs me".
- Typed orchestration messages and the Run inbox that `crew.sh asks/reports`, the agenda and the
  start skill are built on.
- Scheduled automations. The watch would move to cron or a systemd timer per machine.

### What we would gain

- **Blocked detection**, but only in the TUI, and from screen rules of the same kind this PR
  ports. herdr gets it for Claude by maintaining those rules.
- **Child-to-parent reporting** in core. It is plainer than Orca orchestration, which hi-crew
  already uses.
- **SSH machines in one view.** TUI remote servers and core `hc machine add` are both
  first-class, and hi-crew has nothing like it today.
- **Headless operation.** core runs without a UI, and terminals outlive the client and core
  updates.

### Claude status under herdr-core

core never reads the screen. A terminal has a status only if its program writes OSC 7501, and
core's API has no method to set a status from outside. Claude Code does not emit OSC 7501, so a
Claude worker under core has no status: `hc wait` and `hc send --if idle` have nothing to act on.
There are two ways out:

- **Run Claude workers under the TUI.** Its screen manifests give status, which brings back the
  same kind of rules this PR ports.
- **A Claude Code hook that emits OSC 7501.** A hook's stdout goes to Claude, not to the
  terminal, so the hook would have to write to the pane's tty device itself. That is possible in
  principle and unmeasured. It would be fragile under Claude's own redraws, and it would be a
  hook we maintain for a runtime we do not otherwise need.

The hook direction has value without herdr. hi-crew already reads Claude's own events for dialogs
(`prompt-mark.sh`). A small hook-fed state (UserPromptSubmit = working, Notification = blocked,
Stop = idle) would not depend on any terminal runtime. It would be the right input for whichever
runtime runs the workers.

### Option: herdr only for headless workers

Dispatch and the watch on herdr-core, Orca kept for interactive work. Today this means two
runtimes: a third dispatch branch in `wt.sh`, a status source that core lacks for Claude (see
above), an agenda and watch that read both Orca orchestration and `hc` notes, and a separate
scheduler. hi-crew has no headless workers today. The cost is real and there is no user for it
yet.

### Trust and maturity

- **Remote manifests (TUI).** By default the TUI fetches detection-rule updates from herdr.dev and
  applies them without a restart (`[update] manifest_check = false` turns this off). The rules
  decide when automation may type, so they are part of the trust boundary.
- **Updates (core).** Updates check a SHA-256 from a manifest served over HTTPS. That manifest is
  not signed with a separate key, so trust rests on HTTPS and the release service.
- **Telemetry (app).** The app sends a daily usage report with a random install ID to
  telemetry.herdr.dev. It is on by default in releases. The TUI and core docs mention no
  telemetry.
- **Socket API.** A local Unix socket in a 0700 directory, with no password and no per-client
  check. Any process running as the user can drive every terminal. A `blocked` status is not an
  access boundary.
- **Plugins.** They run unsandboxed as the user, with the full API, installed from GitHub
  shorthand. Install shows a preview, and a pinned `--ref` is optional.
- **Maturity.** core is 0.1.x (0.1.19) and the TUI 0.9.x.

## Recommendation

**Do not migrate now.** Take herdr's detection rules (done in this PR), and keep the question
open on three named conditions.

1. The gain that motivated the issue was blocked detection. For Claude, herdr gets it from screen
   rules like the ones now in `wt.sh`, and herdr-core gets none. Moving runtimes would not buy a
   better signal.
2. The cost is concrete: orchestration messages, automations, the board and the IDE, plus a new
   dispatch branch, all for a 0.x runtime whose detection rules update themselves from the
   network by default.
3. Revisit when any of these holds:
   - workers need to run on other machines or with no UI;
   - Claude Code emits a terminal status protocol, or herdr's Claude integration reports state
     from hooks;
   - Orca's orchestration or automations stop serving hi-crew.

   At that point, start with the headless-only option behind a hook-fed Claude state, not with a
   full move.

One cheaper follow-up stands on its own: the hook-fed state described above. It would make
"is this worker idle, working or on a dialog" independent of both Orca and herdr.
