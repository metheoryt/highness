#!/usr/bin/env bash
# tab-title.sh — name this session's Orca tab after the work in it.
#
#   tab-title.sh set <title>   rename this session's tab (a terminal tab or a chat tab)
#   tab-title.sh context       the SessionStart hook (hooks/hooks.json): print the naming rule
#                              into the session's context, only when the session runs in Orca
#
# Orca's own auto-generated titles name a tab after what was typed first, so a session opened
# with a skill keeps that skill's name ("agenda") whatever it goes on to do. The agent knows what
# the work is; this lets it say so.
#
# The terminal is always named explicitly (--terminal "$ORCA_TERMINAL_HANDLE"). Orca's default
# target when --terminal is left out is not this session's tab: measured on Orca 1.4.271, it
# renamed a neighbouring tab.
#
# A tab opened from ANOTHER Orca window (one Orca using this host as its remote server) is
# `orphaned` in this host's runtime: the rename is stored here but that window does not redraw
# it (measured 2026-11-23, Orca 1.4.271). `set` says so on stderr; there is nothing else to do.
#
# Never fails the session: outside Orca, or when Orca refuses, `set` prints one line to stderr
# and exits 0, and `context` prints nothing. HI_ORCA overrides the binary (tests stub it).
set -u
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *UTF-8*|*utf8*|*UTF8*|*utf-8*) ;; *) if [ "$(uname -s 2>/dev/null)" = Darwin ]; then export LC_ALL=en_US.UTF-8; else export LC_ALL=C.UTF-8; fi ;; esac
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MAX=60

in_orca() { [ -n "${ORCA_TERMINAL_HANDLE:-}" ] || [ -n "${ORCA_WORKTREE_ID:-}" ]; }

cmd_set() {
  local title="$*" o out
  title=$(printf '%s' "$title" | tr '\n\t' '  ' | sed 's/^ *//; s/ *$//')
  [ -n "$title" ] || { echo 'tab-title: usage: set <title>' >&2; return 2; }
  # Characters, not bytes (GNU cut -c counts bytes and would split a Cyrillic letter).
  if [ "${#title}" -gt "$MAX" ]; then title="${title:0:$((MAX - 1))}…"; fi
  in_orca || { echo 'tab-title: not an Orca session; nothing renamed' >&2; return 0; }
  o=$(bash "$HERE/orca.sh" resolve 2>/dev/null) || { echo 'tab-title: Orca CLI not found; nothing renamed' >&2; return 0; }
  if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
    out=$("$o" terminal rename --terminal "$ORCA_TERMINAL_HANDLE" --title "$title" --json 2>&1) \
      || { echo "tab-title: Orca refused the rename: $(printf '%s' "$out" | head -c 300)" >&2; return 0; }
    if "$o" terminal show --terminal "$ORCA_TERMINAL_HANDLE" --json 2>/dev/null \
        | jq -e '.result.terminal.orphaned == true' >/dev/null 2>&1; then
      echo "tab-title: stored, but this tab is orphaned on this host (opened from another Orca window?); that window may keep the old name" >&2
    fi
  else
    out=$("$o" chat rename --name "$title" --json 2>&1) \
      || { echo "tab-title: Orca refused the rename: $(printf '%s' "$out" | head -c 300)" >&2; return 0; }
  fi
  printf 'tab-title: %s\n' "$title"
}

cmd_context() {
  in_orca || return 0
  local root; root=$(cd "$HERE/.." && pwd -P)
  cat <<EOF
This session runs in an Orca tab. Name the tab after the work in it:
bash "$root/lib/tab-title.sh" set "<title>"
- When: once the task is clear (usually the first real request), and again when the work moves to a different subject. Not every turn; not for a side question.
- What: the subject in 2-6 words, in the user's language — a ticket key with its short title, the thing being built or fixed. Never the skill or command that opened the session ("agenda", "where"): after /hi-crew:agenda picks a task, the tab is named after that task.
- It prints one line; a warning on stderr needs no action and no mention.
EOF
}

case "${1:-}" in
  set) shift; cmd_set "$@" ;;
  context) cmd_context ;;
  *) echo 'usage: tab-title.sh set <title> | context' >&2; exit 2 ;;
esac
