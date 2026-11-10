#!/usr/bin/env bash
# setup.sh — what a machine and a person need before the first /hi-crew:start, and what the repo
# in the cwd needs on top. Read-only: /hi:setup renders the rows, proposes one fix per gap and runs
# each only on a yes.
#
# Usage:
#   setup.sh status        one row per item: section<TAB>name<TAB>state<TAB>detail
#   setup.sh profile       the Claude Code config dir Orca starts workers under<TAB>why
#
# Sections and rows:
#   machine  jq, orca, launcher, plugin:<name> (each highness plugin), hi-crew (its crew.sh),
#            session-state (that hi-crew registers the session-state hooks),
#            orchestration, orca-skill, watch (these three from `crew.sh setup-status`), board
#   person   config, crew.agent, crew.model (from crew.sh), overlay
#   repo     orca-project, then every row of `repo-setup.sh status` except launcher and board,
#            which the machine section already has. Only inside a git work tree.
#
# hi never depends on hi-crew: its rows come from the crew.sh of the hi-crew plugin enabled in the
# worker profile, found through `claude plugin list --json`, and read `hi-crew off` without it.
#
# Seams: HI_ORCA (orca.sh), HI_CLAUDE (the claude binary, default claude), HI_CLAUDE_PROFILE
# (the worker profile, skipping Orca's account), HI_ORCA_STATE_DB / HI_ORCA_BOARD (board.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_BIN=${HI_CLAUDE:-claude}
PLUGINS='hi hi-crew hi-guard hi-docs'

_row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# Orca's own data dir on this box (where claude-profiles/ lives), or nothing.
_orca_dirs() {
  printf '%s\n' "$HOME/Library/Application Support/orca" "$HOME/.config/orca" "$HOME/AppData/Roaming/orca"
}

# The Claude Code config dir Orca starts a worker under: Orca's active managed Claude account
# (`orca account list`: result.claude.activeAccountId) has its own profile at
# <orca data>/claude-profiles/<id>/home; with none, Claude Code's default, ~/.claude.
cmd_profile() {
  if [ -n "${HI_CLAUDE_PROFILE:-}" ]; then printf '%s\tHI_CLAUDE_PROFILE\n' "$HI_CLAUDE_PROFILE"; return; fi
  local O id d
  if O=$(bash "$HERE/orca.sh" resolve 2>/dev/null) && command -v "$O" >/dev/null 2>&1; then
    id=$("$O" account list --json 2>/dev/null | jq -r '.result.claude.activeAccountId // empty' 2>/dev/null)
    if [ -n "$id" ]; then
      while IFS= read -r d; do
        [ -d "$d/claude-profiles/$id/home" ] || continue
        printf '%s\tOrca'"'"'s active Claude account\n' "$d/claude-profiles/$id/home"; return
      done <<EOF
$(_orca_dirs)
EOF
      printf '%s\tOrca'"'"'s active Claude account %s has no profile dir here; the current one\n' \
        "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$id"; return
    fi
  fi
  printf '%s\tno managed Claude account in Orca: Claude Code'"'"'s default\n' "$HOME/.claude"
}

# `claude plugin list --json` as the worker profile sees it.
_plugin_list() {
  CLAUDE_CONFIG_DIR=$1 "$CLAUDE_BIN" plugin list --json 2>/dev/null
}

