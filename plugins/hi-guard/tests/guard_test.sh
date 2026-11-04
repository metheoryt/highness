#!/usr/bin/env bash
# guard.sh pretool — hi-guard's PreToolUse hook. Every payload goes in as the JSON Claude Code
# sends; allow is no stdout + exit 0, deny/ask is one hookSpecificOutput object + exit 0.
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
G="$LIB/guard.sh"
# The exempt command of the scanner cases (guard.exempt_commands): only ever named, never run.
NOTE="$SANDBOX/bin/note.sh"

# The fixture check: denies `gh pr ready` (no --undo) and a `gh pr|issue edit` naming the label
# needs-eyes, wherever the scan finds them. The scanner cases use it to prove that a command
# reaches guard.checks through continuations, nested -c code, eval, env -S, flock and the strict
# path.
FIX="$SANDBOX/fixture-check"
cat > "$FIX" <<'SH'
#!/bin/sh
exec awk '
BEGIN { FS = "\t" }
{
  moved = $1; n = split($2, w, "\037"); g = 0
  for (i = 1; i <= n; i++) { b = w[i]; sub(/.*\//, "", b); if (b == "gh") { g = i; break } }
  if (!g) next
  p1 = ""; p2 = ""; undo = 0; lab = 0
  for (i = g + 1; i <= n; i++) {
    if (w[i] == "-R" || w[i] == "--repo") { i++; continue }
    if (w[i] == "--undo") undo = 1
    if (w[i] == "needs-eyes") lab = 1
    if (w[i] ~ /^-/) continue
    if (p1 == "") p1 = w[i]; else if (p2 == "") p2 = w[i]
  }
  if (p1 == "pr" && p2 == "ready" && !undo) { printf "D\tfixture: gh pr ready (moved %s)\n", moved; exit }
  if ((p1 == "pr" || p1 == "issue") && p2 == "edit" && lab) { printf "D\tfixture: review label\n"; exit }
}'
SH
chmod +x "$FIX"

# The user config. HIGHNESS_CONFIG always points into the sandbox, so the real one is never
# read: CFG (deny pattern, exempt note.sh, the fixture check) and CFG_BARE (no checks).
CFG="$SANDBOX/config.json"; CFG_BARE="$SANDBOX/config-bare.json"
jq -n --arg f "$FIX" '{guard:{deny_patterns:["prod-cluster"],exempt_commands:["note.sh"],checks:[$f]}}' > "$CFG"
jq -n '{guard:{deny_patterns:["prod-cluster"],exempt_commands:["note.sh"]}}' > "$CFG_BARE"
export HIGHNESS_CONFIG="$CFG"

REPO="$SANDBOX/repo"
git init -q "$REPO"; git -C "$REPO" commit -q --allow-empty -m init

# run <command> [cwd] [tool]: sets OUT and RC
run() {
  local p
  # the command on stdin: one argument over 128 KB is past Linux's MAX_ARG_STRLEN
  p=$(printf '%s' "$1" | jq -Rsc --arg d "${2:-$REPO}" --arg t "${3:-Bash}" \
        '{session_id:"s",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:.},cwd:$d}')
  OUT=$(printf '%s' "$p" | bash "$G" pretool); RC=$?
}
decision() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null; }
reason()   { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null; }
denies() {  # denies <desc> <command> [cwd]
  run "$2" "${3:-}"
  assert_status "deny exits 0: $1" 0 "$RC"
  assert_eq "deny: $1" "deny" "$(decision)"
  assert_eq "deny names the event: $1" "PreToolUse" \
    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
  case "$(reason)" in
    hi-guard:*|fixture:*|'check '*) _assert_ok "deny reason is hi-guard's or a check's: $1" ;;
    *) _assert_bad "deny reason is hi-guard's or a check's: $1 — got [$(reason)]" ;;
  esac
}
allows() {  # allows <desc> <command> [cwd] [tool]
  run "$2" "${3:-}" "${4:-}"
  assert_status "allow exits 0: $1" 0 "$RC"
  assert_eq "allow is silent: $1" "" "$OUT"
}

# 1. sudo as a command word
denies "sudo apt install"           'sudo apt install x'
denies "sudo after &&"              'cd /tmp && sudo rm -rf y'
denies "sudo after a pipe"          'echo 1 | sudo tee /etc/x'
denies "sudo in \$( )"              'x=$(sudo cat /etc/shadow)'
denies "sudo on a later line"       "$(printf 'ls\nsudo true')"
allows "pseudo is not sudo"         'cat pseudo.txt'
allows "sudoers.d is not sudo"      'ls sudoers.d'
run 'sudo true'
assert_contains "the sudo reason starts hi-guard:" "$(reason)" "hi-guard: sudo"
assert_contains "the sudo reason says the user runs it" "$(reason)" "run it themselves"

# 2. deny patterns (the user file, HIGHNESS_CONFIG)
denies "a prod context"             'kubectl --context prod-cluster get pods'
allows "a testing context"          'kubectl --context testing-cluster get pods'
assert_contains "pattern reason names the pattern" \
  "$(run 'kubectl --context prod-cluster get pods'; reason)" "prod-cluster"


