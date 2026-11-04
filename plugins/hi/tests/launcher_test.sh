#!/usr/bin/env bash
# bin/highness (the stable entry point) and lib/install-launcher.sh (the SessionStart hook that
# keeps ~/.local/bin/highness pointing at the current plugin root).
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
PLUGIN=$(cd "$HERE/.." && pwd -P)
INSTALL="$PLUGIN/lib/install-launcher.sh"
BIN="$HOME/.local/bin"; L="$BIN/highness"
inode() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }

# --- hooks.json: SessionStart on startup runs the installer -----------------------------------
H="$PLUGIN/hooks/hooks.json"
assert_eq "hooks.json: SessionStart matcher" startup "$(jq -r '.hooks.SessionStart[0].matcher' "$H")"
assert_eq "hooks.json: runs install-launcher.sh" 'bash "${CLAUDE_PLUGIN_ROOT}/lib/install-launcher.sh"' \
  "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$H")"
assert_eq "plugin.json: name hi" hi "$(jq -r .name "$PLUGIN/.claude-plugin/plugin.json")"

# --- bin/highness ----------------------------------------------------------------------------
assert_eq "highness version" "$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")" "$(bash "$PLUGIN/bin/highness" version)"
assert_eq "highness root" "$PLUGIN" "$(bash "$PLUGIN/bin/highness" root)"
bash "$PLUGIN/bin/highness" >/dev/null 2>&1; assert_status "highness: no command is usage (2)" 2 "$?"
bash "$PLUGIN/bin/highness" frob >/dev/null 2>&1; assert_status "highness: unknown command is usage (2)" 2 "$?"
bash "$PLUGIN/bin/highness" wt >/dev/null 2>&1; assert_status "highness wt: wt.sh's own usage (2)" 2 "$?"
out=$(cd "$SANDBOX" && bash "$PLUGIN/bin/highness" worktree-setup 2>&1); rc=$?
assert_status "highness worktree-setup outside a repo: exit 0" 0 "$rc"
assert_contains "highness worktree-setup: runs lib/worktree-setup.sh" "$out" "[worktree-setup] not inside a git work tree"
(cd "$SANDBOX" && bash "$PLUGIN/bin/highness" worktree-teardown >/dev/null 2>&1); assert_status "highness worktree-teardown: exit 0" 0 "$?"

# --- install-launcher.sh: a root with a space (a config dir under "Application Support") ------
ROOT="$SANDBOX/Application Support/hi/0.1.0"; mkdir -p "$(dirname "$ROOT")"; cp -R "$PLUGIN" "$ROOT"
out=$(CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/lib/install-launcher.sh" 2>&1); rc=$?
assert_status "install: exit 0" 0 "$rc"
assert_eq "install: silent on success" "" "$out"
assert_eq "install: executable launcher" yes "$([ -x "$L" ] && echo yes || echo no)"
assert_contains "install: execs the root's bin/highness" "$(cat "$L")" "exec bash '$ROOT/bin/highness' \"\$@\""
assert_eq "launcher: reaches the plugin through the space" "$ROOT" "$("$L" root)"
assert_eq "launcher: passes arguments through" "$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")" "$("$L" version)"
assert_eq "launcher: no stray temp files" "" "$(ls -A "$BIN" | grep -v '^highness$')"

i1=$(inode "$L")
CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/lib/install-launcher.sh"
assert_eq "install again, same root: not rewritten" "$i1" "$(inode "$L")"

ROOT2="$SANDBOX/cache/hi/0.2.0"; mkdir -p "$(dirname "$ROOT2")"; cp -R "$PLUGIN" "$ROOT2"
out=$(CLAUDE_PLUGIN_ROOT="$ROOT2" bash "$ROOT2/lib/install-launcher.sh" 2>&1)
assert_eq "install, new root: silent" "" "$out"
assert_eq "install, new root: rewritten to it" "$ROOT2" "$("$L" root)"

# CLAUDE_PLUGIN_ROOT unset: the directory above the script
out=$(env -u CLAUDE_PLUGIN_ROOT bash "$ROOT/lib/install-launcher.sh" 2>&1)
assert_eq "install, no CLAUDE_PLUGIN_ROOT: the script's own root" "$ROOT" "$("$L" root)"

# HIGHNESS_BIN_DIR moves it
HIGHNESS_BIN_DIR="$SANDBOX/other bin" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$INSTALL"
assert_eq "HIGHNESS_BIN_DIR: written there" yes "$([ -x "$SANDBOX/other bin/highness" ] && echo yes || echo no)"

# a file there that is not the launcher is left alone, and the session goes on
printf '#!/bin/sh\necho mine\n' > "$SANDBOX/other bin/highness"
out=$(HIGHNESS_BIN_DIR="$SANDBOX/other bin" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$INSTALL" 2>"$SANDBOX/err"); rc=$?
assert_status "foreign file: exit 0" 0 "$rc"
assert_eq "foreign file: no stdout" "" "$out"
assert_eq "foreign file: untouched" "$(printf '#!/bin/sh\necho mine')" "$(cat "$SANDBOX/other bin/highness")"
assert_contains "foreign file: said on stderr" "$(cat "$SANDBOX/err")" "not the hi launcher"

# an unwritable directory never fails the session
mkdir -p "$SANDBOX/ro"; chmod 555 "$SANDBOX/ro"
out=$(HIGHNESS_BIN_DIR="$SANDBOX/ro" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$INSTALL" 2>/dev/null); rc=$?
assert_status "unwritable dir: exit 0" 0 "$rc"
assert_eq "unwritable dir: no stdout" "" "$out"
assert_eq "unwritable dir: nothing written" no "$([ -e "$SANDBOX/ro/highness" ] && echo yes || echo no)"
chmod 755 "$SANDBOX/ro"
out=$(HIGHNESS_BIN_DIR="$SANDBOX/ro/file/below" CLAUDE_PLUGIN_ROOT="$SANDBOX/nowhere" bash "$INSTALL" 2>/dev/null); rc=$?
assert_status "a root without bin/highness: exit 0" 0 "$rc"
assert_eq "a root without bin/highness: nothing written" no "$([ -e "$SANDBOX/ro/file" ] && echo yes || echo no)"

assert_summary
