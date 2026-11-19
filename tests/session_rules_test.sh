#!/usr/bin/env bash
# Every skill opens with the session-rules gist and points at its own plugin's reference/session.md
# (a plugin is installed on its own, so it cannot point at a sibling's), and every session.md
# carries the language rule for a call with no words: the person's session.language.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
for s in "$ROOT"/plugins/*/skills/*/SKILL.md; do
  rel=${s#"$ROOT"/}
  plugin=${rel#plugins/}; plugin=${plugin%%/*}
  if ! grep -q '^\*\*Session rules\*\* (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`' "$s"; then
    echo "  FAIL $rel: no Session rules line pointing at reference/session.md"; fail=1
  fi
  if ! grep -q 'session\.language' "$s"; then
    echo "  FAIL $rel: the gist does not name session.language"; fail=1
  fi
  if [ ! -f "$ROOT/plugins/$plugin/reference/session.md" ]; then
    echo "  FAIL $rel: plugins/$plugin/reference/session.md does not exist"; fail=1
  fi
done
for f in "$ROOT"/plugins/*/reference/session.md; do
  rel=${f#"$ROOT"/}
  grep -qF 'bash "${CLAUDE_PLUGIN_ROOT}/lib/config.sh" get --user .session.language' "$f" && continue
  echo "  FAIL $rel: no session.language rule (config.sh get --user .session.language)"; fail=1
done
[ "$fail" = 0 ] && echo '  ok   every skill points at its session.md; every session.md reads session.language'
exit "$fail"
