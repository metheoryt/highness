#!/usr/bin/env bash
# repo-setup.sh — what one repo needs for hi workspaces: gortex, the Python type view, the
# Orca worktree hooks and the repo's worktree delegate. Everything except scaffold-delegate
# is read-only.
#
# Usage:
#   repo-setup.sh mode                local | commit
#   repo-setup.sh status              one row per item: name<TAB>state<TAB>detail
#   repo-setup.sh guard <path>        exit 0 when this mode allows writing <path>; 1 + reason
#   repo-setup.sh delegate-path       where the worktree delegate goes in this mode
#   repo-setup.sh scaffold-delegate   copy the template there; never overwrites
#
# Mode: `repo_setup.mode` from the highness config (config.sh: the repo's
# .claude/highness.json, then the user file). `commit` lets the skill commit files to the repo;
# `local` never writes a file the repo tracks. Unset or an unknown value → local, the side
# that writes less.
#
# Exit 2 on usage, 3 outside a git work tree. HI_GORTEX names the gortex binary (default
# gortex). HI_ORCA_DATA (newline-separated paths, may be empty) replaces the Orca data-file
# search.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GORTEX=${HI_GORTEX:-gortex}

_repo() {
  TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo 'repo-setup: not inside a git work tree' >&2; return 3; }
  TOP=$(cd "$TOP" && pwd -P)
  COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 3
  COMMON=$(cd "$COMMON" && pwd -P)
  BASE=$(dirname "$COMMON")
}

_mode() {
  local m
  m=$(cd "$TOP" && bash "$HERE/config.sh" get .repo_setup.mode 2>/dev/null) || m=''
  case "$m" in
    commit|local) MODE=$m; MODE_WHY='repo_setup.mode' ;;
    '') MODE=local; MODE_WHY='repo_setup.mode unset' ;;
    *) echo "repo-setup: unknown repo_setup.mode '$m' — using local" >&2
       MODE=local; MODE_WHY="repo_setup.mode '$m' unknown" ;;
  esac
}

_row() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

