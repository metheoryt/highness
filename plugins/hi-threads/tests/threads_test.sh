#!/usr/bin/env bash
# threads.sh: the digest, the project, the cursor, applying a model's ops, ranking, the hooks and
# ticket comments. The model is a fake `claude` on PATH that records its input and prints a reply.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TH="$HERE/../lib/threads.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
T=$(cd "$T" && pwd -P)
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/config.json" XDG_CONFIG_HOME="$T/xdg"
DIR="$HIGHNESS_STATE/threads"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

mkdir -p "$T/bin" "$T/calls"
cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
n=$(ls "$FAKE_CALLS" | grep -vc args)
cat >"$FAKE_CALLS/$n"
printf '%s\n' "$*" >"$FAKE_CALLS/$n.args"
cat "$FAKE_REPLY"
EOF
chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH" FAKE_CALLS="$T/calls" FAKE_REPLY="$T/reply"
calls() { ls "$T/calls" | grep -vc args; }
reply() { printf '%s\n' "$1" >"$T/reply"; }

# A repo inside an umbrella (a repos.txt above it) and a worktree of it elsewhere.
mkdir -p "$T/umb/repos/svc" && touch "$T/umb/repos.txt"
git -C "$T/umb/repos/svc" init -q && git -C "$T/umb/repos/svc" -c user.email=a@b -c user.name=a commit -q --allow-empty -m i
git -C "$T/umb/repos/svc" worktree add -q "$T/wt/svc-1" -b b1 2>/dev/null
check 'project: a clone belongs to its umbrella' "$(bash "$TH" project "$T/umb/repos/svc")" "$T/umb"
check 'project: a worktree of the clone too' "$(bash "$TH" project "$T/wt/svc-1")" "$T/umb"
mkdir -p "$T/plain"
check 'project: a plain directory is itself' "$(bash "$TH" project "$T/plain")" "$T/plain"

TR="$T/t.jsonl"
u() { jq -n -c --arg t "$1" '{type: "user", message: {role: "user", content: $t}}'; }
a() { jq -n -c --arg t "$1" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}'; }
tool() { jq -n -c '{type: "assistant", message: {content: [{type: "tool_use", id: "x", name: "Bash", input: {command: "git status\nmore"}}]}}'; }
side() { jq -n -c '{type: "assistant", isSidechain: true, message: {content: [{type: "text", text: "SUBAGENT"}]}}'; }
{ printf '{"type":"user","entrypoint":"cli","message":{"role":"user","content":"fix the login<system-reminder>SECRET CONTEXT</system-reminder>"}}\n'
  tool; side; a 'Fixed. Still need to add a test.'; } >"$TR"

d=$(bash "$TH" digest "$TR")
check 'digest: the prompt without the injected block' "$(printf '%s\n' "$d" | sed -n 1p)" '[USER] fix the login'
check 'digest: a tool call in one line' "$(printf '%s\n' "$d" | sed -n 2p)" '[TOOL] Bash git status'
check 'digest: no subagent entries' "$(printf '%s\n' "$d" | grep -c SUBAGENT)" '0'

# process: one model call, the thread created, the cursor at the end of the file.
reply '{"ops":[{"op":"create","title":"Login fix","status":"active","next":"add a test","open_items":["add a test"],"waits_on":"agent","ticket":"AB-1","note":"fixed"}]}'
bash "$TH" process "$TR" s1 "$T/wt/svc-1"
check 'process: one model call' "$(calls)" '1'
check 'process: the model gets the activity' "$(grep -c '^\[USER\] fix the login' "$T/calls/0")" '1'
check 'process: the inner run has no hooks, tools or saved session' \
  "$(grep -c -- "--no-session-persistence --tools  --strict-mcp-config --settings {\"disableAllHooks\":true}" "$T/calls/0.args")" '1'
check 'process: thread created in the project' "$(jq -r '.threads[0] | [.title, .project, .status] | @tsv' "$DIR/threads.json")" "Login fix	$T/umb	active"
check 'process: repo is the main checkout' "$(jq -r '.threads[0].repos[0]' "$DIR/threads.json")" "$T/umb/repos/svc"
check 'process: cursor at the end' "$(cat "$DIR/cursors/s1")" "$(wc -c <"$TR" | tr -d ' ')"
bash "$TH" process "$TR" s1 "$T/wt/svc-1"
check 'process: nothing new, no model call' "$(calls)" '1'

# A line still being written is left for the next job.
id=$(jq -r '.threads[0].id' "$DIR/threads.json")
size=$(wc -c <"$TR" | tr -d ' ')
printf '{"type":"user","message":{"role":"user","content":"half' >>"$TR"
bash "$TH" process "$TR" s1 "$T/wt/svc-1"
check 'process: a partial line is not read' "$(calls)|$(cat "$DIR/cursors/s1")" "1|$size"
printf ' done"}}\n' >>"$TR"; a 'Switching to the docs now.' >>"$TR"