# deny patterns from the repo's .claude/highness.json, read in the hook's cwd; arrays of the
# repo file and the user file add up.
TEAM="$SANDBOX/team"
git init -q "$TEAM"; mkdir -p "$TEAM/.claude"
printf '{"guard":{"deny_patterns":["team-secret"],"exempt_commands":["team.sh","sudo"],"checks":["%s"]}}\n' "$FIX" > "$TEAM/.claude/highness.json"
denies "a repo file's pattern, in that repo"           'vault read team-secret' "$TEAM"
assert_contains "the repo pattern is named"            "$(reason)" "team-secret"
denies "a repo file's pattern, from a subdirectory"    'vault read team-secret' "$TEAM/.claude"
allows "a repo file's pattern, in another repo"        'vault read team-secret'
allows "a repo file's pattern, outside any repo"       'vault read team-secret' "$SANDBOX"
denies "the user file's pattern still holds there"     'kubectl --context prod-cluster get pods' "$TEAM"
denies "a repo file cannot exempt a command"           "$(printf "team.sh add <<'EOF'\nsudo x\nEOF")" "$TEAM"
denies "a repo file cannot exempt sudo itself"         'sudo ls' "$TEAM"
denies "a repo file's exempt command, elsewhere"       "$(printf "team.sh add <<'EOF'\nsudo x\nEOF")"
HIGHNESS_CONFIG="$SANDBOX/none.json"
denies "the repo file alone, no user file"             'vault read team-secret' "$TEAM"
allows "no user file: its pattern is gone"             'kubectl --context prod-cluster get pods' "$TEAM"
allows "no config at all: no deny patterns"           'kubectl --context prod-cluster get pods'
denies "no config at all: rule 1 holds"                'sudo ls'
denies "no config at all: no exempt command"           "$(printf "note.sh add <<'EOF'\nsudo x\nEOF")"
denies "no config at all: no exempt command (bash)"    "$(printf "bash \$L/note.sh add <<'EOF'\nsudo x\nEOF")"
HIGHNESS_CONFIG="$SANDBOX/user-only.json"
printf '{"guard":{"deny_patterns":["user-only-[0-9]+"]}}\n' > "$HIGHNESS_CONFIG"
denies "a HIGHNESS_CONFIG user file's ERE"             'curl https://x/user-only-42'
allows "a HIGHNESS_CONFIG user file's ERE, no match"   'curl https://x/user-only-x'
BROKEN="$SANDBOX/broken"
git init -q "$BROKEN"; mkdir -p "$BROKEN/.claude"; printf '{bad' > "$BROKEN/.claude/highness.json"
denies "a broken repo file does not hide the user file" 'curl https://x/user-only-42' "$BROKEN"
allows "a broken repo file does not break the common path" 'ls -la' "$BROKEN"
printf '{bad' > "$HIGHNESS_CONFIG"
allows "a broken user file allows"                     'ls -la'
denies "a broken user file: rule 1 holds"              'sudo ls'
HIGHNESS_CONFIG=$CFG

# guard.exempt_commands: an exempt segment is out of rules 1 and 2, its heredoc is data; every
# other segment, and its own $(…), stays checked.
allows "exempt: a quoted heredoc naming sudo"          "$(printf "note.sh add <<'EOF'\nsudo apt install x\nEOF")"
allows "exempt: by path, through bash"                 "$(printf "bash %s add <<'EOF'\nsudo x\nEOF" "$NOTE")"
allows "exempt: through sh"                            "$(printf "sh note.sh add <<'EOF'\nsudo x\nEOF")"
denies "exempt: not through zsh"                       "$(printf "zsh note.sh add <<'EOF'\nsudo x\nEOF")"
allows "exempt: its words naming a deny pattern"       "note.sh add 'kubectl --context prod-cluster'"
denies "exempt: off, its words are rule 2's"           "notes.sh add 'kubectl --context prod-cluster'"
denies "exempt: its \$( ) is checked"                  'note.sh add "$(sudo id)"'
HIGHNESS_CONFIG="$SANDBOX/exempt-path.json"
printf '{"guard":{"exempt_commands":["/opt/tools/other.sh"]}}\n' > "$HIGHNESS_CONFIG"
allows "exempt: a configured path counts by basename"  "$(printf "other.sh <<'EOF'\nsudo x\nEOF")"
denies "exempt: note.sh is no longer exempt"           "$(printf "note.sh <<'EOF'\nsudo x\nEOF")"
HIGHNESS_CONFIG=$CFG

