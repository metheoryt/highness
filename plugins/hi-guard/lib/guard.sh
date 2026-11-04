#!/usr/bin/env bash
# guard.sh — hi-guard's PreToolUse hook: hard limits on every Bash call in every session.
#
#   guard.sh pretool      hook JSON on stdin (tool_name, tool_input.command, cwd)
#
# Allow is no stdout and exit 0. Deny (or ask) is exit 0 with one
# {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":…}} object.
# Rules, first match wins:
#   1. `sudo` as a command word (unquoted, unescaped: `\sudo`, `'su'do`); or anywhere as a word
#      in an interpreter segment (sh/bash/dash/zsh/ksh/mksh/fish/busybox, su, eval, ssh; not the
#      argv of a script file a shell runs: `bash wt.sh --name '… sudo …'`) or in
#      the -c code of a shell word anywhere in the segment (`nice bash -o pipefail -c '…'`,
#      `$SHELL -c '…'`), of script or flock (`script -qc '…'`, `flock f -c '…'`) or the -S
#      string of env. That code, eval's arguments, flock's command after the lock file and the
#      arguments of a command word that is itself an expansion (`$X sudo id`, `$BASH -c '…'`)
#      are scanned as commands in turn: 16 scans, then the rest the strict way, never skipped.
#   2. Any guard.deny_patterns entry (ERE, anywhere in the command), except in the words of a
#      search command (grep, egrep, fgrep, zgrep, rg without --pre): there a match is a search
#      pattern or a file name, not an access.
#   3. guard.checks, when rules 1 and 2 allow (below).
#
# Configuration: lib/config.sh (a copy of shared/config.sh), read in the hook's .cwd: the user
# file ${HIGHNESS_CONFIG:-~/.config/highness/config.json} and the repo's .claude/highness.json,
# arrays concatenated. All keys are optional; with none set, only rule 1 applies.
# guard.exempt_commands and guard.checks come from the USER file only (config.sh --user): a repo's
# file arrives with every clone, and these two keys switch rule 1 off or run a program on every
# Bash call. A repo can only add deny patterns.
#   guard.deny_patterns    EREs for rule 2.
#   guard.exempt_commands  basenames. A segment whose command word (or the script right after a
#                          `bash`/`sh` command word) has one of these basenames is exempt from
#                          rules 1 and 2, and a heredoc belonging to it is data (see below). Its
#                          $(…) and `…` are commands of their own and stay checked, as does
#                          every other segment of the line. Default: none.
#   guard.checks           absolute paths (or ~/…) of executables, run in order after rules 1
#                          and 2 allow. Each runs in .cwd with .cwd as $1 and, on stdin, every
#                          simple command the scan found, one per line:
#                            <moved><TAB><word1><US><word2>…
#                          US is \x1f. Words are unquoted and unescaped, redirections dropped; a
#                          newline inside a word is passed as a space; a word may hold a TAB,
#                          so split a line on its first TAB only. Order: the commands of the
#                          line as written (a $(…) or (…) before the command holding it), then
#                          those of nested code (-c strings, eval, env -S, flock's command, the
#                          arguments of a `$X` command word), then heredoc bodies kept as
#                          commands and anything checked the strict way, split quote-blind.
#                          A data heredoc body (see below) never appears. <moved> is 1 once any
#                          earlier line of the feed is a cd or pushd command, else 0.
#                          A check prints lines `D<TAB>reason` (deny) or `A<TAB>reason` (ask the
#                          user); other lines are ignored. The first D of any check wins (later
#                          checks are not run), else the first A. A check that prints nothing,
#                          exits non-zero, is missing or not executable allows.
#
# The command is split into simple commands by one awk pass (SCAN_AWK, linear in its length):
# quote-aware, with a $(…) or `…` (inside "…" and $((…)) too) a command of its own, a
# backslash-newline dropped as bash does, and a comment dropped. A heredoc body never reaches
# the quote tracking: it is cut out whole. Bash then reads each command's words, unquoted.
#
# A heredoc body is data (dropped) ONLY when its delimiter is quoted, or unquoted with a body
# that expands nothing executable (no $(…), no `…`, no line ending in a backslash), and its
# `<<` belongs to an exempt command, to `git commit|tag|notes` or `gh pr|issue|release` (a
# message), or to a `cat` that is the whole of a "$(…)" argument of one of those two;
# also to a top-level cat, tee, python, python3, node, jq, awk or sed whose output feeds
# nothing further on its line (no `|`, no `(` after it). Every other body (cat … | bash,
# eval "$(cat <<EOF)", bash /dev/stdin, ssh host <<'EOF', …) stays checked the strict way:
# line by line, quote-blind. A body written to a file and run later is not followed.
# The scan may only decide "allow" on what it models exactly: a command holding anything it
# does not model (see the scan's header: an unclosed quote, a $'…' escape, a ${…} with quotes
# or expansions other than a plain $NAME inside, quotes in $((…)), a $-delimiter, …), or over
# SCAN_MAX bytes, is checked the strict way as a whole: quote-blind, erring toward deny.
#
# A pattern guard catches the honest mistake; it is not a sandbox (a command built at runtime
# slips past it). It must never break a session: bad input, a broken config or a failing
# check all fall through to allow.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The quote-blind check, for heredoc bodies kept as commands (and a command the scan cannot
# close): matched against the text with newlines turned into `;`, since bash's =~ anchors ^ at
# the start of the string only.
CMD_START='(^|[;&|(\`]|&&|\|\||\$\()'
SUDO_RE="${CMD_START}[[:space:]]*sudo([[:space:]]|\$)"
SSH_SUDO_RE="${CMD_START}[[:space:]]*ssh[[:space:]][^;&|]*[[:space:]\"']sudo([[:space:]\"']|\$)"
# Per segment: sudo as a word in an interpreter's code (bash -c "a && sudo b", ssh box 'sudo x').
WORD_SUDO_RE="(^|[[:space:];&|(\`\"'])sudo([[:space:];&|)\`\"']|\$)"
# Above this size the command is checked only the strict, quote-blind way.
SCAN_MAX=262144
# A duration (timeout 5, 1.5m) in a wrapper prefix. In a variable: bash 3.2 and 5 disagree on
# quoting inside a literal [[ =~ ]] pattern.
DUR_RE='^[0-9][0-9.]*[smhd]?$'

