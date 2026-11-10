#!/usr/bin/env bash
# lib/wt.sh dispatch — a new session never sits unseen on a dialog: folder trust is copied from
# the repo's own trust into the config the session runs under (highness#9), extra read-only dirs
# come from dispatch.read_dirs with edits denied (highness#22), and a new session that still
# opens on a dialog is reported with exit 6.
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_assert.sh"
. "$HERE/_sandbox.sh"
. "$HERE/_wt_fixture.sh"
col() { printf '%s\n' "$1" | cut -f"$2"; }
U=11111111-2222-3333-4444-555555555555
export HI_PLUGIN_DIR=/opt/hi

mk_repo; cd "$R"
row=$(bash "$WT" create --kind ticket --key AB-7 --name 'AB-7 trust' --base main --branch task/AB-7 2>/dev/null)
P=$(col "$row" 1); PP=$(cd "$P" && pwd -P); RP=$(cd "$R" && pwd -P)
row=$(bash "$WT" create --kind work --key other --name other --base main --branch work/other 2>/dev/null)
O=$(cd "$(col "$row" 1)" && pwd -P)
printf 'Go.\n' > "$SANDBOX/brief.md"
C="$CLAUDE_CONFIG_DIR"; CJ="$C/.claude.json"
# cfg <file> <trusted path>…: a Claude Code config whose projects trust those paths.
cfg() { local f=$1; shift
  jq -n --args '{numStartups: 3, projects: ($ARGS.positional | map({key: ., value: {hasTrustDialogAccepted: true, allowedTools: []}}) | from_entries)}' "$@" > "$f"
  chmod 600 "$f"; }
