# highness

A harness for Claude Code agents, as a plugin marketplace. Each plugin is enabled on its own.

| plugin | what it gives |
|---|---|
| `hi` | `/hi:worktrees` — one workspace per piece of work, over Orca worktrees or plain git worktrees, with lineage, a removal check and a per-tree setup (gortex tracking when gortex is installed, local config links, the repo's own setup script). `/hi:repo-setup` — check and wire a repo for that. `/hi:setup` — check and fix a machine and a person for hi and hi-crew, then the repo. |
| `hi-guard` | A PreToolUse hook on Bash: denies `sudo` from an agent session (quote-aware, through `bash -c`, `ssh`, `eval`…) and any configured deny pattern. Other tools can add checks. |
| `hi-docs` | `/hi-docs:write-doc` and `/hi-docs:reader-test` — documents that read in short sittings, tested on a reader with no context. |
| `hi-crew` | `/hi-crew:start <KEY>` — a worker agent on a ticket, in its own Orca workspace, carrying it to a reviewed pull request and stopping only for a person's decision. Before it asks, a worker does its own research and takes the obvious calls; what it brings is a trade-off, each option with what it loses and the rule it leans on (or `no rule`), and it states its direction before building so a wrong one is caught early. Each answered ask is recorded (`crew.sh choices`), so a person's choices can be read back across tickets. `/hi-crew:agenda` — what the workers wait on you for: their questions, people's comments on their PRs, PRs ready to merge. A watch (an Orca automation that never starts an agent) wakes the coordinator when a worker's PR is merged or closed, its CI fails, a person comments, the worker sits on a dialog, or one of its tool calls stays open too long. Its hooks keep one small state line per Claude Code session (working, blocked or idle), which `/hi:worktrees` dispatch reads before the screen. A worker first checks its ticket is not already done (landed on the trunk, a merged PR, the result present) and then reports that instead of opening a PR; any session that does work belonging to an open ticket comments on that ticket. Needs Orca with orchestration turned on, and `jq`. Team settings under `crew` in `.claude/highness.json`: `process`, `agent`, `model`, `marker`, `pr_state`; and `agenda.sections`, the team's own digest sections (its tickets, its PRs, reviews waiting), each a command that prints JSON lines, so the digest covers the person's whole plate without hi knowing the team's tracker or forge. A tracker adapter for Jira, YouTrack and GitHub Issues (`tracker` in the config) gives those sections, the autostart candidates and the workers' ticket reads, moves and comments without glue of the team's own (see Tracker below). Opt-in autostart: the watch starts labelled tickets into free slots, after a check of the plan's usage (see below). |
| `hi-threads` | A journal of work threads across every Claude Code session on the machine. After each turn a Stop hook starts a background job that gives what happened since the last update, with the project's open threads, to a model (`threads.model`, default `sonnet`), which notes the thread it belonged to, what was done, what is left and who it waits on. A new session starts with the project's most urgent open threads in its context; `/hi-crew:agenda`, when installed, shows them first among its sections, beside tickets, PRs and workers; `/hi-threads:where` shows only the threads, ranked, and offers a backfill from the sessions already on the machine. A thread that closes, or stays paused for two hours, gets a comment in its ticket through the person's own command (`threads.comment.commands` in the user config: a regex on the ticket key and a command that reads the comment on stdin). The journal is checked against the forge and the tracker: with the team's commands `threads.check.pr` (`{{PR}}` → `{"state": "open|merged|closed"}`) and `threads.check.ticket` (`{{KEY}}` → `{"state", "resolved"}`), the job after each turn (at most every 10 minutes) and the agenda close a thread whose PRs all merged or closed and whose tickets are all resolved. A project is the repo, or the umbrella of nested clones (a `repos.txt` above them). Costs one model call per turn; headless `claude -p` sessions are skipped. Needs `jq`. |
| `hi-review` | `/hi-review:review <PR>` — review a GitHub pull request from the current session and submit it as one review. A read-only reviewer subagent (`hi-review:reviewer`: no edits, no checkout, no posting) drafts the findings against the PR head, using gortex's view of the head when gortex is installed; a second, fresh reviewer pass tries to break each finding before you see it; you read the cards and the exact payload, and one question picks the verdict (approve, request changes, comment, or nothing posted). The review is created and submitted in one call, replacing your own pending draft if you had one. Team settings under `review` (see Configuration). Quick mode only for now: review workspaces, re-reviews since the last round and checking your own PR come later. Needs `gh` and `jq`. |

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
   (jq, Orca and its orchestration, the launcher, that every Claude profile Orca uses loads each
   highness plugin once, stale project pins of them, the hi-crew watch, the board columns), your config (`crew.agent`, `crew.model`, a repo overlay) and the repo
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
  Unset, it asks the root's tracker (below) for its ready tickets with the label, or, with no
  tracker configured, lists the root's GitHub issues with the label. Other keys: `repo`, `base`, `run`.
  `bash crew.sh` lists them all.
- Workers join the Run of the coordinator session that last asked for its Run on this machine, so
  their questions go there. With no such session, nothing starts.
- A slot is busy while a worker may still work: its PR is open, or it has no PR and has not
  reported yet. A merged PR frees the slot even when the ticket stays open.
- Each ticket is tried once (`autostart/tried/<KEY>` in the state dir). One line per start or skip
  goes to `autostart/log`. `crew.sh autostart --dry-run` shows what it would do.

**Usage check.** Before it starts anything, the watch asks `lib/budget.sh` whether the account
Orca launches agents on may spend. You keep a reserve of each plan window for your own sessions,
and it shrinks as the window nears its reset — a leftover about to reset is lost anyway:

    agents may run while  used% < 100 - reserve × (time left / window length)

The reserve is `crew.budget.five_hour_reserve` and `crew.budget.seven_day_reserve` in your own
config, 50 by default: a fresh 5-hour window lets agents reach 50%, one with an hour left 90%.
The figures come live from the plan's usage endpoint (no tokens spent, every machine on the account
counted); a figure that cannot be read holds the start (`crew.budget.on_unknown: "go"` to change
that). `bash lib/budget.sh check` prints the verdict. Other launchers of background agents can call
it the same way: exit 0 is go, 1 is hold.

