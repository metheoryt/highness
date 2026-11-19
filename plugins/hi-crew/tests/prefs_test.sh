#!/usr/bin/env bash
# prefs.sh: resolving `preferences` (list, directory, unset), the spec's citation, the close-step
# proposal, diff/write, repeats and the team-rule draft.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$HERE/../lib/prefs.sh"
C="$HERE/../lib/crew.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# Every location the script reads or writes points into $T: the person's real config may name a
# live store, and the default file derives from XDG_CONFIG_HOME.
export HIGHNESS_STATE="$T/state" HIGHNESS_CONFIG="$T/user.json" XDG_CONFIG_HOME="$T/xdg" HOME="$T/home"
unset ORCA_CLI_COMMAND CLAUDE_CONFIG_DIR
mkdir -p "$HOME" "$HIGHNESS_STATE/crew"
fail=0
ok() { echo "  ok   $1"; }
no() { echo "  FAIL $1"; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1: [$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1: [$3] in [$2]" ;; *) ok "$1" ;; esac; }

command -v jq >/dev/null || { echo '  skip: no jq'; exit 0; }
DEF="$XDG_CONFIG_HOME/highness/preferences.md"
cfg() { printf '%s\n' "$1" >"$HIGHNESS_CONFIG"; }

# --- resolving
cfg '{}'
check 'unset: no file yet, nothing cited' "$(bash "$P" paths)" ''
check 'unset: the default file is the target' "$(bash "$P" targets)" "$DEF"
mkdir -p "$(dirname "$DEF")" && echo '# Mine' >"$DEF"
check 'unset: the default file once it exists' "$(bash "$P" paths)" "$DEF"

S="$T/store"; mkdir -p "$S/facets"
echo '# Values' >"$S/values.md"; echo '# Tone' >"$S/facets/tone.md"; echo 'not md' >"$S/notes.txt"
cfg '{"preferences": ["~/notes/how.md", "'"$S"'/values.md", "relative/x.md", "'"$S"'/missing.md"]}'
mkdir -p "$HOME/notes"; echo '# How' >"$HOME/notes/how.md"
check 'list: existing files, ~ expanded, in order' "$(bash "$P" paths 2>/dev/null)" "$HOME/notes/how.md
$S/values.md"
has 'list: a relative entry is skipped with a warning' "$(bash "$P" paths 2>&1 >/dev/null)" 'relative/x.md'
has 'list: a missing file is still a target' "$(bash "$P" targets 2>/dev/null)" "$S/missing.md"
has 'list: the default file stays a target' "$(bash "$P" targets 2>/dev/null)" "$DEF"

ln -s "$S" "$T/link"
cfg '{"preferences": "'"$T"'/link"}'
check 'directory through a symlink: its *.md files, sorted' "$(bash "$P" paths)" "$T/link/facets/tone.md
$T/link/values.md"

# A repo file cannot pick where lines are written.
R="$T/repo"; mkdir -p "$R/.claude"; git -C "$R" init -q
echo '{"preferences": "/etc/evil.md"}' >"$R/.claude/highness.json"
cfg '{}'
check 'a repo file setting preferences is ignored' "$(cd "$R" && bash "$P" targets)" "$DEF"

# --- the spec cites the files, never their text
cfg '{"preferences": ["'"$S"'/values.md"]}'
echo 'SECRET-PREF-TEXT' >>"$S/values.md"
spec=$(bash "$C" spec --key k-1 --title T --root "$R")
has 'spec names the preference file' "$spec" "\`$S/values.md\`"
hasnt 'spec does not inline its text' "$spec" 'SECRET-PREF-TEXT'
hasnt 'spec leaves no placeholder' "$spec" '{{PREFERENCES}}'
cfg '{"preferences": ["'"$S"'/missing.md"]}'
spec=$(bash "$C" spec --key k-1 --title T --root "$R")
hasnt 'no file: no preferences line' "$spec" "own preferences are in these files"
hasnt 'no file: no placeholder' "$spec" '{{PREFERENCES}}'
has 'no file: the ask still says leans on' "$spec" '`leans on:`'

# --- propose from a fixture choices.jsonl
cfg '{"preferences": ["'"$S"'/values.md", "'"$S"'/facets/tone.md"]}'
cat >"$HIGHNESS_STATE/crew/choices.jsonl" <<'EOF'
{"key":"p-1","at":"2026-11-01T10:00:00Z","question":null,"ask_body":"\nWhere does the retry live?\nmore text","options":[{"name":"A new script","loses":"one more file","leans_on":"values.md › Small diffs"},{"name":"In crew.sh","loses":"a wide diff","leans_on":"no rule: size"}],"took":"option","picked":"A new script","reply":"yes, VERBATIM-REPLY-ONE"}
{"key":"p-1","at":"2026-11-01T10:00:00Z","question":null,"took":null}
{"key":"p-2","at":"2026-11-03T10:00:00Z","question":"Where does the cache go?","options":[{"name":"a new script","loses":"x","leans_on":"values.md › Small diffs"}],"took":"option","picked":"a new script","reply":"ok VERBATIM-REPLY-TWO"}
{"key":"p-2","at":"2026-11-03T10:00:00Z","question":"Which tone?","options":[{"name":"Short","loses":"detail","leans_on":"tone.md › Answer first"}],"took":"option","picked":"Short","reply":"short"}
{"key":"p-3","at":"2026-11-04T10:00:00Z","question":"Name?","took":"own","picked":null,"reply":"call it relay"}
EOF
out=$(bash "$P" propose p-1)
has 'propose: grouped under the file the option leans on' "$out" "## $S/values.md"
has 'propose: the question falls back to the ask body' "$out" '- Where does the retry live?: chose A new script (leans on values.md › Small diffs) — p-1'
check 'propose: a null-took line gives nothing' "$(printf '%s\n' "$out" | grep -c '^- ')" 1
out=$(bash "$P" propose p-2)
has 'propose: tone.md option goes to tone.md' "$out" "## $S/facets/tone.md"
out=$(bash "$P" propose p-3)
has 'propose: an own answer is kept, to the first file' "$out" "## $S/values.md
- Name?: answered with their own option: call it relay — p-3"
check 'propose: a ticket with no choices gives nothing' "$(bash "$P" propose p-9)" ''

# --- diff writes nothing; write adds exactly that, once
F="$S/values.md"; printf '# Values\n\n## Small diffs\n\n- keep it narrow\n\n## Other\n\n- x\n' >"$F"
before=$(cat "$F")
printf -- '- prefer a new script to widening a shared one — p-1\n- keep it narrow\n' >"$T/lines"
d=$(bash "$P" diff "$F" "$T/lines" --under '## Small diffs')
has 'diff shows the new line' "$d" '+- prefer a new script to widening a shared one — p-1'
hasnt 'diff skips a line already there' "$d" '+- keep it narrow'
check 'diff leaves the file byte-identical' "$(cat "$F")" "$before"
bash "$P" write "$F" "$T/lines" --under '## Small diffs' >/dev/null
check 'write puts the line at the end of its section' "$(cat "$F")" '# Values

## Small diffs

- keep it narrow
- prefer a new script to widening a shared one — p-1

## Other

- x'
after=$(cat "$F")
check 'a second write changes nothing' "$(bash "$P" write "$F" "$T/lines" --under '## Small diffs')" 'nothing to add'
check 'a second write leaves the file as it was' "$(cat "$F")" "$after"
printf -- '- a fresh line\n' >"$T/lines3"
bash "$P" write "$F" "$T/lines3" --under '## New heading' >/dev/null
check 'a missing heading is added at the end' "$(tail -5 "$F")" '- x

## New heading

- a fresh line'
if bash "$P" write "$T/elsewhere.md" "$T/lines" 2>/dev/null; then no 'write refuses a file outside the targets'; else ok 'write refuses a file outside the targets'; fi
[ -e "$T/elsewhere.md" ] && no 'refused write created no file' || ok 'refused write created no file'
rm -f "$DEF"
bash "$P" write "$DEF" "$T/lines" >/dev/null
check 'write creates the default file' "$(cat "$DEF")" '- prefer a new script to widening a shared one — p-1
- keep it narrow'
ln -sf "$F" "$T/link.md"; cfg '{"preferences": ["'"$T"'/link.md"]}'
printf -- '- through a link\n' >"$T/lines2"
bash "$P" write "$T/link.md" "$T/lines2" >/dev/null
[ -L "$T/link.md" ] && ok 'write keeps a symlinked file a symlink' || no 'write keeps a symlinked file a symlink'
has 'write reaches the file behind the link' "$(cat "$F")" '- through a link'

# --- repeats and the team-rule draft
cfg '{"preferences": ["'"$S"'/values.md", "'"$S"'/facets/tone.md"]}'
rep=$(bash "$P" repeats)
has 'repeats: same preference line on two tickets' "$rep" "$(printf 'leans_on\tvalues md small diffs\t2\tp-1,p-2')"
has 'repeats: same picked option on two tickets' "$rep" "$(printf 'picked\ta new script\t2\tp-1,p-2')"
hasnt 'repeats: a one-ticket choice is not a repeat' "$rep" 'short'
check 'repeats --min 3: none' "$(bash "$P" repeats --min 3)" ''
echo '{"crew": {"team_rules": "docs/team-rules.md"}}' >"$R/.claude/highness.json"
dr=$(bash "$P" draft-rule leans_on 'values md small diffs' --root "$R")
check 'draft: target is the team rules file' "$(printf '%s\n' "$dr" | head -1)" 'target: docs/team-rules.md'
has 'draft: the rule line' "$dr" '- values.md › Small diffs'
has 'draft: the evidence names both tickets' "$dr" 'p-1, p-2'
has 'draft: one row per choice' "$dr" '| p-2 | 2026-11-03 | Where does the cache go? | a new script |'
hasnt 'draft: never the verbatim reply' "$dr" 'VERBATIM-REPLY'
hasnt 'draft: never a home path' "$dr" "$HOME"
echo '{}' >"$R/.claude/highness.json"
check 'draft: no team rules file says none' "$(bash "$P" draft-rule picked 'a new script' --root "$R" | head -1)" 'target: none'
if bash "$P" draft-rule picked 'never chosen' --root "$R" 2>/dev/null; then no 'draft refuses an unknown choice'; else ok 'draft refuses an unknown choice'; fi

exit "$fail"
