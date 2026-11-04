#!/usr/bin/env bash
# lib/await-track.sh <git-dir> <max-seconds> <command…> — wait out a background gortex track,
# then exec the command.
#
# The worktree setup (worktree-setup.sh) runs `gortex track` in the background and keeps
# <git-dir>/gortex-track.pid while it indexes (a large repo: minutes). A session's gortex
# coverage is fixed when it starts, so the session should start after the index. `wt.sh
# dispatch` used to wait here itself, which held the caller's turn for up to 20 minutes;
# it now puts this script in front of the launched line, so the wait happens in the new
# session's own terminal and dispatch returns at once.
#
# It runs without a shell around it (Orca's --command may exec the line), so it takes the
# command as words and execs them. Bounded: past <max-seconds> it starts the command anyway.
# HI_TRACK_POLL sets the poll step (tests).
g=${1:-}; max=${2:-}
[ -n "$g" ] && [ -n "$max" ] && [ $# -ge 3 ] || { echo 'usage: await-track.sh <git-dir> <max-seconds> <command…>' >&2; exit 2; }
shift 2
pf="$g/gortex-track.pid"; lf="$g/gortex-track.log"; step=${HI_TRACK_POLL:-5}; waited=-1
if [ -f "$pf" ] && pid=$(cat "$pf" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  echo "gortex is still indexing this workspace — the session starts when it is done (up to ${max}s; log: $lf)"
  waited=0
  while [ -f "$pf" ] && kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$max" ]; then
      echo "still indexing after ${waited}s — starting anyway; graph tools stay dark until the session restarts"
      exec "$@"
    fi
    sleep "$step"; waited=$((waited + step))
    [ $((waited % 60)) -lt "$step" ] && echo "still indexing (${waited}s)"
  done
fi
rc=$(sed -n 's/^exit \([0-9][0-9]*\)$/\1/p' "$lf" 2>/dev/null | tail -1)
if [ -n "$rc" ] && [ "$rc" != 0 ]; then
  echo "gortex track exited $rc — the session starts without its graph (log: $lf)"
elif [ "$waited" -ge 0 ]; then
  echo "indexing done (${waited}s)"
fi
exec "$@"
