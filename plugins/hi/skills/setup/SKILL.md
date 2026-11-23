---
name: setup
description: Check and fix what a machine and a person need before the first /hi-crew:start — jq, Orca and its orchestration, the highness launcher, which highness plugins each Claude profile Orca uses loads (missing, loaded twice, stale project pins, project pins at another version than the user install), the hi-crew watch, the board columns hi moves workspaces between, the person's highness config (crew.agent, crew.model, session.language, a repo overlay, their preferences file, offering /hi:meet when there is none) — and then the repo in the cwd (an Orca project, plus every /hi:repo-setup row). One status table, then one proposed fix per gap, each run only on a yes. Never writes a file a repo tracks. Use on a fresh box, when the user asks to set up or check hi / hi-crew / highness, "why does hi-crew not work here", or before a first /hi-crew:start.
---

# /hi:setup

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language (no words of theirs yet: `session.language` in their config), Read one file
per call, 2–4 options per question.

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
- `account-switch restarts`: on an account switch Orca restarts the Claude sessions in new panes,
  with new terminal handles, so a running hi-crew worker loses its Dispatch (the chat survives).
  The person's step in the Orca window: Settings → Accounts → "When you switch accounts while
  Claude is running in terminals" → **Never restart**. Then `/hi:account` moves the sessions in
  their own panes. Keeping "Ask" is their call, but say what it costs: a switch from the CLI,
  `/hi:account` or the agenda is then refused, and in the status bar's dialog they untick every
  worker. Never write Orca's database. `unknown`: the setting could not be read; say so only.
