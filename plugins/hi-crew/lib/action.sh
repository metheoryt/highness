# action.sh — sourced by crew.sh: a step that needs a person's yes, run once by the coordinator.
#
# Under Claude Code's auto mode a worker is refused an action whose approval only reached it as a
# relayed message: the classifier sees its own session, and the yes was typed in another one. So
# the worker never runs such a step itself. It prepares it as an action — the exact commands,
# pinned to the workspace's HEAD — and asks; the coordinator shows the action verbatim with the
# question, and on yes `crew.sh relay` runs it once in the workspace, in the session where the
# person said yes, records the result and wakes the worker with the outcome, not the instruction.
#
#   crew.sh action <KEY> <script-file>   store the script as a new action of <KEY>, pinned to the
#                                        workspace's HEAD; prints its id. Write-once: the stored
#                                        copy is read-only and its sha256 is checked before a run
#   crew.sh action-show <KEY> [<id>]     with <id>: the action's pins, then the script verbatim
#                                        after a `---` line. Without: one line per action, TSV:
#                                        id, status, prepared_at, head
#
# Store: $DIR/actions/<KEY>/<id>.sh (the script) and <id>.json:
#   {id, key, workspace, head, pr, pr_head, sha256, prepared_at,
#    status: prepared | running | applied | failed | refused, rc, ran_at, reason, tail, delivered}
# A run happens at most once: status leaves `prepared` under a mkdir lock before the script
# starts, so a crash mid-run reads `running` and is never run again. Before the run, in order:
# the stored script still has its sha256; the workspace's HEAD is the pinned head; the PR's head
# (when the ticket has a PR and its state can be read) is the pinned head too; and hi-guard, when
# installed beside this plugin, does not deny the script as a Bash command. A check that fails
# refuses the action: nothing runs, and the worker hears why.

act_dir() { printf '%s/actions/%s\n' "$DIR" "$1"; }

act_sha() { # <file>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

act_meta() { # <KEY> <id>
  case "$2" in ''|*[!A-Za-z0-9-]*) die "bad action id: '$2'" ;; esac
  printf '%s/%s.json\n' "$(act_dir "$1")" "$2"
}

act_set() { # <meta file> <json to merge>; it can carry a run's output: through a pipe, not argv
  local tmp="$1.tmp.$$"
  jq --slurpfile add <(printf '%s' "$2") '. + $add[0]' "$1" >"$tmp" && mv "$tmp" "$1" || { rm -f "$tmp"; return 1; }
}

cmd_action() {
  [ $# -eq 2 ] || die 'usage: action <KEY> <script-file>'
  need_jq
  local key=$1 src=$2 facts ws head pr id d
  keyfile "$key" >/dev/null || exit 2
  [ -s "$src" ] || die "action: no script, or an empty one: $src"
  facts=$(cmd_get "$key") || die "action: no open facts for $key"
  ws=$(printf '%s' "$facts" | jq -r "$WS_PATH")
  [ -z "$ws" ] && ws=$(git rev-parse --show-toplevel 2>/dev/null)
  [ -n "$ws" ] && [ -d "$ws" ] || die "action: $key has no workspace recorded"
  head=$(git -C "$ws" rev-parse HEAD 2>/dev/null) || die "action: cannot read HEAD in $ws"
  pr=$(printf '%s' "$facts" | jq -r '.pr // empty')
  d=$(act_dir "$key"); mkdir -p "$d" || die "action: cannot write $d"
  id="a$(date -u +%Y%m%d%H%M%S)-$$"
  [ ! -e "$d/$id.sh" ] || die "action: $id exists"
  cp "$src" "$d/$id.sh" && chmod a-w "$d/$id.sh" || die "action: cannot store the script"
  jq -n --arg id "$id" --arg key "$key" --arg ws "$ws" --arg head "$head" --arg pr "$pr" \
    --arg sha "$(act_sha "$d/$id.sh")" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id: $id, key: $key, workspace: $ws, head: $head, pr: $pr, sha256: $sha, prepared_at: $now, status: "prepared"}' \
    >"$d/$id.json" || die "action: cannot write $d/$id.json"
  printf '%s\n' "$id"
}

