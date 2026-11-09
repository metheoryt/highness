#!/usr/bin/env bash
# lib/wt.sh — one workspace layer over Orca worktrees and plain git worktrees.
#
# A workspace is the home of one piece of work: a ticket, a review, or work without a ticket.
# Orca is a layer over git worktrees, so the two backends behave the same; with Orca the
# workspace also shows in the sidebar with its lineage. Every verb prints TSV rows (see
# `list`) or nothing, and one human announce line on stderr.
#
# Rules carried over from orca.sh and an earlier review-tree script, each learned the hard way:
#   * Read TSV with `cut -f`, never `IFS=$'\t' read`: sel/parent/session/key can be empty,
#     and TAB is IFS whitespace, so `read` shifts every column after an empty one.
#   * The POSIX path (col 1) and Orca's selector (col 2) are separate values. On a Windows
#     Orca runtime with the checkout in WSL, Orca speaks UNC paths that `git -C` rejects.
#   * Never emit or interpolate an empty path: `git -C ""` and a bare `path:` selector both
#     target the CURRENT directory, and removal carries --force.
#   * Never run a bare `orca` on Linux (the GNOME screen reader): the binary comes from
#     `orca.sh resolve`.
#   * Orca `worktree create` answering runtime_unavailable is listed before any retry: a
#     blind retry duplicates the worktree.
#   * Orca removal passes --run-hooks, or the repo's archive hook (test-DB teardown) is
#     skipped. Success is judged by the filesystem, never by `ok`.
#
# Records live in <git-common-dir>/hi/ (shared by every worktree, never staged): <KEY>.md for a
# ticket, review-<n>.md, work-<slug>.md. A record is `field: value` lines; the last one wins
# and an empty value means unset. Orca's --comment is a one-line mirror, never read back.
# A record that exists only in <git-common-dir>/us/ (written by an older tool) is read from
# there; the first write copies it into hi/, so nothing it held is lost, and every write
# goes to hi/.
#
# `--repo <path>` (before the verb) runs the verb as if from <path>: how a session in an
# umbrella repo (umbrella.sh) works on one of its nested clones. The "this session is inside
# it" guards still read the caller's own cwd. `create` refuses in an umbrella itself unless
# given --umbrella: a change to a nested clone belongs in that clone's workspace, and only a
# change to the umbrella's own files (repos.txt, its docs) takes a workspace of the umbrella.
# A nested clone's workspace made from a workspace of the umbrella records it as `umbrella:`
# (a parent must be of the same repo), so the umbrella's task can find its nested trees.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ORCA_SH="$HERE/orca.sh"
BOARD_SH="$HERE/board.sh"
UMBRELLA_SH="$HERE/umbrella.sh"
GORTEX=${HI_GORTEX:-gortex}
CLAUDE=${HI_CLAUDE:-claude}
ORCA=''
BACKEND=''
REPO_SEL=''

say() { printf 'wt: %s\n' "$*" >&2; }

usage() {
  cat >&2 <<'U'
usage: wt.sh [--repo PATH] <verb> …   (--repo: run as if from PATH, e.g. a clone in an umbrella)
       wt.sh rec get|set (--ticket K|--review N|--work S) <field> [<value> [<field> <value>]…]
       wt.sh list [--state]
       wt.sh find --branch B | --ticket K | --review N | --work S | --path P
       wt.sh create --kind ticket|review|work --key K --name N [--base REF] [--branch B | --adopt B] [--umbrella]
                    [--detach SHA] [--parent PATH (default: the workspace it runs in)] [--slug S] [--tests]
       wt.sh dispatch <path> --brief <file> [--name N] [--resume ID] [--config-dir D]
                    (a live agent session there gets the brief; else a new terminal, which
                    waits out gortex indexing itself; exit 3: that session is mid-turn)
       wt.sh remove-if-safe <path> | remove-if-landed <path> | remove <path> | sweep
       wt.sh review-head --pr N --base-ref B | waiting
       wt.sh board <path> <column>   (Orca board column: board.sh lists them; prints one row)
       wt.sh board -                 (path<TAB>column lines on stdin; one row each, one listing)
exit: 0 ok · 1 not found or failed · 2 usage, not in a git work tree, or create in an umbrella
      · 3 refused (remove-if-safe; dispatch: a session is mid-turn there) · 4 removed, but the directory survived
U
  exit 2
}

# MAIN: the main checkout (physical path). COMMON: the absolute git common dir. STORE: the
# record store; LEGACY: the older store it falls back to. REPO: the main checkout's basename
# (git-backend folder root).
_repo() {
  local top common first
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1
  common=$(cd "$top" && git rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in /*) ;; *) common="$top/$common" ;; esac
  COMMON=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  first=$(git -C "$top" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
  [ -n "$first" ] || return 1
  MAIN=$(cd "$first" 2>/dev/null && pwd -P) || return 1
  [ -n "$MAIN" ] || return 1
  STORE="$COMMON/hi"
  LEGACY="$COMMON/us"
  REPO=${MAIN##*/}
}

_valid_id() {
  case "$1" in
    ticket) printf '%s' "$2" | grep -Eq '^([A-Za-z][A-Za-z0-9]*-[0-9]+|[a-z0-9][a-z0-9._-]*#[0-9]+)$' ;;
    review) case "$2" in ''|*[!0-9]*) return 1 ;; esac ;;
    work)   printf '%s' "$2" | grep -Eq '^[a-z0-9][a-z0-9-]*$' ;;
    *) return 1 ;;
  esac
}

# _id_rule <kind>: _valid_id's rule for that kind, in words for an error message. Keep in step.
_id_rule() {
  case "$1" in
    ticket) printf '%s' '^[A-Za-z][A-Za-z0-9]*-[0-9]+$ or <repo>#<n> (a ticket key, e.g. AB-123 or app#16)' ;;
    review) printf '%s' '^[0-9]+$ (a PR number)' ;;
    work)   printf '%s' '^[a-z0-9][a-z0-9-]*$ (lowercase letters, digits and dashes; no dots)' ;;
  esac
}

# _id_opt <--ticket|--review|--work> <value>: sets KIND and ID (the caller declares them local).
_id_opt() {
  case "${1:-}" in
    --ticket) KIND=ticket ;;
    --review) KIND=review ;;
    --work)   KIND=work ;;
    *) return 2 ;;
  esac
  ID="${2:-}"
  _valid_id "$KIND" "$ID" || return 2
}

_valid_field() {
  case "${1:-}" in
    ''|*[!a-z_]*) say "rec: bad field name [${1:-}]"; return 2 ;;
  esac
}

_rec_name() {
  case "$1" in
    ticket) printf '%s.md' "$2" ;;
    review) printf 'review-%s.md' "$2" ;;
    work)   printf 'work-%s.md' "$2" ;;
    *) return 1 ;;
  esac
}

# _rec_file <kind> <id>: the record to READ — hi/'s, else the older store's when only it has one.
_rec_file() {
  local n
  n=$(_rec_name "$1" "$2") || return 1
  if [ ! -f "$STORE/$n" ] && [ -f "$LEGACY/$n" ]; then printf '%s/%s' "$LEGACY" "$n"
  else printf '%s/%s' "$STORE" "$n"; fi
}

# _rec_files: every record file to read, one per line: all of hi/, then each of the older store
# whose name hi/ lacks.
_rec_files() {
  local f
  for f in "$STORE"/*.md; do [ -f "$f" ] && printf '%s\n' "$f"; done
  for f in "$LEGACY"/*.md; do [ -f "$f" ] && [ ! -f "$STORE/${f##*/}" ] && printf '%s\n' "$f"; done
  return 0
}

# _rec_get <kind> <id> <field>: prints the last value; exit 1 when absent or empty.
_rec_get() {
  local f v
  f=$(_rec_file "$1" "$2") || return 1
  [ -f "$f" ] || return 1
  v=$(awk -v k="$3: " 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { print v }' "$f")
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# _rec_set <kind> <id> <field> <value> [<field> <value>]…: one append to hi/. A record only
# the older store has is copied first — its `field: value` lines, the rest of such a file
# (prose, headings) is not a record's.
_rec_set() {
  local kind="$1" id="$2" body='' f n nl='
'
  shift 2
  while [ $# -ge 2 ]; do
    _valid_field "$1" || return 2
    case "$2" in *"$nl"*) say 'rec: a value must be one line'; return 2 ;; esac
    body="$body$1: $2$nl"
    shift 2
  done
  [ $# -eq 0 ] || { say 'rec set: fields come in <field> <value> pairs'; return 2; }
  [ -n "$body" ] || { say 'rec set: nothing to set'; return 2; }
  mkdir -p "$STORE" || return 1
  n=$(_rec_name "$kind" "$id") || return 1
  f="$STORE/$n"
  if [ ! -f "$f" ]; then
    printf '# hi %s %s\n' "$kind" "$id" > "$f" || return 1
    [ -f "$LEGACY/$n" ] && { grep -E '^[a-z_]+: ' "$LEGACY/$n" >> "$f" || true; }
  fi
  printf '%s' "$body" >> "$f" || return 1
}

# Lowercase ASCII, runs of anything else → '-', trimmed, at most $2 (default 40) characters.
_slugify() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' |
    LC_ALL=C sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-*//; s/-*$//' | cut -c1-"${2:-40}" | sed 's/-*$//'
}

# The folder name of a ticket: the dashed key, then the slug of the title. The title is what
# follows "<key> · " in the name; a name that already starts with the key in any spelling
# ("x-1-foo", "x#1 foo") has that prefix dropped, so the key is not written twice.
_ticket_slug() {
  local dkey kslug part
  dkey=$(printf '%s' "$1" | tr '#' '-')
  kslug=$(_slugify "$dkey" 1000)
  part=$(_slugify "${2#* · }" 1000)
  case "$part" in
    "$kslug")   part='' ;;
    "$kslug"-*) part=${part#"$kslug"-} ;;
  esac
  part=$(_slugify "$part")
  printf '%s-%s' "$dkey" "$part"
}

cmd_rec() {
  local op="${1:-}" KIND ID
  [ $# -gt 0 ] && shift
  _id_opt "${1:-}" "${2:-}" || { say 'rec: need --ticket <KEY> | --review <n> | --work <slug> with a valid value'; return 2; }
  shift 2
  case "$op" in
    get) [ $# -eq 1 ] || { say 'rec get: exactly one <field>'; return 2; }
         _valid_field "$1" || return 2
         _rec_get "$KIND" "$ID" "$1" ;;
    set) _rec_set "$KIND" "$ID" "$@" ;;
    *) usage ;;
  esac
}

