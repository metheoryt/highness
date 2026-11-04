#!/usr/bin/env bash
# lib/worktree-setup.sh and lib/worktree-teardown.sh, with a fake `gortex` on PATH and real
# git repos with linked worktrees.
#
# The fake serves `repos --json` from a mutable path-list file and rewrites that file on
# track/untrack, as the real binary does: the scripts ask the daemon, never a config file, and
# the "reads no config file" case below keeps it that way.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
export TMPDIR="$SANDBOX/tmp"; mkdir -p "$TMPDIR"
setup="$HERE/../lib/worktree-setup.sh"
teardown="$HERE/../lib/worktree-teardown.sh"
check() { if eval "$2"; then _assert_ok "$1"; else _assert_bad "$1"; fi; }
# setup runs `gortex track` in the background: poll (up to 5 s) for what it leaves behind.
eventually() { local i=0; while [ $i -lt 50 ]; do eval "$1" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }

# --- Fake gortex.
#   * records every call in $GORTEX_CALLS
#   * `daemon status` exits $FAKE_GORTEX_DAEMON_UP (0/1)
#   * `repos` exits 1 with no output when $FAKE_GORTEX_REPOS_FAIL is set (an older
#     gortex with no `repos --json`)
#   * `repos --json` renders $FAKE_GORTEX_REPOS (newline-separated paths) as the
#     real pretty-printed JSON, backslashes escaped the way encoding/json does
#   * `track` / `untrack` MUTATE $FAKE_GORTEX_REPOS, like the real config rewrite
#   * `untrack` also appends to $FAKE_GORTEX_UNTRACK_LOG when set (ordering probe)
mk_fakebin() {
  local d; d="$(mktemp -d)"
  cat > "$d/gortex" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$GORTEX_CALLS"
store="${FAKE_GORTEX_REPOS:-/dev/null}"
case "$1" in
  daemon)
    [ "$2" = "status" ] && exit "${FAKE_GORTEX_DAEMON_UP:-0}"
    ;;
  repos)
    # Older gortex has no `repos` subcommand / no --json: non-zero, no output.
    [ -n "${FAKE_GORTEX_REPOS_FAIL:-}" ] && exit 1
    printf '[\n'
    n=0
    while IFS= read -r p || [ -n "$p" ]; do
      [ -n "$p" ] || continue
      [ "$n" -eq 0 ] || printf ',\n'
      n=1
      esc=$(printf '%s' "$p" | sed 's/\\/\\\\/g')
      printf '  {\n    "name": "%s",\n    "path": "%s",\n    "indexed": true\n  }' \
        "$(basename "$p")" "$esc"
    done < "$store"
    printf '\n]\n'
    exit 0
    ;;
  track)
    sleep "${FAKE_GORTEX_TRACK_SLEEP:-0}"
    [ -f "$store" ] && printf '%s\n' "$2" >> "$store"
    exit 0
    ;;
  untrack)
    if [ -f "$store" ]; then
      grep -v -x -F -- "$2" "$store" > "$store.tmp"
      mv "$store.tmp" "$store"
    fi
    [ -n "${FAKE_GORTEX_UNTRACK_LOG:-}" ] && echo untrack >> "$FAKE_GORTEX_UNTRACK_LOG"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$d/gortex"
  printf '%s' "$d"
}

# A path-list store holding the arguments, one per line.
mk_store() { local f; f="$(mktemp)"; printf '%s\n' "$@" > "$f"; printf '%s' "$f"; }

