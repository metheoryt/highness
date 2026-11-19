#!/usr/bin/env bash
# retro.sh: the bundle, filing findings (sink, gh fallback, dedupe, the cap), the retro comment.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
R="$HERE/../lib/retro.sh"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json" HI_RETRO_CONFIG_DIRS="$T/none"
unset ORCA_CLI_COMMAND CLAUDE_CONFIG_DIR
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

# A root (the coordinator's checkout) with a github origin, and a workspace.
ROOT="$T/root"; WS="$T/ws"
mkdir -p "$ROOT" "$WS"
git -C "$ROOT" init -q && git -C "$ROOT" remote add origin https://github.com/team/root.git
echo '{}' >"$HIGHNESS_CONFIG"

# A fake gh: issue list answers $T/open.json, create prints a url and logs, comment logs stdin.
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
log="$GH_LOG"
case "$1 $2" in
  "issue list") printf 'list %s\n' "$*" >>"$log"; cat "$GH_OPEN" ;;
  "issue create")
    printf 'create %s\n' "$*" >>"$log"
    case "$*" in *needs-decision*) [ -n "${GH_NO_LABEL:-}" ] && { echo 'could not add label' >&2; exit 1; } ;; esac
    n=$(($(grep -c '^create' "$log") + 100)); echo "https://github.com/x/y/issues/$n" ;;
  "issue comment") printf 'comment %s\n' "$*" >>"$log"; cat >>"$GH_COMMENT" ;;
  *) echo "fake gh: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GH_OPEN="$T/open.json" GH_COMMENT="$T/comment.txt"
echo '[]' >"$GH_OPEN"; : >"$GH_LOG"

bash "$C" record proj-7 "{\"title\":\"Seven\",\"repo\":\"team/proj\",\"workspace\":\"$WS\",\"root\":\"$ROOT\",\"pr\":\"https://github.com/team/proj/pull/9\"}"

# --- gather: every part degrades on its own
out=$(bash "$R" gather proj-7)
has 'bundle names the PR' "$out" 'https://github.com/team/proj/pull/9'
has 'no transcript is said, not fatal' "$out" $'## transcript\nnot found'
has 'no denial log is said' "$out" 'no denial log at'
has 'no choices is said' "$out" $'## choices\nnone'
if bash "$R" gather nope-1 2>/dev/null; then no 'gather refuses unknown ticket'; else ok 'gather refuses unknown ticket'; fi
has 'no spec is said' "$out" $'## spec\nnot recorded'
# The spec: the copy crew.sh spec keeps for the key, then the facts' `spec` path (highness#85).
mkdir -p "$HIGHNESS_STATE/crew/specs" && echo 'spec text' >"$HIGHNESS_STATE/crew/specs/proj-7.md"
has 'spec: the kept copy, unrecorded' "$(bash "$R" gather proj-7)" $'## spec\n'"$HIGHNESS_STATE/crew/specs/proj-7.md"
echo 'spec text' >"$T/spec.md"
bash "$C" record proj-7 "{\"spec\":\"$T/spec.md\"}"
has 'spec: the recorded path' "$(bash "$R" gather proj-7)" $'## spec\n'"$T/spec.md"

