---
name: setup
description: Check and fix what a machine and a person need before the first /hi-crew:start — jq, Orca and its orchestration, the highness launcher, which highness plugins the Orca worker profile loads, the hi-crew watch, the board columns hi moves workspaces between, the person's highness config (crew.agent, crew.model, a repo overlay) — and then the repo in the cwd (an Orca project, plus every /hi:repo-setup row). One status table, then one proposed fix per gap, each run only on a yes. Never writes a file a repo tracks. Use on a fresh box, when the user asks to set up or check hi / hi-crew / highness, "why does hi-crew not work here", or before a first /hi-crew:start.
---

# /hi:setup

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language, Read one file per call, 2–4 options per question.

`L="${CLAUDE_PLUGIN_ROOT}/lib"` (if that path does not exist: `L="$("$HOME/.local/bin/highness" root)/lib"`).
The script measures; you render, propose and ask. It needs no repo; run it from the repo the person
will start tickets in, and the repo section comes along.

## 1. Status

    bash "$L/setup.sh" status

Rows are `section<TAB>name<TAB>state<TAB>detail`. Render one short table per section (machine,
person, repo): item, state, detail. Paste states and paths as they are.

## 2. One fix per row that is not OK

In table order, one payload per row, each shown before it runs and run only on a yes. Rows that are
fine get no line. A fix that is the person's to make by hand (the Orca UI) gets the exact steps,
and is never reported as done until a re-run of `status` shows it.

Writes stay outside every repo: Orca's state through its CLI, the Claude Code profile through
`claude plugin`, the person's own `~/.config/highness/config.json`. A row whose fix would write a
file a repo tracks is a printed proposal, as in `/hi:repo-setup`'s `local` mode.

### machine

- `jq missing`: a machine-level install: `brew install jq` on macOS, the distro's package
  otherwise. Name the command; installing with `sudo` is the person's to run.
- `orca unavailable` / `degraded` / `outdated`: start Orca, or update it (hi needs 1.4.246 or
  newer). Without Orca, skip every Orca row below and say so: hi still makes plain git worktrees,
  hi-crew does not run.
- `launcher`: as in `/hi:repo-setup` (`missing` / `stale` are rewritten at the next session start
  with hi enabled; `foreign` is the person's own file).
- `plugin:<name> off`: the plugin is not enabled in the profile Orca starts workers under (the
  detail names it and why). A worker there runs without that plugin's skills and hooks: without
  `hi-crew` its permission-dialog marker and the watch's dialog wake-ups are dead; without
  `hi-guard`, no `sudo` and deny-pattern guard. `hi` and `hi-crew` are needed; `hi-guard` is
  recommended; `hi-docs` is optional (offer, do not push). The fix, on a yes:

      CLAUDE_CONFIG_DIR='<profile from the detail>' claude plugin install <name>@highness --scope user

  When the plugin is already installed there but disabled (`claude plugin list` shows it with
  `enabled: false`), the fix is `CLAUDE_CONFIG_DIR='<profile>' claude plugin enable <id>` instead.
  If install says the marketplace is unknown, first
  `CLAUDE_CONFIG_DIR='<profile>' claude plugin marketplace add metheoryt/highness`. Plugins and
  hooks load at session start: say that the running sessions keep the old set.
- `plugins unknown`: `claude` is missing or `claude plugin list --json` failed; say so, and that
  the plugin rows were not checked.
- `hi-crew off`: hi-crew is not enabled for workers, so there are no orchestration, watch or crew
  rows. Fix the `plugin:hi-crew` row first and re-run. `hi-crew unknown`: the enabled hi-crew is
  older than this check: `claude plugin update hi-crew@highness`, then re-run.
- `orchestration off`: the detail is Orca's own answer. In Orca 1.4.254 there is no switch for it;
  it is set up in Orca → **Settings → Orchestration → Agent Orchestration**, which installs the
  Orca CLI and the orchestration skill. An older Orca had it under Settings → Experimental. These
  are the person's steps in the Orca window: give them, and re-run after.
- `orca-skill missing`: `orca skills install --skill orchestration` (Orca's bundled skill for the
  detected agents; `--dry-run` first shows what it writes).
- `watch missing` / `disabled` / `stale`: `bash <hi-crew lib>/crew.sh watch-install` (the crew.sh
  next to the hi-crew the `plugin:hi-crew` row found). `stale`: the automation runs a crew.sh
  from another install; the same command repoints it.
- `board missing <labels>`: the workspace board lacks columns hi moves workspaces to; `wt.sh
  board` skips a move to a missing one, so a workspace waiting on the person never shows it.
  Orca's CLI cannot add a column (1.4.254: no command for it; `worktree set --workspace-status`
  only takes an existing id). The person adds each label by hand, spelled exactly: in Orca, open
  the **Workspace board**, its **Board settings** menu → **Statuses** → **Add status**, then
  **Rename** the new status to the label. Never write Orca's profile database. `board unknown`:
  the set could not be read (no Orca profile database, two of them, or no python3); the detail
  says which.

### person

The person's file is `~/.config/highness/config.json` (or `$HIGHNESS_CONFIG`). Show a write to it
as the whole new JSON before it happens, and keep every key it already has.

- `config none`: offer to create it with what the rows below decide (`{}` at least).
- `crew.agent unset` / `crew.model unset`: workers then run `claude` with that agent's own default
  model, which differs per person. Ask: set it (an Orca agent id; a provider model id), or leave
  it to the default on purpose: `null` there, which reads as `default` from then on.
- `overlay none`: the repo has no team `.claude/highness.json`, and the person's file has no
  `repos["<owner/repo>"]` or `repos["<owner>"]` block for it. Only when the team has settings
  (`crew.process`, `crew.marker`, …) that cannot be committed to the repo: offer that block in the
  person's file. Otherwise the defaults hold, and the row needs nothing.

### repo

- `orca-project missing`: `orca repo add --path <the path in the detail> --json`. A worker can start
  only in an Orca project. On Windows, add a WSL repo at its WSL path, never `C:/…`.
- Every other repo row is `/hi:repo-setup`'s: Read `${CLAUDE_PLUGIN_ROOT}/skills/repo-setup/SKILL.md`
  and propose its fix for each row, in its order and with its `mode` rules. Its `orca-setup ABSENT`
  is the `orca-project` row above: do not propose it twice.

## 3. Close

Re-run `status` and show only the rows that changed. Say what was done, what is left for the
person in the Orca UI, and which fixes need a new Claude Code session. Then the first run, in two
lines: `/hi-crew:start <KEY>`, where `<KEY>` is letters, digits, `.`, `_` and `-` only and does
not start with a dot (`repo-24`, not `repo#24`).
