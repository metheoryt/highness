#!/usr/bin/env bash
# install-launcher.sh — the SessionStart hook (hooks/hooks.json): keep
# ${HIGHNESS_BIN_DIR:-$HOME/.local/bin}/highness a tiny script that execs THIS plugin version's
# bin/highness, so callers outside Claude Code (an Orca hook in a repo's orca.yaml) reach the
# plugin whose install path changes with every version.
#
# The file is rewritten only when its content would change (the plugin moved), atomically (a
# temp file in the same directory, then mv), so a hook running it mid-write never reads half a
# script. A file there that is not this launcher (no marker line) is left alone. It never fails
# the session and prints nothing on success: a SessionStart hook's stdout lands in the session's
# context. CLAUDE_PLUGIN_ROOT names the plugin root (else the directory above this file).
set -u
MARK='# highness launcher'

# _q <s>: <s> single-quoted for sh.
_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

main() {
  local root dir f tmp want
  root=${CLAUDE_PLUGIN_ROOT:-}
  [ -n "$root" ] || root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P) || return 0
  [ -f "$root/bin/highness" ] || { echo "highness: no bin/highness under $root — launcher not written" >&2; return 0; }
  dir=${HIGHNESS_BIN_DIR:-$HOME/.local/bin}
  f="$dir/highness"
  want="#!/bin/sh
$MARK — written by the hi plugin at session start (lib/install-launcher.sh), rewritten when
# the plugin moves. Edits are lost; delete this file to stop it (it comes back next session).
exec bash $(_q "$root/bin/highness") \"\$@\""
  if [ -f "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "$want" ]; then return 0; fi
  if { [ -e "$f" ] || [ -L "$f" ]; } && ! grep -q "^$MARK" "$f" 2>/dev/null; then
    echo "highness: $f exists and is not the hi launcher — left alone" >&2; return 0
  fi
  mkdir -p "$dir" 2>/dev/null || { echo "highness: cannot create $dir — launcher not written" >&2; return 0; }
  tmp=$(mktemp "$dir/.highness.XXXXXX" 2>/dev/null) || { echo "highness: $dir is not writable — launcher not written" >&2; return 0; }
  if printf '%s\n' "$want" > "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$f"; then return 0; fi
  rm -f "$tmp"
  echo "highness: could not write $f" >&2
  return 0
}

main >/dev/null
exit 0
