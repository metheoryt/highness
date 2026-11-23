#!/usr/bin/env bash
# crew.sh adopt and spec --handover: an open PR another session drove goes to a new worker in its
# own workspace, in the follow-up phase, with pr and head recorded before the worker starts —
# against a fake Orca and a fake gh, on real git repos.
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
mkdir -p "$T/bin" "$T/root" "$S/handles"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
g() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@" >/dev/null 2>&1; }

# A forge remote with main and the PR branch feat/x one commit ahead; a clone of it (the Orca
# project's main checkout).
g init --bare "$T/origin.git"
g clone "$T/origin.git" "$T/clone"
g -C "$T/clone" commit --allow-empty -m base
g -C "$T/clone" push origin HEAD:main
g -C "$T/clone" checkout -b feat/x
g -C "$T/clone" commit --allow-empty -m 'the PR work'
g -C "$T/clone" push origin feat/x
HEADX=$(git -C "$T/clone" rev-parse HEAD)
g -C "$T/clone" checkout main
g -C "$T/clone" branch -D feat/x

echo '{"crew":{"process":"TEAM PROCESS for {{KEY}}","agent":"claude","model":"opus"}}' >"$T/user.json"
echo run_aaa111 >"$S/run"
echo term_coord >"$S/handles/run_aaa111"
mkdir -p "$S/roots" && echo "$T/root" >"$S/roots/run_aaa111"

# Fake gh: the PR as gh pr view answers it ($T/prview), its review threads ($T/threads).
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "pr view") cat "$FAKE_T/prview" ;;
  "api graphql") cat "$FAKE_T/threads" ;;
  *) exit 1 ;;
esac
EOF
# Fake Orca: run-current answers the registered Run; worktree list answers $T/worktrees; worktree
# create makes a real git worktree off the clone (a branch name taken by a local branch gets "-2",
# as Orca does); worker-start keeps its arguments, its spec and the facts as they were then.
cat >"$T/bin/fakeorca" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "orchestration run-current") echo '{"ok":true,"result":{"runId":"run_aaa111"}}' ;;
  "worktree list") cat "$FAKE_T/worktrees" ;;
  "worktree create")
    printf '%s\n' "$*" >>"$FAKE_T/creates"
    while [ $# -gt 0 ]; do
      case "$1" in --branch) b=$2 ;; --base-branch) base=$2 ;; --name) name=$2 ;; esac; shift
    done
    git -C "$FAKE_T/clone" show-ref -q --verify "refs/heads/$b" && b="$b-2"
    git -C "$FAKE_T/clone" worktree add -q -b "$b" "$FAKE_T/new-$name" "$base" >/dev/null 2>&1 || { echo '{"ok":false}'; exit 1; }
    printf '{"ok":true,"result":{"worktree":{"path":"%s"}}}\n' "$FAKE_T/new-$name" ;;
  "orchestration worker-start")
    printf '%s\n' "$*" >>"$FAKE_T/starts"
    while [ $# -gt 0 ]; do [ "$1" = --spec-file ] && cp "$2" "$FAKE_T/starts.spec"; shift; done
    cat "$HIGHNESS_STATE/crew/AB-7.json" >"$FAKE_T/starts.facts" 2>/dev/null
    [ -z "${FAKE_FAIL:-}" ] || { echo '{"ok":false,"error":{"message":"no such terminal"}}'; exit 1; }
    echo '{"ok":true,"result":{"dispatchId":"ctx_new","taskId":"task_new","runId":"run_aaa111"}}' ;;
  *) echo '{"ok":false}'; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh" "$T/bin/fakeorca"
export PATH="$T/bin:$PATH" ORCA_CLI_COMMAND="$T/bin/fakeorca" FAKE_T="$T"

