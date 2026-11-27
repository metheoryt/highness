#!/usr/bin/env bash
# lib/setup.sh — the /hi:setup rows: machine, person, repo (#25, #23).
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
S="$LIB/setup.sh"
CREW_ROOT=$(cd "$HERE/../../hi-crew" && pwd -P)
command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

# row <out> <section> <name> → state;  detail <out> <section> <name> → detail
row()    { printf '%s\n' "$1" | awk -F'\t' -v s="$2" -v n="$3" '$1==s && $2==n {print $3; exit}'; }
detail() { printf '%s\n' "$1" | awk -F'\t' -v s="$2" -v n="$3" '$1==s && $2==n {print $4; exit}'; }

# A fake Orca: ready 1.4.254, one Claude account, the repos in $FAKE_REPOS, orchestration on.
FAKE_ORCA="$SHIM/fake-orca"
cat > "$FAKE_ORCA" <<'SH'
#!/bin/sh
case "$1 $2" in
  "status --json") echo '{"ok":true,"result":{"runtime":{"state":"ready","reachable":true,"appVersion":"1.4.254"}}}' ;;
  "repo list") printf '{"ok":true,"result":{"repos":%s}}\n' "${FAKE_REPOS:-[]}" ;;
  "account list") printf '{"ok":true,"result":{"claude":{"activeAccountId":%s}}}\n' "${FAKE_ACCOUNT:-null}" ;;
  "orchestration run-list") echo '{"ok":true,"result":{"runs":[]}}' ;;
  "skills installed") echo '{"ok":true,"result":{"skills":[{"name":"orchestration"}]}}' ;;
  "automations list") echo '{"ok":true,"result":{"automations":[]}}' ;;
  *) echo '{"ok":false}'; exit 1 ;;
esac
SH
# A fake claude: `plugin list --json` prints the profile's own fake-plugins.json when it has one,
# else $FAKE_PLUGINS, and logs each profile it was asked about.
FAKE_CLAUDE="$SHIM/fake-claude"
cat > "$FAKE_CLAUDE" <<SH
#!/bin/sh
printf '%s\n' "\$CLAUDE_CONFIG_DIR" >> "$SANDBOX/claude-profile"
[ "\$1 \$2 \$3" = "plugin list --json" ] || exit 1
if [ -f "\$CLAUDE_CONFIG_DIR/fake-plugins.json" ]; then cat "\$CLAUDE_CONFIG_DIR/fake-plugins.json"
else printf '%s\n' "\${FAKE_PLUGINS:-[]}"; fi
SH
chmod +x "$FAKE_ORCA" "$FAKE_CLAUDE"
export HI_ORCA="$FAKE_ORCA" HI_CLAUDE="$FAKE_CLAUDE"
printf 'todo\tTodo\nin-progress\tIn progress\nin-review\tIn review\ncompleted\tDone\n' > "$SANDBOX/defaults.tsv"
export HI_ORCA_BOARD="$SANDBOX/defaults.tsv"

