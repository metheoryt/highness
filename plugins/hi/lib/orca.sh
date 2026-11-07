#!/usr/bin/env bash
# Orca CLI adapter for hi. Orca is OPTIONAL: every subcommand
# degrades to "exit 1 + empty stdout" so a caller can fall back to the plain-git
# flow without special-casing a missing binary.
#
# Two invariants, both learned the hard way:
#   * Never emit an empty path. A bare `path:` selector or `git -C ""` silently
#     targets the current directory — that is how a reviewer once detached a dev's
#     live worktree. Empty is a failure (exit 1, no stdout), never a success.
#   * Orca reports `branch` as a full ref (`refs/heads/x`). Every comparison here
#     strips `refs/heads/` from BOTH sides, and `branch:<x>` selectors are built
#     from the stripped form.
#
# `create-cmd` only PRINTS the command line — it never runs it. Worktree creation
# is a confirmed step in the calling skill (worktree provisioning), so the skill
# shows this exact string and waits.
#
# `create-cmd`'s line starts with a LITERAL `orca ` — that prefix is pinned by
# orca_test.sh, so it must never change. A caller
# that intends to RUN the line therefore has to swap that literal for the resolved
# binary: `resolve` exists for exactly that, and worktree provisioning shows the
# swapped line (what runs is what the dev approves). Never run the literal as-is.
#
# Override the binary with HI_ORCA (tests stub it).
#
# Exit codes: 0 ok; 1 Orca absent/unresolved or a failed step (empty stdout); 2 bad
# arguments (including a --key that the branch does not carry); 3 `send` without
# HI_CONFIRMED=1; 4 `candidates` could not list origin's branches (unknown, not "none").
set -uo pipefail

ORCA=''

# Resolve the Orca binary. HI_ORCA (this plugin's own override and test seam) wins outright;
# otherwise follow orca-cli's own documented resolution order:
#   1. ORCA_CLI_COMMAND, which Orca exports for managed sessions (e.g. WSL).
#   2. On Linux, `orca-ide` if it's on PATH.
#   3. On Linux, with neither of the above: FAIL. Do not fall back to `orca`.
#   4. Off Linux (no screen-reader collision exists there): `orca`.
# This file EXECUTES the resolved binary — `have_orca` (`command -v`), `available`
# (`status --json`), `current`, `siblings` — and `available` runs on every ordinary
# path as the worktree provisioning probe. On Linux, bare `orca`
# normally resolves to the GNOME Orca screen reader at /usr/bin/orca, so the old
# bare-`orca` default (HI_ORCA with a plain fallback) could start speech on
# the dev's desktop from a read-only probe. Never restore a Linux `orca` fallback.
resolve_orca() {
  if [ -n "${HI_ORCA:-}" ]; then printf '%s\n' "$HI_ORCA"; return 0; fi
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then printf '%s\n' "$ORCA_CLI_COMMAND"; return 0; fi
  if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
    if command -v orca-ide >/dev/null 2>&1; then printf 'orca-ide\n'; return 0; fi
    return 1
  fi
  printf 'orca\n'
  return 0
}

UNRESOLVED_MSG='could not resolve the Orca CLI binary on Linux — set ORCA_CLI_COMMAND or HI_ORCA, or install orca-ide on PATH (never falls back to bare `orca`, which risks starting the GNOME Orca screen reader)'

# Print the resolved Orca binary — the value a caller substitutes for the literal
# `orca` that create-cmd prints, so the line that is shown is the line that runs.
# Unlike `available`, whose stdout is a human-readable REASON the skill displays,
# this stdout is consumed as a VALUE: on failure it prints nothing at all and the
# reason goes to stderr, so a caller that ignores the exit status cannot mistake an
# error message — or a bare `orca` — for a binary.
resolve() {
  local bin
  bin=$(resolve_orca) || { printf 'orca.sh resolve: %s\n' "$UNRESOLVED_MSG" >&2; return 1; }
  [ -n "$bin" ] || { printf 'orca.sh resolve: %s\n' "$UNRESOLVED_MSG" >&2; return 1; }
  printf '%s\n' "$bin"
}