# guard.checks: run after rules 1 and 2 allow, in .cwd, with .cwd as $1 and the scanned simple
# commands on stdin. First D wins, else first A; empty, failing, missing: allow.
CK="$SANDBOX/checks"; mkdir -p "$CK" "$HOME/bin"
export DUMP="$SANDBOX/feed"
printf '#!/bin/sh\ncat >/dev/null\nprintf "D\\tcheck d says no\\n"\n' > "$CK/d"
printf '#!/bin/sh\ncat >/dev/null\nprintf "noise\\nA\\tcheck a asks\\nA\\tcheck a again\\n"\n' > "$CK/a"
printf '#!/bin/sh\ncat >/dev/null\nprintf "A\\tcheck a2 asks\\n"\n' > "$CK/a2"
printf '#!/bin/sh\ncat >/dev/null\n' > "$CK/empty"
printf '#!/bin/sh\ncat >/dev/null\nprintf "D\\tfailing\\n"\nexit 3\n' > "$CK/fail"
printf '#!/bin/sh\ncat > "$DUMP"\nprintf "%%s" "$1" > "$DUMP.arg"\npwd -P > "$DUMP.pwd"\n' > "$CK/dump"
printf '#!/bin/sh\nprintf "D\\tnot executable\\n"\n' > "$CK/noexec"
chmod +x "$CK/d" "$CK/a" "$CK/a2" "$CK/empty" "$CK/fail" "$CK/dump"
cp "$CK/d" "$HOME/bin/d"
checks() {  # checks <path>...: the user config with these guard.checks
  HIGHNESS_CONFIG="$SANDBOX/checks.json"
  jq -n '{guard:{deny_patterns:["prod-cluster"],checks:$ARGS.positional}}' --args "$@" > "$HIGHNESS_CONFIG"
}
checks "$CK/d"
denies "checks: D denies"                              'ls'
assert_eq "checks: the D reason, verbatim"             "check d says no" "$(reason)"
checks "$CK/a"
run 'ls'
assert_eq "checks: A asks"                             "ask" "$(decision)"
assert_eq "checks: the first A of a check"             "check a asks" "$(reason)"
checks "$CK/a2" "$CK/a"
run 'ls'
assert_eq "checks: the first A over checks"            "check a2 asks" "$(reason)"
checks "$CK/a" "$CK/d"
denies "checks: a later D beats an earlier A"          'ls'
assert_eq "checks: D's reason"                         "check d says no" "$(reason)"
rm -f "$DUMP"
checks "$CK/d" "$CK/dump"
denies "checks: after a D"                             'ls'
assert_eq "checks: no check runs after a D"            "no" "$([ -e "$DUMP" ] && echo yes || echo no)"
checks "$CK/empty"
allows "checks: an empty check allows"                 'ls'
checks "$CK/fail"
allows "checks: a failing check allows, whatever it printed" 'ls'
checks "$SANDBOX/no-such-check"
allows "checks: a missing check allows"                'ls'
checks "$CK/noexec"
allows "checks: a check that is not executable allows" 'ls'
checks "checks/d"
allows "checks: a relative path is not run"            'ls' "$SANDBOX"
checks "~/bin/d"
denies "checks: a ~/ path"                             'ls'
checks "$CK/d"
denies "checks: rule 1 first"                          'sudo ls'
assert_contains "checks: rule 1's reason, not the check's" "$(reason)" "hi-guard: sudo"
denies "checks: rule 2 first"                          'kubectl --context prod-cluster get pods'
assert_contains "checks: rule 2's reason, not the check's" "$(reason)" "hi-guard: the command matches"
checks "$CK/dump"
rm -f "$DUMP"
allows "checks: dump the feed"                         "cd sub && gh pr edit --title 'a > b' 7 --add-label needs-eyes 2>&1; bash -c 'echo \"x
y\"'"
US=$(printf '\037')
exp=$(printf '0\tcd%ssub\n1\tgh%spr%sedit%s--title%sa > b%s7%s--add-label%sneeds-eyes\n1\tbash%s-c%secho "x y"\n1\techo%sx y\n' \
  "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US" "$US")
assert_eq "checks: the feed, one simple command per line, nested code after" "$exp" "$(cat "$DUMP")"
assert_eq "checks: \$1 is the hook's cwd"              "$REPO" "$(cat "$DUMP.arg")"
assert_eq "checks: run in the hook's cwd"              "$REPO" "$(cat "$DUMP.pwd")"
allows "checks: an exempt segment, a reader and a pushd" "note.sh add 'x'; grep -c prod-cluster f; pushd /tmp; ls"
exp=$(printf '0\tnote.sh%sadd%sx\n0\tgrep%s-c%sprod-cluster%sf\n0\tpushd%s/tmp\n1\tls\n' \
  "$US" "$US" "$US" "$US" "$US" "$US")
assert_eq "checks: every segment reaches the feed; pushd moves the rest" "$exp" "$(cat "$DUMP")"
allows "checks: a here-string and a heredoc body"      "$(printf "cat <<'EOF' > f\nbody\nEOF\ntr a b <<< x")"
exp=$(printf '0\tcat\n0\ttr%sa%sb\n' "$US" "$US")
assert_eq "checks: heredoc bodies and redirections are not words" "$exp" "$(cat "$DUMP")"
HIGHNESS_CONFIG=$CFG

# the fixture check, through the scan: gh commands reach guard.checks in every shape
denies "fixture: gh pr ready"                          'gh pr ready 5'
assert_eq "fixture: not moved"                         "fixture: gh pr ready (moved 0)" "$(reason)"
denies "fixture: after a cd"                           'cd /tmp && gh pr ready 5'
assert_eq "fixture: moved after a cd"                  "fixture: gh pr ready (moved 1)" "$(reason)"
denies "fixture: after a pushd"                        'pushd /tmp; gh pr ready 5'
assert_eq "fixture: moved after a pushd"               "fixture: gh pr ready (moved 1)" "$(reason)"
denies "fixture: -R before the subcommand"             'gh -R o/r pr ready 7'
denies "fixture: --repo= between"                      'gh pr --repo=o/r ready 7'
denies "fixture: an edit with the label"               "gh pr edit --add-label 'needs-eyes' 5"
denies "fixture: a note.sh call, then a flip"          "bash $NOTE list && gh pr ready 5"
allows "fixture: --undo"                               'gh pr ready 5 --undo'
allows "fixture: a mention is not a call"              "grep -rn 'gh pr ready' plugins/"
allows "fixture: gh pr view"                           'gh pr view 5'
allows "fixture: another label"                        'gh pr edit 5 --add-label bug'
allows "fixture: redirections are not words"           'gh pr view 5 2>&1 > out.txt'
HIGHNESS_CONFIG=$CFG_BARE
allows "no checks: gh pr ready is allowed"             'gh pr ready 5'
HIGHNESS_CONFIG=$CFG

# never break a session
allows "a Read payload" 'sudo rm -rf /' "$REPO" Read
for bad in '' 'not json' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":"x"}' '[1,2]'; do
  o=$(printf '%s' "$bad" | bash "$G" pretool 2>&1); rc=$?
  assert_status "malformed payload [$bad] exits 0" 0 "$rc"
  assert_eq "malformed payload [$bad] allows silently" "" "$o"
