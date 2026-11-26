# highness

A harness for Claude Code agents, as a plugin marketplace. Each plugin is enabled on its own.

| plugin | what it gives |
|---|---|
| `hi` | `/hi:worktrees` — one workspace per piece of work, over Orca worktrees or plain git worktrees, with lineage, a removal check and a per-tree setup (gortex tracking when gortex is installed, local config links, the repo's own setup script). `/hi:repo-setup` — check and wire a repo for that. `/hi:setup` — check and fix a machine and a person for hi and hi-crew, then the repo. `/hi:meet` — seed your working preferences from your own past sessions, each line with its evidence, written only where you say yes. `/hi:account` — after an Orca account switch, move the live agent sessions onto the selected account, each resuming its own chat in its own pane. |
| `hi-guard` | A PreToolUse hook on Bash: denies `sudo` as a command from an agent session (quote-aware, through `bash -c`, `ssh`, `eval`…; a mention in a string, a grep pattern or a heredoc of text is data) and any configured deny pattern. Other tools can add checks. Every deny and ask it makes, and every refusal of Claude Code's auto-mode classifier (a `PermissionDenied` hook), goes to one local log, `<state>/denials.jsonl` (JSON lines: time, session, cwd, tool, the command or path, who denied it and why), which the hi-crew retro reads to find false denials. |
| `hi-docs` | `/hi-docs:write-doc` and `/hi-docs:reader-test` — documents that read in short sittings, tested on a reader with no context. |
| `hi-crew` | `/hi-crew:start <KEY>` — a worker agent on a ticket, in its own Orca workspace, carrying it to a reviewed pull request and stopping only for a person's decision. Before it asks, a worker does its own research and takes the obvious calls; what it brings is a trade-off, each option with what it loses and the rule it leans on (or `no rule`), and it states its direction before building so a wrong one is caught early. Each answered ask is recorded (`crew.sh choices`), so a person's choices can be read back across tickets. `/hi-crew:agenda` — what the workers wait on you for: their questions, people's comments on their PRs, PRs ready to merge. A watch (an Orca automation that never starts an agent) wakes the worker itself, with a round, when its PR's CI fails or a review bot leaves findings, and wakes the coordinator when the PR is merged or closed, a person comments or approves, the worker sits on a dialog, or one of its tool calls stays open too long. Bots on normal accounts are named in `crew.bots`, so their comments wake no one. Its hooks keep one small state line per Claude Code session (working, blocked or idle), which `/hi:worktrees` dispatch reads before the screen. A worker first checks its ticket is not already done (landed on the trunk, a merged PR, the result present) and then reports that instead of opening a PR; any session that does work belonging to an open ticket comments on that ticket. Needs Orca with orchestration turned on, and `jq`. Team settings under `crew` in `.claude/highness.json`: `process`, `agent`, `model`, `marker`, `pr_state`, `bots`, `finding_patterns`; and `agenda.sections`, the team's own digest sections (its tickets, its PRs, reviews waiting), each a command that prints JSON lines, so the digest covers the person's whole plate without hi knowing the team's tracker or forge. A tracker adapter for Jira, YouTrack and GitHub Issues (`tracker` in the config) gives those sections, the autostart candidates and the workers' ticket reads, moves and comments without glue of the team's own (see Tracker below). Opt-in autostart: the watch starts labelled tickets into free slots, after a check of the plan's usage (see below). |
| `hi-threads` | A journal of work threads across every Claude Code session on the machine. After each turn a Stop hook starts a background job that gives what happened since the last update, with the project's open threads, to a model (`threads.model`, default `sonnet`), which notes the thread it belonged to, what was done, what is left and who it waits on. A new session starts with the project's most urgent open threads in its context; `/hi-crew:agenda`, when installed, shows them first among its sections, beside tickets, PRs and workers; `/hi-threads:where` shows only the threads, ranked, and offers a backfill from the sessions already on the machine. A thread that closes, or stays paused for two hours, gets a comment in its ticket through the person's own command (`threads.comment.commands` in the user config: a regex on the ticket key and a command that reads the comment on stdin). The journal is checked against the forge and the tracker: with the team's commands `threads.check.pr` (`{{PR}}` → `{"state": "open|merged|closed"}`) and `threads.check.ticket` (`{{KEY}}` → `{"state", "resolved"}`), the job after each turn (at most every 10 minutes) and the agenda close a thread whose PRs all merged or closed and whose tickets are all resolved. A project is the repo, or the umbrella of nested clones (a `repos.txt` above them). Costs one model call per turn; headless `claude -p` sessions are skipped. Needs `jq`. |
| `hi-review` | `/hi-review:review <PR>` — review a GitHub pull request from the current session and submit it as one review. A read-only reviewer subagent (`hi-review:reviewer`: no edits, no checkout, no posting) drafts the findings against the PR head, using gortex's view of the head when gortex is installed; a second, fresh reviewer pass tries to break each finding before you see it; you read the cards and the exact payload, and one question picks the verdict (approve, request changes, comment, or nothing posted). The review is created and submitted in one call, replacing your own pending draft if you had one. Team settings under `review` (see Configuration). Quick mode only for now: review workspaces, re-reviews since the last round and checking your own PR come later. Needs `gh` and `jq`. `/hi-review:brief <PR>` — when a review bot already finds the bugs: a brief of 2–4 items for you to decide, picked by your review lens (what you look at in a review), each with the agent's own view before the question, plus where people's reviews agree or clash and an optional bold idea that closes several past problems; below them, apart, at most three defects no one on the PR raised, each confirmed by a second reviewer pass. Posts nothing; every item's outcome goes to a local journal, `/hi-review:brief stats` sums it up. Reads a GitHub PR through `gh`, any other forge through the team's adapter (`review.brief.source`). |

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
   highness plugin once, stale project pins of them and live ones at another version than the user
   install, the hi-crew watch, the board columns), your config (`crew.agent`, `crew.model`,
   `session.language`, a repo overlay) and the repo
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
that).