# Strip refs/heads/ so a full ref and a short branch name compare equal.
short_branch() { printf '%s' "${1#refs/heads/}"; }

# jq: Orca's path as THIS side sees it. With the Orca runtime on a Windows host and the
# checkout in WSL, Orca reports `\\wsl.localhost\<distro>\home\…`, and `git -C` on a UNC
# path fails outright — every path this file prints is consumed as a local path, so the
# conversion belongs here rather than in each caller. A UNC path's first two components
# are host + share; the rest is the path. Non-UNC values pass through untouched.
JQ_POSIX='def posix: if startswith("\\\\") then (gsub("\\\\"; "/") | sub("^//[^/]+/[^/]+"; "")) else . end;'

# The same conversion for a caller that parsed Orca's JSON itself (a skill that runs
# the create line and reads the response cannot get the converted path from
# `current` / `siblings`). Text only — needs no Orca binary.
# Anything not starting with a backslash passes through untouched.
posix_path() {
  local p="${1:-}"
  case "$p" in
    '\\'*)
      p=${p//\\//}
      case "$p" in
        //*/*/*) p="/${p#//*/*/}" ;;
      esac
      ;;
  esac
  printf '%s\n' "$p"
}

# Sets $ORCA as a side effect. Exit 1 — silently — when the binary cannot be
# resolved OR is not on PATH; every caller already degrades on a non-zero here.
have_orca() {
  [ -n "$ORCA" ] || ORCA=$(resolve_orca) || return 1
  command -v "$ORCA" >/dev/null 2>&1
}

