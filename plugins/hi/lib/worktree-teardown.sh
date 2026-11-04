#!/usr/bin/env bash
# worktree-teardown.sh — run inside a worktree before it is removed; the reverse of
# worktree-setup.sh. `wt.sh remove` runs it on the git backend; Orca runs it through a repo's
# orca.yaml archive script (`highness worktree-teardown`), or by hand.
#
#   0. a background `gortex track` setup started and that still runs is stopped, or it would
#      re-add the path once it finishes.
#   1. the repo's committed teardown script FIRST (it reclaims what setup made while gortex
#      still covers the worktree; it does not need gortex).
#   2. gortex untrack this worktree, then reconcile: untrack every tracked path gone from disk
#      (worktrees removed outside any tool — `git worktree remove`, `rm -rf`). Guarded on gortex
#      being installed and its daemon up.
#
# Always exits 0. HI_GORTEX names the gortex binary.
set -u
GORTEX=${HI_GORTEX:-gortex}
CANDIDATES='.orca/worktree-teardown.sh docker/worktree-teardown.sh .worktree/teardown.sh scripts/worktree-teardown.sh'

log() { printf '[worktree-teardown] %s\n' "$*" >&2; }

# The tracked-repo paths, one per line, from the daemon. Twin of the helper in
# worktree-setup.sh — see there for why the daemon, why sed, and why the query is captured.
gortex_tracked_paths() {
  local raw
  raw=$("$GORTEX" repos --json 2>/dev/null) || return 1
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" \
    | sed -n 's/^[[:space:]]*"path"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' \
    | sed 's/\\\\/\//g'
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  log "not inside a git work tree; nothing to do"; exit 0;
}

wt_root=$(git rev-parse --show-toplevel)

# 0. Setup ran the track under setsid where it could, so the pid is a group leader; without
#    setsid (macOS) its child is stopped by parent pid.
track_pid="$(git rev-parse --absolute-git-dir)/gortex-track.pid"
if [ -f "$track_pid" ] && pid=$(cat "$track_pid" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill -- "-$pid" 2>/dev/null || { pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; }
  log "stopped the background gortex track ($pid)"
fi

# 1. The repo's committed teardown FIRST (first executable candidate wins).
for rel in $CANDIDATES; do
  cand="$wt_root/$rel"
  if [ -x "$cand" ]; then
    log "running repo-local teardown: $rel"
    ( cd "$wt_root" && "$cand" ) || log "repo-local teardown exited $? (non-fatal)"
    break
  fi
done

# 2. gortex untrack + reconcile (guarded).
if ! command -v "$GORTEX" >/dev/null 2>&1; then
  log "gortex not installed; skipping untrack/reconcile"; exit 0
fi
if ! "$GORTEX" daemon status >/dev/null 2>&1; then
  log "gortex daemon down; skipping untrack/reconcile"; exit 0
fi

if "$GORTEX" untrack "$wt_root" >/dev/null 2>&1; then
  log "untracked worktree $wt_root"
fi

# Reconcile off a snapshot: `gortex untrack` rewrites the store the list came from, so walking
# it live skips entries.
if ! tracked=$(gortex_tracked_paths); then
  log "gortex repos unavailable; skipping reconcile"
else
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    if [ ! -d "$p" ]; then
      if "$GORTEX" untrack "$p" >/dev/null 2>&1; then
        log "reconcile: pruned missing path $p"
      fi
    fi
  done <<LIST
$tracked
LIST
fi

exit 0
