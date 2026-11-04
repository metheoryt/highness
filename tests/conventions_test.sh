#!/usr/bin/env bash
# Nothing private leaks into a public repo: owner, companies, hosts, private paths; and the
# us plugin highness was extracted from is never referenced (highness never depends on it).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAT='pagapay|jared|\boleg\b|\bcharlie\b|\bsierra\b|\bromeo\b|\balisa\b|\bMaxim\b|cyphy|qaz-code|personality/|0ccfa30e|paga\.team|thepureapp|\bpure\b|\bPure\b|backend-api|\bCFT-[0-9]|metheoryt/us\b|\$HOME/my/|~/my/|/Users/me\b|~/machines|\$HOME/machines|\bg15\b|\bg16\b|\bxps\b|\bus:[a-z]|asks\.sh|journal\.sh|profile\.sh|Romanyuk|romanyuk'
hits=$(cd "$ROOT" && git ls-files -co --exclude-standard | grep -v -E '^tests/conventions_test\.sh$' | while IFS= read -r f; do [ -f "$f" ] && grep -nHE "$PAT" "$f"; done)
# Self-check: the grep in use must understand the pattern (\b, alternation), or the scan passes vacuously.
probe=$(printf 'see backend-api\nStatus: ok\nrun /us:review\n' | grep -cE "$PAT")
[ "$probe" = 2 ] || { echo "  FAIL self-check: the pattern matched $probe of 2 known-bad lines (grep: $(command -v grep))"; exit 1; }
if [ -n "$hits" ]; then printf '  FAIL private names:\n%s\n' "$hits" | head -60; exit 1; fi
echo '  ok   no private names'