**Account health.** `lib/account-health.sh` (in hi and hi-crew) tells whether an account can run
at all: `ok`, `limited` (a window spent), `dead` (payment past due, disabled, logged out) or
`unknown`. It reads the usage endpoint first. With no figures — a 401, and also a 429, which the
endpoint answers both for an account whose token needs a refresh and for one whose payment is
past due — it runs one tiny `claude -p`, which refreshes the token, and reads again once. A probe
that fails says why, and that line decides. `claude auth status` cannot tell: it says logged in
for a past-due account. The budget holds a dead account whatever its cache says, `budget.sh
room` never offers one, and `account.sh select` refuses a dead or limited account (`--force`
overrides). `bash lib/budget.sh check` prints the verdict. Other launchers of background agents can call
it the same way: exit 0 is go, 1 is hold.

The account is the one Orca launches agents on (`crew.sh account` prints it): Orca's active Claude
account; with none, the profile home `claude-profiles/selected-host` in Orca's data dir names; else
`crew.budget.config_dir` in your own config; else the profile home whose statusline cache is the
freshest. A hold that lasts over an hour shows in `/hi-crew:agenda` as
"autostart held <N> h: <reason>" (`crew.sh held`). When the budget is the reason and another of
Orca's Claude accounts is under its line (`budget.sh room`), the agenda offers to switch to it.
It never switches on its own, because which plan pays is your call. On your yes it selects that
account and `/hi:account` moves the live sessions onto it. Then `hold.sh repoint <its config dir>`
points the workers the budget paused at the new account, and they continue if it has room.

**Moving sessions to another account.** After `orca account select`, sessions that are already
running stay on the old account. `/hi:account` (`lib/account.sh move` in hi) moves them: the
coordinator, the workers and your other work sessions. It waits until each session is idle, then
types `/exit` into its Orca pane and `claude --resume <its session> <its flags>`. Orca's pane shell
starts that line on the selected account, and every account reads the same transcripts. The pane
keeps its terminal handle, so the coordinator keeps its Run. A worker's Dispatch is failed by Orca
when its Claude exits; `crew.sh resume <KEY>` gives the moved worker a new one in the same pane,
with its chat. A session
mid-turn is never interrupted: it moves once idle, or is reported `busy` when the wait runs out.
The session that runs the move goes last, in the background, after its turn. claude.ai connectors
belong to the account. Each one the new account lacks is named in the report and to the session
itself. A move to another organization makes each session's first turn slower and dearer, because
Claude cannot reuse thinking written under another organization.

**Switch with Orca's restart off.** Orca can restart the sessions itself on a switch, but it does
so in a new pane with a new terminal handle: the chat survives, and a worker's Dispatch is lost.
With workers running, set Orca's Settings → Accounts → "When you switch accounts while Claude is
running in terminals" to **Never restart**, then switch and run `/hi:account`. Under "Ask" a
switch in the status bar shows a dialog where you can untick the workers, but a switch from the
CLI restarts everything with no dialog, so `/hi:account` (`account.sh select`) and the agenda
refuse to switch unless the setting is Never restart. `/hi:setup` shows the setting as the
`account-switch` row.

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

To start that file from what you already did, run `/hi:meet` (`/hi:setup` offers it when you have
no preference file yet). It reads your own Claude Code sessions on this machine (the last 60 days,
every Claude profile Orca uses included; headless runs, dispatched workers, subagents and pasted
text left out), counts your corrections, rejected tool calls, permission denials, repeated asks and
the skills you use, reads a sample in full, and drafts lines each backed by evidence: the session,
the date and a short quote of your own words, with paths, addresses and anything token-shaped
masked. You keep, reword or drop each line; only kept ones are written, through `prefs.sh`, into
the files `preferences` names (no second store). Candidate team rules come apart and become a
pull request only on your yes, without your quotes. Nothing leaves the machine
(`hi/lib/meet.sh`).

