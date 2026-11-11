#!/usr/bin/env bash
# lib/umbrella.sh — an umbrella repo: one checkout that holds several independent clones.
#
# Some owners keep a small repo whose only job is to hold a CLAUDE.md, a bootstrap script and
# a list of the repos cloned inside it. Each listed directory is a full clone of its own, with
# its own origin, worktrees and <git-common-dir>/hi/ records. The skills run from the umbrella
# root, so they need to know which nested clone a PR or a ticket belongs to. Everything they
# do — git, gh, wt.sh, records — then runs in that clone. The umbrella itself never gets a
# workspace and keeps no records of its own.
#
# The marker is a `repos.txt` at the git toplevel of the cwd, and nothing else. Inside a
# nested clone the toplevel is that clone, so a session there is not "in the umbrella".
# repos.txt: one `<dir> <origin-url>` per line, `<dir>` relative to the umbrella's MAIN checkout,
# or to `<main checkout>/<umbrella.dir>` when the umbrella's config sets `umbrella.dir` (an
# umbrella whose bootstrap clones into a subdirectory: `api` listed, cloned at `repos/api`;
# the committed `.claude/highness.json` says {"umbrella": {"dir": "repos"}}, see config.sh).
# `#` comments and blank lines are ignored. A listed dir that is missing, or is not a git
# toplevel of its own (an empty directory would otherwise answer with the umbrella's origin),
# is skipped. owner/repo comes from the clone's ACTUAL origin, which is what a PR names; the
# URL column is only the fallback for a clone with no origin.
#
# A workspace of the umbrella (a linked worktree, `wt.sh create --umbrella`) is an umbrella too:
# `root` is that workspace, but the clones live only in the main checkout, so `repos` and
# `resolve` answer with the main checkout's clones. An agent there makes a nested clone's
# workspace the same way as from the main checkout: `wt.sh --repo <clone> create …`.
#
# Usage:
#   umbrella.sh root                   the umbrella root (physical path)
#   umbrella.sh home                   the umbrella's main checkout (= root outside a workspace)
#   umbrella.sh repos                  <abs-path>TAB<owner/repo> per cloned listed dir
#   umbrella.sh repos --paths          <abs-path> only, one per line: what a per-clone loop
#                                      feeds to `wt.sh --repo` (no cut, no word-splitting)
#   umbrella.sh resolve --pr <url|owner/repo#n>
#                                      the abs path of the clone whose origin is that repo
#   umbrella.sh resolve --issue <repo#n>
#                                      the abs path of the clone whose origin repo NAME is
#                                      <repo> (case-insensitive): a GitHub Issues key names
#                                      its repo, so no origin is asked
#   umbrella.sh resolve --key <KEY>    <abs-path>TAB<branch> for every origin branch, in every
#                                      clone, that carries KEY (orca.sh candidates). Zero or
#                                      several rows are a question for the user, never a guess.
#
# Exit codes: 0 ok; 1 not in an umbrella, or the PR's repo is not cloned here; 2 usage
# (including a bare PR number, which names no repo); 3 --key: every clone answered and none
# has a branch for KEY (said on stderr: the clone is the user's pick from `repos`); 4 --key
# could not ask some clone's origin — the rows printed are the clones that answered, the
# others are named on stderr, and "no row" from them is unknown, not "none".
# bash 3.2 floor.
set -uo pipefail
_UMB_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# owner/repo of a remote URL, lowercased: git@host:owner/repo, ssh://git@host/owner/repo,
# https://[user@]host/owner/repo. String work only.
_url_repo() {
  local url="${1:-}"
  url=${url%/}
  url=${url%.git}
  url=${url#*://}
  url=${url#*@}
  url=${url#*[:/]}
  printf '%s' "$url" | tr '[:upper:]' '[:lower:]'
}

# owner/repo of `origin`, lowercased. The configured URL, not `remote get-url`: that one
# applies url.<base>.insteadOf, a transport rewrite that says nothing about identity.
_origin_repo() {
  local url
  url=$(git config --get remote.origin.url 2>/dev/null) || return 1
  _url_repo "$url"
}

umb_say() { printf 'umbrella.sh: %s\n' "$*" >&2; }

umb_root() {
  local top
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] && [ -f "$top/repos.txt" ] || return 1
  (cd "$top" && pwd -P)
}

# umb_home: the umbrella's main checkout — the root itself, or, from a workspace of the
# umbrella, the checkout git lists first. That is where the nested clones are.
umb_home() {
  local root first
  root=$(umb_root) || return 1
  first=$(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$first" ] && (cd "$first" 2>/dev/null && pwd -P) || printf '%s\n' "$root"
}

umb_repos() {
  local mode="${1:-}" root home base sub dir url rest p top slug
  case "$mode" in ''|--paths) ;; *) umb_usage; return 2 ;; esac
  root=$(umb_root) || { umb_say 'not in an umbrella repo (no repos.txt at the git toplevel)'; return 1; }
  home=$(umb_home) || home=$root
  base=$home
  sub=$(cd "$root" && bash "$_UMB_HERE/config.sh" get '.umbrella.dir' 2>/dev/null) || sub=''
  sub=${sub%/}
  case "$sub" in ''|.) ;; /*) base=$sub ;; *) base="$home/$sub" ;; esac
  while read -r dir url rest || [ -n "$dir" ]; do
    dir=${dir%$'\r'}; url=${url%$'\r'}
    case "$dir" in ''|'#'*) continue ;; esac
    dir=${dir%/}
    case "$dir" in /*) p=$dir ;; *) p="$base/$dir" ;; esac
    [ -d "$p" ] || continue
    p=$(cd "$p" 2>/dev/null && pwd -P) || continue
    [ "$p" != "$root" ] && [ "$p" != "$home" ] || continue   # the umbrella itself is never a nested repo
    top=$(git -C "$p" rev-parse --show-toplevel 2>/dev/null) || continue
    [ "$(cd "$top" 2>/dev/null && pwd -P)" = "$p" ] || continue
    slug=$(cd "$p" && _origin_repo 2>/dev/null) || slug=''
    [ -n "$slug" ] || slug=$(_url_repo "$url")
    [ -n "$slug" ] || continue
    if [ "$mode" = --paths ]; then printf '%s\n' "$p"; else printf '%s\t%s\n' "$p" "$slug"; fi
  done < "$root/repos.txt"
  return 0
}

umb_resolve_pr() {
  local ref="${1:-}" slug rows hit
  case "$ref" in
    http://*/pull/*|https://*/pull/*)
      slug=${ref#*://}; slug=${slug#*/}; slug=${slug%%/pull/*} ;;
    */*'#'*) slug=${ref%%#*} ;;
    *) umb_say "--pr needs a PR URL or owner/repo#n — a bare number names no repo here (got [$ref])"; return 2 ;;
  esac
  slug=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
  case "$slug" in */*) ;; *) umb_say "cannot read owner/repo from [$ref]"; return 2 ;; esac
  rows=$(umb_repos) || return 1
  hit=$(printf '%s\n' "$rows" | awk -F'\t' -v s="$slug" '$2 == s { print $1; exit }')
  [ -n "$hit" ] || { umb_say "$slug is not cloned in this umbrella (see repos.txt)"; return 1; }
  printf '%s\n' "$hit"
}

umb_resolve_issue() {
  local ref="${1:-}" name rows hit n
  case "$ref" in
    ?*'#'[0-9]*) name=${ref%%#*} ;;
    *) umb_say "--issue needs <repo>#<n> (got [$ref])"; return 2 ;;
  esac
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  rows=$(umb_repos) || return 1
  hit=$(printf '%s\n' "$rows" | awk -F'\t' -v r="$name" '{ s = tolower($2); sub(/.*\//, "", s) } s == r { print $1 }')
  n=$(printf '%s' "$hit" | grep -c . || true)
  [ "$n" -eq 1 ] || { umb_say "$n clones here are named $name (see repos.txt)"; return 1; }
  printf '%s\n' "$hit"
}

umb_resolve_key() {
  local key="${1:-}" rows row p out rc=0 b hits=0
  [ -n "$key" ] || { umb_say 'resolve --key needs a value'; return 2; }
  rows=$(umb_repos) || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    p=$(printf '%s\n' "$row" | cut -f1)
    if ! out=$(bash "$_UMB_HERE/orca.sh" candidates --repo "$p" --key "$key" </dev/null); then
      umb_say "could not ask $(printf '%s\n' "$row" | cut -f2)'s origin — its answer is unknown"
      rc=4; continue
    fi
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      printf '%s\t%s\n' "$p" "$b"; hits=$((hits + 1))
    done <<EOF
$out
EOF
  done <<EOF
$rows
EOF
  if [ "$rc" -eq 0 ] && [ "$hits" -eq 0 ]; then
    umb_say "no clone has a branch for $key — pick its clone from: umbrella.sh repos"
    rc=3
  fi
  return "$rc"
}

umb_usage() {
  echo 'usage: umbrella.sh root | home | repos [--paths] | resolve --pr <url|owner/repo#n> | resolve --issue <repo#n> | resolve --key <KEY>' >&2
  return 2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    root)  umb_root ;;
    home)  umb_home ;;
    repos) umb_repos "${2:-}" ;;
    resolve)
      case "${2:-}" in
        --pr)  umb_resolve_pr "${3:-}" ;;
        --issue) umb_resolve_issue "${3:-}" ;;
        --key) umb_resolve_key "${3:-}" ;;
        *)     umb_usage ;;
      esac ;;
    *) umb_usage ;;
  esac
fi
