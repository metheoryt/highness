#!/usr/bin/env bash
# lib/umbrella.sh — root marker, repos.txt parsing, resolve by PR and by ticket key.
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
U="$LIB/umbrella.sh"

# An umbrella with three listed clones: alpha (origin someone/alpha), beta (origin
# Someone/Beta, listed with a trailing slash and CRLF), gamma (listed, never cloned), plus an
# empty listed dir that is not a clone. Each clone has a bare origin of its own.
UMB="$SANDBOX/umb"
git init -q -b main "$UMB"
mkclone() {  # mkclone <dir> <origin-slug>: origin reads as GitHub, fetches from a local bare repo
  local up="$SANDBOX/up/$2.git" url="git@github.com:$2.git"
  mkdir -p "${up%/*}"; git init -q --bare "$up"
  git config --global "url.$up.insteadOf" "$url"
  git init -q -b main "$UMB/$1"
  git -C "$UMB/$1" commit -q --allow-empty -m base
  git -C "$UMB/$1" remote add origin "$url"
  git -C "$UMB/$1" push -q origin main
}
mkclone alpha someone/alpha
mkclone beta Someone/Beta
mkdir -p "$UMB/empty"
printf '# repos in this umbrella\n\nalpha git@github.com:someone/alpha.git\nbeta/ git@github.com:someone/beta.git\r\ngamma git@github.com:someone/gamma.git\nempty git@github.com:someone/empty.git\n. git@github.com:someone/umb.git\n' > "$UMB/repos.txt"

# --- root ---
out=$(cd "$SANDBOX" && bash "$U" root); rc=$?
assert_status "root: outside any repo → exit 1" 1 "$rc"
mkdir -p "$UMB/docs"
assert_eq "root: from the umbrella root" "$UMB" "$(cd "$UMB" && bash "$U" root)"
assert_eq "root: from a subdirectory of it" "$UMB" "$(cd "$UMB/docs" && bash "$U" root)"
out=$(cd "$UMB/alpha" && bash "$U" root); rc=$?
assert_status "root: inside a nested clone it is not the umbrella" 1 "$rc"
git init -q "$SANDBOX/plain"
out=$(cd "$SANDBOX/plain" && bash "$U" root); rc=$?
assert_status "root: a repo with no repos.txt → exit 1" 1 "$rc"

# --- repos: from the clone's actual origin; missing, non-clone and self entries skipped ---
out=$(cd "$UMB" && bash "$U" repos); rc=$?
assert_status "repos: exit 0" 0 "$rc"
assert_eq "repos: one row per cloned dir, CRLF and trailing slash tolerated" \
  "$(printf '%s\tsomeone/alpha\n%s\tsomeone/beta' "$UMB/alpha" "$UMB/beta")" "$out"
assert_eq "repos --paths: the paths alone, one per line" \
  "$(printf '%s\n%s' "$UMB/alpha" "$UMB/beta")" "$(cd "$UMB" && bash "$U" repos --paths)"
(cd "$UMB" && bash "$U" repos --bogus >/dev/null 2>&1)
assert_status "repos: an unknown flag → exit 2" 2 "$?"
git -C "$UMB/alpha" remote set-url origin 'git@alias.github.com:Other/Renamed.git'
assert_contains "repos: the real origin wins over the listed URL" "$(cd "$UMB" && bash "$U" repos)" "$(printf '%s\tother/renamed' "$UMB/alpha")"
git -C "$UMB/alpha" remote remove origin
assert_contains "repos: no origin → the listed URL" "$(cd "$UMB" && bash "$U" repos)" "$(printf '%s\tsomeone/alpha' "$UMB/alpha")"
git -C "$UMB/alpha" remote add origin git@github.com:someone/alpha.git
out=$(cd "$UMB/alpha" && bash "$U" repos 2>&1); rc=$?
assert_status "repos: outside an umbrella → exit 1" 1 "$rc"
assert_contains "repos: says why" "$out" "not in an umbrella"

# --- resolve --pr ---
cd "$UMB"
assert_eq "pr: owner/repo#n" "$UMB/alpha" "$(bash "$U" resolve --pr 'someone/alpha#12')"
assert_eq "pr: URL, case-insensitive, with a /files tail" "$UMB/beta" \
  "$(bash "$U" resolve --pr 'https://github.com/SomeOne/beta/pull/7/files')"