# _col <row> <n>: one field of a TSV row.
_col() { printf '%s\n' "$1" | cut -f"$2"; }

# Orca when it is reachable AND this repo is registered with it; git otherwise.
# HI_WT_BACKEND=git forces git; HI_WT_BACKEND=orca fails (exit 1) when Orca is unusable.
_backend() {
  [ -n "$BACKEND" ] && return 0
  BACKEND=git; REPO_SEL=''; ORCA=''
  case "${HI_WT_BACKEND:-}" in
    git) return 0 ;;
    orca|'') ;;
    *) say 'HI_WT_BACKEND must be git or orca'; exit 2 ;;
  esac
  local why
  why=$(bash "$ORCA_SH" available 2>/dev/null)
  case "$why" in outdated:*) say "${why#outdated: } (using plain git worktrees until then)" ;; esac
  if [ "$why" = ok ]; then
    REPO_SEL=$(bash "$ORCA_SH" repo-selector "$MAIN" 2>/dev/null) || REPO_SEL=''
    ORCA=$(bash "$ORCA_SH" resolve 2>/dev/null) || ORCA=''
    if [ -n "$REPO_SEL" ] && [ -n "$ORCA" ]; then BACKEND=orca; else REPO_SEL=''; ORCA=''; fi
  fi
  if [ "${HI_WT_BACKEND:-}" = orca ] && [ "$BACKEND" != orca ]; then
    say 'HI_WT_BACKEND=orca, but Orca is not available for this repo'; return 1
  fi
  return 0
}

# path<TAB>head<TAB>short-branch for every worktree except the first (the main checkout).
_git_rows() {
  git -C "$MAIN" worktree list --porcelain 2>/dev/null | awk '
    function out() { if (n > 1 && p != "") printf "%s\t%s\t%s\n", p, h, b }
    /^worktree / { out(); n++; p = substr($0, 10); h = ""; b = ""; next }
    /^HEAD /     { h = substr($0, 6); next }
    /^branch /   { b = substr($0, 8); sub(/^refs\/heads\//, "", b); next }
    END          { out() }'
}

# workspace-path<TAB>kind<TAB>key for every record that names a workspace.
_rec_index() {
  local f b kind key ws
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    b=${f##*/}; b=${b%.md}
    case "$b" in
      *.log)    continue ;;
      review-*) kind=review; key=${b#review-} ;;
      work-*)   kind=work;   key=${b#work-} ;;
      *)        kind=ticket; key=$b ;;
    esac
    ws=$(awk 'index($0, "workspace: ") == 1 { v = substr($0, 12) } END { print v }' "$f")
    [ -n "$ws" ] && printf '%s\t%s\t%s\n' "$ws" "$kind" "$key"
  done <<EOF
$(_rec_files)
EOF
  return 0
}

# _infer <path> <branch>: kind and key for a workspace no record names. Prints kind<TAB>key.
_infer() {
  local folder=${1##*/} last k
  case "$folder" in
    review-[0-9]*|*-review-[0-9]*)
      k=${folder##*review-}
      case "$k" in *[!0-9]*) ;; *) printf 'review\t%s\n' "$k"; return ;; esac ;;
  esac
  last=${2##*/}
  k=$(printf '%s' "$last" | sed -n 's/^\([A-Za-z][A-Za-z0-9]*-[0-9][0-9]*\).*/\1/p' | LC_ALL=C tr '[:lower:]' '[:upper:]')
  if [ -n "$k" ]; then printf 'ticket\t%s\n' "$k"; return; fi
  printf 'work\t%s\n' "$folder"
}

# _rec_owns <kind> <key> <path>: may <path>'s row read that key's record? A record is per key and
# names one workspace: yes when it names <path>, or names no live tree (an inferred tree, one made
# outside wt.sh). No when it names another live tree of the same key — an old, landed tree
# beside a new one would borrow the new one's name, session and base.
_rec_owns() {
  local ws
  ws=$(_rec_get "$1" "$2" workspace 2>/dev/null) || return 0
  [ "$ws" = "$3" ] || [ ! -d "$ws" ]
}

_rows() {
  local idx omap line p h b hit kind key name parent session sel backend
  _backend || return 1
  idx=$(_rec_index)
  omap=''
  if [ "$BACKEND" = orca ]; then
    omap=$(bash "$ORCA_SH" siblings "$REPO_SEL" 2>/dev/null | cut -f1,3)
  fi
  _git_rows | while IFS= read -r line; do
    p=$(_col "$line" 1); h=$(_col "$line" 2); b=$(_col "$line" 3)
    [ -n "$p" ] && [ -d "$p" ] || continue
    hit=$(printf '%s\n' "$idx" | awk -F'\t' -v p="$p" '$1 == p { print $2 "\t" $3; exit }')
    name=${p##*/}; parent=''; session=''
    if [ -n "$hit" ]; then
      kind=$(_col "$hit" 1); key=$(_col "$hit" 2)
      name=$(_rec_get "$kind" "$key" name 2>/dev/null) || name=${p##*/}
      parent=$(_rec_get "$kind" "$key" parent 2>/dev/null) || parent=''
      session=$(_rec_get "$kind" "$key" session 2>/dev/null) || session=''
    else
      hit=$(_infer "$p" "$b"); kind=$(_col "$hit" 1); key=$(_col "$hit" 2)
      if _rec_owns "$kind" "$key" "$p"; then
        name=$(_rec_get "$kind" "$key" name 2>/dev/null) || name=${p##*/}
        parent=$(_rec_get "$kind" "$key" parent 2>/dev/null) || parent=''
        session=$(_rec_get "$kind" "$key" session 2>/dev/null) || session=''
      fi
    fi
    sel=$(printf '%s\n' "$omap" | awk -F'\t' -v p="$p" '$1 == p { print $2; exit }')
    backend=git; [ -n "$sel" ] && backend=orca
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$p" "$sel" "$b" "$h" "$kind" "$key" "$name" "$parent" "$session" "$backend"
  done
}

# _find <--branch|--ticket|--review|--work|--path> <value>: the first matching row, or exit 1.
_find() {
  local by="${1:-}" v="${2:-}" phys='' ws='' hit
  [ -n "$v" ] || { say "find: $by needs a value"; return 2; }
  case "$by" in
    --branch) v=${v#refs/heads/} ;;
    --path)   phys=$(cd "$v" 2>/dev/null && pwd -P) || phys='' ;;
    --ticket|--review|--work) ws=$(_rec_get "${by#--}" "$v" workspace 2>/dev/null) || ws='' ;;
    *) say "find: unknown flag $by"; return 2 ;;
  esac
  # By key, the workspace the record names wins over another tree of the same key.
  hit=$(_rows | awk -F'\t' -v by="$by" -v v="$v" -v phys="$phys" -v ws="$ws" '
    (by == "--branch" && $3 == v) ||
    (by == "--path"   && ($1 == v || (phys != "" && $1 == phys))) { print; done = 1; exit }
    ("--" $5 == by && $6 == v) {
      if (ws != "" && $1 == ws) { print; done = 1; exit }
      if (first == "") first = $0 }
    END { if (!done && first != "") print first }')
  [ -n "$hit" ] || return 1
  printf '%s\n' "$hit"
}

cmd_list() {
  case "${1:-}" in
    '') _rows ;;
    --state) _rows_state ;;
    *) usage ;;
  esac
}

# The Orca worktree selector for a row's sel (Orca id) and path. `id:` is the form measured to
# work; every caller passes both values so a switch to `path:` is one line.
_osel() { printf 'id:%s' "$1"; }

# Does <branch> carry <KEY> as a whole token in its last path segment? (orca.sh's rule.)
_carries_key() {
  local last=${1##*/} k=$2
  case "$k" in *'#'*) k=${k##*#} ;; esac   # <repo>#<n> rides the branch as <n>
  case "$last" in "$k"|"$k"-*|"$k"_*) return 0 ;; esac
  return 1
}

# The worktree setup (worktree-setup.sh: gortex, local config links, the repo's committed
# setup and its local delegate), the same on both backends. Never blocks creation.
_setup() {
  local s="${HI_WT_SETUP:-$HERE/worktree-setup.sh}"
  if [ -f "$s" ]; then
    say "setup: $s"
    (cd "$1" && bash "$s") >&2 || say "setup exited $? (non-fatal)"
  else
    say "setup: no script at $s — skipped"
  fi
}

# Git backend. Reads the caller's locals; sets WT (and leaves SEL empty).
_create_git() {
  local out
  WT="${HI_WT_ROOT:-$HOME/wt}/$REPO/$slug"
  mkdir -p "${WT%/*}" || return 1
  # An empty leftover directory is cleared; anything else is refused, never deleted: a
  # library does not remove a directory whose contents it cannot account for.
  [ -d "$WT" ] && rmdir "$WT" 2>/dev/null
  if [ -e "$WT" ]; then
    say "$WT already exists and is not empty — refusing to reuse or delete it; move it away and re-run"
    return 1
  fi
  if [ "$kind" = review ]; then
    out=$(git -C "$MAIN" worktree add --detach "$WT" "$detach" 2>&1)
  elif [ -n "$adopt" ]; then
    out=$(git -C "$MAIN" fetch --quiet origin "$adopt" 2>&1) || { say "git fetch origin $adopt failed: $out"; return 1; }
    if git -C "$MAIN" show-ref --verify --quiet "refs/heads/$adopt"; then
      out=$(git -C "$MAIN" worktree add "$WT" "$adopt" 2>&1)
    else
      out=$(git -C "$MAIN" worktree add --track -b "$adopt" "$WT" "origin/$adopt" 2>&1)
    fi
  elif git -C "$MAIN" show-ref --verify --quiet "refs/heads/$branch"; then
    out=$(git -C "$MAIN" worktree add "$WT" "$branch" 2>&1)
  else
    out=$(git -C "$MAIN" worktree add -b "$branch" "$WT" "$base" 2>&1)
  fi || { say "git worktree add failed: $out"; WT=''; return 1; }
}

