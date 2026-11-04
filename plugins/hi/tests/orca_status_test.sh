#!/usr/bin/env bash
# Behavior tests for orca-status.sh — builds a fixture orca-data.json, runs the
# helper for each matrix branch, and asserts the two emitted slot tokens. Also
# asserts the fixture is byte-identical afterwards (read-only contract).
set -u
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../lib/orca-status.sh"
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { echo "PASS $1"; }
die()  { echo "FAIL $1"; fail=1; }

SETUP='bash "$HOME/bin/worktree-setup.sh"'
TEARDOWN='bash "$HOME/bin/worktree-teardown.sh"'
LEGACY='bash "$HOME/bin/old-worktree-setup.sh"'

# extract the token for a slot ("setup"/"archive") from multi-line status output.
tok() { printf '%s\n' "$1" | awk -v s="$2" -F'\t' '$1==s{ sub(/^[^\t]*\t/,""); print; exit }'; }

DATA="$tmp/orca-data.json"
cat > "$DATA" <<'JSON'
{
  "repos": [
    { "path": "/base/reposonly", "hookSettings": { "scripts": {
      "setup": "bash \"$HOME/bin/worktree-setup.sh\"",
      "archive": "bash \"$HOME/bin/worktree-teardown.sh\"" } } }
  ],
  "projectHostSetups": [
    { "projectId": "github:me/app", "path": "/base/app",
      "hookSettings": { "scripts": {
        "setup": "bash \"$HOME/bin/worktree-setup.sh\"",
        "archive": "bash \"$HOME/bin/worktree-teardown.sh\"" } } },
    { "projectId": "github:me/legacy", "path": "/base/legacy",
      "hookSettings": { "scripts": {
        "setup": "bash \"$HOME/bin/old-worktree-setup.sh\"" } } },
    { "projectId": "github:me/empty", "path": "/base/empty",
      "hookSettings": { "scripts": { "setup": "", "archive": "" } } }
  ]
}
JSON

# Fully wired (both slots) — and URL forms all canonicalize to the same projectId.
for u in \
  "git@github.com:me/app.git" \
  "https://github.com/me/app.git" \
  "ssh://git@github.com/me/app.git" ; do
  got="$(bash "$SCRIPT" "$DATA" "$u" "$SETUP" "$TEARDOWN" "/base/app")"
  [ "$(tok "$got" setup)" = "WIRED" ] && [ "$(tok "$got" archive)" = "WIRED" ] \
    && pass "WIRED both $u" || die "WIRED both $u -> '$got'"
done

# Legacy setup + missing archive -> setup CONFLICT (surfaces old value), archive UNWIRED.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:me/legacy.git" "$SETUP" "$TEARDOWN" "/base/legacy")"
[ "$(tok "$got" setup)" = "$(printf 'CONFLICT\t%s' "$LEGACY")" ] \
  && pass "legacy setup CONFLICT" || die "legacy setup -> '$(tok "$got" setup)'"
[ "$(tok "$got" archive)" = "UNWIRED" ] \
  && pass "legacy archive UNWIRED" || die "legacy archive -> '$(tok "$got" archive)'"

# Preferred + accepted forms: an already-wired repo may hold an older form that still
# works, so it reports LEGACY (with the current value, so the skill can offer the
# preferred one) and NOT CONFLICT — a status check that reports every wired repo as
# broken is one nobody reads. The first line of the expectation is preferred; the rest
# are accepted.
PREF_SETUP='highness worktree-setup'
PREF_TEARDOWN='highness worktree-teardown'
MULTI_SETUP="$PREF_SETUP
$SETUP"
MULTI_TEARDOWN="$PREF_TEARDOWN
$TEARDOWN"

# The fixture's wired repo holds the older form.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:me/app.git" "$MULTI_SETUP" "$MULTI_TEARDOWN" "/base/app")"
# tok returns "TOKEN<TAB>value" for the value-carrying tokens, so match the prefix.
case "$(tok "$got" setup)" in
  LEGACY*) pass "older form reports LEGACY, not CONFLICT" ;;
  *)       die "old form -> '$(tok "$got" setup)'" ;;
esac
printf '%s' "$got" | grep -q 'worktree-setup.sh' \
  && pass "LEGACY surfaces the current value" || die "LEGACY did not surface the value"

# And the preferred form alone is plain WIRED.
# jq, not sed: the fixture stores the value as a JSON string with escaped quotes,
# so a text substitution has to out-guess the escaping. Set the field instead.
jq '(.projectHostSetups[] | select(.projectId=="github:me/app") | .hookSettings.scripts)
    |= { setup: "highness worktree-setup", archive: "highness worktree-teardown" }' "$DATA" > "$DATA.pref"
got="$(bash "$SCRIPT" "$DATA.pref" "git@github.com:me/app.git" "$MULTI_SETUP" "$MULTI_TEARDOWN" "/base/app")"
[ "$(tok "$got" setup)" = "WIRED" ] && [ "$(tok "$got" archive)" = "WIRED" ] \
  && pass "preferred form is WIRED" || die "preferred form -> '$got'"

# An unrelated value is still CONFLICT — the accepted list must not swallow everything.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:me/legacy.git" "$MULTI_SETUP" "$MULTI_TEARDOWN" "/base/legacy")"
case "$(tok "$got" setup)" in
  CONFLICT*) pass "an unknown script is still CONFLICT" ;;
  *)         die "unknown -> '$(tok "$got" setup)'" ;;
