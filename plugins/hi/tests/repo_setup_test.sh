#!/usr/bin/env bash
# lib/repo-setup.sh — mode, status rows, guard, delegate path, scaffold.
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
RS="$LIB/repo-setup.sh"

# row <status-output> <name> → state;  detail <status-output> <name> → detail
row()    { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1==n{print $2; exit}'; }
detail() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1==n{print $3; exit}'; }

# mkrepo <dir> <origin-url>: a repo with one commit and an origin remote.
mkrepo() {
  mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init \
    && git -C "$1" remote add origin "$2"
}
WORK="$SANDBOX/work"; mkrepo "$WORK" git@github.com:workorg/app.git
MINE="$SANDBOX/mine"; mkrepo "$MINE" git@github.com:me/tool.git
WORK=$(cd "$WORK" && pwd -P); MINE=$(cd "$MINE" && pwd -P)

# --- usage and repo detection ------------------------------------------------
bash "$RS" bogus >/dev/null 2>&1; assert_status "unknown verb exits 2" 2 "$?"
(cd "$SANDBOX" && bash "$RS" mode >/dev/null 2>&1); assert_status "outside a repo exits 3" 3 "$?"

# --- mode ----------------------------------------------------------------------
out=$(cd "$MINE" && bash "$RS" mode); assert_eq "mode: unset → local" "local" "$out"
out=$(cd "$MINE" && bash "$RS" status | head -1)
assert_eq "mode row: says it is unset" "$(printf 'mode\tlocal\trepo_setup.mode unset')" "$out"

mkdir -p "$XDG_CONFIG_HOME/highness"
printf '{"repo_setup":{"mode":"commit"}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
out=$(cd "$MINE" && bash "$RS" mode); assert_eq "mode: the user file says commit" "commit" "$out"

mkdir -p "$WORK/.claude"; printf '{"repo_setup":{"mode":"lcoal"}}\n' > "$WORK/.claude/highness.json"
out=$(cd "$WORK" && bash "$RS" mode 2>"$SANDBOX/err"); assert_eq "mode: unknown value → local" "local" "$out"
assert_contains "mode: unknown value warns" "$(cat "$SANDBOX/err")" "lcoal"

# The repo's own file wins over the user file; committed, so the repo stays clean.
printf '{"repo_setup":{"mode":"local"}}\n' > "$WORK/.claude/highness.json"
git -C "$WORK" add .claude/highness.json && git -C "$WORK" commit -q -m cfg
out=$(cd "$WORK" && bash "$RS" mode); assert_eq "mode: the repo file wins over the user file" "local" "$out"
out=$(HIGHNESS_CONFIG="$SANDBOX/none.json" bash -c "cd '$MINE' && bash '$RS' mode")
assert_eq "mode: HIGHNESS_CONFIG names the user file" "local" "$out"

# --- status: gortex -----------------------------------------------------------
FAKE="$SANDBOX/fakegortex"
cat > "$FAKE" <<'SH'
#!/usr/bin/env bash
case "$1" in
  daemon) exit "${FAKE_UP:-0}" ;;
  repos)  [ -n "${FAKE_REPOS_FAIL:-}" ] && exit 1; printf '%s\n' "${FAKE_REPOS_JSON:-[]}" ;;
esac
SH
chmod +x "$FAKE"
st() { (cd "$1" && HI_GORTEX="${G:-$FAKE}" bash "$RS" status); }

out=$(G="$SANDBOX/no-such-gortex" st "$MINE"); assert_eq "gortex: no binary → absent" "absent" "$(row "$out" gortex)"
out=$(FAKE_UP=1 st "$MINE");                   assert_eq "gortex: daemon down → down" "down" "$(row "$out" gortex)"
out=$(FAKE_REPOS_FAIL=1 st "$MINE");           assert_eq "gortex: repos --json fails → down" "down" "$(row "$out" gortex)"
out=$(FAKE_REPOS_JSON='[{"path":"/elsewhere","indexed":true,"stale":false}]' st "$MINE")
assert_eq "gortex: not listed → untracked" "untracked" "$(row "$out" gortex)"
out=$(FAKE_REPOS_JSON="[{\"path\":\"$MINE\",\"indexed\":true,\"stale\":false}]" st "$MINE")
assert_eq "gortex: listed → tracked" "tracked" "$(row "$out" gortex)"
assert_eq "gortex: detail indexed" "indexed" "$(detail "$out" gortex)"
out=$(FAKE_REPOS_JSON="[{\"path\":\"$MINE\",\"indexed\":true,\"stale\":true}]" st "$MINE")
assert_eq "gortex: detail stale" "stale" "$(detail "$out" gortex)"
assert_eq "status: first row is mode" "mode" "$(printf '%s\n' "$out" | head -1 | cut -f1)"