The account is the one Orca launches agents on (`crew.sh account` prints it): Orca's active Claude
account; with none, the profile home `claude-profiles/selected-host` in Orca's data dir names; else
`crew.budget.config_dir` in your own config; else the profile home whose statusline cache is the
freshest. A hold that lasts over an hour shows in `/hi-crew:agenda` as
"autostart held <N> h: <reason>" (`crew.sh held`).

**Pausing a running worker.** Each watch pass also writes the verdict for the account as a flag
(`<config dir>/highness-hold`, `lib/hold.sh pass`). While it is there, an autostarted worker's next
tool call ends its turn: the session stays open and idle, its work in the tree as it was. When the
account is back under its line, the watch types "continue" into exactly the sessions it stopped. Your
own sessions are never stopped: the hook acts only on a session the autostart launched (a hi-crew
record with `autostart: true` for its directory, or a session started with
`wt.sh dispatch --pretool "bash <…>/lib/hold.sh hook --worker"`). `bash lib/hold.sh held` lists the
stopped ones.

When the endpoint cannot be reached, the figures your statusline keeps are used while they are
fresh (`crew.budget.cache_max_age_min`, 30). For that, add one line to your statusline command,
which gets the session JSON on stdin:

```sh
printf '%s' "$input" | bash <marketplace clone>/plugins/hi-crew/lib/crew.sh usage-save
```

Known gaps:
- The usage endpoint is not documented; a change in its shape reads as unknown, which holds.
- A worker is paused at its next tool call, not mid-call, and only as often as the watch runs: a
  worker can spend past the line for up to one watch interval.
- Taking over an autostarted hi-crew worker's session by hand does not exempt it from the pause
  (the hook knows it by its directory).
- Orca has no per-launch account choice, so the watch cannot move a start to a less-used account.
  It skips the start instead. Switching Orca's selected account would also move your own new
  sessions.

