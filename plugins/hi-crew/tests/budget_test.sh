#!/usr/bin/env bash
# lib/budget.sh: the reserve that shrinks toward each window's reset, the live answer's shape, the
# statusline cache as the fallback, and unknown = hold. No network: HI_BUDGET_RESPONSE stands in.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$HERE/../lib/budget.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_CONFIG="$T/user.json" HI_BUDGET_REFRESH=0 HI_BUDGET_RESPONSE="$T/live.json" HI_NOW=2000000000
echo '{}' >"$HIGHNESS_CONFIG"
mkdir -p "$T/acct"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

# <5h %> <5h seconds left | null> <7d %> <7d seconds left | null>
live() {
  jq -n --argjson now "$HI_NOW" --argjson p5 "$1" --argjson l5 "$2" --argjson p7 "$3" --argjson l7 "$4" '
    def iso: if . == null then null else todate | sub("Z$"; ".214621+00:00") end;
    {five_hour: {utilization: $p5, resets_at: (if $l5 == null then null else $now + $l5 end | iso)},
     seven_day: {utilization: $p7, resets_at: (if $l7 == null then null else $now + $l7 end | iso)},
     extra_usage: {is_enabled: false}}' >"$T/live.json"
}
verdict() { bash "$B" check "$T/acct" >/dev/null 2>&1 && echo go || echo hold; }
line() { bash "$B" show "$T/acct" | awk -F'\t' -v w="$1" '$1 == w { printf "%d", $3 }'; }

# --- the line: 100 - reserve × left / length
live 10 18000 10 604800
check 'a fresh window: agents up to 100 - 50' "$(line five_hour)/$(line seven_day)" '50/50'
live 10 3600 10 86400
check 'an hour of 5 left: up to 90; a day of 7 left: up to 92' "$(line five_hour)/$(line seven_day)" '90/92'
live 40 18000 40 604800
check 'both under the line: go' "$(verdict)" go
live 60 18000 10 604800
check '5h over the line: hold' "$(verdict)" hold
live 10 18000 60 302400
check '7d under its line (75 at half the week): go' "$(verdict)" go
live 10 18000 80 302400
check '7d over its line at half the week: hold' "$(verdict)" hold
live 85 600 10 604800
check 'a high 5h figure ten minutes before its reset: go' "$(verdict)" go
live 50 18000 10 604800
check 'exactly on the line holds' "$(verdict)" hold

# --- the message
live 37 9660 34 371820
out=$(bash "$B" check "$T/acct")
check 'check says each window, its line and its reset' "$out" \
  "5h 37% (agents up to 73%, resets in 2h41m); 7d 34% (agents up to 69%, resets in 4d7h) on $T/acct [live]; go"
live 60 18000 10 604800
has 'a held window is marked' "$(bash "$B" check "$T/acct")" '5h 60% (agents up to 50%, resets in 5h00m) over'

# --- the reserve is configurable
echo '{"crew": {"budget": {"five_hour_reserve": 20, "seven_day_reserve": 0}}}' >"$HIGHNESS_CONFIG"
live 60 18000 99 604800
check 'reserve 20 and 0: 5h up to 80, 7d up to 100' "$(line five_hour)/$(line seven_day)" '80/100'
check 'with them, 60 and 99 go' "$(verdict)" go
echo '{}' >"$HIGHNESS_CONFIG"

# --- no window running, a window already reset
live 0 null 10 604800
check 'no 5h window running (utilization 0, no reset): go' "$(verdict)" go
check '…and its line is the fresh one' "$(line five_hour)" 50
live 95 -60 10 604800
check 'a window whose reset has passed starts from zero: go' "$(verdict)" go

# --- unknown holds
HI_BUDGET_RESPONSE=fail
check 'the endpoint failing, no cache: hold' "$(verdict)" hold
has '…and says unknown' "$(bash "$B" check "$T/acct")" 'usage unknown on'
echo '{"five_hour": {"utilization": "a lot"}}' >"$T/odd.json"; HI_BUDGET_RESPONSE="$T/odd.json"
check 'an answer of another shape: hold' "$(verdict)" hold
jq -n '{five_hour: {utilization: 10, resets_at: "2033-05-18T03:33:20+05:00"}, seven_day: {utilization: 10, resets_at: null}}' >"$T/odd.json"
check 'a reset not in UTC: hold' "$(verdict)" hold
echo '{"crew": {"budget": {"on_unknown": "go"}}}' >"$HIGHNESS_CONFIG"
HI_BUDGET_RESPONSE=fail
check 'on_unknown go: go' "$(verdict)" go
echo '{}' >"$HIGHNESS_CONFIG"

# --- the statusline cache when the endpoint fails
jq -n --argjson now "$HI_NOW" '{five_hour: {used_percentage: 30, resets_at: ($now + 9000)},
  seven_day: {used_percentage: 20, resets_at: ($now + 302400)}, updated_at: ($now - 60)}' >"$T/acct/highness-usage.json"
check 'a fresh cache decides' "$(verdict)" go
has '…and says so' "$(bash "$B" check "$T/acct")" '[cache]; go'
jq '.five_hour.used_percentage = 80' "$T/acct/highness-usage.json" >"$T/c" && mv "$T/c" "$T/acct/highness-usage.json"
check 'a fresh cache over the line: hold' "$(verdict)" hold
jq --argjson t $((HI_NOW - 3600)) '.updated_at = $t | .five_hour.used_percentage = 1' "$T/acct/highness-usage.json" >"$T/c" \
  && mv "$T/c" "$T/acct/highness-usage.json"
check 'a cache an hour old is unknown: hold' "$(verdict)" hold
live 10 18000 10 604800; HI_BUDGET_RESPONSE="$T/live.json"
check 'the live answer wins over the cache' "$(bash "$B" check "$T/acct" | sed 's/.*\[\(.*\)\].*/\1/')" live

# --- the token never goes on the command line
mkdir -p "$T/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/curl.args"; cat >>"%s/curl.stdin"; printf "{}\\n500"\n' "$T" "$T" >"$T/bin/curl"
chmod +x "$T/bin/curl"
echo '{"claudeAiOauth": {"accessToken": "sk-test-secret"}}' >"$T/acct/.credentials.json"
rm -f "$T/acct/highness-usage.json"
PATH="$T/bin:$PATH" HI_BUDGET_RESPONSE='' bash "$B" check "$T/acct" >/dev/null 2>&1
check 'curl was called' "$([ -f "$T/curl.args" ] && echo yes)" yes
check 'the token is not in its arguments' "$(grep -c 'sk-test-secret' "$T/curl.args")" 0
has 'the token goes in on stdin' "$(cat "$T/curl.stdin")" 'Authorization: Bearer sk-test-secret'

exit $fail
