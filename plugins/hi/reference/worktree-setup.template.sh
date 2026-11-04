#!/usr/bin/env bash
# worktree-setup.sh — this repo's own worktree delegate.
#
# Scaffolded by /hi:repo-setup. The hi plugin's worktree-setup (`highness worktree-setup`,
# run by `wt.sh create` and by a repo's orca.yaml) runs it inside every fresh worktree, after
# it gortex-tracks the worktree and links .claude/settings.local.json from the main checkout.
# It lives at .orca/worktree-setup.sh (committed) or at <git-common-dir>/hi/worktree-setup.sh
# (local: never committed, shared by every worktree, run after the repo's committed delegate).
#
# `.env` is NOT linked, deliberately — it is repo-semantic. If this repo needs a per-worktree
# .env, write it HERE; a link to main's .env would make an append-style write land in the main
# checkout and give every worktree one shared namespace. If this repo instead wants main's .env
# verbatim, link it here.
#
# INVARIANT: never block Orca. Every path is non-fatal; always exit 0.
# Never use the errexit option.

log() { echo "worktree-setup: $*" >&2; }

# >>> repo-setup:managed:repo-steps >>>
# Repo-specific steps go here. Examples:
#   - link an extra gitignored file the generic set misses
#   - copy a seed DB / .superpowers ledger the app needs
#   - print a ready-to-run command for the developer
# Keep every step non-fatal (guard with `|| log "WARN: ..."`).
# <<< repo-setup:managed:repo-steps <<<

exit 0