trusted() { jq -r --arg k "$2" '.projects[$k].hasTrustDialogAccepted // false' "$1"; }
go() { HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" "$@" 2>"$SANDBOX/err"; }

# --- the account: the dispatcher's CLAUDE_CONFIG_DIR is named on the line, since a tmux window
# gets the tmux server's environment, not the caller's
out=$(go)
assert_contains "account: the line names the dispatcher's config dir" "$(printf '%s\n' "$out" | sed -n 2p)" \
  "&& env CLAUDE_CONFIG_DIR=$C claude "
assert_eq "account: recorded" "$C" "$(bash "$WT" rec get --ticket AB-7 config_dir)"
out=$(env -u CLAUDE_CONFIG_DIR HI_TMUX=none bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" 2>/dev/null)
assert_not_contains "account: none set, none named" "$(printf '%s\n' "$out" | sed -n 2p)" "CLAUDE_CONFIG_DIR"

# --- folder trust (highness#9)
# another worktree of the repo is trusted (as Orca trusts each it launches an agent in): the new
# one is trusted too, in the same file, with its mode and every other key kept
cfg "$CJ" "$O" /elsewhere
go >/dev/null
assert_eq "trust: the workspace is trusted" true "$(trusted "$CJ" "$PP")"
assert_eq "trust: other keys kept" 3 "$(jq -r .numStartups "$CJ")"
assert_eq "trust: other projects kept" true "$(trusted "$CJ" /elsewhere)"
assert_eq "trust: mode kept" 600 "$(stat -c %a "$CJ" 2>/dev/null || stat -f %Lp "$CJ")"
assert_contains "trust: said" "$(cat "$SANDBOX/err")" "trusted $PP in $CJ"
assert_eq "trust: no lock left" no "$([ -e "$CJ.lock" ] && echo yes || echo no)"
# the main checkout is trusted: Claude Code already counts the worktree as trusted, no write
cfg "$CJ" "$RP"
go >/dev/null
assert_eq "main trusted: no key written" false "$(trusted "$CJ" "$PP")"
assert_not_contains "main trusted: nothing said" "$(cat "$SANDBOX/err")" "trusted $PP"
# nothing of the repo is trusted: trust is the person's call, never made here
cfg "$CJ" /elsewhere
go >/dev/null
assert_eq "untrusted repo: not written" false "$(trusted "$CJ" "$PP")"
assert_contains "untrusted repo: says the session will ask" "$(cat "$SANDBOX/err")" "the session will ask whether to trust $PP"
# a trusted folder above the repo is not the repo's trust (Claude Code stops at the git root)
cfg "$CJ" "$(dirname "$RP")"
go >/dev/null
assert_eq "a trusted parent dir: not written" false "$(trusted "$CJ" "$PP")"
# --config-dir: written into that account's file, from the dispatcher's own trust of the repo
D="$SANDBOX/acct two"; mkdir -p "$D"; cfg "$D/.claude.json" /elsewhere; cfg "$CJ" "$RP"
go --config-dir "$D" >/dev/null
assert_eq "other account: trusted there" true "$(trusted "$D/.claude.json" "$PP")"
assert_eq "other account: the dispatcher's file untouched" false "$(trusted "$CJ" "$PP")"
# an older account layout keeps its config in <dir>/.config.json: that file is the one read
D2="$SANDBOX/acct3"; mkdir -p "$D2"; cfg "$D2/.config.json" "$RP"; cfg "$D2/.claude.json"
cfg "$CJ" "$O"
go --config-dir "$D2" >/dev/null
assert_eq ".config.json: main checkout trusted there, nothing written" false "$(trusted "$D2/.claude.json" "$PP")"
cfg "$D2/.config.json"
go --config-dir "$D2" >/dev/null
assert_eq ".config.json: written there" true "$(trusted "$D2/.config.json" "$PP")"
assert_eq ".config.json: not into .claude.json" false "$(trusted "$D2/.claude.json" "$PP")"
# a held lock is never broken
cfg "$CJ" "$O"; mkdir "$CJ.lock"
HI_TRUST_TRIES=1 go >/dev/null
assert_eq "lock held: not written" false "$(trusted "$CJ" "$PP")"
assert_contains "lock held: said" "$(cat "$SANDBOX/err")" ".lock is held"
assert_eq "lock held: left in place" yes "$([ -d "$CJ.lock" ] && echo yes || echo no)"
rmdir "$CJ.lock"
# an empty .config.json beside a non-empty .claude.json is not the one read
D4="$SANDBOX/acct4"; mkdir -p "$D4"; : > "$D4/.config.json"; cfg "$D4/.claude.json" "$O"
go --config-dir "$D4" >/dev/null
assert_eq "empty .config.json: .claude.json written" true "$(trusted "$D4/.claude.json" "$PP")"
# a review tree holds someone else's branch: another worktree's trust is not borrowed for it,
# only the main checkout's (here from the dispatcher's own config into another account's)
RV=$(col "$(bash "$WT" create --kind review --key 9 --name 'review 9' --detach "$(git -C "$R" rev-parse HEAD)" 2>/dev/null)" 1)
RVP=$(cd "$RV" && pwd -P)
cfg "$CJ" "$O"
HI_TMUX=none bash "$WT" dispatch "$RV" --brief "$SANDBOX/brief.md" >/dev/null 2>"$SANDBOX/err"
assert_eq "review: a sibling's trust is not borrowed" false "$(trusted "$CJ" "$RVP")"
assert_contains "review: says the session will ask" "$(cat "$SANDBOX/err")" "will ask whether to trust $RVP"
D5="$SANDBOX/acct5"; mkdir -p "$D5"; cfg "$D5/.claude.json"; cfg "$CJ" "$RP"
HI_TMUX=none bash "$WT" dispatch "$RV" --brief "$SANDBOX/brief.md" --config-dir "$D5" >/dev/null 2>&1
assert_eq "review: the main checkout's trust is copied" true "$(trusted "$D5/.claude.json" "$RVP")"
# no config file: none created
rm -f "$CJ"
go >/dev/null
assert_eq "no config: none created" no "$([ -e "$CJ" ] && echo yes || echo no)"

# --- a new session that opens on a dialog: exit 6, the row still printed, the screen shown
RULE='────────────────────────────────────────'
TRUST=" Accessing workspace:
 $PP
 Quick safety check: Is this a project you created or one you trust?
 ❯ No, exit
   Yes, I trust this folder
 Enter to confirm · Esc to cancel"
printf '%s\n%s\n' "$RULE" "$TRUST" > "$FX/tmux-pane"; reset_log
out=$(bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "tmux trust dialog: exit 6" 6 "$rc"
assert_eq "tmux trust dialog: the row is printed" "$U	tmux	hi:AB-7 trust" "$out"
assert_contains "tmux trust dialog: names it" "$(cat "$SANDBOX/err")" "stopped on Claude Code's folder-trust dialog"
assert_contains "tmux trust dialog: the screen tail" "$(cat "$SANDBOX/err")" "Yes, I trust this folder"
assert_contains "tmux: the pane is read by window id" "$(logged)" "tmux capture-pane -p -t @7"
printf '%s\n%s\n%s\n' "$RULE" " Do you want to proceed?" " ❯ 1. Yes" > "$FX/tmux-pane"
printf '%s\n' "   2. No" " Esc to cancel" >> "$FX/tmux-pane"
bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" >/dev/null 2>"$SANDBOX/err"
assert_status "tmux permission dialog: exit 6" 6 "$?"
assert_contains "tmux permission dialog: said" "$(cat "$SANDBOX/err")" "opened a dialog and waits for an answer"
printf '%s\n' "❯ Read the brief" "✽ Thinking… (2s)" "$RULE" "❯ " "$RULE" > "$FX/tmux-pane"
bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" >/dev/null 2>"$SANDBOX/err"
assert_status "tmux turn running: exit 0" 0 "$?"
rm -f "$FX/tmux-pane"
bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" >/dev/null 2>&1
assert_status "tmux nothing on screen: exit 0" 0 "$?"
# a session that waits for gortex first is not watched: it has not started yet
G=$(git -C "$P" rev-parse --absolute-git-dir)
printf '%s\n%s\n' "$RULE" "$TRUST" > "$FX/tmux-pane"
sleep 5 & sp=$!; echo "$sp" > "$G/gortex-track.pid"; reset_log
bash "$WT" dispatch "$P" --brief "$SANDBOX/brief.md" >/dev/null 2>"$SANDBOX/err"
assert_status "gortex wait: exit 0" 0 "$?"
assert_not_contains "gortex wait: not watched" "$(logged)" "capture-pane"
assert_contains "gortex wait: said" "$(cat "$SANDBOX/err")" "cannot watch it for a dialog"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null; rm -f "$G/gortex-track.pid" "$FX/tmux-pane"
# Orca: the new terminal's rendered screen
orca_on
row=$(bash "$WT" create --kind work --key orc --name orc --base main --branch work/orc 2>/dev/null)
OP=$(col "$row" 1)
printf '%s\n%s\n' "$RULE" "$TRUST" | jq -R . | jq -s '{ok:true,result:{terminal:{source:"screen",tail:.}}}' > "$FX/read.json"
reset_log
out=$(bash "$WT" dispatch "$OP" --brief "$SANDBOX/brief.md" 2>"$SANDBOX/err"); rc=$?
assert_status "orca trust dialog: exit 6" 6 "$rc"
assert_eq "orca trust dialog: the row" "$U	orca	h1" "$out"
assert_contains "orca: the new terminal is read" "$(logged)" "orca terminal read --terminal h1 --screen --json"
assert_contains "orca trust dialog: names it" "$(cat "$SANDBOX/err")" "folder-trust dialog"
rm -f "$FX/read.json"; orca_off

# --- extra read-only dirs (highness#22): dispatch.read_dirs, from the user's own file only
mkdir -p "$HOME/sib/reference" "$SANDBOX/team plugin"
SIB=$(cd "$HOME/sib" && pwd -P); TP=$(cd "$SANDBOX/team plugin" && pwd -P)
mkdir -p "$XDG_CONFIG_HOME/highness"
jq -n --arg tp "$TP" --arg ws "$(dirname "$PP")" --arg in "$PP/sub" \
  '{dispatch: {read_dirs: ["~/sib", $tp, "/no/such/dir", $ws, $in]}}' > "$XDG_CONFIG_HOME/highness/config.json"
mkdir -p "$PP/sub"
out=$(go); L=$(printf '%s\n' "$out" | sed -n 2p)
assert_contains "read dirs: ~ expanded, added" "$L" "--add-dir $SIB "
assert_contains "read dirs: a path with a space, quoted" "$L" "--add-dir '$TP' "
assert_contains "read dirs: before --settings, after the plugin root" "$L" "--add-dir /opt/hi --add-dir $SIB --add-dir '$TP' --settings"
assert_contains "read dirs: edits denied" "$L" "Edit(/$SIB/**)"
assert_contains "read dirs: edits denied, spaced path" "$L" "Edit(/$TP/**)"
assert_not_contains "read dirs: a missing dir left out" "$L" "/no/such/dir"
assert_contains "read dirs: a missing dir said" "$(cat "$SANDBOX/err")" "/no/such/dir is not a directory"
assert_not_contains "read dirs: a dir holding the workspace left out" "$L" "--add-dir $(dirname "$PP") "
assert_contains "read dirs: holding said" "$(cat "$SANDBOX/err")" "holds the workspace"
assert_not_contains "read dirs: a dir inside the workspace left out" "$L" "$PP/sub"
assert_contains "read dirs: inside said" "$(cat "$SANDBOX/err")" "is inside the workspace"
assert_contains "read dirs: the session flags still follow" "$L" "--settings"
assert_eq "read dirs: the session id after the dirs" 1 "$(printf '%s' "$L" | grep -c "' --session-id $U ")"
rm -f "$XDG_CONFIG_HOME/highness/config.json"
# a repo's own file cannot open reads outside the workspace: it comes with any clone
mkdir -p "$R/.claude"; jq -n '{dispatch: {read_dirs: ["~/sib"]}}' > "$R/.claude/highness.json"
out=$(go)
assert_not_contains "read dirs: a repo file is ignored" "$(printf '%s\n' "$out" | sed -n 2p)" "$SIB"
rm -f "$R/.claude/highness.json"
assert_summary
