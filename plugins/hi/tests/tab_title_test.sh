#!/usr/bin/env bash
# lib/tab-title.sh — naming this session's Orca tab, and the SessionStart rule that asks for it.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
PLUGIN=$(cd "$HERE/.." && pwd -P)
T="$PLUGIN/lib/tab-title.sh"

# A stub Orca: logs each call's arguments, one per line, then a blank line; `terminal show`
# answers with $STUB_ORPHANED; a call named in $STUB_FAIL exits 1.
STUB="$SANDBOX/orca"; LOG="$SANDBOX/orca.log"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf '%s\n' "$a"; done >>"$ORCA_LOG"; echo >>"$ORCA_LOG"
case "$1 $2" in
  "${STUB_FAIL:-none}") echo '{"ok":false,"error":"nope"}'; exit 1 ;;
  "terminal show") printf '{"ok":true,"result":{"terminal":{"orphaned":%s}}}\n' "${STUB_ORPHANED:-false}" ;;
  *) echo '{"ok":true}' ;;
esac
EOF
chmod +x "$STUB"
run() { : >"$LOG"; env -u ORCA_TERMINAL_HANDLE -u ORCA_WORKTREE_ID HI_ORCA="$STUB" ORCA_LOG="$LOG" "$@"; }

# --- a terminal tab: always the session's own handle, never Orca's default target ---------------
out=$(run ORCA_TERMINAL_HANDLE=term_me bash "$T" set "PAY-12: refund flow" 2>&1); rc=$?
assert_status "terminal: exit 0" 0 "$rc"
assert_eq "terminal: reports the title" "tab-title: PAY-12: refund flow" "$out"
assert_eq "terminal: rename names the handle explicitly" \
  "$(printf 'terminal\nrename\n--terminal\nterm_me\n--title\nPAY-12: refund flow\n--json')" \
  "$(sed -n '1,/^$/p' "$LOG" | sed '/^$/d')"

# --- an orphaned tab (opened from another Orca window): stored, with a warning ------------------
err=$(run ORCA_TERMINAL_HANDLE=term_me STUB_ORPHANED=true bash "$T" set "x" 2>&1 >/dev/null); rc=$?
assert_status "orphaned: still exit 0" 0 "$rc"
assert_contains "orphaned: says the other window may keep the old name" "$err" "orphaned on this host"
err=$(run ORCA_TERMINAL_HANDLE=term_me bash "$T" set "x" 2>&1 >/dev/null)
assert_eq "not orphaned: no warning" "" "$err"

# --- a chat tab: no terminal handle, so `chat rename` on the chat it runs in --------------------
out=$(run ORCA_WORKTREE_ID=wt bash "$T" set "Доступ отчиму" 2>&1); rc=$?
assert_status "chat: exit 0" 0 "$rc"
assert_eq "chat: chat rename, no session id" "$(printf 'chat\nrename\n--name\nДоступ отчиму\n--json')" \
  "$(sed '/^$/d' "$LOG")"

# --- cleaned and capped -----------------------------------------------------------------------
long=$(printf 'я%.0s' $(seq 1 80))
run ORCA_TERMINAL_HANDLE=term_me bash "$T" set "  two
lines  " >/dev/null 2>&1
assert_eq "set: newlines folded, ends trimmed" "two lines" "$(sed -n 6p "$LOG")"
run ORCA_TERMINAL_HANDLE=term_me bash "$T" set "$long" >/dev/null 2>&1
capped=$(sed -n 6p "$LOG")
assert_eq "set: capped at 60 characters, Cyrillic intact" "$(printf 'я%.0s' $(seq 1 59))…" "$capped"

# --- never fails the session ------------------------------------------------------------------
err=$(run bash "$T" set "x" 2>&1 >/dev/null); rc=$?
assert_status "outside Orca: exit 0" 0 "$rc"
assert_contains "outside Orca: says nothing was renamed" "$err" "not an Orca session"
assert_eq "outside Orca: Orca not called" "" "$(cat "$LOG")"
err=$(run ORCA_TERMINAL_HANDLE=term_me STUB_FAIL="terminal rename" bash "$T" set "x" 2>&1 >/dev/null); rc=$?
assert_status "Orca refuses: exit 0" 0 "$rc"
assert_contains "Orca refuses: says so" "$err" "Orca refused the rename"
run ORCA_TERMINAL_HANDLE=term_me bash "$T" set "" >/dev/null 2>&1; assert_status "set: empty title is usage (2)" 2 "$?"
bash "$T" >/dev/null 2>&1; assert_status "no subcommand is usage (2)" 2 "$?"

# --- context: the rule reaches Orca sessions only, with a runnable path -------------------------
out=$(run bash "$T" context 2>&1)
assert_eq "context outside Orca: silent" "" "$out"
out=$(run ORCA_TERMINAL_HANDLE=term_me bash "$T" context 2>&1)
assert_contains "context: names the command with this plugin's path" "$out" "bash \"$PLUGIN/lib/tab-title.sh\" set"
assert_contains "context: never the skill's name" "$out" "Never the skill or command"
out=$(run ORCA_WORKTREE_ID=wt bash "$T" context 2>&1)
assert_contains "context in a chat tab: the rule too" "$out" "This session runs in an Orca tab"

# --- wiring: hooks.json and the launcher --------------------------------------------------------
H="$PLUGIN/hooks/hooks.json"
assert_eq "hooks.json: context on start, resume, clear, compact" "startup|resume|clear|compact" \
  "$(jq -r '.hooks.SessionStart[1].matcher' "$H")"
assert_eq "hooks.json: runs tab-title.sh context" 'bash "${CLAUDE_PLUGIN_ROOT}/lib/tab-title.sh" context' \
  "$(jq -r '.hooks.SessionStart[1].hooks[0].command' "$H")"
out=$(run ORCA_TERMINAL_HANDLE=term_me bash "$PLUGIN/bin/highness" tab-title "via launcher" 2>&1)
assert_eq "highness tab-title: runs set" "tab-title: via launcher" "$out"

sandbox_cleanup
assert_summary