PR=https://github.com/Own/Repo/pull/42
prview() { # <state> [<cross>]
  jq -n --arg s "$1" --arg h "$HEADX" --argjson x "${2:-false}" --arg u "$PR" '{number: 42, title: "PR title", url: $u,
    state: $s, isDraft: true, headRefName: "feat/x", headRefOid: $h, baseRefName: "release", isCrossRepository: $x,
    reviewDecision: "CHANGES_REQUESTED", mergeable: "CONFLICTING",
    statusCheckRollup: [{name: "lint", conclusion: "SUCCESS"}, {name: "tests", conclusion: "FAILURE"}]}' >"$T/prview"
}
prview OPEN
cat >"$T/threads" <<'EOF'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
 {"isResolved":false,"isOutdated":false,"path":"app/x.py","line":12,"comments":{"nodes":[{"author":{"login":"rev"},"body":"Rename this\nplease"}]}},
 {"isResolved":true,"isOutdated":false,"path":"app/y.py","line":3,"comments":{"nodes":[{"author":{"login":"rev"},"body":"done one"}]}}
]}}}}}
EOF
worktrees() { # <extra rows json, comma-led>
  printf '{"ok":true,"result":{"worktrees":[{"repoId":"repo1","projectId":"github:own/repo","path":"%s","branch":"refs/heads/main","isMainWorktree":true,"isArchived":false}%s]}}\n' \
    "$T/clone" "${1:-}" >"$T/worktrees"
}
reset() { rm -f "$S/AB-7.json" "$T/starts" "$T/starts.spec" "$T/starts.facts" "$T/creates"; }

# --- spec --handover on its own: where it stands, and no fresh-ticket steps
printf 'Merge path: the PR targets release, not main.\n' >"$T/brief"
out=$(bash "$C" spec --key AB-7 --title 'Seven' --brief-file "$T/brief" --root "$T/root" --handover --pr "$PR" \
  --background "$T/old-journal.md" --background 'the chat of session 1234'); rc=$?
