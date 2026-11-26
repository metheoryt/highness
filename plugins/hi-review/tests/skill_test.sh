#!/usr/bin/env bash
# hi-review: the skill and the agent have frontmatter, every reference/... and lib/... path they
# name exists in the plugin, the reviewer cannot write, and the rules the review stands on stay in
# the text (a rewrite must not drop them). bash 3.2 compatible.
set -uo pipefail
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; rc=1; }

fm() { awk 'NR==1 { if ($0 != "---") exit; next } /^---$/ { exit } { print }' "$1"; }

for f in "$PLUGIN"/skills/*/SKILL.md "$PLUGIN"/agents/*.md; do
  [ -e "$f" ] || { fail "no skill or agent at $f"; continue; }
  rel=${f#"$PLUGIN"/}
  if fm "$f" | grep -q '^name: [^ ]' && fm "$f" | grep -q '^description: [^ ]'; then
    ok "$rel frontmatter has name and description"
  else
    fail "$rel frontmatter lacks name or description"
  fi
  paths=$(grep -oE '(reference|lib)/[A-Za-z0-9_./-]+' "$f" | sed -e 's/[.]*$//' | sort -u)
  for p in $paths; do
    if [ -e "$PLUGIN/$p" ]; then ok "$rel -> $p exists"; else fail "$rel -> $p missing from the plugin"; fi
  done
done

# The reviewer has no tool that writes a file or starts another agent. It keeps Bash (git diff,
# git show), so no checkout and no posting rest on its prose, which the has-checks below pin.
tools=$(fm "$PLUGIN/agents/reviewer.md" | sed -n 's/^tools: //p')
case "$tools" in *Bash*) ok 'reviewer has Bash (git diff, git show)' ;; *) fail 'reviewer lacks Bash' ;; esac
for t in Edit Write NotebookEdit Agent; do
  if printf '%s' "$tools" | tr ',' '\n' | sed 's/^ *//' | grep -qx "$t"; then fail "reviewer can $t"; else ok "reviewer has no $t"; fi
done

# The skill names the agent by its plugin-qualified name.
grep -qF 'subagent_type: "hi-review:reviewer"' "$PLUGIN/skills/review/SKILL.md" \
  && ok 'skill calls hi-review:reviewer' || fail 'skill does not call hi-review:reviewer'

has() { if grep -qF -- "$3" "$PLUGIN/$1"; then ok "$1: $2"; else fail "$1: $2 (missing: $3)"; fi; }
S=skills/review/SKILL.md A=agents/reviewer.md
has $S 'quick and deep serve, quick by default' 'Quick (this session, no workspace) and deep serve; quick is the default.'
has $S 'deep follows deep.md' 'follow its coordinator part'
has $S 'delta still says it is not built' 'delta is not built yet'
DP=reference/deep.md
has $DP 'deep reuses hi-crew, not a copy' 'The machinery is hi-crew'"'"'s'
has $DP 'one worker per PR' 'never a second'
has $DP 'the workspace from wt.sh' '"$W" create --kind review'
has $DP 'started through crew.sh dispatch' 'bash "$C" dispatch "$KEY" --kind review'
has $DP 'answered through relay only' 'the only way a worker is answered'
has $DP 'the post is an action on the person yes' 'the post runs once, here'
has $DP 'the coordinator checks each action' 'One that is anything'
has $DP 'slices fan out in one message' 'launched in one message (at most six at a time'
has $DP 'deep verify is fresh too' 'the verify subagents fresh, never a drafting'
has $DP 'submit posts only what the cards showed' 'posts only what the cards showed'
has $DP 'a taken-over session asks here' 'Taken over.'
has reference/deep-task.md 'the task asks for subagents' 'This task asks for subagents'
has reference/deep-task.md 'the worker never posts' 'never by you'
has $A 'a slice anchors on its own paths' 'Anchor findings only on lines of these'
has $S 'own PR stops' 'own mode (checking your own PR) is not'
has $S 'nothing checked out' 'Nothing is checked out.'
has $S 'intent miss is said' 'findings are'
has $S 'a fresh verify pass' 'never the drafting one resumed'
has $S 'nothing unverified' 'Nothing reaches a card unverified.'
has $S 'an unverified blocking finding drops' "its \`blocking\` findings drop to \`note\`"
has $S 'anchors checked by the script' 'bash "$R" anchor'
has $S 'pending review re-checked before the write' 'Re-run step 7.3 right before the write.'
has $S 'one question' 'One `AskUserQuestion`'
has $S 'the answer is the approval' 'The answer is the approval to post'
has $S 'one call creates and submits' 'one call that creates and submits'
has $S 'never a silent retry' 'never retry'
has $S 'the person voice from user config only' 'get --user .review.voice'
has $S 'team intent from config' 'get .review.intent'
has $A 'read the head, not the checkout' 'HEAD_SHA:<path>'
has $A 'no check-out' 'never check out a ref'
has $A 'verify breaks, not agrees' 'not to agree with it'
has $A 'graph absence said first' 'graph: unavailable'
has $A 'unknown phase refused' 'is not served by this reviewer'
has reference/methodology.md 'asymmetry needs both sides' 'An asymmetry is a claim about code the diff did not touch.'
has reference/methodology.md 'resolved thread is not a fix' 'A resolved or outdated thread is a click, not a fix.'
has reference/voice.md 'one fix, not a menu' 'Name one fix, never a menu.'
has reference/voice.md 'person voice wins' 'wins where the two differ'
has reference/session.md 'only the chosen review is written' 'Nothing reaches GitHub unasked'

S=skills/brief/SKILL.md
has $S 'brief posts nothing' 'This skill posts nothing'
has $S 'brief defects are verified' 'Nothing reaches the person unverified'
has $S 'brief defects come after the items' 'after the items and set apart'
has $S 'a defect is never an item' 'never an item: defects go to step 5'
has $S 'view before the question' 'your own view and recommendation'
has $S 'context from zero' 'Context from zero'
has $S 'bold needs two citations' 'Without two citations, no'
has $S 'outside item keeps the lens wide' 'does not narrow'
has $S 'every item logged' 'every item without an outcome is logged'
has $S 'lens never written by the agent' 'Never write the lens yourself.'
has $S 'source through the script' 'bash "$B" source'

exit $rc
