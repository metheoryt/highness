#!/usr/bin/env bash
# lib/orca.sh — Orca BINARY RESOLUTION. Kept out of orca_test.sh so that file's
# 55 assertions stay exactly as they were pinned.
#
# orca.sh used to default to a bare `orca` (`ORCA="${HI_ORCA:-orca}"`). It
# was deferred once on the reasoning that `create-cmd` only prints — but $ORCA is
# EXECUTED by have_orca / available / current / siblings, and `available` runs on
# every ordinary path as the worktree provisioning probe. On Linux
# bare `orca` normally resolves to the GNOME Orca screen reader (/usr/bin/orca),
# so that probe could start speech on the dev's desktop.
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
O="$LIB/orca.sh"

READY='{"ok":true,"result":{"app":{"running":true},"runtime":{"state":"ready","reachable":true}}}'

# The success-path assertions below build a PATH from scratch and drive `available`
# all the way through its jq parsing, so jq has to be on that PATH. It is not always
# in /usr/bin: Homebrew puts it in /opt/homebrew/bin, and this team is macOS-centric.
# Appended, never prepended, so the stub dir still wins.
# Deliberately NOT added to the fail-closed PATHs ("/usr/bin:/bin" below): those never
# reach jq, and a real `orca` / `orca-ide` sitting in jq's directory would satisfy
# `command -v` and make the fail-closed assertions pass for the wrong reason.
JQDIR=$(command -v jq 2>/dev/null); [ -n "$JQDIR" ] && JQDIR=$(dirname "$JQDIR")
jqpath() { if [ -n "$JQDIR" ]; then printf '%s:%s' "$1" "$JQDIR"; else printf '%s' "$1"; fi; }

# --- the bare-`orca` default is gone from the source --------------------------
o=$(cat "$O")
assert_not_contains "orca.sh: no bare-orca default" "$o" '${HI_ORCA:-orca}'
assert_contains     "orca.sh: honours ORCA_CLI_COMMAND" "$o" 'ORCA_CLI_COMMAND'
assert_contains     "orca.sh: prefers orca-ide on Linux" "$o" 'orca-ide'

# Two stub dirs so we can tell WHICH binary actually ran.
d1=$(mktemp -d "$SANDBOX/tmp.XXXXXX"); d2=$(mktemp -d "$SANDBOX/tmp.XXXXXX")
mk() { # mk <dir> <name>
  { printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> "%s/argv.%s"\n' "$1" "$2"
    printf 'echo %s\n' "'$READY'"
  } > "$1/$2"
  chmod +x "$1/$2"
}
ran() { [ -f "$1/argv.$2" ] && echo yes || echo no; }

# --- HI_ORCA outranks ORCA_CLI_COMMAND ---------------------------------
rm -f "$d1"/argv.* "$d2"/argv.*
mk "$d1" orca; mk "$d2" orca
out=$(HI_ORCA="$d1/orca" ORCA_CLI_COMMAND="$d2/orca" bash "$O" available); rc=$?
assert_status "resolve: HI_ORCA alongside ORCA_CLI_COMMAND exits 0" 0 "$rc"
assert_eq     "resolve: available is ok"                    "ok"  "$out"
assert_eq     "resolve: HI_ORCA's stub ran"           "yes" "$(ran "$d1" orca)"
assert_eq     "resolve: ORCA_CLI_COMMAND's stub did not run" "no" "$(ran "$d2" orca)"

# --- ORCA_CLI_COMMAND is honored when HI_ORCA is unset ------------------
rm -f "$d1"/argv.* "$d2"/argv.*
out=$(HI_ORCA= ORCA_CLI_COMMAND="$d2/orca" bash "$O" available); rc=$?
assert_status "resolve: ORCA_CLI_COMMAND fallback exits 0" 0 "$rc"
assert_eq     "resolve: ORCA_CLI_COMMAND's stub ran"       "yes" "$(ran "$d2" orca)"
assert_eq     "resolve: HI_ORCA's stub did not run"  "no"  "$(ran "$d1" orca)"

rm -rf "$d1" "$d2"

# --- platform-specific tail ---------------------------------------------------
# A constructed PATH is scoped to the one subprocess it is set on, so it cannot
# bleed into sibling tests.
pathdir=$(mktemp -d "$SANDBOX/tmp.XXXXXX")
mk "$pathdir" orca-ide
mk "$pathdir" orca   # sibling — must NEVER run on Linux

