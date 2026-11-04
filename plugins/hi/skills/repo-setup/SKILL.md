---
name: repo-setup
description: Set up or re-check one repo for hi workspaces — gortex tracking and index health, the gortex MCP wiring, the Python type view gortex's resolver keys off (a type checker plus ruff annotation rules), the highness launcher, the Orca worktree hooks (a committed orca.yaml and each person's own hook fields), and the repo's own worktree delegate. One status table, then one proposed fix per gap. In "local" mode (the default; config repo_setup.mode) it never writes a file the repo tracks. Use when the user asks to set up, align, onboard or check a repo for gortex or for Orca worktrees.
---

# /hi:repo-setup

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language, Read one file per call, 2–4 options per question.

`L="${CLAUDE_PLUGIN_ROOT}/lib"` (if that path does not exist: `L="$("$HOME/.local/bin/highness" root)/lib"`).
The script measures; you render, propose and ask.

## 1. Status

First, in an umbrella repo (`bash "$L/umbrella.sh" root` succeeds) the umbrella itself is not set
up for workspaces: ask which nested clone (`bash "$L/umbrella.sh" repos`) and run every step below,
this one included, as `cd <clone> && …`.

    bash "$L/repo-setup.sh" status

Exit 3 → not in a git repo: say so and stop. Render the rows as one short table (item, state,
detail). The `mode` row decides every write below. It comes from `repo_setup.mode` in the
highness config — the repo's `.claude/highness.json` (a team's), else the user's
`~/.config/highness/config.json`:

- `commit`: the user may commit to this repo. Writes happen in a workspace (never the main
  checkout), are committed and land the way the repo lands work. A revert is the undo; nothing is
  left staged for the user to ship.
- `local` (also when unset or unknown): nothing the repo tracks is written. Before every file
  write, run `bash "$L/repo-setup.sh" guard <path>`; a non-zero exit turns that write into a
  printed proposal (the exact block and where it goes) for the user to take to the team.

## 2. One fix per row that is not OK

In this order, one payload per row, each shown before it runs and run only on a yes. Rows that
are already fine get no line.

### gortex

- `absent` / `down`: installing or starting gortex is a machine-level job, never this skill's.
  Name it and skip the gortex rows. No piped installer, no daemon start.
- `untracked`: `gortex track <repo-top>`, then re-run status until the row reads
  `tracked indexed`. Graph answers mid-warmup are not trusted.
- `tracked stale`: say so; the daemon re-indexes on its own.

### wiring

- `machine`: nothing to do. The user-scope gortex MCP already serves the repo.
- `missing` in `commit` mode: the reduced init, preview first:

      gortex init --dry-run --yes --agents claude-code --no-skills --no-hooks
      gortex init --yes --agents claude-code --no-skills --no-hooks

  Never a bare `gortex init`: it writes about 32 files across every detected adapter,
  including ~20 generated `.claude/skills/generated/gortex-*` routing skills and per-repo
  hooks. Then add `.claude/skills/generated/` to `.gitignore`. If generated skills are already
  committed, `git rm -r .claude/skills/generated/` and drop the block between the
  `<!-- gortex:communities:start/end -->` or `<!-- gortex:skills:start/end -->` markers in
  `CLAUDE.md` / `AGENTS.md`. If `gortex repos --json` still does not list the repo, run
  `gortex daemon reload`. New MCP tools appear only in a session started afterwards.
- `missing` in `local` mode: the user-scope gortex MCP entry is missing on this machine. That
  is a machine-level fix: name it and move on.
- An allowlist `.gitignore` (`*`, then `!` lines) silently ignores `.mcp.json` and `.claude/`.
  After a commit-mode write, check `git status` and say so when nothing got into the commit.

### checker / ann (Python)

Read `${CLAUDE_PLUGIN_ROOT}/reference/type-governance.md` before proposing anything here.

- `checker none`: ty by default (its `[tool.ty]` block), pyright or mypy on request. A
  checker that is already configured is used as is; never add a second one.
- `ann off`: add `ANN` to ruff's `select`, or the reference's `[tool.ruff.lint]` block when
  there is no ruff. Detail `ANN ignored`: the repo turned it off on purpose; propose dropping
  `ANN` from `ignore` only as a proposal, and say why it was likely ignored (the noise).
- In `local` mode these are proposals only: `pyproject.toml` is tracked, so `guard` refuses it.
- Either mode: a checker needs an env with the dependencies installed (`.venv`). Without one,
  every import reads as unresolved and no config helps.

### launcher