# _land_orca: checks a fresh Orca tree is where the kind wants it, or moves it there. A new
# ticket or work branch is named at creation (`--branch`, _create_orca); an existing branch
# and an adopted origin branch are switched to here, and a review is detached. Reads
# _create_orca's locals (kind key branch adopt detach slug target WT MAIN auto named). 1 on failure.
_land_orca() {
  if [ -n "$named" ]; then
    [ "$auto" = "$branch" ] && return 0
    say "create: Orca put the tree on [$auto], not $branch"; return 1
  fi
  case "$kind" in
    ticket)
      if [ -n "$adopt" ]; then
        bash "$ORCA_SH" land-branch "$WT" --adopt "$adopt" --key "$key" || return 1
      else
        git -C "$WT" switch --quiet "$branch" || return 1
        [ -n "$auto" ] && git -C "$MAIN" branch -d "$auto" >/dev/null 2>&1
      fi ;;
    review)
      git -C "$WT" switch --detach --quiet "$detach" || return 1
      case "$auto" in
        '') ;;
        "$slug"|*/"$slug") git -C "$MAIN" branch -D "$auto" >/dev/null 2>&1 || say "could not delete Orca's branch $auto" ;;
        *) say "Orca put the tree on [$auto], not */$slug — leaving that branch alone" ;;
      esac ;;
  esac
  return 0
}

# Orca backend. `--setup skip`: wt.sh runs the setup itself on both backends.
# Reads the caller's locals; sets WT (POSIX) and SEL (Orca id, verbatim).
_create_orca() {
  local target js rc err errf code line auto named=''
  target=$base; [ "$kind" = review ] && target=$detach
  # A branch that does not exist yet is named at creation. An existing one is switched to
  # after (_land_orca): Orca reuses it only when it sits at the base, and otherwise cuts
  # `<name>-2` beside it (measured on Orca 1.4.252).
  case "$kind" in ticket|work)
    [ -z "$adopt" ] && ! git -C "$MAIN" show-ref --verify --quiet "refs/heads/$branch" && named=$branch ;;
  esac
  if [ "$kind" = work ] && [ -z "$named" ]; then
    say "create: $branch already exists; pick another --branch"; return 1
  fi
  set -- worktree create --repo "$REPO_SEL" --name "$slug" --base-branch "$target" \
         --setup skip --comment "hi:$kind $key" --json
  [ -n "$named" ] && set -- "$@" --branch "$named"
  # Always an explicit parent (cmd_create guarantees psel): with no lineage flag Orca guesses from
  # the caller's worktree, and --no-parent is what left trees orphaned in the sidebar.
  set -- "$@" --parent-worktree "$(_osel "$psel" "$parent")"
  errf=$(mktemp "${TMPDIR:-/tmp}/wt-create.XXXXXX") || return 1
  js=$("$ORCA" "$@" 2>"$errf"); rc=$?
  err=$(tr '\n' ' ' < "$errf" | cut -c1-200); rm -f "$errf"
  # Success is keyed on `ok`, never on rc: Orca answers a failed create with exit 1 AND a
  # well-formed {"ok":false,"error":{…}} on stdout, which carries the reason.
  if [ -n "$js" ] && [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
    WT=$(bash "$ORCA_SH" posix "$(printf '%s' "$js" | jq -r '.result.worktree.path // ""' 2>/dev/null)")
    SEL=$(printf '%s' "$js" | jq -r '.result.worktree.id // ""' 2>/dev/null)
  else
    code=$(printf '%s' "$js" | jq -r '.error.code // empty' 2>/dev/null)
    if [ "$code" != runtime_unavailable ]; then
      say "orca worktree create failed: ${code:-${err:-no output}} (exit $rc)"; return 1
    fi
    # List before any retry: the create may have landed before the runtime dropped, and a
    # blind retry makes a second tree.
    line=$(bash "$ORCA_SH" siblings "$REPO_SEL" 2>/dev/null |
           awk -F'\t' -v s="/$slug" 'substr($1, length($1) - length(s) + 1) == s { print; exit }')
    WT=$(_col "$line" 1); SEL=$(_col "$line" 3)
    if [ -z "$WT" ] || [ ! -d "$WT" ]; then
      say 'Orca answered runtime_unavailable; the list shows no such tree, so nothing was created (not retried)'
      WT=''; return 1
    fi
    say "Orca answered runtime_unavailable, but $WT exists — using it"
  fi
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    say "Orca built the worktree somewhere this machine cannot reach: [$WT] — removing it on Orca's side"
    [ -n "$SEL" ] && "$ORCA" worktree rm --worktree "$(_osel "$SEL" "$WT")" --force --run-hooks --json >/dev/null 2>&1
    WT=''; return 1
  fi
  "$ORCA" worktree set --worktree "$(_osel "$SEL" "$WT")" --display-name "$name" --json >/dev/null 2>&1 ||
    say 'could not set the Orca display name (non-fatal)'
  # Land the tree where the kind wants it. A failure here
  # leaves a fresh tree on Orca's auto branch that holds no work: remove it, or a later create
  # would find it and hand it back on the wrong branch.
  auto=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || auto=''
  if ! _land_orca; then
    say "create: could not land $WT on the requested branch — removing the fresh Orca tree (it holds no work)"
    "$ORCA" worktree rm --worktree "$(_osel "$SEL" "$WT")" --force --run-hooks --json >/dev/null 2>&1
    git -C "$MAIN" worktree prune >/dev/null 2>&1
    if [ -n "$auto" ] && git -C "$MAIN" show-ref --verify --quiet "refs/heads/$auto" &&
       [ "$(git -C "$MAIN" rev-parse "refs/heads/$auto")" = "$(git -C "$MAIN" rev-parse --verify --quiet "$target^{commit}")" ]; then
      git -C "$MAIN" branch -D "$auto" >/dev/null 2>&1
    fi
    [ -d "$WT" ] && say "the directory $WT survived the rollback; remove it by hand"
    WT=''; return 1
  fi
}

# _create_leftover <path>: the tree was removed while create ran. A leftover holding only
# .claude/ is what the setup dispatcher writes (links, settings) and is cleared; anything else
# is named and left: a library does not delete what it cannot account for.
_create_leftover() {
  local left
  if [ ! -e "$1" ]; then
    say "create: $1 was removed while setup ran (it is no longer a worktree) — no record written"
    return 0
  fi
  left=$(ls -A "$1" 2>/dev/null | tr '\n' ' ')
  if [ "$left" = '.claude ' ] && rm -rf "$1" 2>/dev/null; then
    say "create: $1 was removed while setup ran — cleared the .claude/ setup left there; no record written"
  else
    say "create: $1 was removed while setup ran, but the directory remains with: ${left:-nothing readable} — not deleted, no record written; remove it by hand"
  fi
}