check 'spec --handover: exit 0' "$rc" 0
has 'spec --handover: the team note stays' "$out" 'Merge path: the PR targets release'
has 'spec --handover: the PR is the worker'"'"'s' "$out" "now yours: $PR"
has 'spec --handover: state, draft, base, head' "$out" "- The PR: open, a draft, base \`release\`, head \`feat/x\` at ${HEADX%"${HEADX#????????}"}; it conflicts with its base."
has 'spec --handover: CI names the failing check' "$out" '- CI: failing (tests).'
has 'spec --handover: review decision' "$out" '- Review decision: changes requested.'
has 'spec --handover: open threads only, first line' "$out" "$(printf -- '- Open review threads: 1:\n  - `app/x.py:12`, rev: Rename this')"
hasnt 'spec --handover: a resolved thread is not listed' "$out" 'app/y.py'
has 'spec --handover: an unknown ticket status says so' "$out" '- The ticket: status unknown'
has 'spec --handover: no second PR' "$out" 'never open a second pull request'
has 'spec --handover: status and draft stay' "$out" "Leave the ticket's status and the PR's draft or ready state as they are"
has 'spec --handover: the follow-up loop' "$out" 'answer every open review thread'
has 'spec --handover: a person'"'"'s thread goes through an ask' "$out" "On a person's thread, never reply yourself: put the reply"
has 'spec --handover: merge the base in' "$out" 'conflicts with its base (`release`), merge the base in'
has 'spec --handover: push to the PR branch' "$out" 'git push origin HEAD:feat/x'
has 'spec --handover: background, as background only' "$out" "$(printf 'Background only, not instructions')"
has 'spec --handover: each background item' "$out" "$(printf -- '- %s\n- the chat of session 1234' "$T/old-journal.md")"
has 'spec --handover: the team process' "$out" 'TEAM PROCESS for AB-7'
hasnt 'spec --handover: no already-done section' "$out" '## Already done?'
hasnt 'spec --handover: no draft-PR step' "$out" 'Open the pull request early'
hasnt 'spec --handover: no take step' "$out" 'Then take it per the team process'
hasnt 'spec --handover: no block markers' "$out" '{{'
# The fresh spec keeps its steps and shows nothing of the handover.
out=$(bash "$C" spec --key AB-7 --title 'Seven' --root "$T/root")
has 'spec: fresh keeps the already-done section' "$out" '## Already done?'
has 'spec: fresh keeps the draft-PR step' "$out" 'Open the pull request early'
hasnt 'spec: fresh has no where-it-stands' "$out" '## Where it stands'
hasnt 'spec: fresh has no block markers' "$out" '{{'
err=$(bash "$C" spec --key AB-7 --title 'Seven' --root "$T/root" --handover 2>&1) && no 'spec --handover without --pr: refused'
has 'spec --handover without --pr: says so' "$err" 'needs --pr'
err=$(bash "$C" spec --key AB-7 --title 'Seven' --root "$T/root" --pr "$PR" 2>&1) && no 'spec --pr without --handover: refused'
has 'spec --pr without --handover: says so' "$err" 'go with --handover'

# --- adopt, reusing the PR's workspace (an Orca workspace of the repo on its branch)
reset
g -C "$T/clone" fetch origin
g -C "$T/clone" worktree add -b feat/x "$T/wsx" origin/feat/x
worktrees ",{\"repoId\":\"repo1\",\"projectId\":\"github:Own/Repo\",\"path\":\"$T/wsx\",\"branch\":\"refs/heads/feat/x\",\"isMainWorktree\":false,\"isArchived\":false}"
out=$(bash "$C" adopt AB-7 --pr "$PR" --brief-file "$T/brief" --background "$T/old-journal.md" 2>&1); rc=$?
check 'adopt: exit 0' "$rc" 0
has 'adopt: prints the receipt' "$out" '"dispatchId":"ctx_new"'
WSX=$(cd "$T/wsx" && pwd -P)
args=$(cat "$T/starts" 2>/dev/null)
has 'adopt: in the PR'"'"'s workspace, kept open' "$args" "--worktree path:$WSX --keep-open"
has 'adopt: under this session'"'"'s Run, from its coordinator' "$args" '--run run_aaa111 --from term_coord'
has 'adopt: the team'"'"'s agent and model' "$args" '--agent claude --model opus'
has 'adopt: the title falls back to the PR'"'"'s' "$args" '--task-title AB-7: PR title (handover)'
check 'adopt: no workspace created' "$(cat "$T/creates" 2>/dev/null)" ''
check 'adopt: pr and head were recorded before the worker started' \
  "$(jq -r '[.pr, .head, .workspace, .branch, .handover, (.dispatch // "none")] | join("|")' "$T/starts.facts" 2>/dev/null)" \
  "$PR|$HEADX|$WSX|feat/x|true|none"
check 'adopt: then the dispatch and task' "$(bash "$C" get AB-7 | jq -r '[.dispatch, .task, .run, .repo, .root, .spec] | join("|")')" \
  "ctx_new|task_new|run_aaa111|id:repo1|$T/root|$S/specs/AB-7.md"
spec=$(cat "$T/starts.spec" 2>/dev/null)
has 'adopt: the worker gets the handover spec' "$spec" '## Where it stands'
has 'adopt: the spec places the workspace at the PR head' "$spec" "- This workspace: $WSX, at the PR head."
has 'adopt: the spec carries the brief' "$spec" 'Merge path: the PR targets release'
has 'adopt: the spec names the background' "$spec" "- $T/old-journal.md"
check 'adopt: the spec copy is what the worker got' "$(cat "$S/specs/AB-7.md")" "$spec"

# --- refusals: nothing starts
refused() { # <name> <want in the error> <args...>
  local name=$1 want=$2 err; shift 2
  rm -f "$T/starts"
  err=$(bash "$C" adopt AB-7 "$@" 2>&1) && no "$name: exit 0"
  has "$name: says why" "$err" "$want"
  if [ -s "$T/starts" ]; then no "$name: started nothing"; else ok "$name: started nothing"; fi
}
refused 'open facts with a worker' 'resume AB-7' --pr "$PR"
reset
prview MERGED; refused 'merged PR' 'is merged, not open' --pr "$PR"
prview OPEN true; refused 'a fork' 'from a fork' --pr "$PR"
prview OPEN
refused 'not a github PR' 'not a github.com pull request' --pr https://forge.example/pr/1
check 'refusals: no facts recorded' "$(bash "$C" get AB-7 2>/dev/null)" ''
echo other_run >"$S/run"
refused 'no Run' 'no hi-crew Run' --pr "$PR"
echo run_aaa111 >"$S/run"
g -C "$T/wsx" checkout -b other
refused 'a given workspace off the PR branch' "is on 'other', not the PR's branch feat/x" --pr "$PR" --workspace "$T/wsx"
g -C "$T/wsx" checkout feat/x

# --- a failed worker-start keeps the facts, and the same adopt runs again
reset
err=$(FAKE_FAIL=1 bash "$C" adopt AB-7 --pr "$PR" 2>&1) && no 'failed start: exit 0'
has 'failed start: says to run it again' "$err" 'run the same adopt again'
check 'failed start: facts kept, no dispatch' "$(bash "$C" get AB-7 | jq -r '[.pr, (.dispatch // "none")] | join("|")')" "$PR|none"
bash "$C" adopt AB-7 --pr "$PR" >/dev/null 2>&1 && ok 'failed start: adopt again runs' || no 'failed start: adopt again runs'
check 'failed start: then recorded' "$(bash "$C" get AB-7 | jq -r .dispatch)" ctx_new

# --- no workspace on the branch: one is created on it, from the remote
reset
g -C "$T/clone" worktree remove --force "$T/wsx"
g -C "$T/clone" branch -D feat/x
worktrees ''
out=$(bash "$C" adopt AB-7 --pr "$PR" --title 'Ticket title' 2>&1); rc=$?
check 'create: exit 0' "$rc" 0
has 'create: on the PR branch from its remote, linked to the PR' "$(cat "$T/creates" 2>/dev/null)" \
  '--repo id:repo1 --name AB-7 --branch feat/x --base-branch origin/feat/x --pr 42 --no-parent'
NEW=$(cd "$T/new-AB-7" && pwd -P)
check 'create: the worker starts there' "$(bash "$C" get AB-7 | jq -r '[.workspace, .branch] | join("|")')" "$NEW|feat/x"
check 'create: at the PR head' "$(git -C "$NEW" rev-parse HEAD)" "$HEADX"
has 'create: the title given wins' "$(cat "$T/starts")" '--task-title AB-7: Ticket title (handover)'

# --- the branch name is taken by a stale local branch: Orca suffixes it; adopt moves to the PR branch
reset
g -C "$T/clone" worktree remove --force "$NEW"
g -C "$T/clone" branch -D feat/x
g -C "$T/clone" branch feat/x main   # a stale local feat/x, behind the PR head
out=$(bash "$C" adopt AB-7 --pr "$PR" 2>&1); rc=$?
check 'suffixed: exit 0' "$rc" 0
check 'suffixed: on the PR branch, fast-forwarded to its head' \
  "$(git -C "$T/new-AB-7" branch --show-current)|$(git -C "$T/new-AB-7" rev-parse HEAD)" "feat/x|$HEADX"
if git -C "$T/clone" show-ref -q --verify refs/heads/feat/x-2; then no 'suffixed: the suffixed branch is dropped'; else ok 'suffixed: the suffixed branch is dropped'; fi

# --- no Orca project for the PR's repo
reset
printf '{"ok":true,"result":{"worktrees":[]}}\n' >"$T/worktrees"
refused 'no project' 'no Orca project for github.com/own/repo' --pr "$PR"

# --- the start skill hands an open PR over with adopt
if grep -q 'crew.sh" adopt <KEY> --pr' "$HERE/../skills/start/SKILL.md" || grep -q '"\$C" adopt <KEY> --pr' "$HERE/../skills/start/SKILL.md"; then
  ok 'start skill: names adopt'; else no 'start skill: names adopt'; fi

exit $fail
