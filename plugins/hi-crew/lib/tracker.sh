#!/usr/bin/env bash
# tracker.sh — one interface to a team's ticket tracker (Jira, YouTrack or GitHub Issues), so a
# team configures its tracker instead of writing the same glue for agenda.sections, autostart
# candidates and its workers' ticket reads and status moves.
#
#   tracker.sh [--root DIR] status             does the tracker answer with the person's
#                                              credential: one line, "<kind> <where> as <who>"
#   tracker.sh [--root DIR] sections           the person's open tickets as agenda.sections JSON
#                                              lines: group, title, next, url, since, key, role, status
#   tracker.sh [--root DIR] candidates [LABEL] ready tickets (role todo) carrying LABEL (default
#                                              crew.autostart.label, else "auto"), as autostart
#                                              candidates: key, title, url, created
#   tracker.sh [--root DIR] read <KEY>         one ticket: key, title, status, role, url, labels,
#                                              assignee, description, comments [{author, created, body}]
#   tracker.sh [--root DIR] move <KEY> <role>  move the ticket to a status of that role
#   tracker.sh [--root DIR] comment <KEY>      comment the ticket with stdin
#
# --root: read the config at DIR's git root rather than the cwd's (a worker runs in another tree).
# crew.sh fills {{TRACKER}} with this command and --root already set.
#
# Config, under `tracker` in .claude/highness.json or the person's file (lib/config.sh):
#   kind          jira | youtrack | github (required)
#   base_url      the tracker's URL (jira, youtrack)
#   projects      project keys the queries keep to (jira, youtrack); default every project
#   repo          owner/repo (github); default the root's origin
#   statuses      {"<status or label name>": "<role>"}, roles: todo active in_review waiting
#                 testing done bounced. GitHub reads role labels. Unmapped statuses fall back:
#                 Jira by status category, YouTrack resolved or not, GitHub closed or not
#   transitions   {"<role>": "<name>"}: Jira, the transition to take; YouTrack, the command
#                 to apply. Default: the first transition (or state) that lands in that role
#   fields        {"<role>": {...}}: fields a move to that role sets (Jira: the transition's
#                 "fields"; YouTrack: "<field> <value>" command parts)
#   state_field   YouTrack's state field (default State)
#   query         an extra clause in the tracker's own query language, ANDed into sections and
#                 candidates (GitHub: search terms)
#
# Credentials never come from a repo. They sit in the person's own file, top level, keyed by the
# tracker's host, so a token is only ever sent to the host the person paired it with — a cloned
# repo's base_url cannot redirect it:
#   "trackers": {"<host>": {"token_command": "...", "token_env": "VAR", "email": "...",
#                           "auth": "basic | bearer", "allow_http": false}}
# token_env is read first, then token_command (its first line). Jira's default auth is basic
# (email + API token); bearer is a personal access token. GitHub uses gh's own login.
#
# Exit: 0 ok · 1 no credential · 2 credential rejected · 3 usage · 4 no or bad config ·
# 5 tracker error (network, HTTP, nothing matched). The reason is the last line on stderr.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.sh"
ROLES='todo active in_review waiting testing done bounced'

die() { printf 'tracker: %s\n' "$2" >&2; exit "$1"; }
usage() { die 3 'usage: tracker.sh [--root DIR] status | sections | candidates [LABEL] | read KEY | move KEY ROLE | comment KEY'; }
command -v jq >/dev/null 2>&1 || die 3 'jq is required'

if [ "${1:-}" = --root ]; then
  [ -n "${2:-}" ] || usage
  cd "$2" 2>/dev/null || die 4 "no such directory: $2"
  shift 2
fi
VERB=${1:-}; [ $# -gt 0 ] && shift
case "$VERB" in status|sections|candidates|read|move|comment) ;; *) usage ;; esac

cfg() { bash "$CONFIG" get ".tracker.$1"; }         # a string, or compact JSON for a list/object
cfg_json() { local v; v=$(bash "$CONFIG" get ".tracker.$1 | select(. != null) | tojson") && printf '%s' "$v" || printf '%s' "$2"; }