_create_usage() {
  cat >&2 <<'U'
usage: wt.sh create --kind work   --key SLUG --name N --base REF --branch B   [--parent P] [--tests]
       wt.sh create --kind ticket --key KEY  --name N --base REF (--branch B | --adopt B) [--slug S]
              (--name is "<KEY> · <title>"; the folder is <KEY with # as ->-<slug of title>)
       wt.sh create --kind review --key PR#  --name N --detach SHA
       --umbrella: in an umbrella repo, a workspace of the umbrella itself (its own files)
U
}

cmd_create() {
  local col='' kind='' key='' b0='' name='' base='' branch='' adopt='' detach='' parent='' psel='' slug='' ufrom='' uhome='' \
        tests=0 hit prev prow row WT='' SEL='' nl='
' tab='	'
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)   kind="${2:-}";   shift 2 ;;
      --key)    key="${2:-}";    shift 2 ;;
      --name)   name="${2:-}";   shift 2 ;;
      --base)   base="${2:-}";   shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --adopt)  adopt="${2:-}";  shift 2 ;;
      --detach) detach="${2:-}"; shift 2 ;;
      --parent) parent="${2:-}"; shift 2 ;;
      --slug)   slug="${2:-}";   shift 2 ;;
      --tests)  tests=1;         shift ;;
      --umbrella) shift ;;   # read by the dispatcher
      -h|--help) _create_usage; return 0 ;;
      *) say "create: unknown flag $1 (every argument is a flag)"; _create_usage; return 2 ;;
    esac
  done
  case "$kind" in
    ticket|review|work) ;;
    '') say 'create: --kind is required: ticket, review or work'; return 2 ;;
    *)  say "create: unknown --kind $kind (want ticket, review or work)"; return 2 ;;
  esac
  [ -n "$key" ] || { say "create: --kind $kind needs --key, format $(_id_rule "$kind")"; return 2; }
  _valid_id "$kind" "$key" || { say "create: --key $key is not a valid $kind key, want $(_id_rule "$kind")"; return 2; }
  [ -n "$name" ] || { say 'create: --name is required'; return 2; }
  case "$name" in *"$nl"*|*"$tab"*) say 'create: --name must be one line with no TAB'; return 2 ;; esac
  case "$kind" in
    ticket)
      [ -n "$base" ] || { say 'create: a ticket needs --base'; return 2; }
      if [ -n "$branch" ] && [ -n "$adopt" ]; then say 'create: --branch and --adopt are mutually exclusive'; return 2; fi
      [ -n "$branch$adopt" ] || { say 'create: a ticket needs --branch or --adopt'; return 2; }
      _carries_key "${branch:-$adopt}" "$key" || {
        say "create: ${branch:-$adopt} does not carry $key — refusing to put one ticket on another ticket's branch"; return 2; }
      # The folder spells a <repo>#<n> key as <repo>-<n>: no '#' in a path.
      [ -n "$slug" ] || slug=$(_ticket_slug "$key" "$name")
      slug=${slug%-} ;;
    review)
      [ -n "$detach" ] || { say 'create: a review needs --detach <sha>'; return 2; }
      detach=$(git -C "$MAIN" rev-parse --verify --quiet "$detach^{commit}") || {
        say "create: --detach is not a commit in this repo"; return 2; }
      slug="review-$key" ;;
    work)
      [ -n "$base" ] && [ -n "$branch" ] || {
        say "create: work needs --base and --branch (missing:$([ -n "$base" ] || printf ' --base')$([ -n "$branch" ] || printf ' --branch'))"
        return 2; }
      slug="$key" ;;
  esac
  printf '%s' "$slug" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || { say "create: bad folder name [$slug]"; return 2; }
  # Every workspace wt.sh makes has a parent (his rule, 2026-09-26). Without --parent it is the
  # workspace this call stands in: a linked tree — ours, or one made in Orca's UI — or the main
  # checkout itself, which Orca also lists and nests under.
  [ -n "$parent" ] || parent=$(git rev-parse --show-toplevel 2>/dev/null) || parent=''
  [ -n "$parent" ] || { say 'create: cannot tell which workspace this runs in'; return 2; }
  _backend || return 1
  # A bare trunk name as --base means the remote trunk (highness#16): Orca, handed the local
  # branch name with a new --branch, put the tree on [main] and create failed. origin/<trunk> is
  # also the fresh trunk, not a local copy the sync may not have moved yet.
  if [ -n "$base" ] && [ "$(_trunk)" = "origin/$base" ] &&
     git -C "$MAIN" show-ref --verify --quiet "refs/remotes/origin/$base"; then
    base="origin/$base"
  fi
  if [ "$(cd "$parent" 2>/dev/null && pwd -P)" = "$MAIN" ]; then
    parent=$MAIN
    if [ "$BACKEND" = orca ]; then
      psel=$(bash "$ORCA_SH" siblings "$REPO_SEL" 2>/dev/null | awk -F'\t' -v p="$MAIN" '$1 == p { print $3; exit }')
    fi
  else
    prow=$(_find --path "$parent") || { say "create: --parent $parent is not a workspace of this repo"; return 2; }
    parent=$(_col "$prow" 1); psel=$(_col "$prow" 2)
  fi
  if [ "$BACKEND" = orca ] && [ -z "$psel" ]; then
    say "create: Orca does not list the parent $parent — refusing to make a workspace with no parent"
    return 1
  fi

  # Find first: a workspace is reused, never duplicated.
  # A hit is handed back only when it matches the request: a ticket by its branch, work on its
  # branch, a review re-detached at the asked head (clean trees only).
  case "$kind" in
    ticket) hit=$(_find --branch "${branch:-$adopt}" 2>/dev/null) || hit='' ;;
    review) hit=$(_find --review "$key" 2>/dev/null) || hit='' ;;
    work)   hit=$(_find --work "$key" 2>/dev/null) || hit='' ;;
  esac
  if [ -n "$hit" ]; then
    if [ "$kind" = work ] && [ "$(_col "$hit" 3)" != "$branch" ]; then
      say "create: $(_col "$hit" 1) is the workspace for $key, but it is on [$(_col "$hit" 3)], not $branch — refusing to hand it back"
      return 1
    fi
    if [ "$kind" = review ] && [ "$(_col "$hit" 4)" != "$detach" ]; then
      if [ -n "$(git -C "$(_col "$hit" 1)" status --porcelain 2>/dev/null)" ]; then
        say "create: review $key's workspace has uncommitted changes — not moving it to $detach"
        return 1
      fi
      git -C "$(_col "$hit" 1)" switch --detach --quiet "$detach" || { say "create: could not move review $key's workspace to $detach"; return 1; }
      _rec_set review "$key" head "$detach" || say 'create: moved, but the record could not be written'
      say "moved \"$(_col "$hit" 7)\" to the new head ${detach%"${detach#????????}"}"
      hit=$(_find --path "$(_col "$hit" 1)") || return 1
    fi
    say "reusing \"$(_col "$hit" 7)\" → $(_col "$hit" 1)"
    printf '%s\n' "$hit"; return 0
  fi

  # The record is per key and names one tree: a second tree of this key takes it over.
  prev=$(_find "--$kind" "$key" 2>/dev/null) || prev=''
  [ -n "$prev" ] &&
    say "create: $key already has a workspace, \"$(_col "$prev" 7)\" at $(_col "$prev" 1) on [$(_col "$prev" 3)]; the record moves to the new one, the old tree is listed by its folder name"

  "_create_$BACKEND" || return 1
  [ -n "$WT" ] && [ -d "$WT" ] || { say 'create: no workspace directory came back'; return 1; }
  if [ "$kind" != review ] || [ "$tests" = 1 ]; then _setup "$WT"; fi
  # Setup can run for minutes (a gortex index), and the tree can be removed meanwhile: a caller
  # timed out and the work landed and was cleaned up. Then no record is written, and
  # what setup left behind in the dead path is cleared when it is only setup's own .claude/.
  if ! _is_wt "$WT" && ! _is_wt "$(cd "$WT" 2>/dev/null && pwd -P)"; then
    _create_leftover "$WT"
    return 1
  fi

  set -- workspace "$WT" name "$name" backend "$BACKEND"
  set -- "$@" parent "$parent"
  [ "$kind" = review ] && set -- "$@" head "$detach"
  ufrom=$(cd "$CALLER_PWD" && bash "$UMBRELLA_SH" root 2>/dev/null) &&
    uhome=$(cd "$CALLER_PWD" && bash "$UMBRELLA_SH" home 2>/dev/null) &&
    [ "$ufrom" != "$uhome" ] && [ "$MAIN" != "$uhome" ] && set -- "$@" umbrella "$ufrom"
  # base: the commit the workspace started at, so `landed` can tell finished work from a fresh tree.
  b0=$(git -C "$WT" rev-parse --verify -q HEAD 2>/dev/null) && [ "$kind" != review ] && set -- "$@" base "$b0"
  _rec_set "$kind" "$key" "$@" || say 'create: the workspace exists, but its record could not be written'
  row=$(_find --path "$WT") || { say "create: made $WT but cannot list it"; return 1; }
  say "created \"$name\" → $WT ($BACKEND)"
  if [ "$BACKEND" = orca ]; then
    col=active; [ "$kind" = review ] && col=review_queue
    _board "$row" "$col" >/dev/null </dev/null || true
  fi
  printf '%s\n' "$row"
}

# The worktree setup (worktree-setup.sh) runs `gortex track` in the background and keeps
# <git-dir>/gortex-track.pid while it indexes (a large repo: minutes). A session's gortex
# coverage is fixed when it starts, so the session should start after the index. Dispatch
# never waits for it itself (that held the caller's turn up to 20 minutes): while the
# track runs, _track_wrap prints the await-track.sh prefix, and the new session's own
# terminal waits, bounded by HI_TRACK_WAIT. A finished track that failed is said here.
_track_wrap() {
  local g pf lf pid rc max=${HI_TRACK_WAIT:-1200}
  g=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  pf="$g/gortex-track.pid"; lf="$g/gortex-track.log"
  if [ -f "$pf" ] && pid=$(cat "$pf" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    say "dispatch: gortex is still indexing $1 — the session starts when it is done (up to ${max}s, in its own terminal; log: $lf)"
    printf 'bash %s %s %s ' "$(_q "$HERE/await-track.sh")" "$(_q "$g")" "$max"
    return 0
  fi
  rc=$(sed -n 's/^exit \([0-9][0-9]*\)$/\1/p' "$lf" 2>/dev/null | tail -1)
  [ -n "$rc" ] && [ "$rc" != 0 ] && say "dispatch: gortex track exited $rc — the session starts without its graph (log: $lf)"
  return 0
}

# _live_agent <wt> <sel>: the handle of an idle agent terminal in that workspace (exit 0),
# `busy` (exit 3) when an agent runs there but none is idle, `chat` (exit 4) when the only
# idle agent is a chat — Orca's CLI cannot type into a chat — or nothing (exit 1). Only Orca
# reports agents; a bare shell never counts. Orca's status says which terminal is idle; the
# one we would type into is confirmed with a tui-idle wait first, since typing into a
# running turn could answer a permission prompt.
_live_agent() {
  local h kind v busy=0 chat=0
  [ -n "$2" ] && [ -n "$ORCA" ] || return 1
  while IFS="$(printf '\t')" read -r h kind v; do
    [ -n "$h" ] || continue
    case "$kind:$v" in
      terminal:busy) busy=1 ;;
      terminal:*) if _tui_idle "$h"; then printf '%s' "$h"; return 0; fi; busy=1 ;;
      chat:idle) chat=1 ;;
      *) busy=1 ;;
    esac
  done <<AGENTS
$(bash "$ORCA_SH" agents "$1" 2>/dev/null </dev/null)
AGENTS
  [ "$busy" = 1 ] && { printf busy; return 3; }
  [ "$chat" = 1 ] && { printf chat; return 4; }
  return 1
}

# _tui_idle <handle>: exit 0 when that agent terminal's TUI goes idle within 2 s.
_tui_idle() {
  [ "$("$ORCA" terminal wait --terminal "$1" --for tui-idle --timeout-ms 2000 --json 2>/dev/null </dev/null |
       jq -r '.ok // false' 2>/dev/null)" = true ]
}

# Extra `claude` flags for a dispatched session.
DISPATCH_FLAGS=''

# The hi plugin root this wt.sh runs from (physical): its reference/*.md, which a dispatched
# worker may be told to read, live under it. HI_PLUGIN_DIR overrides it.
_plugin_dir() {
  [ -n "${HI_PLUGIN_DIR:-}" ] && { printf '%s' "$HI_PLUGIN_DIR"; return; }
  (cd "$HERE/.." && pwd -P)
}

