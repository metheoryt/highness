#!/usr/bin/env bash
# lib/meet.sh — /hi:meet's counting over a synthetic transcript set (#77): only the person's own
# words, the window, the scrub, a draft whose every line carries evidence, accept, the team-rule
# body, and that a decline writes nothing.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
M="$HERE/../lib/meet.sh"
P="$(cd "$HERE/../../hi-crew/lib" && pwd -P)/prefs.sh"
command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }
export HIGHNESS_CONFIG="$SANDBOX/user.json"
echo '{}' >"$HIGHNESS_CONFIG"

NOW=$(jq -nr '(now - 2 * 86400) | todate')
DAY=${NOW%%T*}
OLD='2001-02-03T04:05:06.000Z'

# One transcript line each. Session ids and texts are made up. The default goes through a
# variable: bash 3.2 keeps the backslash of "${5:-{\}}".
NOEXTRA='{}'
u()  { jq -nc --arg s "$1" --arg t "$2" --arg x "$3" --arg c "$4" --argjson e "${5:-$NOEXTRA}" \
         '{type: "user", sessionId: $s, timestamp: $t, cwd: $c, entrypoint: "cli", uuid: ($s + ($x | length | tostring) + ($x[0:6])),
           origin: {kind: "human"}, message: {role: "user", content: $x}} + $e'; }
at() { jq -nc --arg s "$1" --arg t "$2" --arg x "$3" \
         '{type: "assistant", sessionId: $s, timestamp: $t, entrypoint: "cli", message: {content: [{type: "text", text: $x}]}}'; }
tu() { jq -nc --arg s "$1" --arg t "$2" --arg id "$3" --arg n "$4" --arg k "${5:-}" \
         '{type: "assistant", sessionId: $s, timestamp: $t, entrypoint: "cli",
           message: {content: [{type: "tool_use", id: $id, name: $n, input: (if $k != "" then {skill: $k} else {} end)}]}}'; }
