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

# The reviewer is read-only by its tool list, not only by its prose.
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
has $S 'quick is the only mode, the seams say so' 'Quick is the only mode this version serves'
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

exit $rc