# --- Fixture: a main repo + one linked worktree. Echoes "<main> <wt>".
mk_repo_with_worktree() {
  local base main wt
  # `pwd -P`: on macOS /var is a symlink to /private/var, and the scripts report git's
  # PHYSICAL path.
  base="$(cd "$(mktemp -d)" && pwd -P)"
  main="$base/main"
  git init -q "$main"
  ( cd "$main" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
  wt="$base/wt-feature"
  ( cd "$main" && git worktree add -q "$wt" -b feature >/dev/null 2>&1 )
  printf '%s %s' "$main" "$wt"
}

# ============ SETUP ============

# Case 1: daemon up + main covered + worktree new -> tracks worktree, prefix qualified
# with the main checkout's basename (bare basename would collide across repos).
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
store="$(mk_store "$main")"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup tracks a new worktree when main is covered" \
  'eventually "grep -q \"track '"$wt"' --as-worktree\" \"$calls\""'
check "setup qualifies --name with the main checkout basename" \
  'grep -q -- "--name main-wt-feature" "$calls"'
wgit="$(cd "$wt" && git rev-parse --absolute-git-dir)"
check "the background track removes its pid file when done" 'eventually "[ ! -f \"$wgit/gortex-track.pid\" ]"'
check "the background track logs its exit" 'eventually "grep -q \"^exit 0\" \"$wgit/gortex-track.log\""'

# Case 1b: a slow track does not hold the caller. A caller that captures setup's output
# waits for every writer to close, so a job that inherited stderr would block it here.
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
store="$(mk_store "$main")"; calls="$(mktemp)"; wgit="$(cd "$wt" && git rev-parse --absolute-git-dir)"
t0=$(date +%s)
out=$(cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 \
      FAKE_GORTEX_TRACK_SLEEP=6 bash "$setup" 2>&1 | cat)
t1=$(date +%s)
check "setup returns before a slow track finishes" '[ $((t1 - t0)) -lt 4 ]'
check "setup says the track runs in the background" 'printf "%s" "$out" | grep -q "started in the background"'
check "a pid file marks the running track" 'eventually "[ -s \"$wgit/gortex-track.pid\" ]"'
# Teardown stops it before untracking, so a finished track cannot re-add the path.
tpid=$(cat "$wgit/gortex-track.pid" 2>/dev/null)
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "teardown stops a running background track" 'eventually "! kill -0 '"${tpid:-0}"' 2>/dev/null"'
sleep 1
check "the stopped track never recorded the worktree" '! grep -qxF "$wt" "$store"'

# Case 2: daemon down -> no track call.
store="$(mk_store "$main")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=1 bash "$setup" >/dev/null 2>&1 )
check "setup does not track when daemon is down" '! grep -q "^track " "$calls"'

# Case 3: main NOT covered -> no track call.
store2="$(mk_store /some/other/repo)"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store2" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup skips track when main is not covered" '! grep -q "^track " "$calls"'

# Case 4: worktree already tracked -> no duplicate track.
store3="$(mk_store "$main" "$wt")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store3" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup skips track when worktree already listed" '! grep -q "^track " "$calls"'

# Case 5: main checkout (not a linked worktree) -> takes main-checkout branch (distinctive log).
store="$(mk_store "$main")"; err="$(mktemp)"
( cd "$main" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" 2>"$err" >/dev/null )
check "setup takes the main-checkout branch in the main checkout" 'grep -q "main checkout" "$err"'

# Case 6: repo-local setup script runs; first candidate wins.
touched="$(mktemp)"; rm -f "$touched"
mkdir -p "$wt/.orca" "$wt/docker"
printf '#!/usr/bin/env bash\necho orca > "%s"\n' "$touched" > "$wt/.orca/worktree-setup.sh"
printf '#!/usr/bin/env bash\necho docker > "%s"\n' "$touched" > "$wt/docker/worktree-setup.sh"
chmod +x "$wt/.orca/worktree-setup.sh" "$wt/docker/worktree-setup.sh"
store="$(mk_store "$main")"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup runs first repo-local candidate (.orca over docker)" '[ "$(cat "$touched")" = "orca" ]'
rm -rf "$wt/.orca" "$wt/docker"

# Case 6d: the local delegate (<git-common-dir>/hi/worktree-setup.sh, written by the
# repo-setup skill where nothing may be committed) runs AFTER the committed candidate.
order="$(mktemp)"; rm -f "$order"
mkdir -p "$wt/.orca" "$main/.git/hi"
printf '#!/usr/bin/env bash\necho committed >> "%s"\n' "$order" > "$wt/.orca/worktree-setup.sh"
printf '#!/usr/bin/env bash\necho local >> "%s"\n' "$order" > "$main/.git/hi/worktree-setup.sh"
chmod +x "$wt/.orca/worktree-setup.sh" "$main/.git/hi/worktree-setup.sh"
store="$(mk_store "$main")"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup runs the local delegate after the committed one" '[ "$(tr "\n" " " < "$order")" = "committed local " ]'

# Case 6e: the local delegate alone still runs, from the worktree root.
rm -rf "$wt/.orca"; rm -f "$order"
printf '#!/usr/bin/env bash\npwd -P >> "%s"\n' "$order" > "$main/.git/hi/worktree-setup.sh"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup runs the local delegate alone, from the worktree root" '[ "$(cat "$order")" = "$(cd "$wt" && pwd -P)" ]'

# Case 6f: an older <git-common-dir>/us/ delegate runs when hi/ has none, and never beside it.
rm -f "$order"
mkdir -p "$main/.git/us"
printf '#!/usr/bin/env bash\necho older >> "%s"\n' "$order" > "$main/.git/us/worktree-setup.sh"
chmod +x "$main/.git/us/worktree-setup.sh"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup runs hi/'s delegate, not also the older us/ one" '[ "$(cat "$order")" = "$(cd "$wt" && pwd -P)" ]'
rm -rf "$main/.git/hi"; rm -f "$order"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup falls back to the older us/ delegate" '[ "$(cat "$order")" = "older" ]'
rm -rf "$main/.git/us"

# Case 6b: coverage comes from the daemon, not a config file. Two halves:
# the script must ASK (`repos --json` in the call log) and must not read a config
# file to decide (no GORTEX_CONFIG / config.yaml default anywhere in either script).
store="$(mk_store "$main")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup asks the daemon for tracked repos" 'grep -q "^repos --json$" "$calls"'
check "neither script depends on a config-file path" \
  '! grep -qE "GORTEX_CONFIG|config\.yaml\"" "$setup" "$teardown"'

# Case 6c: a FAILED `repos` query must not read as an empty repo list (an older gortex without
# the subcommand would look "not covered" and silently skip tracking). Both scripts say so.
store="$(mk_store "$main")"; calls="$(mktemp)"; err="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" \
  FAKE_GORTEX_REPOS_FAIL=1 FAKE_GORTEX_DAEMON_UP=0 bash "$setup" 2>"$err" >/dev/null )
check "setup distinguishes a failed repos query from 'not covered'" \
  'grep -q "gortex repos unavailable" "$err" && ! grep -q "not covered" "$err" && ! grep -q "^track " "$calls"'
err="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" \
  FAKE_GORTEX_REPOS_FAIL=1 FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" 2>"$err" >/dev/null )
check "teardown skips reconcile when the repos query fails" \
  'grep -q "gortex repos unavailable" "$err"'

# ============ TEARDOWN ============

# Case 7: repo-local teardown runs BEFORE gortex untrack.
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
store="$(mk_store "$main" "$wt")"
order="$(mktemp)"
mkdir -p "$wt/docker"
printf '#!/usr/bin/env bash\necho local >> "%s"\n' "$order" > "$wt/docker/worktree-teardown.sh"
chmod +x "$wt/docker/worktree-teardown.sh"
calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$calls" \
  FAKE_GORTEX_UNTRACK_LOG="$order" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "teardown untracks this worktree" 'grep -q "untrack '"$wt"'" "$calls"'
check "teardown runs local script before untrack" '[ "$(head -1 "$order")" = "local" ] && grep -q untrack "$order"'

# Case 8: reconcile prunes a missing path, keeps a live one.
missing="/no/such/dir/should/exist/$$"
store4="$(mk_store "$main" "$missing")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store4" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "reconcile untracks the missing path" 'grep -q "untrack '"$missing"'" "$calls"'
check "reconcile keeps the live main path" '! grep -q "untrack '"$main"'\$" "$calls"'

# Case 9: daemon down -> no untrack, no reconcile.
store4="$(mk_store "$main" "$missing")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store4" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=1 bash "$teardown" >/dev/null 2>&1 )
check "teardown does no gortex work when daemon down" '! grep -q "^untrack " "$calls"'

