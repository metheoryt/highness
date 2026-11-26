# tracker/jira.sh — Jira Cloud (REST v3 search) and Jira Data Center (v2 search), sourced by
# tracker.sh, which holds the config, the credential and http/check. Reads and writes go through
# REST v2, whose descriptions and comments are plain strings on both.

jira_key() { case "$1" in ''|*[!A-Za-z0-9._-]*) die 3 "bad ticket key: '$1'" ;; esac; }

# JQL from parts, as one string: jq builds it, so a quote in a name never breaks the query.
JQ_JQL='def jqs: "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")) + "\"";
        def inlist: map(jqs) | join(", ") | "(\(.))";'

# The tickets a JQL query finds, one {key, fields} per line, up to 500. Cloud's search/jql pages
# with nextPageToken; where it does not exist (404: Data Center), the v2 search pages with startAt.
jira_search() { # <jql> <fields csv> [expand]
  local jql=$1 fields=$2 expand=${3:-} token='' printed=0 n req max=500
  while :; do
    req=$(jq -nc --arg q "$jql" --arg f "$fields" --arg t "$token" --arg x "$expand" \
      '{jql: $q, maxResults: 100, fields: ($f | split(","))} + (if $t == "" then {} else {nextPageToken: $t} end)
       + (if $x == "" then {} else {expand: $x} end)')
    http POST rest/api/3/search/jql "$req"
    [ "$CODE" = 404 ] && [ "$printed" = 0 ] && { jira_search_v2 "$jql" "$fields" "$expand"; return; }
    check
    printf '%s' "$RESP" | jq -c '(.issues // [])[] | {key, fields} + (if .changelog then {changelog} else {} end)'
    n=$(printf '%s' "$RESP" | jq -r '(.issues // []) | length')
    printed=$((printed + n))
    token=$(printf '%s' "$RESP" | jq -r '.nextPageToken // empty')
    [ -n "$token" ] && [ "$n" -gt 0 ] && [ "$printed" -lt "$max" ] || break
  done
}

jira_search_v2() {
  local jql=$1 fields=$2 expand=${3:-} at=0 n total req
  while :; do
    req=$(jq -nc --arg q "$jql" --arg f "$fields" --argjson at "$at" --arg x "$expand" \
      '{jql: $q, startAt: $at, maxResults: 100, fields: ($f | split(","))}
       + (if $x == "" then {} else {expand: ($x | split(","))} end)')
    http POST rest/api/2/search "$req"
    check
    printf '%s' "$RESP" | jq -c '(.issues // [])[] | {key, fields} + (if .changelog then {changelog} else {} end)'
    n=$(printf '%s' "$RESP" | jq -r '(.issues // []) | length')
    total=$(printf '%s' "$RESP" | jq -r '.total // 0')
    at=$((at + n))
    [ "$n" -gt 0 ] && [ "$at" -lt "$total" ] && [ "$at" -lt 500 ] || break
  done
}

# {key, fields} lines → normalized tickets. A status tracker.statuses does not name takes its
# role from Jira's status category. [sprint field]: add `sprint`, whether the ticket is in an
# active sprint. A `handed` on the line is kept.
jira_norm() {
  jq -c --argjson statuses "$STATUSES" --arg base "$BASE" --arg sf "${1:-}" "$JQ_DEFS$JQ_SPRINT"'
    .fields as $f
    | ($f.status.statusCategory.key // "") as $cat
    | {key, title: ($f.summary // ""), status: ($f.status.name // ""),
       role: role_of($f.status.name; ({new: "todo", done: "done"}[$cat] // "active")),
       url: "\($base)/browse/\(.key)", updated: $f.updated, created: $f.created,
       labels: ($f.labels // [])}
      + (if $sf != "" then {sprint: in_active_sprint($f[$sf])} else {} end)
      + (if .handed then {handed} else {} end)'
}

t_status() {
  load_auth
  http GET rest/api/2/myself; check
  printf 'jira %s as %s\n' "$BASE" "$(printf '%s' "$RESP" | jq -r '.displayName // .name // .accountId // "?"')"
}

# A sprint value: an object with a state (Cloud, and Data Center's newer API), or the old
# toString form "com.atlassian.greenhopper.service.sprint.Sprint@…[id=1,state=ACTIVE,name=…]".
JQ_SPRINT='def in_active_sprint($v):
  [($v // []) | if type == "array" then .[] else . end
   | if type == "object" then ((.state // "") | ascii_downcase) == "active"
     elif type == "string" then test("[,\\[]state=active[,\\]]"; "i")
     else false end] | any;'

# The JQL clause that finds the person's own tickets, and the sections' shared clauses.
jira_open_clauses() {
  jq -rn --argjson p "$PROJECTS" --argjson statuses "$STATUSES" --arg x "$QUERY" "$JQ_JQL"'
    [ (if ($p | length) > 0 then "project in \($p | inlist)" else empty end),
      "statusCategory != Done",
      ([$statuses | to_entries[] | select(.value == "done") | .key] | if length > 0 then "status not in \(inlist)" else empty end),
      (if $x != "" then "(\($x))" else empty end)
    ] | join(" AND ")'
}

t_sections() {
  if [ -n "$SPRINT" ]; then
    printf '%s\n' "$SPRINT" | grep -Eq '^customfield_[0-9]+$' \
      || die 4 "tracker.sprint '$SPRINT' is not a Jira custom field id (customfield_N)"
  fi
  local hf='' hl='' hnames='' me='' rest
  if [ "$HANDOFF" != null ]; then
    hf=$(printf '%s' "$HANDOFF" | jq -r '.field // empty')
    hl=$(printf '%s' "$HANDOFF" | jq -r '.last_assignee // empty')
    if [ -n "$hf" ]; then
      printf '%s\n' "$hf" | grep -Eq '^customfield_[0-9]+$' \
        || die 4 "tracker.handed_off.field '$hf' is not a Jira custom field id (customfield_N)"
    fi
    hnames=$(handoff_names) || exit $?
  fi
  load_auth
  rest=$(jira_open_clauses)
  local fields=summary,status,updated,created,labels${SPRINT:+,$SPRINT}
  jira_search "assignee = currentUser() AND $rest ORDER BY updated DESC" "$fields" | jira_norm "$SPRINT" \
    | jq -c --argjson statuses "$STATUSES" "$JQ_DEFS"' select(.role != "done") | section'
  [ "$HANDOFF" != null ] || return 0

  # Handed to someone else: the person's by the developer field, or by having been the assignee
  # before the last change of assignee (JQL's "was" says only "ever", so the changelog decides).
  local who jql
  if [ -n "$hf" ]; then who="cf[${hf#customfield_}] = currentUser()"; else who='assignee was currentUser()'; fi
  jql=$(jq -rn --arg who "$who" --arg rest "$rest" --argjson h "$hnames" "$JQ_JQL"'
    "\($who) AND (assignee != currentUser() OR assignee is EMPTY) AND status in \($h | inlist) AND \($rest) ORDER BY updated DESC"')
  if [ -n "$hl" ]; then
    http GET rest/api/2/myself; check
    me=$(printf '%s' "$RESP" | jq -c '[.accountId, .key, .name] | map(select(type == "string" and . != ""))')
    jira_search "$jql" summary,status,updated,created,labels,assignee changelog \
      | jq -c --argjson me "$me" '
          [(.changelog.histories // []) | sort_by(.created)[] | .created as $c
           | .items[]? | select(.fieldId == "assignee" or .field == "assignee") | {c: $c, from}] as $ch
          | select(($ch | length) > 0 and (($ch | last | .from) as $f | $me | index($f)) != null)
          | del(.changelog)'
  else
    jira_search "$jql" summary,status,updated,created,labels,assignee
  fi | jq -c '. + {handed: (.fields.assignee.displayName // "no one")}' | jira_norm \
     | jq -c --argjson statuses "$STATUSES" "$JQ_DEFS"' select(.role != "done") | section'
}

t_candidates() {
  load_auth
  local jql
  jql=$(jq -rn --argjson p "$PROJECTS" --argjson todo "$(names_for todo)" --arg l "$1" --arg x "$QUERY" "$JQ_JQL"'
    [ (if ($p | length) > 0 then "project in \($p | inlist)" else empty end),
      "labels = \($l | jqs)",
      (if ($todo | length) > 0 then "status in \($todo | inlist)" else "statusCategory = \"To Do\"" end),
      (if $x != "" then "(\($x))" else empty end)
    ] | join(" AND ") + " ORDER BY created ASC"')
  jira_search "$jql" summary,status,created,labels | jira_norm \
    | jq -c 'select(.role == "todo") | {key, title, url, created}'
}

t_read() {
  jira_key "$1"; load_auth
  http GET "rest/api/2/issue/$1?fields=summary,status,labels,assignee,description,comment,created,updated"; check
  printf '%s' "$RESP" | jq -c '{key, fields}' | jira_norm | jq -c --slurpfile raw <(printf '%s' "$RESP") '$raw[0] as $raw |
    . + {assignee: ($raw.fields.assignee.displayName // null),
         description: ($raw.fields.description // ""),
         comments: [($raw.fields.comment.comments // [])[]
                    | {author: (.author.displayName // ""), created, body: (.body // "")}]}'
}

t_move() { # <KEY> <role>
  jira_key "$1"; load_auth
  local key=$1 role=$2 cur pick tid
  http GET "rest/api/2/issue/$key?fields=status"; check
  cur=$(printf '%s' "$RESP" | jq -c '{key, fields}' | jira_norm)
  if [ "$(printf '%s' "$cur" | jq -r .role)" = "$role" ]; then
    printf '%s: already %s (%s)\n' "$key" "$role" "$(printf '%s' "$cur" | jq -r .status)"; return 0
  fi
  http GET "rest/api/2/issue/$key/transitions?expand=transitions.fields"; check
  # The configured transition by name, else the first whose target status has the role (by
  # tracker.statuses, else by category for todo and done).
  pick=$(printf '%s' "$RESP" | jq -c --argjson statuses "$STATUSES" --argjson tr "$TRANSITIONS" \
         --argjson fields "$FIELDS" --arg r "$role" "$JQ_DEFS"'
    ($tr[$r] // "" | ascii_downcase) as $name
    | ($fields[$r] // {}) as $given
    | [ .transitions[]?
        | select(if $name != "" then (.name | ascii_downcase) == $name
                 else role_of(.to.name; ({new: "todo", done: "done"}[.to.statusCategory.key // ""] // "")) == $r end) ]
    | if length == 0 then {error: "no transition from here to \($r)"}
      else .[0] | {id, name, to: .to.name,
                   missing: [(.fields // {}) | to_entries[]
                             | .key as $k
                             | select(.value.required == true and (.value.hasDefaultValue | not) and ($given | has($k) | not))
                             | "\(.key) (\(.value.name // ""))"]} end')
  if [ "$(printf '%s' "$pick" | jq -r '.error // empty')" != '' ]; then
    die 5 "$key ($(printf '%s' "$cur" | jq -r .status)): $(printf '%s' "$pick" | jq -r .error); transitions: $(printf '%s' "$RESP" | jq -r '[.transitions[]? | "\(.name) → \(.to.name)"] | join(", ")')"
  fi
  if [ "$(printf '%s' "$pick" | jq -r '.missing | length')" != 0 ]; then
    die 5 "$key: transition '$(printf '%s' "$pick" | jq -r .name)' requires $(printf '%s' "$pick" | jq -r '.missing | join(", ")'): set them in tracker.fields.$role"
  fi
  tid=$(printf '%s' "$pick" | jq -r .id)
  http POST "rest/api/2/issue/$key/transitions" \
    "$(jq -nc --arg id "$tid" --argjson f "$(printf '%s' "$FIELDS" | jq -c --arg r "$role" '.[$r] // {}')" \
         '{transition: {id: $id}} + (if ($f | length) > 0 then {fields: $f} else {} end)')"
  check
  printf '%s: %s → %s\n' "$key" "$(printf '%s' "$cur" | jq -r .status)" "$(printf '%s' "$pick" | jq -r .to)"
}

t_comment() { # <KEY> <body>
  jira_key "$1"; load_auth
  http POST "rest/api/2/issue/$1/comment" "$(jq -nc --arg b "$2" '{body: $b}')"; check
  printf '%s/browse/%s\n' "$BASE" "$1"
}
