#!/usr/bin/env bash
# lib/orca.sh — the optional Orca CLI adapter. A stub binary on
# HI_ORCA drives every branch without a running Orca app.
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
O="$LIB/orca.sh"

stub=$(mktemp -d "$SANDBOX/tmp.XXXXXX")
mkstub() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$stub/orca"; chmod +x "$stub/orca"; }
run() { HI_ORCA="$stub/orca" bash "$O" "$@"; }

READY='{"ok":true,"result":{"app":{"running":true},"runtime":{"state":"ready","reachable":true,"appVersion":"1.4.252"}}}'
# A repo with three worktrees: the main checkout, an epic worktree, a child.
LIST='{"ok":true,"result":{"worktrees":[
  {"path":"/r","branch":"refs/heads/develop","id":"R::/r","isMainWorktree":true},
  {"path":"/w/epic","branch":"refs/heads/epic/AB-1_thing","id":"R::/w/epic"},
  {"path":"/w/kid","branch":"refs/heads/task/dev/AB-2-kid","id":"R::/w/kid"},
  {"path":"","branch":"refs/heads/broken","id":"R::"}
]}}'
CURRENT='{"ok":true,"result":{"worktree":{"path":"/w/kid","branch":"refs/heads/task/dev/AB-2-kid","id":"R::/w/kid"}}}'

# --- available ---------------------------------------------------------------
out=$(HI_ORCA="$stub/absent" bash "$O" available); rc=$?
assert_contains "available: missing CLI is unavailable" "$out" 'unavailable: orca CLI not on PATH'
assert_status   "available: missing CLI exits 1"        1 "$rc"

mkstub 'exit 1'
out=$(run available); rc=$?
assert_contains "available: failed status is unavailable" "$out" 'unavailable: orca status failed'
assert_status   "available: failed status exits 1"        1 "$rc"

mkstub 'echo "{\"ok\":false}"'
out=$(run available); rc=$?
assert_contains "available: ok=false is unavailable" "$out" 'ok=false'
assert_status   "available: ok=false exits 1"        1 "$rc"

mkstub 'echo '"'"'{"ok":true,"result":{"runtime":{"state":"starting","reachable":true}}}'"'"''
out=$(run available); rc=$?
assert_contains "available: non-ready runtime is degraded" "$out" 'degraded: orca runtime state is "starting"'
assert_status   "available: degraded exits 1"              1 "$rc"

# The desktop app being closed must NOT make Orca unavailable — only --activate needs it.
mkstub 'echo '"'"'{"ok":true,"result":{"app":{"running":false},"runtime":{"state":"ready","reachable":true,"appVersion":"1.4.252"}}}'"'"''
out=$(run available); rc=$?
assert_eq     "available: closed app is still ok" "ok" "$out"
assert_status "available: closed app exits 0"    0 "$rc"

# hi follows the current Orca: an older one is reported, not driven.
mkstub 'echo '"'"'{"ok":true,"result":{"runtime":{"state":"ready","reachable":true,"appVersion":"1.4.245"}}}'"'"''
out=$(run available); rc=$?
assert_contains "available: an Orca below the floor is outdated" "$out" 'outdated: Orca 1.4.245 is older than 1.4.246 — update Orca'
assert_status   "available: outdated exits 1" 1 "$rc"
mkstub 'echo '"'"'{"ok":true,"result":{"runtime":{"state":"ready","reachable":true}}}'"'"''
out=$(run available); rc=$?
assert_contains "available: no version reported is outdated" "$out" 'outdated: Orca (unknown)'
for v in 1.4.246 1.4.300 1.5.0 2.0.0; do
  mkstub 'echo '"'"'{"ok":true,"result":{"runtime":{"state":"ready","reachable":true,"appVersion":"'"$v"'"}}}'"'"''
  assert_eq "available: $v passes the floor" ok "$(run available)"
done
for v in 1.3.999 0.9.0 1.4.24; do
  mkstub 'echo '"'"'{"ok":true,"result":{"runtime":{"state":"ready","reachable":true,"appVersion":"'"$v"'"}}}'"'"''
  assert_contains "available: $v is below the floor" "$(run available)" outdated
done

mkstub "echo '$READY'"
out=$(run available); rc=$?
assert_eq     "available: ready runtime is ok" "ok" "$out"
assert_status "available: ready exits 0"      0 "$rc"

# --- current ----------------------------------------------------------------
mkstub "case \"\$*\" in 'worktree current --json') echo '$CURRENT' ;; esac"
out=$(run current); rc=$?
assert_eq     "current: TSV path/branch/id" \
  "/w/kid	task/dev/AB-2-kid	R::/w/kid" "$out"
