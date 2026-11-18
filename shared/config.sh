#!/usr/bin/env bash
# config.sh — highness configuration, read by every highness plugin.
#
# Each plugin ships its own byte-identical copy at plugins/<name>/lib/config.sh (a plugin is
# installed on its own, so it cannot reach a sibling's files); tests/config_copies_test.sh keeps
# the copies equal to shared/config.sh, the one to edit.
#
# Two JSON files, both optional:
#   user   ${HIGHNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/highness/config.json}
#   repo   <git toplevel of the cwd>/.claude/highness.json   (committed by a team); when the
#          toplevel has none, the file of the nearest umbrella above the clone: a directory with
#          .claude/highness.json and a repos.txt that lists the clone (relative to it, or to its
#          `umbrella.dir`; see hi's lib/umbrella.sh). A clone the umbrella does not list gets none.
# The user file may also hold per-repo overlays, for repos a team cannot or will not commit a
# file to: `repos.<owner/repo>` and `repos.<owner>`, keyed by the cwd's `origin` (host ignored,
# lowercase, no .git), each an object of the same keys:
#   {"repos": {"acme": {"docs": {"conventions": "~/notes/acme-docs.md"}}}}
# A key is taken from the first source that sets it: repo file, user `repos.<owner/repo>`, user
# `repos.<owner>`, user top level. `list` concatenates the arrays of all of them in that order,
# which is how deny patterns from a team and from one person add up.
#
#   config.sh get [--user] <jq-path>    the value (raw for strings); exit 1 when unset
#   config.sh list [--user] <jq-path>   one array element per line from both files; nothing when unset
#   config.sh has [--user] <jq-path>    the file that sets the key, even to null (how a person says
#                                       "leave it to the default" on purpose); exit 1 when no source does
#   config.sh files [--user]            the files that exist, repo first
#   config.sh root                      the directory whose team file applies here (the toplevel, or
#                                       the umbrella), physical path; exit 1 when no team file does
#
# --user reads the user file's top level only. A key that runs code or switches a protection off
# must be read with it: the repo file comes with any clone, so trusting it would let a cloned repo
# decide, and an overlay is chosen by a remote name any host can carry.
#
# A missing jq, an unreadable or invalid file: treated as unset, never an error on stdout.
set -uo pipefail

USER_ONLY=0
_user_file() { printf '%s\n' "${HIGHNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/highness/config.json}"; }

# owner/repo of the cwd's origin, lowercase: git@host:o/r(.git), ssh://…/o/r, https://…/o/r.
_origin() {
  local u
  u=$(git config --get remote.origin.url 2>/dev/null) || return 1
  u=${u%/}; u=${u%.git}; u=${u##*:}
  printf '%s\n' "$u" | awk -F/ 'NF >= 2 { print tolower($(NF-1) "/" $NF) }'
}

# Whether <umbrella dir>/repos.txt lists the clone at <physical path>: a `<dir> [url]` line whose dir,
# relative to the umbrella dir or to its `umbrella.dir` (umbrella.sh's rules), is that path.
_lists() {
  local up=$1 clone=$2 base sub dir rest p
  base=$up
  sub=$(jq -r '.umbrella.dir // empty | strings' "$up/.claude/highness.json" 2>/dev/null) || sub=''
  sub=${sub%/}
  case "$sub" in ''|.) ;; /*) base=$sub ;; *) base="$up/$sub" ;; esac
  while read -r dir rest || [ -n "$dir" ]; do
    dir=${dir%$'\r'}
    case "$dir" in ''|'#'*) continue ;; esac
    dir=${dir%/}
    case "$dir" in /*) p=$dir ;; *) p="$base/$dir" ;; esac
    [ -d "$p" ] || continue
    p=$(cd "$p" 2>/dev/null && pwd -P) || continue
    [ "$p" = "$clone" ] && [ "$p" != "$up" ] && return 0
  done < "$up/repos.txt"
  return 1
}

# The team file: the git toplevel's .claude/highness.json; when it has none, the file of the nearest
# umbrella above the clone that lists it. The clone is the toplevel's main checkout (the one that
# repos.txt names), so a linked worktree of a child clone resolves to the same umbrella. File tests
# only on the way up: most repos have no team file, and every highness hook reads the config.
_team_file() {
  local out top common clone up
  out=$(git rev-parse --show-toplevel --git-common-dir 2>/dev/null) || return 1
  top=$(printf '%s\n' "$out" | sed -n 1p); common=$(printf '%s\n' "$out" | sed -n 2p)
  [ -n "$top" ] || return 1
  [ -f "$top/.claude/highness.json" ] && { printf '%s\n' "$top/.claude/highness.json"; return 0; }
  command -v jq >/dev/null 2>&1 || return 1
  case "$common" in /*) ;; *) common="$(pwd)/$common" ;; esac
  case "$common" in */.git) clone=${common%/.git} ;; *) clone=$top ;; esac
  clone=$(cd "$clone" 2>/dev/null && pwd -P) || return 1
  up=$clone
  while [ "$up" != / ] && [ -n "$up" ]; do
    up=$(dirname "$up")
    [ -f "$up/repos.txt" ] && [ -f "$up/.claude/highness.json" ] && _lists "$up" "$clone" \
      && _is_umbrella "$up" && { printf '%s\n' "$up/.claude/highness.json"; return 0; }
  done
  return 1
}