done

# sudo through ssh, or first in a quoted string
denies "ssh host sudo"                          'ssh box sudo systemctl restart x'
denies "ssh -p 22 host 'sudo ls'"               "ssh -p 22 box 'sudo ls'"
denies "bash -c \"sudo ls\""                  'bash -c "sudo ls"'
denies "sh -c 'sudo id'"                        "sh -c 'sudo id'"
allows "echo sudoku"                            'echo sudoku'
allows "ssh without sudo"                       'ssh box ls /etc/sudoers.d'
allows "pseudo in quotes"                       "cat 'pseudo.txt'"

# the plugin wires it as a Bash PreToolUse hook
H="$HERE/../hooks/hooks.json"
assert_eq "hooks.json: PreToolUse matcher Bash" "Bash" "$(jq -r '.hooks.PreToolUse[0].matcher' "$H" 2>/dev/null)"
assert_eq "hooks.json: runs guard.sh pretool" 'bash "${CLAUDE_PLUGIN_ROOT}/lib/guard.sh" pretool' \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$H" 2>/dev/null)"

# An exempt command's text is data. Heredoc bodies are not commands, and an exempt segment is out
# of rules 1 and 2; every other segment still is checked.
allows "a piped note.sh call whose words name the prod pattern" \
  "printf 'searched: s\\n' | bash \$L/note.sh add ABC-17 access access:prod-cluster"
allows "note.sh --repo, args naming sudo" "$NOTE --repo $REPO add ABC-17 sudo sudo:leaked </dev/null"
denies "note.sh add … && sudo ls"        "bash $NOTE add ABC-17 sudo g </dev/null && sudo ls"
denies "note.sh add; prod in another segment" "bash $NOTE list; kubectl --context prod-cluster get pods"
denies "note.sh, then a flip the fixture denies"  "bash $NOTE list && gh pr ready 5"
# A quoted body to cat that feeds nothing further is data; so is an unquoted one that expands
# nothing executable (see the inert-body block below).
allows "a heredoc body fed to cat"        "$(printf 'cat <<EOF\nsudo x\nEOF')"
allows "a quoted, dashed heredoc to cat"  "$(printf "cat <<-'X'\n\tsudo x\n\tX")"
allows "a quoted, dashed note.sh heredoc" "$(printf "bash \$L/note.sh add ABC-17 sudo sudo:x <<-'X'\n\tsearched: s\n\tpayload: sudo x\n\tX")"
allows "a reply draft naming sudo, via a note.sh heredoc" \
  "$(printf "bash \"\$L/note.sh\" add ABC-17 reply reply:t <<'EOF'\nneed: answer the reviewer\nsearched: the thread\npayload: We never run sudo here; the deploy user owns the path.\nEOF")"
# Bodies fed to a shell some other way stay commands
for c in "cat <<EOF | bash" "cat <<'EOF' | sh" 'eval "$(cat <<EOF' 'bash -c "$(cat <<EOF' \
         "bash /dev/stdin <<EOF" "source /dev/stdin <<EOF" "timeout 5 bash <<EOF" \
         "env -i bash <<EOF" "docker exec -i c bash <<EOF" "cat <<EOF; bash <<EOF" \
         "mynote.sh add ABC-17 sudo g <<'EOF'"; do
  case "$c" in *'$('*) tail='EOF\n)"' ;; 'cat <<EOF; bash <<EOF') tail='EOF\nsudo y\nEOF' ;; *) tail='EOF' ;; esac
  denies "sudo in the body of: $c" "$(printf '%s\nsudo x\n'"$tail" "$c")"
done
denies "prod in the body of: cat <<EOF | bash" "$(printf 'cat <<EOF | bash\nkubectl --context prod-cluster get pods\nEOF')"
denies "prod in the body of: bash /dev/stdin" "$(printf "bash /dev/stdin <<'EOF'\nkubectl --context prod-cluster get pods\nEOF")"
denies "an unquoted note.sh heredoc still expands \$(…)" "$(printf 'bash $L/note.sh add ABC-17 sudo g <<EOF\nsearched: $(sudo id)\nEOF')"
denies "arithmetic << is not a heredoc"   "$(printf 'echo $((1<<2))\nsudo x')"
denies "sudo after the terminator"        "$(printf 'cat <<EOF\nsudo x\nEOF\nsudo y')"
denies "a heredoc fed to bash is commands" "$(printf 'bash <<EOF\nsudo x\nEOF')"
denies "a heredoc fed to ssh is commands" "$(printf 'ssh host <<EOF\nkubectl --context prod-cluster get pods\nEOF')"
denies "an unterminated << strips nothing" "$(printf 'echo \"a <<X\"\nsudo y')"
allows "a here-string is not a heredoc"   'cat <<< "x"'
allows "an exempt answer's quoted heredoc, sudo text" \
  "$(printf "bash \"\$L/note.sh\" answer %s yes <<'EOF'\nsudo apt install done\nEOF" "N-1")"
denies "printf-piped prod text is checked" \
  "printf 'need: prod-cluster access\\n' | bash \$L/note.sh add ABC-17 access g"

# The split into simple commands is quote-aware.
allows "a title with parens"                'gh pr create --title "fix (parser)" --draft'
allows "a conventional-commit title"        'gh pr create --title "feat(x): y" --draft'
allows "a heredoc body in \$( ) in a --body" \
  "$(printf "gh pr create --title t --body \"\$(cat <<'EOF'\nIt's done (really); see #3\nEOF\n)\" --draft")"