cmd_action_show() {
  [ $# -ge 1 ] && [ $# -le 2 ] || die 'usage: action-show <KEY> [<id>]'
  need_jq
  local m f
  keyfile "$1" >/dev/null || exit 2
  if [ $# -eq 1 ]; then
    for f in "$(act_dir "$1")"/*.json; do
      [ -f "$f" ] && jq -r '[.id, .status, .prepared_at, .head] | @tsv' "$f"
    done
    return 0
  fi
  m=$(act_meta "$1" "$2"); [ -f "$m" ] || die "action-show: $1 has no action $2"
  jq -r '"action \(.id) of \(.key): \(.status)", "workspace \(.workspace)", "pinned to HEAD \(.head)",
         (if .pr != "" then "PR \(.pr) (its head must be the same)" else empty end),
         "sha256 \(.sha256)", "prepared \(.prepared_at)"' "$m"
  echo '---'
  cat "${m%.json}.sh"
}

# The hi-guard hook script installed beside this plugin: the repo or marketplace layout
# (plugins/hi-guard), else the plugin cache (<marketplace>/hi-guard/<version>). None: empty.
act_guard_path() {
  local g
  for g in "$HERE/../../hi-guard/lib/guard.sh" "$HERE"/../../../hi-guard/*/lib/guard.sh; do
    [ -f "$g" ] && { printf '%s\n' "$g"; return 0; }
  done
  return 1
}

# A run inside crew.sh is a subprocess: no PreToolUse hook sees its commands. So the script is
# put to hi-guard as the Bash command it would have been. A deny refuses the action; an ask does
# not, since the person said yes to this exact text. HI_GUARD_PROBE=1 keeps the probe out of
# hi-guard's denial log: no agent met this decision, and a deny is recorded on the action.
act_guard() { # <script> <workspace>; prints the reason and exit 1 on a deny
  local g out
  g=${HI_GUARD:-$(act_guard_path)} || return 0
  [ -n "$g" ] && [ -f "$g" ] || return 0
  out=$(jq -n --rawfile c "$1" --arg cwd "$2" '{tool_name: "Bash", tool_input: {command: ($c | sub("\n+$"; ""))}, cwd: $cwd}' \
    | (cd "$2" && HI_GUARD_PROBE=1 bash "$g" pretool) 2>/dev/null) || return 0
  printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 || return 0
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // "hi-guard denied it"'
  return 1
}

# Run one action once; print the outcome as the worker should hear it. Exit 0 once the action is
# settled (applied, failed or refused); exit 2, with nothing run and nothing changed, when it
# cannot be (no such action, already run, another run holds it).
act_run() { # <KEY> <id>
  local key=$1 id=$2 m s ws head now pr facts st reason='' out rc tail
  m=$(act_meta "$key" "$id"); s=${m%.json}.sh
  [ -f "$m" ] && [ -f "$s" ] || { printf 'crew: relay: %s has no action %s\n' "$key" "$id" >&2; return 2; }
  mkdir "$m.lock" 2>/dev/null || { printf 'crew: relay: action %s is being run already\n' "$id" >&2; return 2; }
  st=$(jq -r .status "$m")
  if [ "$st" != prepared ]; then
    rmdir "$m.lock"
    printf 'crew: relay: action %s was run already (%s); an action runs once: the worker prepares a new one\n' "$id" "$st" >&2
    return 2
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  act_set "$m" "$(jq -nc --arg now "$now" '{status: "running", ran_at: $now}')" || { rmdir "$m.lock"; return 2; }
  rmdir "$m.lock"
  ws=$(jq -r .workspace "$m"); head=$(jq -r .head "$m"); pr=$(jq -r '.pr // ""' "$m")
  if [ "$(act_sha "$s")" != "$(jq -r .sha256 "$m")" ]; then
    reason='the stored script changed after it was prepared'
  elif [ ! -d "$ws" ]; then
    reason="the workspace $ws is gone"
  elif [ "$(git -C "$ws" rev-parse HEAD 2>/dev/null)" != "$head" ]; then
    reason="the workspace moved from the pinned head ${head:0:12} to $(git -C "$ws" rev-parse --short=12 HEAD 2>/dev/null)"
  elif [ -n "$pr" ] && facts=$(cmd_get "$key" 2>/dev/null) && out=$(pr_state "$facts") \
       && out=$(printf '%s' "$out" | jq -r '.head // empty' 2>/dev/null) && [ -n "$out" ] && [ "$out" != "$head" ]; then
    reason="the PR head is ${out:0:12}, not the pinned head ${head:0:12} (push first, then prepare it again)"
  else
    reason=$(act_guard "$s" "$ws") && reason=''
  fi
  if [ -n "$reason" ]; then
    act_set "$m" "$(jq -nc --arg r "$reason" '{status: "refused", reason: $r}')"
    printf 'hi-crew did NOT run action %s: %s. Nothing ran. If the step is still needed, prepare it again (crew.sh action) and ask again.\n' "$id" "$reason"
    return 0
  fi
  out="$m.out"
  (cd "$ws" && bash -e "$s" </dev/null >"$out" 2>&1); rc=$?
  tail=$(tail -n 20 "$out" 2>/dev/null)
  act_set "$m" "$(jq -nc --argjson rc "$rc" --rawfile t <(printf '%s' "$tail") --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{status: (if $rc == 0 then "applied" else "failed" end), rc: $rc, ran_at: $now, tail: $t}')"
  if [ "$rc" -eq 0 ]; then
    printf 'hi-crew ran action %s once, in this workspace, on the person'"'"'s yes: it succeeded (exit 0). Do not run it again.\n' "$id"
  else
    printf 'hi-crew ran action %s once, in this workspace, on the person'"'"'s yes: it FAILED (exit %s). It is not retried; do not run it yourself. Ask again with a new action if the step is still needed.\n' "$id" "$rc"
  fi
  [ -z "$tail" ] || printf 'Its output, last lines:\n%s\n' "$tail"
  return 0
}

# Kept replies (relay could not deliver them: the worker is gone), one JSON object per line in
# $DIR/unsent/<KEY>.jsonl: {key, at, ask, dispatch, body, error, action?}. `stranded` shows them.
keep_unsent() { # <KEY> <json>
  mkdir -p "$DIR/unsent" && printf '%s\n' "$2" >>"$DIR/unsent/$1.jsonl"
}

# stranded: the answers no worker will act on, across the open tickets, one JSON object per line:
#   {key, what, ask, dispatch, since, question, workspace, session, body?, action?}
# what is
#   unanswered  asked, and the worker is gone (its Dispatch is not live): `asks` no longer shows it
#   unheard     answered, the worker is gone, and nothing came from its Dispatch after the answer
#   unsent      relay kept the reply: Orca refused it (the worker was gone); body is what to send
#               (with an action, its outcome: the action ran, or was refused, already)
# session is the believed live session in the ticket's workspace (session-state.sh), or "": a
# person may have resumed the work there by hand, and the answer belongs in that session.
# Each line belongs to the ticket's recorded dispatch: recording the dispatch of a new round (the
# answer sent on) is what retires it.
cmd_stranded() {
  need_jq
  local m t key d ws sess f kept
  m=$(inbox) || exit $?
  cmd_list | while IFS= read -r t; do
    key=$(printf '%s' "$t" | jq -r .key); d=$(printf '%s' "$t" | jq -r '.dispatch // empty')
    ws=$(printf '%s' "$t" | jq -r "$WS_PATH")
    sess=''; if [ -n "$ws" ] && [ -d "$ws" ]; then sess=$(bash "$SESSION_STATE" get "$ws" 2>/dev/null | cut -f3); fi
    f="$DIR/unsent/$key.jsonl"; kept='[]'
    if [ -f "$f" ]; then
      kept=$(jq -sc --arg d "$d" 'map(select($d == "" or .dispatch == $d))' "$f") || kept='[]'
      printf '%s' "$kept" | jq -c --arg ws "$ws" --arg s "$sess" '.[]
        | {key, what: "unsent", ask, dispatch, since: .at, question: (.question // ""), workspace: $ws, session: $s, body}
          + (if .action then {action} else {} end)'
    fi
    [ -n "$d" ] || continue
    dispatch_live "$d" && continue
    # Only the kept replies' ids, through a pipe: their bodies can be any size.
    printf '%s' "$m" | jq -c --arg d "$d" --arg key "$key" --arg ws "$ws" --arg s "$sess" \
        --slurpfile k <(printf '%s' "$kept" | jq -c 'map(.ask)') "$JQ_ANSWER"'
      . as $m
      | $k[0] as $k
      | $m[] | select((.type == "question" or .type == "decision_gate") and .dispatch == $d)
      | select(.id as $id | $k | index($id) | not)
      | . as $q
      | ([ $m[] | select(answers($q)) | .created_at ] | min) as $ans
      | if $ans == null then {what: "unanswered", since: $q.created_at}
        # The "lost without reporting" notice Orca sends is not a word from the worker.
        elif ([ $m[] | select(.dispatch == $d and .created_at > $ans and .thread_id != $q.id)
                | select(((.payload // "{}" | fromjson? // {}) .stopReason // "") != "lost") ] | length) == 0
          then {what: "unheard", since: $ans}
        else empty end
      | {key: $key} + . + {ask: $q.id, dispatch: $d, question: (($q.body // $q.subject // "") | split("\n")[0]),
                          workspace: $ws, session: $s}'
  done
  return 0
}