# _deny_edits <workspace>: the `--settings` JSON that denies Edit and Write (an Edit rule covers
# both) under the plugin root and under the repo's main checkout (highness#14). --add-dir grants
# writes as well as reads: a worker in highness itself, whose plugin root IS the main checkout,
# edited it with no prompt. A deny rule holds in every permission mode, bypass included (measured
# 2026-10-09; on a path with a space 2026-11-09). A dir that holds the workspace is left out, or
# the worker could edit nothing.
_deny_edits() {
  local w d rules=''
  w=$(cd "$1" 2>/dev/null && pwd -P) || w=$1
  for d in "$(_plugin_dir)" "$(cd "$MAIN" 2>/dev/null && pwd -P)"; do
    [ -n "$d" ] || continue
    case "$w/" in "$d/"*) continue ;; esac
    rules="$rules${rules:+,}$(jq -cn --arg d "$d" '"Edit(/" + $d + "/**)"')"
  done
  printf '{"permissions":{"deny":[%s]}}' "$rules"
}

# Shell-quote for a line a human reads (and may paste): bare when safe, single-quoted otherwise.
_q() {
  case "$1" in
    ''|*[!A-Za-z0-9._/:@=+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

_uuid() {
  local u="${HI_UUID:-}"
  [ -n "$u" ] || u=$(uuidgen 2>/dev/null) || u=''
  [ -n "$u" ] || u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || u=''
  printf '%s' "$u" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

cmd_dispatch() {
  local path="${1:-}" brief='' name='' resume='' cfg='' env='' row wt sel kind key dst dirs uuid line via=print handle='' js T rc tmp wrap
  [ -n "$path" ] || { say 'dispatch: <path> is required'; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --brief) brief="${2:-}"; shift 2 ;;
      --name)  name="${2:-}";  shift 2 ;;
      --resume) resume="${2:-}"; shift 2 ;;
      --config-dir) cfg="${2:-}"; shift 2 ;;
      *) say "dispatch: unknown flag $1"; return 2 ;;
    esac
  done
  [ -n "$brief" ] && [ -f "$brief" ] || { say 'dispatch: --brief <existing file> is required'; return 2; }
  if [ -n "$resume" ]; then
    printf '%s' "$resume" | grep -Eq '^[0-9a-fA-F-]{8,64}$' || { say 'dispatch: --resume takes a session id'; return 2; }
  fi
  # --config-dir runs the session on another Claude account;
  # `env` works whether the terminal runs the line through a shell or execs it.
  if [ -n "$cfg" ]; then
    [ -d "$cfg" ] || { say "dispatch: --config-dir $cfg is not a directory"; return 2; }
    env="env CLAUDE_CONFIG_DIR=$(_q "$cfg") "
  fi
  row=$(_find --path "$path") || { say "dispatch: $path is not a workspace of this repo"; return 1; }
  wt=$(_col "$row" 1); sel=$(_col "$row" 2); kind=$(_col "$row" 5); key=$(_col "$row" 6)
  [ -n "$name" ] || name=$(_col "$row" 7)
  mkdir -p "$STORE/briefs" || return 1
  dst="$STORE/briefs/${wt##*/}.md"
  [ "$brief" -ef "$dst" ] || cp "$brief" "$dst" || return 1
  # A workspace with a live agent session gets the brief in that session, never a second one
  # beside it (a second session overwrote the recorded one). Busy → refuse: typing into
  # a running turn could answer a permission prompt. --resume too: resuming a session that is
  # live elsewhere would run it twice.
  handle=$(_live_agent "$wt" "$sel"); rc=$?
  if [ "$rc" = 0 ]; then
    uuid=${resume:-$(_col "$row" 9)}
    tmp=$(mktemp "${TMPDIR:-/tmp}/hi-send.XXXXXX") || return 1
    printf 'Read %s and follow it.' "$dst" > "$tmp"
    js=$(HI_CONFIRMED=1 bash "$ORCA_SH" send "$handle" "$tmp" 2>/dev/null </dev/null)
    if [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
      rm -f "$tmp"
      _rec_set "$kind" "$key" dispatched send || say 'dispatch: could not record the dispatch'
      printf '%s\t%s\t%s\n' "$uuid" send "$handle"
      say "dispatched \"$name\" into its live session (terminal $handle)${uuid:+ — resume: cd $wt && claude --resume $uuid}"
      return 0
    fi
    rm -f "$tmp"
    say "dispatch: sending to the live session in $wt (terminal $handle) failed — not starting a second one; brief: $dst"
    return 1
  elif [ "$rc" = 3 ]; then
    uuid=${resume:-$(_col "$row" 9)}
    printf '%s\t%s\t%s\n' "$uuid" busy ''
    say "dispatch: a session is mid-turn in $wt — not starting a second one; give it $dst when it is idle, or rerun dispatch then"
    return 3
  elif [ "$rc" = 4 ]; then
    uuid=${resume:-$(_col "$row" 9)}
    printf '%s\t%s\t%s\n' "$uuid" chat ''
    say "dispatch: a chat session is open in $wt and Orca cannot type into a chat from the CLI — not starting a second one; paste \"Read $dst and follow it.\" into that chat, or close it and rerun dispatch"
    return 3
  fi
  handle=''
  # A new session is always an agent terminal, whatever the person's Chat/CLI setting
  # (`orca agent launch` would follow it): the next dispatch must be able to type into it,
  # and Orca's CLI cannot reach a chat — orchestration mail reaches only worker-start
  # workers, which are supervised, not handed off — nor give one --session-id, --add-dir
  # or the gortex wait. Measured on Orca 1.4.252 (highness#10).
  wrap=$(_track_wrap "$wt")
  # The worker's first Reads are the brief and the plugin's references (reference/*.md),
  # both outside its workspace: with blockReadsOutsideWorkingDirectories
  # each one is a permission prompt nobody watches. --add-dir takes several values, so
  # it goes before --session-id/--resume: an option ends its list, the prompt would not.
  # Both are read, never written: --settings denies edits there (_deny_edits).
  dirs="--add-dir $(_q "$STORE/briefs") --add-dir $(_q "$(_plugin_dir)") --settings $(_q "$(_deny_edits "$wt")")"
  if [ -n "$resume" ]; then
    uuid=$(printf '%s' "$resume" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    line="$wrap$env$(_q "$CLAUDE") $dirs --resume $uuid${DISPATCH_FLAGS:+ $DISPATCH_FLAGS} $(_q "Read $dst and follow it.")"
  else
    uuid=$(_uuid)
    [ -n "$uuid" ] || { say 'dispatch: cannot make a session id (no HI_UUID, uuidgen or /proc uuid)'; return 1; }
    line="$wrap$env$(_q "$CLAUDE") $dirs --session-id $uuid --name $(_q "$name")${DISPATCH_FLAGS:+ $DISPATCH_FLAGS} $(_q "Read $dst and follow it.")"
  fi

  if [ -n "$sel" ] && [ -n "$ORCA" ]; then
    js=$("$ORCA" terminal create --worktree "$(_osel "$sel" "$wt")" --title "$name" --command "$line" --json 2>/dev/null)
    if [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
      via=orca
      handle=$(printf '%s' "$js" | jq -r '.result.terminal.handle // .result.handle // ""' 2>/dev/null)
    else
      say "orca terminal create failed ($(printf '%s' "$js" | jq -r '.error.code // "no output"' 2>/dev/null)) — trying tmux"
    fi
  fi
  T=${HI_TMUX:-tmux}
  if [ "$via" = print ] && [ "$T" != none ] && command -v "$T" >/dev/null 2>&1; then
    "$T" has-session -t hi 2>/dev/null || "$T" new-session -d -s hi -c "$HOME" 2>/dev/null || T=none
    if [ "$T" != none ] && "$T" new-window -d -t hi: -n "$name" -c "$wt" "$line" 2>/dev/null; then
      via=tmux; handle="hi:$name"
    fi
  fi
  if [ -n "$cfg" ]; then
    _rec_set "$kind" "$key" session "$uuid" dispatched "$via" config_dir "$cfg" || say 'dispatch: could not record the session id'
  else
    _rec_set "$kind" "$key" session "$uuid" dispatched "$via" || say 'dispatch: could not record the session id'
  fi
  printf '%s\t%s\t%s\n' "$uuid" "$via" "$handle"
  [ "$via" = print ] && printf 'cd %s && %s\n' "$(_q "$wt")" "$line"
  say "dispatched \"$name\" ($via) — resume: cd $wt && ${cfg:+CLAUDE_CONFIG_DIR=$(_q "$cfg") }claude --resume $uuid"
  return 0
}

# _pr <kind> <key> <branch>: state<TAB>number<TAB>headRefOid (state lowercased), or none/unknown.
_pr() {
  local js
  if [ "$1" = review ]; then
    js=$(cd "$MAIN" && gh pr view "$2" --json state,number,headRefOid 2>/dev/null) || { echo unknown; return; }
    printf '%s' "$js" | jq -r '[(.state | ascii_downcase), .number, .headRefOid] | @tsv' 2>/dev/null || echo unknown
    return
  fi
  [ -n "$3" ] || { echo none; return; }
  # The PR's head is the branch on origin, which the local one may not be named after
  # (fix/x tracking origin/bug/x): the upstream's name first, then the local name.
  local up h t out=none
  up=$(git -C "$MAIN" for-each-ref --format='%(upstream:lstrip=3)' "refs/heads/$3" 2>/dev/null) || up=''
  # A branch cut from origin/main tracks it: the trunk is never a ticket's PR head (a release PR
  # from main would be read as this workspace's, and a fresh tree at its tip as merged).
  t=$(_trunk) && [ "$up" = "${t#origin/}" ] && up=''
  for h in $up "$3"; do
    js=$(cd "$MAIN" && gh pr list --head "$h" --state all --limit 1 --json state,number,headRefOid 2>/dev/null) ||
      { echo unknown; return; }
    out=$(printf '%s' "$js" | jq -r 'if length == 0 then "none"
      else (.[0] | [(.state | ascii_downcase), .number, .headRefOid] | @tsv) end' 2>/dev/null) || { echo unknown; return; }
    [ "$out" = none ] || break
    [ "$h" != "$3" ] || break
  done
  printf '%s\n' "$out"
}

# _memory_bad <wt>: prints the first gitignored file under .claude/memory that is not a link to
# the main checkout's copy (a regular file there forks the memory, and removing the workspace
# would lose it); exit 1 when all are links. Where the main checkout has no copy (memory linked
# per checkout from somewhere else), a link out of the tree is fine too.
_memory_bad() {
  local f t d wp
  wp=$(cd "$1" 2>/dev/null && pwd -P)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -L "$1/$f" ] && [ "$1/$f" -ef "$MAIN/$f" ] && continue
    if [ -L "$1/$f" ] && [ ! -e "$MAIN/$f" ] && [ ! -L "$MAIN/$f" ]; then
      t=$(readlink "$1/$f"); case "$t" in /*) ;; *) t="$(dirname "$1/$f")/$t" ;; esac
      d=$(cd "$(dirname "$t")" 2>/dev/null && pwd -P) || continue   # dangling: holds nothing
      case "$d/" in "$wp/"*) ;; *) continue ;; esac
    fi
    printf '%s\n' "$f"; return 0
  done <<EOF
$(git -C "$1" ls-files --others --ignored --exclude-standard -- .claude/memory 2>/dev/null)
EOF
  return 1
}

# _terminal <wt> <name> <sel>: none | idle | busy (Orca) | open (a tmux window of that name).
# Orca agents are agent terminals and chats (orca.sh agents); a bare shell never counts. A
# terminal Orca gave no status for is waited on (tui-idle, 2 s), as before #10.
_terminal() {
  local h kind v st=none busy=0 T
  if [ -n "$3" ] && [ -n "$ORCA" ]; then
    while IFS="$(printf '\t')" read -r h kind v; do
      [ -n "$h" ] || continue
      [ "$kind:$v" = terminal:unknown ] && { if _tui_idle "$h"; then v=idle; else v=busy; fi; }
      if [ "$v" = idle ]; then st=idle; else busy=1; fi
    done <<AGENTS
$(bash "$ORCA_SH" agents "$1" 2>/dev/null </dev/null)
AGENTS
    [ "$busy" = 1 ] && st=busy
    printf '%s\n' "$st"; return
  fi
  T=${HI_TMUX:-tmux}
  if [ "$T" != none ] && command -v "$T" >/dev/null 2>&1 &&
     "$T" list-windows -t hi -F '#{window_name}' 2>/dev/null | grep -Fxq -- "$2"; then
    st=open
  fi
  printf '%s\n' "$st"
}

# _trunk: the remote trunk (origin/HEAD, e.g. origin/main); exit 1 when origin/HEAD is unset.
_trunk() { git -C "$MAIN" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null; }

# _in_trunk <sha>: exit 0 when <sha> is reachable from the remote trunk, or its tree is (a squash
# merge), so nothing on it is lost.
_in_trunk() {
  local t
  t=$(_trunk) || return 1
  git -C "$MAIN" merge-base --is-ancestor "$1" "$t" 2>/dev/null && return 0
  # A squash (or rebase) merge leaves <sha> off trunk, yet a trunk commit since their fork
  # point carries its exact tree: nothing on it is lost either. The tree must differ from the
  # fork point's, or a branch of empty commits would match any empty trunk commit.
  local mb tree
  mb=$(git -C "$MAIN" merge-base "$1" "$t" 2>/dev/null) || return 1
  tree=$(git -C "$MAIN" rev-parse --verify --quiet "$1^{tree}") || return 1
  [ "$tree" != "$(git -C "$MAIN" rev-parse "$mb^{tree}")" ] || return 1
  git -C "$MAIN" log --format=%T "$mb..$t" 2>/dev/null | grep -Fxq "$tree" && return 0
  # Rebased onto trunk before it landed: new shas, so neither test above holds, yet
  # `git cherry` finds a patch-equivalent trunk commit for every one of them (all `-`). The
  # tree test above comes first: empty commits all share one patch id, so a branch of them
  # would match any empty trunk commit.
  local ch
  ch=$(git -C "$MAIN" cherry "$t" "$1" 2>/dev/null) || return 1
  [ -n "$ch" ] && ! printf '%s\n' "$ch" | grep -qv '^- '
}

# _landed <kind> <key> <branch> <head> [<path>]: exit 0 when the work landed in trunk with no PR (a personal
# repo fast-forwards into main): HEAD is in origin/<trunk> AND moved past the commit the workspace
# started at. That start is the record's `base`, else the branch's oldest reflog entry (trees made
# before `base` was recorded); with neither it is not landed — a fresh tree is also in trunk.
# A detached HEAD (empty <branch>, e.g. a merge done on `checkout --detach origin/main`) has no
# reflog to fall back on, so only the record's base can tell. <path>: the record's base
# is read only when the record is this tree's (_rec_owns); another tree of the key started elsewhere.
_landed() {
  local base=''
  [ "$1" != review ] && [ -n "$4" ] || return 1
  _in_trunk "$4" || return 1
  if [ -z "${5:-}" ] || _rec_owns "$1" "$2" "$5"; then
    base=$(_rec_get "$1" "$2" base 2>/dev/null) || base=''
  fi
  [ -z "$base" ] && [ -n "$3" ] &&
    base=$(git -C "$MAIN" reflog show --format=%H "refs/heads/$3" -- 2>/dev/null | tail -1)
  [ -n "$base" ] && [ "$base" != "$4" ]
}

# _state <row>: dirty pushed memory pr terminal age safe reasons (TSV). Read-only.
_state() {
  local row="$1" p b h kind key name sel pp dirty=0 pushed=- memory=ok prs pr oid='' term age now ct reasons=''
  p=$(_col "$row" 1); b=$(_col "$row" 3); h=$(_col "$row" 4); kind=$(_col "$row" 5)
  key=$(_col "$row" 6); name=$(_col "$row" 7); sel=$(_col "$row" 2)
  [ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ] && dirty=1
  _memory_bad "$p" >/dev/null && memory=unique
  prs=$(_pr "$kind" "$key" "$b")
  case "$prs" in
    none|unknown) pr=$prs ;;
    *) pr="$(_col "$prs" 1)#$(_col "$prs" 2)"; oid=$(_col "$prs" 3) ;;
  esac
  # An unreadable PR state does not block `landed`: the work is in trunk whatever a PR says, and a
  # repo off GitHub (Forgejo) never has a state gh can read, so it would never be removable.
  case "$pr" in none|unknown) _landed "$kind" "$key" "$b" "$h" "$p" && pr=landed ;; esac
  if [ "$kind" != review ]; then
    if [ -n "$oid" ] && [ "$h" = "$oid" ]; then pushed=yes
    elif [ -n "$(git -C "$p" branch -r --contains "$h" 2>/dev/null)" ]; then pushed=yes
    elif [ "$pr" = landed ] || _in_trunk "$h"; then pushed=yes   # its work is in trunk: nothing to lose
    else pushed=no; fi
  fi
  term=$(_terminal "$p" "$name" "$sel")
  now=$(date +%s); ct=$(git -C "$p" log -1 --format=%ct HEAD 2>/dev/null) || ct=$now
  age=$(( (now - ${ct:-$now}) / 86400 ))

  pp=$(cd "$p" 2>/dev/null && pwd -P)
  case "$CALLER_PWD/" in "$pp/"*) reasons="$reasons;cwd" ;; esac
  case "$pr" in
    open#*)  reasons="$reasons;pr-open" ;;
    unknown) reasons="$reasons;pr-unknown" ;;
    none)    if [ "$kind" = review ]; then reasons="$reasons;pr-unknown"; else reasons="$reasons;no-pr"; fi ;;
  esac
  [ "$dirty" = 1 ] && reasons="$reasons;dirty"
  [ "$pushed" = no ] && reasons="$reasons;unpushed"
  # A merged or closed PR finishes the work only at its own final head: a reused branch name
  # (a bounced ticket, an adopted branch, commits pushed after the merge) carries an old PR.
  case "$pr" in
    merged#*|closed#*) [ "$kind" != review ] && [ "$pushed" = yes ] && [ "$h" != "$oid" ] &&
                       reasons="$reasons;pr-stale" ;;
  esac
  [ "$memory" = unique ] && reasons="$reasons;memory"
  case "$term" in busy) reasons="$reasons;busy" ;; open) reasons="$reasons;open-window" ;; esac
  reasons=${reasons#;}
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$dirty" "$pushed" "$memory" "$pr" "$term" "$age" \
    "$([ -z "$reasons" ] && echo yes || echo no)" "$reasons"
}

_rows_state() {
  local rows row
  rows=$(_rows) || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    # </dev/null: gh and orca may read stdin, which here is the rest of the rows.
    printf '%s\t%s\n' "$row" "$(_state "$row" </dev/null)"
  done <<EOF
$rows
EOF
}

# _reason_text <code> <row> <state>: the sentence the owner reads.
_reason_text() {
  case "$1" in
    cwd)         echo 'this session is inside it' ;;
    pr-open)     echo "PR #$(_col "$3" 4 | sed 's/^open#//') is open" ;;
    pr-unknown)  echo 'cannot read the PR state (gh failed, or no PR found for this review)' ;;
    no-pr)       echo 'no PR, and no commit of its own in origin/HEAD yet (a fresh workspace, or work not landed)' ;;
    pr-stale)    echo "PR #$(_col "$3" 4 | sed 's/^[a-z]*#//') is $(_col "$3" 4 | sed 's/#.*//'), but HEAD $(_col "$2" 4 | cut -c1-8) is not its final head (new work on a reused branch?)" ;;
    dirty)       echo 'uncommitted changes' ;;
    unpushed)    echo "HEAD $(_col "$2" 4 | cut -c1-8) is neither the PR's final head nor on any remote branch" ;;
    memory)      echo ".claude/memory has a file that is not a link to the main checkout's copy: $(_memory_bad "$(_col "$2" 1)")" ;;
    busy)        echo 'an agent here is busy (a terminal or a chat)' ;;
    open-window) echo "its tmux window (hi:$(_col "$2" 7)) is still open" ;;
    live)        echo 'an agent session is open here (idle): it may be another session'"'"'s, and removing would close it' ;;
    work)        echo 'a work or scratch workspace: removed only when you ask, even when its branch is merged' ;;
    not-ticket)  echo "a $(_col "$2" 5) workspace: only a ticket workspace is removed unattended" ;;
    not-landed)  echo "not landed: its PR is $(_col "$3" 4 | sed 's/#.*//'), not merged, and its work is not in trunk" ;;
    *)           echo "$1" ;;
  esac
}