# Case 10: not inside a work tree -> both exit 0.
empty="$(mktemp -d)"
( cd "$empty" && PATH="$fb:$PATH" bash "$setup" >/dev/null 2>&1 ); check "setup exits 0 outside a work tree" '[ "$?" -eq 0 ]'
( cd "$empty" && PATH="$fb:$PATH" bash "$teardown" >/dev/null 2>&1 ); check "teardown exits 0 outside a work tree" '[ "$?" -eq 0 ]'

# Case 11: untrack rewrites the very list reconcile is walking, so the sweep runs off a
# snapshot. Two missing paths: both must go.
gone1="/no/such/dir/a/$$"; gone2="/no/such/dir/b/$$"
store5="$(mk_store "$main" "$gone1" "$gone2")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store5" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "reconcile prunes every missing path while untrack rewrites the list" \
  'grep -q "untrack '"$gone1"'" "$calls" && grep -q "untrack '"$gone2"'" "$calls"'

# Case 11b: a native-Windows path arrives JSON-escaped (C:\\Users\\...). The parser
# must unescape it to the forward-slash form Git Bash's `cd` accepts before deciding
# it is gone from disk.
winpath='C:\Users\someone\gone'
store6="$(mk_store "$main" "$winpath")"; calls="$(mktemp)"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store6" GORTEX_CALLS="$calls" FAKE_GORTEX_DAEMON_UP=0 bash "$teardown" >/dev/null 2>&1 )
check "reconcile unescapes a JSON-escaped Windows path" \
  'grep -qF "untrack C:/Users/someone/gone" "$calls"'