allows "a title naming sudo after ;"        'gh pr create --title "a; sudo rm" --draft'
denies "sudo after the create"              'gh pr create --draft; sudo rm x'
denies "a review label after a body with parens" 'gh pr edit 5 --body "(see above)" --add-label "needs-eyes"'
denies "a quoted value with > is not a redirection" "gh pr edit --title 'a > b' 7 --add-label needs-eyes"
denies "sudo in \$( ) inside double quotes"  'gh pr create --title x --body "$(sudo id)" --draft'
denies "sudo in backticks inside double quotes" 'echo "`sudo id`"'
denies "a note.sh argument's \$( ) is checked" "bash $NOTE add ABC-17 sudo g \"\$(sudo id)\" </dev/null"
denies "a note.sh argument's backticks are checked" "bash $NOTE add ABC-17 sudo g \"\`sudo id\`\" </dev/null"
denies "a quoted '; note.sh' does not own the heredoc" "$(printf "cat \"; note.sh\" <<'EOF' | sh\nsudo x\nEOF")"
denies "an apostrophe in a body hides nothing after it" "$(printf "cat <<'EOF'\nit's\nEOF\nsudo y")"
denies "an apostrophe in a comment hides nothing"       "$(printf "ls # don't\nsudo y")"
denies "bash -c with sudo later"            'bash -c "make && sudo make install"'
denies "sh -c with sudo after ;"            "sh -c 'true; sudo id'"
denies "eval with sudo after ;"             'eval "a; sudo b"'
denies "ssh with sudo after ;"              "ssh box 'cd x; sudo systemctl restart y'"
denies "a wrapped sh -c"                    "docker exec c sh -c 'sudo id'"
denies "an unclosed quote falls back to the raw check" "$(printf "echo 'a\nsudo y")"

# A quoted sudo is a mention, except as a shell's -c argument.
allows "grep for 'sudo'"                    "grep -rn 'sudo' plugins/"
allows "grep for \"sudo \""                 'grep -rn "sudo " lib/'
allows "git log --grep=\"sudo\""            'git log --grep="sudo"'
allows "python -c printing sudo"            "python -c 'print(\"sudo\")'"
allows "grep -c 'sudo'"                     "grep -c 'sudo' f"
allows "a git commit -F- body with a sudo line" \
  "$(printf "git commit -F- <<'EOF'\nguard: block sudo\n\nsudo is now blocked\nEOF")"
allows "a git commit -m \"\$(cat <<'EOF')\" body with a sudo line" \
  "$(printf "git commit -m \"\$(cat <<'EOF'\nguard: block sudo\n\nsudo is now blocked\nEOF\n)\"")"
denies "eval \"sudo ls\""                   'eval "sudo ls"'
denies "an unquoted git commit body still expands" "$(printf 'git commit -F- <<EOF\n$(sudo id)\nEOF')"
denies "a git body piped on to sh"          "$(printf "git commit -m \"\$(cat <<'EOF' | sh\nsudo x\nEOF\n)\"")"
denies "eval of a cat heredoc"              "$(printf "eval \"\$(cat <<'EOF'\nsudo x\nEOF\n)\"")"
denies "a quoted heredoc fed to ssh"        "$(printf "ssh host <<'EOF'\nsudo ls\nEOF")"
denies "git with a -c before commit is not a message" "$(printf "git -c alias.x=y commit -F- <<'EOF'\nsudo x\nEOF")"

# A quoted heredoc body read by a data consumer is data; a script's argv is not code.
allows "a python3 heredoc naming \`sudo\`" "$(printf "python3 - <<'PY'\ns = 'the guard denies \`sudo\` here'\nPY")"
allows "cat > file with a sudo line"    "$(printf "cat > /tmp/x <<'EOF'\nsudo apt install x\nEOF")"
allows "tee with a piped sudo line"     "$(printf "tee f <<'EOF' >/dev/null\na | sudo tee g\nEOF")"
allows "a quoted body, then ||"         "$(printf "cat > f <<'EOF' || true\nsudo x\nEOF")"
allows "a script's argument naming sudo" "bash \"\$L/wt.sh\" create --name 'issue 20 · sudo heredoc' --base main"
allows "sh script argv after options"   "sh -e -o pipefail x.sh 'sudo y'"
denies "sudo after the quoted body"     "$(printf "cat > f <<'EOF'\nx\nEOF\nsudo y")"
denies "sudo after && on the << line"   "$(printf "cat > f <<'EOF' && sudo y\nx\nEOF")"
denies "echo piped to sudo tee"         "echo x | sudo tee f"
denies "a quoted cat body piped to sh"  "$(printf "cat <<'EOF' | sh\nsudo x\nEOF")"
denies "a quoted python body piped on"  "$(printf "python3 - <<'PY' | bash\nprint(1)\nsudo x\nPY")"
denies "a tee body into >(sh)"          "$(printf "tee f <<'EOF' >(sh)\nsudo x\nEOF")"
denies "a quoted body to a non-data command" "$(printf "mynote.sh add <<'EOF'\nsudo x\nEOF")"
denies "a quoted cat body inside \$( )"  "$(printf "x=\"\$(cat <<'EOF'\nsudo x\nEOF\n)\"; eval \"\$x\"")"
denies "a script, then sudo"            "bash x.sh && sudo y"
denies "bash -s args are checked"       "bash -s 'sudo'"
denies "bash - args are checked"        "bash - 'sudo'"
denies "--rcfile then -c"               "bash --rcfile r -c 'sudo id'"
denies "bash /dev/stdin args"           "bash /dev/stdin 'sudo'"
denies "ssh's words stay code"          "ssh box 'sudo ls'"

