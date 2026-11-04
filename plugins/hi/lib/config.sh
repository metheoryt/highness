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
# A key set in the repo file wins over the user file; `list` concatenates the arrays of both
# (repo first), which is how deny patterns from a team and from one person add up.
#
#   config.sh get [--user] <jq-path>    the value (raw for strings); exit 1 when unset
#   config.sh list [--user] <jq-path>   one array element per line from both files; nothing when unset
#   config.sh files [--user]            the files that exist, repo first
#
# --user reads the user file only. A key that runs code or switches a protection off must be read
# with it: the repo file comes with any clone, so trusting it would let a cloned repo decide.
#
# A missing jq, an unreadable or invalid file: treated as unset, never an error on stdout.
set -uo pipefail

USER_ONLY=0
_files() {
  local top user
  if [ "$USER_ONLY" = 0 ]; then
    top=$(git rev-parse --show-toplevel 2>/dev/null) || top=''
    [ -n "$top" ] && [ -f "$top/.claude/highness.json" ] && printf '%s\n' "$top/.claude/highness.json"
  fi
  user=${HIGHNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/highness/config.json}
  [ -f "$user" ] && printf '%s\n' "$user"
  return 0
}

_get() {
  local f v
  command -v jq >/dev/null 2>&1 || return 1
  while IFS= read -r f; do
    v=$(jq -er "$1 | select(. != null)" "$f" 2>/dev/null) || continue
    printf '%s\n' "$v"
    return 0
  done <<EOF
$(_files)
EOF
  return 1
}

_list() {
  local f
  command -v jq >/dev/null 2>&1 || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    jq -r "($1 // []) | if type == \"array\" then .[] else empty end | tostring" "$f" 2>/dev/null
  done <<EOF
$(_files)
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