# --- status: wiring -----------------------------------------------------------
out=$(st "$MINE"); assert_eq "wiring: nothing anywhere → missing" "missing" "$(row "$out" wiring)"
printf '{"mcpServers":{"gortex":{"command":"gortex"}}}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
out=$(st "$MINE"); assert_eq "wiring: user config → machine" "machine" "$(row "$out" wiring)"
out=$(env -u CLAUDE_CONFIG_DIR bash -c "cd '$MINE' && HI_GORTEX='$FAKE' bash '$RS' status")
assert_eq "wiring: ~/.claude/.claude.json with the config dir unset is never read → missing" "missing" "$(row "$out" wiring)"
printf '{"mcpServers":{"gortex":{"command":"gortex"}}}\n' > "$HOME/.claude.json"
out=$(env -u CLAUDE_CONFIG_DIR bash -c "cd '$MINE' && HI_GORTEX='$FAKE' bash '$RS' status")
assert_eq "wiring: ~/.claude.json with the config dir unset → machine" "machine" "$(row "$out" wiring)"
rm -f "$HOME/.claude.json"
printf '{"mcpServers":{"gortex":{"command":"gortex"}}}\n' > "$MINE/.mcp.json"
out=$(st "$MINE"); assert_eq "wiring: repo .mcp.json → repo" "repo" "$(row "$out" wiring)"
rm -f "$MINE/.mcp.json"

# --- status: checker / ann ----------------------------------------------------
out=$(st "$MINE")
assert_eq "checker: no Python → n/a" "n/a" "$(row "$out" checker)"
assert_eq "ann: no Python → n/a"     "n/a" "$(row "$out" ann)"

PY="$SANDBOX/py"; mkrepo "$PY" git@github.com:me/py.git
pp() { printf '%s\n' "$1" > "$PY/pyproject.toml"; }
pp '[project]
dependencies = ["django-stubs[compatible-mypy]==6.0.3", "mypy-baseline==0.7.4"]'
out=$(st "$PY")
assert_eq "checker: names inside other deps do not count" "none" "$(row "$out" checker)"
assert_eq "ann: no ruff → off" "off" "$(row "$out" ann)"
assert_eq "ann: no ruff detail" "no ruff" "$(detail "$out" ann)"

pp '[project]
dependencies = ["mypy==1.20.2", "basedpyright==1.39.9"]
[tool.ruff.lint]
select = ["E", "ANN"]'
out=$(st "$PY")
assert_eq "checker: real deps → ok" "ok" "$(row "$out" checker)"
assert_eq "checker: both listed, basedpyright is not pyright" "mypy,basedpyright" "$(detail "$out" checker)"
assert_eq "ann: ANN selected → on" "on" "$(row "$out" ann)"

pp '[tool.ty]
[tool.ruff]
select = ["E"]
[tool.other]
select = ["ANN"]'
out=$(st "$PY")
assert_eq "checker: [tool.ty] section → ty" "ty" "$(detail "$out" checker)"
assert_eq "ann: ANN only in another tool's table → off" "off" "$(row "$out" ann)"

pp '[tool.ruff]
lint.select = [ "ALL" ]
lint.ignore = [
  "A004",
  "ANN",
  # a comment ]
  "ARG001",
]'
out=$(st "$PY")
assert_eq "ann: ALL selected but ANN ignored → off" "off" "$(row "$out" ann)"
assert_eq "ann: ignored detail" "ANN ignored" "$(detail "$out" ann)"
pp '[tool.ruff.lint]
extend-select = ["ANN"]
ignore = ["ANN401"]'
out=$(st "$PY")
assert_eq "ann: one ANN rule ignored, ANN extend-selected → on" "on" "$(row "$out" ann)"
pp '[tool.ruff.lint]
select = ["E"]
ignore = ["E501"]
[tool.ruff.lint.per-file-ignores]
"x.py" = ["ANN"]'
out=$(st "$PY")
assert_eq "ann: ANN only in per-file-ignores, not selected → off" "off" "$(row "$out" ann)"