_out() {  # _out <deny|ask> <reason>
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
}

# ---- the scan: a command into simple commands and their words ----
#
# One awk pass, linear in the command's length. Mode P is quote-aware: unquoted ; & | ( ) `
# and newlines split; nothing inside '…' or "…" does, but a $(…) or `…` (in "…" and in
# $((…)) too) is a command of its own and leaves `$()` in its parent. A backslash-newline is
# dropped, as bash does; a comment is dropped. A heredoc body is cut out whole when its line
# ends: a data body (see the header) is dropped, any other is a K record. Mode L is the old,
# quote-blind split, for those bodies and for a command P cannot close. Records (RS1 = \036):
# S<raw text>, then W<words> (unquoted, unescaped, joined by \037, redirections dropped: a
# word ending in an unquoted < or > (or >& <& >| &>) and the word after it, any other word
# holding one), one K<body> per kept body, T<text> (the text rule 2 reads: each segment's raw
# text and its unquoted words), and P<1|0> last. With allc set (guard.checks configured), every
# segment also gets a C<words> record, kept or not.
#
# Awk variables: mode (P or L), exempt (guard.exempt_commands joined by US, with a US at each
# end; no newline: BSD awk takes none in a -v value), allc (1 or empty).
#
# P is 1 only when the scan modeled every construct exactly. The invariant: the scan may only
# decide "allow" on input it models exactly, so anything it does not model sets P to 0 and the
# whole command goes to the strict, quote-blind check. That is: the text ends inside a quote, a
# substitution or a heredoc; a $'…' holds a backslash; an escaped backtick nests; a ${…} holds
# anything but plain characters and a plain $NAME (a quote, any other $, `, a bracket, a
# redirection, a separator: bash reads quotes inside "${x:-'…'}" that the scan would not);
# $[…]; $((…)) or ((…)) holds a quote, ${, `, \, ; or a brace, or does not close on `))` (bash
# then reads `$((a); b)` as a command substitution); a heredoc delimiter holds $ or `.
#
# Strings are built through badd (three tiers): mawk copies a string whole on every append,
# so one built a character at a time is quadratic.
SCAN_AWK='
function badd(k, x) {
  b1[k] = b1[k] x
  if (length(b1[k]) > 64) {
    b2[k] = b2[k] b1[k]; b1[k] = ""
    if (length(b2[k]) > 4096) { b3[k] = b3[k] b2[k]; b2[k] = "" }
  }
}
function bval(k) { return b3[k] b2[k] b1[k] }
function bclr(k) { b1[k] = ""; b2[k] = ""; b3[k] = "" }
function wput(x, unq) {
  badd("w", x); whave = 1
  if (unq && (x == "<" || x == ">")) { wrd = 1; wlast = 1 } else wlast = 0
}
function wend() {
  if (whave) { wf[wn] = wlast ? 2 : (wrd ? 1 : 0); wv[wn] = bval("w"); wn++ }
  bclr("w"); whave = 0; wrd = 0; wlast = 0
}
# The words of the current command (wbase..wn-1), redirections dropped, joined by US.
function wlist(   k, skip, first) {
  bclr("l"); skip = 0; first = 1
  for (k = wbase; k < wn; k++) {
    if (skip) { skip = 0; continue }
    if (wf[k] == 2) { skip = 1; continue }
    if (wf[k] == 1) continue
    if (!first) badd("l", US)
    badd("l", wv[k]); first = 0
  }
  return bval("l")
}
# A segment reaches bash (S, W) only when bash has something to check in it: its command word
# is sudo, eval, ssh, a shell, script, flock, an exempt command, gh, cd/pushd (so `$X gh …` is
# rescanned and a check sees the gh command) or an expansion ($X, ${X}, $(…)), or a word is a
# shell, script, flock (their -c) or env (its -S). Every segment but an exempt one adds its text
# and its unquoted words to T, which rule 2 reads.
function isx(x) { return x != "" && index(exempt, US x US) > 0 }
function interesting(x) { return x ~ /^(sudo|gh|bash|sh|eval|ssh|su|cd|pushd|script|flock)$/ || isx(x) }
# An expansion as the command word: kept when a later word is a -c flag, or the words after it
# (each further expansion skipped too) start an interesting command (`$X sudo id`).
function expkeep(   k) {
  for (k = CI + 1; k <= tn; k++) if (tv[k] ~ /^-[^-]*c/ || tv[k] ~ /^--command/) return 1
  while (index(CW, "$") && CI < tn) cmdword(CI + 1)
  return interesting(CW)
}
# reader(): the segment (tv, CW, CI set by cmdword(1)) only searches text, so a deny pattern
# among its words is a search pattern or a file name, not an access: grep and its kin, rg
# without --pre (which runs a command per file), behind no env (-S runs its string as the
# command). git grep is left out (-O runs a pager command).
function reader(   k, x) {
  if (CW !~ /^(grep|egrep|fgrep|zgrep|rg)$/) return 0
  for (k = 1; k < CI; k++) { x = tv[k]; sub(/.*\//, "", x); if (x == "env") return 0 }
  if (CW == "rg") for (k = CI + 1; k <= tn; k++) if (tv[k] ~ /^--pre/) return 0
  return 1
}
function emit(   k, b, keep, wl, c, cw, rd) {
  wend()
  c = bval("c")
  if (c ~ /[^ \t\n]/) {
    wl = wlist(); tn = split(wl, tv, US); cmdword(1); cw = CW; rd = reader()
    keep = interesting(CW)
    if (index(CW, "$")) keep = expkeep()
    for (k = 1; !keep && k <= tn; k++) {
      b = tv[k]; if (length(b) <= 256) sub(/.*\//, "", b)
      if (b ~ /^(sh|bash|dash|zsh|ksh|mksh|fish|busybox|su|script|flock|env)$/ || tv[k] ~ /^\$.*SHELL/) keep = 1
    }
    if (!isx(cw) && !rd) {
      badd("T", c); badd("T", "\n")
      for (k = 1; k <= tn; k++) { badd("T", tv[k]); badd("T", " ") }
      badd("T", "\n")
    }
    if (keep) printf "S%s%sW%s%s", c, RS1, wl, RS1
    if (allc) printf "C%s%s", wl, RS1
    nseg++
  }
  bclr("c"); wn = wbase
}
function hasb(   k) { for (k = 1; k <= np; k++) if (ftype[k] == "b") return 1; return 0 }
# A frame per open (…), $(…), `…` or arithmetic. A substitution saves its parent command (text,
# partial word, words wbase..wn-1) and starts its own words at wn.
function push(t, ret) {
  np++; ftype[np] = t; fret[np] = ret; fad[np] = ad
  if (t == "s" || t == "b") {
    fwb[np] = wbase; fwn[np] = wn
    fc1[np] = b1["c"]; fc2[np] = b2["c"]; fc3[np] = b3["c"]
    fw1[np] = b1["w"]; fw2[np] = b2["w"]; fw3[np] = b3["w"]; fwr[np] = wrd
    wbase = wn; bclr("c"); bclr("w"); whave = 0; wrd = 0; wlast = 0
  }
  st = "c"
}
function popsub() {
  emit()
  wbase = fwb[np]; wn = fwn[np]
  b1["c"] = fc1[np]; b2["c"] = fc2[np]; b3["c"] = fc3[np]; badd("c", "$()")
  b1["w"] = fw1[np]; b2["w"] = fw2[np]; b3["w"] = fw3[np]; badd("w", "$()")
  whave = 1; wrd = fwr[np]; wlast = 0
  st = fret[np]; ad = fad[np]; np--
}
function arith(ret, s) { push("a", ret); ad = 2; st = "A"; badd("c", s); badd("w", s); whave = 1; wlast = 0 }
# ${…} at i: modeled only when it holds plain characters (BSAFE) up to its }. Returns the
# index after it; anything else sets ok = 0.
function brace(i, n,   j, k) {
  for (j = i + 2; j <= n && ch[j] != "}"; j++) {
    if (ch[j] == "$" && j < n && index(AZ, ch[j + 1])) continue   # ${REPO:-$PWD}: a plain $NAME
    if (!index(BSAFE, ch[j])) { ok = 0; return n + 1 }
  }
  if (j > n) { ok = 0; return n + 1 }
  for (k = i; k <= j; k++) { badd("c", ch[k]); wput(ch[k], 0) }
  return j + 1
}
# CW/CW2: the command word (basename) of tv[1..tn], past assignments, wrappers (and their
# options; -n -a -u -C -s -I take a value, a duration after timeout is skipped), keywords, and
# `function NAME`.
function cmdword(start,   i, x) {
  i = start
  while (i <= tn) {
    x = tv[i]
    if (x == "command" && tv[i + 1] ~ /^-[vV]$/) { i = tn + 1; break }   # a lookup, runs nothing
    if (index(x, "=") > 0 || x ~ /^(env|command|exec|time|nohup|nice|builtin|coproc|timeout|xargs|setsid|\{|!|if|then|elif|else|do|while|until)$/) i++
    else if (x == "function") i += 2
    else if (i > start && x ~ /^-[nauCsI]$/) i += 2
    else if (i > start && (x ~ /^-/ || x ~ /^[0-9][0-9.]*[smhd]?$/)) i++
    else break
  }
  CW = ""; CW2 = ""; CI = i
  if (i > tn) return
  CW = tv[i]; if (length(CW) <= 256) sub(/.*\//, "", CW)
  if (CW ~ /^\{[^,]*,.*\}/) { CW = substr(CW, 2); sub(/,.*/, "", CW) }   # {sudo,id}
  if (i < tn) CW2 = tv[i + 1]
  if ((CW == "bash" || CW == "sh") && i < tn) { x = tv[i + 1]; sub(/.*\//, "", x); if (isx(x)) CW = x }
}
# A quoted body read by a consumer that is not a shell is data, unless its output goes on
# (a pipe, a process substitution: hfed). A consumer that may run it as shell code stays checked.
function datacmd() { return CW ~ /^(cat|tee|python|python3|node|jq|awk|sed)$/ }
# fed(): the heredocs of the current segment feed something further (| or a `(` after them).
function fed(   k) { for (k = 1; k <= nh; k++) if (hseg[k] == nseg && hnp[k] == np) hfed[k] = 1 }
function msgcmd() {
  return (CW == "git" && CW2 ~ /^(commit|tag|notes)$/) || (CW == "gh" && CW2 ~ /^(pr|issue|release)$/)
}
function heredoc(i, n,   j, dash, w, q, c, k, kind) {
  wend()
  j = i + 2; dash = 0
  if (ch[j] == "-") { dash = 1; j++ }
  while (j <= n && (ch[j] == " " || ch[j] == "\t")) j++
  w = ""; q = 0
  while (j <= n) {
    c = ch[j]
    if (c == "$" || c == "`") { ok = 0; return n + 1 }   # <<$'"'"'EOF'"'"': bash decodes it, the scan would not
    if (c == "\047" || c == "\"") {
      k = j + 1
      while (k <= n && ch[k] != c) { w = w ch[k]; k++ }
      if (k > n) { ok = 0; break }
      q = 1; j = k + 1; continue
    }
    if (c == "\\") { w = w ch[j + 1]; q = 1; j += 2; continue }
    if (c == " " || c == "\t" || index(";&|()<>", c)) break
    w = w c; j++
  }
  for (k = i; k < j; k++) badd("c", ch[k])
  if (w == "") { ok = 0; return j }
  # kind 1 is data; an unquoted body (q = 0) only when it is also inert(), judged at its end
  kind = 0
  tn = split(wlist(), tv, US); cmdword(1)
  if (isx(CW) || msgcmd()) kind = 1
  else if (np == 0 && datacmd()) kind = 3
  else if (CW == "cat" && np > 0 && ftype[np] == "s" && fret[np] == "d") {
    tn = 0
    for (k = fwb[np]; k < fwn[np]; k++) if (wf[k] == 0) tv[++tn] = wv[k]
    cmdword(1); if (msgcmd()) kind = 2
  }
  nh++; hdash[nh] = dash; hword[nh] = w; hkind[nh] = kind; hq[nh] = q; hseg[nh] = nseg; hnp[nh] = np; hfed[nh] = 0
  return j
}
# inert(body): an unquoted heredoc body that expands nothing executable: no $(…), no `…`, and
# no line ending in a backslash (bash joins it to the next line, so `$\` + `(…)` is a $(…)).
function inert(b) { return !index(b, "$(") && !index(b, "`") && b !~ /\\\n/ }
# run(i, n, stop): the end of the run of characters at i that are not in stop.
function run(i, n, stop) { while (i <= n && !index(stop, ch[i])) i++; return i }
# plain(line, i, j): characters i..j-1 are word text (quoted or plain, no redirection), one append.
function plain(line, i, j,   x) { x = substr(line, i, j - i); badd("c", x); badd("w", x); whave = 1; wlast = 0 }
function scanline(line,   n, i, c, nx, k, j) {
  n = split(line, ch, "")
  i = 1
  while (i <= n) {
    c = ch[i]; nx = (i < n) ? ch[i + 1] : ""
    if (st == "q") {
      if (c == "\047") { st = "c"; badd("c", c); i++; continue }
      j = run(i, n, "\047"); plain(line, i, j); i = j; continue
    }
    if (st == "Q") {
      if (c == "\\") ok = 0           # ANSI-C escapes are not decoded: the strict check decides
      if (c == "\047") st = "c"; else wput(c, 0)
      badd("c", c); i++; continue
    }
    if (st == "d") {
      if (c == "\\") {
        if (i == n) { contl = 1; i++; continue }
        if (nx == "$" || nx == "`" || nx == "\"" || nx == "\\") wput(nx, 0); else { wput(c, 0); wput(nx, 0) }
        if (nx == "`" && hasb()) ok = 0
        badd("c", c nx); i += 2; continue
      }
      if (c == "\"") { st = "c"; badd("c", c); i++; continue }
      if (c == "$" && nx == "{") { i = brace(i, n); continue }
      if (c == "$" && nx == "[") ok = 0
      if (c == "$" && nx == "(") { if (ch[i + 2] == "(") { arith("d", "$(("); i += 3 } else { push("s", "d"); i += 2 } continue }
      if (c == "`") { if (hasb()) ok = 0; push("b", "d"); i++; continue }
      j = run(i + 1, n, DSTOP); plain(line, i, j); i = j; continue
    }
    if (st == "A") {
      if (c == "$" && nx == "(") { if (ch[i + 2] == "(") { arith("A", "$(("); i += 3 } else { push("s", "A"); i += 2 } continue }
      if (c == "\\" && i == n) { contl = 1; i++; continue }
      if (!index(ASAFE, c)) ok = 0    # a quote, `, \, {, ;: not modeled inside arithmetic
      badd("c", c); wput(c, 0); i++
      if (c == "(") ad++
      else if (c == ")") {
        if (--ad == 1 && nx != ")") ok = 0   # bash reads $((a); b) as a command substitution
        if (ad == 0) { st = fret[np]; ad = fad[np]; np-- }
      }
      continue
    }
    # st == "c"
    if (c == "\\") {
      if (i == n) { contl = 1; i++; continue }     # backslash-newline: dropped, as bash does
      if (nx == "`" && hasb()) ok = 0
      badd("c", c nx); wput(nx, 0); i += 2; continue
    }
    if (c == "\047") { st = "q"; badd("c", c); whave = 1; wlast = 0; i++; continue }
    if (c == "$" && nx == "\047") { st = "Q"; badd("c", c nx); whave = 1; wlast = 0; i += 2; continue }
    if (c == "\"") { st = "d"; badd("c", c); whave = 1; wlast = 0; i++; continue }
    if (c == "`") {
      if (np > 0 && ftype[np] == "b") popsub()
      else { if (hasb()) ok = 0; push("b", "c") }
      i++; continue
    }
    if (c == "$" && nx == "{") { i = brace(i, n); continue }
    if (c == "$" && nx == "[") ok = 0
    if (c == "$" && nx == "(") { if (ch[i + 2] == "(") { arith("c", "$(("); i += 3 } else { push("s", "c"); i += 2 } continue }
    if (c == "(" && nx == "(" && !whave) { emit(); arith("c", "(("); i += 2; continue }
    if (c == "(") { fed(); emit(); push("u", "c"); i++; continue }
    if (c == ")") {
      if (np > 0 && ftype[np] == "s") popsub()
      else { if (np > 0 && ftype[np] == "u") np--; emit() }
      i++; continue
    }
    # a redirection operator holding & or |: >&2 2>&1 <&3 >| &> &>> (not a separator)
    if ((c == ">" || c == "<") && (nx == "&" || (c == ">" && nx == "|"))) {
      badd("c", c nx); wput(c, 1); wput(nx, 0); wlast = 1; i += 2; continue
    }
    if (c == "&" && nx == ">") { badd("c", c); wput(c, 0); i++; continue }
    if (c == "|" && nx == "|") { emit(); i += 2; continue }
    if (c == "|") { fed(); emit(); i++; continue }
    if (c == ";" || c == "&") { emit(); i++; continue }
    if (c == "#" && !whave) { i = n + 1; continue }  # a comment, to the end of the line
    if (c == " " || c == "\t") { wend(); badd("c", c); i++; continue }
    if (c == "<" && nx == "<") {
      if (ch[i + 2] == "<") { badd("c", "<<<"); wput("<", 1); wput("<", 1); wput("<", 1); i += 3; continue }
      i = heredoc(i, n); continue
    }
    if (c == "<" || c == ">") { wput(c, 1); badd("c", c); i++; continue }
    j = run(i + 1, n, CSTOP); plain(line, i, j); i = j
  }
  if (!ok) exit
  if (contl) { contl = 0; return }
  if (st == "c") {
    for (k = 1; k <= nh; k++) {
      if (hkind[k] == 2) hkind[k] = (hseg[k] == nseg && hnp[k] == np) ? 1 : 0
      else if (hkind[k] == 3) hkind[k] = hfed[k] ? 0 : 1
    }
    emit()
    if (nh > 0) { hb = 1; bclr("h") }
    return
  }
  if (nh > 0) { ok = 0; exit }
  badd("c", "\n"); wput("\n", 0)
}
function legacy(line,   n, i, c) {
  n = split(line, ch, ""); bclr("p")
  for (i = 1; i <= n; i++) {
    c = ch[i]
    if (index(";&|()`", c)) { lemit(bval("p")); bclr("p") } else badd("p", c)
  }
  lemit(bval("p"))
}
function lemit(p,   n, i, c, q, a) {
  bclr("c"); badd("c", p); wn = 0; wbase = 0; bclr("w"); whave = 0; wrd = 0; wlast = 0; q = ""
  n = split(p, a, "")
  for (i = 1; i <= n; i++) {
    c = a[i]
    if (q != "") {
      if (c == q) q = ""
      else if (q == "\"" && c == "\\") { i++; wput(a[i], 0) }
      else wput(c, 0)
      continue
    }
    if (c == "\047" || c == "\"") { q = c; whave = 1; wlast = 0 }
    else if (c == " " || c == "\t") wend()
    else if (c == "\\") { i++; wput(a[i], 0) }
    else wput(c, 1)
  }
  emit()
}
BEGIN {
  RS1 = "\036"; US = "\037"; st = "c"; np = 0; ok = 1; nh = 0; hb = 0; nseg = 0; ad = 0
  contl = 0; whave = 0; wrd = 0; wlast = 0; wn = 0; wbase = 0
  AZ = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
  BSAFE = AZ "#%:/?!@*+=.,^~ -[]"
  ASAFE = AZ " \t+-*/%<>=!&|^~?:,.#@[]()$"
  DSTOP = "\\\"$`"                       # what ends a plain run in "…"
  CSTOP = "\\\047\"`$()<>;&|# \t"       # … and unquoted
  bclr("c"); bclr("w"); bclr("T"); bclr("h")
}
# L: every raw line, and a backslash-newline chain once more joined, as bash reads it
mode == "L" {
  legacy($0)
  c = $0; n = 0
  while (n < length(c) && substr(c, length(c) - n, 1) == "\\") n++
  if (n % 2) { lj = lj substr(c, 1, length(c) - 1); lc++; next }
  if (lc) legacy(lj c)
  lj = ""; lc = 0; next
}
hb > 0 {
  c = $0
  if (hdash[hb]) sub(/^\t+/, "", c)
  if (c == hword[hb]) {
    if (hkind[hb] != 1 || (!hq[hb] && !inert(bval("h")))) printf "K%s%s", bval("h"), RS1
    bclr("h"); hb++
    if (hb > nh) { hb = 0; nh = 0 }
  } else { badd("h", $0); badd("h", "\n") }
  next
}
{ scanline($0) }
END {
  if (mode == "L" && lc) legacy(lj)
  if (mode != "L") {
    if (hb || nh || st != "c" || np > 0 || contl) ok = 0
    emit()
  }
  printf "T%s%sP%d", bval("T"), RS1, ok
}
'

# _scan <P|L> <text>: append the simple commands bash must look at to SR (raw) and SW (words),
# the kept heredoc bodies to KEPT, the text rule 2 reads to TEXT, and (with ALLC=1) every
# simple command's words to SC. SOK=1 iff the P scan closed.
_scan() {
  local out r recs=()
  SOK=0
  out=$(printf '%s' "$2" | LC_ALL=C awk -v mode="$1" -v exempt="$EXS" -v allc="$ALLC" "$SCAN_AWK" 2>/dev/null) || return 0
  IFS=$'\036' read -r -d '' -a recs <<<"$out" || true
  for r in ${recs[@]+"${recs[@]}"}; do
    case "$r" in
      S*) SR+=("${r#S}") ;;
      W*) SW+=("${r#W}") ;;
      C*) SC+=("${r#C}") ;;
      K*) KEPT=$KEPT${r#K} ;;
      T*) TEXT=$TEXT${r#T} ;;
      P1*) SOK=1 ;;
    esac
  done
}

# _setw <k>: W = the words of segment k.
_setw() {
  local l
  W=()
  [ -n "${SW[$1]}" ] || return 0
  IFS=$'\037' read -r -d '' -a W <<<"${SW[$1]}" || true
  l=$((${#W[@]} - 1))
  W[l]=${W[l]%$'\n'}
}

# _isx <name>: 0 iff <name> is one of guard.exempt_commands (EXS: joined by US, a US at each end).
_isx() { [ -n "$1" ] && case "$EXS" in *$'\037'"$1"$'\037'*) true ;; *) false ;; esac; }

# _base <word>: B = its basename. A word over 256 bytes is no command name and is kept whole:
# ${w##*/} is quadratic in bash, and a 100 KB --body is an everyday word.
_base() { B=$1; [ "${#B}" -gt 256 ] || B=${B##*/}; }

# _cmdword: CW = the command word of W (basename), past assignments, plain wrappers (and their
# options: -n -a -u -C -s -I take a value; a duration after timeout), shell keywords, `function
# NAME`, and a `bash`/`sh` in front of an exempt script; CW2 = the word after it, CI = its index.
# Mirrors cmdword in SCAN_AWK.
_cmdword() {
  local n=${#W[@]} i=0
  while [ "$i" -lt "$n" ]; do
    case "${W[i]}" in
      command) case "${W[i+1]:-}" in -v|-V) i=$n; break ;; esac; i=$((i + 1)) ;;   # -v: a lookup
      *=*|env|exec|time|nohup|nice|builtin|coproc|timeout|xargs|setsid|'{'|'!'|if|then|elif|else|do|while|until) i=$((i + 1)) ;;
      function) i=$((i + 2)) ;;
      -[nauCsI]) [ "$i" -gt 0 ] || break; i=$((i + 2)) ;;
      -*) [ "$i" -gt 0 ] || break; i=$((i + 1)) ;;
      *) [ "$i" -gt 0 ] && [[ ${W[i]} =~ $DUR_RE ]] || break; i=$((i + 1)) ;;
    esac
  done
  CW='' CW2='' CI=$i
  [ "$i" -lt "$n" ] || return 0
  CW=${W[i]} CW2=${W[i+1]:-}
  _base "$CW"; CW=$B
  case "$CW" in '{'*,*'}'*) CW=${CW#'{'}; CW=${CW%%,*} ;; esac   # {sudo,id}: brace expansion
  case "$CW" in bash|sh) _base "$CW2"; ! _isx "$B" || CW=$B ;; esac
  return 0
}

