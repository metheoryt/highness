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
#   machine  jq, orca, launcher, plugin:<name> (each highness plugin in the worker profile: on,
#            off or double, with its source: a skills-dir link or a marketplace),
#            profile:<dir> (every other Claude config dir Orca uses: ok, or gaps against the
#            worker profile's set), pins:<installed_plugins.json> (stale project pins) or pins ok,
#            hi-crew (its crew.sh),
#            session-state (that hi-crew registers the session-state hooks),
#            orchestration, orca-skill, watch (these three from `crew.sh setup-status`), board
#   person   config, crew.agent, crew.model, tracker (from crew.sh; tracker only when one is
#            configured), overlay
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
# Every plugin of this marketplace (.claude-plugin/marketplace.json; setup_test.sh holds them equal).
PLUGINS='hi hi-crew hi-guard hi-threads hi-review hi-docs'

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

# Every enabled entry of plugin <name> that a session in <top> loads: user scope, or a project
# scope at <top> (a team's committed settings). @highness and @skills-dir count alike; more than
# one line is the plugin loaded twice. Prints id<TAB>scope<TAB>installPath per entry.
_enabled() {
  printf '%s' "$1" | jq -r --arg n "$2" --arg top "$3" '
    .[]? | select((.id // "") | startswith($n + "@")) | select(.enabled == true)
      | select(.scope == "user" or (.scope == "project" and $top != "" and .projectPath == $top))
      | [.id, .scope, (.installPath // "")] | @tsv' 2>/dev/null
}

# Where one enabled entry comes from: a link in the skills dir (to a working copy: a local edit
# changes sessions without a release) or a marketplace install.
_source() { # <id> <installPath>
  local t
  case "$1" in
    *@skills-dir)
      t=$(cd -P "$2" 2>/dev/null && pwd -P) || t=$2
      printf 'link → %s' "$t" ;;
    *) printf 'marketplace %s' "${1#*@}" ;;
  esac
}

# The entries of _enabled as one phrase: "<id> (<scope>, <source>); …".
_entries() {
  local id sc ip out=''
  while IFS='	' read -r id sc ip; do
    [ -n "$id" ] || continue
    out="$out${out:+; }$id ($sc, $(_source "$id" "$ip"))"
  done <<EOF
$1
EOF
  printf '%s' "$out"
}

# Every Claude Code config dir Orca uses, the worker profile first: Orca's
# claude-observed-config-dirs.json (a JSON array of paths) and each claude-profiles/*/home.
# One line per existing dir, deduplicated by physical path.
_config_dirs() { # <worker profile>
  local d o p seen='' phys
  {
    printf '%s\n' "$1"
    while IFS= read -r o; do
      [ -n "$o" ] || continue
      [ -f "$o/claude-observed-config-dirs.json" ] \
        && jq -r '.[]? | strings' "$o/claude-observed-config-dirs.json" 2>/dev/null
      for p in "$o"/claude-profiles/*/home; do [ -d "$p" ] && printf '%s\n' "$p"; done
    done <<EOF
$(_orca_dirs)
EOF
  } | while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    phys=$(cd -P "$d" 2>/dev/null && pwd -P) || continue
    case "$seen" in *"
$phys
"*) continue ;; esac
    seen="$seen
$phys
"
    printf '%s\n' "$d"
  done
}

# Project-scope pins of highness plugins whose project dir is gone (an old worktree): reopening a
# workspace at that path loads the pinned, older code. Reads <dir>/plugins/installed_plugins.json;
# prints id<TAB>projectPath per stale pin.
_stale_pins() { # <installed_plugins.json>
  local id pp p
  jq -r '.plugins // {} | to_entries[] | .key as $k | .value[]?
         | select(.scope == "project" or .scope == "local") | [$k, (.projectPath // "")] | @tsv' \
    "$1" 2>/dev/null | while IFS='	' read -r id pp; do
    [ -n "$pp" ] && [ ! -d "$pp" ] || continue
    for p in $PLUGINS; do
      case "$id" in "$p"@*) printf '%s\t%s\n' "$id" "$pp"; break ;; esac
    done
  done
}

# The rows for every other config dir and the stale pins of all of them.
# <worker profile> <the plugins the worker profile loads, space-separated>
rows_profiles() {
  local prof=$1 want=$2 d list p hits n off dbl state file files='' phys pins any=''
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    file="$d/plugins/installed_plugins.json"
    if [ -f "$file" ]; then
      phys="$(cd -P "$(dirname "$file")" && pwd -P)/installed_plugins.json"
      case "$files" in *"
$phys
"*) ;; *)
        files="$files
$phys
"
        pins=$(_stale_pins "$file" | awk -F'\t' '{ printf "%s%s → %s", (NR > 1 ? "; " : ""), $1, $2 }')
        if [ -n "$pins" ]; then _row machine "pins:$file" stale "$pins"; any=1; fi ;;
      esac
    fi
    [ "$d" = "$prof" ] && continue
    if ! list=$(_plugin_list "$d") || ! printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1; then
      _row machine "profile:$d" unknown "$CLAUDE_BIN plugin list --json failed"; continue
    fi
    off=''; dbl=''
    for p in $PLUGINS; do
      hits=$(_enabled "$list" "$p" "${BASE:-}")
      n=$(printf '%s' "$hits" | grep -c .)
      if [ "$n" -gt 1 ]; then dbl="$dbl${dbl:+; }$p twice: $(_entries "$hits")"
      elif [ "$n" -eq 0 ]; then
        case " $want " in *" $p "*) off="$off${off:+, }$p" ;; esac
      fi
    done
    state=ok
    if [ -n "$off" ] || [ -n "$dbl" ]; then state=gaps; fi
    if [ "$state" = ok ]; then
      _row machine "profile:$d" ok "loads the worker profile's highness plugins, each once"
    else
      _row machine "profile:$d" gaps "${off:+off: $off}${off:+${dbl:+ | }}${dbl:+double: $dbl}"
    fi
  done <<EOF
$(_config_dirs "$prof")
EOF
  [ -n "$any" ] || _row machine pins ok 'no project pin of a highness plugin points at a dir that is gone'
}

rows_machine() {
  local prof why list p hit n loaded='' crew='' O ver js line
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
      n=$(printf '%s' "$hit" | grep -c .)
      if [ "$n" -gt 1 ]; then
        _row machine "plugin:$p" double "loaded twice in $prof: $(_entries "$hit") — $why"
      elif [ "$n" -eq 1 ]; then
        _row machine "plugin:$p" on "$(_entries "$hit") in $prof — $why"
      else
        _row machine "plugin:$p" off "not enabled in $prof — $why"
      fi
      if [ "$n" -gt 0 ]; then
        loaded="$loaded $p"
        [ "$p" = hi-crew ] && crew="$(printf '%s\n' "$hit" | head -1 | cut -f3)/lib/crew.sh"
      fi
    done
    rows_profiles "$prof" "$loaded"
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
    printf '%s\n' "$CREW_ROWS" | awk -F'\t' 'NF >= 2 && $1 !~ /^(crew\.|tracker$)/ { print "machine\t" $0 }'
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

  printf '%s\n' "$CREW_ROWS" | awk -F'\t' 'NF >= 2 && $1 ~ /^(crew\.|tracker$)/ { print "person\t" $0 }'

  [ -n "${TOP:-}" ] || return 0
  if [ -f "$TOP/.claude/highness.json" ]; then _row person overlay team-file "$TOP/.claude/highness.json"; return; fi
  # A child clone of an umbrella takes the umbrella's team file (config.sh): say which one.
  if key=$(cd "$TOP" && bash "$HERE/config.sh" root 2>/dev/null) && [ -n "$key" ]; then
    _row person overlay team-file "$key/.claude/highness.json (the umbrella that lists this clone)"; return
  fi
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