plugins() { # <name>@<market>:<scope>[:<projectPath>] … → a plugin list
  local a out='' id sc pp
  for a in "$@"; do
    id=${a%%:*}; sc=${a#*:}; pp=''; case "$sc" in *:*) pp=${sc#*:}; sc=${sc%%:*} ;; esac
    out="$out$(jq -nc --arg id "$id" --arg sc "$sc" --arg pp "$pp" --arg ip "$CREW_ROOT" \
      '{id: $id, scope: $sc, enabled: true, installPath: (if ($id | startswith("hi-crew@")) then $ip else "/x" end)}
       + (if $pp != "" then {projectPath: $pp} else {} end)'),"
  done
  printf '[%s]' "${out%,}"
}

# --- usage ---------------------------------------------------------------------------------
bash "$S" bogus >/dev/null 2>&1; assert_status "unknown verb exits 2" 2 "$?"

# --- outside a repo: machine and person only ------------------------------------------------
out=$(cd "$SANDBOX" && FAKE_PLUGINS="$(plugins hi@highness:user)" bash "$S" status); rc=$?
assert_status "status: exit 0 outside a repo" 0 "$rc"
assert_eq "no repo section outside a repo" "0" "$(printf '%s\n' "$out" | grep -c '^repo	')"
assert_eq "jq: ok" ok "$(row "$out" machine jq)"
assert_eq "orca: ok" ok "$(row "$out" machine orca)"
assert_contains "orca: the version" "$(detail "$out" machine orca)" 1.4.254
assert_eq "account-switch: no Orca database reads unknown" unknown "$(row "$out" machine account-switch)"

# Orca's account-switch setting: only Never restart keeps workers' Dispatch (highness#106).
DB="$SANDBOX/state.db"
py_sqlite || skip 'account-switch from a database: no python3 with its sqlite3 module'
for pair in keep:ok restart:restarts ask:restarts; do
  py_sqlite || break
  python3 -I - "$DB" "${pair%%:*}" <<'PY'
import sqlite3, sys, json
con = sqlite3.connect(sys.argv[1])
con.execute("create table if not exists profile_state_documents (domain text primary key, payload text)")
con.execute("insert or replace into profile_state_documents values ('settings', ?)",
            (json.dumps({"claudeAccountSwitchRunningSessions": sys.argv[2]}),))
con.commit()
PY
  o=$(cd "$SANDBOX" && HI_ORCA_STATE_DB="$DB" FAKE_PLUGINS="$(plugins hi@highness:user)" bash "$S" status)
  assert_eq "account-switch: ${pair%%:*} reads ${pair#*:}" "${pair#*:}" "$(row "$o" machine account-switch)"
done
assert_eq "launcher: from repo-setup" missing "$(row "$out" machine launcher)"
assert_eq "plugin:hi on" on "$(row "$out" machine plugin:hi)"
assert_eq "plugin:hi-guard off" off "$(row "$out" machine plugin:hi-guard)"
assert_eq "plugin:hi-crew off" off "$(row "$out" machine plugin:hi-crew)"
assert_eq "hi-crew off → no crew rows" off "$(row "$out" machine hi-crew)"
assert_eq "hi-crew off → no orchestration row" "" "$(row "$out" machine orchestration)"
assert_eq "board: the missing hi column" missing "$(row "$out" machine board)"
assert_eq "board: detail" "Review queue" "$(detail "$out" machine board)"
assert_eq "config: none" none "$(row "$out" person config)"
assert_eq "no overlay row outside a repo" "" "$(row "$out" person overlay)"

# --- the worker profile: Orca's active Claude account, else ~/.claude ------------------------
out=$(cd "$SANDBOX" && bash "$S" profile)
assert_eq "profile: no Orca account → ~/.claude" "$HOME/.claude" "$(printf '%s' "$out" | cut -f1)"
P="$HOME/Library/Application Support/orca/claude-profiles/acc-1/home"; mkdir -p "$P"
out=$(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" profile)
assert_eq "profile: Orca's active account's dir" "$P" "$(printf '%s' "$out" | cut -f1)"
rm -f "$SANDBOX/claude-profile"
(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" status >/dev/null)
assert_eq "plugins are listed for the worker profile" "$P" "$(head -1 "$SANDBOX/claude-profile")"
out=$(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" status)
assert_contains "plugin rows name the profile" "$(detail "$out" machine plugin:hi)" "$P"
out=$(cd "$SANDBOX" && HI_CLAUDE_PROFILE=/elsewhere bash "$S" profile | cut -f1)
assert_eq "profile: HI_CLAUDE_PROFILE wins" /elsewhere "$out"
out=$(cd "$SANDBOX" && HI_CLAUDE="$SANDBOX/no-claude" bash "$S" status)
assert_eq "plugins: no claude → unknown" unknown "$(row "$out" machine plugins)"

# --- every highness plugin is checked: the list is the marketplace's (#60) ------------------
MKT=$(cd "$HERE/../../.." && pwd -P)/.claude-plugin/marketplace.json
want=$(jq -r '[.plugins[].name] | sort | join(" ")' "$MKT")
have=$(sed -n "s/^PLUGINS='\(.*\)'$/\1/p" "$S" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "setup.sh checks every plugin of the marketplace" "$want" "$have"
out=$(cd "$SANDBOX" && bash "$S" status)
assert_eq "plugin:hi-threads is checked" off "$(row "$out" machine plugin:hi-threads)"
assert_eq "plugin:hi-review is checked" off "$(row "$out" machine plugin:hi-review)"

# --- every Claude config dir Orca uses (#60) -------------------------------------------------
# The worker profile acc-1 (P, above), a second Orca profile home, and one more dir Orca observed.
ORCA_D="$HOME/Library/Application Support/orca"
P2="$ORCA_D/claude-profiles/acc-2/home"; OBS="$SANDBOX/observed"; mkdir -p "$P2" "$OBS"
printf '["%s", "%s"]\n' "$OBS" "$P" > "$ORCA_D/claude-observed-config-dirs.json"
plugins hi@highness:user hi-crew@highness:user hi-guard@highness:user hi-threads@highness:user > "$P/fake-plugins.json"
# acc-2 lacks hi-guard and hi-threads; the observed dir loads hi twice (a link and the marketplace).
plugins hi@highness:user hi-crew@highness:user > "$P2/fake-plugins.json"
mkdir -p "$SANDBOX/wc/hi" "$OBS/skills"; ln -s "$SANDBOX/wc/hi" "$OBS/skills/hi"
jq -c --arg ip "$OBS/skills/hi" '. + [{id: "hi@skills-dir", scope: "user", enabled: true, installPath: $ip}]' \
  "$P/fake-plugins.json" > "$OBS/fake-plugins.json"
out=$(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" status)
assert_eq "worker profile: hi once → on" on "$(row "$out" machine plugin:hi)"
assert_contains "worker profile: names the marketplace source" "$(detail "$out" machine plugin:hi)" "marketplace highness"
assert_eq "the worker profile has no profile: row" "" "$(row "$out" machine "profile:$P")"
assert_eq "a profile missing plugins → gaps" gaps "$(row "$out" machine "profile:$P2")"
assert_contains "gaps: names the missing plugins" "$(detail "$out" machine "profile:$P2")" "off: hi-guard, hi-threads"
assert_not_contains "gaps: not a plugin the worker lacks too" "$(detail "$out" machine "profile:$P2")" "hi-docs"
assert_eq "a double load → gaps" gaps "$(row "$out" machine "profile:$OBS")"
d=$(detail "$out" machine "profile:$OBS")
assert_contains "double: names the plugin" "$d" "double: hi twice"
assert_contains "double: names the link and its target" "$d" "hi@skills-dir (user, link → $SANDBOX/wc/hi)"
assert_contains "double: names the marketplace copy" "$d" "hi@highness (user, marketplace highness)"
assert_eq "each config dir is listed once" 1 "$(printf '%s\n' "$out" | grep -c "	profile:$OBS	")"
assert_eq "no stale pins → pins ok" ok "$(row "$out" machine pins)"

# The same double load in the worker profile itself.
cp "$OBS/fake-plugins.json" "$P/fake-plugins.json"
out=$(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" status)
assert_eq "worker profile: hi twice → double" double "$(row "$out" machine plugin:hi)"
assert_contains "double: both sources" "$(detail "$out" machine plugin:hi)" "link → $SANDBOX/wc/hi"

# Stale pins: a project pin of a highness plugin at a dir that is gone; acc-2 shares acc-1's
# plugins dir through a link (as Orca's profile homes do), so the pin is listed once.
LIVE="$SANDBOX/live-wt"; mkdir -p "$LIVE" "$P/plugins"; ln -s "$P/plugins" "$P2/plugins"
jq -n --arg gone "$SANDBOX/gone-wt" --arg live "$LIVE" '{version: 2, plugins: {
  "hi-crew@highness": [{scope: "user"}, {scope: "project", projectPath: $gone}],
  "hi@highness": [{scope: "project", projectPath: $live}],
  "other@elsewhere": [{scope: "project", projectPath: $gone}]}}' > "$P/plugins/installed_plugins.json"
out=$(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" status)
pins=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "machine" && $2 ~ /^pins/')
assert_eq "a stale pin: one row for the shared file" 1 "$(printf '%s\n' "$pins" | grep -c .)"
assert_eq "a stale pin → stale" stale "$(printf '%s\n' "$pins" | cut -f3)"
assert_contains "stale: names the plugin and the gone dir" "$(printf '%s\n' "$pins" | cut -f4)" "hi-crew@highness → $SANDBOX/gone-wt"
assert_not_contains "stale: not a pin whose dir exists" "$(printf '%s\n' "$pins" | cut -f4)" "$LIVE"
assert_not_contains "stale: not another marketplace's plugin" "$(printf '%s\n' "$pins" | cut -f4)" "other@"
assert_eq "a gone pin is stale, not drift" ok "$(row "$out" machine drift)"

# Drift (#128): a live project pin at another version than the user install of the same id.
L2="$SANDBOX/live-2"; L3="$SANDBOX/live-3"; mkdir -p "$L2" "$L3"
jq -n --arg gone "$SANDBOX/gone-wt" --arg live "$LIVE" --arg l2 "$L2" --arg l3 "$L3" '{version: 2, plugins: {
  "hi@highness": [{scope: "user", version: "0.1.22", gitCommitSha: "aaaaaaaaaa"},
                  {scope: "project", projectPath: $live, version: "0.1.20", gitCommitSha: "bbbbbbbbbb"},
                  {scope: "project", projectPath: $gone, version: "0.1.19"}],
  "hi-crew@highness": [{scope: "user", version: "1111111", gitCommitSha: "1111111abc"},
                       {scope: "local", projectPath: $l2, version: "1111111", gitCommitSha: "2222222def"}],
  "hi-guard@highness": [{scope: "user", version: "x", gitCommitSha: "c1"},
                        {scope: "project", projectPath: $l3, version: "x", gitCommitSha: "c1"}],
  "hi-docs@highness": [{scope: "project", projectPath: $l3, version: "0.0.1"}],
  "other@elsewhere": [{scope: "user", version: "2"}, {scope: "project", projectPath: $l3, version: "1"}]}}' \
  > "$P/plugins/installed_plugins.json"
out=$(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" status)
drift=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "machine" && $2 ~ /^drift/')
assert_eq "drift: one row for the shared file" 1 "$(printf '%s\n' "$drift" | grep -c .)"
assert_eq "drift: the row is named after the file" "drift:$P/plugins/installed_plugins.json" "$(printf '%s\n' "$drift" | cut -f2)"
assert_eq "drift: state" drift "$(printf '%s\n' "$drift" | cut -f3)"
d=$(printf '%s\n' "$drift" | cut -f4)
assert_contains "drift: another version, both sides named" "$d" "hi@highness: $LIVE at 0.1.20 (project) vs 0.1.22 (user)"
assert_contains "drift: same version, another commit" "$d" "hi-crew@highness: $L2 at 1111111 2222222 (local) vs 1111111 1111111 (user)"
assert_not_contains "drift: same version and commit is none" "$d" "hi-guard@"
assert_not_contains "drift: a pin with no user install is skipped" "$d" "hi-docs@"
assert_not_contains "drift: not another marketplace's plugin" "$d" "other@"
assert_not_contains "drift: not a gone pin" "$d" "gone-wt"
assert_eq "the gone pin is still stale" stale "$(printf '%s\n' "$out" | awk -F'\t' '$2 ~ /^pins:/ {print $3}')"
rm -rf "$P/fake-plugins.json" "$P/plugins" "$P2" "$OBS" "$ORCA_D/claude-observed-config-dirs.json"

# --- hi-crew enabled: its crew.sh adds the orchestration, watch and crew rows ----------------
out=$(cd "$SANDBOX" && FAKE_PLUGINS="$(plugins hi@skills-dir:user hi-crew@highness:user hi-guard@highness:user)" bash "$S" status)
assert_eq "a skills-dir copy counts as on" on "$(row "$out" machine plugin:hi)"
assert_eq "plugin:hi-crew on" on "$(row "$out" machine plugin:hi-crew)"
assert_eq "hi-crew: ok" ok "$(row "$out" machine hi-crew)"
assert_eq "hi-crew: names its crew.sh" "$CREW_ROOT/lib/crew.sh" "$(detail "$out" machine hi-crew)"
assert_eq "orchestration: from crew.sh" on "$(row "$out" machine orchestration)"
assert_eq "orca-skill: from crew.sh" ok "$(row "$out" machine orca-skill)"
assert_eq "watch: from crew.sh" missing "$(row "$out" machine watch)"
assert_eq "crew.model: in the person section" unset "$(row "$out" person crew.model)"
assert_eq "crew.agent: in the person section" unset "$(row "$out" person crew.agent)"
assert_eq "crew rows are not machine rows" "" "$(row "$out" machine crew.model)"
assert_eq "no preference file: the person row that offers /hi:meet" missing "$(row "$out" person preferences)"
assert_eq "preferences is not a machine row" "" "$(row "$out" machine preferences)"
assert_eq "session-state: this hi-crew registers its hooks" ok "$(row "$out" machine session-state)"

# An older hi-crew: a crew.sh with setup-status, but no session-state hooks.
OLD="$SANDBOX/old-crew"; mkdir -p "$OLD/lib" "$OLD/hooks"
cp -R "$CREW_ROOT/lib/"* "$OLD/lib/"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash prompt-mark.sh hook"}]}]}}\n' > "$OLD/hooks/hooks.json"
out=$(cd "$SANDBOX" && FAKE_PLUGINS="$(CREW_ROOT=$OLD plugins hi-crew@highness:user)" bash "$S" status)
assert_eq "session-state: an older hi-crew → old" old "$(row "$out" machine session-state)"

mkdir -p "$XDG_CONFIG_HOME/highness"
printf '{"crew":{"agent":"claude","model":null}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
out=$(cd "$SANDBOX" && FAKE_PLUGINS="$(plugins hi-crew@highness:user)" bash "$S" status)
assert_eq "config: ok" ok "$(row "$out" person config)"
assert_eq "crew.model null → default" default "$(row "$out" person crew.model)"
assert_eq "crew.agent set" set "$(row "$out" person crew.agent)"
assert_eq "session.language: unset" unset "$(row "$out" person session.language)"
printf '{"session":{"language":"Russian"}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
out=$(cd "$SANDBOX" && bash "$S" status)
assert_eq "session.language: set" set "$(row "$out" person session.language)"
assert_eq "session.language: the value" Russian "$(detail "$out" person session.language)"
printf '{"session":{"language":null}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
out=$(cd "$SANDBOX" && bash "$S" status)
assert_eq "session.language: null → default" default "$(row "$out" person session.language)"
printf '[1]\n' > "$XDG_CONFIG_HOME/highness/config.json"
out=$(cd "$SANDBOX" && bash "$S" status)
assert_eq "config: not an object → invalid" invalid "$(row "$out" person config)"
rm -f "$XDG_CONFIG_HOME/highness/config.json"

# A disabled or another project's plugin does not count.
out=$(cd "$SANDBOX" && FAKE_PLUGINS='[{"id":"hi-guard@highness","scope":"user","enabled":false},{"id":"hi-docs@highness","scope":"project","enabled":true,"projectPath":"/other"}]' bash "$S" status)
assert_eq "a disabled plugin is off" off "$(row "$out" machine plugin:hi-guard)"
assert_eq "another project's plugin is off" off "$(row "$out" machine plugin:hi-docs)"

# --- inside a repo: orca-project, then repo-setup's rows minus launcher and board ------------
R="$SANDBOX/app"; mkdir -p "$R" && git -C "$R" init -q && git -C "$R" commit -q --allow-empty -m i \
  && git -C "$R" remote add origin git@github.com:acme/app.git
R=$(cd "$R" && pwd -P)
out=$(cd "$R" && bash "$S" status)
assert_eq "orca-project: not registered → missing" missing "$(row "$out" repo orca-project)"
assert_contains "orca-project: names the path to add" "$(detail "$out" repo orca-project)" "$R"
assert_eq "repo-setup's rows come along" local "$(row "$out" repo mode)"
assert_eq "repo-setup's delegate row" none "$(row "$out" repo delegate)"
assert_eq "launcher is shown once" 1 "$(printf '%s\n' "$out" | awk -F'\t' '$2 == "launcher"' | grep -c .)"
assert_eq "board is shown once" 1 "$(printf '%s\n' "$out" | awk -F'\t' '$2 == "board"' | grep -c .)"
assert_eq "overlay: none" none "$(row "$out" person overlay)"
out=$(cd "$R" && FAKE_REPOS="[{\"id\":\"r1\",\"path\":\"$R\"}]" bash "$S" status)
assert_eq "orca-project: registered → ok" ok "$(row "$out" repo orca-project)"
assert_contains "orca-project: the selector" "$(detail "$out" repo orca-project)" "id:r1"
out=$(cd "$R" && FAKE_PLUGINS="[{\"id\":\"hi-guard@highness\",\"scope\":\"project\",\"enabled\":true,\"projectPath\":\"$R\"}]" bash "$S" status)
assert_eq "a project-scope plugin of this repo is on" on "$(row "$out" machine plugin:hi-guard)"

mkdir -p "$XDG_CONFIG_HOME/highness"
printf '{"repos":{"acme":{"crew":{"process":"x"}}}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
out=$(cd "$R" && bash "$S" status)
assert_eq "overlay: an owner block → ok" ok "$(row "$out" person overlay)"
printf '{"repos":{"acme":{"session":{"language":"German"}}}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
mkdir -p "$R/.claude"; printf '{"session":{"language":"French"}}\n' > "$R/.claude/highness.json"
out=$(cd "$R" && bash "$S" status)
assert_eq "session.language: neither an overlay nor the team file counts" unset "$(row "$out" person session.language)"
rm -f "$R/.claude/highness.json"
printf '{"repos":{"acme":{"crew":{"process":"x"}}}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
mkdir -p "$R/.claude"; printf '{}\n' > "$R/.claude/highness.json"
out=$(cd "$R" && bash "$S" status)
assert_eq "overlay: the repo's own file → team-file" team-file "$(row "$out" person overlay)"
# A child clone with no file of its own, listed by the umbrella above it: the umbrella's file.
UMB="$SANDBOX/umb"; mkdir -p "$UMB/.claude" "$UMB/kid" && git -C "$UMB" init -q && git -C "$UMB/kid" init -q
printf '{}\n' > "$UMB/.claude/highness.json"; printf 'kid git@github.com:someone/kid.git\n' > "$UMB/repos.txt"
UMB=$(cd "$UMB" && pwd -P)
out=$(cd "$UMB/kid" && bash "$S" status)
assert_eq "overlay: a child clone of an umbrella → team-file" team-file "$(row "$out" person overlay)"
assert_contains "overlay: names the umbrella's file" "$(detail "$out" person overlay)" "$UMB/.claude/highness.json (the umbrella"
assert_eq "no tracker configured: no tracker row" "" "$(row "$out" person tracker)"

# A tracker the repo configures: hi-crew's crew.sh checks the person's credential (#42).
printf '{"tracker":{"kind":"jira","base_url":"https://example.atlassian.net"}}\n' > "$R/.claude/highness.json"
PLUG="$(plugins hi-crew@highness:user)"
out=$(cd "$R" && FAKE_PLUGINS="$PLUG" bash "$S" status)
assert_eq "tracker: no credential → no-token, a person row" no-token "$(row "$out" person tracker)"
assert_contains "tracker: names the host" "$(detail "$out" person tracker)" "example.atlassian.net"
assert_eq "tracker is not a machine row" "" "$(row "$out" machine tracker)"
printf '{}\n' > "$R/.claude/highness.json"

# Orca down: repo rows say unknown rather than "missing".
out=$(cd "$R" && HI_ORCA="$SANDBOX/no-orca" bash "$S" status)
assert_eq "orca: not reachable" unavailable "$(row "$out" machine orca)"
assert_eq "orca-project: unknown without Orca" unknown "$(row "$out" repo orca-project)"

assert_summary