# An umbrella is a checkout of its own (repos.txt at a git toplevel, as umbrella.sh marks it), and
# its two files are the person's: a repo file's keys run commands, so a planted /tmp/repos.txt with
# a file beside it must not decide for a clone under /tmp.
_is_umbrella() {
  local t
  [ -O "$1/repos.txt" ] && [ -O "$1/.claude/highness.json" ] || return 1
  t=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$(cd "$t" 2>/dev/null && pwd -P)" = "$1" ]
}

_files() {
  local user
  [ "$USER_ONLY" = 0 ] && _team_file
  user=$(_user_file)
  [ -f "$user" ] && printf '%s\n' "$user"
  return 0
}

# Sources in precedence order, one per line: <file><TAB><jq path to the object holding the keys>.
_sources() {
  local f user o
  user=$(_user_file)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$f" = "$user" ] && [ "$USER_ONLY" = 0 ] && o=$(_origin) && [ -n "$o" ]; then
      printf '%s\t.repos[%s]\n' "$f" "$(printf '%s' "$o" | jq -R .)"
      printf '%s\t.repos[%s]\n' "$f" "$(printf '%s' "${o%%/*}" | jq -R .)"
    fi
    printf '%s\t.\n' "$f"
  done <<EOF
$(_files)
EOF
}

_get() {
  local f base v
  command -v jq >/dev/null 2>&1 || return 1
  while IFS="$(printf '\t')" read -r f base; do
    [ -n "$f" ] || continue
    v=$(jq -er "($base // {}) | $1 | select(. != null)" "$f" 2>/dev/null) || continue
    printf '%s\n' "$v"
    return 0
  done <<EOF
$(_sources)
EOF
  return 1
}

# A key set to null counts here, unlike _get: `(path(<p>)) as $q | getpath($q[:-1]) | has(last)`.
_has() {
  local f base
  command -v jq >/dev/null 2>&1 || return 1
  while IFS="$(printf '\t')" read -r f base; do
    [ -n "$f" ] || continue
    jq -e "($base // {}) as \$o | (try path($1) catch null) as \$q
           | (\$q != null) and (\$q | length) > 0
             and ((\$o | getpath(\$q[:-1])) as \$p | (\$p | type) == \"object\" and (\$p | has(\$q[-1])))" \
      "$f" >/dev/null 2>&1 || continue
    printf '%s\n' "$f"
    return 0
  done <<EOF
$(_sources)
EOF
  return 1
}

_list() {
  local f base
  command -v jq >/dev/null 2>&1 || return 0
  while IFS="$(printf '\t')" read -r f base; do
    [ -n "$f" ] || continue
    jq -r "($base // {}) | ($1 // []) | if type == \"array\" then .[] else empty end | tostring" "$f" 2>/dev/null
  done <<EOF
$(_sources)
EOF
  return 0
}

cmd=${1:-}; [ $# -gt 0 ] && shift
[ "${1:-}" = --user ] && { USER_ONLY=1; shift; }
set -- "$cmd" "$@"
case "${1:-}" in
  get)   [ -n "${2:-}" ] || { echo 'usage: config.sh get [--user] <jq-path>' >&2; exit 2; }; _get "$2" ;;
  list)  [ -n "${2:-}" ] || { echo 'usage: config.sh list [--user] <jq-path>' >&2; exit 2; }; _list "$2" ;;
  has)   [ -n "${2:-}" ] || { echo 'usage: config.sh has [--user] <jq-path>' >&2; exit 2; }; _has "$2" ;;
  files) _files ;;
  root)  f=$(_team_file) || exit 1; d=${f%/.claude/highness.json}; (cd "$d" && pwd -P) ;;
  *) echo 'usage: config.sh get|list|has [--user] <jq-path> | files [--user] | root' >&2; exit 2 ;;
esac
