# _sandbox.sh — isolate a test from the real machine. Source it right after _assert.sh.
#
# HOME, the XDG dirs and CLAUDE_CONFIG_DIR move into a temp tree, so no test reads the real
# ~/.config, the highness config or an Orca install. mktemp's own stdout is checked BEFORE any
# `cd` — `cd ""` is a bash error, but not every shell agrees (dash and some `sh`s silently stay
# in the cwd on `cd ""` and report success), so a bare `cd "$(mktemp -d ...)" && pwd -P` cannot
# be trusted to fail loudly on its own. The invoking-cwd check below is the backstop for exactly
# that case: SANDBOX must never equal it, because sandbox_cleanup's EXIT trap does
# `rm -rf "$SANDBOX"`.
_sandbox_cwd=$(pwd -P)
_sandbox_dir=$(mktemp -d "${TMPDIR:-/tmp}/hi-test.XXXXXX" 2>/dev/null)
[ -n "$_sandbox_dir" ] && [ -d "$_sandbox_dir" ] || { echo "_sandbox: mktemp -d failed" >&2; exit 1; }
SANDBOX=$(cd "$_sandbox_dir" && pwd -P)
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "_sandbox: mktemp -d failed" >&2; exit 1; }
if [ "$SANDBOX" = "$_sandbox_cwd" ]; then
  echo "_sandbox: mktemp -d failed (resolved to the invoking cwd — refusing)" >&2
  exit 1
fi
unset _sandbox_cwd _sandbox_dir
export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$CLAUDE_CONFIG_DIR"
# No test may read the real Orca config (the /mnt/c glob would find it on WSL).
export HI_ORCA_DATA=
# SHIM: a directory first on PATH for a test's own stub binaries.
SHIM="$SANDBOX/shim"; mkdir -p "$SHIM"; export PATH="$SHIM:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset HIGHNESS_CONFIG HIGHNESS_BIN_DIR CLAUDE_PLUGIN_ROOT \
      HI_ORCA HI_GORTEX HI_CONFIRMED ORCA_CLI_COMMAND HI_ORCA_BOARD HI_ORCA_STATE_DB \
      HI_WT_BACKEND HI_WT_ROOT HI_WT_SETUP HI_WT_TEARDOWN HI_WT_RM_WAIT HI_TMUX HI_CLAUDE HI_UUID \
      HI_PLUGIN_DIR HI_TRACK_WAIT HI_TRACK_POLL HI_SEND_WAIT HI_SEND_READS HI_MOTION_WAIT HI_STATE_MAX_AGE HIGHNESS_STATE
sandbox_cleanup() { cd / && rm -rf "$SANDBOX"; }
trap sandbox_cleanup EXIT
