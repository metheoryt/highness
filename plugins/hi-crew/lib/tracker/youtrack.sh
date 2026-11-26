# tracker/youtrack.sh — YouTrack REST (/api), sourced by tracker.sh, which holds the config, the
# credential (a permanent token, sent as bearer) and http/check. Status moves are YouTrack
# commands, so a workflow's own rules apply to them.

yt_key() { case "$1" in ''|*[!A-Za-z0-9._-]*) die 3 "bad ticket key: '$1'" ;; esac; }

SF=$(cfg state_field) || SF=State
ISSUE_FIELDS='idReadable,summary,created,updated,resolved,tags(name),customFields(name,value(name,login,fullName))'

# A query or command value in braces when it holds a space: {In Progress}.
yt_q() { case "$1" in *' '*) printf '{%s}' "$1" ;; *) printf '%s' "$1" ;; esac; }

# Issues a query finds, as one JSON array (up to 500).
yt_search() { # <query>
  http GET api/issues '' -G --data-urlencode "query=$1" --data-urlencode "fields=$ISSUE_FIELDS" \
    --data-urlencode '$top=500'
  check
  printf '%s' "$RESP" | jq -e 'type == "array"' >/dev/null 2>&1 || die 5 "youtrack at $BASE answered without an issue list"
  printf '%s\n' "$RESP"
}

