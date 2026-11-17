# tracker/jira.sh — Jira Cloud (REST v3 search) and Jira Data Center (v2 search), sourced by
# tracker.sh, which holds the config, the credential and http/check. Reads and writes go through
# REST v2, whose descriptions and comments are plain strings on both.

jira_key() { case "$1" in ''|*[!A-Za-z0-9._-]*) die 3 "bad ticket key: '$1'" ;; esac; }

# JQL from parts, as one string: jq builds it, so a quote in a name never breaks the query.
JQ_JQL='def jqs: "\"" + (gsub("\\\\"; "\\\\") | gsub("\""; "\\\"")) + "\"";
        def inlist: map(jqs) | join(", ") | "(\(.))";'

# The tickets a JQL query finds, one {key, fields} per line, up to 500. Cloud's search/jql pages
# with nextPageToken; where it does not exist (404: Data Center), the v2 search pages with startAt.
jira_search() { # <jql> <fields csv>
  local jql=$1 fields=$2 token='' printed=0 n req max=500
  while :; do
    req=$(jq -nc --arg q "$jql" --arg f "$fields" --arg t "$token" \
      '{jql: $q, maxResults: 100, fields: ($f | split(","))} + (if $t == "" then {} else {nextPageToken: $t} end)')
    http POST rest/api/3/search/jql "$req"
    [ "$CODE" = 404 ] && [ "$printed" = 0 ] && { jira_search_v2 "$jql" "$fields"; return; }
    check
    printf '%s' "$RESP" | jq -c '(.issues // [])[] | {key, fields}'
    n=$(printf '%s' "$RESP" | jq -r '(.issues // []) | length')
    printed=$((printed + n))
    token=$(printf '%s' "$RESP" | jq -r '.nextPageToken // empty')
    [ -n "$token" ] && [ "$n" -gt 0 ] && [ "$printed" -lt "$max" ] || break
  done
}

jira_search_v2() {
  local jql=$1 fields=$2 at=0 n total req
  while :; do
    req=$(jq -nc --arg q "$jql" --arg f "$fields" --argjson at "$at" \
      '{jql: $q, startAt: $at, maxResults: 100, fields: ($f | split(","))}')
    http POST rest/api/2/search "$req"
    check
    printf '%s' "$RESP" | jq -c '(.issues // [])[] | {key, fields}'
    n=$(printf '%s' "$RESP" | jq -r '(.issues // []) | length')
    total=$(printf '%s' "$RESP" | jq -r '.total // 0')
    at=$((at + n))
    [ "$n" -gt 0 ] && [ "$at" -lt "$total" ] && [ "$at" -lt 500 ] || break
  done
}

# {key, fields} lines → normalized tickets. A status tracker.statuses does not name takes its
# role from Jira's status category.
jira_norm() {
  jq -c --argjson statuses "$STATUSES" --arg base "$BASE" "$JQ_DEFS"'
    .fields as $f
    | ($f.status.statusCategory.key // "") as $cat
    | {key, title: ($f.summary // ""), status: ($f.status.name // ""),
       role: role_of($f.status.name; ({new: "todo", done: "done"}[$cat] // "active")),
       url: "\($base)/browse/\(.key)", updated: $f.updated, created: $f.created,
       labels: ($f.labels // [])}'
}

t_status() {
  load_auth
  http GET rest/api/2/myself; check
  printf 'jira %s as %s\n' "$BASE" "$(printf '%s' "$RESP" | jq -r '.displayName // .name // .accountId // "?"')"
}

t_sections() {
  load_auth
  local jql
  jql=$(jq -rn --argjson p "$PROJECTS" --argjson statuses "$STATUSES" --arg x "$QUERY" "$JQ_JQL"'
    [ "assignee = currentUser()",
      (if ($p | length) > 0 then "project in \($p | inlist)" else empty end),
      "statusCategory != Done",
      ([$statuses | to_entries[] | select(.value == "done") | .key] | if length > 0 then "status not in \(inlist)" else empty end),
      (if $x != "" then "(\($x))" else empty end)
    ] | join(" AND ") + " ORDER BY updated DESC"')
  jira_search "$jql" summary,status,updated,created,labels | jira_norm \
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
  printf '%s' "$RESP" | jq -c '{key, fields}' | jira_norm | jq -c --argjson raw "$RESP" '
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