- `launcher`: as in `/hi:repo-setup` (`missing` / `stale` are rewritten at the next session start
  with hi enabled; `foreign` is the person's own file).
- `plugin:<name> off`: the plugin is not enabled in the profile Orca starts workers under (the
  detail names it and why). A worker there runs without that plugin's skills and hooks: without
  `hi-crew` its permission-dialog marker and the watch's dialog wake-ups are dead; without
  `hi-guard`, no `sudo` and deny-pattern guard; without `hi-threads`, no journal of work threads
  and no threads section in `/hi-crew:agenda`. `hi` and `hi-crew` are needed; `hi-guard` and
  `hi-threads` are recommended; `hi-review` and `hi-docs` are optional (offer, do not push). The
  fix, on a yes:

      CLAUDE_CONFIG_DIR='<profile from the detail>' claude plugin install <name>@highness --scope user

  When the plugin is already installed there but disabled (`claude plugin list` shows it with
  `enabled: false`), the fix is `CLAUDE_CONFIG_DIR='<profile>' claude plugin enable <id>` instead.
  If install says the marketplace is unknown, first
  `CLAUDE_CONFIG_DIR='<profile>' claude plugin marketplace add metheoryt/highness`. Plugins and
  hooks load at session start: say that the running sessions keep the old set.
- `plugin:<name> double`: the profile loads the plugin twice; the detail names each copy and its
  source. A `link → <dir>` copy (`<id>@skills-dir`) is a link in the profile's `skills/` dir to a
  working copy: a local edit there changes every session without a release, and two copies run
  every hook twice. Ask which one stays (the marketplace copy, unless the person develops
  highness on this box). The fix for the link, on a yes: `rm '<profile>/skills/<name>'` (the link
  only, never its target; check `[ -L ]` first). When `<profile>/skills` is itself a link to a
  shared dir (Orca's profile homes often share one), the removal reaches every profile that
  shares it: check `[ -L '<profile>/skills' ]` and name those profiles before asking. For the
  marketplace copy:
  `CLAUDE_CONFIG_DIR='<profile>' claude plugin uninstall <name>@<marketplace> --scope <scope>`.
- `profile:<dir> gaps`: another Claude config dir Orca uses (it observed it, or it is an Orca
  account's profile home): if Orca switches to it, the plugins after `off:` silently go away, and
  `double:` names a plugin it loads twice. One fix per plugin, the same commands as the
  `plugin:<name>` rows above with `CLAUDE_CONFIG_DIR='<dir>'`. `profile:<dir> unknown`: its
  plugin list failed; say it was not checked. `ok` needs nothing.
- `pins:<file> stale`: project-scope pins of highness plugins whose project dir is gone (an old
  worktree): a workspace reopened at that path loads the pinned, older code. `claude plugin
  uninstall --scope project` cannot drop them (it only sees the project of its cwd, and needs
  that project's own settings). The fix, one per pin and on a yes: copy the file to
  `<file>.bak`, then drop that entry, shown before it runs:

      jq --arg id '<id>' --arg pp '<dir>' '.plugins[$id] |= map(select(.projectPath != $pp))
        | if (.plugins[$id] | length) == 0 then del(.plugins[$id]) else . end' '<file>' > '<file>.new' \
        && mv '<file>.new' '<file>'

  Say that running sessions keep what they loaded.
- `drift:<file> drift`: a project or local pin of a highness plugin whose dir still exists is at
  another version than the user-scope install of the same plugin, so a session in that project
  runs other code than every other session (`<id>: <dir> at <pin> (<scope>) vs <user> (user)`; a
  plugin that declares no version is compared by commit, shown after the version). Ask which side
  is behind; usually the pin. `claude plugin update` with a project or local scope only sees the
  project of its cwd, so the fix, one per pin and on a yes:

      cd '<dir>' && CLAUDE_CONFIG_DIR='<the profile that holds <file>>' claude plugin update <id> --scope <scope>

  When the user install is the older one: the same command with `--scope user` from anywhere. If
  the person did not mean to pin it at all, `claude plugin uninstall <id> --scope <scope>` from
  `<dir>` drops the pin instead; that one edits `<dir>/.claude/settings.json` (project) or
  `settings.local.json` (local), so in a repo that tracks the file it is a printed proposal. Say
  that running sessions keep what they loaded.
- `plugins unknown`: `claude` is missing or `claude plugin list --json` failed; say so, and that
  the plugin rows were not checked.
- `hi-crew off`: hi-crew is not enabled for workers, so there are no orchestration, watch or crew
  rows. Fix the `plugin:hi-crew` row first and re-run. `hi-crew unknown`: the enabled hi-crew is
  older than this check: `claude plugin update hi-crew@highness`, then re-run.
- `session-state old`: the enabled hi-crew predates the hooks that keep each session's state
  (working, blocked, idle), so dispatch and the watch tell a worker's state from its screen alone.
  The fix is the same update: `claude plugin update hi-crew@highness` in the worker profile; the
  hooks load at the next session start.
- `orchestration off`: the detail is Orca's own answer. In Orca 1.4.254 there is no switch for it;
  it is set up in Orca → **Settings → Orchestration → Agent Orchestration**, which installs the
  Orca CLI and the orchestration skill. An older Orca had it under Settings → Experimental. These
  are the person's steps in the Orca window: give them, and re-run after.
- `orca-skill missing`: `orca skills install --skill orchestration` (Orca's bundled skill for the
  detected agents; `--dry-run` first shows what it writes).
- `watch missing` / `disabled` / `stale`: `bash <hi-crew lib>/crew.sh watch-install` (the crew.sh
  next to the hi-crew the `plugin:hi-crew` row found). `stale`: the automation runs a crew.sh
  from another install; the same command repoints it.
- `board missing <labels>`: the workspace board lacks a column hi moves workspaces to (In
  progress, Review queue); `wt.sh
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
- `preferences missing`: none of the person's preference files exists yet (hi-crew's `prefs.sh
  paths`), so workers have nothing of theirs to read before they ask. Offer `/hi:meet` once, in one
  line: it seeds the file from their own past sessions, it is long and spends tokens, and it runs
  only when they start it. Never run it from here, and do not offer it again in this session after
  a no. `preferences ok`: a file or a store `preferences` points at exists; nothing to offer.
- `tracker` (only when the repo or the person configures `tracker`): hi-crew's tracker adapter
  asked the tracker who the person is. `no-token`: the person's file has no
  `trackers["<host>"]` entry for the tracker's host, or its `token_env` / `token_command` gives
  nothing. Offer the entry (`email` and `token_command` for Jira, `token_command` for YouTrack),
  shown as the whole new file; the token itself is the person's to mint and store in their own
  secret store or environment. Never ask them to paste it into the chat, and never write it to a
  file a repo tracks. `rejected`: the tracker refused the token; it needs a new one. `config`: the
  detail names the bad key (in the repo's file or the person's). `error`: the tracker did not
  answer (network, a VPN); say so, nothing to fix here.
- `session.language unset`: no language for a skill call with no words of the person's yet (a
  bare `/hi-crew:agenda`): those answer in English. Offer to set it to the language the person
  writes in this session, as an English name (`"session": {"language": "Russian"}`), shown as the
  whole new file. On a bare `/hi:setup` with no words of theirs, ask which language instead of
  guessing. It is read from the top level of the person's file only (never the repo's file or a
  `repos` block). A no is `null` there, on purpose, which reads as `default` and is not offered
  again. `set` and `default` need nothing.
- `overlay team-file`: the detail names the team file that applies. From a clone with no file of
  its own it is the umbrella's (an umbrella above the clone whose `repos.txt` lists it); nothing
  to fix. When the user expected the umbrella's file and the row says `none`, the umbrella does
  not list this clone in `repos.txt`.
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
