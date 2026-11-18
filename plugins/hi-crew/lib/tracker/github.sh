# tracker/github.sh — GitHub Issues through gh (its own login), sourced by tracker.sh. A ticket's
# key is <repo name>-<number> (a '#' cannot be in a key), its status the role label it carries:
# tracker.statuses maps label names to roles. An open issue with no role label is todo, a closed
# one is done.

command -v gh >/dev/null 2>&1 || die 3 'gh is required for tracker.kind github'

REPO=$(cfg repo) || REPO=''
if [ -z "$REPO" ]; then
  REPO=$(git config --get remote.origin.url 2>/dev/null) || die 4 'tracker.repo is not set and this tree has no origin'
  REPO=${REPO%/}; REPO=${REPO%.git}; REPO=${REPO##*:}
  REPO=$(printf '%s' "$REPO" | awk -F/ 'NF >= 2 { print $(NF-1) "/" $NF }')
fi
case "$REPO" in */*) ;; *) die 4 "tracker.repo '$REPO' is not owner/repo" ;; esac
RNAME=${REPO##*/}

# <repo>-<n> → n, for this repo only.
gh_num() {
  local n=${1##*-}
  case "$1" in "$RNAME-$n") ;; *) die 3 "key '$1' is not $RNAME-<number>" ;; esac
  case "$n" in ''|*[!0-9]*) die 3 "key '$1' is not $RNAME-<number>" ;; esac
  printf '%s' "$n"
}

# gh's answer, or the reason it failed as the last line.
gh_json() {
  local out
  out=$(gh "$@" 2>&1) || die 5 "gh $1 $2 failed: $(printf '%s' "$out" | tail -1)"
  printf '%s\n' "$out"
}

# gh issue JSON (an array or one issue) → normalized tickets, one per line.
gh_norm() {
  jq -c --argjson statuses "$STATUSES" --arg r "$RNAME" "$JQ_DEFS"'
    (if type == "array" then .[] else . end)
    | ([.labels[]?.name | select(rolemap[ascii_downcase] != null)][0] // null) as $l
    | ((.state // "OPEN") | ascii_upcase) as $s
    | {key: "\($r)-\(.number)", title: (.title // ""),
       status: (if $s == "CLOSED" then "closed" else ($l // "open") end),
       role: (if $s == "CLOSED" then "done" elif $l then role_of($l; "todo") else "todo" end),
       url, updated: .updatedAt, created: .createdAt, labels: [.labels[]?.name]}'
}

t_status() {
  local who
  who=$(gh_json api user --jq .login)
  gh_json repo view "$REPO" --json name >/dev/null
  printf 'github %s as %s\n' "$REPO" "$who"
}

t_sections() {
  gh_json issue list -R "$REPO" --assignee @me --state open --limit 200 ${QUERY:+--search "$QUERY"} \
      --json number,title,url,labels,state,updatedAt,createdAt \
    | gh_norm | jq -c --argjson statuses "$STATUSES" "$JQ_DEFS"' select(.role != "done") | section'
}

t_candidates() {
  gh_json issue list -R "$REPO" --label "$1" --state open --limit 100 ${QUERY:+--search "$QUERY"} \
      --json number,title,url,labels,state,createdAt \
    | gh_norm | jq -c 'select(.role == "todo") | {key, title, url, created}'
}

t_read() {
  local n
  n=$(gh_num "$1") || exit 3
  gh_json issue view "$n" -R "$REPO" --json number,title,body,state,labels,assignees,comments,url,updatedAt,createdAt \
    | jq -c '.' | {
      raw=$(cat)
      printf '%s' "$raw" | gh_norm | jq -c --argjson raw "$raw" '
        . + {assignee: ([$raw.assignees[]?.login] | join(", ") | if . == "" then null else . end),
             description: ($raw.body // ""),
             comments: [($raw.comments // [])[] | {author: (.author.login // ""), created: .createdAt, body: (.body // "")}]}'
    }
}

t_move() { # <KEY> <role>
  local key=$1 role=$2 n cur add rm state
  n=$(gh_num "$key") || exit 3
  cur=$(gh_json issue view "$n" -R "$REPO" --json number,title,labels,state,url | gh_norm) || exit 5
  if [ "$(printf '%s' "$cur" | jq -r .role)" = "$role" ]; then
    printf '%s: already %s (%s)\n' "$key" "$role" "$(printf '%s' "$cur" | jq -r .status)"; return 0
  fi
  add=$(names_for "$role" | jq -r '.[0] // empty')
  case "$role" in todo|done) ;; *) [ -n "$add" ] || die 4 "tracker.statuses names no label for role $role" ;; esac
  # The role labels it carries that are not the new one.
  rm=$(printf '%s' "$cur" | jq -r --argjson statuses "$STATUSES" --arg add "$add" "$JQ_DEFS"'
    [.labels[] | select(rolemap[ascii_downcase] != null and . != $add)] | join(",")')
  state=$(printf '%s' "$cur" | jq -r .status)
  if [ -n "$add" ] || [ -n "$rm" ]; then
    gh_json issue edit "$n" -R "$REPO" ${add:+--add-label "$add"} ${rm:+--remove-label "$rm"} >/dev/null
  fi
  if [ "$role" = done ]; then
    gh_json issue close "$n" -R "$REPO" >/dev/null
  elif [ "$state" = closed ]; then
    gh_json issue reopen "$n" -R "$REPO" >/dev/null
  fi
  printf '%s: %s → %s\n' "$key" "$state" "${add:-$([ "$role" = done ] && echo closed || echo open)}"
}

t_comment() { # <KEY> <body>
  local n
  n=$(gh_num "$1") || exit 3
  printf '%s' "$2" | gh_json issue comment "$n" -R "$REPO" --body-file -
}