out=$(bash "$U" resolve --pr 'someone/gamma#1' 2>&1); rc=$?
assert_status "pr: a listed but uncloned repo → exit 1" 1 "$rc"
assert_contains "pr: says it is not cloned" "$out" "someone/gamma is not cloned"
out=$(bash "$U" resolve --pr '12' 2>&1); rc=$?
assert_status "pr: a bare number names no repo → exit 2" 2 "$rc"
out=$(bash "$U" resolve 2>&1); rc=$?
assert_status "resolve: no flag → exit 2" 2 "$rc"

# --- resolve --key: every hit in every clone, nothing guessed ---
git -C "$UMB/alpha" push -q origin main:refs/heads/feat/dev/AB-7-retry main:refs/heads/feat/dev/AB-70-other
git -C "$UMB/beta" push -q origin main:refs/heads/feat/dev/AB-7-retry
assert_eq "key: one row per clone that carries it, whole-token match" \
  "$(printf '%s\tfeat/dev/AB-7-retry\n%s\tfeat/dev/AB-7-retry' "$UMB/alpha" "$UMB/beta")" \
  "$(bash "$U" resolve --key AB-7)"
out=$(bash "$U" resolve --key AB-9 2>"$SANDBOX/err"); rc=$?
assert_status "key: no hit anywhere → exit 3" 3 "$rc"
assert_eq "key: no hit → no rows" "" "$out"
assert_contains "key: no hit is said, with the way out" "$(cat "$SANDBOX/err")" "no clone has a branch for AB-9"
git -C "$UMB/beta" remote set-url origin "$SANDBOX/up/nowhere.git"   # unreachable
out=$(bash "$U" resolve --key AB-7 2>"$SANDBOX/err"); rc=$?
assert_status "key: an unreachable origin → exit 4" 4 "$rc"
assert_eq "key: the clones that answered still print" "$(printf '%s\tfeat/dev/AB-7-retry' "$UMB/alpha")" "$out"
assert_contains "key: the unreachable one is named" "$(cat "$SANDBOX/err")" "nowhere"

# --- a workspace of the umbrella: root is the workspace, the clones are the main checkout's ---
git -C "$UMB/beta" remote set-url origin git@github.com:someone/beta.git
git -C "$UMB" add repos.txt && git -C "$UMB" commit -q -m repos
git -C "$UMB" worktree add -q -b work/docs "$SANDBOX/umb-ws" >/dev/null 2>&1
UWS=$(cd "$SANDBOX/umb-ws" && pwd -P)
assert_eq "workspace: root is the workspace" "$UWS" "$(cd "$UWS" && bash "$U" root)"
assert_eq "workspace: home is the main checkout" "$UMB" "$(cd "$UWS" && bash "$U" home)"
assert_eq "main checkout: home is the root" "$UMB" "$(cd "$UMB" && bash "$U" home)"
assert_eq "workspace: repos are the main checkout's clones" "$(cd "$UMB" && bash "$U" repos)" "$(cd "$UWS" && bash "$U" repos)"
assert_eq "workspace: resolve --pr finds the main checkout's clone" "$UMB/alpha" \
  "$(cd "$UWS" && bash "$U" resolve --pr 'someone/alpha#1')"
mkdir -p "$UWS/alpha"
assert_eq "workspace: a same-named dir in the workspace is not the clone" "$(cd "$UMB" && bash "$U" repos)" "$(cd "$UWS" && bash "$U" repos)"
out=$(cd "$UMB/alpha" && bash "$U" home 2>/dev/null); rc=$?
assert_status "home: inside a nested clone → exit 1" 1 "$rc"

out=$(bash "$U" bogus 2>&1); rc=$?
assert_status "unknown verb → exit 2" 2 "$rc"
# --- resolve --issue: a GitHub Issues key names its clone by repo name, no origin asked ---
assert_eq "issue: repo#n → that clone" "$UMB/alpha" "$(bash "$U" resolve --issue 'alpha#3')"
assert_eq "issue: the name is case-insensitive" "$UMB/alpha" "$(bash "$U" resolve --issue 'ALPHA#3')"
out=$(bash "$U" resolve --issue 'gamma#1' 2>&1); rc=$?
assert_status "issue: no such clone → exit 1" 1 "$rc"
assert_contains "issue: says no clone matched" "$out" "0 clones"
out=$(bash "$U" resolve --issue 'alpha' 2>&1); rc=$?
assert_status "issue: not repo#n → exit 2" 2 "$rc"

assert_summary