# Shell-quote for a payload a human reads before approving: bare when safe,
# single-quoted otherwise (`%q`'s backslash form is correct but unreadable).
q() {
  case "$1" in
    ''|*[!A-Za-z0-9._/:@=+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The oldest Orca hi drives. Orca nags for updates and the team keeps it current, so hi follows
# the current CLI and keeps no path for an older one: worktree create --branch (1.4.244), rm
# that waits for the real outcome (1.4.245) and keeps the branch (1.4.246).
MIN_VERSION=1.4.246

# version_ok <x.y.z>: exit 0 when the version is at least MIN_VERSION. An empty or unparsable
# version fails: the runtime always reports one.
version_ok() {
  local v="${1:-}" i a b
  case "$v" in ''|*[!0-9.]*) return 1 ;; esac
  for i in 1 2 3; do
    a=$(printf '%s' "$v" | cut -d. -f"$i"); b=$(printf '%s' "$MIN_VERSION" | cut -d. -f"$i")
    a=${a:-0}
    [ "$a" -gt "$b" ] && return 0
    [ "$a" -lt "$b" ] && return 1
  done
  return 0
}

# `ok` + runtime reachable is enough to drive the CLI. Deliberately NOT gated on
# .result.app.running — the desktop app matters for --activate, not for creation.
available() {
  ORCA=$(resolve_orca) || { printf 'unavailable: %s\n' "$UNRESOLVED_MSG"; return 1; }
  have_orca || { printf 'unavailable: orca CLI not on PATH\n'; return 1; }
  local js
  js=$("$ORCA" status --json 2>/dev/null) || {
    printf 'unavailable: orca status failed — app or runtime not reachable\n'; return 1; }
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || {
    printf 'unavailable: orca status returned ok=false\n'; return 1; }
  local reachable state
  reachable=$(printf '%s' "$js" | jq -r '.result.runtime.reachable // false' 2>/dev/null)
  state=$(printf '%s' "$js" | jq -r '.result.runtime.state // ""' 2>/dev/null)
  [ "$reachable" = "true" ] || { printf 'unavailable: orca runtime not reachable\n'; return 1; }
  [ "$state" = "ready" ] || {
    printf 'degraded: orca runtime state is "%s", not ready\n' "$state"; return 1; }
  local ver
  ver=$(printf '%s' "$js" | jq -r '.result.runtime.appVersion // ""' 2>/dev/null)
  version_ok "$ver" || {
    printf 'outdated: Orca %s is older than %s — update Orca\n' "${ver:-(unknown)}" "$MIN_VERSION"; return 1; }
  printf 'ok\n'
}

# path<TAB>short-branch<TAB>worktree-id for the Orca worktree containing cwd.
current() {
  have_orca || return 1
  local js path branch id
  js=$("$ORCA" worktree current --json 2>/dev/null) || return 1
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || return 1
  path=$(printf   '%s' "$js" | jq -r "$JQ_POSIX"' (.result.worktree.path // "") | posix' 2>/dev/null)
  branch=$(printf '%s' "$js" | jq -r '.result.worktree.branch // ""' 2>/dev/null)
  id=$(printf     '%s' "$js" | jq -r '.result.worktree.id     // ""' 2>/dev/null)
  [ -n "$path" ] || return 1          # empty path is a failure, never a result
  printf '%s\t%s\t%s\n' "$path" "$(short_branch "$branch")" "$id"
}

# One TSV line per Orca worktree of <repo-path|selector>: path<TAB>short-branch<TAB>id.
# Takes a selector as well as a path for the same reason `create-cmd` does: Orca's registered
# path is not always the caller's path, so a caller that has already resolved `id:<uuid>` must
# be able to hand it over rather than have `path:` re-imposed on it here. The selector is
# built into a VARIABLE and its status checked — an inline `$( )` in the argument would
# swallow the failure and hand Orca a bare `--repo`, the empty-selector hazard.
# Rows are joined by hand, not @tsv: @tsv escapes backslashes, and a WSL Orca id is full of them.
siblings() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo 'usage: orca.sh siblings <repo-path>' >&2; return 2; }
  have_orca || return 1
  local js sel
  sel=$(repo_selector_of "$repo") || return 2
  js=$("$ORCA" worktree list --repo "$sel" --json 2>/dev/null) || return 1
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || return 1
  printf '%s' "$js" | jq -r "$JQ_POSIX"'
    (.result.worktrees // [])[]
    | select((.path // "") != "")
    | [(.path | posix), ((.branch // "") | sub("^refs/heads/"; "")), (.id // "")]
    | map(gsub("[\t\n]"; " ")) | join("\t")' 2>/dev/null
}

# Path of the <repo-path> worktree checked out on <branch>, or exit 1 + nothing.
find_branch() {
  local repo="${1:-}" want="${2:-}"
  [ -n "$repo" ] && [ -n "$want" ] || {
    echo 'usage: orca.sh find-branch <repo-path> <branch>' >&2; return 2; }
  want=$(short_branch "$want")
  local hit=''
  while IFS=$'\t' read -r p b _ || [ -n "$p" ]; do
    [ "$b" = "$want" ] && { hit="$p"; break; }
  done < <(siblings "$repo" 2>/dev/null)
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

# Turn a --repo VALUE into an Orca repo selector, without touching the binary.
# A value that already carries a selector scheme (`id:` / `name:` / `path:`) passes
# through verbatim; anything else is a filesystem path and gets `path:`. Pass-through
# exists because Orca's registered path is NOT always the caller's path: with the Orca
# runtime on a Windows host and the checkout in WSL, the repo is registered as
# `\\wsl.localhost\<distro>\home\…`, so `path:/home/…` answers `repo_not_found` for a
# repo Orca knows perfectly well. `repo-selector` resolves that case to `id:<uuid>`.
# A bare scheme with no value (`path:`, `id:`) is rejected: an empty `path:` selector
# silently targets the caller's own cwd — the invariant at the top of this file.
repo_selector_of() {
  local v="${1:-}"
  case "$v" in
    id:|name:|path:)
      echo 'orca.sh: --repo carries a selector scheme with no value' >&2; return 2 ;;
    id:*|name:*|path:*) printf '%s' "$v" ;;
    '') echo 'orca.sh: --repo is empty' >&2; return 2 ;;
    *) printf 'path:%s' "$v" ;;
  esac
}

# Print `id:<repo-id>` for the Orca repo registered at <path>, matching on the FULL
# normalised path (case-folded, `\`→`/`, a `\\wsl.localhost\<distro>` UNC prefix
# stripped). Basename matching is deliberately not attempted — two checkouts of the
# same repo name would be indistinguishable. Zero or 2+ matches is a failure: exit 1
# with the reason on stderr and NOTHING on stdout, so a caller that ignores the exit
# status cannot feed an error message to `--repo`. Callers fall back to `path:<path>`.
repo_selector() {
  local want="${1:-}"
  [ -n "$want" ] || { echo 'usage: orca.sh repo-selector <repo-path>' >&2; return 2; }
  have_orca || { echo 'orca.sh repo-selector: orca CLI not resolvable or not on PATH' >&2; return 1; }
  local js hits n
  js=$("$ORCA" repo list --json 2>/dev/null) || {
    echo 'orca.sh repo-selector: orca repo list failed' >&2; return 1; }
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || {
    echo 'orca.sh repo-selector: orca repo list returned ok=false' >&2; return 1; }
  hits=$(printf '%s' "$js" | jq -r --arg want "$want" "$JQ_POSIX"'
    def norm: posix | ascii_downcase | sub("/+$"; "");
    (.result.repos // [])[]
    | select((.path // "") != "" and (.id // "") != "")
    | select((.path | norm) == ($want | norm))
    | .id' 2>/dev/null)
  n=$(printf '%s' "$hits" | grep -c . || true)
  case "$n" in
    1) printf 'id:%s\n' "$hits" ;;
    0) echo "orca.sh repo-selector: no Orca repo registered at $want" >&2; return 1 ;;
    *) echo "orca.sh repo-selector: $n Orca repos match $want — refusing to guess" >&2; return 1 ;;
  esac
}

# Print (never run) the `orca worktree create` command line.
# Exactly one of --parent/--no-parent is REQUIRED: with neither, Orca infers the
# caller's worktree as parent, so a standalone ticket silently nests under
# whatever checkout the dev happened to be sitting in.
create_cmd() {
  local repo='' name='' base='' parent='' noparent=0 comment=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)      repo="${2:-}"; shift 2 ;;
      --name)      name="${2:-}"; shift 2 ;;
      --base)      base="${2:-}"; shift 2 ;;
      --parent)    parent="${2:-}"; shift 2 ;;
      --no-parent) noparent=1; shift ;;
      --comment)   comment="${2:-}"; shift 2 ;;
      *) echo "create-cmd: unknown flag $1" >&2; return 2 ;;
    esac
  done
  [ -n "$repo" ] || { echo 'create-cmd: --repo <repo-path|selector> is required' >&2; return 2; }
  [ -n "$name" ] || { echo 'create-cmd: --name <worktree-name> is required' >&2; return 2; }
  [ -n "$base" ] || { echo 'create-cmd: --base <ref> is required (the base selection)' >&2; return 2; }
  if [ -n "$parent" ] && [ "$noparent" = 1 ]; then
    echo 'create-cmd: --parent and --no-parent are mutually exclusive' >&2; return 2
  fi
  if [ -z "$parent" ] && [ "$noparent" != 1 ]; then
    echo 'create-cmd: pass --parent <selector> or --no-parent (never neither — Orca would infer one)' >&2
    return 2
  fi
  local out sel
  sel=$(repo_selector_of "$repo") || return 2
  out="orca worktree create --repo $(q "$sel") --name $(q "$name")"
  out="$out --base-branch $(q "$base") --setup run"
  if [ -n "$parent" ]; then
    out="$out --parent-worktree $(q "$parent")"
  else
    out="$out --no-parent"
  fi
  [ -n "$comment" ] && out="$out --comment $(q "$comment")"
  printf '%s --json\n' "$out"
}

