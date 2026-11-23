#!/usr/bin/env bash
# crew.sh branch and workspace: the worker's branch from the team's crew.branch template, and
# autostart creating the workspace on that branch before it starts the worker — against a fake Orca.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json" HI_ACCOUNT="$T/acct" HI_ORCA_PROFILES="$T/profiles"
export HI_BUDGET_REFRESH=0 HI_BUDGET_RESPONSE="$T/live.json"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }
lacks() { case "$2" in *"$3"*) no "$1: [$3] in [$2]" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

# The team's file at the coordinator root; the person's own file holds crew.owner.
mkdir -p "$T/root/.claude" "$T/acct" "$T/ws"; git -C "$T/root" init -q
team() { jq -n --arg b "$1" '{crew: {branch: $b}}' >"$T/root/.claude/highness.json"; }
b() { bash "$C" branch --root "$T/root" "$@" 2>"$T/err"; }

# --- unset: today's behaviour
echo '{}' >"$T/root/.claude/highness.json"; echo '{}' >"$HIGHNESS_CONFIG"
out=$(b --key AB-1 --title 'Fix it'); rc=$?
check 'unset: exit 1, nothing printed' "$rc [$out]" '1 []'

# --- placeholders
team '{{TYPE}}/{{KEY}}-{{SLUG}}'
check 'KEY, SLUG from the title, TYPE defaults to feat' "$(b --key AB-1 --title 'Fix the Login: page!')" 'feat/AB-1-fix-the-login-page'
check 'TYPE given' "$(b --key AB-1 --title 'Fix it' --type fix)" 'fix/AB-1-fix-it'
check 'SLUG given wins over the title' "$(b --key AB-1 --title 'Fix it' --slug 'Short Name')" 'feat/AB-1-short-name'
check 'slug: at most 5 words' "$(b --key AB-1 --title 'one two three four five six seven')" 'feat/AB-1-one-two-three-four-five'
check 'slug: at most 40 characters, no trailing dash' \
  "$(b --key AB-1 --title 'abcdefghijklmnopqrstuvwxyz abcdefghijklmnopqrstuvwxyz')" 'feat/AB-1-abcdefghijklmnopqrstuvwxyz-abcdefghijklm'
check 'slug: no ASCII words gives work' "$(b --key AB-1 --title 'Починить вход')" 'feat/AB-1-work'
team '{{TYPE}}/{{OWNER}}/{{KEY}}-{{SLUG}}'
out=$(b --key AB-1 --title 'Fix it'); rc=$?
check 'OWNER with no crew.owner: exit 2' "$rc [$out]" '2 []'
has 'OWNER with no crew.owner: says what to set' "$(cat "$T/err")" 'set crew.owner'
echo '{"crew":{"owner":"sam"}}' >"$HIGHNESS_CONFIG"
check 'OWNER from the person'"'"'s file' "$(b --key AB-1 --title 'Fix it' --type chore)" 'chore/sam/AB-1-fix-it'
team '{{KEY}}-{{TICKET}}'
out=$(b --key AB-1 --title 'Fix it'); rc=$?
check 'an unknown placeholder: exit 2' "$rc [$out]" '2 []'
team '{{KEY}}..{{SLUG}}'
out=$(b --key AB-1 --title 'Fix it'); rc=$?
check 'a name git refuses: exit 2' "$rc [$out]" '2 []'
out=$(b --key 'a b' --title 'Fix it'); rc=$?
check 'a bad key: exit 2' "$rc" 2

