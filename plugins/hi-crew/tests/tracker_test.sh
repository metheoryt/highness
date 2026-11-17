#!/usr/bin/env bash
# lib/tracker.sh — Jira, YouTrack and GitHub Issues behind one interface, against a fake curl and
# a fake gh: the credential bound to its host and never in argv, the queries, the role mapping,
# the transition choice, the exit codes; and crew.sh's {{TRACKER}}.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TR="$HERE/../lib/tracker.sh"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1: [$3] in [$2]" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

mkdir -p "$T/bin" "$T/root/.claude" "$T/f"
git -C "$T/root" init -q && git -C "$T/root" remote add origin https://github.com/acme/widgets.git
export HIGHNESS_CONFIG="$T/user.json" HIGHNESS_STATE="$T/state" PATH="$T/bin:$PATH" FAKE="$T/f"

# Fake curl: logs argv, the config it reads on stdin, and "METHOD URL DATA [query]"; answers from
# $FAKE/routes, lines "METHOD<TAB>url substring<TAB>code<TAB>body file", first match wins.
cat >"$T/bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE/argv"
cat >>"$FAKE/stdin"
method=GET url='' data='' qs=''
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    --data-raw) data=$2; shift 2 ;;
    --data-urlencode) qs="$qs&$2"; shift 2 ;;
    -K|--max-time|-w) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s %s %s %s\n' "$method" "$url" "$data" "$qs" >>"$FAKE/req"
while IFS='	' read -r m sub code body; do
  [ "$m" = "$method" ] || continue
  case "$url" in *"$sub"*) cat "$FAKE/$body"; printf '\n%s' "$code"; exit 0 ;; esac
done <"$FAKE/routes"
printf '{"errorMessages":["no route"]}\n404'
EOF
chmod +x "$T/bin/curl"
reset() { rm -f "$FAKE/argv" "$FAKE/stdin" "$FAKE/req" "$FAKE/routes"; touch "$FAKE/routes"; }
route() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$FAKE/routes"; }
body() { cat >"$FAKE/$1"; }
team() { printf '%s' "$1" >"$T/root/.claude/highness.json"; }
person() { printf '%s' "$1" >"$HIGHNESS_CONFIG"; }
run() { (cd "$T/root" && bash "$TR" "$@"); }

# ---------------------------------------------------------------- jira
JIRA='{"tracker": {"kind": "jira", "base_url": "https://example.atlassian.net/", "projects": ["AB"],
  "statuses": {"To Do": "todo", "In Progress": "active", "In Review": "in_review", "Done": "done", "Reopened": "bounced"},
  "fields": {"done": {"resolution": {"name": "Fixed"}}}}}'
CRED='{"trackers": {"example.atlassian.net": {"email": "ada@example.com", "token_env": "HI_TEST_TOKEN"}}}'
export HI_TEST_TOKEN=s3cret-token

reset; team '{}'; person '{}'
run status 2>"$T/err"; check "no tracker.kind → exit 4" "$?" 4
has "no tracker.kind: says so" "$(cat "$T/err")" 'no tracker.kind'

team "$JIRA"; person '{"trackers": {"other.example.com": {"email": "a@b", "token_env": "HI_TEST_TOKEN"}}}'
run status 2>"$T/err"; check "a credential for another host → exit 1" "$?" 1
check "no credential for the host: nothing is sent" "$([ -e "$FAKE/req" ] && echo sent || echo none)" none
has "no credential: names the host" "$(cat "$T/err")" 'no credential for example.atlassian.net'

# A repo cannot pick the person's overlay to get a credential: only the top level counts.
person '{"repos": {"acme": {"trackers": {"example.atlassian.net": {"email": "a@b", "token_env": "HI_TEST_TOKEN"}}}}}'
run status 2>/dev/null; check "a credential in a repo overlay is not used" "$?" 1
team '{"tracker": {"kind": "jira", "base_url": "https://example.atlassian.net"}, "trackers": {"example.atlassian.net": {"email": "a@b", "token_env": "HI_TEST_TOKEN"}}}'
person '{}'
run status 2>/dev/null; check "a credential in the repo file is not used" "$?" 1