# An issue array (or one issue) → normalized tickets, one per line. A state tracker.statuses
# does not name is done when the issue is resolved, active otherwise.
yt_norm() {
  jq -c --argjson statuses "$STATUSES" --arg base "$BASE" --arg sf "$SF" "$JQ_DEFS"'
    def ms2iso: if type == "number" then (. / 1000 | floor | todate) else . end;
    (if type == "array" then .[] else . end)
    | ([.customFields[]? | select(.name == $sf) | .value.name][0] // "") as $st
    | {key: .idReadable, title: (.summary // ""), status: $st,
       role: role_of($st; (if .resolved then "done" else "active" end)),
       url: "\($base)/issue/\(.idReadable)", updated: (.updated | ms2iso), created: (.created | ms2iso),
       labels: [.tags[]?.name]} + (if .handed then {handed} else {} end)'
}

yt_projects() { printf '%s' "$PROJECTS" | jq -r 'map(if test(" ") then "{\(.)}" else . end) | if length > 0 then "project: " + join(", ") else empty end'; }

t_status() {
  load_auth
  http GET 'api/users/me?fields=login,fullName'; check
  printf 'youtrack %s as %s\n' "$BASE" "$(printf '%s' "$RESP" | jq -r '.fullName // .login // "?"')"
}

t_sections() {
  local hf='' hnames='' states q mine sprint='null'
  if [ "$HANDOFF" != null ]; then
    hf=$(printf '%s' "$HANDOFF" | jq -r '.field // empty')
    [ -n "$hf" ] || die 4 'tracker.handed_off.last_assignee is Jira only: on YouTrack name the developer field (handed_off.field)'
    hnames=$(handoff_names) || exit $?
  fi
  load_auth
  q="for: me #Unresolved $(yt_projects)${QUERY:+ ($QUERY)} sort by: updated desc"
  mine=$(yt_search "$q") || exit $?
  # The sprint: the keys of the person's issues that also match tracker.sprint's clause.
  if [ -n "$SPRINT" ]; then
    sprint=$(yt_search "for: me #Unresolved $(yt_projects)${QUERY:+ ($QUERY)} ($SPRINT)" | jq -c '[.[].idReadable]') || exit $?
  fi
  printf '%s' "$mine" | yt_norm | jq -c --argjson statuses "$STATUSES" --argjson sp "$sprint" "$JQ_DEFS"'
    select(.role != "done")
    | if $sp == null then . else . + {sprint: (.key as $k | $sp | index($k) != null)} end | section'
  [ -n "$hf" ] || return 0
  states=$(printf '%s' "$hnames" | jq -r --arg sf "$SF" '
    def br: if test(" ") then "{\(.)}" else . end;
    "\($sf | br): " + (map(br) | join(", "))')
  q="$(yt_q "$hf"): me Assignee: -me #Unresolved $states $(yt_projects)${QUERY:+ ($QUERY)} sort by: updated desc"
  yt_search "$q" \
    | jq -c '.[] | . + {handed: ([.customFields[]? | select(.name == "Assignee") | .value.fullName // .value.login][0] // "no one")}' \
    | yt_norm | jq -c --argjson statuses "$STATUSES" "$JQ_DEFS"' select(.role != "done") | section'
}

t_candidates() {
  load_auth
  local todo q
  todo=$(names_for todo | jq -r --arg sf "$SF" '
    map(if test(" ") then "{\(.)}" else . end) | if length > 0 then "\($sf | if test(" ") then "{\(.)}" else . end): " + join(", ") else empty end')
  [ -n "$todo" ] || die 4 'tracker.statuses names no todo state: autostart cannot tell a ready YouTrack issue from a started one'
  q="tag: $(yt_q "$1") $todo $(yt_projects)${QUERY:+ ($QUERY)} sort by: created asc"
  yt_search "$q" | yt_norm | jq -c 'select(.role == "todo") | {key, title, url, created}'
}

t_read() {
  yt_key "$1"; load_auth
  http GET "api/issues/$1" '' -G --data-urlencode "fields=$ISSUE_FIELDS,description,comments(text,created,author(login,fullName))"
  check
  printf '%s' "$RESP" | yt_norm | jq -c --slurpfile raw <(printf '%s' "$RESP") '$raw[0] as $raw |
    def ms2iso: if type == "number" then (. / 1000 | floor | todate) else . end;
    . + {assignee: ([$raw.customFields[]? | select(.name == "Assignee") | .value.fullName // .value.login][0] // null),
         description: ($raw.description // ""),
         comments: [($raw.comments // [])[]
                    | {author: (.author.fullName // .author.login // ""), created: (.created | ms2iso), body: (.text // "")}]}'
}

t_move() { # <KEY> <role>
  yt_key "$1"; load_auth
  local key=$1 role=$2 cur command to extra
  http GET "api/issues/$key" '' -G --data-urlencode "fields=$ISSUE_FIELDS"; check
  cur=$(printf '%s' "$RESP" | yt_norm)
  if [ "$(printf '%s' "$cur" | jq -r .role)" = "$role" ]; then
    printf '%s: already %s (%s)\n' "$key" "$role" "$(printf '%s' "$cur" | jq -r .status)"; return 0
  fi
  command=$(printf '%s' "$TRANSITIONS" | jq -r --arg r "$role" '.[$r] // empty')
  if [ -z "$command" ]; then
    to=$(names_for "$role" | jq -r '.[0] // empty')
    [ -n "$to" ] || die 4 "tracker.statuses names no state for role $role, and tracker.transitions.$role is not set"
    command="$(yt_q "$SF") $(yt_q "$to")"
  fi
  extra=$(printf '%s' "$FIELDS" | jq -r --arg r "$role" '
    (.[$r] // {}) | to_entries | map("\(.key | if test(" ") then "{\(.)}" else . end) \(.value | tostring | if test(" ") then "{\(.)}" else . end)") | join(" ")')
  [ -z "$extra" ] || command="$command $extra"
  http POST api/commands "$(jq -nc --arg q "$command" --arg k "$key" '{query: $q, issues: [{idReadable: $k}]}')"
  check
  printf '%s: %s → %s\n' "$key" "$(printf '%s' "$cur" | jq -r .status)" "$command"
}

t_comment() { # <KEY> <body>
  yt_key "$1"; load_auth
  http POST "api/issues/$1/comments" "$(jq -nc --arg t "$2" '{text: $t}')"; check
  printf '%s/issue/%s\n' "$BASE" "$1"
}