# The enabled entry of plugin <name> that a worker in <top> loads: user scope, or a project scope
# at <top> (a team's committed settings). @highness and @skills-dir count alike. Prints
# id<TAB>scope<TAB>installPath, or nothing.
_enabled() {
  printf '%s' "$1" | jq -r --arg n "$2" --arg top "$3" '
    [ .[]? | select((.id // "") | startswith($n + "@")) | select(.enabled == true)
      | select(.scope == "user" or (.scope == "project" and $top != "" and .projectPath == $top)) ][0]
    // empty | [.id, .scope, (.installPath // "")] | @tsv' 2>/dev/null
}

rows_machine() {
  local prof why list p hit crew='' O ver js line
  if command -v jq >/dev/null 2>&1; then _row machine jq ok "$(command -v jq)"
  else _row machine jq missing 'hi and hi-crew read every Orca and Claude Code answer with jq'; fi

  js=$(bash "$HERE/orca.sh" available 2>/dev/null | head -1)
  if [ "$js" = ok ]; then
    O=$(bash "$HERE/orca.sh" resolve 2>/dev/null)
    ver=$("$O" status --json 2>/dev/null | jq -r '.result.runtime.appVersion // ""' 2>/dev/null)
    _row machine orca ok "${ver:-?} ($O)"
  elif [ -n "$js" ]; then
    _row machine orca "${js%%:*}" "${js#*: }"
  else
    _row machine orca unavailable 'orca.sh available printed nothing'
  fi

  bash "$HERE/repo-setup.sh" launcher | sed 's/^/machine	/'

  line=$(cmd_profile); prof=${line%%	*}; why=${line#*	}
  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    _row machine plugins unknown "no $CLAUDE_BIN on PATH"
  elif ! list=$(_plugin_list "$prof") || ! printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1; then
    _row machine plugins unknown "$CLAUDE_BIN plugin list --json failed for $prof"
  else
    for p in $PLUGINS; do
      hit=$(_enabled "$list" "$p" "${BASE:-}")
      if [ -n "$hit" ]; then
        _row machine "plugin:$p" on "$(printf '%s' "$hit" | cut -f1) ($(printf '%s' "$hit" | cut -f2)) in $prof — $why"
        [ "$p" = hi-crew ] && crew="$(printf '%s' "$hit" | cut -f3)/lib/crew.sh"
      else
        _row machine "plugin:$p" off "not enabled in $prof — $why"
      fi
    done
  fi

  if [ -n "$crew" ] && [ -f "$crew" ]; then
    CREW_ROWS=$(cd "${TOP:-.}" && ORCA_CLI_COMMAND=${O:-${ORCA_CLI_COMMAND:-}} bash "$crew" setup-status 2>/dev/null) || CREW_ROWS=''
    if [ -n "$CREW_ROWS" ]; then _row machine hi-crew ok "$crew"
    else _row machine hi-crew unknown "$crew has no setup-status: an older hi-crew, update it"; fi
    # The session-state hooks (highness#27): without them dispatch and the watch read the screen only.
    if grep -q 'session-state\.sh' "$(dirname "$(dirname "$crew")")/hooks/hooks.json" 2>/dev/null; then
      _row machine session-state ok "hi-crew's hooks keep each session's state"
    else
      _row machine session-state old "this hi-crew registers no session-state hooks: dispatch and the watch read the screen only; update it"
    fi
    printf '%s\n' "$CREW_ROWS" | awk -F'\t' 'NF >= 2 && $1 !~ /^crew\./ { print "machine\t" $0 }'
  else
    CREW_ROWS=''
    _row machine hi-crew off 'hi-crew is not enabled for workers: no orchestration, watch or crew rows'
  fi

  bash "$HERE/repo-setup.sh" board | sed 's/^/machine	/'
}

rows_person() {
  local f o key
  f=${HIGHNESS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/highness/config.json}
  if [ ! -f "$f" ]; then _row person config none "$f"
  elif ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then _row person config invalid "$f is not a JSON object"
  else _row person config ok "$f"; fi

  printf '%s\n' "$CREW_ROWS" | awk -F'\t' 'NF >= 2 && $1 ~ /^crew\./ { print "person\t" $0 }'

  [ -n "${TOP:-}" ] || return 0
  if [ -f "$TOP/.claude/highness.json" ]; then _row person overlay team-file "$TOP/.claude/highness.json"; return; fi
  o=$(git -C "$TOP" config --get remote.origin.url 2>/dev/null) || o=''
  o=${o%/}; o=${o%.git}; o=${o##*:}
  o=$(printf '%s\n' "$o" | awk -F/ 'NF >= 2 { print tolower($(NF-1) "/" $NF) }')
  if [ -z "$o" ]; then _row person overlay n/a 'no origin: no overlay can name this repo'; return; fi
  for key in "$o" "${o%%/*}"; do
    if [ -f "$f" ] && jq -e --arg k "$key" '.repos[$k] | type == "object"' "$f" >/dev/null 2>&1; then
      _row person overlay ok "repos[\"$key\"] in $f"; return
    fi
  done
  _row person overlay none "no .claude/highness.json in the repo and no repos[\"$o\"] or repos[\"${o%%/*}\"] in $f"
}

rows_repo() {
  local sel
  [ -n "${TOP:-}" ] || return 0
  if sel=$(bash "$HERE/orca.sh" repo-selector "$BASE" 2>/dev/null); then
    _row repo orca-project ok "$sel ($BASE)"
  elif bash "$HERE/orca.sh" available >/dev/null 2>&1; then
    _row repo orca-project missing "Orca has no repo at $BASE"
  else
    _row repo orca-project unknown 'Orca is not available'
  fi
  bash "$HERE/repo-setup.sh" status 2>/dev/null | awk -F'\t' '$1 != "launcher" && $1 != "board" { print "repo\t" $0 }'
}

case "${1:-}" in
  status|profile) ;;
  *) echo 'usage: setup.sh status | profile' >&2; exit 2 ;;
esac
TOP=''; BASE=''
if TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
  TOP=$(cd "$TOP" && pwd -P)
  BASE=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && BASE=$(dirname "$(cd "$BASE" && pwd -P)")
else
  TOP=''
fi
case "$1" in
  profile) cmd_profile ;;
  status) CREW_ROWS=''; rows_machine; rows_person; rows_repo ;;
esac