Orca's hooks reach the plugin through `~/.local/bin/highness` (or `$HIGHNESS_BIN_DIR`), a small
script the plugin's SessionStart hook rewrites to point at the installed version.

- `missing` / `stale`: it is written at the next Claude Code session start with the hi plugin
  enabled; nothing to do now. To repair a worktree made meanwhile, run
  `bash "$L/worktree-setup.sh"` from inside it.
- `foreign`: a file of the user's own sits there and is never replaced. The user moves it, or
  sets `HIGHNESS_BIN_DIR` (then the orca.yaml commands below need that path).

### orca-yaml / orca-setup / orca-archive

Orca runs a worktree's setup and archive scripts from two sources: the repo's committed
`orca.yaml` (read from the main checkout; each person approves its commands once in a trust
dialog, and again whenever the command text changes) and each person's own hook fields in Orca →
the repo's settings. Per repo, Orca's **command source** setting (`commandSourcePolicy`) decides:
`shared-only` (orca.yaml), `local-only` (the person's fields) or `run-both`. Unset, it is
`local-only` for a slot where the person has a local script — so a leftover local script
silently hides orca.yaml — and `shared-only` otherwise. `orca-setup` / `orca-archive` say what
Orca will actually run.

The team recipe, committed at the repo root:

```yaml
scripts:
  setup: '"$HOME/.local/bin/highness" worktree-setup || true'
  archive: '"$HOME/.local/bin/highness" worktree-teardown || true'
```

`|| true` keeps a teammate without the hi plugin (no launcher) able to create and, above all,
remove worktrees: a failing archive script blocks Orca's removal. Keep this text byte-stable —
any change re-asks every teammate's trust.

- `orca-yaml none` / `unwired` / `partial` / `other`: in `commit` mode, add or complete the
  `scripts:` block above (keep any other keys the file has: `defaultTabs`,
  `setupAgentStartupPolicy`, …; an existing `scripts.setup` that runs something else is the
  user's call: chain it, `<theirs> && <ours>`, only on a yes). In `local` mode `orca.yaml` is
  tracked or would show in `git status`: print the block as a proposal for the team.
- `WIRED` / `LEGACY`: nothing. `LEGACY <value>` is an older local form that still works; say so,
  the preferred one is optional. Values a person's setup has always used can be accepted in the
  config: `repo_setup.accept.setup` / `.archive` (arrays).
- `SHADOWED`: orca.yaml is wired, but the person's own hook field runs instead. Fix in Orca →
  the repo's settings: clear that field, or set the command source to "run both".
- `TWICE`: both run highness — harmless for the setup (it skips what is done) but slow; clear the
  local field.
- `UNWIRED`, no orca.yaml in reach (a repo the team will not commit to): the person pastes the
  same two commands into Orca → the repo's settings → **Setup script** / **Archive script**.
- `CONFLICT <value>`: another script runs; the user decides.
- `ABSENT`: the repo is not listed in Orca yet: open it there once. On Windows, register a repo at
  its WSL path (`\\wsl.localhost\<distro>\home\<user>\…`), never `C:/…`: Orca runs the hook through
  cmd.exe there, where neither `bash` nor `$HOME` resolve.
- Any fix affects only worktrees Orca creates afterwards. To repair an existing one, run
  `bash "$L/worktree-setup.sh"` from inside it.

`wt.sh create` does not depend on any of this: it runs the setup itself on both backends.

### delegate

- `none`: `bash "$L/repo-setup.sh" scaffold-delegate`. It copies the template to
  `.orca/worktree-setup.sh` in `commit` mode, or to `<git-common-dir>/hi/worktree-setup.sh`
  in `local` mode: never committed, shared by every worktree, and run after the repo's own
  committed delegate. Repo-specific steps go between the `repo-setup:managed:repo-steps`
  markers; every step stays non-fatal.
- An existing delegate is never overwritten: `scaffold-delegate` prints the diff against the
  template and exits 1. Show the diff; the user decides.

## 3. Close

Re-run `status` and show only the rows that changed. Say what was written, what was committed,
and what was printed as a proposal. A durable fact learned here (a checker that needs a
particular env, a repo quirk) belongs in the repo's own agent instructions or memory, never in
gortex memory: that has no backup and no tracking.

## Limits (say them when they apply)

- No static checker is the framework. ty and pyright do not load the django-stubs mypy
  plugin, so Django manager and queryset types stay partly unresolved; mypy with the plugin
  resolves the most.
- Framework-invoked code (signals, Celery `@shared_task`, admin registration, settings string
  lists, templates) reads as unused in the graph however clean the checker is. Never act on
  "0 usages" there.