# update: the switch pauses the thread; the change is an event.
reply "{\"ops\":[{\"op\":\"update\",\"id\":\"$id\",\"status\":\"paused\",\"note\":\"left for docs\"},{\"op\":\"create\",\"title\":\"Docs\",\"status\":\"active\",\"waits_on\":\"agent\"},{\"op\":\"create\",\"title\":\"Try caching\",\"status\":\"idea\",\"waits_on\":\"none\"}]}"
bash "$TH" process "$TR" s1 "$T/wt/svc-1"
check 'update: the model sees the open thread' "$(grep -c '"title":"Login fix"' "$T/calls/1")" '1'
check 'update: paused' "$(jq -r --arg id "$id" '.threads[] | select(.id == $id) | .status' "$DIR/threads.json")" 'paused'
check 'update: open items kept' "$(jq -r --arg id "$id" '.threads[] | select(.id == $id) | .open_items[0]' "$DIR/threads.json")" 'add a test'
check 'events: the status change logged' "$(jq -r --arg id "$id" 'select(.id == $id) | .from + ">" + .to' "$DIR/events.jsonl" | tail -1)" 'active>paused'

# list: left unfinished before active before ideas.
check 'list: ranked' "$(cd "$T/umb" && bash "$TH" list | cut -f5 | tr '\n' ,)" 'Login fix,Docs,Try caching,'
check 'list: another project sees none' "$(cd "$T/plain" && bash "$TH" list | wc -l | tr -d ' ')" '0'
check 'agenda: a paused thread waits on the person' "$(cd "$T/umb" && bash "$TH" agenda | head -1 | jq -r '.group + " " + .title')" 'you Login fix (AB-1)'

# hook-start: the top threads as context.
out=$(printf '{}' | (cd "$T/umb/repos/svc" && bash "$TH" hook-start))
check 'hook-start: context names the paused thread' "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -c 'paused.*Login fix')" '1'
check 'hook-start: nothing for another project' "$(printf '{}' | (cd "$T/plain" && bash "$TH" hook-start))" ''

# hook-stop: the inner run and headless sessions start nothing.
stop() { jq -n -c --arg tr "$1" --arg c "$T/umb" '{hook_event_name: "Stop", session_id: "s2", transcript_path: $tr, cwd: $c}'; }
stop "$TR" | HI_THREADS_INNER=1 bash "$TH" hook-stop
HL="$T/headless.jsonl"; printf '{"type":"user","entrypoint":"sdk-cli","message":{"role":"user","content":"x"}}\n' >"$HL"
stop "$HL" | CLAUDE_CODE_ENTRYPOINT= bash "$TH" hook-stop
sleep 1
check 'hook-stop: inner run and headless start no job' "$(ls "$DIR/cursors" | tr '\n' ,)" 's1,'
echo '{"threads":{"enabled":false}}' >"$HIGHNESS_CONFIG"
stop "$TR" | bash "$TH" hook-stop; sleep 1
check 'hook-stop: off by config' "$(ls "$DIR/cursors" | tr '\n' ,)" 's1,'
rm -f "$HIGHNESS_CONFIG"
reply '{"ops":[]}'
stop "$TR" | CLAUDE_CODE_ENTRYPOINT=cli bash "$TH" hook-stop
n=0; while { [ ! -f "$DIR/cursors/s2" ] || [ -d "$DIR/s-s2.lock" ]; } && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
check 'hook-stop: starts the job in the background' "$([ -f "$DIR/cursors/s2" ] && echo yes)" 'yes'

# Comments: a closed thread with a ticket gets one, with a token masked; replay posts none.
jq -n --arg out "$T/comment" '{threads: {comment: {commands: [{match: "^AB-", project: "/elsewhere$", command: "exit 1"}, {match: "^AB-", project: "/umb$", command: ("{ echo \"$HI_THREAD_TICKET\"; cat; } > " + $out)}]}}}' >"$HIGHNESS_CONFIG"
a 'Done, tests pass.' >>"$TR"
reply "{\"ops\":[{\"op\":\"close\",\"id\":\"$id\",\"note\":\"test added with key ghp_abcdefghijklmnop1234\"}]}"
bash "$TH" process "$TR" s1 "$T/wt/svc-1"
check 'comment: sent to the ticket' "$(head -1 "$T/comment" 2>/dev/null)" 'AB-1'
check 'comment: says the thread is done' "$(grep -c 'Login fix.*done' "$T/comment" 2>/dev/null)" '1'
check 'comment: token masked' "$(grep -c 'ghp_abc' "$T/comment" 2>/dev/null)|$(grep -c 'ghp_\*\*\*' "$T/comment" 2>/dev/null)" '0|1'
rm -f "$T/comment"
reply "{\"ops\":[{\"op\":\"update\",\"id\":\"$id\",\"status\":\"paused\"}]}"
bash "$TH" replay "$TR" s3 "$T/umb"
check 'replay: no comment' "$([ -f "$T/comment" ] && echo sent || echo none)" 'none'
check 'replay: cursor set at the end' "$(cat "$DIR/cursors/s3")" "$(wc -c <"$TR" | tr -d ' ')"