rm -f "$PY/pyproject.toml"
printf 'mypy==1.0\n' > "$PY/requirements.txt"
printf 'select = ["ALL"]\n' > "$PY/ruff.toml"
out=$(st "$PY")
assert_eq "checker: requirements.txt counts" "mypy" "$(detail "$out" checker)"
assert_eq "ann: ruff.toml ALL → on" "on" "$(row "$out" ann)"

# --- status: launcher -------------------------------------------------------------
out=$(st "$MINE"); assert_eq "launcher: none yet → missing" "missing" "$(row "$out" launcher)"
CLAUDE_PLUGIN_ROOT="$LIB/.." bash "$LIB/install-launcher.sh"
out=$(st "$MINE"); assert_eq "launcher: installed → ok" "ok" "$(row "$out" launcher)"
assert_contains "launcher: detail names the target" "$(detail "$out" launcher)" "/bin/highness"
mkdir -p "$SANDBOX/gone"; cp -R "$LIB/.." "$SANDBOX/gone/hi"
CLAUDE_PLUGIN_ROOT="$SANDBOX/gone/hi" bash "$LIB/install-launcher.sh"; rm -rf "$SANDBOX/gone"
out=$(st "$MINE"); assert_eq "launcher: its plugin version gone → stale" "stale" "$(row "$out" launcher)"
printf '#!/bin/sh\n' > "$HOME/.local/bin/highness"
out=$(st "$MINE"); assert_eq "launcher: someone else's file → foreign" "foreign" "$(row "$out" launcher)"
rm -f "$HOME/.local/bin/highness"

# --- status: orca.yaml and the Orca hooks ------------------------------------------
out=$(st "$MINE")
assert_eq "orca: no data file → ABSENT" "ABSENT" "$(row "$out" orca-setup)"
assert_eq "orca: no data file detail" "no Orca data file" "$(detail "$out" orca-archive)"
assert_eq "orca-yaml: no file → none" "none" "$(row "$out" orca-yaml)"

ODIR="$SANDBOX/orca"; mkdir -p "$ODIR"
# hooks <file> <setup> <archive> [<policy>]: an Orca data file whose me/tool entry has those values.
hooks() {
  jq -n --arg s "$2" --arg a "$3" --arg p "${4:-}" '{ projectHostSetups: [ { projectId: "github:me/tool", path: "/x",
    hookSettings: ({ scripts: { setup: $s, archive: $a } } + (if $p == "" then {} else { commandSourcePolicy: $p } end)) } ] }' > "$1"
}
PREF_S='"$HOME/.local/bin/highness" worktree-setup || true'
PREF_A='"$HOME/.local/bin/highness" worktree-teardown || true'
hooks "$ODIR/win.json" "$PREF_S" "$PREF_A"
cat > "$ODIR/wsl.json" <<'JSON'
{ "projectHostSetups": [ { "projectId": "github:me/other", "path": "/x",
  "hookSettings": { "scripts": { "setup": "x" } } } ] }
