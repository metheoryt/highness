#!/usr/bin/env bash
# shared/config.sh: repo file over user overlays over the user top level; --user reads the top level only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="$ROOT/shared/config.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: got [$2] want [$3]"; fail=1; fi; }
export HIGHNESS_CONFIG="$T/user.json"
cat >"$HIGHNESS_CONFIG" <<'JSON'
{"x": "top", "deny": ["u"],
 "repos": {"acme": {"x": "owner", "deny": ["o"]},
           "acme/shop": {"x": "repo", "deny": ["r"]}}}
JSON
repo() { mkdir -p "$T/$1" && git -C "$T/$1" init -q && git -C "$T/$1" remote add origin "$2"; }
repo shop   'git@github.com:Acme/Shop.git'
repo other  'https://git.example.org/acme/other'
repo ssh    'ssh://git@host:2222/acme/shop.git'
repo mine   'git@github.com:someone/thing.git'
mkdir -p "$T/plain"
g() { (cd "$T/$1" && bash "$C" "${@:2}"); }

check 'owner/repo overlay wins over owner and top'      "$(g shop get .x)"  repo
check 'owner overlay for another repo of the owner'     "$(g other get .x)" owner
check 'ssh:// url with a port parses'                   "$(g ssh get .x)"   repo
check 'no overlay for an unrelated origin'              "$(g mine get .x)"  top
check 'outside a repo: top level'                       "$(g plain get .x)" top
check '--user ignores overlays'                         "$(g shop get --user .x)" top
check 'list adds up overlays then top'                  "$(g shop list .deny | tr '\n' ' ')" 'r o u '
mkdir -p "$T/shop/.claude" && printf '{"x":"team","deny":["t"]}' >"$T/shop/.claude/highness.json"
check 'repo file wins over every overlay'               "$(g shop get .x)"  team
check 'list: repo file first'                           "$(g shop list .deny | tr '\n' ' ')" 't r o u '
if g mine get .nothing >/dev/null; then check 'unset key exits 1' set unset; else check 'unset key exits 1' unset unset; fi

# has: a key set to null counts (a person leaving it to the default on purpose); get does not see it.
cat >"$T/user2.json" <<'JSON'
{"crew": {"model": null}, "repos": {"acme": {"crew": {"agent": null}}}}
JSON
h() { (cd "$T/$1" && HIGHNESS_CONFIG="$T/user2.json" bash "$C" has "$2" >/dev/null); }
if h mine .crew.model; then check 'has: a key set to null' yes yes; else check 'has: a key set to null' no yes; fi
if (cd "$T/mine" && HIGHNESS_CONFIG="$T/user2.json" bash "$C" get .crew.model >/dev/null); then check 'get: null reads unset' set unset; else check 'get: null reads unset' unset unset; fi
if h mine .crew.agent; then check 'has: an absent key' yes no; else check 'has: an absent key' no no; fi
if h other .crew.agent; then check 'has: through an owner overlay' yes yes; else check 'has: through an owner overlay' no yes; fi
if h mine .nothing.deeper; then check 'has: under an absent parent' yes no; else check 'has: under an absent parent' no no; fi

# An umbrella: a checkout with the team file and a repos.txt listing the clones inside it. A child
# clone with no file of its own takes the umbrella's; one the umbrella does not list takes none.
U="$T/umb"; repo umb 'git@github.com:someone/umb.git'
mkdir -p "$U/.claude" && printf '{"x":"umbrella","deny":["m"]}' >"$U/.claude/highness.json"
printf '# clones\nlisted/ git@github.com:someone/listed.git\r\n\nmine git@github.com:someone/mine2.git\n' >"$U/repos.txt"
repo umb/listed   'git@github.com:someone/listed.git'
repo umb/unlisted 'git@github.com:someone/unlisted.git'
repo umb/mine     'git@github.com:someone/mine2.git'
mkdir -p "$U/listed/src" "$U/mine/.claude" && printf '{"x":"own"}' >"$U/mine/.claude/highness.json"
UP=$(cd "$U" && pwd -P)
check 'umbrella: a listed child clone takes its file'   "$(g umb/listed get .x)" umbrella
check 'umbrella: from a subdirectory of the clone too'  "$(g umb/listed/src get .x)" umbrella
check 'umbrella: files names it'                        "$(g umb/listed files | head -1)" "$UP/.claude/highness.json"
check 'umbrella: root is the umbrella'                  "$(g umb/listed root)" "$UP"
check 'umbrella: an unlisted clone takes none'          "$(g umb/unlisted get .x)" top
if g umb/unlisted root >/dev/null; then check 'umbrella: unlisted root exits 1' 0 1; else check 'umbrella: unlisted root exits 1' 1 1; fi
check "umbrella: a clone's own file wins"               "$(g umb/mine get .x)" own
check 'umbrella: root of a clone with its own file'     "$(g umb/mine root)" "$(cd "$U/mine" && pwd -P)"
check '--user ignores the umbrella file'                "$(g umb/listed get --user .x)" top
check 'umbrella: root itself takes its own file'        "$(g umb get .x)" umbrella
# A linked worktree of the child clone, made elsewhere: its main checkout is the listed clone.
git -C "$U/listed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$U/listed" worktree add -q "$T/listed-wt" 2>/dev/null
check "umbrella: a worktree of a listed clone takes it" "$(g listed-wt get .x)" umbrella
# umbrella.dir: the listed dirs live under a subdirectory the umbrella's file names.
V="$T/umb2"; repo umb2 'git@github.com:someone/umb2.git'
mkdir -p "$V/.claude" "$V/repos" && printf '{"x":"umbrella2","umbrella":{"dir":"repos/"}}' >"$V/.claude/highness.json"
printf 'api git@github.com:someone/api.git\n' >"$V/repos.txt"
repo umb2/repos/api 'git@github.com:someone/api.git'
repo umb2/api       'git@github.com:someone/api.git'
check 'umbrella.dir: a clone under it takes the file'   "$(g umb2/repos/api get .x)" umbrella2
check 'umbrella.dir: the same name beside it does not'  "$(g umb2/api get .x)" top
exit $fail