# A session met for the first time with history: only the turn that just ended is read; the
# history is backfill's, up to that point, and posts nothing.
rm -f "$HIGHNESS_CONFIG"
TR2="$T/t2.jsonl"; { u 'old work on AB-9'; a 'old answer'; u 'new question'; a 'new answer'; } >"$TR2"
reply '{"ops":[]}'
c0=$(calls); bash "$TH" process "$TR2" s4 "$T/umb"
last=$(ls "$T/calls" | grep -v args | sort -n | tail -1)
check 'first job: one call' "$(( $(calls) - c0 ))" '1'
check 'first job: history left out' "$(grep -c 'old work' "$T/calls/$last")|$(grep -c 'new question' "$T/calls/$last")" '0|1'
check 'first job: origin recorded' "$(cat "$DIR/origin/s4")" "$(head -2 "$TR2" | wc -c | tr -d ' ')"
c0=$(calls); bash "$TH" replay "$TR2" s4 "$T/umb" "$(cat "$DIR/origin/s4")"
last=$(ls "$T/calls" | grep -v args | sort -n | tail -1)
check 'backfill replay: only the history' "$(( $(calls) - c0 ))|$(grep -c 'old work' "$T/calls/$last")|$(grep -c 'new question' "$T/calls/$last")" '1|1|0'
check 'backfill replay: the live cursor kept' "$(cat "$DIR/cursors/s4")" "$(wc -c <"$TR2" | tr -d ' ')"
check 'backfill replay: marked' "$([ -f "$DIR/backfilled/s4" ] && echo yes)" 'yes'

# A paused thread is commented only after the quiet time, and once while nothing new happens.
jq -n --arg out "$T/comment" '{threads: {comment: {quiet_minutes: 120, commands: [{match: "^AB-", command: ("cat >> " + $out)}]}}}' >"$HIGHNESS_CONFIG"
rm -f "$T/comment"
a 'Back on login.' >>"$TR"
reply "{\"ops\":[{\"op\":\"update\",\"id\":\"$id\",\"status\":\"paused\",\"note\":\"paused again\"}]}"
bash "$TH" process "$TR" s1 "$T/wt/svc-1"
check 'paused: no comment before the quiet time' "$([ -f "$T/comment" ] && echo sent || echo none)" 'none'
jq '.threads.comment.quiet_minutes = -1' "$HIGHNESS_CONFIG" >"$T/c" && mv "$T/c" "$HIGHNESS_CONFIG"
a 'Still on docs.' >>"$TR"; reply '{"ops":[]}'
bash "$TH" process "$TR" s1 "$T/wt/svc-1"
check 'paused: commented once quiet' "$(grep -c 'paused again' "$T/comment" 2>/dev/null)" '1'
a 'More docs.' >>"$TR"
bash "$TH" process "$TR" s1 "$T/wt/svc-1"
check 'paused: not again with nothing new' "$(grep -c 'Agent journal' "$T/comment")" '1'


# A replay stops at the first turn the model fails on and goes on from there next time.
rm -f "$HIGHNESS_CONFIG"
TR3="$T/t3.jsonl"; { u 'turn one'; a 'a1'; u 'turn two'; a 'a2'; u 'turn three'; a 'a3'; } >"$TR3"
reply '{"ops":[]}'
cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
n=$(ls "$FAKE_CALLS" | grep -vc args)
cat >"$FAKE_CALLS/$n"
printf '%s\n' "$*" >"$FAKE_CALLS/$n.args"
if grep -q 'turn two' "$FAKE_CALLS/$n" && [ -f "$FAKE_LIMIT" ]; then echo "You've hit your usage limit"; exit 1; fi
cat "$FAKE_REPLY"
EOF
export FAKE_LIMIT="$T/limit"; touch "$FAKE_LIMIT"
c0=$(calls); bash "$TH" replay "$TR3" s5 "$T/umb"; rc=$?
check 'replay: stops on the failing turn' "$rc|$(( $(calls) - c0 ))|$([ -f "$DIR/backfilled/s5" ] && echo marked || echo open)" '1|2|open'
check 'replay: the reply is in the log' "$(grep -c 'model said: You.ve hit your usage limit' "$DIR/log")" '1'
check 'replay: where it stopped' "$(cat "$DIR/replayed/s5")" "$(head -2 "$TR3" | wc -c | tr -d ' ')"
rm -f "$FAKE_LIMIT"; c0=$(calls); bash "$TH" replay "$TR3" s5 "$T/umb"
first=$(ls "$T/calls" | grep -v args | sort -n | sed -n "$((c0 + 1))p")
check 'replay: goes on from there' "$(( $(calls) - c0 ))|$(grep -c 'turn one' "$T/calls/$first")|$(grep -c 'turn two' "$T/calls/$first")" '2|0|1'
check 'replay: marked once through' "$([ -f "$DIR/backfilled/s5" ] && echo marked)|$([ -f "$DIR/replayed/s5" ] && echo left || echo gone)" 'marked|gone'

