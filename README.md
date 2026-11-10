# highness

A harness for Claude Code agents, as a plugin marketplace. Each plugin is enabled on its own.

| plugin | what it gives |
|---|---|
| `hi` | `/hi:worktrees` — one workspace per piece of work, over Orca worktrees or plain git worktrees, with lineage, a removal check and a per-tree setup (gortex tracking when gortex is installed, local config links, the repo's own setup script). `/hi:repo-setup` — check and wire a repo for that. |
| `hi-guard` | A PreToolUse hook on Bash: denies `sudo` from an agent session (quote-aware, through `bash -c`, `ssh`, `eval`…) and any configured deny pattern. Other tools can add checks. |
| `hi-docs` | `/hi-docs:write-doc` and `/hi-docs:reader-test` — documents that read in short sittings, tested on a reader with no context. |
| `hi-crew` | `/hi-crew:start <KEY>` — a worker agent on a ticket, in its own Orca workspace, carrying it to a reviewed pull request and stopping only for a person's decision. `/hi-crew:agenda` — what the workers wait on you for: their questions, people's comments on their PRs, PRs ready to merge. A watch (an Orca automation that never starts an agent) wakes the coordinator when a worker's PR is merged or closed, its CI fails, a person comments, or the worker sits on a permission dialog (a Notification hook marks it). Needs Orca with orchestration turned on, and `jq`. Team settings under `crew` in `.claude/highness.json`: `process`, `agent`, `model`, `marker`, `pr_state`. |

## Install

```
/plugin marketplace add metheoryt/highness
/plugin install hi@highness
```

For a team, add the marketplace and the plugins to the repo's `.claude/settings.json`
(`extraKnownMarketplaces` and `enabledPlugins`).

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
`CLAUDE_CONFIG_DIR`, else `~/.claude.json`); a repo never trusted is left to ask. A new session
that still opens on a dialog makes dispatch exit 6 with the screen it shows.

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
