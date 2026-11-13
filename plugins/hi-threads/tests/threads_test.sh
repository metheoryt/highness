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

exit $fail