# _guard_target <path>: sets TROW, or exit 2. Only a workspace of THIS repo, never the main
# checkout (the row list excludes it), never the workspace the caller stands in.
_guard_target() {
  local p="${1:-}" pp
  [ -n "$p" ] || { say 'refusing an empty path'; return 2; }
  TROW=$(_find --path "$p" 2>/dev/null) || {
    say "$p is not a workspace of this repo (the main checkout, another repo, or not a worktree) — nothing removed"
    return 2; }
  pp=$(cd "$(_col "$TROW" 1)" 2>/dev/null && pwd -P)
  case "$CALLER_PWD/" in
    "$pp/"*) say "refusing to remove $(_col "$TROW" 1): this session is inside it"; return 2 ;;
  esac
  return 0
}

_close_terms() {
  local h
  for h in $(bash "$ORCA_SH" terminals "$1" 2>/dev/null | cut -f1); do
    "$ORCA" terminal close --terminal "$h" --json >/dev/null 2>&1 && say "closed terminal $h"
  done
}

_is_wt() { git -C "$MAIN" worktree list --porcelain | grep -Fxq "worktree $1"; }

# _gone <path> <secs>: prune until <path> is neither a directory nor a worktree, or <secs> pass.
_gone() {
  local end=$(( $(date +%s) + $2 ))
  while :; do
    git -C "$MAIN" worktree prune >/dev/null 2>&1
    [ -d "$1" ] || _is_wt "$1" || return 0
    [ "$(date +%s)" -lt "$end" ] || return 1
    sleep 0.5
  done
}

