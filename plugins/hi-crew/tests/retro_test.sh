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
has 'no transcript is said, not fatal' "$out" $'## transcripts\nnot found'
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
check 'decision filed in the ticket repo' "$(grep '^create' "$GH_LOG" | sed -n 2p | grep -o -- '-R [^ ]*')" '-R team/proj'
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
# The refusal names the finding and the accepted kinds (highness#130).
has 'bad kind: the accepted values named' "$(bash "$R" file proj-8 "$T/bad.json" 2>&1)" 'finding 1: kind "mood": give one of tool'
echo '[{"kind":"tool","title":"a","body":"b"},{"title":"a","body":"b"}]' >"$T/nokind.json"
has 'missing kind: which finding, and the values' "$(bash "$R" file proj-8 "$T/nokind.json" 2>&1)" 'finding 2: kind missing: give one of tool (a tool fault), brief (a worker-spec gap), decision (for a person)'
echo '[{"kind":"tool","title":"a"}]' >"$T/nobody.json"
has 'missing body named' "$(bash "$R" file proj-8 "$T/nobody.json" 2>&1)" 'finding 1: body missing'

# --- the ticket's repo (highness#130): a finding with no repo goes there before the root, and an
# Orca selector in the facts (autostart records path:<clone>) resolves to the clone's owner/repo.
CLONE="$T/clone"; mkdir -p "$CLONE"
git -C "$CLONE" init -q && git -C "$CLONE" remote add origin git@github.com:team/clone.git
bash "$C" record proj-11 "{\"title\":\"Eleven\",\"repo\":\"path:$CLONE\",\"workspace\":\"$WS\",\"root\":\"$ROOT\"}"
bash "$C" record proj-12 "{\"title\":\"Twelve\",\"workspace\":\"$WS\",\"root\":\"$ROOT\"}"
bash "$C" record proj-13 "{\"title\":\"Thirteen\",\"repo\":\"name:clone\",\"workspace\":\"$WS\",\"root\":\"$ROOT\"}"
echo '[{"kind":"tool","title":"repo-less","body":"b"}]' >"$T/rl.json"
echo '[]' >"$GH_OPEN"; : >"$GH_LOG"
bash "$R" file proj-11 "$T/rl.json" >/dev/null
check 'path: facts repo resolves to the clone' "$(grep '^create' "$GH_LOG" | tail -1 | grep -o -- '-R [^ ]*')" '-R team/clone'
bash "$R" file proj-12 "$T/rl.json" >/dev/null
check 'no facts repo: the root' "$(grep '^create' "$GH_LOG" | tail -1 | grep -o -- '-R [^ ]*')" '-R team/root'
echo "[{\"kind\":\"tool\",\"title\":\"sel\",\"body\":\"b\",\"repo\":\"path:$CLONE\"}]" >"$T/sel.json"
bash "$R" file proj-12 "$T/sel.json" >/dev/null
check "a finding's own path: repo resolves too" "$(grep '^create' "$GH_LOG" | tail -1 | grep -o -- '-R [^ ]*')" '-R team/clone'
echo '[{"kind":"tool","title":"bogus","body":"b","repo":"not a repo"}]' >"$T/bogus.json"
: >"$GH_LOG"
out=$(bash "$R" file proj-12 "$T/bogus.json"); rc=$?
check 'a finding repo naming nothing fails' "$rc" 1
has '... and says which' "$out" "failed: the finding's repo 'not a repo' names no GitHub owner/repo"
check '... and files nothing elsewhere' "$(grep -c '^create' "$GH_LOG")" 0
# id: and name: are asked of Orca.
cat >"$T/bin/orca-fake" <<EOF
#!/bin/sh
case "\$*" in *"--repo name:clone"*) printf '%s\n' '{"result":{"repo":{"path":"$CLONE","gitRemoteIdentity":{"canonicalKey":"github.com/team/viaorca"}}}}' ;; *) exit 1 ;; esac
EOF
chmod +x "$T/bin/orca-fake"
ORCA_CLI_COMMAND="$T/bin/orca-fake" bash "$R" file proj-13 "$T/rl.json" >/dev/null
check 'name: selector asked of Orca' "$(grep '^create' "$GH_LOG" | tail -1 | grep -o -- '-R [^ ]*')" '-R team/viaorca'
# The retro comment goes to the resolved repo, not `gh -R path:/…`.
: >"$GH_COMMENT"
bash "$R" comment proj-11 || no 'comment with a path: repo posts'
check 'comment: path: repo resolved' "$(grep '^comment' "$GH_LOG" | tail -1)" 'comment issue comment 11 -R team/clone --body-file -'
bash "$C" record proj-14 "{\"title\":\"Fourteen\",\"repo\":\"path:$T/nowhere\",\"workspace\":\"$WS\",\"root\":\"$T/noroot\"}"
has 'comment: an unresolvable repo is named' "$(cd "$T" && bash "$R" comment proj-14 2>&1)" "repo 'path:$T/nowhere' names no GitHub owner/repo"

