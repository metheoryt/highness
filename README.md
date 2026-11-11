# highness

A harness for Claude Code agents, as a plugin marketplace. Each plugin is enabled on its own.

| plugin | what it gives |
|---|---|
| `hi` | `/hi:worktrees` — one workspace per piece of work, over Orca worktrees or plain git worktrees, with lineage, a removal check and a per-tree setup (gortex tracking when gortex is installed, local config links, the repo's own setup script). `/hi:repo-setup` — check and wire a repo for that. `/hi:setup` — check and fix a machine and a person for hi and hi-crew, then the repo. |
| `hi-guard` | A PreToolUse hook on Bash: denies `sudo` from an agent session (quote-aware, through `bash -c`, `ssh`, `eval`…) and any configured deny pattern. Other tools can add checks. |
| `hi-docs` | `/hi-docs:write-doc` and `/hi-docs:reader-test` — documents that read in short sittings, tested on a reader with no context. |
| `hi-crew` | `/hi-crew:start <KEY>` — a worker agent on a ticket, in its own Orca workspace, carrying it to a reviewed pull request and stopping only for a person's decision. `/hi-crew:agenda` — what the workers wait on you for: their questions, people's comments on their PRs, PRs ready to merge. A watch (an Orca automation that never starts an agent) wakes the coordinator when a worker's PR is merged or closed, its CI fails, a person comments, the worker sits on a dialog, or one of its tool calls stays open too long. Its hooks keep one small state line per Claude Code session (working, blocked or idle), which `/hi:worktrees` dispatch reads before the screen. A worker first checks its ticket is not already done (landed on the trunk, a merged PR, the result present) and then reports that instead of opening a PR; any session that does work belonging to an open ticket comments on that ticket. Needs Orca with orchestration turned on, and `jq`. Team settings under `crew` in `.claude/highness.json`: `process`, `agent`, `model`, `marker`, `pr_state`; and `agenda.sections`, the team's own digest sections (its tickets, its PRs, reviews waiting), each a command that prints JSON lines, so the digest covers the person's whole plate without hi knowing the team's tracker or forge. Opt-in autostart: the watch starts labelled tickets into free slots, after a check of the plan's usage (see below). |

## Install

```
/plugin marketplace add metheoryt/highness
/plugin install hi@highness
```

For a team, add the marketplace and the plugins to the repo's `.claude/settings.json`
(`extraKnownMarketplaces` and `enabledPlugins`).

## First run

1. Install the plugins above (`hi` and `hi-crew` at least; `hi-guard` is recommended), in the Claude
   Code profile Orca starts its agents under.
2. In a new session, from the repo you will start tickets in: `/hi:setup`. It checks the machine
   (jq, Orca and its orchestration, the launcher, the plugins the worker profile loads, the hi-crew
   watch, the board columns), your config (`crew.agent`, `crew.model`, a repo overlay) and the repo
   (an Orca project, plus `/hi:repo-setup`), and proposes one fix per gap. Some steps are yours in
   the Orca window; it gives them.
3. `/hi-crew:start <KEY>`. A key is letters, digits, `.`, `_` and `-` only (`[A-Za-z0-9._-]`), not
   starting with a dot: `repo-24` works, `repo#24` does not.

### Autostart (opt-in)

The watch can start tickets on its own: every 10 minutes it starts ready tickets that carry a label,
oldest first, into free slots. It is off by default, and every key is read from your own config
only, since it runs a command and starts agents:

```json
{"crew": {"autostart": {
  "enabled": true,
  "root": "~/work/team-workspace",
  "candidates": "my-tracker-query --label {{LABEL}} --json",
  "label": "auto",
  "max_active": 3
}}}
```

- `root`: the coordinator's git root. The team's `crew` settings are read there, the candidates
  command runs there, and workers start in it unless a ticket names a repo.
- `candidates`: prints one JSON object per ready ticket, `{"key", "title", "url", "repo"?, "created"?}`.
  Unset, it lists the root's GitHub issues with the label. Other keys: `repo`, `base`, `run`,
  `max_usage_pct` (80), `usage_max_age_min` (30). `bash crew.sh` lists them all.
- Workers join the Run of the coordinator session that last asked for its Run on this machine, so
  their questions go there. With no such session, nothing starts.
- A slot is busy while a worker may still work: its PR is open, or it has no PR and has not
  reported yet. A merged PR frees the slot even when the ticket stays open.
- Each ticket is tried once (`autostart/tried/<KEY>` in the state dir). One line per start or skip
  goes to `autostart/log`. `crew.sh autostart --dry-run` shows what it would do.

**Usage check.** Before it starts anything, the watch reads the plan usage of the account Orca
launches agents on. At or over `max_usage_pct` in the 5-hour or the weekly window, it starts
nothing. Claude Code hands these figures only to a statusline, so yours has to keep them. Add one
line to your statusline command, which gets the session JSON on stdin:

```sh
printf '%s' "$input" | bash <marketplace clone>/plugins/hi-crew/lib/crew.sh usage-save
```

Known gaps:
- A figure that is missing, unreadable or older than 30 minutes counts as unknown. Unknown never
  blocks a start.
- The figure is only as fresh as the last statusline refresh on that account.
- Orca has no per-launch account choice, so the watch cannot move a start to a less-used account.
  It skips the start instead. Switching Orca's selected account would also move your own new
  sessions.

## Configuration

Optional JSON, read by every plugin: `~/.config/highness/config.json` (or `$HIGHNESS_CONFIG`) for one
person, `.claude/highness.json` in a repo for a team. A repo key wins; lists from both add up.
`guard.exempt_commands` and `guard.checks` are read from the personal file only: a repo's file comes
with every clone, so it may add deny patterns but never switch the guard off or run a program. One exception:
`land.test`, the suite `wt.sh land` runs before it lands a branch, is read from the repo's file too —
it runs the repo's own tests, code any clone already carries.

```json
{
  "guard": { "deny_patterns": ["terraform apply"], "exempt_commands": [], "checks": [] },
  "repo_setup": { "mode": "local" },
  "land": { "test": "bash tests/run.sh </dev/null" },
  "dispatch": { "read_dirs": ["~/plugins/team-skills"] },
  "docs": { "conventions": "docs/writing.md" }
}
```

`dispatch.read_dirs` (personal file only) lists directories a worker started by `wt.sh dispatch`
may read but never edit — another plugin's skills or reference files, a team checkout outside
the workspace. Each becomes an `--add-dir` with an Edit deny rule beside it, as the hi plugin's own
directory already is, so the worker neither stops on "read outside working directory" nor
changes them. A directory that holds the workspace, or sits inside it, is left out.

`wt.sh dispatch` also keeps a new session off Claude Code's folder-trust dialog, which nobody
watching a dispatched terminal answers. Trust stays the person's decision: when the repo's main
checkout or another of its worktrees is already trusted, the new workspace is trusted in the
config of the account the session runs under (`--config-dir`, else the caller's
`CLAUDE_CONFIG_DIR`, else `~/.claude.json`); a repo never trusted is left to ask, and a review
workspace counts only its main checkout's trust. A new session that still opens on a dialog makes
dispatch exit 6 with the screen it shows.

For a team repo that cannot carry `.claude/highness.json`, the personal file can set keys per repo,
by `origin`'s owner or owner/repo (host ignored): `"repos": {"acme": {"docs": {"conventions":
"~/acme/writing.md"}}}`. The repo's own file still wins, then `owner/repo`, then `owner`, then the
top level. Keys read from the personal file only ignore these overlays.

## Orca

`hi` writes a small launcher, `~/.local/bin/highness`, at session start, so Orca (outside Claude
Code) can reach the plugin. To set up every new worktree of a repo for the whole team, commit an
`orca.yaml` at its root (each person approves its commands once in Orca):

```yaml
scripts:
  setup: '"$HOME/.local/bin/highness" worktree-setup || true'
  archive: '"$HOME/.local/bin/highness" worktree-teardown || true'
```

A personal hook set in Orca's repo settings takes precedence over `orca.yaml` unless the repo's
command source policy says otherwise; `/hi:repo-setup` shows which one Orca will run.

## Requirements

bash 3.2+, git, jq. Optional: [Orca](https://github.com/stablyai/orca) 1.4.246 or newer, gortex. hi follows the current Orca and keeps no path for an older one: with an older Orca, `wt.sh` says to update it and makes plain git worktrees meanwhile.

## Tests

`bash tests/run.sh </dev/null`