# _do_remove: removes TROW's workspace. 0 removed, 1 failed (nothing removed), 4 leaked.
_do_remove() {
  local p sel b h kind key name session js code out n td bnote wait rc=0
  p=$(_col "$TROW" 1); sel=$(_col "$TROW" 2); b=$(_col "$TROW" 3); h=$(_col "$TROW" 4); kind=$(_col "$TROW" 5)
  key=$(_col "$TROW" 6); name=$(_col "$TROW" 7); session=$(_col "$TROW" 9)
  [ -n "$p" ] || { say 'refusing an empty path'; return 1; }
  if [ -n "$sel" ] && [ -n "$ORCA" ]; then
    # --run-hooks: without it the repo's archive hook (test-DB teardown) is skipped.
    js=$("$ORCA" worktree rm --worktree "$(_osel "$sel" "$p")" --force --run-hooks --json 2>/dev/null)
    code=$(printf '%s' "$js" | jq -r '.error.code // empty' 2>/dev/null)
    if [ "$code" = worktree_archive_hook_failed ]; then
      say "the repo's archive hook failed, so Orca removed nothing: $(printf '%s' "$js" | jq -r '.error.message // "no message"' 2>/dev/null). Fix what it names and remove again; wt.sh never passes --allow-failed-archive-hook."
      return 1
    fi
  else
    td="${HI_WT_TEARDOWN:-$HERE/worktree-teardown.sh}"
    if [ -f "$td" ]; then (cd "$p" && bash "$td") >&2 || say "teardown exited $? (non-fatal)"; fi
    out=$(git -C "$MAIN" worktree remove --force "$p" 2>&1) || say "git worktree remove: $out"
  fi
  # The filesystem decides, never `ok`: Orca has answered ok:false for a removal that
  # happened, and root-owned files a container wrote survive both git and Orca. Both
  # backends answer once the tree is gone (Orca 1.4.245+, measured ~2.5 s on 1.4.252); the
  # short wait only covers a slow filesystem and ends as soon as the tree is gone.
  wait=${HI_WT_RM_WAIT:-15}
  _gone "$p" "$wait"
  if [ -d "$p" ]; then
    if _is_wt "$p"; then
      say "removal failed: $p is still a worktree after ${wait}s${code:+ (orca: $code $(printf '%s' "$js" | jq -r '.error.message // empty' 2>/dev/null))}"
      return 1
    fi
    n=$(find "$p" -type f 2>/dev/null | wc -l | tr -d ' ')
    say "LEAKED the directory $p ($n files): git no longer knows it, but files remain — usually root-owned files a container wrote. Clear it by hand: sudo rm -rf $p"
    rc=4
  fi
  [ "$kind" = review ] && git -C "$MAIN" update-ref -d "refs/hi-review/$key" >/dev/null 2>&1
  command -v "$GORTEX" >/dev/null 2>&1 && "$GORTEX" untrack "$p" >/dev/null 2>&1
  # The record is per key: clear it only when it names this tree, or removing an old tree of a
  # ticket would blank the live one's record.
  [ "$(_rec_get "$kind" "$key" workspace 2>/dev/null)" = "$p" ] &&
    _rec_set "$kind" "$key" workspace '' >/dev/null 2>&1
  # A branch whose work is proven in — its head is in origin/<trunk>, or its PR merged at that
  # head — is deleted: nothing is lost. Any other branch is kept: both backends leave it alone
  # (Orca keeps the branch on rm since 1.4.246 unless given --delete-branch, never passed here).
  bnote=''
  if [ -n "$b" ] && { _in_trunk "$h" || _merged_at "$kind" "$key" "$b" "$h"; }; then
    if git -C "$MAIN" show-ref --verify --quiet "refs/heads/$b" &&
       [ "$(git -C "$MAIN" rev-parse "refs/heads/$b")" != "$h" ]; then bnote=" — branch $b kept (it moved past ${h%"${h#????????}"})"
    else
      git -C "$MAIN" branch -D "$b" >/dev/null 2>&1
      bnote=" — branch $b deleted, its work is merged (back: git branch $b ${h%"${h#????????}"})"
    fi
  elif [ -n "$b" ]; then
    if git -C "$MAIN" show-ref --verify --quiet "refs/heads/$b"; then bnote=" — branch $b kept"
    else bnote=" — branch $b is gone; it was at $h: git branch $b $h"; fi
  fi
  say "removed \"$name\" ($p)$bnote${session:+ — resume the chat: claude --resume $session}"
  return "$rc"
}

# _merged_at <kind> <key> <branch> <head>: exit 0 when the branch's PR merged at exactly <head>.
_merged_at() {
  local prs
  [ "$1" != review ] || return 1
  prs=$(_pr "$1" "$2" "$3" </dev/null)
  [ "$(_col "$prs" 1)" = merged ] && [ "$(_col "$prs" 3)" = "$4" ]
}

cmd_remove() {
  local TROW
  _guard_target "${1:-}" || return 2
  _do_remove
}

cmd_remove_if_safe() {
  local TROW st reasons
  _guard_target "${1:-}" || return 2
  st=$(_state "$TROW"); reasons=$(_col "$st" 8)
  _remove_unless "$reasons" "$st"
}

# remove-if-landed <path>: remove-if-safe for a caller no one watches (an unattended watcher).
# Safe is not enough there: a PR closed unmerged is safe (nothing unpushed), and so is a work
# or scratch workspace whose branch equals trunk. So only a ticket workspace whose PR merged,
# or whose work is in trunk with no PR, is removed; anything else is `unsafe` lines, exit 3.
cmd_remove_if_landed() {
  local TROW st reasons
  _guard_target "${1:-}" || return 2
  st=$(_state "$TROW"); reasons=$(_col "$st" 8)
  [ "$(_col "$TROW" 5)" = ticket ] || reasons="${reasons:+$reasons;}not-ticket"
  case "$(_col "$st" 4)" in merged#*|landed) ;; *) reasons="${reasons:+$reasons;}not-landed" ;; esac
  _remove_unless "$reasons" "$st"
}

# _remove_unless <reasons> <state>: TROW's workspace is removed when <reasons> is empty; else
# one `unsafe` line per reason, exit 3.
_remove_unless() {
  local reasons=$1 st=$2 code
  if [ -n "$reasons" ]; then
    for code in $(printf '%s' "$reasons" | tr ';' ' '); do
      printf 'unsafe\t%s\t%s\n' "$code" "$(_reason_text "$code" "$TROW" "$st")"
    done
    return 3
  fi
  _close_terms "$(_col "$TROW" 1)"   # safe already means no busy agent: close the rest, shells too
  _do_remove
}

# sweep: every finished workspace (PR merged or closed, or landed in trunk with no PR). Safe → removed (or `leaked` / `failed`
# with the hint or the reason); unsafe → one `ask`
# line; the workspace this session stands in is skipped silently; unfinished ones untouched.
# A work (or scratch) workspace is always an `ask`: a branch equal to trunk reads as landed, but
# it can be a long-lived workspace someone is about to use. Only ticket and review
# workspaces are removed unasked. So is one with an idle agent (a terminal or a chat): safe
# means no BUSY agent, but an idle one is a session someone may come back to, and the sweep
# runs from another session that cannot tell whose it is (highness#13).
cmd_sweep() {
  local rows row st reasons pr p name code texts TROW rc err
  git -C "$MAIN" worktree prune >/dev/null 2>&1
  rows=$(_rows) || return 1
  # Every call in the loop reads /dev/null: the loop's stdin is the rows.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    st=$(_state "$row" </dev/null); reasons=$(_col "$st" 8); pr=$(_col "$st" 4)
    case "$pr" in merged#*|closed#*|landed) ;; *) continue ;; esac
    case ";$reasons;" in *";cwd;"*) continue ;; esac
    [ "$(_col "$row" 5)" = work ] && reasons="${reasons:+$reasons;}work"
    [ "$(_col "$st" 5)" = idle ] && reasons="${reasons:+$reasons;}live"
    p=$(_col "$row" 1); name=$(_col "$row" 7)
    if [ -z "$reasons" ]; then
      TROW=$row
      _close_terms "$p" </dev/null
      # stderr is passed through and kept: a failure or a leak becomes its own row, since the
      # skills render stdout only.
      err=$(_do_remove 2>&1 >/dev/null </dev/null); rc=$?
      [ -n "$err" ] && printf '%s\n' "$err" >&2
      case "$rc" in
        0) printf 'removed\t%s\t%s\n' "$p" "$name" ;;
        4) printf 'leaked\t%s\t%s\tsudo rm -rf %s\n' "$p" "$name" "$(_q "$p")" ;;
        *) printf 'failed\t%s\t%s\t%s\n' "$p" "$name" \
             "$(printf '%s\n' "$err" | sed -n 's/^wt: //p' | tail -1 | tr '\t' ' ')" ;;
      esac
    else
      texts=''
      for code in $(printf '%s' "$reasons" | tr ';' ' '); do
        texts="$texts; $(_reason_text "$code" "$row" "$st")"
      done
      printf 'ask\t%s\t%s\t%s\n' "$p" "$name" "${texts#; }"
    fi
  done <<EOF
$rows
EOF
  return 0
}