# --- every transcript of a restarted worker (highness#130): found in each config dir, one per
# session, oldest first by first entry (the first one was touched last), a usage-limit stop is a
# signal, the gap until the restart a stall, and the denials of every session kept.
WS2="$T/ws2"; mkdir -p "$WS2"
SLUG=$(printf '%s' "$WS2" | sed 's|[/.]|-|g')
mkdir -p "$T/cfgA/projects/$SLUG" "$T/cfgB/projects/$SLUG"
cat >"$T/cfgA/projects/$SLUG/s-first.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-02-01T09:00:00.000Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-02-01T09:30:00.000Z","apiError":"usage_limit_reached","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You've hit your 5-hour limit · resets 3pm"}]}}
EOF
cat >"$T/cfgB/projects/$SLUG/s-restart.jsonl" <<'EOF'
{"type":"user","timestamp":"2026-02-01T15:05:00.000Z","message":{"content":"resume"}}
{"type":"assistant","timestamp":"2026-02-01T15:06:00.000Z","message":{"content":[{"type":"tool_use","id":"r1","name":"Bash","input":{"command":"make test"}}]}}
{"type":"user","timestamp":"2026-02-01T15:06:30.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"r1","is_error":true,"content":"Exit code 2"}]}}
EOF
cp "$T/cfgA/projects/$SLUG/s-first.jsonl" "$T/cfgB/projects/$SLUG/s-first.jsonl"
touch "$T/cfgA/projects/$SLUG/s-first.jsonl" "$T/cfgB/projects/$SLUG/s-first.jsonl"
printf '%s\n' '{"session":"s-first","cwd":"/x","by":"hi-guard","decision":"deny"}' '{"session":"s-restart","cwd":"/y","by":"claude-code","decision":"deny"}' \
  '{"session":"s-other","cwd":"/z","by":"x","decision":"deny"}' >"$T/den.jsonl"
bash "$C" record proj-10 "{\"title\":\"Ten\",\"repo\":\"team/proj\",\"workspace\":\"$WS2\",\"root\":\"$ROOT\"}"
out=$(HI_RETRO_CONFIG_DIRS="$T/cfgA $T/cfgB" HI_RETRO_DENIALS="$T/den.jsonl" bash "$R" gather proj-10)
has 'both transcripts, oldest first' "$out" $'1\t'"$T/cfgA/projects/$SLUG/s-first.jsonl"$'\n2\t'"$T/cfgB/projects/$SLUG/s-restart.jsonl"
check 'one per session across config dirs' "$(printf '%s\n' "$out" | grep -c 's-first.jsonl')" 1
has 'the usage-limit stop is a signal' "$out" $'1\tlimit\t2026-02-01T09:30:00.000Z\t\t\tYou\'ve hit your 5-hour limit'
has 'the restart transcript is read' "$out" $'2\terror\t2026-02-01T15:06:30.000Z\tBash\tmake test\tExit code 2'
has 'the wait for the restart is a stall' "$out" $'2\tstall\t2026-02-01T09:30:00.000Z\t\t\t335 min'
has 'denials of the first session' "$out" '"session":"s-first"'
has 'denials of the restart' "$out" '"session":"s-restart"'
case "$out" in *s-other*) no 'denials of other sessions dropped (restart)' ;; *) ok 'denials of other sessions dropped (restart)' ;; esac

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

# --- the configured comment command (highness#122: a tracker no built-in kind covers): it wins
# over tracker.kind and gh, gets the body as a file, and its failure is the comment's failure
cat >"$T/poster" <<'EOF'
#!/bin/sh
printf '%s|%s|%s\n' "$1" "$3" "$(pwd -P)" >>"$POST_LOG"
cat "$2" >>"$POST_LOG"
echo "posted"
EOF
chmod +x "$T/poster"
printf '%s\n' "{\"crew\":{\"retro_comment\":\"$T/poster {{TICKET}} {{BODY_FILE}} {{ROOT}}\"},\"tracker\":{\"kind\":\"youtrack\"}}" >"$ROOT/.claude/highness.json"
export POST_LOG="$T/post.log"; : >"$POST_LOG"; : >"$GH_LOG"
bash "$C" record proj-8 '{"retro_at": null}'
bash "$R" comment proj-8 || no 'comment command posts'
check 'comment command got the ticket and root, ran at the root' "$(sed -n 1p "$POST_LOG")" "proj-8|$ROOT|$(cd "$ROOT" && pwd -P)"
check 'comment command body starts with the retro mark' "$(sed -n 2p "$POST_LOG")" '<!-- hi:retro -->'
has 'comment command body lists what was filed' "$(cat "$POST_LOG")" '(agent) Retro of proj-8: what was filed.'
check 'gh not used when a comment command is set' "$(grep -c . "$GH_LOG")" 0
check 'retro_at recorded after the command' "$(bash "$C" get proj-8 | jq -r '.retro_at | test("^[0-9]{4}-")')" 'true'
printf '%s\n' '{"crew":{"retro_comment":"echo down >&2; exit 3"}}' >"$ROOT/.claude/highness.json"
bash "$C" record proj-8 '{"retro_at": null}'
out=$(bash "$R" comment proj-8 2>&1); rc=$?
check 'failing comment command exits 2' "$rc" 2
has 'failing comment command is named' "$out" 'crew.retro_comment exit 3: down'
check 'no retro_at when the command failed' "$(bash "$C" get proj-8 | jq -r '.retro_at')" 'null'
printf '%s\n' '{"crew":{"retro_sink":"false"}}' >"$ROOT/.claude/highness.json"

# --- close without a retro warns
bash "$C" record proj-9 '{"title":"Nine"}'
has 'close without a retro warns' "$(bash "$C" close proj-9 2>&1)" 'closed without a retro'

exit "$fail"