## Configuration

Optional JSON, read by every plugin: `~/.config/highness/config.json` (or `$HIGHNESS_CONFIG`) for one
person, `.claude/highness.json` in a repo for a team. A repo key wins; lists from both add up.
A clone with no `.claude/highness.json` of its own, inside an umbrella (a checkout whose `repos.txt`
lists it), takes the umbrella's file; `config.sh root` names the directory whose file applies.
`guard.exempt_commands` and `guard.checks` are read from the personal file only: a repo's file comes
with every clone, so it may add deny patterns but never switch the guard off or run a program
(scoping them per repo: the overlays below). One exception:
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

`/hi-review:brief` reads two more keys. `review.brief.source` (team file) is a command that prints
a pull request as one JSON object — `{repo, number, url, title, body, author, state, draft, head,
base, diff, reviews, threads, comments}`, the full shape in `plugins/hi-review/lib/brief.sh` — with
`{{PR}}` (the skill's argument) and `{{ROOT}}` filled in, quoted; unset, a GitHub PR is read with
`gh`. `review.brief.lens` (team file) is a command that prints a person's review lens as text,
`{{LOGIN}}` empty for the person themselves; `review.lens` (personal file) is the person's own lens,
text or a path to a file. Both are shown when both are set. The journal is
`$XDG_STATE_HOME/highness/review/briefs.jsonl` and never leaves the machine.

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
by `origin`'s owner or owner/repo (host ignored, keys lowercase): `"repos": {"acme": {"docs":
{"conventions": "~/acme/writing.md"}}}`. The repo's own file still wins, then `owner/repo`, then
`owner`, then the top level. Keys read from the personal file only ignore these overlays, with one
exception: `guard.checks`.

A person who works for a team and on their own repos scopes the team's guard to the team's repos
the same way. `guard.deny_patterns` and `guard.checks` under `repos.<owner>` (or `<owner/repo>`)
apply only in sessions whose repo matches; the top level's apply everywhere. A check is the
person's own program and can only deny or ask, so it is the one personal-only key an overlay may
carry; `guard.exempt_commands` stays top-level only, since any clone can carry a matching remote
name. A team's ready-gate check that sat in the top-level `guard.checks`, and so also ran in the
person's own repos, moves under the team's owner (and leaves the top level, or it runs twice there):

```json
{
  "guard": { "deny_patterns": ["terraform apply"] },
  "repos": {
    "acme": { "guard": { "checks": ["~/plugins/acme-tools/bin/ready-gate"],
                         "deny_patterns": ["acme-prod-[a-z]+"] } }
  }
}
```

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

### Forge sections

The agenda lists your pull requests and the reviews waiting on you by itself, from GitHub through
`gh`'s own login (`lib/forge.sh`, after the team's `agenda.sections`). No `gh` on the machine:
nothing. A PR a worker owns, or one a team section already lists, shows once.

- **my PRs**: your open PRs, each with its next step: CI failing (which checks), changes requested,
  unanswered review comments (an unresolved thread counts while it is outdated too; a reply of
  yours on the PR, or a review with a body, answers what came before it), merge conflicts, a draft
  to mark ready (or, when its branch or title names a ticket a tracker section shows in role
  `waiting`, a draft that waits on that ticket), a re-request once the changes are answered,
  approved and green: merge it; or waiting on reviewers, CI, a review check, auto-merge.
- **reviews asked of me** and **reviews asked of my team**: the PRs whose review was requested of
  you by name or through a team. A draft review of yours not yet submitted is marked; one you
  already reviewed links to what changed since your review.

Settings, under `agenda.forge` (`"forge": false` turns the sections off):

- `query`: search terms added to every search, say `org:acme`; default every repo you can see.
- `approvals`: how many approvals a PR needs; default GitHub's own review decision.
- `review_labels`: labels that summon reviewers; a ready PR with none is told to add the first.
- `review_checks`: a regex of check names that are review gates, not CI (waited on, never "CI
  failing").
- `reviews`: extra review queues, `[{"name": "...", "query": "label:needs-review", "group":
  "others"}]`, each a section of its own.

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

In an Orca tab, `hi` asks the agent to name the tab after the work in it — the ticket or the thing
being fixed, not the skill that opened the session — and to rename it when the subject changes
(`lib/tab-title.sh`; `highness tab-title "<title>"` from a shell). Turn off Orca's own **Auto
Generate Tab Titles** so the two do not overwrite each other. A tab opened from another Orca
window, with this host as its remote server, keeps its old name there: Orca stores the rename on
this host but that window does not redraw it.

## Requirements

bash 3.2+, git, jq. Optional: [Orca](https://github.com/stablyai/orca) 1.4.246 or newer, gortex. hi follows the current Orca and keeps no path for an older one: with an older Orca, `wt.sh` says to update it and makes plain git worktrees meanwhile.

## Tests

`bash tests/run.sh </dev/null`