# _code: CODE = the code W runs as a string: eval's arguments, or the -c argument of a shell
# word anywhere in W (sh bash dash zsh ksh mksh fish busybox su, a $…SHELL… variable), past
# its options and their values (`nice bash --norc -o pipefail -c '…'`), or of script/flock
# (-c, -qc, --command[=]). A command word that is an expansion ($BASH, ${X}, $(…)) is not
# modeled: its -c code, or else its arguments as a command (`$X sudo id`), are code; so are
# flock's command words after the lock file. ARGS=1 when CODE is such argument words (they
# are re-quoted with %q, so the scan sees the same words), not a -c string. Empty when none.
_code() {
  local n=${#W[@]} k j w
  CODE='' ARGS=0
  if [ "$CW" = eval ]; then CODE="${W[*]:CI+1}"; return 0; fi
  # env -S'…' (a wrapper, so before CI) splits its string into a command
  for ((k = 0; k < n && k <= CI; k++)); do
    _base "${W[k]}"; [ "$B" = env ] || continue
    for ((j = k + 1; j < n; j++)); do
      w=${W[j]}
      case "$w" in
        -S|--split-string) CODE=${W[j+1]:-}; return 0 ;;
        --split-string=*) CODE=${w#*=}; return 0 ;;
        -S*) CODE=${w#-S}; return 0 ;;
        -*|*=*) ;;
        *) break ;;
      esac
    done
  done
  for ((k = CI; k < n; k++)); do
    _base "${W[k]}"
    case "$B" in
      sh|bash|dash|zsh|ksh|mksh|fish|busybox|su|'$'*SHELL*) ;;
      script|flock)
        for ((j = k + 1; j < n; j++)); do
          w=${W[j]}
          case "$w" in
            --command=*) CODE=${w#--command=}; return 0 ;;
            --command|-c|-[!-]*c) CODE=${W[j+1]:-}; return 0 ;;
            -[!-]*c*) CODE=${w#*c}; return 0 ;;
          esac
        done
        if [ "$B" = flock ]; then   # flock [options] <file> <command> [args]
          for ((j = k + 1; j < n; j++)); do
            case "${W[j]}" in
              -w|-E|--wait|--timeout|--conflict-exit-code) j=$((j + 1)) ;;
              -*) ;;
              *) break ;;
            esac
          done
          j=$((j + 1))
          if [ "$j" -lt "$n" ]; then printf -v CODE '%q ' "${W[@]:j}"; ARGS=1; return 0; fi
        fi
        continue ;;
      *'$'*) [ "$k" = "$CI" ] || continue ;;
      *) continue ;;
    esac
    for ((j = k + 1; j < n; j++)); do
      case "${W[j]}" in
        --) break ;;
        -o|+o|-O|+O) j=$((j + 1)) ;;
        --*) ;;
        [-+]*c*) CODE=${W[j+1]:-}; return 0 ;;
        [-+]*) ;;
        *) break ;;
      esac
    done
    if [ "$k" = "$CI" ] && [[ $B == *'$'* ]] && [ $((k + 1)) -lt "$n" ]; then
      printf -v CODE '%q ' "${W[@]:k+1}"; ARGS=1; return 0
    fi
  done
  return 0
}