team "$JIRA"; person "$CRED"
body myself.json <<'EOF'
{"accountId":"1","displayName":"Ada Lovelace"}
EOF
route GET rest/api/2/myself 200 myself.json
out=$(run status); check "status: exit 0" "$?" 0
check "status: kind, site, who" "$out" 'jira https://example.atlassian.net as Ada Lovelace'
hasnt "the token is never in argv" "$(cat "$FAKE/argv")" s3cret
hasnt "the auth header is never in argv" "$(cat "$FAKE/argv")" Authorization
has "basic auth goes in the curl config on stdin" "$(cat "$FAKE/stdin")" "Authorization: Basic $(printf 'ada@example.com:s3cret-token' | base64 | tr -d '\n')"
hasnt "no redirect is followed" "$(cat "$FAKE/argv")" ' -L'

unset HI_TEST_TOKEN
person '{"trackers": {"example.atlassian.net": {"email": "ada@example.com", "token_env": "HI_TEST_TOKEN", "token_command": "printf from-command"}}}'
reset; route GET rest/api/2/myself 200 myself.json
run status >/dev/null; check "token_command when the env var is unset" "$?" 0
has "token_command's token is used" "$(cat "$FAKE/stdin")" "$(printf 'ada@example.com:from-command' | base64 | tr -d '\n')"
person '{"trackers": {"example.atlassian.net": {"auth": "bearer", "token_command": "echo pat-1"}}}'
reset; route GET rest/api/2/myself 200 myself.json
run status >/dev/null; has "bearer auth" "$(cat "$FAKE/stdin")" 'Authorization: Bearer pat-1'
person '{"trackers": {"example.atlassian.net": {"email": "a@b", "token_command": "true"}}}'
run status 2>/dev/null; check "a token_command that prints nothing → exit 1" "$?" 1
export HI_TEST_TOKEN=s3cret-token
person "$CRED"

body e401.json <<'EOF'
{"message":"Client must be authenticated"}
EOF
reset; route GET rest/api/2/myself 401 e401.json
run status 2>"$T/err"; check "401 → exit 2" "$?" 2
hasnt "the rejection never prints the token" "$(cat "$T/err")" s3cret
reset
run status 2>"$T/err"; check "an unknown route (HTTP 404) → exit 5" "$?" 5

team '{"tracker": {"kind": "jira", "base_url": "http://example.atlassian.net"}}'
reset; route GET rest/api/2/myself 200 myself.json
run status 2>"$T/err"; check "plain http → exit 4" "$?" 4
check "plain http: nothing is sent" "$([ -s "$FAKE/req" ] && echo sent || echo none)" none
person '{"trackers": {"example.atlassian.net": {"email": "a@b", "token_env": "HI_TEST_TOKEN", "allow_http": true}}}'
run status >/dev/null; check "plain http with allow_http" "$?" 0
team "$JIRA"; person "$CRED"

team '{"tracker": {"kind": "jira", "base_url": "https://example.atlassian.net", "statuses": {"Open": "started"}}}'
run status 2>"$T/err"; check "an unknown role in tracker.statuses → exit 4" "$?" 4
team "$JIRA"

body search.json <<'EOF'
{"issues":[
 {"key":"AB-1","fields":{"summary":"First","status":{"name":"To Do","statusCategory":{"key":"new"}},"updated":"2026-01-01T10:00:00.000+0000","created":"2026-01-01T09:00:00.000+0000","labels":["auto"]}},
 {"key":"AB-2","fields":{"summary":"Second","status":{"name":"In Review","statusCategory":{"key":"indeterminate"}},"updated":"2026-01-02T10:00:00.000+0000","labels":[]}},
 {"key":"AB-3","fields":{"summary":"Third","status":{"name":"Blocked","statusCategory":{"key":"indeterminate"}},"updated":"2026-01-03T10:00:00.000+0000"}},
 {"key":"AB-4","fields":{"summary":"Fourth","status":{"name":"reopened","statusCategory":{"key":"indeterminate"}},"updated":"2026-01-04T10:00:00.000+0000"}}
],"isLast":true}
EOF
reset; route POST rest/api/3/search/jql 200 search.json
out=$(run sections); check "sections: exit 0" "$?" 0
check "sections: one line per ticket" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 4
check "todo → later, not started" "$(printf '%s\n' "$out" | jq -r 'select(.key == "AB-1") | "\(.group)|\(.next)|\(.role)"')" 'later|not started|todo'
check "in_review → others" "$(printf '%s\n' "$out" | jq -r 'select(.key == "AB-2") | .group')" others
check "an unmapped status: role from its category" "$(printf '%s\n' "$out" | jq -r 'select(.key == "AB-3") | "\(.role)|\(.group)"')" 'active|you'
check "status names match without case" "$(printf '%s\n' "$out" | jq -r 'select(.key == "AB-4") | .role')" bounced
check "title, url, since" "$(printf '%s\n' "$out" | jq -r 'select(.key == "AB-1") | "\(.title)|\(.url)|\(.since)"')" \
  'AB-1 · First — To Do|https://example.atlassian.net/browse/AB-1|2026-01-01T10:00:00.000+0000'
