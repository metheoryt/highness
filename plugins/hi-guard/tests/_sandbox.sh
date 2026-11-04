# _sandbox.sh — isolate a test from the real machine. Source it right after _assert.sh.
#
# HOME and the XDG dirs move into a temp tree, and HIGHNESS_CONFIG points at a file there that
# does not exist, so no test reads the real highness config (a test sets its own).
# mktemp's own stdout is checked BEFORE any `cd` — `cd ""` is a bash error, but not every
# shell agrees (dash and some `sh`s silently stay in the cwd on `cd ""` and report success),
# so a bare `cd "$(mktemp -d ...)" && pwd -P` cannot be trusted to fail loudly on its own.
# The invoking-cwd check below is the belt-and-suspenders backstop for exactly that case:
# SANDBOX must never equal it, because sandbox_cleanup's EXIT trap does `rm -rf "$SANDBOX"`.
_sandbox_cwd=$(pwd -P)
_sandbox_dir=$(mktemp -d "${TMPDIR:-/tmp}/hi-guard-test.XXXXXX" 2>/dev/null)
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
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"
export HIGHNESS_CONFIG="$SANDBOX/no-config.json"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
sandbox_cleanup() { cd / && rm -rf "$SANDBOX"; }
trap sandbox_cleanup EXIT