JSON
ost() { (cd "$MINE" && HI_GORTEX="$FAKE" HI_ORCA_DATA="$1" bash "$RS" status); }
out=$(ost "$ODIR/wsl.json
$ODIR/win.json")
assert_eq "orca: the install that knows the repo wins" "WIRED" "$(row "$out" orca-setup)"
assert_eq "orca: archive WIRED too" "WIRED" "$(row "$out" orca-archive)"
assert_contains "orca: detail names the file" "$(detail "$out" orca-setup)" "@ $ODIR/win.json"
assert_contains "orca: no orca.yaml, a local hook: it runs" "$(detail "$out" orca-setup)" "via the local hook"

hooks "$ODIR/acc.json" 'wt-setup' ''
out=$(ost "$ODIR/acc.json")
assert_eq "orca: another script → CONFLICT" "CONFLICT" "$(row "$out" orca-setup)"
assert_eq "orca: empty slot → UNWIRED" "UNWIRED" "$(row "$out" orca-archive)"
mkdir -p "$XDG_CONFIG_HOME/highness"
printf '{"repo_setup":{"mode":"commit","accept":{"setup":["wt-setup"]}}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
out=$(ost "$ODIR/acc.json")
assert_eq "orca: a form the config accepts → LEGACY" "LEGACY" "$(row "$out" orca-setup)"
printf '{"repo_setup":{"mode":"commit"}}\n' > "$XDG_CONFIG_HOME/highness/config.json"

# the committed recipe
cat > "$MINE/orca.yaml" <<'YAML'
# Orca worktree hooks, run through the hi plugin's launcher
scripts:
  setup: '"$HOME/.local/bin/highness" worktree-setup || true'
  archive: |
    "$HOME/.local/bin/highness" worktree-teardown || true
YAML
git -C "$MINE" add orca.yaml && git -C "$MINE" commit -q -m hooks
hooks "$ODIR/none.json" '' ''
out=$(ost "$ODIR/none.json")
assert_eq "orca-yaml: both slots → wired" "wired" "$(row "$out" orca-yaml)"
assert_contains "orca-yaml: committed" "$(detail "$out" orca-yaml)" "committed"
assert_eq "orca: orca.yaml, no local hook → WIRED" "WIRED" "$(row "$out" orca-setup)"
assert_contains "orca: … via orca.yaml" "$(detail "$out" orca-setup)" "via orca.yaml (policy unset → shared-only)"
assert_eq "orca: the archive slot too" "WIRED" "$(row "$out" orca-archive)"

hooks "$ODIR/shadow.json" 'my-own-setup' ''
out=$(ost "$ODIR/shadow.json")
assert_eq "orca: a local script with no policy shadows orca.yaml" "SHADOWED" "$(row "$out" orca-setup)"
assert_contains "orca: … says so" "$(detail "$out" orca-setup)" "policy unset → local-only runs only the local hook [my-own-setup]"
assert_eq "orca: the other slot still runs orca.yaml" "WIRED" "$(row "$out" orca-archive)"
hooks "$ODIR/both.json" 'my-own-setup' '' run-both
out=$(ost "$ODIR/both.json")
assert_eq "orca: run-both runs orca.yaml as well" "WIRED" "$(row "$out" orca-setup)"
assert_contains "orca: … and names the local one" "$(detail "$out" orca-setup)" "the local hook also runs [my-own-setup]"
hooks "$ODIR/twice.json" "$PREF_S" "$PREF_A" run-both
out=$(ost "$ODIR/twice.json")
assert_eq "orca: run-both with highness in both → TWICE" "TWICE" "$(row "$out" orca-setup)"
hooks "$ODIR/local.json" "$PREF_S" "$PREF_A" local-only
out=$(ost "$ODIR/local.json")
assert_eq "orca: local-only with the local hook → WIRED" "WIRED" "$(row "$out" orca-setup)"
hooks "$ODIR/shared.json" 'my-own-setup' '' shared-only
out=$(ost "$ODIR/shared.json")
assert_eq "orca: shared-only ignores the local script" "WIRED" "$(row "$out" orca-setup)"
out=$(ost "$ODIR/wsl.json")
assert_eq "orca: Orca does not list the repo → ABSENT" "ABSENT" "$(row "$out" orca-setup)"
assert_contains "orca: … but orca.yaml is wired" "$(detail "$out" orca-setup)" "orca.yaml is wired"

printf 'scripts:\n  setup: make setup\n' > "$MINE/orca.yaml"
out=$(ost "$ODIR/none.json")
assert_eq "orca-yaml: other commands → other" "other" "$(row "$out" orca-yaml)"
assert_eq "orca: orca.yaml runs something else → CONFLICT" "CONFLICT" "$(row "$out" orca-setup)"
printf 'scripts:\n  setup: "\\"$HOME/.local/bin/highness\\" worktree-setup"\n' > "$MINE/orca.yaml"
out=$(ost "$ODIR/none.json")
assert_eq "orca-yaml: one slot → partial" "partial" "$(row "$out" orca-yaml)"
printf 'defaultTabs: []\n' > "$MINE/orca.yaml"
assert_eq "orca-yaml: no scripts → unwired" "unwired" "$(row "$(ost "$ODIR/none.json")" orca-yaml)"
printf 'scripts: { setup: x }\n' > "$MINE/orca.yaml"
assert_contains "orca-yaml: flow style is said, not misread" "$(detail "$(ost "$ODIR/none.json")" orca-yaml)" "flow style"
git -C "$MINE" rm -q -f orca.yaml && git -C "$MINE" commit -q -m drop

# --- guard (local mode: WORK's own config says local) --------------------------
printf 'x\n' > "$WORK/tracked.txt"; printf '.cache/\nignored.txt\n' > "$WORK/.gitignore"
git -C "$WORK" add tracked.txt .gitignore && git -C "$WORK" commit -q -m files
g() { (cd "${2:-$WORK}" && bash "$RS" guard "$1" 2>"$SANDBOX/gerr"); }
g tracked.txt;          assert_status "guard: tracked file refused" 1 "$?"
assert_contains "guard: says why" "$(cat "$SANDBOX/gerr")" "tracked"
g new.txt;              assert_status "guard: untracked, not ignored → refused" 1 "$?"
g ignored.txt;          assert_status "guard: ignored file allowed" 0 "$?"
g .cache/a/b/c.txt;     assert_status "guard: missing parents under an ignored dir → allowed" 0 "$?"
g .git/hi/worktree-setup.sh; assert_status "guard: under the git common dir → allowed" 0 "$?"
g "$SANDBOX/outside.txt"; assert_status "guard: outside the repo → allowed" 0 "$?"
mkdir -p "$WORK/sub"
g ../tracked.txt "$WORK/sub"; assert_status "guard: relative path from a subdir resolves" 1 "$?"
(cd "$MINE" && bash "$RS" guard anything.txt >/dev/null 2>&1)
assert_status "guard: commit mode allows anything" 0 "$?"
(cd "$WORK" && bash "$RS" guard >/dev/null 2>&1); assert_status "guard: no path → 2" 2 "$?"

# --- linked worktree: same shared local path -------------------------------------
git -C "$WORK" worktree add -q "$SANDBOX/work-wt" -b feat >/dev/null 2>&1
WT=$(cd "$SANDBOX/work-wt" && pwd -P)
out=$(cd "$WT" && bash "$RS" delegate-path)
assert_eq "delegate-path: a worktree gets the main checkout's shared path" "$WORK/.git/hi/worktree-setup.sh" "$out"
(cd "$WT" && bash "$RS" guard "$WORK/.git/hi/worktree-setup.sh" 2>/dev/null)
assert_status "guard: from a worktree, the shared common dir is allowed" 0 "$?"
(cd "$WT" && bash "$RS" guard tracked.txt 2>/dev/null)
assert_status "guard: from a worktree, a tracked file is refused" 1 "$?"

# --- guard: the review's bypasses --------------------------------------------------
(cd "$WT" && bash "$RS" guard "$WORK/tracked.txt" 2>/dev/null)
assert_status "guard: from a worktree, the main checkout's tracked file is refused" 1 "$?"
(cd "$WORK" && bash "$RS" guard "$WT/tracked.txt" 2>/dev/null)
assert_status "guard: from main, a sibling worktree's tracked file is refused" 1 "$?"
(cd "$WT" && bash "$RS" guard "$WORK/ignored.txt" 2>/dev/null)
assert_status "guard: from a worktree, main's ignored file is allowed" 0 "$?"
g .git/nope/../../tracked.txt; assert_status "guard: .. under a missing dir → refused" 1 "$?"
g "$SANDBOX/nope/../work/tracked.txt"; assert_status "guard: .. outside, landing on a tracked file → refused" 1 "$?"
ln -s tracked.txt "$WORK/ignored.txt"
g ignored.txt; assert_status "guard: an ignored symlink to a tracked file → refused" 1 "$?"
rm -f "$WORK/ignored.txt"

# --- delegate-path / scaffold ------------------------------------------------------
out=$(cd "$MINE" && bash "$RS" delegate-path)
assert_eq "delegate-path: commit mode → .orca" "$MINE/.orca/worktree-setup.sh" "$out"
out=$(cd "$WORK" && bash "$RS" scaffold-delegate); rc=$?
assert_status "scaffold: local mode creates it" 0 "$rc"
assert_eq "scaffold: prints the path" "$WORK/.git/hi/worktree-setup.sh" "$out"
assert_eq "scaffold: executable" "yes" "$([ -x "$WORK/.git/hi/worktree-setup.sh" ] && echo yes || echo no)"
assert_eq "scaffold: content is the template" "" "$(diff "$WORK/.git/hi/worktree-setup.sh" "$LIB/../reference/worktree-setup.template.sh")"
printf '# mine\n' >> "$WORK/.git/hi/worktree-setup.sh"; before=$(cat "$WORK/.git/hi/worktree-setup.sh")
out=$(cd "$WORK" && bash "$RS" scaffold-delegate 2>&1); rc=$?
assert_status "scaffold: existing file → exit 1" 1 "$rc"
assert_contains "scaffold: shows the diff" "$out" "# mine"
assert_eq "scaffold: existing file untouched" "$before" "$(cat "$WORK/.git/hi/worktree-setup.sh")"
assert_eq "scaffold: nothing new in git status" "" "$(git -C "$WORK" status --porcelain)"

# --- status: delegate --------------------------------------------------------------
out=$(st "$WORK"); assert_eq "delegate: local only" "local" "$(row "$out" delegate)"
mkdir -p "$WORK/docker"; printf '#!/usr/bin/env bash\n' > "$WORK/docker/worktree-setup.sh"; chmod +x "$WORK/docker/worktree-setup.sh"
out=$(st "$WORK"); assert_eq "delegate: executable but untracked is not committed" "local" "$(row "$out" delegate)"
git -C "$WORK" add docker/worktree-setup.sh && git -C "$WORK" commit -q -m d
out=$(st "$WORK"); assert_eq "delegate: committed + local → both" "both" "$(row "$out" delegate)"
assert_contains "delegate: detail names the committed one" "$(detail "$out" delegate)" "docker/worktree-setup.sh"
out=$(st "$MINE"); assert_eq "delegate: none" "none" "$(row "$out" delegate)"

mkdir -p "$MINE/.git/us"; printf '#!/usr/bin/env bash\n' > "$MINE/.git/us/worktree-setup.sh"; chmod +x "$MINE/.git/us/worktree-setup.sh"
out=$(st "$MINE"); assert_eq "delegate: an older us/ delegate counts as local" "local" "$(row "$out" delegate)"
assert_contains "delegate: detail names it" "$(detail "$out" delegate)" ".git/us/worktree-setup.sh"
rm -rf "$MINE/.git/us"

# --- status: board (#23) -----------------------------------------------------------
printf 'todo\tTodo\nin-progress\tIn progress\nin-review\tIn review\ncompleted\tDone\n' > "$SANDBOX/defaults.tsv"
out=$(HI_ORCA_BOARD="$SANDBOX/defaults.tsv" st "$MINE")
assert_eq "board: Orca's default columns → missing" "missing" "$(row "$out" board)"
assert_eq "board: names the five labels to add" "Mains, QA, Review queue, Waiting author, Needs me" "$(detail "$out" board)"
printf 'a\tMains\nb\tIn progress\nc\tIn review\nd\tQA\ne\tDone\nf\tReview queue\ng\tWaiting author\nh\tNeeds me\n' > "$SANDBOX/full.tsv"
out=$(HI_ORCA_BOARD="$SANDBOX/full.tsv" st "$MINE"); assert_eq "board: every column → ok" "ok" "$(row "$out" board)"
out=$(HI_ORCA_STATE_DB="$SANDBOX/none.db" st "$MINE")
assert_eq "board: an unreadable set → unknown, never all missing" "unknown" "$(row "$out" board)"

# --- launcher / board alone, outside any repo (for /hi:setup) -----------------------
out=$(cd "$SANDBOX" && HI_ORCA_BOARD="$SANDBOX/defaults.tsv" bash "$RS" board); rc=$?
assert_status "board verb: no repo needed" 0 "$rc"
assert_eq "board verb: the row" "$(printf 'board\tmissing\tMains, QA, Review queue, Waiting author, Needs me')" "$out"
out=$(cd "$SANDBOX" && bash "$RS" launcher); assert_eq "launcher verb: no repo needed" "launcher" "$(printf '%s' "$out" | cut -f1)"

assert_summary