# ---- branch-for-ticket helpers ----

# Does <branch> carry <KEY> as a whole token in its LAST path segment: `<KEY>`, `<KEY>-…`
# or `<KEY>_…`? A substring match would let `AB-101` claim `AB-1018`'s branch, and the
# type/owner prefix varies by convention, so it is not part of the pattern.
branch_carries_key() {
  local b="${1:-}" key="${2:-}" last
  [ -n "$key" ] || return 0
  # A GitHub Issues key <repo>#<n> rides the branch as its number alone: <type>/<n>-<slug>.
  case "$key" in *'#'*) key=${key##*#} ;; esac
  last=${b##*/}
  case "$last" in
    "$key"|"$key"-*|"$key"_*) return 0 ;;
  esac
  return 1
}

# candidates --repo <path> --key <KEY>: origin branches that carry KEY, one per line.
# Read-only (ls-remote writes nothing). Empty stdout + exit 0 means no branch yet. Exit 4
# (reason on stderr, nothing on stdout) means origin could not be asked (offline, auth, no
# origin): the answer is UNKNOWN, so a caller must not create a branch on it. Two or more
# lines are a question for the user, never a guess made here. --repo may be a linked
# worktree: it shares the repo's remotes.
candidates() {
  local repo='' key='' ref b heads err
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      --key)  key="${2:-}";  shift 2 ;;
      *) echo "orca.sh candidates: unknown flag $1" >&2; return 2 ;;
    esac
  done
  [ -n "$repo" ] || { echo 'orca.sh candidates: --repo is required' >&2; return 2; }
  [ -n "$key" ]  || { echo 'orca.sh candidates: --key is required' >&2; return 2; }
  [ -d "$repo" ] || { echo "orca.sh candidates: --repo is not a directory: $repo" >&2; return 2; }
  err=$(mktemp "${TMPDIR:-/tmp}/orca-candidates.XXXXXX") || {
    echo 'orca.sh candidates: cannot create a temp file' >&2; return 4; }
  if ! heads=$(git -C "$repo" ls-remote --heads origin 2>"$err"); then
    printf 'orca.sh candidates: cannot list remote branches: %s\n' \
      "$(tr '\n' ' ' < "$err" | sed 's/ *$//')" >&2
    rm -f "$err"; return 4
  fi
  rm -f "$err"
  while read -r _ ref; do
    b=${ref#refs/heads/}
    [ "$b" = "$ref" ] && continue
    if branch_carries_key "$b" "$key"; then printf '%s\n' "$b"; fi
  done <<EOF
$heads
EOF
  return 0
}

