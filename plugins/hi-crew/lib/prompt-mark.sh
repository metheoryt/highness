#!/usr/bin/env bash
# prompt-mark.sh — which sessions sit on an open permission dialog.
#
# A worker that hits a permission prompt waits for someone to answer it, and nothing else tells
# the person: Orca shows the worker as busy and the worker sends no question. The Notification
# hook (matcher permission_prompt|elicitation_dialog) writes one marker per session in
# ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/prompts/<session_id>.json: since
# (UTC), the session's cwd, the transcript, the pending tool call and the kind: `permission`, or
# `input` for an MCP server's input dialog (elicitation), which also holds a tool call open.
# elicitation_dialog is a notification type the Claude Code 2.1.319 CLI carries; its payload is
# not measured. Without a transcript the marker is never believed, so a payload unlike
# permission_prompt's stays silent (herdr's screen manifest has the same dialog, highness#24).
#
# Measured on Claude Code 2.1.316 in default mode: the payload carries session_id,
# transcript_path, cwd, message and notification_type ("permission_prompt"), and no tool name;
# the tool_use is already in the transcript when it fires. Approving the dialog fires PostToolUse
# and Stop, but Esc (deny) fires neither: the transcript gets the tool_result and turn_duration
# only. So a marker is believed only while the transcript agrees: its tool call has no
# tool_result yet and no turn ended after it. A marker that fails that test, or whose transcript
# is gone, is removed on read. The Stop hook removes the session's marker too. No hook fires on
# the approval itself, so an approved call that runs long still reads as a dialog until its
# tool_result lands: a wrong "on a prompt" costs one line, never a send.
#
#   prompt-mark.sh hook                hook payload on stdin (Notification, Stop); always exit 0,
#                                      never prints: every error is silence
#   prompt-mark.sh list                every live marker: cwd<TAB>since<TAB>tool<TAB>session<TAB>kind
#   prompt-mark.sh check <workspace>   since<TAB>tool<TAB>kind when a session working in <workspace> (its
#                                      cwd is the workspace or under it) sits on a prompt (exit 0),
#                                      else exit 1
set -uo pipefail
dir="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}/prompts"

# The newest tool_use in the transcript with no tool_result after it → id<TAB>name, or nothing.
pending_tool() { # <transcript>
  tail -n 400 "$1" 2>/dev/null | jq -R -n -r '
    [inputs | fromjson? | objects | select(.type == "assistant" or .type == "user")
     | (.message.content // empty) | arrays | .[] | objects] as $c
    | ([$c[] | select(.type == "tool_result") | .tool_use_id] ) as $done
    | [$c[] | select(.type == "tool_use") | select(.id as $i | ($done | index($i)) == null)]
    | last // empty | [(.id // ""), (.name // "")] | @tsv' 2>/dev/null
}

# Is the marker still true? Its tool call unanswered (or, with no id, no tool result) and no
# turn end since it was written.
live() { # <marker file>
  local m t
  m=$(cat "$1" 2>/dev/null) || return 1
  t=$(printf '%s' "$m" | jq -r '.transcript // ""' 2>/dev/null) || return 1
  [ -n "$t" ] && [ -f "$t" ] || return 1
  tail -n 400 "$t" | jq -R -n -e --argjson m "$m" '
    [inputs | fromjson? | objects] as $r
    | ($m.tool_id // "") as $id | ($m.since // "") as $s
    | ([$r[] | select(.type == "system" and ((.subtype // "") | test("^(turn_duration|stop_hook_summary)$")))
        | select((.timestamp // "") > $s)] | length) == 0
      and (if $id != ""
           then ([$r[] | select(.type == "user") | (.message.content // empty) | arrays | .[] | objects
                  | select(.type == "tool_result" and .tool_use_id == $id)] | length) == 0
           else ([$r[] | select(.type == "user" and ((.timestamp // "") > $s)) | (.message.content // empty)
                  | arrays | .[] | objects | select(.type == "tool_result")] | length) == 0
           end)' >/dev/null 2>&1
}

hook() {
  local in ev sid cwd tr pt f kind
  command -v jq >/dev/null 2>&1 || return 0
  in=$(cat 2>/dev/null) || return 0
  ev=$(printf '%s' "$in" | jq -r '[(.hook_event_name // ""), (.notification_type // ""), (.session_id // ""),
         (.cwd // ""), (.transcript_path // "")] | @tsv' 2>/dev/null) || return 0
  sid=$(printf '%s' "$ev" | cut -f3)
  case "$sid" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  f="$dir/$sid.json"
  case "$(printf '%s' "$ev" | cut -f1)" in
    Stop) rm -f "$f" 2>/dev/null; return 0 ;;
    Notification)
      case "$(printf '%s' "$ev" | cut -f2)" in
        permission_prompt) kind=permission ;;
        elicitation_dialog) kind=input ;;
        *) return 0 ;;
      esac ;;
    *) return 0 ;;
  esac
  cwd=$(printf '%s' "$ev" | cut -f4); tr=$(printf '%s' "$ev" | cut -f5)
  [ -n "$cwd" ] || return 0
  cwd=$(cd "$cwd" 2>/dev/null && pwd -P) || return 0
  pt=''; [ -z "$tr" ] || pt=$(pending_tool "$tr")
  mkdir -p "$dir" 2>/dev/null || return 0
  jq -n -c --arg since "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" --arg cwd "$cwd" --arg sid "$sid" --arg tr "$tr" \
     --arg id "$(printf '%s' "$pt" | cut -f1)" --arg tool "$(printf '%s' "$pt" | cut -f2)" --arg kind "$kind" \
     '{since: $since, cwd: $cwd, session: $sid, transcript: $tr, tool_id: $id, tool: $tool, kind: $kind}' \
     > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
  rm -f "$f.tmp" 2>/dev/null
  return 0
}

list() {
  local f
  command -v jq >/dev/null 2>&1 || return 0
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if live "$f"; then
      jq -r '[.cwd, .since, (.tool // ""), .session, (.kind // "permission")] | @tsv' "$f" 2>/dev/null || true
    else
      rm -f "$f" 2>/dev/null
    fi
  done
}

case "${1:-}" in
  hook) hook; exit 0 ;;
  list) list; exit 0 ;;
  check)
    [ -n "${2:-}" ] || { echo 'prompt-mark.sh check: <workspace> is required' >&2; exit 2; }
    ws=$(cd "$2" 2>/dev/null && pwd -P) || exit 1
    hit=$(list | awk -F'\t' -v w="$ws" '$1 == w || index($1, w "/") == 1 { print $2 "\t" $3 "\t" $5; exit }')
    [ -n "$hit" ] || exit 1
    printf '%s\n' "$hit" ;;
  *) echo 'usage: prompt-mark.sh hook | list | check <workspace>' >&2; exit 2 ;;
esac