# --- autostart: with crew.branch set, the workspace is created on the branch, then the worker
# starts in it. Fake Orca: worktree create checks out the branch in a new repo (with a -2 suffix
# when FAKE_TAKEN is set, as Orca does for a taken name); worker-start answers a receipt.
mkdir -p "$T/bin"
cat >"$T/bin/fakeorca" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "worktree create")
    printf '%s\n' "$*" >>"$FAKE_LOG.create"
    [ -z "${FAKE_CREATE_FAIL:-}" ] || { echo '{"ok":false,"error":{"message":"branch exists"}}'; exit 1; }
    br=''; prev=''
    for a in "$@"; do [ "$prev" = --branch ] && br=$a; prev=$a; done
    [ -z "${FAKE_TAKEN:-}" ] || br="$br-2"
    d="$FAKE_WS/c$(wc -l <"$FAKE_LOG.create" | tr -d ' ')"
    git init -q "$d" && git -C "$d" symbolic-ref HEAD "refs/heads/$br"
    # FAKE_SETUP=<seconds>: Orca writes a runner and starts it, as its Setup terminal does.
    [ -z "${FAKE_YAML:-}" ] || printf 'setupAgentStartupPolicy: "wait-for-setup"\n' >"$d/orca.yaml"
    if [ -n "${FAKE_SETUP:-}" ]; then
      mkdir -p "$d/.git/orca"; printf '#!/bin/sh\nsleep %s\n' "$FAKE_SETUP" >"$d/.git/orca/setup-runner.sh"
      echo "$d/.git/orca/setup-runner.sh" >"$FAKE_WS/typed"
      [ "$FAKE_SETUP" = 0 ] || (nohup bash "$d/.git/orca/setup-runner.sh" >/dev/null 2>&1 &)
    fi
    printf '{"ok":true,"result":{"worktree":{"path":"%s","branch":"refs/heads/%s"}}}\n' "$d" "$br" ;;
  "repo show")
    printf '{"ok":true,"result":{"repo":{"hookSettings":{"setupAgentStartupPolicy":"%s"}}}}\n' "${FAKE_POLICY:-start-immediately}" ;;
  "terminal list") echo '{"ok":true,"result":{"terminals":[{"handle":"term_setup"}]}}' ;;
  "terminal read")
    jq -n --arg l "$(cat "$FAKE_WS/typed" 2>/dev/null)" '{ok: true, result: {terminal: {tail: ["$ bash \($l)", ""]}}}' ;;
  "orchestration worker-start")
    printf '%s\n' "$*" >>"$FAKE_LOG"
    [ -z "${FAKE_FAIL:-}" ] || { echo '{"ok":false,"error":{"message":"no such terminal"}}'; exit 1; }
    printf '{"ok":true,"result":{"dispatchId":"ctx_1","taskId":"task_1","runId":"run_aaa111","workspace":"repo1::/elsewhere"}}\n' ;;
  "orchestration send") : ;;
  "account list") echo '{"ok":true,"result":{"activeAccountId":null,"accounts":[]}}' ;;
  *) echo '{"ok":false}'; exit 1 ;;
esac
EOF
chmod +x "$T/bin/fakeorca"
export ORCA_CLI_COMMAND="$T/bin/fakeorca" FAKE_LOG="$T/starts" FAKE_WS="$T/ws"
jq -n --argjson now "$(date +%s)" 'def iso: todate | sub("Z$"; ".214621+00:00");
  {five_hour: {utilization: 20, resets_at: ($now + 14400 | iso)}, seven_day: {utilization: 20, resets_at: ($now + 518400 | iso)}}' >"$T/live.json"
echo '{"key":"AB-7","title":"Fix the login","url":"https://t/AB-7","created":"2026-01-01","type":"fix"}' >"$T/cands"
S="$T/state/crew"
reset() { rm -rf "$S" "$T/starts" "$T/starts.create"; mkdir -p "$S/handles"; echo term_1 >"$S/handles/run_aaa111"; }
jq -n --arg root "$T/root" --arg cmd "cat $T/cands" \
  '{crew: {owner: "sam", autostart: {enabled: true, root: $root, candidates: $cmd, max_active: 2}}}' >"$HIGHNESS_CONFIG"

team '{{TYPE}}/{{OWNER}}/{{KEY}}-{{SLUG}}'
reset
has 'dry run: names the branch' "$(bash "$C" autostart --dry-run)" 'as fix/sam/AB-7-fix-the-login'
out=$(bash "$C" autostart)
create=$(cat "$T/starts.create" 2>/dev/null); start=$(cat "$T/starts" 2>/dev/null)
has 'create: on the rendered branch, a top-level workspace from the base' "$create" \
  "--repo path:$T/root --name AB-7 --branch fix/sam/AB-7-fix-the-login --base-branch origin/main --no-parent"
has 'start: in the created workspace, kept open' "$start" "--worktree path:$T/ws/c1 --keep-open"
lacks 'start: no creation flags' "$start" '--base-branch'
check 'facts: the created workspace and its branch' "$(bash "$C" get AB-7 | jq -r '.workspace + " " + .branch')" "$T/ws/c1 fix/sam/AB-7-fix-the-login"
has 'one log line per start' "$out" "started	AB-7	$T/ws/c1"

reset
FAKE_TAKEN=1 bash "$C" autostart >/dev/null
check 'a taken name: the facts hold the branch Orca gave' "$(bash "$C" get AB-7 | jq -r .branch)" 'fix/sam/AB-7-fix-the-login-2'

reset
out=$(FAKE_CREATE_FAIL=1 bash "$C" autostart)
has 'failed create: logged with the reason' "$out" 'failed	AB-7	workspace: orca worktree create failed: branch exists'
check 'failed create: no worker started, no facts' "$([ -f "$T/starts" ] && echo started || echo none) $(bash "$C" get AB-7 >/dev/null 2>&1 && echo facts || echo none)" 'none none'

