#!/usr/bin/env bash
# crew.sh dispatch and spec --task-file: a worker for a task that is not a ticket (hi-review's deep
# review) on hi-crew's machinery — its own spec mode, facts with a kind and no PR, the watch
# leaving its PR alone, the compaction re-entry naming the task — against a fake Orca and gh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json"
unset ORCA_TERMINAL_HANDLE
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1: [$3] is there" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }
command -v git >/dev/null || { echo '  skip: no git'; exit 0; }
S="$T/state/crew"
mkdir -p "$T/bin" "$T/root" "$T/ws" "$S/handles" "$S/roots"
git -C "$T/ws" init -q 2>/dev/null
echo '{"crew":{"process":"TEAM PROCESS for {{KEY}}","agent":"claude","model":"opus"}}' >"$T/user.json"
echo run_aaa111 >"$S/run"
echo term_coord >"$S/handles/run_aaa111"
echo "$T/root" >"$S/roots/run_aaa111"

# Fake gh: every call is logged; the watch must make none for a task worker.
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_T/gh.log"
exit 1
EOF
cat >"$T/bin/fakeorca" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "orchestration run-current") echo '{"ok":true,"result":{"runId":"run_aaa111"}}' ;;
  "orchestration worker-start")
    printf '%s\n' "$*" >>"$FAKE_T/starts"
    while [ $# -gt 0 ]; do [ "$1" = --spec-file ] && cp "$2" "$FAKE_T/starts.spec"; shift; done
    cat "$HIGHNESS_STATE/crew/review-o-r-7.json" >"$FAKE_T/starts.facts" 2>/dev/null
    [ -z "${FAKE_FAIL:-}" ] || { echo '{"ok":false,"error":{"message":"no such terminal"}}'; exit 1; }
    echo '{"ok":true,"result":{"dispatchId":"ctx_rv","taskId":"task_rv","runId":"run_aaa111"}}' ;;
  *) echo '{"ok":false}'; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh" "$T/bin/fakeorca"
export PATH="$T/bin:$PATH" ORCA_CLI_COMMAND="$T/bin/fakeorca" FAKE_T="$T"

printf 'Review PR 7.\n\nREVIEW TASK BODY with {{KEY}} kept as written.\n' >"$T/task.md"
echo 'how to handle a review worker' >"$T/guide.md"

# --- spec --task-file: the task, the asking rules, no ticket steps, no team process.
spec=$(cd "$T/root" && bash "$C" spec --key review-o-r-7 --title 'review #7' --task-file "$T/task.md" 2>&1); rc=$?
check 'task spec builds with no team file at the root' "$rc" 0
has 'task spec: the task heading' "$spec" 'Task review-o-r-7: review #7'
has 'task spec: the task text verbatim' "$spec" 'REVIEW TASK BODY with {{KEY}} kept as written.'
has 'task spec: the asking rules' "$spec" '## Asking'
has 'task spec: actions for a person-only step' "$spec" "action review-o-r-7 <file>"
has 'task spec: finish points at the task' "$spec" 'as the task above says'
hasnt 'task spec: no ticket heading' "$spec" 'Ticket review-o-r-7'
hasnt 'task spec: no team process' "$spec" 'TEAM PROCESS'
hasnt 'task spec: no draft PR step' "$spec" 'Open the pull request early'
hasnt 'task spec: no already-done step' "$spec" 'Already done?'
hasnt 'task spec: no merge line' "$spec" 'Never merge'
hasnt 'task spec: no block markers left' "$spec" '{{#'
out=$(bash "$C" spec --key K --title T --task-file "$T/task.md" --brief-file "$T/task.md" 2>&1); rc=$?
check 'task file and brief file together refused' "$rc" 2
# The ticket spec still has its ticket steps and process.
tspec=$(cd "$T/root" && bash "$C" spec --key AB-1 --title t 2>&1)
has 'ticket spec keeps its heading' "$tspec" 'Ticket AB-1: t'
has 'ticket spec keeps the team process' "$tspec" 'TEAM PROCESS for AB-1'
hasnt 'ticket spec has no task block' "$tspec" 'one task, this workspace'

