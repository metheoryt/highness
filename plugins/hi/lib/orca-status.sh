#!/usr/bin/env bash
# orca-status.sh — READ-ONLY report of how a repo's Orca worktree hook fields are
# currently wired. Never writes orca-data.json; safe with Orca open.
#
# Usage: orca-status.sh <orca-data.json | profile-state.db> <origin-url> <expected-setup> <expected-teardown> <base-path>
# Prints THREE lines, one per Orca hook slot and the repo's command-source policy:
#   setup<TAB><TOKEN>
#   archive<TAB><TOKEN>
#   policy<TAB><hookSettings.commandSourcePolicy, empty when unset or the repo is absent>
# where TOKEN is WIRED | LEGACY<TAB><current-value> | UNWIRED | ABSENT |
# CONFLICT<TAB><current-value>. Exit 0. The slots are the person's own hook fields in Orca;
# a committed orca.yaml is read by repo-setup.sh, which also applies the policy.
#
# <expected-setup> / <expected-teardown> may list SEVERAL acceptable values, one per
# line: the first is PREFERRED, the rest are older forms that still work. Anything
# matching a non-first entry reports LEGACY rather than CONFLICT — the wrapper
# form that still works would otherwise make every already-wired repo look broken,
# and a status check that cries wolf gets ignored.
#
# Orca hook keys: Setup = hookSettings.scripts.setup; Delete = hookSettings.scripts.archive.
#
# Note: this derives Orca's `github:owner/repo` projectId (provider:owner/repo).
set -u

DATA="${1:-}"; ORIGIN="${2:-}"; EXPECT_SETUP="${3:-}"; EXPECT_TEARDOWN="${4:-}"; BASE="${5:-}"

# No data file: both slots ABSENT (never an error).
if [ -z "$DATA" ] || [ ! -f "$DATA" ]; then
  printf 'setup\tABSENT\narchive\tABSENT\npolicy\t\n'
  exit 0
fi

# Derive Orca's projectId (e.g. github:owner/repo) from a git origin URL.
project_id() {
  local u="$1"
  u="${u%.git}"
  u="${u#ssh://}"; u="${u#git+ssh://}"; u="${u#https://}"; u="${u#http://}"
  u="${u#git@}"; u="${u#*@}"
  u="${u/://}"
  u="${u/:/\/}"
  local host="${u%%/*}" rest="${u#*/}"
  local provider
  case "$host" in
    github.com)    provider=github ;;
    gitlab.com)    provider=gitlab ;;
    bitbucket.org) provider=bitbucket ;;
    *)             provider="$host" ;;
  esac
  printf '%s:%s' "$provider" "$rest"
}

pid="$(project_id "$ORIGIN")"

# Orca moved profile state into SQLite (profile-state.db, 2026-09-29); the orca-data.json
# beside it is a frozen export that no longer changes. A .db argument is read through
# python3's sqlite3, read-only, into the same {repos, projectHostSetups} shape the JSON had. Not
# the sqlite3 CLI: it is missing on some boxes, and there every repo silently read ABSENT.
JSON=""
case "$DATA" in
  *.db)
    doc() { python3 -I -c '
import sqlite3, sys
con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
row = con.execute("select payload from profile_state_documents where domain = ?", (sys.argv[2],)).fetchone()
print(row[0] if row else "")' "$DATA" "$1" 2>/dev/null; }
    r="$(doc repos)"; p="$(doc projectHostSetups)"
    JSON="$(jq -n --argjson r "${r:-[]}" --argjson p "${p:-[]}" '{repos: $r, projectHostSetups: $p}' 2>/dev/null)" \
      || JSON='{}'
    ;;
esac
src() { if [ -n "$JSON" ]; then printf '%s' "$JSON"; else cat "$DATA"; fi; }

# Read one slot's current value. Prefer .projectHostSetups[] by projectId; fall back
# to .repos[] by base path. "" = entry present but key unset; __ABSENT__ = no entry.
read_slot() {
  local key="$1"
  src | jq -r --arg pid "$pid" --arg base "$BASE" --arg key "$key" '
    ( [ .projectHostSetups[]? | select(.projectId == $pid) ] ) as $phs
    | ( [ .repos[]? | select(.path == $base) ] ) as $rp
    | if   ($phs | length) > 0 then ($phs[0].hookSettings.scripts[$key] // "")
      elif ($rp  | length) > 0 then ($rp[0].hookSettings.scripts[$key]  // "")
      else "__ABSENT__" end
  ' 2>/dev/null || printf '__ABSENT__'
}

classify() {
  local slot="$1" current="$2" expect="$3" first="" line=""
  case "$current" in
    __ABSENT__) printf '%s\tABSENT\n' "$slot"; return ;;
    "")         printf '%s\tUNWIRED\n' "$slot"; return ;;
  esac
  first="${expect%%
*}"
  [ "$current" = "$first" ] && { printf '%s\tWIRED\n' "$slot"; return; }
  # Accepted-but-older forms: exact match against any remaining line.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$line" = "$first" ] && continue
    if [ "$current" = "$line" ]; then
      printf '%s\tLEGACY\t%s\n' "$slot" "$current"
      return
    fi
  done <<EOF
$expect
EOF
  printf '%s\tCONFLICT\t%s\n' "$slot" "$current"
}

# The repo entry's hookSettings.commandSourcePolicy (local-only | run-both | shared-only), raw.
read_policy() {
  src | jq -r --arg pid "$pid" --arg base "$BASE" '
    ( [ .projectHostSetups[]? | select(.projectId == $pid) ] ) as $phs
    | ( [ .repos[]? | select(.path == $base) ] ) as $rp
    | if   ($phs | length) > 0 then ($phs[0].hookSettings.commandSourcePolicy // "")
      elif ($rp  | length) > 0 then ($rp[0].hookSettings.commandSourcePolicy  // "")
      else "" end | tostring | gsub("[\t\n]"; " ")
  ' 2>/dev/null || true
}

classify setup   "$(read_slot setup)"   "$EXPECT_SETUP"
classify archive "$(read_slot archive)" "$EXPECT_TEARDOWN"
printf 'policy\t%s\n' "$(read_policy)"
exit 0
