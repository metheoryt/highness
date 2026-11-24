#!/usr/bin/env bash
# crew.sh watch keeps a ticket's Orca workspace in step with its PR (the PR linked once, the board
# column through hi's wt.sh board), and crew.sh release removes a workspace only once its PR merged.
# Fakes: orca (worktree show/set), wt.sh (board, remove-if-safe), tracker.sh, crew.pr_state.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json"
export LOG="$T/log"; : >"$LOG"
mkdir -p "$T/bin" "$T/root/.claude" "$T/ws"
git -C "$T/root" init -q
ROOT=$(cd "$T/root" && git rev-parse --show-toplevel); WS=$(cd "$T/ws" && pwd -P)

# orca: worktree show answers FAKE_PROJECT / FAKE_LINKED; worktree set is logged; the rest is quiet.
cat >"$T/bin/orca" <<'EOF'
#!/bin/sh
case "$1 $2" in
  'worktree show') printf '{"ok":true,"result":{"worktree":{"projectId":"%s","linkedPR":%s}}}\n' \
                     "${FAKE_PROJECT:-github:acme/app}" "${FAKE_LINKED:-null}" ;;
  'worktree set') printf 'orca %s\n' "$*" >>"$LOG"; echo '{"ok":true}' ;;
  *) echo '{"ok":true,"result":{}}' ;;
esac
EOF
# wt.sh: logged; board prints a row of FAKE_BOARD (moved by default), remove-if-safe FAKE_RM_RC.
cat >"$T/bin/wt.sh" <<'EOF'
#!/bin/sh
printf 'wt %s\n' "$*" >>"$LOG"
case "$3" in
  board) r=${FAKE_BOARD:-moved}; printf '%s\t%s\tname\t%s\n' "$r" "$4" "$5"; [ "$r" = skip ] && exit 1; exit 0 ;;
  remove-if-safe) [ "${FAKE_RM_RC:-0}" = 0 ] || printf 'unsafe\tdirty\tuncommitted changes\n'; exit "${FAKE_RM_RC:-0}" ;;
esac
EOF
cat >"$T/bin/tracker.sh" <<'EOF'
#!/bin/sh
printf '{"role":"%s"}\n' "${FAKE_ROLE:-active}"
EOF
chmod +x "$T/bin/orca" "$T/bin/wt.sh" "$T/bin/tracker.sh"
export ORCA_CLI_COMMAND="$T/bin/orca" HI_WT_SH="$T/bin/wt.sh" HI_TRACKER_SH="$T/bin/tracker.sh"
printf '{"crew":{"pr_state":"cat {{ROOT}}/state.json"}}' >"$T/root/.claude/highness.json"
st() { printf '%s\n' "$1" >"$ROOT/state.json"; }
pass() { : >"$LOG"; bash "$C" watch; }
logged() { grep -c "$1" "$LOG" | tr -d ' '; }

PR=https://github.com/acme/app/pull/12
bash "$C" record K-1 "{\"pr\":\"$PR\",\"workspace\":\"$WS\",\"root\":\"$ROOT\"}"

# --- link and board from the PR
st '{"state":"open","draft":true}'; pass
check 'a draft PR: the workspace In progress' "$(grep '^wt ' "$LOG")" "wt --repo $WS board $WS active"
check 'the PR is linked by its number' "$(grep '^orca ' "$LOG")" "orca worktree set --worktree path:$WS --pr 12 --json"
pass
check 'nothing changed: Orca is not asked again' "$(wc -l <"$LOG" | tr -d ' ')" 0
st '{"state":"open","draft":false}'; pass
check 'ready for review: In review' "$(grep '^wt ' "$LOG")" "wt --repo $WS board $WS in_review"
check 'the link is not sent twice' "$(logged '^orca ')" 0
st '{"state":"merged"}'; pass
check 'merged: Done, in the pass that saw it' "$(grep '^wt ' "$LOG")" "wt --repo $WS board $WS done"
check 'the merge is still an event' "$(bash "$C" events | cut -f5)" 'PR merged'

# --- a move wt.sh could not make is tried again; a hand move it kept is not
rm -f "$T/state/crew/watch/K-1.board"
st '{"state":"open","draft":false}'
FAKE_BOARD=skip pass
FAKE_BOARD=skip pass
check 'a skipped move is tried again next pass' "$(logged ' board ')" 1
FAKE_BOARD=kept pass; pass
check 'a kept (hand-moved) workspace is not asked again' "$(logged ' board ')" 0

