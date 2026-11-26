#!/usr/bin/env bash
# lib/brief.sh: the PR through the team's adapter (its argument quoted, its stderr kept out of the
# JSON) or through gh, the lens from the team and from the person, and the journal (bad kinds and
# outcomes refused, the last word on an item wins). No network: a stub gh (HI_REVIEW_GH).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B="$HERE/../lib/brief.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HIGHNESS_CONFIG="$T/user.json" HIGHNESS_STATE="$T/state" GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$HOME"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }

git init -q "$T/team" && mkdir -p "$T/team/.claude"
cd "$T/team" || exit 1
echo '{}' >"$HIGHNESS_CONFIG"

# --- source through the team adapter
cat >"$T/adapter.sh" <<'EOF'
printf 'arg=[%s]\n' "$1" >&2
printf '%s' "$1" >"$(dirname "$0")/seen"
jq -n --arg n "$1" '{repo: "acme/api", number: 7, title: "T", author: "ann", state: "open", draft: false,
  diff: "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n", reviews: [{author: "bob", bot: false, state: "COMMENT", body: "hm"}],
  threads: [], comments: []}'
EOF
jq -n --arg c "bash $T/adapter.sh {{PR}}" '{review: {brief: {source: $c}}}' >.claude/highness.json
out=$(bash "$B" source "7; rm -rf x" 2>"$T/err"); rc=$?
check 'adapter source exits 0' "$rc" 0
check 'the argument reaches the adapter as one quoted word' "$(cat "$T/seen")" '7; rm -rf x'
json=$(printf '%s' "$out" | cut -f1); diff=$(printf '%s' "$out" | cut -f2)
check 'the JSON file has no diff' "$(jq -r 'has("diff")' "$json")" false
check 'the diff file holds the diff' "$(sed -n 2p "$diff")" '+++ b/x'
has 'the summary names the PR' "$(printf '%s' "$out" | cut -f3)" 'acme/api#7 open · T · by ann · 1 reviews'

echo 'echo not json' >"$T/adapter.sh"
bash "$B" source 7 >/dev/null 2>"$T/err"; check 'bad adapter output: exit 3' "$?" 3
has 'bad adapter output is said' "$(cat "$T/err")" 'not a PR object'
echo 'echo boom >&2; exit 4' >"$T/adapter.sh"
bash "$B" source 7 >/dev/null 2>"$T/err"; check 'failing adapter: exit 3' "$?" 3
has 'the adapter error is shown' "$(cat "$T/err")" 'exit 4): boom'

# --- source through gh
cat >"$T/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo '{"number":3,"title":"G","body":null,"author":{"login":"ann"},"url":"https://github.com/acme/web/pull/3","state":"OPEN","isDraft":true,"headRefOid":"abc","baseRefName":"main"}' ;;
  "pr diff") printf -- '--- a/y\n+++ b/y\n' ;;
  "api --paginate")
    case "$3" in
      */reviews) echo '[{"user":{"login":"bob","type":"User"},"state":"COMMENTED","body":"b","submitted_at":"t"},{"user":{"login":"me","type":"User"},"state":"PENDING","body":"draft"}]' ;;
      */pulls/3/comments) echo '[{"id":1,"path":"y","line":2,"user":{"login":"lint-helper","type":"User"},"body":"x","created_at":"t","html_url":"u1"}]'
                          echo '[{"id":2,"in_reply_to_id":1,"path":"y","line":2,"user":{"login":"ann","type":"User"},"body":"ok","created_at":"t","html_url":"u2"}]' ;;
      */issues/3/comments) echo '[{"user":{"login":"ci[bot]","type":"Bot"},"body":"green","created_at":"t"}]' ;;
    esac ;;
esac
EOF
chmod +x "$T/gh"
echo '{"review": {"bots": ["lint-helper"]}}' >.claude/highness.json
out=$(HI_REVIEW_GH="$T/gh" bash "$B" source 3); rc=$?
check 'gh source exits 0' "$rc" 0
json=$(printf '%s' "$out" | cut -f1)
check 'gh: repo from the url' "$(jq -r .repo "$json")" acme/web
check 'gh: state lowercased, draft kept' "$(jq -r '"\(.state) \(.draft)"' "$json")" 'open true'
check 'gh: a pending review is left out' "$(jq '.reviews | length' "$json")" 1
check 'gh: a reply joins its thread across pages' "$(jq -c '[.threads[] | .comments | length]' "$json")" '[2]'
check 'gh: a review.bots login is a bot' "$(jq '.threads[0].comments[0].bot' "$json")" true
check 'gh: a Bot account is a bot' "$(jq '.comments[0].bot' "$json")" true

# --- lens
echo '{}' >.claude/highness.json
bash "$B" lens >/dev/null 2>&1; check 'no lens: exit 1' "$?" 1
jq -n '{review: {brief: {lens: "[ -z {{LOGIN}} ] && echo mine || echo of {{LOGIN}}"}}}' >.claude/highness.json
check 'team lens' "$(bash "$B" lens)" "# source: team
mine"
check 'someone else s lens' "$(bash "$B" lens --login bob)" "# source: team
of bob"
jq -n '{review: {brief: {lens: "echo NEED_TOKEN >&2; exit 1"}}}' >.claude/highness.json
bash "$B" lens >/dev/null 2>"$T/err"; check 'failing lens command: exit 1' "$?" 1
has 'a failing lens command is said' "$(cat "$T/err")" "the team's command failed: NEED_TOKEN"
jq -n '{review: {brief: {lens: "[ -z {{LOGIN}} ] && echo mine || echo of {{LOGIN}}"}}}' >.claude/highness.json
printf 'design first\n' >"$HOME/lens.md"
echo '{"review": {"lens": "~/lens.md"}}' >"$HIGHNESS_CONFIG"
has 'personal lens from a file' "$(bash "$B" lens)" "# source: personal
design first"
check 'the personal lens is never someone else s' "$(bash "$B" lens --login bob | grep -c personal)" 0

# --- journal
bash "$B" log --pr p#1 --item 1 --kind lens --outcome skipped --title a
bash "$B" log --pr p#1 --item 1 --kind lens --outcome ticket
bash "$B" log --pr p#1 --item 2 --kind bold --outcome not_interesting
bash "$B" log --pr p#2 --item 0 --kind empty --outcome skipped
bash "$B" log --pr p#2 --item 1 --kind finding --outcome change --title f
bash "$B" log --pr p#2 --item 1 --kind nope --outcome ticket 2>/dev/null; check 'unknown kind: exit 2' "$?" 2
bash "$B" log --pr p#2 --item 1 --kind lens --outcome meh 2>/dev/null; check 'unknown outcome: exit 2' "$?" 2
check 'journal has five lines' "$(wc -l <"$(bash "$B" journal)" | tr -d ' ')" 5
s=$(bash "$B" stats)
has 'stats: PRs and items' "$s" 'briefs: 2 PRs, 2 items, 1 empty'
has 'stats: the last outcome wins' "$s" 'led somewhere: 1 of 2 (50%)'
has 'stats: by kind' "$s" 'lens: ticket 1'
has 'stats: findings apart' "$s" 'findings: 1, acted on: 1 of 1 (100%)'
has 'stats: findings by kind' "$s" 'finding: change 1'
has 'stats --since filters' "$(bash "$B" stats --since 2999-01-01)" 'briefs: 0 PRs'

exit $fail