rej() { jq -nc --arg s "$1" --arg t "$2" --arg id "$3" --arg fb "$4" \
         '{type: "user", sessionId: $s, timestamp: $t, entrypoint: "cli", uuid: ("r-" + $id),
           message: {content: [{type: "tool_result", tool_use_id: $id, is_error: true,
             content: ("The user doesn'"'"'t want to proceed with this tool use. The tool use was rejected." + (if $fb != "" then " To tell you how to proceed, the user said:\n" + $fb else "" end))}]}}'; }
den() { jq -nc --arg s "$1" --arg t "$2" --arg id "$3" --arg src "$4" --arg why "$5" \
         '{type: "user", sessionId: $s, timestamp: $t, entrypoint: "cli",
           permissionDecision: {decision: "reject", source: $src, reasonType: $why},
           message: {content: [{type: "tool_result", tool_use_id: $id, is_error: true, content: "Permission denied"}]}}'; }

A=a1a1a1a1-0000-4000-8000-000000000001   # project alpha: a rejection with words, a correction
B=b2b2b2b2-0000-4000-8000-000000000002   # project beta: the same ask again, an interrupt
C=c3c3c3c3-0000-4000-8000-000000000003   # fresh file, turns older than the window
D=d4d4d4d4-0000-4000-8000-000000000004   # headless (claude -p)
E=e5e5e5e5-0000-4000-8000-000000000005   # a dispatched worker
F=f6f6f6f6-0000-4000-8000-000000000006   # the /hi:meet run itself
CA="$HOME/work/alpha"; CB="$HOME/work/beta"

PR1="$CLAUDE_CONFIG_DIR/projects/-work-alpha"; PR2="$SANDBOX/profile/projects/-work-beta"
mkdir -p "$PR1" "$PR2"
{
  u "$A" "$NOW" 'Write the parser for the config file' "$CA"
  at "$A" "$NOW" 'Here is a parser.'
  tu "$A" "$NOW" tool-1 Edit
  rej "$A" "$NOW" tool-1 "keep functions short and never add comments

Note: The user's next message may contain a correction or preference. CLAUDE_CODE_NOTE"
  u "$A" "$NOW" "Don't add comments to the code, I asked for that already" "$CA"
  u "$A" "$NOW" 'see the brief <pasted_content id=1>PASTED_BRIEF_TEXT</pasted_content id=1>' "$CA"
  u "$A" "$NOW" 'my token: ghp_abcdefghijklmnop1234 and write to jane.doe@example.com from /home/someone/x' "$CA"
  tu "$A" "$NOW" tool-2 Bash
  den "$A" "$NOW" tool-2 hook hook
  tu "$A" "$NOW" tool-3 Bash
  den "$A" "$NOW" tool-3 user_reject ''
  u "$A" "$NOW" '<command-name>/hi:worktrees</command-name>' "$CA"
  tu "$A" "$NOW" tool-4 Skill hi-docs:write-doc
  u "$A" "$NOW" 'always run the tests before you commit anything' "$CA"
  u "$A" "$NOW" 'META_TEXT should not count' "$CA" '{"isMeta": true}'
  u "$A" "$NOW" 'PEER_TEXT from another agent' "$CA" '{"origin": {"kind": "peer"}}'
} >"$PR1/$A.jsonl"
{
  u "$B" "$NOW" 'always run the tests before you commit anything' "$CB"
  tu "$B" "$NOW" tool-5 AskUserQuestion
  rej "$B" "$NOW" tool-5 'The user wants to clarify these questions. CLARIFY_FORM_TEXT'
  u "$B" "$NOW" '[Request interrupted by user]' "$CB"
  u "$B" "$NOW" 'use English in commit messages' "$CB"
  u "$B" "$NOW" 'SIDECHAIN_TEXT from a subagent' "$CB" '{"isSidechain": true}'
} >"$PR2/$B.jsonl"
cp "$PR1/$A.jsonl" "$PR2/$A.jsonl"      # the same session seen through a second config dir
u "$C" "$OLD" 'OLD_SESSION_TEXT is outside the window' "$CA" >"$PR1/$C.jsonl"
u "$D" "$NOW" 'HEADLESS_TEXT from a nightly job' "$CA" '{"entrypoint": "sdk-cli"}' >"$PR1/$D.jsonl"
{ u "$E" "$NOW" 'You are working inside Orca. Your task ID is: task_1' "$CA"; u "$E" "$NOW" 'WORKER_TEXT relayed by the coordinator' "$CA"; } >"$PR1/$E.jsonl"
{ u "$F" "$NOW" '<command-name>/hi:meet</command-name>' "$CA"; u "$F" "$NOW" 'MEET_SELF_TEXT yes to line one' "$CA"; } >"$PR1/$F.jsonl"
# A resumed session copies earlier lines under the same uuid: not a second ask, not a second
# rejection.
G=a7a7a7a7-0000-4000-8000-000000000007
grep -e 'always run the tests' -e '"r-tool-1"' "$PR1/$A.jsonl" | jq -c --arg s "$G" '.sessionId = $s' >"$PR2/$G.jsonl"
u "$G" "$NOW" 'carry on from where we were' "$CA" >>"$PR2/$G.jsonl"
export HI_MEET_DIRS="$CLAUDE_CONFIG_DIR
$SANDBOX/profile
$SANDBOX/no-such-dir"

# --- sources and scan
src=$(bash "$M" sources)
assert_eq "sources: the config dirs that have projects/" "$CLAUDE_CONFIG_DIR
$SANDBOX/profile" "$src"
out=$(bash "$M" scan)
r() { printf '%s\n' "$out" | awk -F'\t' -v k="$1" '$1 == k { print $2 }'; }
assert_eq "scan: three sessions of the person's" 3 "$(r sessions)"
assert_eq "scan: two rejections (a resumed copy is not a third)" 2 "$(r rejection)"
assert_eq "scan: one denial (the person's, not the hook's)" 1 "$(r denial)"
assert_eq "scan: one interrupt" 1 "$(r interrupt)"
assert_eq "scan: one repeated ask" 1 "$(r repeat)"
assert_eq "scan: corrections — the opener, and the turn after the interrupt" 2 "$(r correction)"
assert_eq "scan: skills, typed and the agent's" 2 "$(r skill)"
said=$(bash "$M" list said --limit 99)
for x in PASTED_BRIEF_TEXT META_TEXT PEER_TEXT SIDECHAIN_TEXT OLD_SESSION_TEXT HEADLESS_TEXT WORKER_TEXT MEET_SELF_TEXT; do
  assert_not_contains "not the person's own words: $x" "$said" "$x"
done
assert_contains "a pasted block is cut, the person's words around it stay" "$said" 'see the brief'
assert_eq "a session seen twice is read once" 1 "$(printf '%s\n' "$said" | grep -c 'parser for the config')"
assert_not_contains "scrub: the token" "$said" 'ghp_abcdefghijklmnop1234'
assert_not_contains "scrub: the email" "$said" 'jane.doe@example.com'
assert_not_contains "scrub: a home path" "$said" '/home/someone'
assert_contains "scrub: masks what it removes" "$said" '<secret> and write to <email> from ~/x'
assert_not_contains "scrub: no home path in a project name" "$said" "$HOME"
rj=$(bash "$M" list rejection)
assert_contains "rejection: the tool and the person's words" "$rj" "Edit	keep functions short and never add comments"
assert_not_contains "rejection: not Claude Code's trailing note" "$rj" CLAUDE_CODE_NOTE
assert_not_contains "rejection: not the question tool's clarify form" "$rj" CLARIFY_FORM_TEXT
assert_contains "rejection: the clarify form still counts, with no words" "$rj" "AskUserQuestion	"
assert_contains "denial: the tool and its source" "$(bash "$M" list denial)" 'Bash (user_reject)'
assert_contains "correction: after the interrupt" "$(bash "$M" list correction)" "after interrupt	use English in commit messages"
assert_contains "repeat: two sessions" "$(bash "$M" list repeat)" "2	$DAY	$DAY	a1a1a1a1,b2b2b2b2	always run the tests"
sk=$(bash "$M" list skill)
assert_contains "skill: typed" "$sk" "hi:worktrees	1	0	1"
assert_contains "skill: by the agent" "$sk" "hi-docs:write-doc	0	1	1"
assert_contains "sample: the session with a rejection first" "$(bash "$M" sample | head -1)" 'a1a1a1a1'
sh=$(bash "$M" show a1a1a1a1)
assert_contains "show: the person's turns" "$sh" 'person: Write the parser'
assert_contains "show: a rejected call" "$sh" 'REJECTED by the person: Edit — keep functions short'
assert_not_contains "show: no pasted text" "$sh" PASTED_BRIEF_TEXT
bash "$M" show 'x;y' >/dev/null 2>&1; assert_status "show: refuses a non-id" 2 $?

# --- the draft: every line backed by evidence
DR="$SANDBOX/draft.md"
cat >"$DR" <<EOF
# hi:meet draft

## Preferences

1. Keep functions short and leave no code comments.
   - a1a1a1a1 $DAY "keep functions short and never add comments"
   - a1a1a1a1 $DAY "Don't add comments to the code"
2. Run the tests before every commit.
   - a1a1a1a1 $DAY alpha "always run the tests before you commit anything"
   - b2b2b2b2 $DAY beta "always run the tests before you commit anything"

## Team rule candidates

1. Run the full test suite before every commit.
   - a1a1a1a1 $DAY "always run the tests before you commit anything"
   - b2b2b2b2 $DAY "always run the tests before you commit anything"
EOF
bash "$M" check "$DR" >"$SANDBOX/check.out"; assert_status "check: a draft with evidence per line passes" 0 $?
assert_eq "check: says nothing when it passes" "" "$(cat "$SANDBOX/check.out")"

BAD="$SANDBOX/bad.md"
cat >"$BAD" <<EOF
## Preferences

1. A line with no evidence.
2. A quote the person never wrote.
   - a1a1a1a1 $DAY "please add many comments"
3. Another person's address.
   - a1a1a1a1 $DAY "write to jane.doe@example.com"
4. A session that was never scanned.
   - 99999999 $DAY "always run the tests"
5. The wrong day.
   - a1a1a1a1 2001-01-01 "always run the tests"
6. The worker's words.
   - e5e5e5e5 $DAY "WORKER_TEXT"

## Team rule candidates

1. Seen in one project only.
   - b2b2b2b2 $DAY "use English in commit messages"
EOF
chk=$(bash "$M" check "$BAD"); st=$?
assert_status "check: a bad draft fails" 1 "$st"
assert_contains "check: a line without evidence" "$chk" 'preferences 1: no evidence line'
assert_contains "check: a made-up quote" "$chk" "preferences 2: not the person's own words"
assert_contains "check: a quote the scrub would mask" "$chk" 'preferences 3: quote carries something the scrub masks'
assert_contains "check: an unknown session" "$chk" 'preferences 4: no scanned session 99999999'
assert_contains "check: a day the session has no turn on" "$chk" 'preferences 5: session a1a1a1a1 has no turn on 2001-01-01'
assert_contains "check: a session that is not the person's" "$chk" 'preferences 6: no scanned session e5e5e5e5'
assert_contains "check: a team rule needs two projects" "$chk" 'team 1: a team rule candidate needs evidence from two projects or more, has 1'

# --- accept, and the write through prefs.sh
acc=$(bash "$M" accept "$DR" 2)
assert_eq "accept: the rule and its source tag" "Run the tests before every commit. <!-- hi:meet a1a1a1a1 $DAY -->" "$acc"
assert_eq "accept: all of a section" 2 "$(bash "$M" accept "$DR" all | grep -c .)"
assert_contains "accept: the team section apart" "$(bash "$M" accept "$DR" 1 --section team)" 'Run the full test suite'
DEF="$XDG_CONFIG_HOME/highness/preferences.md"

# A decline: none accepted → no lines, and the file is never created.
acc=$(bash "$M" accept "$DR" none)
assert_eq "decline: nothing accepted, nothing printed" "" "$acc"
[ -n "$acc" ] && { printf '%s\n' "$acc" >"$SANDBOX/lines"; bash "$P" write "$DEF" "$SANDBOX/lines" >/dev/null; }
assert_eq "decline: no preferences file" absent "$([ -e "$DEF" ] && echo present || echo absent)"
# An existing store stays byte-identical on a decline, and gets only the accepted line on a yes.
mkdir -p "$(dirname "$DEF")"; printf '# Mine\n\n- an old line\n' >"$DEF"; cp "$DEF" "$SANDBOX/before"
acc=$(bash "$M" accept "$DR" none)
[ -n "$acc" ] && { printf '%s\n' "$acc" >"$SANDBOX/lines"; bash "$P" write "$DEF" "$SANDBOX/lines" >/dev/null; }
cmp -s "$DEF" "$SANDBOX/before"; assert_status "decline: an existing file is unchanged" 0 $?
bash "$M" accept "$DR" 2 >"$SANDBOX/lines"
bash "$P" write "$DEF" "$SANDBOX/lines" >/dev/null
assert_contains "accept: prefs.sh writes the accepted line" "$(cat "$DEF")" 'Run the tests before every commit.'
assert_not_contains "accept: only the accepted line" "$(cat "$DEF")" 'Keep functions short'
assert_not_contains "accept: no quote in the store" "$(cat "$DEF")" 'always run the tests before you commit'

# --- a team-rule candidate as a PR body: no quote, no session id, no path
R="$SANDBOX/team"; mkdir -p "$R/.claude"; git -C "$R" init -q
echo '{"crew": {"team_rules": "docs/rules.md"}}' >"$R/.claude/highness.json"
body=$(bash "$M" rule "$DR" 1 --root "$R")
assert_eq "rule: the target from crew.team_rules" 'target: docs/rules.md' "$(printf '%s\n' "$body" | head -1)"
assert_contains "rule: the rule" "$body" '- Run the full test suite before every commit.'
assert_contains "rule: the counts" "$body" '2 sessions across 2 projects'
assert_not_contains "rule: no quote" "$body" 'always run the tests'
assert_not_contains "rule: no session id" "$body" 'b2b2b2b2'
assert_not_contains "rule: no session id (2)" "$body" 'a1a1a1a1'
assert_not_contains "rule: no home path" "$body" "$HOME"
assert_eq "rule: no team file → target: none" 'target: none' "$(bash "$M" rule "$DR" 1 --root "$SANDBOX" | head -1)"
bash "$M" rule "$DR" 7 --root "$R" >/dev/null 2>&1; assert_status "rule: an unknown candidate" 2 $?

# --- prefs: hi-crew's writer, found beside this hi
assert_eq "prefs: the hi-crew beside this hi" "$P" "$(bash "$M" prefs)"

# --- discovery: ~/.claude and every Claude profile home Orca uses, each projects dir once
unset HI_MEET_DIRS
export HI_CLAUDE_PROFILE="$CLAUDE_CONFIG_DIR"   # the worker profile, with no call to Orca
OP="$HOME/.config/orca/claude-profiles"
H=b8b8b8b8-0000-4000-8000-000000000008
mkdir -p "$OP/p1/home/projects/-work-gamma" "$OP/p2/home"
u "$H" "$NOW" 'a turn in an Orca profile home' "$HOME/work/gamma" >"$OP/p1/home/projects/-work-gamma/$H.jsonl"
ln -s "$CLAUDE_CONFIG_DIR/projects" "$OP/p2/home/projects"   # a profile sharing ~/.claude's projects
assert_eq "sources: ~/.claude, then the Orca profile, the shared one once" "$CLAUDE_CONFIG_DIR
$OP/p1/home" "$(bash "$M" sources)"
out=$(bash "$M" scan)
assert_eq "scan: finds the profile home's session" 1 "$(bash "$M" list said --limit 99 | grep -c 'in an Orca profile home')"
assert_eq "scan: a shared projects dir is read once" 1 "$(bash "$M" list said --limit 99 | grep -c 'parser for the config')"
assert_eq "scan: the person's sessions across both" 2 "$(r sessions)"

# --- the window and clean
out=$(bash "$M" scan --days 0)
assert_eq "--days 0: nothing in the window" 0 "$(r sessions)"
bash "$M" scan --days x >/dev/null 2>&1; assert_status "--days wants a number" 2 $?
bash "$M" clean
assert_eq "clean: the cache is gone" absent "$([ -e "$(bash "$M" dir)" ] && echo present || echo absent)"
bash "$M" counts >/dev/null 2>&1; assert_status "counts before a scan" 2 $?

assert_summary