jql=$(head -1 "$FAKE/req" | sed 's/^POST [^ ]* //' | jq -r '.jql' 2>/dev/null)
has "sections JQL: mine" "$jql" 'assignee = currentUser()'
has "sections JQL: the projects" "$jql" 'project in ("AB")'
has "sections JQL: not the done statuses" "$jql" 'status not in ("Done")'

# Data Center has no search/jql: the v2 search, paged by startAt.
body search2.json <<'EOF'
{"startAt":0,"total":1,"issues":[{"key":"AB-9","fields":{"summary":"Old","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}}}]}
EOF
body e404.json <<'EOF'
{"errorMessages":["Not found"]}
EOF
reset; route POST rest/api/3/search/jql 404 e404.json; route POST rest/api/2/search 200 search2.json
out=$(run sections); check "v2 search when search/jql is missing" "$(printf '%s' "$out" | jq -r .key)" AB-9

reset; route POST rest/api/3/search/jql 200 search.json
out=$(run candidates auto); check "candidates: exit 0" "$?" 0
check "candidates: role todo only" "$(printf '%s\n' "$out" | jq -r .key | tr '\n' ' ')" 'AB-1 '
check "candidates: the autostart shape" "$(printf '%s\n' "$out" | jq -c 'keys')" '["created","key","title","url"]'
jql=$(head -1 "$FAKE/req" | sed 's/^POST [^ ]* //' | jq -r '.jql')
has "candidates JQL: the label" "$jql" 'labels = "auto"'
has "candidates JQL: the todo statuses" "$jql" 'status in ("To Do")'
team '{"tracker": {"kind": "jira", "base_url": "https://example.atlassian.net", "query": "sprint in openSprints()"}}'
reset; route POST rest/api/3/search/jql 200 search.json
run candidates 'it"s' >/dev/null
jql=$(head -1 "$FAKE/req" | sed 's/^POST [^ ]* //' | jq -r '.jql')
has "a quote in a label is escaped" "$jql" 'labels = "it\"s"'
has "no todo statuses: the To Do category" "$jql" 'statusCategory = "To Do"'
has "tracker.query is ANDed in" "$jql" '(sprint in openSprints())'
team "$JIRA"

body issue.json <<'EOF'
{"key":"AB-1","fields":{"summary":"First","status":{"name":"To Do","statusCategory":{"key":"new"}},"labels":["auto"],
 "assignee":{"displayName":"Ada Lovelace"},"description":"Do the thing.",
 "comment":{"comments":[{"author":{"displayName":"Bob"},"created":"2026-01-02T00:00:00.000+0000","body":"Please hurry."}]}}}
EOF
reset; route GET rest/api/2/issue/AB-1 200 issue.json
out=$(run read AB-1); check "read: exit 0" "$?" 0
check "read: normalized" "$(printf '%s' "$out" | jq -r '"\(.key)|\(.role)|\(.assignee)|\(.description)|\(.comments[0].author): \(.comments[0].body)"')" \
  'AB-1|todo|Ada Lovelace|Do the thing.|Bob: Please hurry.'
run read 'AB-1;rm' 2>/dev/null; check "read: a bad key → exit 3" "$?" 3

body trans.json <<'EOF'
{"transitions":[
 {"id":"11","name":"Start","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},
 {"id":"21","name":"Send to review","to":{"name":"In Review","statusCategory":{"key":"indeterminate"}}},
 {"id":"31","name":"Close","to":{"name":"Done","statusCategory":{"key":"done"}},
  "fields":{"resolution":{"required":true,"name":"Resolution"},"customfield_9":{"required":true,"hasDefaultValue":true}}},
 {"id":"41","name":"Ship","to":{"name":"Shipped","statusCategory":{"key":"done"}},
  "fields":{"customfield_7":{"required":true,"name":"Release"}}}]}
EOF
body empty.json <<'EOF'
{}
EOF
reset; route GET 'issue/AB-1?' 200 issue.json; route GET transitions 200 trans.json; route POST transitions 204 empty.json
out=$(run move AB-1 in_review); check "move: exit 0" "$?" 0
check "move: says from and to" "$out" 'AB-1: To Do → In Review'
check "move: the transition into a status of that role" "$(grep '^POST' "$FAKE/req" | sed 's/^POST [^ ]* //' | jq -c .)" '{"transition":{"id":"21"}}'
reset; route GET 'issue/AB-1?' 200 issue.json; route GET transitions 200 trans.json; route POST transitions 204 empty.json
run move AB-1 done >/dev/null
check "move: the role's fields go with it" "$(grep '^POST' "$FAKE/req" | sed 's/^POST [^ ]* //' | jq -c .)" \
  '{"transition":{"id":"31"},"fields":{"resolution":{"name":"Fixed"}}}'
team '{"tracker": {"kind": "jira", "base_url": "https://example.atlassian.net", "transitions": {"done": "Ship"}}}'
reset; route GET 'issue/AB-1?' 200 issue.json; route GET transitions 200 trans.json; route POST transitions 204 empty.json
run move AB-1 done 2>"$T/err"; check "move: a required field not configured → exit 5" "$?" 5
has "move: names the missing field" "$(cat "$T/err")" 'customfield_7 (Release)'
check "move: nothing is posted" "$(grep -c '^POST' "$FAKE/req")" 0
team "$JIRA"
reset; route GET 'issue/AB-1?' 200 issue.json; route GET transitions 200 trans.json
run move AB-1 testing 2>"$T/err"; check "move: no transition to the role → exit 5" "$?" 5
has "move: lists the transitions there are" "$(cat "$T/err")" 'Send to review → In Review'
reset; route GET 'issue/AB-1?' 200 issue.json
out=$(run move AB-1 todo); check "move: already in the role does nothing" "$out" 'AB-1: already todo (To Do)'
run move AB-1 shipped 2>/dev/null; check "move: an unknown role → exit 3" "$?" 3

reset; route POST 'issue/AB-1/comment' 201 empty.json
out=$(printf '(agent) Done in abc123.' | run comment AB-1); check "comment: exit 0" "$?" 0
check "comment: the body" "$(grep '^POST' "$FAKE/req" | sed 's/^POST [^ ]* //' | jq -r .body)" '(agent) Done in abc123.'
printf '' | run comment AB-1 2>/dev/null; check "comment: an empty body → exit 3" "$?" 3

# ---------------------------------------------------------------- youtrack
YT='{"tracker": {"kind": "youtrack", "base_url": "https://youtrack.example.com", "projects": ["AB", "Big Project"],
  "statuses": {"Open": "todo", "In Progress": "active", "In Review": "in_review", "Fixed": "done"}}}'
team "$YT"; person '{"trackers": {"youtrack.example.com": {"token_env": "HI_TEST_TOKEN"}}}'
body ytme.json <<'EOF'
{"login":"ada","fullName":"Ada Lovelace"}
EOF
reset; route GET api/users/me 200 ytme.json
out=$(run status); check "youtrack status" "$out" 'youtrack https://youtrack.example.com as Ada Lovelace'
has "youtrack: bearer by default" "$(cat "$FAKE/stdin")" 'Authorization: Bearer s3cret-token'

body ytissues.json <<'EOF'
[{"idReadable":"AB-5","summary":"Five","created":1767225600000,"updated":1767312000000,"resolved":null,"tags":[{"name":"auto"}],
  "customFields":[{"name":"State","value":{"name":"Open"}},{"name":"Assignee","value":{"login":"ada","fullName":"Ada Lovelace"}}]},
 {"idReadable":"AB-6","summary":"Six","created":1767225600000,"updated":1767312000000,"resolved":null,"tags":[],
  "customFields":[{"name":"State","value":{"name":"In Review"}}]},
 {"idReadable":"AB-7","summary":"Seven","created":1767225600000,"updated":1767312000000,"resolved":1767312000000,"tags":[],
  "customFields":[{"name":"State","value":{"name":"Won't fix"}}]}]
EOF
reset; route GET api/issues 200 ytissues.json
out=$(run sections); check "youtrack sections: exit 0" "$?" 0
check "youtrack: resolved and unmapped → done, left out" "$(printf '%s\n' "$out" | jq -r .key | tr '\n' ' ')" 'AB-5 AB-6 '
check "youtrack: role, url, since in ISO" "$(printf '%s\n' "$out" | jq -r 'select(.key == "AB-5") | "\(.role)|\(.url)|\(.since)"')" \
  'todo|https://youtrack.example.com/issue/AB-5|2026-01-02T00:00:00Z'
has "youtrack sections query" "$(cat "$FAKE/req")" 'query=for: me #Unresolved project: AB, {Big Project}'
reset; route GET api/issues 200 ytissues.json
out=$(run candidates auto); check "youtrack candidates" "$(printf '%s\n' "$out" | jq -r .key | tr '\n' ' ')" 'AB-5 '
has "youtrack candidates query" "$(cat "$FAKE/req")" 'query=tag: auto State: Open project: AB, {Big Project}'
team '{"tracker": {"kind": "youtrack", "base_url": "https://youtrack.example.com"}}'
run candidates auto 2>/dev/null; check "youtrack candidates with no todo state → exit 4" "$?" 4
team "$YT"

body ytissue.json <<'EOF'
{"idReadable":"AB-5","summary":"Five","resolved":null,"customFields":[{"name":"State","value":{"name":"Open"}},{"name":"Assignee","value":{"login":"ada","fullName":"Ada Lovelace"}}],
 "description":"Body.","comments":[{"text":"Hi.","created":1767312000000,"author":{"login":"bob","fullName":"Bob"}}]}
EOF
reset; route GET api/issues/AB-5 200 ytissue.json
out=$(run read AB-5)
check "youtrack read" "$(printf '%s' "$out" | jq -r '"\(.role)|\(.assignee)|\(.description)|\(.comments[0].author)|\(.comments[0].created)"')" \
  'todo|Ada Lovelace|Body.|Bob|2026-01-02T00:00:00Z'
reset; route GET api/issues/AB-5 200 ytissue.json; route POST api/commands 200 empty.json
out=$(run move AB-5 in_review); check "youtrack move: exit 0" "$?" 0
check "youtrack move: a state command" "$(grep '^POST' "$FAKE/req" | sed 's/^POST [^ ]* //; s/ *$//' | jq -c .)" \
  '{"query":"State {In Review}","issues":[{"idReadable":"AB-5"}]}'
reset; route POST api/issues/AB-5/comments 200 empty.json
printf 'Hello' | run comment AB-5 >/dev/null
check "youtrack comment" "$(grep '^POST' "$FAKE/req" | sed 's/^POST [^ ]* //; s/ *$//' | jq -c .)" '{"text":"Hello"}'

# ---------------------------------------------------------------- github
# Fake gh: logs its argv; answers from $FAKE/gh-<first two args>.json.
cat >"$T/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE/gh"
case "$1 $2" in
  "issue list") cat "$FAKE/gh-list.json" ;;
  "issue view") cat "$FAKE/gh-view.json" ;;
  "api user") echo ada ;;
  "repo view") echo '{"name":"widgets"}' ;;
  "issue comment") cat >"$FAKE/gh-comment"; echo https://github.com/acme/widgets/issues/3#c1 ;;
  "issue edit"|"issue close"|"issue reopen") : ;;
  *) echo "unknown: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
