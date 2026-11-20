#!/usr/bin/env bash
# account-health.sh — can this Claude account run right now? (highness#115)
#
# Edit shared/account-health.sh, then copy it into plugins/hi/lib and plugins/hi-crew/lib
# (tests/config_copies_test.sh checks the copies). hi's account.sh sources it before a select,
# hi-crew's budget.sh before it reads the budget.
#
#   account-health.sh <config dir>    one line: state<TAB>detail; exit 0 when ok, 1 otherwise
#   . account-health.sh               then: account_health <config dir> sets AH_STATE, AH_DETAIL,
#                                     AH_ROWS (window<TAB>used%<TAB>resets_at epoch or -)
#
# States: ok (the figures read, no window spent) · limited (a window at 100%, or the probe says
# the usage limit is reached) · dead (the probe says why: payment past due, account disabled,
# not logged in) · unknown (no figures and no verdict).
#
# Two steps. 1. The plan's usage endpoint (/api/oauth/usage, no tokens spent), with the account's
# own OAuth token. Figures mean the account is alive. 2. No figures (401, 429, any error): one tiny
# headless turn (`claude -p`, haiku) under that config dir, then step 1 once more. The turn
# refreshes an expired token as it starts. Measured 2026-11-20: the endpoint answered 429 for a
# healthy account until such a turn ran, and 429 on every call for one whose payment was past
# due, so 429 alone says nothing. A turn that fails says why on stdout; that line is classified.
# `claude auth status` is no help: it said loggedIn, subscriptionType pro, for the past-due one.
#
# Seams: HI_BUDGET_URL, HI_BUDGET_RESPONSE (a file holding the endpoint's JSON, or the word
# "fail"), HI_BUDGET_REFRESH=0 (no probe), HI_BUDGET_KEYCHAIN=1 (read the macOS Keychain
# anywhere), HI_HEALTH_PROBE_TIMEOUT (seconds, default 120), HI_NOW (epoch seconds).
# bash 3.2, BSD tools.

AH_STATE=''; AH_DETAIL=''; AH_ROWS=''; AH_CODE=''; AH_BODY=''; AH_PROBE_RC=''; AH_PROBE_LINE=''

ah_now() { printf '%s' "${HI_NOW:-$(date +%s)}"; }

ah_span() { # seconds → "2h47m" / "4d9h"
  awk -v s="$1" 'BEGIN { s = int(s); if (s < 0) s = 0
    if (s >= 86400) printf "%dd%dh", s / 86400, (s % 86400) / 3600
    else if (s >= 3600) printf "%dh%02dm", s / 3600, (s % 3600) / 60
    else printf "%dm", s / 60 }'
}

# The Keychain services that may hold <config dir>'s token, most likely first. Claude Code run
# with CLAUDE_CONFIG_DIR keeps it under "Claude Code-credentials-<first 8 hex of sha256(dir)>";
# without it (the default ~/.claude), under the bare name. An Orca profile home has only the
# suffixed entry: the bare name there is another account's token, or none.
ah_services() { # <config dir>
  local d=${1%/} h
  h=$(printf '%s' "$d" | shasum -a 256 2>/dev/null | cut -c1-8)
  [ "$d" = "$HOME/.claude" ] && printf '%s\n' 'Claude Code-credentials'
  [ -n "$h" ] && printf '%s\n' "Claude Code-credentials-$h"
  return 0
}