assert_status "current: exits 0 in a worktree" 0 "$rc"
assert_not_contains "current: branch is short, not a full ref" "$out" 'refs/heads/'

# Not in an Orca worktree → exit 1 and NOTHING on stdout. An empty path must never
# reach a caller: `path:` / `git -C ""` silently target the current directory.
mkstub 'echo "{\"ok\":false}"'
out=$(run current); rc=$?
assert_eq     "current: no worktree prints nothing" "" "$out"
assert_status "current: no worktree exits 1"        1 "$rc"

mkstub 'echo '"'"'{"ok":true,"result":{"worktree":{"path":"","branch":"refs/heads/x"}}}'"'"''
out=$(run current); rc=$?
assert_eq     "current: empty path prints nothing" "" "$out"
assert_status "current: empty path exits 1"        1 "$rc"

out=$(HI_ORCA="$stub/absent" bash "$O" current); rc=$?
assert_eq     "current: no CLI prints nothing" "" "$out"
assert_status "current: no CLI exits 1"        1 "$rc"

# --- siblings ---------------------------------------------------------------
mkstub "case \"\$*\" in 'worktree list --repo path:/r --json') echo '$LIST' ;; esac"
out=$(run siblings /r); rc=$?
assert_status       "siblings: exits 0"                 0 "$rc"
assert_contains     "siblings: main checkout row"       "$out" '/r	develop	R::/r'
assert_contains     "siblings: epic row, ref stripped"  "$out" '/w/epic	epic/AB-1_thing	R::/w/epic'
assert_not_contains "siblings: no full refs"            "$out" 'refs/heads/'
assert_not_contains "siblings: empty-path row dropped"  "$out" 'broken'
n=$(printf '%s\n' "$out" | grep -c .)
assert_eq "siblings: three usable rows" "3" "$n"
UNCLIST='{"ok":true,"result":{"worktrees":[{"path":"\\\\wsl.localhost\\d\\w\\kid","branch":"refs/heads/k","id":"R::\\\\wsl.localhost\\d\\w\\kid"}]}}'
mkstub "case \"\$*\" in 'worktree list --repo path:/r --json') echo '$UNCLIST' ;; esac"
out=$(run siblings /r)
assert_eq "siblings: a UNC id comes out verbatim (single backslashes), path POSIX" \
  '/w/kid	k	R::\\wsl.localhost\d\w\kid' "$out"
mkstub "case \"\$*\" in 'worktree list --repo path:/r --json') echo '$LIST' ;; esac"   # find-branch below needs LIST

out=$(run siblings 2>/dev/null); rc=$?
assert_status "siblings: missing repo arg exits 2" 2 "$rc"

# --- find-branch ------------------------------------------------------------
out=$(run find-branch /r epic/AB-1_thing)
assert_eq "find-branch: short name matches" "/w/epic" "$out"
out=$(run find-branch /r refs/heads/epic/AB-1_thing)
assert_eq "find-branch: full ref matches the same worktree" "/w/epic" "$out"
out=$(run find-branch /r task/dev/AB-2-kid)
assert_eq "find-branch: child branch matches" "/w/kid" "$out"

out=$(run find-branch /r no/such/branch); rc=$?
assert_eq     "find-branch: miss prints nothing" "" "$out"
assert_status "find-branch: miss exits 1"        1 "$rc"

out=$(run find-branch /r 2>/dev/null); rc=$?
assert_status "find-branch: missing branch arg exits 2" 2 "$rc"

# --- create-cmd (prints, never runs) ----------------------------------------
# Runs with NO stub at all: it must not touch the CLI.
out=$(HI_ORCA="$stub/absent" bash "$O" create-cmd \
  --repo /r --name 'AB-2 kid work' --base epic/AB-1_thing \
  --parent 'branch:epic/AB-1_thing' --comment 'AB-2 Kid summary'); rc=$?
assert_status   "create-cmd: works with no Orca on PATH"  0 "$rc"
assert_contains "create-cmd: repo is a path: selector"    "$out" '--repo path:/r'
assert_contains "create-cmd: name is quoted"              "$out" "--name 'AB-2 kid work'"
assert_contains "create-cmd: base-branch from the base selection" "$out" '--base-branch epic/AB-1_thing'
assert_contains "create-cmd: forces setup hooks"          "$out" '--setup run'
assert_contains "create-cmd: parent lineage"              "$out" '--parent-worktree branch:epic/AB-1_thing'
assert_contains "create-cmd: comment carries the ticket key" "$out" "--comment 'AB-2 Kid summary'"
assert_contains "create-cmd: json output"                 "$out" '--json'
assert_not_contains "create-cmd: never adds --activate"   "$out" '--activate'