# review-head --pr N --base-ref B: fetch the PR head under a PRIVATE ref (never a branch, so it
# cannot collide with anyone's branches), forced so a force-push does not fail the review.
# Serves fork PRs too, through the base repo. Prints BASE<TAB>HEAD.
cmd_review_head() {
  local pr='' base_ref='' out head base
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)       pr="${2:-}";       shift 2 ;;
      --base-ref) base_ref="${2:-}"; shift 2 ;;
      *) say "review-head: unknown flag $1"; return 2 ;;
    esac
  done
  case "$pr" in ''|*[!0-9]*) say "review-head: --pr must be a plain PR number (got [$pr])"; return 2 ;; esac
  [ -n "$base_ref" ] || { say 'review-head: --base-ref <baseRefName> is required'; return 2; }
  base_ref=${base_ref#origin/}
  out=$(git -C "$MAIN" fetch --quiet origin "+pull/$pr/head:refs/hi-review/$pr" 2>&1) || {
    say "review-head: git fetch pull/$pr/head failed: $out"; return 1; }
  git -C "$MAIN" fetch --quiet origin "$base_ref" >/dev/null 2>&1 || true
  head=$(git -C "$MAIN" rev-parse --verify --quiet "refs/hi-review/$pr") || head=''
  [ -n "$head" ] || { say "review-head: refs/hi-review/$pr did not resolve"; return 1; }
  base=$(git -C "$MAIN" merge-base "$head" "origin/$base_ref" 2>/dev/null) || base=''
  [ -n "$base" ] || { say "review-head: no merge-base between $head and origin/$base_ref"; return 1; }
  printf '%s\t%s\n' "$base" "$head"
}

# board <path> <column>: put the workspace in that Orca board column. Prints one row,
# <result><TAB><path><TAB><name><TAB><detail>:
#   moved  (detail: the column)  · same (already there) · kept (detail: the column it sits in)
#   skip   (detail: why — git backend, no such column, Orca unreadable)
# The user's own moves win. The record's `board:` is the id this verb last set, and the verb
# moves only a workspace still sitting there; one with no record yet (made before boards) is
# adopted only from "In progress", where Orca puts every new workspace. Anything else was
# moved by hand: kept, and said. A workspace the user moves to where the verb would have put
# it is adopted again (`same` records it).
_board() {
  local row="$1" col="$2" p sel kind key name set want cur last js lbl
  p=$(_col "$row" 1); sel=$(_col "$row" 2); kind=$(_col "$row" 5); key=$(_col "$row" 6); name=$(_col "$row" 7)
  if [ -z "$sel" ]; then printf 'skip\t%s\t%s\tnot an Orca workspace\n' "$p" "$name"; return 0; fi
  set=$(bash "$BOARD_SH" set 2>&1) || {
    printf 'skip\t%s\t%s\t%s\n' "$p" "$name" "$(printf '%s' "$set" | sed 's/^board: //' | tr '\n' ' ')"; return 1; }
  want=$(printf '%s\n' "$set" | awk -F'\t' -v c="$col" '$3 == c { print $1; exit }')
  [ -n "$want" ] || { printf 'skip\t%s\t%s\tOrca has no %s column\n' "$p" "$name" "$col"; return 1; }
  js=$("$ORCA" worktree show --worktree "$(_osel "$sel" "$p")" --json 2>/dev/null </dev/null) || js=''
  [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = true ] || {
    printf 'skip\t%s\t%s\tOrca did not show the workspace\n' "$p" "$name"; return 1; }
  cur=$(printf '%s' "$js" | jq -r '.result.worktree.workspaceStatus // ""' 2>/dev/null)
  last=$(_rec_get "$kind" "$key" board 2>/dev/null) || last=''
  lbl=$(printf '%s\n' "$set" | awk -F'\t' -v i="$want" '$1 == i { print $2; exit }')
  if [ "$cur" = "$want" ]; then
    [ "$last" = "$want" ] || _rec_set "$kind" "$key" board "$want" || true
    printf 'same\t%s\t%s\t%s\n' "$p" "$name" "$lbl"; return 0
  fi
  if { [ -n "$last" ] && [ "$cur" = "$last" ]; } ||
     { [ -z "$last" ] && [ "$cur" = "$(printf '%s\n' "$set" | awk -F'\t' '$3 == "active" { print $1; exit }')" ]; }; then
    js=$("$ORCA" worktree set --worktree "$(_osel "$sel" "$p")" --workspace-status "$want" --json 2>/dev/null </dev/null) || js=''
    [ "$(printf '%s' "$js" | jq -r '.ok // false' 2>/dev/null)" = true ] || {
      printf 'skip\t%s\t%s\tOrca refused the move\n' "$p" "$name"; return 1; }
    _rec_set "$kind" "$key" board "$want" || say "board: moved, but the record could not be written"
    say "board: \"$name\" → $lbl"
    printf 'moved\t%s\t%s\t%s\n' "$p" "$name" "$lbl"; return 0
  fi
  lbl=$(printf '%s\n' "$set" | awk -F'\t' -v i="$cur" '$1 == i { print $2; exit }')
  printf 'kept\t%s\t%s\t%s\n' "$p" "$name" "${lbl:-${cur:-no column}}"
}

# board - : path<TAB>column lines on stdin (fd 3 here: the dispatcher points stdin at /dev/null),
# the workspaces listed once: listing costs seconds through the Orca bridge, so a caller moving
# many workspaces should not list once per workspace.
cmd_board() {
  local row
  if [ "${1:-}" = - ] && [ $# -eq 1 ]; then
    local rows p col phys rc=0
    rows=$(_rows) || return 1
    while IFS="$(printf '\t')" read -r p col; do
      [ -n "$p" ] && [ -n "$col" ] || continue
      phys=$(cd "$p" 2>/dev/null && pwd -P) || phys=''
      row=$(printf '%s\n' "$rows" | awk -F'\t' -v v="$p" -v phys="$phys" '$1 == v || (phys != "" && $1 == phys) { print; exit }')
      if [ -z "$row" ]; then say "board: no workspace at $p"; rc=1; continue; fi
      _board "$row" "$col" || rc=1
    done <&3
    return "$rc"
  fi
  [ $# -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || { say 'board: <path> <column> | board - (path<TAB>column lines on stdin)'; return 2; }
  row=$(_find --path "$1") || { say "board: no workspace at $1"; return 1; }
  _board "$row" "$2"
}

# waiting: n<TAB>name<TAB>workspace<TAB>session for every review whose record says `ready`.
cmd_waiting() {
  local f n
  while IFS= read -r f; do
    n=${f##*/}
    case "$n" in review-*.md) n=${n#review-}; n=${n%.md} ;; *) continue ;; esac
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$(_rec_get review "$n" status 2>/dev/null)" = ready ] || continue
    printf '%s\t%s\t%s\t%s\n' "$n" "$(_rec_get review "$n" name 2>/dev/null || echo "review #$n")" \
      "$(_rec_get review "$n" workspace 2>/dev/null)" "$(_rec_get review "$n" session 2>/dev/null)"
  done <<EOF
$(_rec_files)
EOF
  return 0
}

CALLER_PWD=$(pwd -P); REPO_FLAG=""
if [ "${1:-}" = --repo ]; then
  [ -n "${2:-}" ] && cd "$2" 2>/dev/null || { say "--repo: not a directory: [${2:-}]"; exit 2; }
  shift 2
  REPO_FLAG=1
fi
verb="${1:-}"; [ $# -gt 0 ] && shift
case "$verb" in
  rec|list|find|create|dispatch|remove-if-safe|remove-if-landed|remove|sweep|review-head|waiting|board) ;;
  *) usage ;;
esac
# Every command below reads /dev/null: the orca CLI (and gh) behind the verbs may drain stdin,
# and in a caller's `… | while read c; do wt.sh --repo "$c" sweep; done` that ate the rest of
# the clones, so the loop ran only the first (seen with the Orca backend only). The one
# verb that takes input, `board -`, reads it from fd 3.
exec 3<&0 </dev/null
# dispatch <path>: the path names its own clone. With no --repo, run as if from that
# clone's main checkout, so a session in an umbrella (or in another repo) can dispatch a
# workspace it just made with `--repo <clone> create`. The path goes absolute first: the cd
# would break a relative one.
if [ "$verb" = dispatch ] && [ -z "$REPO_FLAG" ] && [ -d "${1:-}" ]; then
  dp=$(cd "$1" && pwd) &&
    dm=$(git -C "$dp" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p') &&
    [ -n "$dm" ] && cd "$dm" 2>/dev/null && { shift; set -- "$dp" "$@"; }
fi
_repo || { say 'not inside a git work tree'; exit 2; }
if [ "$verb" = create ] && U=$(bash "$UMBRELLA_SH" root 2>/dev/null); then
  case " $* " in
    *" --umbrella "*|*" -h "*|*" --help "*) ;;
    *) say "create: $U is an umbrella repo (repos.txt) — a change to a nested clone gets that clone's workspace: wt.sh --repo <clone> create … (umbrella.sh repos lists them). Only a change to the umbrella's own files takes create --umbrella."
       exit 2 ;;
  esac
fi
# In an umbrella, list shows only the umbrella's own workspaces; the nested clones' live in
# each clone. Say so on stderr, or an empty table reads as "no workspaces here".
if [ "$verb" = list ] && U=$(bash "$UMBRELLA_SH" root 2>/dev/null); then
  clones=$(bash "$UMBRELLA_SH" repos 2>/dev/null | cut -f1 | sed 's|.*/||' | tr '\n' ' ')
  [ -n "$clones" ] && say "list: $U is an umbrella — this lists only its own workspaces; each nested clone's: wt.sh --repo <clone> list (clones: ${clones% })"
fi
[ "$verb" = rec ] || _backend || exit 1
case "$verb" in
  rec) cmd_rec "$@" ;;
  list) cmd_list "$@" ;;
  find) _find "$@" ;;
  create) cmd_create "$@" ;;
  dispatch) cmd_dispatch "$@" ;;
  remove) cmd_remove "$@" ;;
  remove-if-safe) cmd_remove_if_safe "$@" ;;
  remove-if-landed) cmd_remove_if_landed "$@" ;;
  sweep) cmd_sweep ;;
  review-head) cmd_review_head "$@" ;;
  board) cmd_board "$@" ;;
  waiting) cmd_waiting ;;
esac