# The account's OAuth access token, or nothing. macOS keeps it in the login Keychain.
ah_token() { # <config dir>
  local f="$1/.credentials.json" s t
  if [ -f "$f" ]; then
    jq -r '.claudeAiOauth.accessToken // empty' "$f" 2>/dev/null
    return 0
  fi
  [ -n "${HI_BUDGET_KEYCHAIN:-}" ] || [ "$(uname -s)" = Darwin ] || return 0
  command -v security >/dev/null 2>&1 || return 0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    t=$(security find-generic-password -s "$s" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [ -n "$t" ] && { printf '%s' "$t"; return 0; }
  done <<EOF
$(ah_services "$1")
EOF
  return 0
}

# Sets AH_CODE (the HTTP status, or "fail"/"no token"/"no curl") and AH_BODY.
ah_fetch() { # <config dir>
  local t out
  AH_CODE=fail; AH_BODY=''
  if [ -n "${HI_BUDGET_RESPONSE:-}" ]; then
    [ "$HI_BUDGET_RESPONSE" != fail ] && AH_BODY=$(cat "$HI_BUDGET_RESPONSE" 2>/dev/null) && AH_CODE=200
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { AH_CODE='no curl'; return 0; }
  t=$(ah_token "$1"); [ -n "$t" ] || { AH_CODE='no token'; return 0; }
  # The token goes in on stdin (curl -K -), never in argv where ps would show it.
  out=$(printf 'header = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$t" \
    | curl -sS -m 15 -K - -w '\n%{http_code}' "${HI_BUDGET_URL:-https://api.anthropic.com/api/oauth/usage}" 2>/dev/null) \
    || return 0
  AH_CODE=$(printf '%s\n' "$out" | tail -n 1)
  AH_BODY=$(printf '%s\n' "$out" | sed '$d')
}

# window<TAB>used%<TAB>resets_at, for five_hour and seven_day, from the endpoint's JSON on stdin.
# resets_at is an ISO time in UTC (fractional seconds, +00:00); null means no window running (-).
# Any other shape fails the parse.
ah_parse() {
  jq -r '
    def epoch: if . == null then "-"
      else (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 | tostring) end;
    ["five_hour", "seven_day"][] as $w
    | .[$w] as $v
    | if ($v | type) != "object" or ($v.utilization | type) != "number" then error("no \($w)") else . end
    | "\($w)\t\($v.utilization)\t\($v.resets_at | epoch)"' 2>/dev/null
}

# Sets AH_ROWS from a 200 with both windows; exit 1 when there are no figures.
ah_figures() {
  local r
  AH_ROWS=''
  [ "$AH_CODE" = 200 ] || return 1
  r=$(printf '%s' "$AH_BODY" | ah_parse) || return 1
  [ "$(printf '%s\n' "$r" | awk 'NF' | wc -l | tr -d ' ')" = 2 ] || return 1
  AH_ROWS=$r
}

# One tiny headless turn. Sets AH_PROBE_RC and AH_PROBE_LINE (what it said, stdout first: stderr
# carries warnings even on success, such as "this sign-in ends between …"). Exit 1 = no probe ran.
ah_probe() { # <config dir>
  local o e p w
  AH_PROBE_RC=''; AH_PROBE_LINE=''
  [ "${HI_BUDGET_REFRESH:-1}" != 0 ] || return 1
  command -v claude >/dev/null 2>&1 || return 1
  o=$(mktemp "${TMPDIR:-/tmp}/ah-probe.XXXXXX") || return 1
  e=$(mktemp "${TMPDIR:-/tmp}/ah-probe.XXXXXX") || { rm -f "$o"; return 1; }
  (cd "${TMPDIR:-/tmp}" && CLAUDE_CONFIG_DIR="$1" exec claude -p --model haiku --max-turns 1 \
     --no-session-persistence --strict-mcp-config --setting-sources '' -- 'reply ok' >"$o" 2>"$e" </dev/null) &
  p=$!
  # No `timeout` on macOS: a watchdog, its output away from any caller's pipe.
  (sleep "${HI_HEALTH_PROBE_TIMEOUT:-120}"; kill "$p") >/dev/null 2>&1 &
  w=$!
  wait "$p"; AH_PROBE_RC=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  AH_PROBE_LINE=$(awk 'NF { print; exit }' "$o")
  [ -n "$AH_PROBE_LINE" ] || AH_PROBE_LINE=$(awk 'NF { print; exit }' "$e")
  AH_PROBE_LINE=$(printf '%s' "$AH_PROBE_LINE" | cut -c1-300)
  rm -f "$o" "$e"
  return 0
}

# A failing turn's line → "dead<TAB>reason", "limited" or "unknown". The past-due line is
# measured ("Claude Code can't use your Claude subscription, usually because a payment is past
# due · Pay or renew at …", exit 1). The others are Claude Code's wording as far as known and
# not measured here, so they match broadly.
ah_classify() { # <line>
  local l
  l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$l" in
    *'past due'*) printf 'dead\tpayment past due' ;;
    *disabled*|*suspended*|*deactivated*|*banned*) printf 'dead\taccount disabled' ;;
    *'not logged in'*|*'/login'*|*'invalid api key'*|*'token has been revoked'*) printf 'dead\tnot logged in' ;;
    *'usage limit'*|*'limit reached'*|*'hit your'*'limit'*|*'out of'*'usage'*) printf 'limited' ;;
    *) printf 'unknown' ;;
  esac
}

# From AH_ROWS: limited when a running window is at 100%, else ok. Sets AH_STATE and AH_DETAIL.
ah_judge() {
  local now w u r name spent='' seen=''
  now=$(ah_now)
  while IFS="$(printf '\t')" read -r w u r; do
    [ -n "$w" ] || continue
    case "$w" in five_hour) name=5h ;; *) name=7d ;; esac
    # A window whose reset has passed starts from zero.
    [ "$r" != - ] && [ "$r" -le "$now" ] && u=0
    seen="${seen:+$seen, }$name $(awk -v u="$u" 'BEGIN { printf "%g", u }')%"
    if awk -v u="$u" 'BEGIN { exit !(u + 0 >= 100) }'; then
      spent="${spent:+$spent; }$name window spent$([ "$r" = - ] || printf ', resets in %s' "$(ah_span $((r - now)))")"
    fi
  done <<EOF
$AH_ROWS
EOF
  if [ -n "$spent" ]; then AH_STATE=limited; AH_DETAIL=$spent; else AH_STATE=ok; AH_DETAIL=$seen; fi
}

account_health() { # <config dir>
  local d=$1 first v
  AH_STATE=unknown; AH_DETAIL=''; AH_ROWS=''
  ah_fetch "$d"
  if ah_figures; then ah_judge; return 0; fi
  first=$AH_CODE
  if ! ah_probe "$d"; then
    AH_DETAIL="usage endpoint: $first; no probe ran"
    return 0
  fi
  if [ "$AH_PROBE_RC" = 0 ]; then
    ah_fetch "$d"
    if ah_figures; then ah_judge; return 0; fi
    AH_DETAIL="the probe ran, but the usage endpoint still answers $AH_CODE (first $first): no figures"
    return 0
  fi
  v=$(ah_classify "$AH_PROBE_LINE")
  case "$v" in
    dead*) AH_STATE=dead; AH_DETAIL="$(printf '%s' "$v" | cut -f2): $AH_PROBE_LINE" ;;
    limited) AH_STATE=limited; AH_DETAIL="usage limit reached: $AH_PROBE_LINE" ;;
    *) AH_DETAIL="usage endpoint: $first; the probe failed (exit $AH_PROBE_RC): ${AH_PROBE_LINE:-no output}" ;;
  esac
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  export LC_ALL=C
  command -v jq >/dev/null 2>&1 || { printf 'account-health: jq is required\n' >&2; exit 2; }
  [ $# = 1 ] && [ -n "$1" ] || { printf 'usage: account-health.sh <config dir>\n' >&2; exit 2; }
  account_health "$1"
  printf '%s\t%s\n' "$AH_STATE" "$AH_DETAIL"
  [ "$AH_STATE" = ok ]
fi
