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


exit $rc
