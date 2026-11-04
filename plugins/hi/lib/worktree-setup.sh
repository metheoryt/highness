#!/usr/bin/env bash
# worktree-setup.sh — run inside a fresh worktree: what every workspace gets, then the repo's own
# setup. `wt.sh create` runs it on both backends; Orca runs it through a repo's orca.yaml
# (`highness worktree-setup`, see the repo-setup skill), or by hand from inside a worktree.
#
#   1. gortex track, in the background and guarded: gortex installed, its daemon up, the main
#      checkout already tracked, this worktree not yet. A no-op otherwise, so a teammate or a
#      machine without gortex is unaffected.
#   2. .claude/settings.local.json linked from the main checkout (a fresh worktree carries only
#      committed files).
#   3. the repo's committed setup script: the first executable of $CANDIDATES.
#   4. the local delegate <git-common-dir>/hi/worktree-setup.sh (written by the repo-setup skill
#      where nothing may be committed; never tracked, shared by every worktree), else an older
#      <git-common-dir>/us/worktree-setup.sh. It runs AFTER the committed one, not instead.
#
# Always exits 0: it never blocks a worktree's creation. HI_GORTEX names the gortex binary.
set -u
GORTEX=${HI_GORTEX:-gortex}
CANDIDATES='.orca/worktree-setup.sh docker/worktree-setup.sh .worktree/setup.sh scripts/worktree-setup.sh'

log() { printf '[worktree-setup] %s\n' "$*" >&2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  log "not inside a git work tree; nothing to do"; exit 0;
}

wt_root=$(git rev-parse --show-toplevel)

# Main checkout = parent of the absolutized git common dir.
common=$(git rev-parse --git-common-dir)
case "$common" in
  /* | [A-Za-z]:* ) : ;;
  * ) common=$(cd "$wt_root" && cd "$common" && pwd) ;;
esac
main_root=$(dirname "$common")
gitdir=$(git rev-parse --absolute-git-dir)

# Resolve a dir to its physical path; echo the input unchanged if it isn't one. Needed on both
# sides of the comparison below: git reports physical paths, while gortex may report a path
# through a symlink (/var vs /private/var on macOS, a symlinked home), and a prefix-only
# difference would silently disable tracking with a "not covered" line.
resolve_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"; }

# The tracked-repo paths, one per line, straight from the daemon — never from a config file,
# whose location has drifted between gortex versions (a missing file made every guard below
# fail closed). sed, not jq: this runs on Git Bash boxes with no jq; `gortex repos --json` is
# pretty-printed one field per line. The second sed turns the doubled backslashes of a native
# Windows path into forward slashes, which Git Bash's `cd` accepts. The query is captured, not
# piped straight into sed, so a FAILED query (an older gortex without `repos --json`) is told
# apart from an empty list; callers say so in their own words.
gortex_tracked_paths() {
  local raw
  raw=$("$GORTEX" repos --json 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" \
    | sed -n 's/^[[:space:]]*"path"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' \
    | sed 's/\\\\/\//g'
}

# Exact match of a resolved dir ($1) against a newline-separated path list ($2).
list_has_path() {
  local target line
  target="$(resolve_dir "$1")"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    [ "$(resolve_dir "$line")" = "$target" ] && return 0
  done <<LIST
$2
LIST
  return 1
}

# Graph prefix for a linked worktree. --as-worktree without --name defaults to the directory
# basename, and worktree folders repeat across repos (every repo's `spike` worktree would fight
# over one prefix). Qualify it with the main checkout's basename, unless it already carries it.
wt_prefix() {
  local m w
  m=$(basename "$1"); w=$(basename "$2")
  case "$w" in
    "$m" | "$m"-*) printf '%s' "$w" ;;
    *) printf '%s-%s' "$m" "$w" ;;
  esac
}

# 1. gortex track (guarded).
if [ "$gitdir" = "$common" ]; then
  log "main checkout; skipping gortex track"
elif ! command -v "$GORTEX" >/dev/null 2>&1; then
  log "gortex not installed; skipping gortex track"
elif ! "$GORTEX" daemon status >/dev/null 2>&1; then
  log "gortex daemon down; skipping gortex track"
else
  if ! tracked=$(gortex_tracked_paths); then
    log "gortex repos unavailable; skipping track"
  elif ! list_has_path "$main_root" "$tracked"; then
    log "main checkout not covered by gortex ($main_root); skipping track"
  elif list_has_path "$wt_root" "$tracked"; then
    log "worktree already tracked; skipping track"
  else
    prefix=$(wt_prefix "$main_root" "$wt_root")
    # In the background: a large repo indexes for many minutes, and the create would wait on it
    # with no output. The job holds none of our fds — a caller that captures our stderr (wt.sh,
    # a $(…), an agent's Bash tool) waits for every writer to close. setsid, where there is one,
    # keeps it alive past the caller's process group. The pid file lives while it runs:
    # `wt.sh dispatch` waits on it before starting a session (a session's gortex coverage is
    # fixed at its start), and teardown kills it.
    track_log="$gitdir/gortex-track.log"; track_pid="$gitdir/gortex-track.pid"
    bg=''; command -v setsid >/dev/null 2>&1 && bg=setsid
    $bg nohup sh -c 'echo $$ >"$1"; "$4" track "$2" --as-worktree --name "$3"; rc=$?
                     echo "exit $rc"; rm -f "$1"' _ "$track_pid" "$wt_root" "$prefix" "$GORTEX" \
      </dev/null >"$track_log" 2>&1 &
    log "gortex track started in the background as $prefix — a large repo takes minutes (log: $track_log)"
  fi
fi

# 2. Link gitignored local config from the main checkout into a fresh linked worktree.
#    Idempotent; never clobbers; a dangling symlink counts as already linked. Skipped in the
#    main checkout, where there is nothing distinct to link into.
#
#    `.env` is DELIBERATELY NOT linked. It is repo-semantic: a repo whose worktrees need their
#    own namespace (compose project, test databases) writes a per-worktree `.env` from its own
#    setup script below, and an append through a symlink would write INTO the main checkout's
#    `.env` and give every worktree one shared namespace, silently. A repo that wants main's
#    `.env` shared links it from its own script; this one cannot know which a repo means.
if [ "$gitdir" != "$common" ]; then
  for rel in .claude/settings.local.json; do
    src="$main_root/$rel"
    dst="$wt_root/$rel"
    if [ -e "$src" ] && [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
      mkdir -p "$(dirname "$dst")" && ln -s "$src" "$dst" \
        && log "linked $rel" \
        || log "WARN: failed to link $rel"
    fi
  done
fi

# 3. The repo's committed setup script (first executable candidate wins).
for rel in $CANDIDATES; do
  cand="$wt_root/$rel"
  if [ -x "$cand" ]; then
    log "running repo-local setup: $rel"
    ( cd "$wt_root" && "$cand" ) || log "repo-local setup exited $? (non-fatal)"
    break
  fi
done

# 4. The local delegate, after the committed one.
delegate="$common/hi/worktree-setup.sh"
[ -x "$delegate" ] || delegate="$common/us/worktree-setup.sh"
if [ -x "$delegate" ]; then
  log "running the local delegate: $delegate"
  ( cd "$wt_root" && "$delegate" ) || log "local delegate exited $? (non-fatal)"
fi

exit 0