esac

# Empty both -> UNWIRED both.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:me/empty.git" "$SETUP" "$TEARDOWN" "/base/empty")"
[ "$(tok "$got" setup)" = "UNWIRED" ] && [ "$(tok "$got" archive)" = "UNWIRED" ] \
  && pass "empty UNWIRED both" || die "empty -> '$got'"

# Absent repo -> ABSENT both.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:me/nope.git" "$SETUP" "$TEARDOWN" "/base/nope")"
[ "$(tok "$got" setup)" = "ABSENT" ] && [ "$(tok "$got" archive)" = "ABSENT" ] \
  && pass "absent ABSENT both" || die "absent -> '$got'"

# repos[] fallback (by path, no projectId) -> WIRED both.
got="$(bash "$SCRIPT" "$DATA" "git@github.com:me/reposonly.git" "$SETUP" "$TEARDOWN" "/base/reposonly")"
[ "$(tok "$got" setup)" = "WIRED" ] && [ "$(tok "$got" archive)" = "WIRED" ] \
  && pass "repos-fallback WIRED both" || die "repos-fallback -> '$got'"

# Missing data file -> ABSENT both, never an error.
got="$(bash "$SCRIPT" "$tmp/nofile.json" "git@github.com:me/app.git" "$SETUP" "$TEARDOWN" "/base/app")"
[ "$(tok "$got" setup)" = "ABSENT" ] && [ "$(tok "$got" archive)" = "ABSENT" ] \
  && pass "missing-file ABSENT both" || die "missing-file -> '$got'"

# profile-state.db (Orca's SQLite store) reads the same as the JSON it replaced.
DB="$tmp/profile-state.db"
# Built with python3's sqlite3 (as board.sh reads it): the sqlite3 CLI is not on every box.
for d in repos projectHostSetups; do jq -c ".$d" "$DATA" > "$tmp/$d.json"; done
python3 -I - "$DB" "$tmp" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("create table profile_state_documents (domain text primary key, payload text not null)")
for d in ("repos", "projectHostSetups"):
    con.execute("insert into profile_state_documents values (?, ?)", (d, open(sys.argv[2] + "/" + d + ".json").read()))
con.commit()
PY
got="$(bash "$SCRIPT" "$DB" "git@github.com:me/app.git" "$SETUP" "$TEARDOWN" "/base/app")"
[ "$(tok "$got" setup)" = "WIRED" ] && [ "$(tok "$got" archive)" = "WIRED" ] \
  && pass "profile-state.db WIRED both" || die "profile-state.db -> '$got'"
got="$(bash "$SCRIPT" "$DB" "git@github.com:me/reposonly.git" "$SETUP" "$TEARDOWN" "/base/reposonly")"
[ "$(tok "$got" setup)" = "WIRED" ] \
  && pass "profile-state.db repos-fallback WIRED" || die "profile-state.db repos-fallback -> '$got'"
got="$(bash "$SCRIPT" "$DB" "git@github.com:me/nope.git" "$SETUP" "$TEARDOWN" "/base/nope")"
[ "$(tok "$got" setup)" = "ABSENT" ] \
  && pass "profile-state.db absent ABSENT" || die "profile-state.db absent -> '$got'"
before="$(cksum "$DB")"
bash "$SCRIPT" "$DB" "git@github.com:me/app.git" "$SETUP" "$TEARDOWN" "/base/app" >/dev/null
[ "$before" = "$(cksum "$DB")" ] && pass "read-only (db unchanged)" || die "db mutated!"

# commandSourcePolicy: a third line, the raw value (empty when unset or the repo is absent).
[ "$(tok "$got" policy)" = "" ] && pass "policy: unset is empty" || die "policy unset -> '$(tok "$got" policy)'"
got="$(bash "$SCRIPT" "$DATA" "git@github.com:me/app.git" "$SETUP" "$TEARDOWN" "/base/app")"
printf '%s\n' "$got" | grep -q "^policy	" && pass "policy: line present" || die "policy: no line -> '$got'"
jq '(.projectHostSetups[] | select(.projectId=="github:me/app") | .hookSettings.commandSourcePolicy) = "run-both"' "$DATA" > "$DATA.pol"
got="$(bash "$SCRIPT" "$DATA.pol" "git@github.com:me/app.git" "$SETUP" "$TEARDOWN" "/base/app")"
[ "$(tok "$got" policy)" = "run-both" ] && pass "policy: run-both read" || die "policy -> '$(tok "$got" policy)'"
got="$(bash "$SCRIPT" "$tmp/nofile.json" "git@github.com:me/app.git" "$SETUP" "$TEARDOWN" "/base/app")"
[ "$(tok "$got" policy)" = "" ] && pass "policy: no data file is empty" || die "policy nofile -> '$got'"

# READ-ONLY — fixture byte-identical after a run.
before="$(cksum "$DATA")"
bash "$SCRIPT" "$DATA" "git@github.com:me/app.git" "$SETUP" "$TEARDOWN" "/base/app" >/dev/null
after="$(cksum "$DATA")"
[ "$before" = "$after" ] && pass "read-only (fixture unchanged)" || die "fixture mutated!"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