KIND=$(cfg kind) || die 4 'no tracker.kind in .claude/highness.json or the personal config'
case "$KIND" in jira|youtrack|github) ;; *) die 4 "tracker.kind '$KIND' is not jira, youtrack or github" ;; esac
STATUSES=$(cfg_json statuses '{}')
TRANSITIONS=$(cfg_json transitions '{}')
FIELDS=$(cfg_json fields '{}')
PROJECTS=$(cfg_json projects '[]')
QUERY=$(cfg query) || QUERY=''
bad=$(printf '%s' "$STATUSES" | jq -r --arg r "$ROLES" '
  if type != "object" then "tracker.statuses is not an object"
  else [ .[] | select(type != "string" or (. as $v | ($r | split(" ") | index($v)) == null)) ]
       | if length > 0 then "tracker.statuses has a role that is not one of: \($r)" else empty end end')
[ -z "$bad" ] || die 4 "$bad"
printf '%s' "$PROJECTS" | jq -e 'type == "array"' >/dev/null 2>&1 || die 4 'tracker.projects is not a list'

# One role, checked against the list.
want_role() {
  case " $ROLES " in *" $1 "*) ;; *) die 3 "role '$1' is not one of: $ROLES" ;; esac
}

# jq definitions every kind shares: a status name's role from tracker.statuses (case ignored),
# and a section line from a normalized ticket {key, title, status, role, url, updated}.
JQ_DEFS='
  def rolemap: $statuses | to_entries | map({key: (.key | ascii_downcase), value}) | from_entries;
  def role_of($name; $fallback): rolemap[($name // "" | ascii_downcase)] // $fallback;
  def group_of: {todo: "later", active: "you", bounced: "you", in_review: "others",
                 testing: "others", waiting: "others", done: "done"}[.] // "you";
  def next_of: {todo: "not started", active: "in progress", bounced: "came back: read the latest comment",
                in_review: "in review", testing: "in testing", waiting: "waiting on someone else",
                done: "done"}[.] // "status not mapped to a role";
  def section: {group: (.role | group_of), title: "\(.key) · \(.title) — \(.status)",
                next: (.role | next_of), url, since: .updated, key, role, status};
'
# The status names configured for a role, as a JSON list.
names_for() { printf '%s' "$STATUSES" | jq -c --arg r "$1" '[to_entries[] | select(.value == $r) | .key]'; }
# Every role but done that has a status name, as a JSON list of names.
open_names() { printf '%s' "$STATUSES" | jq -c '[to_entries[] | select(.value != "done") | .key]'; }

# ---- HTTP with the person's credential (jira, youtrack) ----

BASE=''
HOST=''
AUTH_HEADER=''
CODE=''
RESP=''

load_base() {
  BASE=$(cfg base_url) || die 4 "tracker.base_url is not set (kind $KIND)"
  BASE=${BASE%/}
  # A whitelist, not a parse: the host must be the only thing curl could read as one. No user
  # info, query or fragment, so "https://other#@tracker" can never pass for tracker's host.
  printf '%s\n' "$BASE" | grep -Eq '^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?$' \
    || die 4 "tracker.base_url '$BASE' is not a plain http(s) URL (scheme, host, optional port and path only)"
  local rest=${BASE#*://}
  rest=${rest%%/*}
  HOST=$(printf '%s' "$rest" | tr 'A-Z' 'a-z')
}

# The person's credential entry for HOST, from their own file only (--user: never a repo, never
# an overlay chosen by a remote name).
cred() { bash "$CONFIG" get --user ".trackers[$(printf '%s' "$HOST" | jq -R .)].$1"; }

load_auth() {
  load_base
  local env cmd token email scheme
  if ! bash "$CONFIG" get --user ".trackers[$(printf '%s' "$HOST" | jq -R .)] | objects | \"set\"" >/dev/null 2>&1; then
    die 1 "no credential for $HOST: add \"trackers\": {\"$HOST\": {\"token_command\": \"...\"}} to your personal highness config (never to a repo)"
  fi
  case "$BASE" in
    http://*) [ "$(cred allow_http 2>/dev/null)" = true ] \
                || die 4 "$BASE is plain http: the token would travel in clear (set trackers.\"$HOST\".allow_http to true to allow it)" ;;
  esac
  token=''
  if env=$(cred token_env); then
    case "$env" in *[!A-Za-z0-9_]*|'') die 4 "trackers.\"$HOST\".token_env is not a variable name" ;; esac
    token=$(printenv "$env" 2>/dev/null) || token=''
  fi
  if [ -z "$token" ] && cmd=$(cred token_command); then
    token=$(sh -c "$cmd" 2>/dev/null </dev/null | head -1) || token=''
  fi
  [ -n "$token" ] || die 1 "no token for $HOST: trackers.\"$HOST\" has no token_env that is set and no token_command that prints one"
  scheme=$(cred auth) || scheme=''
  [ -n "$scheme" ] || { [ "$KIND" = jira ] && scheme=basic || scheme=bearer; }
  case "$scheme" in
    basic)
      email=$(cred email) || die 4 "trackers.\"$HOST\".email is required for basic auth"
      AUTH_HEADER="Basic $(printf '%s:%s' "$email" "$token" | base64 | tr -d '\n')" ;;
    bearer) AUTH_HEADER="Bearer $token" ;;
    *) die 4 "trackers.\"$HOST\".auth '$scheme' is not basic or bearer" ;;
  esac
  unset token
}

# http <METHOD> <path> [json-body] [curl args...] → RESP, CODE. The credential travels in a curl
# config on stdin, never in argv, so `ps` never shows it; no redirects are followed, so it never
# leaves HOST.
http() {
  local method=$1 path=$2 body=${3:-} raw
  local -a data=()
  shift 2; [ $# -gt 0 ] && shift
  [ -n "$body" ] && data=(--data-raw "$body")
  raw=$({ printf 'header = "Authorization: %s"\n' "$AUTH_HEADER"
          printf 'header = "Accept: application/json"\n'
          if [ -n "$body" ]; then printf 'header = "Content-Type: application/json"\n'; fi
        } | curl -sS --max-time 60 -K - -X "$method" -w '\n%{http_code}' \
              ${data[@]+"${data[@]}"} "$@" "$BASE/${path#/}" 2>/dev/null) || raw=''
  if [ -z "$raw" ]; then CODE=000; RESP=''; return 0; fi
  CODE=${raw##*$'\n'}; RESP=${raw%$'\n'*}
  case "$CODE" in ''|*[!0-9]*) CODE=000 ;; esac
}

# Exit on anything but 2xx, with the tracker's own message when it gives one.
check() {
  case "$CODE" in
    2*) return 0 ;;
    000) die 5 "$KIND at $BASE did not answer (network, DNS, TLS or a VPN)" ;;
    401|403) die 2 "$KIND at $BASE rejected the credential for $HOST (HTTP $CODE): renew the token" ;;
    *) die 5 "$KIND at $BASE answered HTTP $CODE: $(printf '%s' "$RESP" | jq -r '
         [(.errorMessages // [])[], ((.errors // {}) | to_entries[] | "\(.key): \(.value)"),
          .error_description, .error, .message] | map(select(type == "string" and . != "")) | first // empty' 2>/dev/null | head -1)" ;;
  esac
}

. "$HERE/tracker/$KIND.sh"

case "$VERB" in
  status) t_status ;;
  sections) t_sections ;;
  candidates)
    label=${1:-}
    [ -n "$label" ] || label=$(bash "$CONFIG" get --user '.crew.autostart.label') || label=auto
    t_candidates "$label" ;;
  read) [ $# -eq 1 ] || usage; t_read "$1" ;;
  move) [ $# -eq 2 ] || usage; want_role "$2"; t_move "$1" "$2" ;;
  comment)
    [ $# -eq 1 ] || usage
    body=$(cat)
    [ -n "$body" ] || die 3 'comment: the body on stdin is empty'
    t_comment "$1" "$body" ;;
esac
