#!/usr/bin/env bash
# budget.sh — may a background agent spend this account's plan right now?
#
#   budget.sh check [<config dir>]   one line saying why; exit 0 = go, 1 = hold
#   budget.sh show  [<config dir>]   window<TAB>used%<TAB>line%<TAB>resets_at (epoch or -), one per window
#   budget.sh room                   Orca's other Claude accounts under their line now (cmd_room)
#   budget.sh starts <n> [<config dir>]
#                                    before n manual starts: each window's remainder above the
#                                    reserve and how many starts it fits (cmd_starts); exit 0 =
#                                    they fit, 1 = a warning. It never decides: the person's
#                                    "start" wins.
#
# The person keeps a reserve of each plan window for their own sessions, and the reserve shrinks
# as the window nears its reset — the leftover of a window about to reset is lost anyway:
#
#   agents may run while  used% < 100 - reserve × (time left / window length)
#
# With the default reserve of 50, a fresh 5-hour window lets agents run up to 50%; with 1 hour
# left, up to 90%. Same for the 7-day window.
#
# The figures come from lib/account-health.sh: live from the plan's usage endpoint (no tokens
# spent), with the account's own OAuth token; with no figures (401, 429, any error) one tiny
# `claude -p` refreshes the token and the call is retried once. A probe that fails says why: a
# dead account (payment past due, disabled, logged out) or a reached usage limit holds, and says
# so, whatever the cache or crew.budget.on_unknown says. Otherwise the statusline's cache
# (<config dir>/highness-usage.json, `crew.sh usage-save`) is used while fresh. No figure at all =
# hold: an agent that cannot see the budget does not spend it.
#
# Config (the person's own, `config.sh get --user`):
#   crew.budget.five_hour_reserve   the person's share of a fresh 5-hour window, % (default 50)
#   crew.budget.seven_day_reserve   the person's share of a fresh 7-day window, % (default 50)
#   crew.budget.cache_max_age_min   how old the statusline cache may be (default 30)
#   crew.budget.on_unknown          "hold" (default) or "go" when no figure can be read
#   crew.budget.five_hour_per_start points of the 5-hour window one worker takes, for `starts`
#                                   (default 20: five workers started by hand at once spent a
#                                   whole window, highness#37's retro)
#   crew.budget.seven_day_per_start points of the 7-day window one worker takes (default 2: the
#                                   memory pass took about ten times more of the 5-hour window
#                                   than of the 7-day one, #37). Both are estimates; tune them.
#
# Fixtures: HI_NOW (epoch seconds), HI_BUDGET_RESPONSE (a file holding the endpoint's JSON, or
# the word "fail"), HI_BUDGET_REFRESH=0 (no refresh probe); account-health.sh lists the rest.
# bash 3.2, BSD tools.
set -u
export LC_ALL=C  # awk prints and reads "73.5", never a locale's "73,5"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
. "$HERE/account-health.sh"