team '{"tracker": {"kind": "github", "statuses": {"in-progress": "active", "in-review": "in_review", "needs-decision": "waiting"}}}'
person '{}'
cat >"$FAKE/gh-list.json" <<'EOF'
[{"number":3,"title":"Three","url":"https://github.com/acme/widgets/issues/3","state":"OPEN","labels":[{"name":"bug"},{"name":"In-Progress"}],"updatedAt":"2026-01-03T00:00:00Z","createdAt":"2026-01-01T00:00:00Z"},
 {"number":4,"title":"Four","url":"https://github.com/acme/widgets/issues/4","state":"OPEN","labels":[{"name":"auto"}],"updatedAt":"2026-01-04T00:00:00Z","createdAt":"2026-01-02T00:00:00Z"}]
EOF
rm -f "$FAKE/gh"
out=$(run sections); check "github sections: exit 0" "$?" 0
check "github: the key is <repo>-<n>" "$(printf '%s\n' "$out" | jq -r .key | tr '\n' ' ')" 'widgets-3 widgets-4 '
check "github: a role label sets the role" "$(printf '%s\n' "$out" | jq -r 'select(.key == "widgets-3") | "\(.role)|\(.status)"')" 'active|In-Progress'
check "github: no role label → todo" "$(printf '%s\n' "$out" | jq -r 'select(.key == "widgets-4") | .role')" todo
has "github sections: mine, in the origin's repo" "$(cat "$FAKE/gh")" 'issue list -R acme/widgets --assignee @me --state open'
out=$(run candidates auto); check "github candidates" "$(printf '%s\n' "$out" | jq -r .key | tr '\n' ' ')" 'widgets-4 '
run read other-3 2>/dev/null; check "github read: another repo's key → exit 3" "$?" 3
cat >"$FAKE/gh-view.json" <<'EOF'
{"number":3,"title":"Three","url":"https://github.com/acme/widgets/issues/3","state":"OPEN","labels":[{"name":"in-progress"}],"body":"Text.","assignees":[{"login":"ada"}],"comments":[{"author":{"login":"bob"},"createdAt":"2026-01-05T00:00:00Z","body":"Ok."}]}
EOF
out=$(run read widgets-3)
check "github read" "$(printf '%s' "$out" | jq -r '"\(.role)|\(.assignee)|\(.description)|\(.comments[0].author)"')" 'active|ada|Text.|bob'
rm -f "$FAKE/gh"
out=$(run move widgets-3 in_review); check "github move: exit 0" "$?" 0
has "github move: swaps the role labels" "$(cat "$FAKE/gh")" 'issue edit 3 -R acme/widgets --add-label in-review --remove-label in-progress'
rm -f "$FAKE/gh"; run move widgets-3 done >/dev/null
has "github move to done: closes" "$(cat "$FAKE/gh")" 'issue close 3 -R acme/widgets'
run move widgets-3 testing 2>/dev/null; check "github move: a role with no label → exit 4" "$?" 4
printf 'Note.' | run comment widgets-3 >/dev/null
check "github comment: the body on stdin" "$(cat "$FAKE/gh-comment")" 'Note.'

