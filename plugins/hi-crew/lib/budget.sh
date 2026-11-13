#!/usr/bin/env bash
# budget.sh — may a background agent spend this account's plan right now?
#
#   budget.sh check [<config dir>]   one line saying why; exit 0 = go, 1 = hold
#   budget.sh show  [<config dir>]   window<TAB>used%<TAB>line%<TAB>resets_at (epoch or -), one per window
#
# The person keeps a reserve of each plan window for their own sessions, and the reserve shrinks
# as the window nears its reset — the leftover of a window about to reset is lost anyway:
#
#   agents may run while  used% < 100 - reserve × (time left / window length)
#
# With the default reserve of 50, a fresh 5-hour window lets agents run up to 50%; with 1 hour
# left, up to 90%. Same for the 7-day window.
#
# The figures come live from the plan's usage endpoint (no tokens spent), with the account's own
# OAuth token; on a 401 one tiny `claude -p` refreshes the token and the call is retried once.
# Failing that, the statusline's cache (<config dir>/highness-usage.json, `crew.sh usage-save`) is
# used while fresh. No figure at all = hold: an agent that cannot see the budget does not spend it.
#
# Config (the person's own, `config.sh get --user`):
#   crew.budget.five_hour_reserve   the person's share of a fresh 5-hour window, % (default 50)
#   crew.budget.seven_day_reserve   the person's share of a fresh 7-day window, % (default 50)
#   crew.budget.cache_max_age_min   how old the statusline cache may be (default 30)
#   crew.budget.on_unknown          "hold" (default) or "go" when no figure can be read
#
# Fixtures: HI_NOW (epoch seconds), HI_BUDGET_RESPONSE (a file holding the endpoint's JSON, or
# the word "fail"), HI_BUDGET_REFRESH=0 (no refresh probe). bash 3.2, BSD tools.
set -u
export LC_ALL=C  # awk prints and reads "73.5", never a locale's "73,5"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
URL="${HI_BUDGET_URL:-https://api.anthropic.com/api/oauth/usage}"

die() { printf 'budget: %s\n' "$*" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die 'jq is required'

now() { printf '%s' "${HI_NOW:-$(date +%s)}"; }
num() { case "$1" in ''|*[!0-9.]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
cfg() { bash "$CONFIG" get --user ".crew.budget.$1" 2>/dev/null; }

# The account's OAuth access token, or nothing. macOS keeps it in the login Keychain.
token() { # <config dir>
  local f="$1/.credentials.json" j=''
  if [ -f "$f" ]; then
    j=$(cat "$f" 2>/dev/null)
  elif [ "$(uname -s)" = Darwin ] && command -v security >/dev/null 2>&1; then
    j=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null) || j=''
  fi
  printf '%s' "$j" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

# The endpoint's JSON on stdout; exit 0, or 1 on any failure, 3 on a 401.
call() { # <config dir>
  local t out code
  if [ -n "${HI_BUDGET_RESPONSE:-}" ]; then
    [ "$HI_BUDGET_RESPONSE" != fail ] && cat "$HI_BUDGET_RESPONSE" 2>/dev/null; return $?
  fi
  command -v curl >/dev/null 2>&1 || return 1
  t=$(token "$1"); [ -n "$t" ] || return 1
  # The token goes in on stdin (curl -K -), never in argv where ps would show it.
  out=$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$t" \
    | curl -sS -m 15 -K - -w '\n%{http_code}' "$URL" 2>/dev/null) || return 1
  code=$(printf '%s\n' "$out" | tail -n 1)
  [ "$code" = 401 ] && return 3
  [ "$code" = 200 ] || return 1
  printf '%s\n' "$out" | sed '$d'
}

# One tiny headless turn: Claude Code refreshes an expired token as it starts.
refresh() { # <config dir>
  [ "${HI_BUDGET_REFRESH:-1}" != 0 ] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  (cd "${TMPDIR:-/tmp}" && CLAUDE_CONFIG_DIR="$1" claude -p --model haiku --max-turns 1 --no-session-persistence \
     --strict-mcp-config --setting-sources '' -- 'reply ok' >/dev/null 2>&1 </dev/null)
}

# window<TAB>used%<TAB>resets_at, for five_hour and seven_day, from the endpoint's JSON.
# resets_at is an ISO time in UTC (fractional seconds, +00:00); null means no window running (-).
# Any other shape fails the parse, which is a hold.
parse_live() {
  jq -r '
    def epoch: if . == null then "-"
      else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 | tostring) end;
    ["five_hour", "seven_day"][] as $w
    | .[$w] as $v
    | if ($v | type) != "object" or ($v.utilization | type) != "number" then error("no \($w)") else . end
    | "\($w)\t\($v.utilization)\t\($v.resets_at | epoch)"' 2>/dev/null
}

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

# Sets ROWS (the windows) and SRC (live or cache); exit 1 when no figure can be read.
ROWS=''; SRC=''
windows() { # <config dir>
  local j rc
  j=$(call "$1"); rc=$?
  if [ "$rc" = 3 ] && refresh "$1"; then j=$(call "$1"); rc=$?; fi
  if [ "$rc" = 0 ] && ROWS=$(printf '%s' "$j" | parse_live) && [ "$(printf '%s\n' "$ROWS" | awk 'NF' | wc -l | tr -d ' ')" = 2 ]; then
    SRC=live; return 0
  fi
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
      left = ($3 == "-") ? len : $3 - now
      if (left < 0) left = 0; if (left > len) left = len
      line = 100 - res * left / len
      # A window already reset, or none running yet, starts from zero.
      used = ($3 != "-" && $3 <= now) ? 0 : $2
      print $1, used, line, $3
    }'
}

span() { # seconds → "2h47m" / "4d9h"
  awk -v s="$1" 'BEGIN { s = int(s); if (s < 0) s = 0
    if (s >= 86400) printf "%dd%dh", s / 86400, (s % 86400) / 3600
    else if (s >= 3600) printf "%dh%02dm", s / 3600, (s % 3600) / 60
    else printf "%dm", s / 60 }'
}

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

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  check) cmd_check "$@" ;;
  show) cmd_show "$@" ;;
  *) die 'usage: budget.sh check|show [<config dir>]' ;;
esac
