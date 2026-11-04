#!/usr/bin/env bash
# lib/wt.sh in an umbrella repo: create refuses there, --repo works on a nested clone, the
# nested workspace's parent is the clone (never the umbrella), the cwd guards still read
# the caller's own cwd, and a workspace of the umbrella works on the main checkout's clones.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }

# The umbrella U holds repos.txt and one nested clone, app, with a bare origin of its own.
U="$SANDBOX/umb"; git init -q -b main "$U"
printf 'app git@github.com:someone/app.git\n' > "$U/repos.txt"
git -C "$U" add repos.txt && git -C "$U" commit -q -m init
UP="$SANDBOX/up.git"; git init -q --bare "$UP"
A="$U/app"; git init -q -b main "$A"
git -C "$A" commit -q --allow-empty -m base
git -C "$A" remote add origin "$UP"
git -C "$A" push -q origin main
git -C "$A" remote set-head origin main >/dev/null
export FX_REPO="$A"
cd "$U"

out=$(bash "$WT" create --kind work --key spike --name 'spike' --base main --branch work/spike 2>"$SANDBOX/err"); rc=$?
assert_status "umbrella: create refused, exit 2" 2 "$rc"
assert_contains "umbrella: says where workspaces go" "$(cat "$SANDBOX/err")" "gets that clone's workspace"
assert_contains "umbrella: names --repo" "$(cat "$SANDBOX/err")" "--repo <clone>"
assert_eq "umbrella: no worktree made in the umbrella" 1 "$(git -C "$U" worktree list | wc -l | tr -d ' ')"
assert_eq "umbrella: no record in the umbrella" no "$([ -d "$U/.git/hi" ] && echo yes || echo no)"
bash "$WT" --repo "$U" create --kind work --key spike --name 'spike' --base main --branch work/spike >/dev/null 2>&1
assert_status "umbrella: --repo at the umbrella itself is refused too" 2 "$?"
assert_contains "umbrella: the refusal names the way out" "$(cat "$SANDBOX/err")" "create --umbrella"
bash "$WT" create --help >/dev/null 2>&1
assert_status "umbrella: create --help is not refused" 0 "$?"
bash "$WT" list >/dev/null 2>"$SANDBOX/err"
assert_status "umbrella: list still runs" 0 "$?"
assert_contains "umbrella: list says it shows only the umbrella's own" "$(cat "$SANDBOX/err")" "lists only its own workspaces"
assert_contains "umbrella: list names the clones" "$(cat "$SANDBOX/err")" "(clones: app)"
assert_eq "umbrella: a nested clone's list has no hint" "" "$(bash "$WT" --repo "$A" list 2>&1 >/dev/null)"


out=$(bash "$WT" --repo "$A" create --kind work --key spike --name 'spike' --base main --branch work/spike 2>"$SANDBOX/err"); rc=$?
assert_status "--repo clone: create exit 0" 0 "$rc"
W=$(col "$out" 1)
assert_eq "--repo clone: the workspace is the clone's" "$SANDBOX/wt/app/spike" "$W"
assert_eq "--repo clone: parent is the clone's main checkout, not the umbrella" "$A" "$(col "$out" 8)"
assert_eq "--repo clone: record parent" "$A" "$(cd "$A" && bash "$WT" rec get --work spike parent)"
assert_eq "--repo clone: record in the clone's git dir" yes "$([ -f "$A/.git/hi/work-spike.md" ] && echo yes || echo no)"
assert_eq "--repo clone: nothing in the umbrella's git dir" no "$([ -d "$U/.git/hi" ] && echo yes || echo no)"
assert_contains "--repo: list from the umbrella sees it" "$(bash "$WT" --repo "$A" list)" "$W"