# An unquoted heredoc body to a data consumer is data when it expands nothing
# executable — no $(…), no `…`, no backslash-newline (bash joins `$\` + `(…)` into a $(…)).
allows "an unquoted cat > file body naming sudo" "$(printf 'cat > b.md <<EOF\nnotes\nsudo apt install x\nEOF')"
allows "an unquoted body with \$VAR and \${X}"  "$(printf 'cat > b.md <<EOF\nhome $HOME, ${X:-y}\nsudo x\nEOF')"
allows "an unquoted body naming the prod pattern" "$(printf 'tee f <<EOF >/dev/null\nkubectl --context prod-cluster get pods\nEOF')"
allows "an unquoted git commit message"     "$(printf 'git commit -F - <<EOF\nguard: sudo is denied\nEOF')"
denies "an unquoted body with \$(sudo …)"   "$(printf 'cat > b.md <<EOF\n$(sudo id)\nEOF')"
denies "an unquoted body with \`sudo …\`"   "$(printf 'cat > b.md <<EOF\n`sudo id`\nEOF')"
denies "a backslash-newline splitting \$("   "$(printf 'cat > b.md <<EOF\n$\\\n(sudo id)\nEOF')"
denies "\$(prod) in an unquoted body"       "$(printf 'cat > b.md <<EOF\n$(kubectl --context prod-cluster get pods)\nEOF')"
denies "an unquoted cat body piped to bash" "$(printf 'cat <<EOF | bash\nsudo x\nEOF')"
denies "an unquoted body to a non-data command" "$(printf 'mynote.sh add <<EOF\nsudo x\nEOF')"
# A deny pattern in a search command's words is a search pattern, not an access.
allows "grep -E for the prod pattern"       "grep -E 'prod-cluster' log.txt"
allows "grep -rn, unquoted pattern"         "grep -rn prod-cluster plugins"
allows "rg for the prod pattern, piped on"  "rg 'prod-cluster|x' . | head -5"
allows "grep behind a wrapper"              "timeout 5 grep -c prod-cluster log"
denies "a substitution inside grep's words" 'grep x $(kubectl --context prod-cluster get pods)'
denies "grep, then prod in a pipe"          'grep x f | ssh prod-cluster'
denies "rg --pre runs a command"            "rg --pre 'kubectl --context prod-cluster' x ."
denies "an expansion in front of grep"      '$X grep prod-cluster f'
denies "env -S in front of grep"            "env -S'kubectl --context prod-cluster' grep x"
denies "git grep is not a reader"           'git grep prod-cluster'
denies "grep, then sudo"                    'grep x f && sudo id'
# ${X:-$Y} is modeled, so its command keeps the note.sh exemption.
allows "cd \"\${REPO:-\$PWD}\" && note.sh access ask" \
  "$(printf 'cd "${REPO:-$PWD}" && note.sh add ABC-17 access access:x <<'"'EOF'"'\nneed: kubectl --context prod-cluster\nsearched: s\nEOF')"
allows "the same, through bash \$L/note.sh" \
  "$(printf 'cd "${REPO:-$PWD}" && bash "$L/note.sh" add ABC-17 sudo sudo:x <<'"'EOF'"'\nneed: x\nsearched: s\npayload: sudo apt x\nEOF')"
denies "\${X:-\$(sudo …)} is not modeled"     'cd "${X:-$(sudo id)}"'
denies "\${X:-\${Y}} is not modeled, prod after" "$(printf 'cd "${X:-${Y}}" && note.sh add K access g; kubectl --context prod-cluster get pods')"
denies "\${X:-\$SHELL} -c 'sudo id'"        "\${X:-\$SHELL} -c 'sudo id'"
denies "cd \"\${R:-\$PWD}\" && sudo id"     'cd "${R:-$PWD}" && sudo id'

# A UTF-8 locale: the parser counts and indexes the command in bytes, so a multibyte character
# never cuts the scan short (an em dash once hid a later `; sudo id`).
U=$(locale -a 2>/dev/null | grep -i -m1 -E '^(C|en_US)\.utf-?8$')
if [ -n "$U" ]; then
  export LC_ALL=$U
  denies "UTF-8: an em-dash run before ; sudo"  'echo ——————————; sudo id'
  denies "UTF-8: Cyrillic before ; sudo"         'echo привет мир; sudo id'
  allows "UTF-8: an em dash in a draft title"    'gh pr create --title "fix — parser" --draft'
  allows "UTF-8: an em dash in a \$(cat) body" \
    "$(printf "gh pr create --title t --body \"\$(cat <<'EOF'\nIt's done — really\nEOF\n)\" --draft")"
  allows "UTF-8: a git commit body with an em dash and a sudo line" \
    "$(printf "git commit -F- <<'EOF'\nguard — block sudo\n\nsudo is now blocked\nEOF")"
  unset LC_ALL
else
  echo "  skip UTF-8 cases: no UTF-8 locale installed"
fi