# land_branch <wt> <adopt>: put a fresh worktree on the ticket's existing origin branch. A new
# branch is named when Orca creates the tree (`worktree create --branch`); this is for a branch
# that already lives on origin. Runs once, before anyone commits there.
land_branch() {
  local wt="$1" adopt="$2" auto out
  [ -n "$wt" ] || { echo 'orca.sh land-branch: refusing an empty worktree path' >&2; return 1; }
  auto=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
    echo "orca.sh land-branch: cannot read HEAD in $wt" >&2; return 1; }
  out=$(git -C "$wt" fetch --quiet origin "$adopt" 2>&1) || {
    printf 'orca.sh land-branch: git fetch origin %s failed in %s: %s\n' "$adopt" "$wt" "$out" >&2; return 1; }
  if git -C "$wt" show-ref --verify --quiet "refs/heads/$adopt"; then
    out=$(git -C "$wt" switch "$adopt" 2>&1) || {
      printf 'orca.sh land-branch: git switch %s failed in %s: %s\n' "$adopt" "$wt" "$out" >&2; return 1; }
  else
    out=$(git -C "$wt" switch -c "$adopt" --track "origin/$adopt" 2>&1) || {
      printf 'orca.sh land-branch: git switch -c %s failed in %s: %s\n' "$adopt" "$wt" "$out" >&2; return 1; }
  fi
  # Drop the leftover auto-branch only when git agrees it holds nothing unique (-d, never -D).
  [ "$auto" != "$adopt" ] && git -C "$wt" branch -d "$auto" >/dev/null 2>&1
  return 0
}