die() { printf 'budget: %s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die 'jq is required'

now() { printf '%s' "${HI_NOW:-$(date +%s)}"; }
num() { case "$1" in ''|*[!0-9.]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
cfg() { bash "$CONFIG" get --user ".crew.budget.$1" 2>/dev/null; }

# The statusline cache: {five_hour: {used_percentage, resets_at (epoch)}, ..., updated_at}.
parse_cache() { # <config dir>
  local age
  age=$(num "$(cfg cache_max_age_min)" 30)
  jq -r --argjson now "$(now)" --argjson age "$(awk -v a="$age" 'BEGIN { print int(a * 60) }')" '
    select(type == "object" and (.updated_at | type) == "number" and ($now - .updated_at) <= $age)
    | ["five_hour", "seven_day"][] as $w | .[$w] as $v
    | select(($v | type) == "object" and ($v.used_percentage | type) == "number" and ($v.resets_at | type) == "number")
    | "\($w)\t\($v.used_percentage)\t\($v.resets_at | floor)"' "$1/highness-usage.json" 2>/dev/null
}

# Sets ROWS (the windows) and SRC (live or cache); exit 1 when no figure can be read. A probe's
# verdict (dead, or limited with no figures) wins over the cache: it is newer than any cache.
ROWS=''; SRC=''
windows() { # <config dir>
  account_health "$1"
  if [ -n "$AH_ROWS" ]; then ROWS=$AH_ROWS; SRC=live; return 0; fi
  case "$AH_STATE" in dead|limited) ROWS=''; SRC=''; return 1 ;; esac
  ROWS=$(parse_cache "$1")
  if [ -n "$ROWS" ]; then SRC=cache; return 0; fi
  SRC=''; return 1
}

# window used reset → window used line reset, the line being the most agents may reach.
lines() {
  local r5 r7
  r5=$(num "$(cfg five_hour_reserve)" 50); r7=$(num "$(cfg seven_day_reserve)" 50)
  awk -F'\t' -v now="$(now)" -v r5="$r5" -v r7="$r7" 'BEGIN { OFS = "\t" }
    NF >= 3 {
      len = ($1 == "five_hour") ? 18000 : 604800; res = ($1 == "five_hour") ? r5 : r7
      # A window already reset, or none running yet, starts from zero, under the line of a fresh window.
      reset = ($3 != "-" && $3 <= now)
      left = ($3 == "-" || reset) ? len : $3 - now
      if (left > len) left = len
      line = 100 - res * left / len
      used = reset ? 0 : $2
      print $1, used, line, $3
    }'
}

span() { ah_span "$@"; }

dir_of() { printf '%s' "${1:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"; }

cmd_show() {
  local d; d=$(dir_of "${1:-}")
  windows "$d" || return 1
  printf '%s\n' "$ROWS" | lines
}

cmd_check() {
  local d out n hold=0 w u l r part
  d=$(dir_of "${1:-}")
  if ! windows "$d"; then
    case "$AH_STATE" in
      dead) printf 'account dead on %s (%s); hold\n' "$d" "$AH_DETAIL"; return 1 ;;
      limited) printf 'account limited on %s (%s); hold\n' "$d" "$AH_DETAIL"; return 1 ;;
    esac
    if [ "$(cfg on_unknown)" = go ]; then printf 'usage unknown on %s; go (crew.budget.on_unknown)\n' "$d"; return 0; fi
    printf 'usage unknown on %s; hold\n' "$d"; return 1
  fi
  out=''; n=$(now)
  while IFS="$(printf '\t')" read -r w u l r; do
    [ -n "$w" ] || continue
    case "$w" in five_hour) part=5h ;; *) part=7d ;; esac
    part="$part $(awk -v u="$u" 'BEGIN { printf "%g", u }')% (agents up to $(awk -v l="$l" 'BEGIN { printf "%d", l }')%"
    [ "$r" = - ] || part="$part, resets in $(span $((r - n)))"
    part="$part)"
    if awk -v u="$u" -v l="$l" 'BEGIN { exit !(u + 0 >= l + 0) }'; then hold=1; part="$part over"; fi
    out="${out:+$out; }$part"
  done <<EOF
$(printf '%s\n' "$ROWS" | lines)
EOF
  if [ "$hold" = 1 ]; then printf '%s on %s [%s]; hold\n' "$out" "$d" "$SRC"; return 1; fi
  printf '%s on %s [%s]; go\n' "$out" "$d" "$SRC"
}