# Round 2: shapes the first quote-aware parser let through (the old guard denied each).
NL='
'
risky=(
  "echo hi && \\${NL}  sudo id"
  "x=1 \\${NL}  sudo id"
  "echo x; \\${NL}sudo id"
  "echo hi && \\${NL}  gh pr ready 5"
  "cd x && \\${NL}  gh pr ready 5"
  "echo hi;\\${NL}gh pr edit 5 --add-label needs-eyes"
  "gh pr \\${NL}  ready 5"
  "su\\${NL}do id"
  "echo \$'\\' # '; sudo id"
  "echo \$'\\' # '; kubectl --context prod-cluster get pods"
  "echo \$'a\\''; sudo id # '"
  'echo $(( $(sudo id) ))'
  'echo $(( `sudo id` ))'
  'echo "$(( $(sudo id) ))"'
  'x=`echo \`sudo id\``'
  '\sudo id'
  's\udo id'
  '"sudo" id'
  "'su'do id"
  "nice bash --norc -c 'sudo id'"
  "nice bash -o pipefail -c 'sudo id'"
  "\$SHELL -c 'sudo id'"
  "\${SHELL} -c 'sudo id'"
  "mksh -c 'sudo id'"
  "fish -c 'sudo id'"
  "zsh -c 'sudo id'"
  "dash -c 'sudo id'"
  "ksh -c 'sudo id'"
  'su -c "sudo id"'
  "busybox sh -c 'sudo id'"
  "bash -c 'gh pr ready 5'"
  "nice bash -c 'kubectl --context prod-cluster get pods'"
  "env -i /bin/bash -lc 'true; sudo id'"
  "eval 'gh pr ready 5'"
)
for c in "${risky[@]}"; do denies "round 2 risky: $(printf '%s' "$c" | tr '\n' '~')" "$c"; done
allows "python -c printing sudo, still"     "python -c 'print(\"sudo\")'"
allows "grep 'sudo', still"                  "grep 'sudo' f"
allows "bash -c on a harmless command"       "bash -c 'gh pr view 5'"
allows "a continuation in an allowed command" "$(printf 'ls -la \\\n  /tmp')"
allows "a backslash-newline inside single quotes is text" "$(printf "echo 'a \\\\\n sudo id'")"
allows "\$'…' without a backslash"          "echo \$'a b'"

# Round 3: shapes the one-pass scanner modeled wrongly. bash ran each one (fake sudo/gh on PATH).
# The scanner may only allow what it models exactly; everything else goes to the strict check.
c16=''
for ((i = 0; i < 16; i++)); do c16="${c16}bash -c true; "; done
risky3=(
  "echo \"\${x:-'\"'}\"; sudo id #'"
  "echo \"\${x:-'\"'}\"; gh pr ready 5 #'"
  "echo \"\${x:-'\"'}\"; bash -c 'sudo id' #'"
  "x=\"\${y:-'\"'}\"; gh pr edit 5 --add-label needs-eyes #'"
  "echo \"\${x#'\"'}\"${NL}sudo id${NL}#'"
  "git commit -q --allow-empty -m \${x:-<<'EOF'}${NL}sudo id${NL}EOF"
  "x=1; echo \$(( \${x:-\"(\"} )); sudo id${NL})"
  "echo \$(( 1 + \${#x} \${x:+\"(\"} )); sudo id${NL})"
  'echo $((echo a); sudo id)'
  'echo $((echo a) | sudo id)'
  "(( x = '\"' )); sudo id #\""
  "git commit -q --allow-empty -F- <<\$'EOF'${NL}msg${NL}EOF${NL}sudo id${NL}\$EOF"
  "gh pr create --body \"\$(cat <<\$'EOF'${NL}x${NL}EOF${NL})\" --title t --draft; gh pr ready 5${NL}\$EOF"
  "\$BASH -c 'sudo id'"
  '"$BASH" -c "sudo id"'
  '${BASH} -c "sudo id"'
  '$(command -v bash) -c "sudo id"'
  '`command -v bash` -c "sudo id"'
  "\$X sudo id"
  "\$X gh pr ready 5"
  "script -qc 'sudo id' /dev/null"
  "script -q -c 'sudo id' /dev/null"
  "script --command='sudo id' /dev/null"
  "flock /tmp/l.lock -c 'sudo id'"
  "flock -x /tmp/l.lock -c 'sudo id'"
  "flock /tmp/l.lock sudo id"
  "flock -w 5 /tmp/l.lock gh pr ready 5"
  "${c16}bash -c \"'su'do id\""
  "${c16}bash -c 'gh pr ready 5'"
  'nice -n 5 sudo id'
  '2>&1 sudo id'
  '>&2 sudo id'
  'ls 2>&1; >&2 gh pr ready 5'
  '>| /tmp/x.out sudo id'
  'env -u HOME sudo id'
  'exec -a x sudo id'
  'coproc sudo id'
  'function f { sudo id; }; f'
  'timeout 5 sudo id'
  'echo id | xargs sudo'
  'kubectl --context prod-clu\ster get pods'
  "env -S'sudo id'"
  'env -S "gh pr ready 5"'
  '{sudo,id}'
  "echo \"\${x:-'\"'}\"; kubectl --context prod-cluster get pods #'"
  $'echo hi\r\nsudo id\r'
  $'echo hi && \\\r\n sudo id'
  $'echo \377\376; sudo id'
  $'echo \'\377\'; sudo id'
  $'echo "\303"; gh pr ready 5'
  'sudo id \'
  'echo hi; sudo id\'
  $'echo \'a\\\nb\'; sudo id'
  $'echo a\r# x\nsudo id'
  'time -p sudo id'
  'if ! sudo id; then :; fi'
  'echo $[1]; sudo id'
  'for ((i=0;i<1;i++)); do sudo id; done'
)
for c in "${risky3[@]}"; do denies "round 3 risky: $(printf '%s' "$c" | tr '\n' '~')" "$c"; done
# Rules 1 and 2 alone, no guard.checks: every sudo and prod shape above is still denied.
HIGHNESS_CONFIG=$CFG_BARE
for c in "${risky[@]}" "${risky3[@]}"; do
  case "$c" in *sudo*|*prod-clu*) denies "no checks: $(printf '%s' "$c" | tr '\n' '~')" "$c" ;; esac