# land-branch <wt> --adopt <origin-branch> --key <KEY>
land_branch_cmd() {
  local wt="${1:-}" adopt='' key=''
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --adopt)  adopt="${2:-}";  shift 2 ;;
      --key)    key="${2:-}";    shift 2 ;;
      *) echo "orca.sh land-branch: unknown flag $1" >&2; return 2 ;;
    esac
  done
  [ -n "$wt" ] && [ -d "$wt" ] || { echo 'orca.sh land-branch: <worktree> must be an existing directory' >&2; return 2; }
  [ -n "$adopt" ] || { echo 'orca.sh land-branch: --adopt is required' >&2; return 2; }
  [ -n "$key" ] || { echo 'orca.sh land-branch: --key is required' >&2; return 2; }
  branch_carries_key "$adopt" "$key" || {
    printf 'orca.sh land-branch: %s does not carry %s; refusing to land one ticket on another ticket branch\n' "$adopt" "$key" >&2
    return 2; }
  land_branch "$wt" "$adopt"
}

# terminals <worktree-path>: one TSV line per live, writable Orca terminal in that
# worktree: handle<TAB>agent<TAB>title. Orca may report the path as UNC; compare POSIX.
terminals() {
  local want="${1:-}" real js
  [ -n "$want" ] || { echo 'orca.sh terminals: <worktree-path> is required' >&2; return 2; }
  real=$(cd "$want" 2>/dev/null && pwd -P) || real=$want
  have_orca || return 1
  js=$("$ORCA" terminal list --json 2>/dev/null) || return 1
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || return 1
  printf '%s' "$js" | jq -r --arg a "$want" --arg b "$real" "$JQ_POSIX"'
    (.result.terminals // [])[]
    | select((.connected // false) and (.writable // false))
    | ((.worktreePath // "") | posix) as $p
    | select($p != "" and ($p == $a or $p == $b))
    | [.handle, (.agentIdentity // ""), ((.title // "") | gsub("[\t\n]"; " "))] | @tsv'
}

# agents <worktree-path>: one TSV line per Orca agent in that worktree:
# handle<TAB>kind<TAB>verdict. kind is `terminal` (an agent terminal from `terminal list`)
# or `chat` (Orca's "structured" surface, the default since 1.4.246: no terminal, so only
# `worktree ps` shows it, paneKey structured-agent-session-<id>:<tab>). verdict is `idle`,
# `busy`, or `unknown` when Orca gave no status for a terminal (the caller waits on it).
# A terminal's verdict is its `worktree ps` programStatus, found by paneKey = tabId:leafId:
# two calls for the whole workspace instead of a tui-idle wait per terminal. A chat's is its
# state: done or idle is idle, any other state (working, a prompt, a new one) is busy. A bare
# shell has no agentIdentity and no ps row: never listed. Exit 1: no Orca or no terminal list.
agents() {
  local want="${1:-}" real tl ps
  [ -n "$want" ] || { echo 'orca.sh agents: <worktree-path> is required' >&2; return 2; }
  real=$(cd "$want" 2>/dev/null && pwd -P) || real=$want
  have_orca || return 1
  tl=$("$ORCA" terminal list --json 2>/dev/null) || return 1
  [ "$(printf '%s' "$tl" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || return 1
  ps=$("$ORCA" worktree ps --limit 10000 --json 2>/dev/null) || ps=''
  [ "$(printf '%s' "$ps" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || ps='{}'
  printf '%s' "$tl" | jq -r --arg a "$want" --arg b "$real" --argjson ps "$ps" "$JQ_POSIX"'
    def here: (. // "" | posix) as $p | $p != "" and ($p == $a or $p == $b);
    [ ($ps.result.worktrees // [])[] | select(.path | here) | (.agents // [])[] ] as $ag
    | ( (.result.terminals // [])[]
        | select((.connected // false) and (.writable // false) and ((.agentIdentity // "") != ""))
        | select(.worktreePath | here)
        | "\(.tabId):\(.leafId)" as $k
        | ([ $ag[] | select(.paneKey == $k) ][0].programStatus.state // "") as $s
        | [.handle, "terminal", (if $s == "idle" then "idle" elif $s == "" then "unknown" else "busy" end)] ),
      ( $ag[] | select((.paneKey // "") | startswith("structured-agent-session-"))
        | [(.paneKey | sub(":.*$"; "")), "chat",
           (if (.state // "") == "done" or (.state // "") == "idle" then "idle" else "busy" end)] )
    | @tsv'
}

# orphaned: one POSIX worktree path per line where Orca holds a terminal that came back from a
# restart orphaned (orphaned:true, no agent identity) and no live agent terminal at all. The
# session there still exists, but nothing can type into it until the tab is reopened. One
# `terminal list` call covers every workspace.
orphaned() {
  local js
  have_orca || return 1
  js=$("$ORCA" terminal list --json 2>/dev/null) || return 1
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = "true" ] || return 1
  printf '%s' "$js" | jq -r "$JQ_POSIX"'
    [ (.result.terminals // [])[] | select((.worktreePath // "") != "") | . + {p: (.worktreePath | posix)} ]
    | group_by(.p)[]
    | select(any(.orphaned == true)
             and all((((.connected // false) and (.writable // false)) and ((.agentIdentity // "") != "")) | not))
    | .[0].p'
}

# send <handle> <prompt-file>: type the prompt into that terminal and press Enter. It
# writes into another live session, so it is gated like a confirmed write.
send_prompt() {
  local handle="${1:-}" file="${2:-}"
  if [ -z "$handle" ] || [ ! -f "$file" ]; then echo 'orca.sh send: <handle> <prompt-file> are required' >&2; return 2; fi
  [ "${HI_CONFIRMED:-}" = 1 ] || { echo 'orca.sh send: refusing without HI_CONFIRMED=1 (show the prompt and get a yes first)' >&2; return 3; }
  have_orca || { echo "orca.sh send: $UNRESOLVED_MSG" >&2; return 1; }
  "$ORCA" terminal send --terminal "$handle" --text "$(cat "$file")" --enter --json
}

case "${1:-}" in
  available)   available ;;
  resolve)     resolve ;;
  current)     current ;;
  siblings)    shift; siblings "$@" ;;
  find-branch) shift; find_branch "$@" ;;
  repo-selector) shift; repo_selector "$@" ;;
  posix)       shift; posix_path "${1:-}" ;;
  create-cmd)  shift; create_cmd "$@" ;;
  candidates)  shift; candidates "$@" ;;
  land-branch) shift; land_branch_cmd "$@" ;;
  terminals)   shift; terminals "$@" ;;
  agents)      shift; agents "$@" ;;
  orphaned)    orphaned ;;
  send)        shift; send_prompt "$@" ;;
  *)
    echo 'usage: orca.sh available|current|siblings <repo-path>|find-branch <repo-path> <branch>|repo-selector <repo-path>|posix <path>|resolve|create-cmd --repo <path|selector> --name <n> --base <ref> (--parent <sel>|--no-parent) [--comment <t>] | candidates --repo <p> --key <K> | land-branch <wt> --adopt <b> --key <K> | terminals <worktree-path> | agents <worktree-path> | orphaned | send <handle> <prompt-file>  (exit: 1 no Orca/failed, 2 usage, 3 send unconfirmed, 4 candidates cannot list origin)' >&2
    exit 2 ;;
esac