# A transcript with a failed tool call, an ask, an interrupt and a 40-minute gap; a denial log.
TR="$T/tr.jsonl"
cat >"$TR" <<'EOF'
{"type":"assistant","timestamp":"2026-01-01T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"rm -rf build"}}]}}
{"type":"user","timestamp":"2026-01-01T10:00:05.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"hook error: denied by rule"}]}}
{"type":"assistant","timestamp":"2026-01-01T10:01:00.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"orca orchestration ask --question x"}}]}}
{"type":"user","timestamp":"2026-01-01T10:41:00.000Z","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}
EOF
bash "$C" record proj-7 "{\"transcript\":\"$TR\"}"
# The lines in the shape hi-guard's lib/denials.sh writes them.
printf '%s\n' '{"time":"2026-01-01T10:00:04Z","session":"tr","cwd":"/ws","tool":"Bash","command":"rm -rf build","by":"hi-guard","rule":"deny_patterns","decision":"deny","reason":"r"}' \
  '{"time":"2026-01-01T10:00:09Z","session":"other","cwd":"/elsewhere","tool":"Bash","command":"x","by":"claude-code","rule":"auto-mode classifier","decision":"deny","reason":"[Unauthorized Access]","permission_mode":"auto","tool_use_id":"t"}' \
  >"$HIGHNESS_STATE/denials.jsonl"
bash "$C" choice proj-7 '{"question":"q","took":"own","reply":"r"}'
out=$(bash "$R" gather proj-7)
has 'signals: the failed tool call' "$out" $'error\t2026-01-01T10:00:05.000Z\tBash\trm -rf build\thook error: denied by rule'
has 'signals: the ask' "$out" $'ask\t\tBash\torca orchestration ask'
has 'signals: the interrupt' "$out" 'interrupt'
has 'signals: the stall' "$out" $'stall\t2026-01-01T10:01:00.000Z\t\t\t40 min'
has 'denials of the session kept' "$out" '"by":"hi-guard"'
case "$out" in *'"/elsewhere"'*) no 'denials of other sessions dropped' ;; *) ok 'denials of other sessions dropped' ;; esac
has 'choices handed over' "$out" '"took":"own"'

# --- close without findings: nothing filed, the comment says so
echo '[]' >"$T/none.json"
check 'no findings files nothing' "$(bash "$R" file proj-7 "$T/none.json")" ''
: >"$GH_COMMENT"
bash "$R" comment proj-7 || no 'comment posts'
check 'comment goes to the ticket issue' "$(grep '^comment' "$GH_LOG" | tail -1)" 'comment issue comment 7 -R team/proj --body-file -'
check 'comment starts with the retro mark' "$(head -1 "$GH_COMMENT")" '<!-- hi:retro -->'
check 'then the marker and "no findings"' "$(sed -n 2p "$GH_COMMENT")" '(agent) Retro of proj-7: no findings.'
check 'retro_at recorded' "$(bash "$C" get proj-7 | jq -r '.retro_at | test("^[0-9]{4}-")')" 'true'
check 'close is quiet after a retro' "$(bash "$C" close proj-7 2>&1)" ''

# --- close with findings, default sink (gh): routing, dedupe, the label
bash "$C" record proj-8 "{\"title\":\"Eight\",\"repo\":\"team/proj\",\"workspace\":\"$WS\",\"root\":\"$ROOT\"}"
echo '[{"title":"Worker spec: name the test command","url":"https://github.com/x/y/issues/5"}]' >"$GH_OPEN"
cat >"$T/f.json" <<EOF
[{"kind":"tool","title":"wt.sh: create fails on a dirty tree","body":"Step: create. Error at $HOME/x.","repo":"team/tool"},
 {"kind":"brief","title":"worker spec — name the test command!","body":"The worker ran no tests."},
 {"kind":"decision","title":"Who merges docs-only PRs?","body":"Asked twice."}]
EOF
: >"$GH_LOG"
out=$(HI_RETRO_SPEC_REPO=team/spec bash "$R" file proj-8 "$T/f.json"); rc=$?
check 'filing exits 0' "$rc" 0
check 'tool fault filed in its repo' "$(grep '^create' "$GH_LOG" | sed -n 1p | grep -o -- '-R [^ ]*')" '-R team/tool'
check 'brief gap deduped by title' "$(printf '%s\n' "$out" | sed -n 2p)" $'brief\tworker spec — name the test command!\tdup https://github.com/x/y/issues/5'
check 'decision filed in the root repo' "$(grep '^create' "$GH_LOG" | sed -n 2p | grep -o -- '-R [^ ]*')" '-R team/root'
has 'decision carries needs-decision' "$(grep '^create' "$GH_LOG" | sed -n 2p)" '--label needs-decision'
check 'two created, one dup' "$(grep -c '^create' "$GH_LOG")" 2
: >"$GH_COMMENT"
bash "$R" comment proj-8
has 'comment lists what was filed' "$(cat "$GH_COMMENT")" '- brief: worker spec — name the test command! — dup https://github.com/x/y/issues/5'

# A missing needs-decision label does not lose the finding.
echo '[]' >"$GH_OPEN"; : >"$GH_LOG"
echo '[{"kind":"decision","title":"Q","body":"b"}]' >"$T/d.json"
out=$(GH_NO_LABEL=1 bash "$R" file proj-8 "$T/d.json")
has 'filed without the label' "$out" 'https://github.com/x/y/issues/'
check 'retried without --label' "$(grep -c '^create' "$GH_LOG")" 2

# The coordinator's own dup is not filed again.
: >"$GH_LOG"
echo '[{"kind":"tool","title":"T","body":"b","dup":"team/tool#4"}]' >"$T/dd.json"
check 'given dup kept' "$(bash "$R" file proj-8 "$T/dd.json")" $'tool\tT\tdup team/tool#4'
check 'given dup files nothing' "$(grep -c . "$GH_LOG")" 0

# The cap and the shape.
echo '[{"kind":"tool","title":"a","body":"b"},{"kind":"tool","title":"a","body":"b"},{"kind":"tool","title":"a","body":"b"},{"kind":"tool","title":"a","body":"b"}]' >"$T/four.json"
if bash "$R" file proj-8 "$T/four.json" 2>/dev/null; then no 'more than 3 refused'; else ok 'more than 3 refused'; fi
echo '[{"kind":"mood","title":"a","body":"b"}]' >"$T/bad.json"
if bash "$R" file proj-8 "$T/bad.json" 2>/dev/null; then no 'unknown kind refused'; else ok 'unknown kind refused'; fi

# --- the configured sink: placeholders shell-quoted, its last line is the result, dup passes through
cat >"$T/sink" <<'EOF'
#!/bin/sh
printf '%s|%s|%s|%s\n' "$1" "$2" "$4" "$5" >>"$SINK_LOG"
cat "$3" >>"$SINK_LOG"
case "$2" in *again*) echo "dup TEAM-1" ;; *) echo "noise"; echo "TEAM-2" ;; esac
EOF
chmod +x "$T/sink"
mkdir -p "$ROOT/.claude"
printf '%s\n' "{\"crew\":{\"retro_sink\":\"$T/sink {{KIND}} {{TITLE}} {{BODY_FILE}} {{TICKET}} {{ROOT}}\"}}" >"$ROOT/.claude/highness.json"
git -C "$ROOT" add .claude/highness.json >/dev/null 2>&1
export SINK_LOG="$T/sink.log"; : >"$SINK_LOG"; : >"$GH_LOG"
cat >"$T/s.json" <<EOF
[{"kind":"tool","title":"it's quoted; \$(echo no)","body":"under $HOME/deep"},{"kind":"brief","title":"seen again","body":"b"}]
EOF
out=$(bash "$R" file proj-8 "$T/s.json")
check 'sink result per finding' "$out" $'tool\tit\'s quoted; $(echo no)\tTEAM-2\nbrief\tseen again\tdup TEAM-1'
check 'sink got the values verbatim' "$(sed -n 1p "$SINK_LOG")" "tool|it's quoted; \$(echo no)|proj-8|$ROOT"
check 'home path scrubbed from the body' "$(sed -n 2p "$SINK_LOG")" 'under ~/deep'
check 'gh not used when a sink is set' "$(grep -c . "$GH_LOG")" 0
printf '%s\n' '{"crew":{"retro_sink":"false"}}' >"$ROOT/.claude/highness.json"
if bash "$R" file proj-8 "$T/d.json" >/dev/null; then no 'failing sink exits 1'; else ok 'failing sink exits 1'; fi

# --- close without a retro warns
bash "$C" record proj-9 '{"title":"Nine"}'
has 'close without a retro warns' "$(bash "$C" close proj-9 2>&1)" 'closed without a retro'

exit "$fail"