reset
team '{{KEY}}-{{NOPE}}'
out=$(bash "$C" autostart)
has 'a broken template: logged, nothing created' "$out" 'failed	AB-7	branch: crew.branch'
check 'a broken template: no workspace' "$([ -f "$T/starts.create" ] && echo created || echo none)" none

reset
echo '{}' >"$T/root/.claude/highness.json"
bash "$C" autostart >/dev/null
check 'unset: no worktree create' "$([ -f "$T/starts.create" ] && echo created || echo none)" none
has 'unset: worker-start creates the workspace, as before' "$(cat "$T/starts")" "--worktree new-top-level --repo path:$T/root --name AB-7 --base-branch origin/main"

# --- workspace in a wait-for-setup repo: Orca reports nothing for a plain create, so workspace
# waits for the runner it wrote to stop running. Real runner processes, a fake Orca around them.
export HI_CREW_SETUP_POLL=0.2
ws() { rm -rf "$T/ws"/c* "$T/ws/typed" "$T/starts.create"; bash "$C" workspace --repo path:"$T/root" --name AB-8 --branch feat/AB-8 --base origin/main "$@" 2>"$T/err"; }
runner="$T/ws/c1/.git/orca/setup-runner.sh"
running() { ps -A -o args= | grep -F "$runner" | grep -Fvq 'grep -F' && echo running || echo done; }

out=$(FAKE_POLICY=wait-for-setup FAKE_SETUP=2 ws); rc=$?
check 'wait-for-setup: returns the path once the setup is done' "$rc $out $(running)" "0 $T/ws/c1 done"

out=$(FAKE_POLICY=start-immediately FAKE_SETUP=2 ws); rc=$?
check 'start-immediately: does not wait' "$rc $out $(running)" "0 $T/ws/c1 running"
sleep 2

out=$(FAKE_POLICY=wait-for-setup FAKE_SETUP=0 ws); rc=$?
check 'setup done before the first look (typed, no process): returns' "$rc $out" "0 $T/ws/c1"

out=$(FAKE_POLICY=wait-for-setup ws); rc=$?
check 'no runner written (setup off): returns' "$rc $out" "0 $T/ws/c1"

out=$(FAKE_POLICY=wait-for-setup FAKE_SETUP=5 ws --setup-timeout 1); rc=$?
check 'still running past the timeout: the path, exit 3' "$rc $out" "3 $T/ws/c1"
has 'still running: stderr carries the spec note with the runner' "$(cat "$T/err")" "grep -F '$runner'"
sleep 4

out=$(FAKE_POLICY=wait-for-setup FAKE_SETUP=5 ws --setup-timeout 0); rc=$?
check '--setup-timeout 0: does not wait' "$rc $out $(running)" "0 $T/ws/c1 running"
sleep 5

out=$(FAKE_POLICY=wait-for-setup ws --setup-timeout soon); rc=$?
check 'a bad --setup-timeout: exit 2' "$rc" 2

# orca.yaml alone can set the policy: Orca waits when either says so.
out=$(FAKE_POLICY=start-immediately FAKE_YAML=1 FAKE_SETUP=2 ws); rc=$?
check "orca.yaml's wait-for-setup alone: waits" "$rc $out $(running)" "0 $T/ws/c1 done"

# --- autostart in a wait-for-setup repo whose setup outlasts its wait: the worker starts, and its
# spec tells it to wait for the setup.
team '{{TYPE}}/{{OWNER}}/{{KEY}}-{{SLUG}}'
reset; rm -rf "$T/ws"/c* "$T/ws/typed"
FAKE_POLICY=wait-for-setup FAKE_SETUP=4 HI_CREW_AUTOSTART_SETUP_TIMEOUT=1 bash "$C" autostart >"$T/out"
has 'autostart, setup outlasts the wait: the worker still starts' "$(cat "$T/starts")" "--worktree path:$T/ws/c1 --keep-open"
has 'autostart, setup outlasts the wait: the spec says to wait for it' "$(cat "$S/specs/AB-7.md" 2>/dev/null)" 'Workspace setup still running'
sleep 4

reset; rm -rf "$T/ws"/c* "$T/ws/typed"
FAKE_POLICY=wait-for-setup FAKE_SETUP=1 bash "$C" autostart >"$T/out"
lacks 'autostart, setup done in time: no wait note in the spec' "$(cat "$S/specs/AB-7.md" 2>/dev/null)" 'Workspace setup still running'
has 'autostart, setup done in time: started' "$(cat "$T/out")" "started	AB-7	$T/ws/c1"

exit $fail