out=$(run create-cmd --repo /r --name wt --base develop --no-parent)
assert_contains     "create-cmd: standalone forces no lineage" "$out" '--no-parent'
assert_not_contains "create-cmd: no-parent has no selector"    "$out" '--parent-worktree'

# Exactly one of --parent/--no-parent is required: with neither, Orca infers the
# caller's worktree and a standalone ticket silently nests under it.
out=$(run create-cmd --repo /r --name wt --base develop 2>&1); rc=$?
assert_status   "create-cmd: neither parent flag exits 2" 2 "$rc"
assert_contains "create-cmd: names the inference risk"    "$out" 'Orca would infer one'

out=$(run create-cmd --repo /r --name wt --base develop --no-parent --parent active 2>&1); rc=$?
assert_status   "create-cmd: both parent flags exit 2" 2 "$rc"
assert_contains "create-cmd: says mutually exclusive"  "$out" 'mutually exclusive'

for miss in '--name wt --base develop --no-parent' \
            '--repo /r --base develop --no-parent' \
            '--repo /r --name wt --no-parent'; do
  # shellcheck disable=SC2086
  rc=0; run create-cmd $miss >/dev/null 2>&1 || rc=$?
  assert_status "create-cmd: missing a required flag exits 2 [$miss]" 2 "$rc"
done

out=$(run create-cmd --repo /r --name wt --base develop --no-parent --bogus x 2>&1); rc=$?
assert_status "create-cmd: unknown flag exits 2" 2 "$rc"

# --- create-cmd: a --repo VALUE that is already a selector passes through -------
# Orca's registered path is not always the caller's path: with the runtime on a
# Windows host and the checkout in WSL, the repo is registered as
# `\\wsl.localhost\<distro>\home\…` and `path:/home/…` answers repo_not_found. The
# caller must be able to hand over `id:<uuid>` instead.
for sel in 'id:44ff91c7-f40a-49c0-863e-fbd9a07d6c39' 'name:app' 'path:/already/prefixed'; do
  out=$(run create-cmd --repo "$sel" --name wt --base develop --no-parent)
  assert_contains     "create-cmd: [$sel] passes through verbatim" "$out" "--repo $sel"
  assert_not_contains "create-cmd: [$sel] is not double-prefixed"  "$out" "path:$sel"
done

# A bare scheme with no value is refused — an empty `path:` selector silently targets
# the caller's own cwd, which is the invariant at the top of lib/orca.sh.
for sel in 'path:' 'id:' 'name:'; do
  out=$(run create-cmd --repo "$sel" --name wt --base develop --no-parent 2>&1); rc=$?
  assert_status "create-cmd: bare [$sel] exits 2" 2 "$rc"
done

# --- repo-selector: resolve a POSIX path to id:<uuid> across the WSL boundary ---
REPOS='{"ok":true,"result":{"repos":[
  {"id":"aaa","path":"\\\\wsl.localhost\\Ubuntu\\home\\me\\src\\app"},
  {"id":"bbb","path":"\\\\wsl.localhost\\Ubuntu\\home\\me\\my\\skep"},
  {"id":"ccc","path":"/home/me/plain/posix"},
  {"id":"","path":"\\\\wsl.localhost\\Ubuntu\\home\\me\\nope"}
]}}'
mkstub "echo '$REPOS'"
out=$(run repo-selector /home/me/src/app); rc=$?
assert_status "repo-selector: UNC-registered repo resolves" 0 "$rc"
assert_eq     "repo-selector: prints id:<uuid>" "id:aaa" "$out"

out=$(run repo-selector /home/me/plain/posix)
assert_eq "repo-selector: a plainly-registered path also resolves" "id:ccc" "$out"

out=$(run repo-selector /home/me/src/app/ )
assert_eq "repo-selector: a trailing slash still matches" "id:aaa" "$out"

out=$(run repo-selector /home/me/app 2>/dev/null); rc=$?
assert_status "repo-selector: unregistered path exits 1" 1 "$rc"
assert_eq     "repo-selector: unregistered path prints nothing on stdout" "" "$out"

# Basename matching is deliberately NOT attempted: two checkouts named the same are
# indistinguishable, and guessing one would target the wrong repo.
out=$(run repo-selector /somewhere/else/app 2>/dev/null); rc=$?
assert_status "repo-selector: same basename elsewhere does not match" 1 "$rc"