if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
  # Case 2: orca-ide on PATH wins; the sibling `orca` (the screen reader's name)
  # must not be touched.
  rm -f "$pathdir"/argv.*
  out=$(PATH="$(jqpath "$pathdir:/usr/bin:/bin")" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" available); rc=$?
  assert_status "resolve/linux: orca-ide on PATH exits 0"        0 "$rc"
  assert_eq     "resolve/linux: orca-ide stub ran"               "yes" "$(ran "$pathdir" orca-ide)"
  assert_eq     "resolve/linux: sibling orca stub did NOT run"   "no"  "$(ran "$pathdir" orca)"

  # Case 3: no overrides, no orca-ide → fail closed. This is the whole point:
  # `available` must refuse rather than execute /usr/bin/orca, the screen reader.
  rm -f "$pathdir"/argv.*
  out=$(PATH="/usr/bin:/bin" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" available); rc=$?
  assert_status   "resolve/linux: no orca-ide, no overrides exits 1" 1 "$rc"
  assert_contains "resolve/linux: says unavailable"          "$out" 'unavailable:'
  assert_contains "resolve/linux: names ORCA_CLI_COMMAND"    "$out" 'ORCA_CLI_COMMAND'
  assert_contains "resolve/linux: names HI_ORCA"       "$out" 'HI_ORCA'
  assert_contains "resolve/linux: names orca-ide"            "$out" 'orca-ide'
  assert_contains "resolve/linux: names the screen reader"   "$out" 'screen reader'
  assert_eq       "resolve/linux: nothing was executed"      "no"  "$(ran "$pathdir" orca)"

  # current/siblings degrade silently rather than executing anything.
  rm -f "$pathdir"/argv.*
  out=$(PATH="/usr/bin:/bin" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" current); rc=$?
  assert_status "resolve/linux: current exits 1 when unresolvable" 1 "$rc"
  assert_eq     "resolve/linux: current prints nothing"            ""   "$out"
  out=$(PATH="/usr/bin:/bin" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" siblings /r); rc=$?
  assert_status "resolve/linux: siblings exits 1 when unresolvable" 1 "$rc"
  assert_eq     "resolve/linux: siblings prints nothing"            ""  "$out"
  assert_eq     "resolve/linux: still nothing executed"             "no" "$(ran "$pathdir" orca)"
else
  # Off Linux there is no screen-reader collision, so bare `orca` is the default.
  rm -f "$pathdir"/argv.*
  out=$(PATH="$(jqpath "$pathdir:/usr/bin:/bin")" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" available); rc=$?
  assert_status "resolve/other: bare orca is the default off Linux" 0 "$rc"
  assert_eq     "resolve/other: the orca stub ran" "yes" "$(ran "$pathdir" orca)"
fi

# --- create-cmd still needs no binary at all ---------------------------------
# It only PRINTS, so an unresolvable Orca must never block the plan.
out=$(PATH="/usr/bin:/bin" HI_ORCA= ORCA_CLI_COMMAND= \
      bash "$O" create-cmd --repo /r --name wt --base main --no-parent); rc=$?
assert_status   "create-cmd: prints with no resolvable binary" 0 "$rc"
assert_contains "create-cmd: still emits the create line"      "$out" 'orca worktree create '

rm -rf "$pathdir"

# --- `resolve` — the value that replaces create-cmd's literal `orca` ----------
# create-cmd's line is pinned to a literal `orca worktree create ` prefix (orca_test.sh's
# assertions depend on it), so worktree provisioning
# must swap that literal for the RESOLVED binary before it shows the line — the dev
# confirms the shown line and then runs it. Before this, fixing `available` (which used
# to fail on Linux and skip the whole section) un-skipped a print-and-run path whose
# first token was a bare `orca` — /usr/bin/orca, the GNOME screen reader.
out=$(HI_ORCA=/opt/orca-ide bash "$O" resolve 2>/dev/null); rc=$?
assert_status "resolve: exits 0 with an override" 0 "$rc"
assert_eq     "resolve: stdout is the binary and nothing else" "/opt/orca-ide" "$out"
out=$(HI_ORCA= ORCA_CLI_COMMAND=/opt/orca-cli bash "$O" resolve 2>/dev/null); rc=$?
assert_status "resolve: honors ORCA_CLI_COMMAND" 0 "$rc"
assert_eq     "resolve: prints ORCA_CLI_COMMAND's value" "/opt/orca-cli" "$out"

rdir=$(mktemp -d "$SANDBOX/tmp.XXXXXX"); mk "$rdir" orca-ide; mk "$rdir" orca
if [ "$(uname -s 2>/dev/null)" = "Linux" ]; then
  # The composed line: exactly what worktree provisioning shows and the dev then runs.
  bin=$(PATH="$rdir:/usr/bin:/bin" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" resolve); rc=$?
  cmd=$(bash "$O" create-cmd --repo /r --name wt --base main --no-parent)
  run="$bin ${cmd#orca }"
  assert_status "resolve/linux: exits 0 with orca-ide on PATH"  0 "$rc"
  assert_eq     "resolve/linux: picks orca-ide over the sibling orca" "orca-ide" "$bin"
  assert_eq     "compose/linux: the shown line's first token is the resolved binary" \
                "orca-ide" "${run%% *}"
  # Inversion guard: if the skill went back to showing create-cmd's line as-is, the
  # confirmed command would start /usr/bin/orca — the screen reader — on the dev's box.
  case "$run" in 'orca '*) first=bare-orca ;; *) first=resolved ;; esac
  assert_eq     "compose/linux: the line does NOT begin with a bare orca" "resolved" "$first"
  assert_contains "compose/linux: it is still the create command" "$run" 'worktree create --repo'

  # Resolution failure → the section SKIPS. stdout must be empty, so a caller that
  # ignores the exit status cannot mistake a reason — or a bare `orca` — for a binary.
  out=$(PATH="/usr/bin:/bin" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" resolve 2>/dev/null); rc=$?
  assert_status "resolve/linux: unresolvable exits 1"                 1 "$rc"
  assert_eq     "resolve/linux: unresolvable prints nothing on stdout" "" "$out"
  err=$(PATH="/usr/bin:/bin" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" resolve 2>&1 >/dev/null)
  assert_contains "resolve/linux: the reason goes to stderr"     "$err" 'ORCA_CLI_COMMAND'
  assert_contains "resolve/linux: stderr names the screen reader" "$err" 'screen reader'
  # What a caller following worktree provisioning does with that: skip, never fall back.
  if bin=$(PATH="/usr/bin:/bin" HI_ORCA= ORCA_CLI_COMMAND= bash "$O" resolve 2>/dev/null)
  then decision="composed a line with [$bin]"; else decision=skipped; fi
  assert_eq "resolve/linux: unresolvable skips instead of falling back" "skipped" "$decision"
fi
rm -rf "$rdir"

assert_summary
