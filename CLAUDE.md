# highness

Public Claude Code plugin marketplace: `hi` (workspaces), `hi-guard` (Bash guard), `hi-docs` (writing), `hi-crew` (ticket workers on Orca), `hi-threads` (a journal of work threads across sessions), `hi-review` (pull request reviews).

- Everything here is generic and public: no owner, company, host or private-path names.
  `tests/conventions_test.sh` enforces it.
- Layering: highness stays generic. A team keeps its process text, tracker config (`tracker`:
  instance URL, projects, statuses, transitions, fields) and team-only hooks in its own private
  repo or plugin, installed beside highness. Its settings reach highness only through the config
  `lib/config.sh` reads: the repo's committed `.claude/highness.json`, or a `repos.<owner>` block in
  each person's file for a repo that cannot carry one. Credentials stay in the person's own file
  (`trackers.<host>`), never in a repo. Test for new code: would another team or a personal repo
  use it unchanged? Then it belongs here; if it names a team, its tracker or its rules, it does not.
- Each plugin is self-contained (installed on its own); `lib/config.sh` in each is a copy of
  `shared/config.sh` — edit the shared one and copy it (`tests/config_copies_test.sh`).
- bash 3.2 is the floor; BSD awk/sed (macOS) must work.
- Run `bash tests/run.sh </dev/null` before landing on `main`. Land by fast-forward.
- Bump `version` in `plugins/hi/.claude-plugin/plugin.json` with every change to `hi`: `main` reaches installs as soon as it moves (teams follow it unpinned), and `claude plugin update` skips a plugin whose version did not change. `hi-docs`, `hi-guard`, `hi-crew`, `hi-threads` and `hi-review` declare no version, so they update by commit.
- No `Co-Authored-By` trailer on commits. English everywhere.