row_gortex() {
  command -v "$GORTEX" >/dev/null 2>&1 || { _row gortex absent 'no gortex binary (a machine-level install)'; return; }
  "$GORTEX" daemon status >/dev/null 2>&1 || { _row gortex down 'daemon not running'; return; }
  local raw st
  raw=$("$GORTEX" repos --json 2>/dev/null) || { _row gortex down 'gortex repos --json failed'; return; }
  st=$(printf '%s' "$raw" | jq -r --arg p "$TOP" '[.[]? | select(.path == $p)][0] // empty
        | if .stale then "stale" elif .indexed then "indexed" else "indexing" end' 2>/dev/null)
  if [ -n "$st" ]; then _row gortex tracked "$st"; else _row gortex untracked "$TOP"; fi
}

row_wiring() {
  local f
  if [ -f "$TOP/.mcp.json" ] && jq -e '.mcpServers.gortex' "$TOP/.mcp.json" >/dev/null 2>&1; then
    _row wiring repo .mcp.json; return
  fi
  # The one user config Claude Code reads: $CLAUDE_CONFIG_DIR/.claude.json when that is set,
  # else ~/.claude.json. A ~/.claude/.claude.json with CLAUDE_CONFIG_DIR unset is never read,
  # so counting it reported "machine" for a repo whose sessions got no gortex tools.
  f=${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}; f=${f:-$HOME/.claude.json}
  if [ -f "$f" ] && jq -e '.mcpServers.gortex' "$f" >/dev/null 2>&1; then _row wiring machine "$f"; return; fi
  _row wiring missing 'no gortex MCP server in the repo or the user config'
}

_is_python() { [ -f "$TOP/pyproject.toml" ] || [ -f "$TOP/setup.py" ] || ls "$TOP"/requirements*.txt >/dev/null 2>&1; }
_pp() { cat "$TOP/pyproject.toml" 2>/dev/null; }
# A [tool.<name>] or [tool.<name>.<sub>] table header.
_has_section() { grep -Eq "^\[tool\.$1[].]" <<<"$(_pp)"; }
# A dependency named exactly <name>: quoted in pyproject, a line start in requirements*.txt
# (prefixed with a quote here so one pattern serves both). "django-stubs[compatible-mypy]"
# and "mypy-baseline" do not match mypy. The class keeps `[` LAST: a leading `[=` opens a
# POSIX equivalence class and grep aborts with exit 2, which -q reads as "no match".
# Here-strings, not pipes, feed grep -q here: under pipefail a missing requirements file
# (cat exits 1) or grep -q closing the pipe early fails the pipeline even on a match.
_has_dep() {
  local txt
  txt=$(_pp; cat "$TOP"/requirements*.txt 2>/dev/null | sed 's/^/"/')
  grep -Eq "[\"']$1([]=<>~!; \"'[]|\$)" <<<"$txt"
}

row_checker() {
  _is_python || { _row checker n/a 'not a Python repo'; return; }
  local found=''
  { _has_section ty || [ -f "$TOP/ty.toml" ] || _has_dep ty; } && found="$found,ty"
  { _has_section mypy || [ -f "$TOP/mypy.ini" ] || [ -f "$TOP/.mypy.ini" ] || _has_dep mypy; } && found="$found,mypy"
  { _has_section pyright || [ -f "$TOP/pyrightconfig.json" ] || _has_dep pyright; } && found="$found,pyright"
  { _has_section basedpyright || _has_dep basedpyright; } && found="$found,basedpyright"
  if [ -n "$found" ]; then _row checker ok "${found#,}"; else _row checker none 'no type checker configured'; fi
}

row_ann() {
  _is_python || { _row ann n/a 'not a Python repo'; return; }
  local cfg
  if   [ -f "$TOP/ruff.toml" ];  then cfg=$(cat "$TOP/ruff.toml")
  elif [ -f "$TOP/.ruff.toml" ]; then cfg=$(cat "$TOP/.ruff.toml")
  elif _has_section ruff; then cfg=$(_pp | awk '/^\[tool\.ruff[].]/{f=1; print; next} /^\[/{f=0} f')
  else _row ann off 'no ruff'; return; fi
  local sel ign
  sel=$(_ruff_array "$cfg" select); ign=$(_ruff_array "$cfg" ignore)
  if ! grep -Eq "[\"'](ANN|ALL)[\"']" <<<"$sel"; then _row ann off 'ruff without ANN'
  elif grep -Eq "[\"']ANN[\"']" <<<"$ign"; then _row ann off 'ANN ignored'
  else _row ann on ruff; fi
}

# _ruff_array <ruff-config-text> select|ignore: the contents of every select / extend-select
# (or ignore / extend-ignore) array, bare or lint.-prefixed, in the top-level or lint table.
# Sub-tables such as per-file-ignores do not count. Arrays may span lines; # comments go.
_ruff_array() {
  awk -v want="$2" '
    { line = $0; sub(/#.*/, "", line) }
    cap { buf = buf line; if (line ~ /\]/) cap = 0; next }
    /^[ \t]*\[/ { h = line; gsub(/[ \t]/, "", h)
                  ok = (h == "[tool.ruff]" || h == "[tool.ruff.lint]" || h == "[lint]"); seen = 1; next }
    (ok || !seen) && line ~ ("^[ \t]*(lint[.])?(extend-)?" want "[ \t]*=") {
      sub(/^[^=]*=/, "", line); buf = buf line; if (line !~ /\]/) cap = 1 }
    END { print buf }' <<<"$1"
}

# The Orca hooks. Orca runs a worktree's setup and archive scripts from two sources: the repo's
# committed orca.yaml (`scripts.setup`, `scripts.archive`; each person approves its commands
# once) and the person's own hook fields in Orca's settings. Per repo,
# hookSettings.commandSourcePolicy picks: local-only, run-both or shared-only; unset means
# local-only when the person has a local script for that slot, else shared-only — so a
# leftover local script silently shadows a committed orca.yaml. The recipe is orca.yaml with
# YAML_SETUP / YAML_ARCHIVE below; `orca-setup` / `orca-archive` say what Orca will run.
LAUNCHER="${HIGHNESS_BIN_DIR:-$HOME/.local/bin}/highness"
YAML_SETUP='"$HOME/.local/bin/highness" worktree-setup || true'
YAML_ARCHIVE='"$HOME/.local/bin/highness" worktree-teardown || true'

# _expect setup|archive: the local hook values that count as ours, the preferred first, then
# older forms that still work, then the config's repo_setup.accept.<slot> list.
_expect() {
  local w=setup; [ "$1" = archive ] && w=teardown
  printf '%s\n' "\"\$HOME/.local/bin/highness\" worktree-$w || true" "\"\$HOME/.local/bin/highness\" worktree-$w" \
    "highness worktree-$w || true" "highness worktree-$w"
  (cd "$TOP" && bash "$HERE/config.sh" list ".repo_setup.accept.$1" 2>/dev/null)
}

# _ours setup|archive <command>: does the command run highness's worktree-setup / -teardown?
_ours() {
  local w=setup; [ "$1" = archive ] && w=teardown
  printf '%s' "$2" | grep -Eq "highness\"?[[:space:]]+worktree-$w([^a-z-]|\$)"
}

# _yaml_scripts <orca.yaml>: `setup<TAB>value` / `archive<TAB>value` for the slots it sets
# under a top-level `scripts:` map; a block scalar's lines are joined with "; ". A flow-style
# `scripts: {…}` is not read: `flow<TAB>` instead. Plain awk, no YAML library.
_yaml_scripts() {
  awk '
    function emit(k, v) { gsub(/\t/, " ", v); print k "\t" v }
    function unq(v,   c) {
      c = substr(v, 1, 1)
      if (c == "\047") { v = substr(v, 2); sub(/\047[ \t]*(#.*)?$/, "", v); gsub(/\047\047/, "\047", v); return v }
      if (c == "\"") { v = substr(v, 2); sub(/"[ \t]*(#.*)?$/, "", v); gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v); return v }
      sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v); return v
    }
    {
      line = $0; sub(/\r$/, "", line)
      if (blk != "") {
        if (line ~ /^[ \t]*$/) next
        match(line, /^ */)
        if (RLENGTH > kind) { t = line; sub(/^ +/, "", t); bv = (bv == "" ? t : bv "; " t); next }
        emit(blk, bv); blk = ""
      }
      if (line ~ /^[^ \t#]/) {
        insc = 0
        if (line ~ /^scripts:/) {
          rest = line; sub(/^scripts:[ \t]*/, "", rest); sub(/^#.*/, "", rest)
          if (rest == "") insc = 1; else print "flow\t"
        }
        next
      }
      if (!insc) next
      if (line ~ /^ +(setup|archive):/) {
        match(line, /^ */); kind = RLENGTH
        key = substr(line, kind + 1); v = key; sub(/:.*/, "", key); sub(/^[a-z]+:[ \t]*/, "", v)
        if (v ~ /^[|>]/) { blk = key; bv = ""; next }
        emit(key, unq(v))
      }
    }
    END { if (blk != "") emit(blk, bv) }' "$1" 2>/dev/null
}

# Sets Y_setup / Y_archive to ours | other | none and Y_setup_v / Y_archive_v to the command;
# prints the orca-yaml row. Orca reads orca.yaml from the repo's main checkout.
row_yaml() {
  local f="$BASE/orca.yaml" out slot val n=0 tr st det
  Y_setup=none; Y_archive=none; Y_setup_v=''; Y_archive_v=''
  if [ ! -f "$f" ]; then _row orca-yaml none "no orca.yaml at $BASE"; return; fi
  tr=untracked; git -C "$BASE" ls-files --error-unmatch -- orca.yaml >/dev/null 2>&1 && tr=committed
  out=$(_yaml_scripts "$f")
  if printf '%s\n' "$out" | grep -q '^flow'; then
    _row orca-yaml other "$tr; scripts: is in flow style ({…}), which this check does not read — use the block form"; return
  fi
  while IFS= read -r slot; do
    [ -n "$slot" ] || continue
    val=${slot#*	}; slot=${slot%%	*}
    case "$slot" in
      setup)   Y_setup_v=$val;   if _ours setup "$val"; then Y_setup=ours; else Y_setup=other; fi ;;
      archive) Y_archive_v=$val; if _ours archive "$val"; then Y_archive=ours; else Y_archive=other; fi ;;
    esac
  done <<EOF
$out
EOF
  [ "$Y_setup" = ours ] && n=$((n + 1)); [ "$Y_archive" = ours ] && n=$((n + 1))
  if [ "$n" = 2 ]; then st=wired
  elif [ "$n" = 1 ]; then st=partial
  elif [ "$Y_setup$Y_archive" != nonenone ]; then st=other
  else st=unwired; fi
  det="$tr; setup: ${Y_setup_v:-unset}; archive: ${Y_archive_v:-unset}"
  _row orca-yaml "$st" "$det"
}

# Every Orca data file on this box: one machine can host a Windows Orca and a WSL one.
# Per profile, profile-state.db wins: since Orca moved state into SQLite the
# orca-data.json beside it is frozen and reads as ABSENT for any repo added later.
# Without sqlite3 the frozen JSON is the best there is.
_orca_files() {
  if [ -n "${HI_ORCA_DATA+x}" ]; then printf '%s\n' "$HI_ORCA_DATA"; return; fi
  local d
  for d in "$HOME/.config/orca/profiles/local-default" \
           "$HOME/Library/Application Support/orca/profiles/local-default" \
           "$HOME/AppData/Roaming/orca/profiles/local-default" \
           /mnt/c/Users/*/AppData/Roaming/orca/profiles/local-default; do
    if [ -f "$d/profile-state.db" ] && command -v sqlite3 >/dev/null 2>&1; then
      printf '%s\n' "$d/profile-state.db"
    elif [ -f "$d/orca-data.json" ]; then
      printf '%s\n' "$d/orca-data.json"
    fi
  done
}
_rank() {
  case "$1" in WIRED) echo 7 ;; LEGACY) echo 6 ;; TWICE) echo 5 ;; SHADOWED) echo 4 ;; CONFLICT) echo 3 ;;
               UNWIRED) echo 2 ;; ABSENT) echo 1 ;; *) echo 0 ;; esac
}

# _effective <tok> <local-value> <policy> <yaml: ours|other|none> <yaml-value>: what Orca runs
# for one slot, as STATE<TAB>detail. tok is orca-status.sh's verdict on the local hook field.
_effective() {
  local tok=$1 val=$2 pol=$3 y=$4 yv=$5 has=0 ours=0 eff rl=0 ry=0 n=0 pd st d
  if [ "$tok" = ABSENT ]; then
    if [ "$y" = ours ]; then printf 'ABSENT\torca.yaml is wired; Orca does not list the repo yet'
    else printf 'ABSENT\tOrca does not list the repo'; fi
    return
  fi
  case "$tok" in WIRED|LEGACY|CONFLICT) has=1 ;; esac
  case "$tok" in WIRED|LEGACY) ours=1 ;; esac
  case "$pol" in
    local-only|run-both|shared-only) eff=$pol; pd="policy $pol" ;;
    *) if [ "$has" = 1 ]; then eff=local-only; else eff=shared-only; fi; pd="policy unset → $eff" ;;
  esac
  [ "$has" = 1 ] && [ "$eff" != shared-only ] && rl=1
  [ "$y" != none ] && [ "$eff" != local-only ] && ry=1
  [ "$rl" = 1 ] && [ "$ours" = 1 ] && n=$((n + 1))
  [ "$ry" = 1 ] && [ "$y" = ours ] && n=$((n + 1))
  if [ "$n" = 2 ]; then
    printf 'TWICE\tboth orca.yaml and the local hook run it (%s)' "$pd"
  elif [ "$n" = 1 ]; then
    if [ "$rl" = 1 ] && [ "$ours" = 1 ]; then
      st=WIRED; [ "$tok" = LEGACY ] && st=LEGACY
      d="the local hook${val:+ [$val]}"; [ "$ry" = 1 ] && d="$d; orca.yaml also runs [$yv]"
    else
      st=WIRED; d='orca.yaml'; [ "$rl" = 1 ] && d="$d; the local hook also runs [$val]"
    fi
    printf '%s\tvia %s (%s)' "$st" "$d" "$pd"
  elif [ "$y" = ours ]; then
    printf 'SHADOWED\torca.yaml is wired, but %s runs only the local hook%s' "$pd" "${val:+ [$val]}"
  elif [ "$rl" = 1 ]; then
    printf 'CONFLICT\truns the local hook [%s] (%s)' "$val" "$pd"
  elif [ "$ry" = 1 ]; then
    printf 'CONFLICT\truns orca.yaml'"'"'s [%s] (%s)' "$yv" "$pd"
  else
    printf 'UNWIRED\tnothing runs (%s)' "$pd"
  fi
}

rows_orca() {
  local origin f out slot tok val r pol e es ea
  local s_tok=ABSENT s_rank=0 s_det='no Orca data file' a_tok=ABSENT a_rank=0 a_det='no Orca data file'
  origin=$(git -C "$TOP" remote get-url origin 2>/dev/null || true)
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    out=$(bash "$HERE/orca-status.sh" "$f" "$origin" "$(_expect setup)" "$(_expect archive)" "$BASE")
    pol=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "policy" { print $2; exit }')
    es=''; ea=''
    while IFS= read -r e; do
      slot=$(printf '%s' "$e" | cut -f1); tok=$(printf '%s' "$e" | cut -f2); val=$(printf '%s' "$e" | cut -f3-)
      case "$slot" in
        setup)   es=$(_effective "$tok" "$val" "$pol" "$Y_setup" "$Y_setup_v") ;;
        archive) ea=$(_effective "$tok" "$val" "$pol" "$Y_archive" "$Y_archive_v") ;;
      esac
    done <<EOF
$out
EOF
    tok=${es%%	*}; r=$(_rank "$tok")
    [ "$r" -gt "$s_rank" ] && { s_rank=$r; s_tok=$tok; s_det="${es#*	} @ $f"; }
    tok=${ea%%	*}; r=$(_rank "$tok")
    [ "$r" -gt "$a_rank" ] && { a_rank=$r; a_tok=$tok; a_det="${ea#*	} @ $f"; }
  done <<EOF
$(_orca_files)
EOF
  _row orca-setup "$s_tok" "$s_det"
  _row orca-archive "$a_tok" "$a_det"
}

# The launcher Orca's hooks call: ok (it execs an existing bin/highness), stale (that plugin
# version is gone; the next session start rewrites it), missing, or foreign (not ours).
row_launcher() {
  local f=$LAUNCHER t
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    _row launcher missing "$f — written at the next Claude Code session start with the hi plugin enabled"; return
  fi
  grep -q '^# highness launcher' "$f" 2>/dev/null || { _row launcher foreign "$f is not the hi launcher"; return; }
  t=$(sed -n "s/^exec bash '\(.*\)' \"\\\$@\"\$/\1/p" "$f" | sed "s/'\\\\''/'/g")
  if [ -n "$t" ] && [ -f "$t" ]; then _row launcher ok "$f → $t"
  else _row launcher stale "$f → ${t:-?} (gone; the next session start rewrites it)"; fi
}

TEMPLATE="$HERE/../reference/worktree-setup.template.sh"
CANDIDATES='.orca/worktree-setup.sh docker/worktree-setup.sh .worktree/setup.sh scripts/worktree-setup.sh'

# Absolute physical path for <p>, which need not exist: walk up to the first existing
# directory, resolve that, then re-append the rest. A `..` in the part that does not exist
# cannot be resolved honestly (the kernel never walks it), so it fails: exit 1.
_abs() {
  local p="$1" tail=''
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$(dirname "$p")" ]; do tail="/$(basename "$p")$tail"; p=$(dirname "$p"); done
  case "/$(basename "$p")$tail/" in */../*) return 1 ;; esac
  printf '%s/%s%s\n' "$(cd "$(dirname "$p")" && pwd -P)" "$(basename "$p")" "$tail"
}

# The top of whichever worktree of THIS repo holds <abs-path> (longest match), or nothing.
# A linked worktree's session can reach the main checkout and its siblings by path, and
# those are the same work repo.
_owning_top() {
  local line w best=''
  while IFS= read -r line; do
    case "$line" in "worktree "*) ;; *) continue ;; esac
    w=${line#worktree }; [ -d "$w" ] || continue
    w=$(cd "$w" && pwd -P)
    case "$1" in "$w"/*) [ "${#w}" -gt "${#best}" ] && best=$w ;; esac
  done <<EOF
$(git -C "$TOP" worktree list --porcelain 2>/dev/null)
EOF
  printf '%s\n' "$best"
}

cmd_guard() {
  [ -n "${1:-}" ] || { echo 'usage: repo-setup.sh guard <path>' >&2; return 2; }
  [ "$MODE" = local ] || return 0
  local p rel top t hops=0
  p=$(_abs "$1") || { echo "guard: $1 has '..' under a directory that does not exist — refused" >&2; return 1; }
  # A write follows a symlink, so judge where it lands.
  while [ -L "$p" ] && [ "$hops" -lt 8 ]; do
    t=$(readlink "$p"); case "$t" in /*) ;; *) t="$(dirname "$p")/$t" ;; esac
    p=$(_abs "$t") || { echo "guard: $1 is a symlink into a path that cannot be resolved — refused" >&2; return 1; }
    hops=$((hops + 1))
  done
  [ -L "$p" ] && { echo "guard: $1 is a symlink chain too deep — refused" >&2; return 1; }
  case "$p" in "$COMMON"/*) return 0 ;; esac
  top=$(_owning_top "$p")
  [ -n "$top" ] || return 0
  rel=${p#"$top"/}
  if git -C "$top" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    echo "guard: $rel is tracked by the repo — local mode never writes it; print it as a proposal" >&2; return 1
  fi
  git -C "$top" check-ignore -q -- "$rel" && return 0
  echo "guard: $rel is not ignored — the write would show up in git status; print it as a proposal" >&2
  return 1
}

cmd_delegate_path() {
  if [ "$MODE" = local ]; then printf '%s\n' "$COMMON/hi/worktree-setup.sh"
  else printf '%s\n' "$TOP/.orca/worktree-setup.sh"; fi
}

cmd_scaffold() {
  local dest; dest=$(cmd_delegate_path)
  if [ -e "$dest" ]; then
    diff -u "$dest" "$TEMPLATE" || true
    echo "scaffold: $dest exists — not overwritten" >&2; return 1
  fi
  cmd_guard "$dest" || return 1
  mkdir -p "$(dirname "$dest")" && cp "$TEMPLATE" "$dest" && chmod +x "$dest" || return 1
  printf '%s\n' "$dest"
}

# The local delegate is <git-common-dir>/hi/worktree-setup.sh; an older us/ one still runs
# (worktree-setup.sh falls back to it), so it counts too.
row_delegate() {
  local rel found='' loc='' st
  for rel in $CANDIDATES; do
    [ -x "$TOP/$rel" ] && git -C "$TOP" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && found="$found,$rel"
  done
  if [ -x "$COMMON/hi/worktree-setup.sh" ]; then loc="$COMMON/hi/worktree-setup.sh"
  elif [ -x "$COMMON/us/worktree-setup.sh" ]; then loc="$COMMON/us/worktree-setup.sh"; fi
  if   [ -n "$found" ] && [ -n "$loc" ]; then st=both; found="$found,$loc"
  elif [ -n "$found" ]; then st=committed
  elif [ -n "$loc" ]; then st=local; found=",$loc"
  else st=none; found=',no delegate'; fi
  _row delegate "$st" "${found#,}"
}

case "${1:-}" in
  mode|status|guard|delegate-path|scaffold-delegate) ;;
  *) echo 'usage: repo-setup.sh mode | status | guard <path> | delegate-path | scaffold-delegate' >&2; exit 2 ;;
esac
_repo || exit 3
_mode
case "$1" in
  mode) printf '%s\n' "$MODE" ;;
  status)
    _row mode "$MODE" "$MODE_WHY"
    row_gortex; row_wiring; row_checker; row_ann; row_launcher; row_yaml; rows_orca; row_delegate ;;
  guard)             shift; cmd_guard "$@" ;;
  delegate-path)     cmd_delegate_path ;;
  scaffold-delegate) cmd_scaffold ;;
esac