# ---------------------------------------------------------------- crew.sh {{TRACKER}}
team '{"tracker": {"kind": "github"}, "agenda": {"sections": [{"name": "tickets", "command": "{{TRACKER}} sections"}]},
  "crew": {"process": "Read the ticket: {{TRACKER}} read {{KEY}}"}}'
out=$(cd "$T/root" && bash "$C" sections | jq -c 'select(.section == "tickets")')
check "agenda.sections: {{TRACKER}} runs the adapter" "$(printf '%s\n' "$out" | jq -r .key | tr '\n' ' ')" 'widgets-3 widgets-4 '
out=$(cd "$T/root" && bash "$C" spec --key widgets-3 --title Three)
has "crew.process: {{TRACKER}} and {{KEY}} filled" "$out" "tracker.sh' --root '$(cd "$T/root" && git rev-parse --show-toplevel)' read widgets-3"
team '{"tracker": {"kind": "jira", "base_url": "https://example.atlassian.net"}, "agenda": {"sections": [{"name": "tickets", "command": "{{TRACKER}} sections"}]}}'
out=$(cd "$T/root" && bash "$C" sections | jq -c 'select(.section == "tickets")')
has "a failing adapter shows as the section's error" "$(printf '%s' "$out" | jq -r .error)" 'no credential for example.atlassian.net'

exit $fail