# starts <n> [<config dir>]: what a manual start shows first (highness#174). One line per window:
#   5h 34% used, agents up to 62% (resets in 3h10m): 28 points left, room for 1 start at ~20 each
# then one verdict line. Exit 0 when the n starts fit under the reserve, 1 when they would pass it
# or nothing can be read (a dead or limited account, unknown usage). It only warns: the caller
# starts anyway. on_unknown does not apply here: it is autostart's rule.
cmd_starts() {
  local n=${1:-} d k=-1 w u l r part left cost fit p5 p7 v
  case "$n" in ''|*[!0-9]*|0) die 'starts: <n> must be a whole number above 0' ;; esac
  d=$(dir_of "${2:-}")
  if ! windows "$d"; then
    case "$AH_STATE" in
      dead) printf 'account dead on %s (%s): a worker would stop at once. Starting anyway is your call.\n' "$d" "$AH_DETAIL" ;;
      limited) printf 'account limited on %s (%s): a worker would wait for the reset. Starting anyway is your call.\n' "$d" "$AH_DETAIL" ;;
      *) printf 'usage unknown on %s: cannot say what is left of the plan. Starting anyway is your call.\n' "$d" ;;
    esac
    return 1
  fi
  p5=$(num "$(cfg five_hour_per_start)" 20); p7=$(num "$(cfg seven_day_per_start)" 2)
  v=$(now)
  while IFS="$(printf '\t')" read -r w u l r; do
    [ -n "$w" ] || continue
    case "$w" in five_hour) part=5h; cost=$p5 ;; *) part=7d; cost=$p7 ;; esac
    left=$(awk -v u="$u" -v l="$l" 'BEGIN { x = l - u; if (x < 0) x = 0; printf "%d", x }')
    # A cost of 0 counts nothing against this window.
    fit=$(awk -v x="$left" -v c="$cost" 'BEGIN { if (c + 0 <= 0) print -1; else printf "%d", x / c }')
    part="$part $(awk -v u="$u" 'BEGIN { printf "%g", u }')% used, agents up to $(awk -v l="$l" 'BEGIN { printf "%d", l }')%"
    [ "$r" = - ] || [ "$r" -le "$v" ] || part="$part (resets in $(span $((r - v))))"
    part="$part: $left points left"
    if [ "$fit" -ge 0 ]; then
      if [ "$fit" = 1 ]; then part="$part, room for 1 start"; else part="$part, room for $fit starts"; fi
      part="$part at ~$cost each"
      if [ "$k" -lt 0 ] || [ "$fit" -lt "$k" ]; then k=$fit; fi
    fi
    printf '%s\n' "$part"
  done <<EOF
$(printf '%s\n' "$ROWS" | lines)
EOF
  if [ "$k" -ge 0 ] && [ "$n" -gt "$k" ]; then
    if [ "$k" = 0 ]; then
      printf '%s on %s [%s] would pass your reserve: the remainder fits none. Starting anyway is your call.\n' \
        "$(plural "$n")" "$d" "$SRC"
    else
      printf '%s on %s [%s] would pass your reserve: the remainder fits %s. Starting anyway is your call.\n' \
        "$(plural "$n")" "$d" "$SRC" "$k"
    fi
    return 1
  fi
  printf '%s on %s [%s] fit under your reserve.\n' "$(plural "$n")" "$d" "$SRC"
}
plural() { if [ "$1" = 1 ]; then echo '1 start'; else echo "$1 starts"; fi; }

# room: Orca's other Claude accounts that are under their line now, one per line:
# email<TAB>account id<TAB>config dir<TAB>the check's line. Each account without room gets one
# line on stderr with its check line, which names a dead or limited one as such. Exit 1 when
# none has room (or Orca cannot list them). The selected account is left out: it is the one being measured. Offering a
# switch is all this does; choosing which plan pays is the person's call (highness#106).
orca_cmd() {
  if [ -n "${ORCA_CLI_COMMAND:-}" ]; then printf '%s\n' "$ORCA_CLI_COMMAND"; return; fi
  if [ "$(uname -s)" = Linux ] && [ -z "${ORCA_TERMINAL_HANDLE:-}" ]; then echo orca-ide; return; fi
  echo orca
}
cmd_room() {
  local j rows id email home out found=1
  j=$("$(orca_cmd)" account list --json 2>/dev/null </dev/null | jq -c '.result.claude // empty' 2>/dev/null)
  [ -n "$j" ] || return 1
  rows=$(printf '%s' "$j" | jq -r '(.activeAccountIdsByRuntime.host // .activeAccountId // "system") as $a
    | .accounts[]? | select(.id != $a and (.home | type) == "string") | [.id, (.email // .id), .home] | @tsv')
  while IFS="$(printf '\t')" read -r id email home; do
    [ -n "$id" ] && [ -d "$home" ] || continue
    # An account without room (a dead one among them) is not offered; stderr says why.
    out=$(cmd_check "$home") || { printf 'budget: no room on %s (%s): %s\n' "$email" "$id" "$out" >&2; continue; }
    printf '%s\t%s\t%s\t%s\n' "$email" "$id" "$home" "$out"; found=0
  done <<EOF
$rows
EOF
  return "$found"
}

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  check) cmd_check "$@" ;;
  show) cmd_show "$@" ;;
  room) cmd_room ;;
  starts) cmd_starts "$@" ;;
  *) die 'usage: budget.sh check|show [<config dir>] | room | starts <n> [<config dir>]' ;;
esac
