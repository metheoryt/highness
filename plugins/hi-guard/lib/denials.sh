#!/usr/bin/env bash
# denials.sh — the denial log: one local file, one JSON object per line, for a retro or a person
# looking for false denials and rules worth loosening.
#
#   denials.sh permission-denied   Claude Code's PermissionDenied hook JSON on stdin
#
# guard.sh sources this file and logs every deny and ask of its own; the PermissionDenied hook
# logs the refusals of Claude Code's auto-mode classifier. Claude Code fires PermissionDenied for
# the classifier only: a permissions.deny rule and a PreToolUse hook's deny (hi-guard's included)
# do not fire it, so nothing is logged twice, and a settings deny rule is not logged at all.
#
# The file: ${HIGHNESS_STATE:-${XDG_STATE_HOME:-~/.local/state}/highness}/denials.jsonl, created
# owner-only. hi-crew's retro.sh reads the same path. A line:
#   time        ISO 8601 UTC
#   session     the Claude Code session id (the transcript's file name without .jsonl)
#   cwd         the session's cwd
#   tool        the tool name (Bash, Write, …)
#   command     tool_input.command, cut to DENIAL_MAX characters; or
#   path        tool_input.file_path / notebook_path / path; or
#   input       the tool input as compact JSON, cut to DENIAL_MAX characters
#   by          hi-guard | claude-code
#   rule        hi-guard: sudo, deny_patterns or checks; claude-code: auto-mode classifier
#   decision    deny | ask (ask: hi-guard's checks only)
#   reason      the message the agent was given (hi-guard), or the classifier's reason
#   claude-code lines also carry permission_mode, tool_use_id and, from a subagent, agent_id.
#
# Logging never changes a decision or breaks a session: a write that fails is dropped, and the
# PermissionDenied hook prints nothing (its output could ask Claude Code to retry).
#
# HI_GUARD_PROBE=1 in the environment: nothing is logged. hi-crew sets it when it puts an action
# the person already approved to guard.sh as a probe; no agent met that decision, so a line would
# read in a retro as a denial the worker hit. A probe's deny is kept on the action itself.

DENIAL_MAX=2000

# denial_write <json object>: append it as one line. Never fails, prints nothing.
denial_write() {
  local d="${HIGHNESS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/highness}"
  [ -n "$1" ] && [ "${HI_GUARD_PROBE:-}" != 1 ] || return 0
  ( umask 077; mkdir -p "$d" && printf '%s\n' "$1" >>"$d/denials.jsonl" ) 2>/dev/null || true
}

# The PermissionDenied payload, as measured on Claude Code 2.1: session_id, transcript_path, cwd,
# prompt_id, permission_mode, effort, hook_event_name, tool_name, tool_input, tool_use_id, reason
# (e.g. "[Unauthorized Access]").
permission_denied() {
  local line
  line=$(jq -c --argjson max "$DENIAL_MAX" '
    def s: if type == "string" then . else "" end;
    if type == "object" then
      (.tool_input // {}) as $i
      | ($i | if type == "object" then (.file_path // .notebook_path // .path) else null end) as $p
      | {time: (now | todate), session: (.session_id | s), cwd: (.cwd | s), tool: (.tool_name | s)}
        + (if ($i | type) == "object" and ($i.command | type) == "string" then {command: $i.command[0:$max]}
           elif ($p | type) == "string" then {path: $p}
           else {input: ($i | tojson | .[0:$max])} end)
        + {by: "claude-code", rule: "auto-mode classifier", decision: "deny",
           reason: (.reason // "" | if type == "string" then . else tojson end),
           permission_mode: (.permission_mode | s), tool_use_id: (.tool_use_id | s)}
        + (if (.agent_id | type) == "string" then {agent_id: .agent_id} else {} end)
    else empty end' 2>/dev/null) || return 0
  [ -z "$line" ] || denial_write "$line"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    permission-denied) permission_denied ;;
    *) echo 'usage: denials.sh permission-denied   (PermissionDenied hook JSON on stdin)' >&2 ;;
  esac
  exit 0
fi