# --- closed unmerged moves nothing
st '{"state":"closed"}'; pass
check 'closed unmerged: no board move' "$(logged ' board ')" 0

# --- the tracker role, when the root configures a tracker
printf '{"crew":{"pr_state":"cat {{ROOT}}/state.json"},"tracker":{"kind":"github"}}' >"$T/root/.claude/highness.json"
st '{"state":"open","draft":true}'
FAKE_ROLE=testing pass
check 'tracker testing: QA' "$(grep '^wt ' "$LOG")" "wt --repo $WS board $WS qa"
FAKE_ROLE=done pass
check 'tracker done: Done' "$(grep '^wt ' "$LOG")" "wt --repo $WS board $WS done"
FAKE_ROLE=active pass
check 'no tracker role to go by: from the PR' "$(grep '^wt ' "$LOG")" "wt --repo $WS board $WS active"
printf '{"crew":{"pr_state":"cat {{ROOT}}/state.json"}}' >"$T/root/.claude/highness.json"

# --- link guards: another repo's workspace, already linked, a GitLab MR
rm -f "$T/state/crew/watch/K-1.linked"; FAKE_PROJECT=github:acme/other pass
check 'another repo: no link (a bare number would name another PR)' "$(logged '^orca ')" 0
rm -f "$T/state/crew/watch/K-1.linked"; FAKE_LINKED=12 pass
check 'already linked: not set again' "$(logged '^orca ')" 0
bash "$C" record K-2 "{\"pr\":\"https://gitlab.example/g/app/-/merge_requests/4\",\"workspace\":\"$WS\",\"root\":\"$ROOT\"}"
pass
check 'a GitLab MR: linked by its url' "$(grep '^orca ' "$LOG")" \
  "orca worktree set --worktree path:$WS --gitlab-mr https://gitlab.example/g/app/-/merge_requests/4 --json"
bash "$C" close K-2 2>/dev/null

# --- no workspace: nothing asked of Orca or wt.sh
bash "$C" record K-3 "{\"pr\":\"https://github.com/acme/app/pull/13\",\"root\":\"$ROOT\"}"
pass
check 'no workspace: Orca and wt.sh untouched' "$(wc -l <"$LOG" | tr -d ' ')" 0

# --- release: only a merged PR, through wt.sh remove-if-safe
: >"$LOG"; st '{"state":"open"}'
bash "$C" release K-1 2>"$T/err"; rc=$?
check 'release: an open PR is refused' "$rc" 3
check 'release: refused before wt.sh' "$(logged '^wt ')" 0
case "$(cat "$T/err")" in *'is open, not merged'*) ok 'release: says why' ;; *) no "release message: $(cat "$T/err")" ;; esac
st '{"state":"closed"}'; bash "$C" release K-1 2>/dev/null
check 'release: closed unmerged is refused' "$?" 3
bash "$C" release K-3 2>/dev/null
check 'release: no workspace recorded is an error' "$?" 2
st '{"state":"merged"}'
FAKE_RM_RC=3 bash "$C" release K-1 >"$T/out" 2>/dev/null; rc=$?
check 'release: an unsafe tree stays, exit 3' "$rc" 3
check 'release: the unsafe lines are shown' "$(cut -f1,2 "$T/out")" "$(printf 'unsafe\tdirty')"
: >"$LOG"; bash "$C" release K-1; rc=$?
check 'release: merged, removed through wt.sh' "$(grep '^wt ' "$LOG")" "wt --repo $WS remove-if-safe $WS"
check 'release: exit 0' "$rc" 0
check 'release: recorded on open facts' "$(bash "$C" get K-1 | jq -r '.released_at | test("^[0-9]{4}-")')" true

# --- close drops the new notes; release still works on the closed facts
bash "$C" close K-1 2>/dev/null
check 'close: the link and board notes are gone' "$(ls "$T/state/crew/watch" | grep -c '^K-1\.\(linked\|board\)$')" 0
: >"$LOG"; bash "$C" release K-1
check 'release: works after close' "$(logged 'remove-if-safe')" 1
rmdir "$WS"; bash "$C" release K-1 2>"$T/err"
check 'release: a workspace already gone is exit 0' "$?" 0
case "$(cat "$T/err")" in *'already gone'*) ok 'release: says it is gone' ;; *) no "gone message: $(cat "$T/err")" ;; esac
bash "$C" release NOPE 2>/dev/null
check 'release: no facts is an error' "$?" 2

[ "$fail" -eq 0 ] && echo 'workspace_sync_test: all ok'
exit "$fail"
