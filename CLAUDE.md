# highness

Public Claude Code plugin marketplace: `hi` (workspaces), `hi-guard` (Bash guard), `hi-docs` (writing), `hi-crew` (ticket workers on Orca).

- Everything here is generic and public: no owner, company, host or private-path names.
  `tests/conventions_test.sh` enforces it.
- Each plugin is self-contained (installed on its own); `lib/config.sh` in each is a copy of
  `shared/config.sh` — edit the shared one and copy it (`tests/config_copies_test.sh`).
- bash 3.2 is the floor; BSD awk/sed (macOS) must work.
- Run `bash tests/run.sh </dev/null` before landing on `main`. Land by fast-forward.
- Bump `version` in `plugins/hi/.claude-plugin/plugin.json` with every change to `hi`: `main` reaches installs as soon as it moves (teams follow it unpinned), and `claude plugin update` skips a plugin whose version did not change. `hi-docs`, `hi-guard` and `hi-crew` declare no version, so they update by commit.
- No `Co-Authored-By` trailer on commits. English everywhere.