DUPES='{"ok":true,"result":{"repos":[
  {"id":"aaa","path":"/home/me/src/app"},
  {"id":"zzz","path":"\\\\wsl.localhost\\Ubuntu\\home\\me\\src\\app"}
]}}'
mkstub "echo '$DUPES'"
out=$(run repo-selector /home/me/src/app 2>&1); rc=$?
assert_status   "repo-selector: 2+ matches refuses to guess" 1 "$rc"
assert_contains "repo-selector: says why"                    "$out" 'refusing to guess'

mkstub 'echo "{\"ok\":false}"'
out=$(run repo-selector /home/me/src/app 2>/dev/null); rc=$?
assert_status "repo-selector: ok=false exits 1" 1 "$rc"
assert_eq     "repo-selector: ok=false prints nothing on stdout" "" "$out"

out=$(HI_ORCA="$stub/absent" bash "$O" repo-selector /r 2>/dev/null); rc=$?
assert_status "repo-selector: no CLI exits 1" 1 "$rc"

# --- every path this file prints is a LOCAL path -------------------------------
# Orca reports paths as its own runtime sees them. On a Windows-host runtime with the
# checkout in WSL that is `\\wsl.localhost\<distro>\home\…`, and `git -C` on a UNC path
# fails outright — so `current` / `siblings` / `find-branch` must hand back the POSIX
# form. The worktree ID is a selector, not a path: it stays verbatim.
UNC_CURRENT='{"ok":true,"result":{"worktree":{
  "path":"\\\\wsl.localhost\\Ubuntu\\home\\me\\orca\\workspaces\\app\\AB-1018",
  "branch":"refs/heads/task/dev/AB-1018-cancel-webhook",
  "id":"R::\\\\wsl.localhost\\Ubuntu\\home\\me\\orca\\workspaces\\app\\AB-1018"}}}'
mkstub "echo '$UNC_CURRENT'"
out=$(run current)
assert_eq       "current: UNC path comes back POSIX" \
                "/home/me/orca/workspaces/app/AB-1018" "$(printf '%s' "$out" | cut -f1)"
assert_contains "current: the id keeps Orca's spelling" "$(printf '%s' "$out" | cut -f3)" 'wsl.localhost'

UNC_LIST='{"ok":true,"result":{"worktrees":[
  {"path":"\\\\wsl.localhost\\Ubuntu\\home\\me\\src\\app","branch":"refs/heads/develop","id":"R::a"},
  {"path":"\\\\wsl.localhost\\Ubuntu\\home\\me\\orca\\workspaces\\app\\AB-1018","branch":"refs/heads/task/dev/AB-1018-x","id":"R::b"},
  {"path":"/home/me/already/posix","branch":"refs/heads/other","id":"R::c"}
]}}'
mkstub "echo '$UNC_LIST'"
out=$(run siblings /r)
assert_contains "siblings: UNC paths come back POSIX" "$out" '/home/me/src/app'
assert_not_contains "siblings: no backslashes survive" "$out" 'wsl.localhost\'
assert_contains "siblings: an already-POSIX path is untouched" "$out" '/home/me/already/posix'
out=$(run find-branch /r task/dev/AB-1018-x)
assert_eq "find-branch: returns a path git can use" \
          "/home/me/orca/workspaces/app/AB-1018" "$out"

# `posix` is the same conversion for a caller that parsed Orca's JSON itself —
# A skill runs the create line and reads the response in the skill.
out=$(HI_ORCA="$stub/absent" bash "$O" posix \
        '\\wsl.localhost\Ubuntu\home\me\orca\workspaces\app\AB-1018'); rc=$?
assert_status "posix: needs no Orca binary" 0 "$rc"
assert_eq     "posix: UNC becomes POSIX" \
              "/home/me/orca/workspaces/app/AB-1018" "$out"
out=$(bash "$O" posix '/home/me/already/posix')
assert_eq "posix: a POSIX path is untouched" "/home/me/already/posix" "$out"
out=$(bash "$O" posix '/tmp/a b/c')
assert_eq "posix: spaces survive" "/tmp/a b/c" "$out"
# A Windows drive path is unreachable from here under ANY spelling — mangling it would
# hide the failure the caller's `-d` check reports honestly.
out=$(bash "$O" posix 'C:\Users\me\repo')
assert_eq "posix: a drive path is left alone" 'C:\Users\me\repo' "$out"

# --- dispatcher -------------------------------------------------------------
out=$(run bogus 2>&1); rc=$?
assert_status   "unknown subcommand exits 2" 2 "$rc"
assert_contains "usage names every subcommand" "$out" 'available|current|siblings'