# Case 12: `.env` is DELIBERATELY NOT linked. A repo that isolates worktrees writes its own
# .env from its setup script; through a symlink that write would land in the MAIN checkout's
# .env and every worktree would share one namespace. Both halves: no link in the worktree, and
# main's .env untouched.
fb="$(mk_fakebin)"; read -r main wt <<<"$(mk_repo_with_worktree)"
store="$(mk_store "$main")"
printf 'SECRET=1\n' > "$main/.env"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup does not link .env into the worktree" '[ ! -L "$wt/.env" ] && [ ! -e "$wt/.env" ]'
check "setup leaves the main checkout .env untouched" '[ "$(cat "$main/.env")" = "SECRET=1" ]'

# Case 12b: end-to-end — a repo-local setup script that writes .env writes into the
# WORKTREE, never through a symlink into main. This is the behaviour case 12 protects.
mkdir -p "$wt/docker"
printf '#!/usr/bin/env bash\nprintf "WT_NS=x\\n" >> "$(git rev-parse --show-toplevel)/.env"\n' > "$wt/docker/worktree-setup.sh"
chmod +x "$wt/docker/worktree-setup.sh"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "a repo-local .env write lands in the worktree, not in main" \
  '[ ! -L "$wt/.env" ] && grep -q WT_NS "$wt/.env" && ! grep -q WT_NS "$main/.env"'
rm -rf "$wt/docker" "$wt/.env"

# Case 13: nested-path config is linked with its parent dir created.
mkdir -p "$main/.claude"; printf '{"x":1}\n' > "$main/.claude/settings.local.json"
store="$(mk_store "$main")"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup symlinks nested .claude/settings.local.json" '[ -L "$wt/.claude/settings.local.json" ]'

# Case 14: a pre-existing dest file is NOT clobbered.
read -r main2 wt2 <<<"$(mk_repo_with_worktree)"
store2="$(mk_store "$main2")"
mkdir -p "$main2/.claude" "$wt2/.claude"
printf 'MAIN=1\n' > "$main2/.claude/settings.local.json"
printf 'LOCAL=1\n' > "$wt2/.claude/settings.local.json"
( cd "$wt2" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store2" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup does not clobber an existing dest file" \
  '[ ! -L "$wt2/.claude/settings.local.json" ] && grep -q LOCAL "$wt2/.claude/settings.local.json"'

# Case 15: idempotent — re-run exits 0 and leaves the link intact.
store="$(mk_store "$main")"
( cd "$wt" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 ); rc=$?
check "setup re-run is idempotent (exit 0, link intact)" \
  '[ "'$rc'" -eq 0 ] && [ -L "$wt/.claude/settings.local.json" ]'

# Case 16: link step is skipped in the main checkout (the linkable file stays a real
# file, not a symlink into itself).
read -r main3 wt3 <<<"$(mk_repo_with_worktree)"
store3="$(mk_store "$main3")"
mkdir -p "$main3/.claude"; printf 'X=1\n' > "$main3/.claude/settings.local.json"
( cd "$main3" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store3" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "link step skipped in main checkout (file not a symlink)" '[ ! -L "$main3/.claude/settings.local.json" ]'

# Case 17: only the listed config is linked: nothing else under .claude/ appears.
read -r main4 wt4 <<<"$(mk_repo_with_worktree)"
store4="$(mk_store "$main4")"
mkdir -p "$main4/.claude/memory"; printf 'P=1\n' > "$main4/.claude/memory/project.md"
( cd "$wt4" && PATH="$fb:$PATH" FAKE_GORTEX_REPOS="$store4" GORTEX_CALLS="$(mktemp)" FAKE_GORTEX_DAEMON_UP=0 bash "$setup" >/dev/null 2>&1 )
check "setup links nothing else under .claude (no .claude/memory)" \
  '[ ! -e "$wt4/.claude/memory" ] && [ ! -L "$wt4/.claude/memory" ]'

assert_summary
