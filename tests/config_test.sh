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
exit $fail