# A sentence or a code fence around the ops object does not lose the turn.
TR6="$T/t6.jsonl"; u 'rename it' >"$TR6"; a 'Renamed.' >>"$TR6"
reply "Обновляю нить.
\`\`\`json
{\"ops\":[{\"op\":\"create\",\"title\":\"Prose first\",\"status\":\"active\",\"waits_on\":\"agent\"}]}
\`\`\`
Готово."
bash "$TH" process "$TR6" s6 "$T/umb"
check 'model: ops after a sentence' "$(jq -r '[.threads[] | select(.title == "Prose first")] | length' "$DIR/threads.json")" '1'
reply 'Session moved on. {"ops":[{"op":"create","title":"Same line","status":"idea","waits_on":"none"}]}'
a 'More.' >>"$TR6"; u 'next' >>"$TR6"; a 'Done.' >>"$TR6"
bash "$TH" process "$TR6" s6 "$T/umb"
check 'model: ops after a sentence on the same line' "$(jq -r '[.threads[] | select(.title == "Same line")] | length' "$DIR/threads.json")" '1'

# relay: the decisions go to the thread's own session through hi's wt.sh dispatch, once; the
# resume line comes back only when nothing was started or typed. A fake wt.sh records its argv,
# prints FAKE_WT_OUT and exits with WT_RC.
check 'agenda: a thread row carries its session and cwd' "$(cd "$T/umb" && bash "$TH" agenda | head -1 | jq -r 'has("session") and has("cwd")')" 'true'
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/wt.log"\nprintf "%%b" "$FAKE_WT_OUT"\nexit "${WT_RC:-0}"\n' "$T" >"$T/wt.sh"
printf 'Decided: keep the old API.\n' >"$T/decisions.md"
mkdir -p "$T/wt/svc-1/sub"
SID=0d1f2e3c-aaaa-bbbb-cccc-000000000001
relay() { # <rc> <dispatch stdout> → "<stdout>|<exit>|<calls>"
  local o r=0; rm -f "$T/wt.log"
  o=$(HI_WT_SH="$T/wt.sh" WT_RC=$1 FAKE_WT_OUT=$2 bash "$TH" relay "$T/wt/svc-1/sub" "$SID" "$T/decisions.md" 2>/dev/null) || r=$?
  printf '%s|%s|%s' "$o" "$r" "$( [ -f "$T/wt.log" ] && wc -l <"$T/wt.log" | tr -d ' ' || echo 0)"
}
TAB=$(printf '\t')
check 'relay: typed into the live session' "$(relay 0 "$SID\tsend\tterm_1\n")" "sent${TAB}term_1|0|1"
check 'relay: one dispatch of the worktree root, resuming the session, with the brief' "$(cat "$T/wt.log")" "dispatch $T/wt/svc-1 --resume $SID --brief $T/decisions.md"
check 'relay: no live session, resumed in a new terminal' "$(relay 0 "$SID\torca\tterm_2\n")" "started${TAB}term_2|0|1"
check 'relay: typed, not seen taken — no resend' "$(relay 5 "$SID\tunconfirmed\tterm_1\n")" "unconfirmed${TAB}term_1|0|1"
check 'relay: resumed onto a dialog — no resume line' "$(relay 6 "$SID\torca\tterm_3\n")" "dialog${TAB}term_3|0|1"
check 'relay: busy — said, one call, no wait' "$(relay 3 "$SID\tbusy\t\n")" "busy${TAB}busy|3|1"
check 'relay: a chat open there is busy too' "$(relay 3 "$SID\tchat\t\n")" "busy${TAB}chat|3|1"
check 'relay: nothing could start (no Orca, no tmux) — the resume line' "$(relay 0 "$SID\tprint\t\nline\n")" "manual${TAB}cd '$T/wt/svc-1/sub' && claude --resume $SID|1|1"
check 'relay: dispatch failed — the resume line' "$(relay 1 '')" "manual${TAB}cd '$T/wt/svc-1/sub' && claude --resume $SID|1|1"
rm -f "$T/wt.log"
o=$(HI_WT_SH="$T/none.sh" bash "$TH" relay "$T/wt/svc-1" "$SID" "$T/decisions.md" 2>/dev/null); r=$?
check 'relay: no hi plugin — the resume line, nothing run' "$o|$r|$([ -f "$T/wt.log" ] && echo ran || echo none)" "manual${TAB}cd '$T/wt/svc-1' && claude --resume $SID|1|none"
o=$(HI_WT_SH="$T/wt.sh" bash "$TH" relay "$T/plain" "$SID" "$T/decisions.md" 2>/dev/null); r=$?
check 'relay: not a git work tree — the resume line, nothing run' "$o|$r|$([ -f "$T/wt.log" ] && echo ran || echo none)" "manual${TAB}cd '$T/plain' && claude --resume $SID|1|none"
HI_WT_SH="$T/wt.sh" bash "$TH" relay "$T/wt/svc-1" "$SID" "$T/missing.md" 2>/dev/null; r=$?
check 'relay: no brief file is a usage error' "$r|$([ -f "$T/wt.log" ] && echo ran || echo none)" '2|none'

# The live check: the team's commands say what became of the PRs and tickets a thread names.
CK="$T/ck"; mkdir -p "$CK/proj/.claude" "$CK/other/.claude" "$CK/state"
git -C "$CK/proj" init -q; git -C "$CK/other" init -q
cat >"$CK/fake.sh" <<'EOF'
#!/bin/sh
echo "$1" >>"$CK_LOG"
case "$1" in slow*) sleep 5 ;; esac
grep "^$1	" "$CK_STATES" | cut -f2
EOF
printf 'svc#1\t{"state":"merged"}\nAB-1\t{"state":"Done","resolved":true}\nsvc#2\t{"state":"merged"}\nAB-2\t{"state":"In Review","resolved":false}\nsvc#3\tnot json\nsvc#9\t{"state":"merged"}\n' >"$CK/states"
for d in proj other; do
  printf '{"threads":{"check":{"pr":"sh %s {{PR}}","ticket":"sh %s {{KEY}}"}}}' "$CK/fake.sh" "$CK/fake.sh" >"$CK/$d/.claude/highness.json"
done
now=$(date +%s); old=$((now - 10 * 86400))
jq -n --arg p "$CK/proj" --arg o "$CK/other" --argjson now "$now" --argjson old "$old" '{threads: [
  {id: "A", project: $p, title: "landed", status: "waiting", waits_on: "person", next: "merge it", open_items: ["merge"], pr: "svc#1", ticket: "AB-1", updated: "x", updated_epoch: $now},
  {id: "B", project: $p, title: "half", status: "waiting", waits_on: "person", next: "merge", open_items: [], pr: "svc#2", ticket: "AB-2", updated: "x", updated_epoch: $now},
  {id: "C", project: $p, title: "unknown", status: "active", waits_on: "agent", next: "", open_items: [], pr: "svc#3", ticket: "", updated: "x", updated_epoch: $now},
  {id: "D", project: $p, title: "old note", status: "active", waits_on: "person", next: "", open_items: [], pr: "", ticket: "", updated: "x", updated_epoch: $old},
  {id: "E", project: $p, title: "new note", status: "active", waits_on: "person", next: "", open_items: [], pr: "", ticket: "", updated: "x", updated_epoch: $now},
  {id: "F", project: $o, title: "elsewhere", status: "waiting", waits_on: "person", next: "", open_items: [], pr: "svc#9", ticket: "", updated: "x", updated_epoch: $now}]}' \
  >"$CK/state/threads.json"
mkdir -p "$CK/state/threads"; mv "$CK/state/threads.json" "$CK/state/threads/threads.json"
ck() { (cd "$CK/proj" && HIGHNESS_STATE="$CK/state" CK_LOG="$CK/log" CK_STATES="$CK/states" bash "$TH" "$@"); }
CL="$CK/state/threads/threads.json"
ag=$(ck agenda)
check 'check: every PR merged and every ticket resolved — closed' "$(jq -r '.threads[] | select(.id == "A") | [.status, .waits_on, (.open_items | length)] | @tsv' "$CL")" "done	none	0"
check 'check: the reason in the history' "$(jq -r '.threads[] | select(.id == "A") | .history[-1] | [.session, .note] | @tsv' "$CL")" "check	closed by the live check: svc#1 merged, AB-1 Done"
check 'check: one event, from the check' "$(jq -r 'select(.id == "A") | [.from, .to, .session] | @tsv' "$CK/state/threads/events.jsonl")" "waiting	done	check"
check 'check: a ticket still open keeps the thread open' "$(jq -r '.threads[] | select(.id == "B") | .status' "$CL")" 'waiting'
check 'check: an answer that is not JSON leaves the link unchecked, the thread open' "$(jq -r '.threads[] | select(.id == "C") | [.status, (.check.links | length)] | @tsv' "$CL")" "active	0"
check 'check: another project is not touched' "$(jq -r '.threads[] | select(.id == "F") | [.status, (.check // "none")] | @tsv' "$CL")" "waiting	none"
check 'agenda: the closed thread first, as done' "$(printf '%s\n' "$ag" | head -1 | jq -r '[.group, .title, .next] | @tsv')" "done	landed (AB-1)	closed by the live check: svc#1 merged, AB-1 Done"
check 'agenda: what the check found on an open thread' "$(printf '%s\n' "$ag" | jq -r 'select(.title == "half (AB-2)") | .live')" 'svc#2 merged; AB-2 In Review'
check 'agenda: an old thread with no links is stale' "$(printf '%s\n' "$ag" | jq -r 'select(.title == "old note") | .stale')" 'true'
check 'agenda: a fresh one is not' "$(printf '%s\n' "$ag" | jq -r 'select(.title == "new note") | .stale')" 'false'
check 'agenda: a closed thread is listed once' "$(printf '%s\n' "$ag" | grep -c '"landed (AB-1)"')" '1'
n=$(wc -l <"$CK/log"); ck check >/dev/null
check 'check: a fresh result is reused; only the unanswered link is asked again' "$(( $(wc -l <"$CK/log") - n ))" '1'
n=$(wc -l <"$CK/log"); ck check --ttl 0 >/dev/null
check 'check: past its ttl, each link of an open thread is asked again' "$(( $(wc -l <"$CK/log") - n ))" '3'
jq --argjson now "$now" '.threads += [{id: "S", project: "'"$CK/proj"'", title: "slow", status: "active", waits_on: "person", next: "", open_items: [], pr: "slow#1", ticket: "", updated: "x", updated_epoch: $now}]' "$CL" >"$CL.n" && mv "$CL.n" "$CL"
s0=$(date +%s); HI_THREADS_CHECK_TIMEOUT=1 ck check --ttl 0 >/dev/null; s1=$(date +%s)
check 'check: a hung command is cut off, its thread stays open' "$([ $((s1 - s0)) -lt 4 ] && echo fast || echo slow) $(jq -r '.threads[] | select(.id == "S") | .status' "$CL")" 'fast active'
mkdir "$CK/state/threads/check.lock"
check 'check: another check runs — gives up at once, prints nothing' "$(ck check --ttl 0)" ''
rmdir "$CK/state/threads/check.lock"

# A paused thread the check closes gets no ticket comment from the next turn's sweep.
jq --argjson old "$old" '.threads += [{id: "P", project: "'"$CK/proj"'", title: "paused landed", status: "paused", waits_on: "person", next: "x", open_items: ["x"], pr: "svc#1", ticket: "AB-1", updated: "x", updated_epoch: $old, history: [{at: "x", session: "s", note: "did a thing"}]}]' "$CL" >"$CL.n" && mv "$CL.n" "$CL"
ck check --ttl 0 >/dev/null
printf '{"threads":{"comment":{"commands":[{"match":".","command":"cat >>%s"}]}}}' "$CK/posted" >"$CK/user.json"
reply '{"ops":[]}'
{ u 'hello'; a 'hi'; } >"$CK/t.jsonl"
(cd "$CK/proj" && HIGHNESS_STATE="$CK/state" HIGHNESS_CONFIG="$CK/user.json" CK_LOG="$CK/log" CK_STATES="$CK/states" bash "$TH" process "$CK/t.jsonl" sck "$CK/proj")
check 'check: a paused thread it closed is done' "$(jq -r '.threads[] | select(.id == "P") | .status' "$CL")" 'done'
check 'check: and the next turn posts no comment for it' "$([ -s "$CK/posted" ] && echo posted || echo none)" 'none'

# The sweep: the live check over the whole journal, every project. Only an answer counts: a
# command that fails or is rate-limited leaves the thread open.
cat >"$CK/fake.sh" <<'EOF'
#!/bin/sh
echo "$1" >>"$CK_LOG"
case "$1" in slow*) sleep 5 ;; fail*) echo '{"state":"merged"}'; exit 1 ;; esac
grep "^$1	" "$CK_STATES" | cut -f2
EOF
printf 'rl#1\t{"message":"API rate limit exceeded","documentation_url":"x"}\nhttps://github.com/o/svc/pull/5\t{"state":"MERGED"}\nsvc#6\t{"state":"CLOSED","resolved":true}\nsvc#7\t{"state":"OPEN","resolved":false}\n' >>"$CK/states"
day=86400
jq --argjson now "$now" --argjson old $((now - 20 * day)) --argjson mid $((now - 10 * day)) --arg p "$CK/proj" --arg o "$CK/other" '
  def th($id; $proj; $pr; $ticket; $epoch): {id: $id, project: $proj, title: $id, status: "waiting", waits_on: "person",
    next: "n", open_items: ["x"], pr: $pr, ticket: $ticket, updated: "x", updated_epoch: $epoch};
  .threads += [th("F1"; $o; "svc#9"; ""; $now), th("G"; $o; "rl#1"; ""; $now), th("H"; $o; "fail#1"; ""; $now),
               th("U"; $o; "https://github.com/o/svc/pull/5"; "svc#6"; $now), th("V"; $o; ""; "svc#7"; $now),
               th("I1"; $p; ""; ""; $old) + {imported: true, sessions: ["r9"]},
               th("I2"; $p; ""; ""; $now) + {imported: true},
               th("I3"; $p; ""; ""; $old) + {imported: false},
               th("IM"; $p; ""; ""; $mid) + {imported: true},
               th("L1"; $p; ""; ""; $old) + {sessions: ["r1"]},
               th("L2"; $p; ""; ""; $old) + {sessions: ["r1", "r2"]},
               th("L3"; $p; ""; ""; $old) + {sessions: []}]' "$CL" >"$CL.n" && mv "$CL.n" "$CL"
mkdir -p "$CK/state/threads/backfilled" "$CK/state/threads/origin"
touch "$CK/state/threads/backfilled/r1" "$CK/state/threads/backfilled/r2" "$CK/state/threads/origin/r2"
st() { jq -r --arg id "$1" '.threads[] | select(.id == $id) | .status' "$CL"; }
rm -f "$CK/posted"
printf '{"threads":{"check":{"pr":"sh %s {{PR}}","ticket":"sh %s {{KEY}}"},"sweep":{"imported_days":15}}}' "$CK/fake.sh" "$CK/fake.sh" >"$CK/proj/.claude/highness.json"
out=$(cd "$CK/proj" && HIGHNESS_STATE="$CK/state" HIGHNESS_CONFIG="$CK/user.json" CK_LOG="$CK/log" CK_STATES="$CK/states" bash "$TH" sweep)
check 'sweep: another project'"'"'s landed thread is closed' "$(st F1)" 'done'
check 'sweep: a rate-limited answer is not done' "$(st G) $(jq -r '.threads[] | select(.id == "G") | .check.links | length' "$CL")" 'waiting 0'
check 'sweep: a failing command is not done, whatever it printed' "$(st H)" 'waiting'
check 'sweep: a PR URL and a repo#N ticket are checked' "$(st U) $(jq -r '.threads[] | select(.id == "U") | .history[-1].note' "$CL")" \
  'done closed by the live check: https://github.com/o/svc/pull/5 MERGED, svc#6 CLOSED'
check 'sweep: a repo#N ticket still open keeps its thread' "$(st V)" 'waiting'
check 'age-out: imported, untouched past the age — dropped, kept' "$(jq -r '.threads[] | select(.id == "I1") | [.status, .waits_on, (.open_items | length), (.aged_out != null), .history[-1].session] | @tsv' "$CL")" "dropped	none	0	true	sweep"
check 'age-out: the age is configurable (10 days old, 15 set)' "$(st IM)" 'waiting'
check 'age-out: imported but fresh — kept open' "$(st I2)" 'waiting'
check 'age-out: a live turn touched it — kept open' "$(st I3)" 'waiting'
check 'age-out: an old journal, every session only replayed — dropped' "$(st L1)" 'dropped'
check 'age-out: an old journal, a session read live — kept open' "$(st L2)" 'waiting'
check 'age-out: no sessions known — kept open' "$(st L3)" 'waiting'
check 'sweep: prints what it closed and dropped' "$(printf '%s\n' "$out" | sort | tr '\n' ,)" 'F1,I1,L1,U,'
check 'age-out: one event each, from the sweep' "$(jq -r 'select(.session == "sweep") | .id + ">" + .to' "$CK/state/threads/events.jsonl" | sort | tr '\n' ,)" 'I1>dropped,L1>dropped,'
check 'sweep: posts no ticket comment' "$([ -s "$CK/posted" ] && echo posted || echo none)" 'none'
check 'sweep: never deletes a thread' "$(jq '.threads | length' "$CL")" '20'
jq '.threads |= map(if .id == "IM" then .updated_epoch = 0 else . end)' "$CL" >"$CL.n" && mv "$CL.n" "$CL"
printf '{"threads":{"check":{"pr":"sh %s {{PR}}","ticket":"sh %s {{KEY}}"},"sweep":{"imported_days":0}}}' "$CK/fake.sh" "$CK/fake.sh" >"$CK/proj/.claude/highness.json"
(cd "$CK/proj" && HIGHNESS_STATE="$CK/state" CK_LOG="$CK/log" CK_STATES="$CK/states" bash "$TH" sweep >/dev/null)
check 'age-out: 0 days turns it off' "$(st IM)" 'waiting'

# After a turn the job sweeps once in threads.sweep.hours, not every turn.
printf '{"threads":{"check":{"pr":"sh %s {{PR}}","ticket":"sh %s {{KEY}}"}}}' "$CK/fake.sh" "$CK/fake.sh" >"$CK/proj/.claude/highness.json"
jq --argjson now "$now" '.threads += [{id: "F2", project: "'"$CK/other"'", title: "later", status: "waiting", waits_on: "person", next: "", open_items: [], pr: "svc#9", ticket: "", updated: "x", updated_epoch: $now}]' "$CL" >"$CL.n" && mv "$CL.n" "$CL"
pr() { a 'more' >>"$CK/t.jsonl"; u 'again' >>"$CK/t.jsonl"; (cd "$CK/proj" && HIGHNESS_STATE="$CK/state" CK_LOG="$CK/log" CK_STATES="$CK/states" bash "$TH" process "$CK/t.jsonl" sck "$CK/proj"); }
pr
check 'sweep: not again within the day' "$(st F2)" 'waiting'
touch -t 202001010000 "$CK/state/threads/swept"; pr
check 'sweep: the next turn after a day sweeps' "$(st F2)" 'done'

# A replay marks the threads it makes imported; a live turn on one clears it.
reply '{"ops":[{"op":"create","title":"From history","status":"waiting","waits_on":"person"}]}'
TR7="$T/t7.jsonl"; { u 'old work'; a 'done'; } >"$TR7"
bash "$TH" replay "$TR7" s7 "$T/umb"
check 'replay: the thread it made is imported' "$(jq -r '.threads[] | select(.title == "From history") | .imported' "$DIR/threads.json")" 'true'
id7=$(jq -r '.threads[] | select(.title == "From history") | .id' "$DIR/threads.json")
reply "{\"ops\":[{\"op\":\"update\",\"id\":\"$id7\",\"next\":\"carry on\"}]}"
{ u 'back to it'; a 'ok'; } >"$T/t8.jsonl"; bash "$TH" process "$T/t8.jsonl" s8 "$T/umb"
check 'live turn: an imported thread it touches is no longer imported' "$(jq -r --arg id "$id7" '.threads[] | select(.id == $id) | .imported' "$DIR/threads.json")" 'false'
reply '{"ops":[{"op":"create","title":"Live one","status":"active","waits_on":"agent"}]}'
u 'new' >>"$T/t8.jsonl"; a 'ok' >>"$T/t8.jsonl"; bash "$TH" process "$T/t8.jsonl" s8 "$T/umb"
check 'live turn: a thread it makes is not imported' "$(jq -r '.threads[] | select(.title == "Live one") | .imported' "$DIR/threads.json")" 'false'

# The log: one line per distinct message, with a count once it repeats, newest last.
LD="$T/logst"; mkdir -p "$LD/threads"
printf '2026-01-01T00:00:00Z old error\nraw stderr line\n2026-01-02T00:00:00Z old error\n2026-01-03T00:00:00Z (x5 since 2025-12-01T00:00:00Z) hook warning\n' >"$LD/threads/log"
printf 'hook warning\nnew thing\n\nhook warning\n' | HIGHNESS_STATE="$LD" bash "$TH" log-in
check 'log: an old log is folded, one line per message' "$(wc -l <"$LD/threads/log" | tr -d ' ')" '4'
check 'log: a repeat keeps its first time and counts' "$(grep 'old error' "$LD/threads/log")" '2026-01-02T00:00:00Z (x2 since 2026-01-01T00:00:00Z) old error'
check 'log: a line with no time takes the one before it' "$(grep 'raw stderr' "$LD/threads/log")" '2026-01-01T00:00:00Z raw stderr line'
check 'log: a counted line goes on counting, moved last' "$(tail -1 "$LD/threads/log" | sed 's/^[^ ]* //')" '(x7 since 2025-12-01T00:00:00Z) hook warning'
check 'log: a new message, once' "$(grep -c 'new thing' "$LD/threads/log")" '1'
cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 'Plugin hooks not loaded: --safe-mode' >&2
cat "$FAKE_REPLY"
EOF
reply '{"ops":[]}'
for i in 1 2 3; do u "turn $i" >>"$T/t8.jsonl"; a 'ok' >>"$T/t8.jsonl"; bash "$TH" process "$T/t8.jsonl" s8 "$T/umb"; done
check 'log: the model'"'"'s stderr repeated each turn is one line' "$(grep -c 'Plugin hooks not loaded' "$DIR/log")|$(grep -c '(x3 since' "$DIR/log")" '1|1'
check 'log: earlier messages are still there' "$(grep -c 'model said: You.ve hit your usage limit' "$DIR/log")" '1'

# The skill relays first and gives the resume line last: sent, then started, then manual.
SK="$HERE/../skills/where/SKILL.md"
case "$(cat "$SK")" in *'"$TH" relay'*'`sent`'*'`started`'*'`manual`'*) ok 'where: relay, then new terminal, then the resume line' ;; *) no 'where: relay, then new terminal, then the resume line' ;; esac
case "$(cat "$SK")" in *'`busy`'*'do not wait'*) ok 'where: busy is said, not waited out' ;; *) no 'where: busy is said, not waited out' ;; esac

exit $fail