# _script_argv: 0 iff the shell at W[CI] runs a script file, so the words after it are its argv,
# not code (`bash "$L/wt.sh" create --name '… sudo …'`). Its options come first: none may
# be a -c or -s cluster (code from a string or stdin), and the file is not stdin.
_script_argv() {
  local n=${#W[@]} j w
  for ((j = CI + 1; j < n; j++)); do
    w=${W[j]}
    case "$w" in
      --) j=$((j + 1)); break ;;
      -) return 1 ;;
      -o|+o|-O|+O|--rcfile|--init-file) j=$((j + 1)) ;;
      --*) ;;
      [-+]*[cs]*) return 1 ;;
      [-+]*) ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$n" ] || return 1
  case "${W[j]}" in -|/dev/stdin|/dev/fd/0|/proc/self/fd/0) return 1 ;; esac
  return 0
}

# _runs_sudo <raw>: 0 iff the segment (W, CW, CODE set) runs sudo: as its command word, as a
# word in an interpreter segment (bash/sh/…, su, eval, ssh; not a script's argv), or as a word
# in its -c code.
_runs_sudo() {
  [ "$CW" = sudo ] && return 0
  case "$CW" in
    bash|sh|dash|zsh|ksh|mksh) _script_argv || { [[ $1 =~ $WORD_SUDO_RE ]] && return 0; } ;;
    fish|busybox|su|eval|ssh) [[ $1 =~ $WORD_SUDO_RE ]] && return 0 ;;
  esac
  [ -n "$CODE" ] && [ "$ARGS" = 0 ] && [[ $CODE =~ $WORD_SUDO_RE ]]
}