# dispatch from the umbrella root: the workspace path names its own clone, no --repo
printf 'brief\n' > "$SANDBOX/brief.md"
out=$(HI_TMUX=none bash "$WT" dispatch "$W" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "dispatch from the umbrella: exit 0" 0 "$rc"
assert_contains "dispatch from the umbrella: prints the clone's workspace" "$out" "cd $W && "
assert_eq "dispatch from the umbrella: brief in the clone's store" yes "$([ -f "$A/.git/hi/briefs/spike.md" ] && echo yes || echo no)"
assert_eq "dispatch from the umbrella: session recorded in the clone" "$(printf "%s\n" "$out" | head -1 | cut -f1)" "$(cd "$A" && bash "$WT" rec get --work spike session)"
assert_eq "dispatch from the umbrella: nothing in the umbrella's git dir" no "$([ -d "$U/.git/hi" ] && echo yes || echo no)"
out=$(cd "$SANDBOX/wt/app" && HI_TMUX=none bash "$WT" dispatch spike --brief "$SANDBOX/brief.md" 2>/dev/null); rc=$?
assert_status "dispatch from outside any repo: a relative path works too" 0 "$rc"
HI_TMUX=none bash "$WT" dispatch "$A" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "dispatch from the umbrella: the clone's main checkout is still not a workspace" 1 "$?"

bash "$WT" --repo "$A" create --kind work --key spike2 --name 'spike2' --base main --branch work/spike2 --parent "$U" >/dev/null 2>"$SANDBOX/err"
assert_status "--parent at the umbrella is refused" 2 "$?"
assert_contains "--parent at the umbrella: not a workspace of this repo" "$(cat "$SANDBOX/err")" "is not a workspace of this repo"
bash "$WT" --repo "$SANDBOX/nowhere" list >/dev/null 2>&1
assert_status "--repo: a missing directory → exit 2" 2 "$?"

# The cwd guards read the caller's cwd, not the --repo directory.
out=$(cd "$W" && bash "$WT" --repo "$A" remove-if-safe "$W" 2>&1); rc=$?
assert_status "cwd guard: a session inside the workspace cannot remove it via --repo" 2 "$rc"
assert_contains "cwd guard: says so" "$out" "this session is inside it"
assert_contains "cwd guard: list --state flags cwd via --repo" "$(cd "$W" && bash "$WT" --repo "$A" list --state | cut -f18)" "cwd"
assert_not_contains "cwd guard: from the umbrella it is not the cwd" "$(bash "$WT" --repo "$A" list --state | cut -f18)" "cwd"

# Orca: the default parent resolves to the clone's main checkout as Orca lists it.
orca_on; reset_log
out=$(bash "$WT" --repo "$A" create --kind work --key orca-spike --name 'orca spike' --base main --branch work/orca-spike 2>"$SANDBOX/err"); rc=$?
assert_status "orca: --repo clone create exit 0" 0 "$rc"
assert_eq "orca: parent is the clone" "$A" "$(col "$out" 8)"
assert_contains "orca: parent passed as the clone's Orca id" "$(logged)" \
  "--parent-worktree id:R::\\\\wsl.localhost\\d$(printf '%s' "$A" | tr '/' '\\');"
orca_off

# --umbrella: a change to the umbrella's own files gets a workspace of the umbrella itself
out=$(bash "$WT" create --umbrella --kind work --key repos --name 'repos' --base main --branch work/repos 2>"$SANDBOX/err"); rc=$?
assert_status "--umbrella: create exit 0" 0 "$rc"
UW=$(col "$out" 1)
assert_eq "--umbrella: the workspace is the umbrella's" "$SANDBOX/wt/umb/repos" "$UW"
assert_eq "--umbrella: parent is the umbrella's main checkout" "$U" "$(col "$out" 8)"
assert_eq "--umbrella: it carries the umbrella's files" yes "$([ -f "$UW/repos.txt" ] && echo yes || echo no)"
assert_eq "nested made from the main checkout: no umbrella field" "" "$(cd "$A" && bash "$WT" rec get --work spike umbrella 2>/dev/null)"

# From a workspace of the umbrella: it sees the main checkout's clones, makes a nested
# workspace the same way, and the nested one records which umbrella workspace it came from.
UMB_SH="$(cd "$HERE/../lib" && pwd)/umbrella.sh"
C=$(cd "$UW" && bash "$UMB_SH" repos | cut -f1)
assert_eq "umbrella workspace: repos lists the main checkout's clone" "$A" "$C"
out=$(cd "$UW" && bash "$WT" create --kind work --key x --name x --base main --branch work/x 2>&1); rc=$?
assert_status "umbrella workspace: a plain create is still refused" 2 "$rc"
out=$(cd "$UW" && bash "$WT" --repo "$C" create --kind work --key nested --name 'nested' --base main --branch work/nested 2>"$SANDBOX/err"); rc=$?
assert_status "umbrella workspace: --repo clone create exit 0" 0 "$rc"
assert_eq "umbrella workspace: the nested workspace is the clone's" "$SANDBOX/wt/app/nested" "$(col "$out" 1)"
assert_eq "umbrella workspace: parent is still the clone's main checkout" "$A" "$(col "$out" 8)"
assert_eq "umbrella workspace: the nested record names the umbrella workspace" "$UW" \
  "$(cd "$A" && bash "$WT" rec get --work nested umbrella)"
out=$(cd "$UW" && bash "$WT" create --umbrella --kind work --key repos2 --name 'repos2' --base main --branch work/repos2 2>/dev/null); rc=$?
assert_status "umbrella workspace: create --umbrella from it exit 0" 0 "$rc"
assert_eq "umbrella workspace: an umbrella workspace gets no umbrella field" "" \
  "$(cd "$U" && bash "$WT" rec get --work repos2 umbrella 2>/dev/null)"

# A per-clone loop feeds its clones on stdin; no verb may read it (a sweep over
# the clones ran only the first). Every gh and orca call here drains stdin, as a real one may.
DRAIN="$SANDBOX/orca-drain"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexec "%s" "$@"\n' "$STUB/orca" > "$DRAIN"; chmod +x "$DRAIN"
touch "$FX/gh.drain"; orca_on
for b in orca git; do
[ "$b" = git ] && orca_off
for v in sweep waiting list board; do
  ran=$(printf '%s\n%s\n' "$A" "$A" | while IFS= read -r c; do
    HI_ORCA="$DRAIN" bash "$WT" --repo "$c" "$v" >/dev/null 2>&1; echo ran; done | grep -c ran)
  assert_eq "stdin ($b): $v in a per-clone loop leaves the rows to the loop" 2 "$ran"
done
done
# board - takes its own rows on stdin: still read, past an orca that drains stdin.
orca_on
out=$(printf '%s\tdone\n' "$SANDBOX/nowhere" | HI_ORCA="$DRAIN" bash "$WT" --repo "$A" board - 2>&1)
assert_contains "stdin: board - still reads its rows" "$out" "no workspace at $SANDBOX/nowhere"
orca_off
rm -f "$FX/gh.drain"

bash "$WT" remove "$UW" >/dev/null 2>&1
assert_status "--umbrella: removable as usual" 0 "$?"
assert_summary
