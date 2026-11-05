#!/usr/bin/env bash
# config.sh — highness configuration, read by every highness plugin.
#
# Each plugin ships its own byte-identical copy at plugins/<name>/lib/config.sh (a plugin is
# installed on its own, so it cannot reach a sibling's files); tests/config_copies_test.sh keeps
# the copies equal to shared/config.sh, the one to edit.
#
# Two JSON files, both optional:
#   user   ${HIGHNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/highness/config.json}
#   repo   <git toplevel of the cwd>/.claude/highness.json   (committed by a team)
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
#   config.sh files [--user]            the files that exist, repo first
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

_files() {
  local top user
  if [ "$USER_ONLY" = 0 ]; then
    top=$(git rev-parse --show-toplevel 2>/dev/null) || top=''
    [ -n "$top" ] && [ -f "$top/.claude/highness.json" ] && printf '%s\n' "$top/.claude/highness.json"
  fi
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
  files) _files ;;
  *) echo 'usage: config.sh get|list [--user] <jq-path> | files [--user]' >&2; exit 2 ;;
esac
