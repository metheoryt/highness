#!/usr/bin/env bash
# shared/account-health.sh: the usage endpoint first; with no figures (401, 429, any error) one
# tiny `claude -p` probe, then the endpoint once more; a failing probe's line classified. Stub
# curl and claude on PATH play the endpoint and Claude Code (highness#115).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
H="$ROOT/shared/account-health.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

export HI_NOW=2000000000 TMPDIR="$T" PATH="$T/bin:$PATH" STUB="$T"
unset HI_BUDGET_RESPONSE HI_BUDGET_REFRESH HI_BUDGET_KEYCHAIN
mkdir -p "$T/bin" "$T/acct"
echo '{"claudeAiOauth": {"accessToken": "sk-test"}}' >"$T/acct/.credentials.json"

# The endpoint: $STUB/code until a probe has run ($STUB/refreshed), then 200 with $STUB/figures.
cat >"$T/bin/curl" <<'S'
#!/bin/sh
cat >/dev/null
echo x >>"$STUB/curl.calls"
if [ -f "$STUB/refreshed" ] || [ "$(cat "$STUB/code")" = 200 ]; then cat "$STUB/figures"; printf '\n200'
else printf '{"error":{"type":"rate_limit_error","message":"Rate limited"}}\n%s' "$(cat "$STUB/code")"; fi
S
# Claude Code: $STUB/mode is ok (refreshes the token), pastdue, limit or broken. stderr always
# carries the sign-in warning, which the classification must not read.
cat >"$T/bin/claude" <<'S'
#!/bin/sh
echo x >>"$STUB/claude.calls"
echo 'Warning: this sign-in ends between 2033-05-20 and 2033-05-23 (in 5 days at the earliest). Run claude auth login before then.' >&2
case "$(cat "$STUB/mode")" in
  ok) touch "$STUB/refreshed"; echo ok ;;
  pastdue) echo "Claude Code can't use your Claude subscription, usually because a payment is past due · Pay or renew at https://claude.ai/settings/billing (if you just paid, try again shortly), or use an Anthropic API key instead"; exit 1 ;;
  limit) echo "You've hit your usage limit · resets 3pm"; exit 1 ;;
  *) echo 'API Error: socket hang up'; exit 1 ;;
esac
S
chmod +x "$T/bin/curl" "$T/bin/claude"

figures() { # <5h %> <7d %>
  jq -n --argjson now "$HI_NOW" --argjson a "$1" --argjson b "$2" '
    {five_hour: {utilization: $a, resets_at: ($now + 3600 | todate | sub("Z$"; ".5+00:00"))},
     seven_day: {utilization: $b, resets_at: null}}' >"$T/figures"
}
# run <first code> <probe mode>: state<TAB>detail; the counts of calls in $T/calls.
run() {
  rm -f "$T/refreshed" "$T/curl.calls" "$T/claude.calls"
  echo "$1" >"$T/code"; echo "$2" >"$T/mode"
  OUT=$(bash "$H" "$T/acct"); RC=$?
  CALLS="curl $(cat "$T/curl.calls" 2>/dev/null | wc -l | tr -d ' '), claude $(cat "$T/claude.calls" 2>/dev/null | wc -l | tr -d ' ')"
}

echo '== figures'
figures 37 34; run 200 ok
check 'figures: ok' "$(printf '%s' "$OUT" | cut -f1)" ok
check '…with the figures' "$(printf '%s' "$OUT" | cut -f2)" '5h 37%, 7d 34%'
check '…no probe spent' "$CALLS" 'curl 1, claude 0'
check '…exit 0' "$RC" 0
figures 100 34; run 200 ok
check 'a window at 100%: limited' "$(printf '%s' "$OUT" | cut -f1)" limited
check '…with its reset' "$(printf '%s' "$OUT" | cut -f2)" '5h window spent, resets in 1h00m'
check '…exit 1' "$RC" 1

echo '== no figures: probe, then the endpoint once more'
figures 12 5; run 401 ok
check '401, then ok after the refresh' "$OUT" "ok	5h 12%, 7d 5%"
check '…one probe, two reads' "$CALLS" 'curl 2, claude 1'
run 429 ok
check '429, then ok after the refresh' "$OUT" "ok	5h 12%, 7d 5%"
check '…one probe, two reads' "$CALLS" 'curl 2, claude 1'
run 500 ok
check 'any other error probes too' "$(printf '%s' "$OUT" | cut -f1)" ok

echo '== a failing probe'
run 429 pastdue
check '429 persisting, the probe says payment past due: dead' "$(printf '%s' "$OUT" | cut -f1)" dead
has '…with the reason' "$OUT" 'payment past due: Claude Code can'"'"'t use your Claude subscription'
check '…the sign-in warning on stderr is not the reason' "$(printf '%s' "$OUT" | grep -c 'sign-in ends')" 0
check '…one read only: no retry after a failing probe' "$CALLS" 'curl 1, claude 1'
check '…exit 1' "$RC" 1
run 429 limit
check 'the probe says usage limit: limited' "$(printf '%s' "$OUT" | cut -f1)" limited
has '…with its line' "$OUT" 'usage limit reached: You'"'"'ve hit your usage limit'
run 429 broken
check 'another failure: unknown' "$(printf '%s' "$OUT" | cut -f1)" unknown
has '…naming the endpoint and the probe' "$OUT" 'usage endpoint: 429; the probe failed (exit 1): API Error: socket hang up'

echo '== no probe allowed, or a probe that does not help'
HI_BUDGET_REFRESH=0 bash "$H" "$T/acct" >"$T/o"; check 'HI_BUDGET_REFRESH=0 and no figures: unknown' "$(cut -f1 "$T/o")" unknown
rm -f "$T/refreshed" "$T/claude.calls"; echo 429 >"$T/code"; echo ok >"$T/mode"
printf '#!/bin/sh\ncat >/dev/null\nprintf "{}\\n429"\n' >"$T/bin/curl"
out=$(bash "$H" "$T/acct")
check 'the probe runs, the endpoint still 429: unknown' "$(printf '%s' "$out" | cut -f1)" unknown
has '…and says so' "$out" 'the probe ran, but the usage endpoint still answers 429'

echo '== the classification'
. "$H"
check 'disabled' "$(ah_classify 'Your account has been disabled.')" "dead	account disabled"
check 'not logged in' "$(ah_classify 'Invalid API key · Please run /login')" "dead	not logged in"
check 'usage limit, other wording' "$(ah_classify 'Claude AI usage limit reached|2000003600')" limited
check 'a busy endpoint is not a verdict' "$(ah_classify 'API Error: 429 rate limited')" unknown

exit $fail
