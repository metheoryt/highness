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
# A fake claude: `plugin list --json` prints $FAKE_PLUGINS, and logs the profile it was asked about.
FAKE_CLAUDE="$SHIM/fake-claude"
cat > "$FAKE_CLAUDE" <<SH
#!/bin/sh
printf '%s\n' "\$CLAUDE_CONFIG_DIR" > "$SANDBOX/claude-profile"
[ "\$1 \$2 \$3" = "plugin list --json" ] || exit 1
printf '%s\n' "\${FAKE_PLUGINS:-[]}"
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
assert_eq "launcher: from repo-setup" missing "$(row "$out" machine launcher)"
assert_eq "plugin:hi on" on "$(row "$out" machine plugin:hi)"
assert_eq "plugin:hi-guard off" off "$(row "$out" machine plugin:hi-guard)"
assert_eq "plugin:hi-crew off" off "$(row "$out" machine plugin:hi-crew)"
assert_eq "hi-crew off → no crew rows" off "$(row "$out" machine hi-crew)"
assert_eq "hi-crew off → no orchestration row" "" "$(row "$out" machine orchestration)"
assert_eq "board: the five missing labels (#23)" missing "$(row "$out" machine board)"
assert_eq "board: detail" "Mains, QA, Review queue, Waiting author, Needs me" "$(detail "$out" machine board)"
assert_eq "config: none" none "$(row "$out" person config)"
assert_eq "no overlay row outside a repo" "" "$(row "$out" person overlay)"

# --- the worker profile: Orca's active Claude account, else ~/.claude ------------------------
out=$(cd "$SANDBOX" && bash "$S" profile)
assert_eq "profile: no Orca account → ~/.claude" "$HOME/.claude" "$(printf '%s' "$out" | cut -f1)"
P="$HOME/Library/Application Support/orca/claude-profiles/acc-1/home"; mkdir -p "$P"
out=$(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" profile)
assert_eq "profile: Orca's active account's dir" "$P" "$(printf '%s' "$out" | cut -f1)"
(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" status >/dev/null)
assert_eq "plugins are listed for the worker profile" "$P" "$(cat "$SANDBOX/claude-profile")"
out=$(cd "$SANDBOX" && FAKE_ACCOUNT='"acc-1"' bash "$S" status)
assert_contains "plugin rows name the profile" "$(detail "$out" machine plugin:hi)" "$P"
out=$(cd "$SANDBOX" && HI_CLAUDE_PROFILE=/elsewhere bash "$S" profile | cut -f1)
assert_eq "profile: HI_CLAUDE_PROFILE wins" /elsewhere "$out"
out=$(cd "$SANDBOX" && HI_CLAUDE="$SANDBOX/no-claude" bash "$S" status)
assert_eq "plugins: no claude → unknown" unknown "$(row "$out" machine plugins)"

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

mkdir -p "$XDG_CONFIG_HOME/highness"
printf '{"crew":{"agent":"claude","model":null}}\n' > "$XDG_CONFIG_HOME/highness/config.json"
out=$(cd "$SANDBOX" && FAKE_PLUGINS="$(plugins hi-crew@highness:user)" bash "$S" status)
assert_eq "config: ok" ok "$(row "$out" person config)"
assert_eq "crew.model null → default" default "$(row "$out" person crew.model)"
assert_eq "crew.agent set" set "$(row "$out" person crew.agent)"
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
mkdir -p "$R/.claude"; printf '{}\n' > "$R/.claude/highness.json"
out=$(cd "$R" && bash "$S" status)
assert_eq "overlay: the repo's own file → team-file" team-file "$(row "$out" person overlay)"

# Orca down: repo rows say unknown rather than "missing".
out=$(cd "$R" && HI_ORCA="$SANDBOX/no-orca" bash "$S" status)
assert_eq "orca: not reachable" unavailable "$(row "$out" machine orca)"
assert_eq "orca-project: unknown without Orca" unknown "$(row "$out" repo orca-project)"

assert_summary