# --- dispatch refusals.
out=$(bash "$C" dispatch review-o-r-7 --kind ticket --title t --workspace "$T/ws" --task-file "$T/task.md" 2>&1); rc=$?
check 'kind ticket refused' "$rc" 2
out=$(bash "$C" dispatch review-o-r-7 --kind review --title t --workspace "$T/ws" --task-file "$T/task.md" --facts '{"pr":"x"}' 2>&1); rc=$?
check 'a pr in the facts refused' "$rc" 2
out=$(bash "$C" dispatch review-o-r-7 --kind review --title t --workspace "$T/nope" --task-file "$T/task.md" 2>&1); rc=$?
check 'a missing workspace refused' "$rc" 2
[ ! -f "$T/starts" ] && ok 'refusals start nothing' || no 'a refusal started a worker'

# --- dispatch: facts before the start, the start kept open in the workspace, dispatch recorded.
out=$(cd "$T/root" && bash "$C" dispatch review-o-r-7 --kind review --title 'review #7' --workspace "$T/ws" \
  --task-file "$T/task.md" --guide "$T/guide.md" \
  --facts '{"review_pr":"https://github.com/o/r/pull/7","head":"abc"}' 2>&1); rc=$?
check 'dispatch exits 0' "$rc" 0
has 'dispatch prints the receipt' "$out" '"dispatchId":"ctx_rv"'
st=$(cat "$T/starts")
has 'worker-start in the workspace' "$st" "--worktree path:$(cd "$T/ws" && pwd -P)"
has 'kept open: the person can take it over' "$st" '--keep-open'
has 'under this session Run' "$st" '--run run_aaa111'
has 'from the coordinator terminal' "$st" '--from term_coord'
has 'the agent from config' "$st" '--agent claude'
has 'the task title' "$st" '--task-title review-o-r-7: review #7'
check 'facts recorded before the start: kind' "$(jq -r .kind "$T/starts.facts")" review
check 'facts: the guide' "$(jq -r .guide "$T/starts.facts")" "$(cd "$T" && pwd -P)/guide.md"
check 'facts: the extra fields' "$(jq -r .review_pr "$T/starts.facts")" https://github.com/o/r/pull/7
check 'facts: no pr' "$(jq -r '.pr // "none"' "$T/starts.facts")" none
has 'the spec started is the task spec' "$(cat "$T/starts.spec")" 'REVIEW TASK BODY'
f=$(bash "$C" get review-o-r-7)
check 'dispatch recorded' "$(printf '%s' "$f" | jq -r .dispatch)" ctx_rv
check 'spec copy recorded' "$(printf '%s' "$f" | jq -r .spec)" "$S/specs/review-o-r-7.md"
has 'spec copy kept' "$(cat "$S/specs/review-o-r-7.md")" 'REVIEW TASK BODY'
out=$(bash "$C" dispatch review-o-r-7 --kind review --title t --workspace "$T/ws" --task-file "$T/task.md" 2>&1); rc=$?
check 'a second dispatch refused' "$rc" 2
has 'refusal names resume' "$out" 'crew.sh resume review-o-r-7'

# --- the watch leaves a task worker's PR alone: no gh call for it.
rm -f "$T/gh.log"
HI_WT_SH="$T/none" bash "$C" watch >/dev/null 2>&1
[ ! -s "$T/gh.log" ] && ok 'the watch makes no forge call for a task worker' || no "the watch called gh: $(cat "$T/gh.log")"
check 'the watch recorded no pr' "$(bash "$C" get review-o-r-7 | jq -r '.pr // "none"')" none

# --- the compaction re-entry names the task, not a ticket.
re=$(printf '{"cwd":"%s"}' "$T/ws" | bash "$C" reentry)
has 'reentry: the review worker' "$re" 'the review worker for review-o-r-7'
hasnt 'reentry: no team process' "$re" 'team process'

# --- a failed start keeps the facts, and the same dispatch runs again.
mkdir -p "$T/ws2"
out=$(cd "$T/root" && FAKE_FAIL=1 bash "$C" dispatch review-o-r-8 --kind review --title t --workspace "$T/ws2" --task-file "$T/task.md" 2>&1); rc=$?
check 'a failed worker-start exits 2' "$rc" 2
has 'failure says to run dispatch again' "$out" 'run the same dispatch again'
out=$(cd "$T/root" && bash "$C" dispatch review-o-r-8 --kind review --title t --workspace "$T/ws2" --task-file "$T/task.md" 2>&1); rc=$?
check 'the same dispatch again takes over its facts' "$rc" 0

exit $fail