### The retro at close

When a ticket is settled, the coordinator runs a short retro in its own session before
`crew.sh close` (`hi-crew/reference/retro.md`): it reads the worker's spec, the ticket, the PR and
the signals `lib/retro.sh gather` pulls from the worker's transcript and the denial log, and files
at most 3 findings (a tool fault, a gap in the worker spec, a process question), each
deduplicated against open items. Then it comments the ticket, first line `<!-- hi:retro -->`.
Findings go to GitHub issues unless the team sets `crew.retro_sink`, a command with `{{KIND}}`
(`tool`, `brief` or `decision`), `{{TITLE}}`, `{{BODY_FILE}}`, `{{TICKET}}` and `{{ROOT}}`
filled in shell-quoted, which prints the created key or URL, or `dup <key>`.

### Your preferences

highness reads your own store of working preferences; it does not keep one for you. Set
`preferences` in your own config (never a repo's) to a file, a directory (its `*.md` files) or a
list of them, e.g. `"preferences": ["~/notes/how-i-work.md", "~/notes/prefs/"]`. Unset, it is one
file, `~/.config/highness/preferences.md`. A worker's spec names these files (it never copies
their text), so its asks cite them in `leans on:`. At the close, the retro turns the ticket's
recorded choices into proposed lines for the file they fit, shown as a diff and written only on
your yes (`hi-crew/lib/prefs.sh`); your own sync carries them from there. A choice made the same
way on several tickets becomes a drafted team rule, opened as a pull request to the team's rules
file (`crew.team_rules` in the team's settings, a path in its repo) only on your yes, for the
team to accept or reject in review.

## Configuration

Optional JSON, read by every plugin: `~/.config/highness/config.json` (or `$HIGHNESS_CONFIG`) for one
person, `.claude/highness.json` in a repo for a team. A repo key wins; lists from both add up.
A clone with no `.claude/highness.json` of its own, inside an umbrella (a checkout whose `repos.txt`
lists it), takes the umbrella's file; `config.sh root` names the directory whose file applies.
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
  "docs": { "conventions": "docs/writing.md" },
  "review": { "intent": "Specs live in docs/specs/<KEY>.md; the key is in the PR title.", "bots": ["lint-helper"], "voice": "~/notes/review-voice.md" },
  "session": { "language": "Russian" }
}
```

`session.language` (personal file only) is the language every highness skill answers in when the
session has no words of the person's yet — a bare `/hi-crew:agenda` or `/hi-crew:start KEY`. Once
the person writes, the chat follows what they write; unset, it is English.

`review.intent` is a text the team writes: where its specs live and how a PR leads to them;
`/hi-review:review` reads it beside the PR body and the issues the PR closes. `review.bots` lists
the logins whose comments count as a bot's (a `[bot]` login always does); lists from both files
add up. `review.voice` (personal file only) names a file with the person's own voice for review
comments, read after the plugin's default and winning where they differ.

`dispatch.read_dirs` (personal file only) lists directories a worker started by `wt.sh dispatch`
may read but never edit — another plugin's skills or reference files, a team checkout outside
the workspace. Each becomes an `--add-dir` with an Edit deny rule beside it, as the hi plugin's own
directory already is, so the worker neither stops on "read outside working directory" nor
changes them. A directory that holds the workspace, or sits inside it, is left out.

`wt.sh dispatch` also keeps a new session off Claude Code's folder-trust and "Allow external
CLAUDE.md file imports" dialogs, which nobody watching a dispatched terminal answers. Both stay the
person's decisions, copied only from where they already made them — the caller's
`CLAUDE_CONFIG_DIR`, Claude Code's default config, or any of Orca's Claude profiles — into the
config of the account the session runs under (`--config-dir`, else the caller's
`CLAUDE_CONFIG_DIR`, else `~/.claude.json`). Trust: when the repo's main checkout or another of its
worktrees is trusted, so is the new workspace; a repo never trusted is left to ask, and a review
workspace counts only its main checkout's trust. Imports: Claude Code keeps the answer on the main
checkout's entry for every worktree of the repo, so the main checkout's yes or no is copied there
when the configs that have one agree; a review workspace gets only a no, since its branch can
import other files. Trusting a folder that holds the workspaces does not help: Claude Code stops
at a git repo's root (measured on 2.1.328). A new session that still opens on a dialog makes
dispatch exit 6 with the screen it shows.

For a team repo that cannot carry `.claude/highness.json`, the personal file can set keys per repo,
by `origin`'s owner or owner/repo (host ignored): `"repos": {"acme": {"docs": {"conventions":
"~/acme/writing.md"}}}`. The repo's own file still wins, then `owner/repo`, then `owner`, then the
top level. Keys read from the personal file only ignore these overlays.

### Tracker

hi-crew ships one adapter for Jira, YouTrack and GitHub Issues, `hi-crew/lib/tracker.sh`, so a
team configures its tracker instead of writing the glue. The tracker part is not secret and goes in
the team's file (or an overlay); the credential never does:

```json
{
  "tracker": {
    "kind": "jira",
    "base_url": "https://example.atlassian.net",
    "projects": ["AB"],
    "statuses": {"To Do": "todo", "In Progress": "active", "In Review": "in_review",
                 "Blocked": "waiting", "QA": "testing", "Done": "done", "Reopened": "bounced"},
    "transitions": {"in_review": "Send to review"},
    "fields": {"done": {"resolution": {"name": "Done"}}}
  },
  "agenda": {"sections": [{"name": "tickets", "command": "{{TRACKER}} sections"}]},
  "crew": {"process": "Read the ticket with `{{TRACKER}} read {{KEY}}`; move it with `{{TRACKER}} move {{KEY}} in_review`."}
}
```

- `kind`: `jira` (Cloud, or Data Center), `youtrack` or `github`. `base_url` and `projects` for the
  first two; `repo` (owner/repo) for GitHub, default the origin.
- `statuses` maps each status name to a role: `todo`, `active`, `in_review`, `waiting`, `testing`,
  `done`, `bounced`. On GitHub the names are labels. A status left out falls back to Jira's status
  category, YouTrack's resolved flag, or GitHub's open/closed (open with no role label is `todo`).
- `transitions` names, per role, the Jira transition to take or the YouTrack command to apply;
  without it a move takes the first transition (state, label) that lands in that role. `fields`
  gives the fields a move to a role must set, so a transition with required fields goes through.
- `state_field` (YouTrack, default `State`); `query`: a clause in the tracker's own query language
  that narrows the person's tickets and the candidates (a sprint, a component).
- In the digest a role becomes a group: `todo` → later, `active` and `bounced` → you, `in_review`,
  `testing` and `waiting` → others; `done` is left out.

The verbs: `status`, `sections` (the person's open tickets, as `agenda.sections` lines),
`candidates [LABEL]` (ready tickets with the label, for autostart), `read <KEY>` (the ticket as
JSON, with its role, description and comments), `move <KEY> <role>`, and `comment <KEY>` (the body
on stdin). `{{TRACKER}}` in `agenda.sections`, `crew.process` and `crew.autostart.candidates`
becomes this command, reading the config at the coordinator's root (a worker runs in another tree).
Exit codes: 1 no credential, 2 credential rejected, 3 usage, 4 config, 5 the tracker failed.

The credential lives in your personal file only, at its top level, keyed by the tracker's host.
The adapter sends a token only to the host you paired it with, so a cloned repo's `base_url`
cannot redirect it (a `base_url` must be a plain scheme, host, port and path: no user info, query
or fragment that could hide another host), and it travels in curl's config on stdin, never in a command line:

```json
{"trackers": {"example.atlassian.net": {"email": "you@example.com", "token_command": "secret-tool lookup service jira"}}}
```

`token_env` (a variable name) is read first, then `token_command` (its first line). Jira uses basic
auth (email + API token) unless `"auth": "bearer"` (a personal access token); YouTrack takes a
permanent token as bearer. A plain `http://` URL needs `"allow_http": true`. GitHub uses `gh`'s own
login. `/hi:setup` checks that the token answers.

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