done
HIGHNESS_CONFIG=$CFG
allows "a braced variable in quotes"        'echo "${HOME}/x"; grep -rn '"'sudo'"' .'
allows "a braced default and suffix strip"  'for f in *.sh; do echo "${f%.sh}" "${x:-none}"; done'
allows "a braced key on a note.sh heredoc" \
  "$(printf "bash \$L/note.sh add \"\${KEY}\" sudo g <<'EOF'\nsudo apt install x\nkubectl --context prod-cluster get pods\nEOF")"
allows "&> and 2>&1 are redirections"       'make test &>/dev/null; git log 2>&1 | grep sudo'
allows "arithmetic, still"                  'echo $(( x + 1 )) $(( (2 + 3) * 4 ))'
allows "a gh pr create --draft with a sudo title, braced body" \
  'gh pr create --draft --title "docs: never sudo" --body "${BODY}"'
allows "git log --grep=\"sudo\", still"     'git log --grep="sudo"'
allows "python3 -c printing sudo, still"    "python3 -c 'print(\"sudo\")'"
allows "flock on a harmless command"        "flock /tmp/l.lock -c 'make test'"
allows "script recording a harmless command" "script -qc 'ls' /dev/null"
allows "env with an assignment, naming sudo" "env FOO=1 grep -rn 'sudo' ."
allows "ls with 2>&1 and a file named sudo"  'ls 2>&1 sudo'
allows "a brace expansion naming files"      'cp x.{txt,bak} /tmp'
allows "command -v sudo is a lookup"         'command -v sudo'
allows "a C-style for loop"                  'for ((i=0; i<3; i++)); do echo "$i"; done'
allows "nice -n on a harmless command"       'nice -n 5 make test'
allows "timeout on a harmless command"       "timeout 30 grep -rn 'sudo' ."

# Round 4: a command the scan hands to the strict check still joins a backslash-newline
denies "strict path: a pr edit split by a continuation" \
  "cd \"\${REPO:-\$HOME/r}\" 2>/dev/null || true${NL}gh pr edit 5 \\${NL}  --add-label needs-eyes"
denies "strict path: gh pr split before ready" \
  "echo \"\${XDG_CONFIG_HOME:-\$HOME/.config}\"; gh pr \\${NL}  ready 5"
denies "strict path: su split by a continuation" \
  "echo \"\${A:-\$HOME}\"; su\\${NL}do id"
allows "strict path: an even run of backslashes ends no line early" \
  "echo \"\${A:-\$HOME}\"; echo x\\\\${NL}echo sudo-free"

# Rounds 2 and 3, latency: a long quoted --body is everyday; the scan must stay linear. Timed
# with bash's own `time` (TIMEFORMAT=%R works on 3.2), under the default awk and, when it is
# installed, under mawk (Debian's default awk, which copies a string on every append).
big=$(awk 'BEGIN { for (i = 0; i < 1600; i++) printf "line %d: it is (a) test; \"q\" $x and more prose — here\n", i }')
big250=$(awk 'BEGIN { for (i = 0; i < 4000; i++) printf "line %d: it is (a) test; \"q\" $x and more prose — here\n", i }')
TIMEFORMAT=%R
under() {  # under <label> <awk dir or empty>
  local save=$PATH t
  [ -z "$2" ] || PATH="$2:$PATH"
  { time allows "$1: a ~100 KB quoted --body" "gh pr create --draft --title t --body \"$big\""; } 2> "$SANDBOX/t"
  t=$(tail -n 1 "$SANDBOX/t")
  assert_eq "$1: a ~100 KB --body takes under 1 s (took ${t}s)" yes "$(awk -v t="$t" 'BEGIN { print (t + 0 < 1) ? "yes" : "no" }')"
  { time allows "$1: a ~250 KB quoted --body" "gh pr create --draft --title t --body \"$big250\""; } 2> "$SANDBOX/t"
  t=$(tail -n 1 "$SANDBOX/t")
  assert_eq "$1: a ~250 KB --body takes under 2 s (took ${t}s)" yes "$(awk -v t="$t" 'BEGIN { print (t + 0 < 2) ? "yes" : "no" }')"
  PATH=$save
}
under "default awk" ''
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$SANDBOX/mawk"; ln -sf "$(command -v mawk)" "$SANDBOX/mawk/awk"
  under mawk "$SANDBOX/mawk"
else
  echo "  skip mawk latency: no mawk installed"
fi


# A repo file's guard.checks never run (user file only), and a hung check is cut off.
printf '{"guard":{"checks":["%s"]}}\n' "$CK/d" > "$TEAM/.claude/highness.json"
HIGHNESS_CONFIG="$SANDBOX/none.json"
allows "a repo file's check does not run"              'ls' "$TEAM"
printf '#!/bin/sh\ncat >/dev/null\nsleep 10\nprintf "D\\tlate\\n"\n' > "$CK/slow"; chmod +x "$CK/slow"
checks "$CK/slow"
t0=$(date +%s); HI_GUARD_CHECK_TIMEOUT=1 run 'ls'; t1=$(date +%s)
assert_eq "a hung check past its limit allows"         "" "$(decision)"
[ $((t1 - t0)) -lt 5 ] && ok "a hung check is cut off at its limit" || fail "a hung check ran $((t1 - t0))s"
HIGHNESS_CONFIG=$CFG

assert_summary