# _cfg <config.sh args>: config.sh run in the hook's cwd, so the repo file is the cwd's repo's.
_cfg() {
  ( { [ -n "$CWD" ] && cd "$CWD" 2>/dev/null; } || cd / || exit 0
    bash "$HERE/config.sh" "$@" ) 2>/dev/null </dev/null
}

# _feed: the guard.checks input built from SC (see the header), one line per simple command.
# Records are joined by RS while they are built and turned into lines by one tr at the end,
# which also turns a newline inside a word into a space.
_feed() {
  local r i moved=0 out=''
  for ((i = 0; i < ${#SC[@]}; i++)); do
    # not ${r%$'\n'}: on a long word that does not end in a newline, bash tries every suffix
    r=${SC[i]}; [ "${r: -1}" != $'\n' ] || r=${r%?}
    W=()
    [ -z "$r" ] || IFS=$'\037' read -r -d '' -a W <<<"$r" || true
    [ "${#W[@]}" -eq 0 ] || W[${#W[@]}-1]=${W[${#W[@]}-1]%$'\n'}
    out=$out$moved$'\t'$r$'\036'
    _cmdword
    case "$CW" in cd|pushd) moved=1 ;; esac
  done
  printf '%s' "$out" | tr '\n\036' ' \n'
}

# _limited <cmd> <args…>: run a check with a time limit (HI_GUARD_CHECK_TIMEOUT seconds,
# default 5), so a hung check cannot stall every Bash call; past it the check counts as failed
# (allow). perl's alarm is on macOS and most Linux; without perl the check runs unlimited.
_limited() {
  local t=${HI_GUARD_CHECK_TIMEOUT:-5}
  if command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV or exit 127' "$t" "$@"
  else "$@"; fi
}

# _checks <cwd>: run guard.checks (CHECKS, one path per line) on the feed. Prints D<TAB>reason
# or A<TAB>reason, nothing to allow.
_checks() {
  local cwd=$1 feed c out line ask=''
  feed=$(_feed; printf x); feed=${feed%x}
  while IFS= read -r c; do
    case "$c" in '~/'*) c=$HOME/${c#'~/'} ;; esac
    case "$c" in /*) ;; *) continue ;; esac
    [ -f "$c" ] && [ -x "$c" ] || continue
    out=$( { [ -n "$cwd" ] && cd "$cwd" 2>/dev/null; } || cd /
           printf '%s' "$feed" | _limited "$c" "$cwd" 2>/dev/null ) || continue
    while IFS= read -r line; do
      case "$line" in
        D$'\t'?*) printf '%s\n' "$line"; return 0 ;;
        A$'\t'?*) [ -n "$ask" ] || ask=$line ;;
      esac
    done <<EOF
$out
EOF
  done <<EOF
$CHECKS
EOF
  [ -z "$ask" ] || printf '%s\n' "$ask"
  return 0
}

pretool() {
  local vals tool cwd cmd p flat r x='' k=0 scans=0 ok=0 pend j files checked
  MORE=()
  vals=$(jq -r 'if type == "object" then
                  [(.tool_name // ""), (.cwd // ""), (.tool_input.command? // "")]
                  | map(if type == "string" then . else "" end) | @sh
                else empty end' 2>/dev/null) || return 0
  [ -n "$vals" ] || return 0
  eval "set -- $vals"
  tool=${1:-} cwd=${2:-} cmd=${3:-}
  [ "$tool" = Bash ] && [ -n "$cmd" ] || return 0

  # The configuration, read in .cwd. No config file at all (the common case) costs one call.
  CWD=$cwd EXS='' ALLC='' CHECKS=''
  files=$(_cfg files)
  if [ -n "$files" ]; then
    while IFS= read -r p; do
      case "$p" in ''|*[\\$'\036\037']*) continue ;; esac   # no awk -v escapes, no separators
      _base "$p"; EXS=$EXS$B$'\037'
    done <<EOF
$(_cfg list --user .guard.exempt_commands)
EOF
    [ -z "$EXS" ] || EXS=$'\037'$EXS
    CHECKS=$(_cfg list --user .guard.checks)
    [ -z "$CHECKS" ] || ALLC=1
  fi

  # SR/SW: the simple commands; KEPT: heredoc bodies checked the strict way. A command the
  # scan cannot close (or one too big, or holding the record separators) is all strict.
  SR=() SW=() SC=() KEPT='' TEXT=''
  case "$cmd" in
    *[$'\036\037']*) ;;
    *) [ "${#cmd}" -gt "$SCAN_MAX" ] || { _scan P "$cmd"; ok=$SOK; } ;;
  esac
  [ "$ok" = 1 ] || { SR=() SW=() SC=() TEXT=''; KEPT=$cmd; }

  # rule 1 on every segment but an exempt one; KEPT is scanned the strict way. A shell's -c
  # code and eval's arguments are scanned in turn, their commands appended.
  # Code the P scan cannot close (or past 16 scans) is checked the strict way: it joins KEPT,
  # one L scan per round (MORE, joined once: an append per code is quadratic in bash).
  pend=$KEPT
  while :; do
    if [ "$k" -ge "${#SR[@]}" ]; then
      if [ "${#MORE[@]}" -gt 0 ]; then
        printf -v j '%s\n' "${MORE[@]}"; MORE=(); KEPT=$KEPT$j; pend=$pend$j
      fi
      [ -n "$pend" ] || break
      _scan L "$pend"; pend=''; continue
    fi
    _setw "$k"; _cmdword
    if ! _isx "$CW"; then
      _code
      if [ -n "$CODE" ] && [ "$scans" -lt 16 ]; then
        scans=$((scans + 1))
        _scan P "$CODE"
        [ "$SOK" = 1 ] || MORE+=("$CODE")
      elif [ -n "$CODE" ]; then
        MORE+=("$CODE")
      fi
      if _runs_sudo "${SR[k]}"; then x=1; break; fi
    fi
    k=$((k + 1))
  done
  flat=''   # tr, not ${KEPT//…}: bash's pattern substitution is quadratic on a long text
  [ -z "$KEPT" ] || flat=$(printf '%s' "$KEPT" | tr '\n' ';')
  if [ "$x" = 1 ] || [[ $flat =~ $SUDO_RE ]] || [[ $flat =~ $SSH_SUDO_RE ]]; then
    _out deny "hi-guard: sudo is not run from an agent session. Do not work around this: show the user the exact command and why it is needed, and ask them to run it themselves."
    return 0
  fi
  [ -n "$files" ] || return 0

  # rule 2
  checked=$TEXT$KEPT
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [[ $checked =~ $p ]]; then
      _out deny "hi-guard: the command matches the denied pattern '$p' (guard.deny_patterns). That access is the user's: do not work around it; tell the user what you need and why, and let them run it or grant it."
      return 0
    fi
  done <<EOF
$(_cfg list .guard.deny_patterns)
EOF

  # rule 3: guard.checks
  [ -n "$CHECKS" ] || return 0
  r=$(_checks "$cwd")
  case "$r" in
    D$'\t'*) _out deny "${r#D$'\t'}" ;;
    A$'\t'*) _out ask "${r#A$'\t'}" ;;
  esac
  return 0
}

case "${1:-}" in
  pretool) pretool ;;
  *) echo 'usage: guard.sh pretool   (PreToolUse hook JSON on stdin)' >&2 ;;
esac
exit 0
