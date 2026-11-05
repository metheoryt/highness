#!/usr/bin/env bash
# hi-docs: every skill has frontmatter, names nothing outside highness, and every
# reference/... or lib/... path it names exists in the plugin. bash 3.2 compatible.
set -uo pipefail
PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; rc=1; }

n=0
for f in "$PLUGIN"/skills/*/SKILL.md; do
  [ -e "$f" ] || continue
  n=$((n + 1))
  rel=${f#"$PLUGIN"/}

  # Frontmatter: first line '---', then name: and description: before the closing '---'.
  fm=$(awk 'NR==1 { if ($0 != "---") exit; next } /^---$/ { exit } { print }' "$f")
  if printf '%s\n' "$fm" | grep -q '^name: [^ ]' && printf '%s\n' "$fm" | grep -q '^description: [^ ]'; then
    ok "$rel frontmatter has name and description"
  else
    fail "$rel frontmatter lacks name or description"
  fi
done
[ "$n" -gt 0 ] || fail "no skills/*/SKILL.md found"


# Every reference/... and lib/... path a skill names exists in the plugin.
for f in "$PLUGIN"/skills/*/SKILL.md; do
  [ -e "$f" ] || continue
  rel=${f#"$PLUGIN"/}
  paths=$(grep -oE '(reference|lib)/[A-Za-z0-9_./-]+' "$f" | sed -e 's/[.]*$//' | sort -u)
  [ -n "$paths" ] || continue
  for p in $paths; do
    if [ -e "$PLUGIN/$p" ]; then ok "$rel -> $p exists"; else fail "$rel -> $p missing from the plugin"; fi
  done
done


# The rules the skills stand on stay in their text (a rewrite of a skill must not drop them).
has() { if grep -qF -- "$3" "$PLUGIN/skills/$1/SKILL.md"; then ok "$1: $2"; else fail "$1: $2 (missing: $3)"; fi; }
has write-doc 'loads the user'"'"'s own calls' 'read them in full before composing'
has write-doc 'declare the reader' 'Reader: <a named person or role>'
has write-doc 'grounding of identifiers' 'An identifier never stands alone.'
has write-doc 'claim before evidence' 'Evidence last, on one line'
has write-doc 'no fact lost in a rewrite' 'never adds or drops a fact'
has write-doc 'cut file for removed passages' 'What a rewrite removes goes to a cut file.'
has write-doc 'fact diff against the cut file' 'A fact in neither is a defect'
has write-doc 'claims checked in the written text' 'checked against the code, in the text you wrote'
has write-doc 'stable external identifiers' 'stay stable'
has write-doc 'team conventions from config' 'get .docs.conventions'
has write-doc 'the team'"'"'s own check before review' 'The team'"'"'s own check.'
has write-doc 'ends with the reader test' '/hi-docs:reader-test'
has reader-test 'no author context' 'Never pass the author'"'"'s notes'
has reader-test 'expected answers first' 'Write down the answer you expect'
has reader-test 'expert calibration' 'Calibrate to the reader.'
has reader-test 'bounded rounds' 'after three rounds'

exit $rc