# --- orphaned ---------------------------------------------------
# /w/a: orphaned only → listed. /w/b: orphaned plus a live agent → not. /w/c: a live shell
# with no agent and no orphan → not. A UNC path is compared as POSIX.
TL='{"ok":true,"result":{"terminals":[
  {"handle":"t1","worktreePath":"/w/a","connected":true,"writable":true,"agentIdentity":null,"orphaned":true},
  {"handle":"t2","worktreePath":"/w/b","connected":true,"writable":true,"agentIdentity":null,"orphaned":true},
  {"handle":"t3","worktreePath":"/w/b","connected":true,"writable":true,"agentIdentity":"claude","orphaned":false},
  {"handle":"t4","worktreePath":"/w/c","connected":true,"writable":true,"agentIdentity":null,"orphaned":false},
  {"handle":"t5","worktreePath":"\\\\wsl.localhost\\Ubuntu\\w\\d","connected":true,"writable":true,"agentIdentity":null,"orphaned":true}
]}}'
printf '%s' "$TL" > "$stub/tl.json"
mkstub "case \"\$*\" in 'status --json') echo '$READY' ;; 'terminal list --json') cat '$stub/tl.json' ;; esac"
out=$(run orphaned); rc=$?
assert_status "orphaned: exits 0" 0 "$rc"
assert_eq "orphaned: only the workspaces with an orphan and no live agent" "/w/a
/w/d" "$out"
mkstub 'exit 1'
run orphaned >/dev/null 2>&1; assert_status "orphaned: no Orca exits 1" 1 "$?"

# --- agents -----------------------------------------------------------------
# /w/a (UNC in ps): an agent terminal Orca calls idle, one it calls working, one with no ps
# row, a bare shell, and a working chat. /w/b: a done chat. /w/c: nothing.
TL='{"ok":true,"result":{"terminals":[
  {"handle":"t1","worktreePath":"/w/a","connected":true,"writable":true,"agentIdentity":"claude","tabId":"A","leafId":"1"},
  {"handle":"t2","worktreePath":"/w/a","connected":true,"writable":true,"agentIdentity":"claude","tabId":"B","leafId":"2"},
  {"handle":"t3","worktreePath":"/w/a","connected":true,"writable":true,"agentIdentity":"codex","tabId":"C","leafId":"3"},
  {"handle":"t4","worktreePath":"/w/a","connected":true,"writable":true,"agentIdentity":null,"tabId":"D","leafId":"4"},
  {"handle":"t5","worktreePath":"/w/b","connected":false,"writable":true,"agentIdentity":"claude","tabId":"E","leafId":"5"}
]}}'
PS='{"ok":true,"result":{"worktrees":[
  {"path":"\\\\wsl.localhost\\Ubuntu\\w\\a","agents":[
    {"paneKey":"A:1","state":"done","programStatus":{"state":"idle"}},
    {"paneKey":"B:2","state":"done","programStatus":{"state":"working"}},
    {"paneKey":"structured-agent-session-claude_1:tab1","state":"working"}]},
  {"path":"/w/b","agents":[{"paneKey":"structured-agent-session-claude_3:tab3","state":"done"}]},
  {"path":"/w/c"}
]}}'
printf '%s' "$TL" > "$stub/tl.json"; printf '%s' "$PS" > "$stub/ps.json"
mkstub "case \"\$*\" in 'status --json') echo '$READY' ;; 'terminal list --json') cat '$stub/tl.json' ;; 'worktree ps --limit 10000 --json') cat '$stub/ps.json' ;; esac"
out=$(run agents /w/a); rc=$?
assert_status "agents: exits 0" 0 "$rc"
assert_eq "agents: terminals by Orca's status (no row → unknown), no shell, the chat" "t1	terminal	idle
t2	terminal	busy
t3	terminal	unknown
structured-agent-session-claude_1	chat	busy" "$out"
assert_eq "agents: a done chat is idle; a disconnected terminal is not listed" "structured-agent-session-claude_3	chat	idle" "$(run agents /w/b)"
assert_eq "agents: no agents" "" "$(run agents /w/c)"
run agents >/dev/null 2>&1; assert_status "agents: no path is 2" 2 "$?"
mkstub "case \"\$*\" in 'status --json') echo '$READY' ;; 'terminal list --json') cat '$stub/tl.json' ;; *) exit 1 ;; esac"
assert_eq "agents: no worktree ps → every terminal unknown, no chats" "t1	terminal	unknown
t2	terminal	unknown
t3	terminal	unknown" "$(run agents /w/a)"
mkstub 'exit 1'
run agents /w/a >/dev/null 2>&1; assert_status "agents: no Orca exits 1" 1 "$?"

rm -rf "$stub"
assert_summary
