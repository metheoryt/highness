#!/usr/bin/env bash
# _wt_fixture.sh — shared fixtures for the wt_*_test.sh files. Source it after _sandbox.sh.
#
# A real repo with a real bare origin, plus stubs for orca, gh, tmux, gortex and the two
# worktree dispatchers. Every stub appends its argv to one log, so a test can assert what was
# (and what was NOT) called. The orca stub is realistic on purpose: `worktree create` makes a
# real git worktree and answers with a Windows UNC path, and `worktree list` is generated from
# `git worktree list`. The UNC-to-POSIX conversion and the id-vs-path split are exercised, not
# mocked.
WT="$HERE/../lib/wt.sh"
STUB="$SANDBOX/stub"; FX="$SANDBOX/fx"; mkdir -p "$STUB" "$FX" "$FX/prs"
export WT_TEST_LOG="$SANDBOX/argv.log" FX FX_ORCA_ROOT="$SANDBOX/orca-ws"
: > "$WT_TEST_LOG"; mkdir -p "$FX_ORCA_ROOT"
reset_log() { : > "$WT_TEST_LOG"; }
logged() { tr '\n' ';' < "$WT_TEST_LOG"; }

cat > "$STUB/orca" <<'SH'
#!/usr/bin/env bash
printf 'orca %s\n' "$*" >> "$WT_TEST_LOG"
unc() { printf '%s%s' '\\wsl.localhost\d' "$(printf '%s' "$1" | tr '/' '\\')"; }
case "$1 $2" in
  'status --json') cat "$FX/status.json" 2>/dev/null || exit 1 ;;
  'repo list') jq -n --arg p "$FX_REPO" '{ok:true,result:{repos:[{id:"R",path:$p}]}}' ;;
  'worktree list')
    git -C "$FX_REPO" worktree list --porcelain | awk '/^worktree /{print substr($0,10)}' |
      while IFS= read -r p; do
        [ -n "${FX_ORCA_ONLY:-}" ] && [ "$p" != "$FX_ORCA_ONLY" ] && [ "$p" != "$FX_REPO" ] && continue
        jq -n --arg u "$(unc "$p")" '{path:$u, id:("R::"+$u), branch:""}'
      done | jq -s '{ok:true,result:{worktrees:.}}' ;;
  'worktree create')
    # --branch names the branch (Orca 1.4.244+); without it Orca cuts `dev/<name>`. A taken
    # name gets `-2`, as Orca does for a branch that does not sit at the base.
    name=''; base=''; br=''
    while [ $# -gt 0 ]; do
      case "$1" in --name) name=$2; shift 2 ;; --base-branch) base=$2; shift 2 ;; --branch) br=$2; shift 2 ;; *) shift ;; esac
    done
    br=${br:-dev/$name}
    rc=$(cat "$FX/create.rc" 2>/dev/null || echo 0)
    if [ -s "$FX/create.json" ]; then
      # FX_CREATE_LANDS: the tree is made before the canned answer (a create that landed
      # before the runtime dropped).
      [ -n "${FX_CREATE_LANDS:-}" ] && git -C "$FX_REPO" worktree add -q -b "$br" "$FX_ORCA_ROOT/$name" "$base" >/dev/null 2>&1
      cat "$FX/create.json"; exit "$rc"
    fi
    git -C "$FX_REPO" show-ref --verify --quiet "refs/heads/$br" && br="$br-2"
    p="$FX_ORCA_ROOT/$name"
    git -C "$FX_REPO" worktree add -q -b "$br" "$p" "$base" >/dev/null 2>&1 ||
      { echo '{"ok":false,"error":{"code":"git_failed"}}'; exit 1; }
    jq -n --arg u "$(unc "$p")" --arg b "refs/heads/$br" \
      '{ok:true,result:{worktree:{path:$u, id:("R::"+$u), branch:$b}}}' ;;
  # A board column persists per selector in $FX/board-<selector>; Orca's default is in-progress.
  # Like the real Orca, any id is taken: validating it is the caller's job.
  'worktree set')
    w=''; st=''
    while [ $# -gt 0 ]; do
      case "$1" in --worktree) w=$2; shift 2 ;; --workspace-status) st=$2; shift 2 ;; *) shift ;; esac
    done
    [ -z "$st" ] || printf '%s' "$st" > "$FX/board-$(printf '%s' "$w" | tr -c 'A-Za-z0-9' '_')"
    echo '{"ok":true}' ;;
  'worktree show')
    w=''
    while [ $# -gt 0 ]; do case "$1" in --worktree) w=$2; shift 2 ;; *) shift ;; esac; done
    f="$FX/board-$(printf '%s' "$w" | tr -c 'A-Za-z0-9' '_')"
    st=in-progress; [ -f "$f" ] && st=$(cat "$f")
    jq -n --arg s "$st" '{ok:true,result:{worktree:{workspaceStatus:$s}}}' ;;
  'worktree rm')
    # FX_RM_PATH: the tree this rm call really removes. FX_RM_KEEP: remove nothing (a
    # blocked archive hook). FX_RM_LEAK: deregister, then leave files behind (root-owned
    # files a container wrote, which neither git nor Orca can unlink). Like Orca 1.4.246+,
    # it answers once the tree is gone and keeps the branch.
    if [ -n "${FX_RM_PATH:-}" ] && [ -z "${FX_RM_KEEP:-}" ]; then
      git -C "$FX_REPO" worktree remove --force "$FX_RM_PATH" >/dev/null 2>&1
      [ -n "${FX_RM_LEAK:-}" ] && mkdir -p "$FX_RM_PATH" && : > "$FX_RM_PATH/root-owned.pyc"
    fi
    cat "$FX/rm.json" 2>/dev/null || echo '{"ok":true}'
    exit "$(cat "$FX/rm.rc" 2>/dev/null || echo 0)" ;;
  'worktree ps') cat "$FX/ps.json" 2>/dev/null || echo '{"ok":true,"result":{"worktrees":[]}}' ;;
  'terminal create') cat "$FX/term.json" 2>/dev/null || echo '{"ok":true,"result":{"terminal":{"handle":"h1"}}}' ;;
  'terminal list') cat "$FX/terms.json" 2>/dev/null || echo '{"ok":true,"result":{"terminals":[]}}' ;;
  # A send receipt as Orca 1.4.254 gives it when it saw the turn start; $FX/send.json overrides.
  'terminal send') cat "$FX/send.json" 2>/dev/null ||
    echo '{"ok":true,"result":{"send":{"handle":"cl1","accepted":true,"prompt":{"stages":["input_accepted","turn_started"],"provider":"claude","observation":"observed"}}}}' ;;
  # terminal read: the Nth call serves $FX/read.N.json when present, else $FX/read.json.
  'terminal read')
    n=$(( $(cat "$FX/read.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/read.n"
    cat "$FX/read.$n.json" 2>/dev/null || cat "$FX/read.json" 2>/dev/null || { echo '{"ok":false}'; exit 1; } ;;
  'terminal wait') cat "$FX/wait.json" 2>/dev/null || echo '{"ok":true}' ;;
  'terminal close') echo '{"ok":true}' ;;
  *) echo '{"ok":false}'; exit 1 ;;
esac
SH

# gh: `pr list --head <b>` → $FX/prs/<b with / as _>.json (default []); `pr view <n>` →
# $FX/prs/view-<n>.json (default: exit 1). $FX/gh.rc forces a failure.
cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$WT_TEST_LOG"
[ -f "$FX/gh.rc" ] && exit "$(cat "$FX/gh.rc")"
# $FX/gh.drain: read stdin to the end, as a real gh (or orca) may; a loop that feeds its
# rows on stdin must keep them from the commands it runs.
[ -f "$FX/gh.drain" ] && cat > /dev/null
if [ "$1 $2" = 'pr list' ]; then
  b=''; while [ $# -gt 0 ]; do case "$1" in --head) b=$2; shift 2 ;; *) shift ;; esac; done
  f="$FX/prs/$(printf '%s' "$b" | tr '/' '_').json"
  if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
elif [ "$1 $2" = 'pr view' ]; then
  f="$FX/prs/view-$3.json"; [ -f "$f" ] && cat "$f" || exit 1
fi
SH

cat > "$STUB/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$WT_TEST_LOG"
case "$1" in
  has-session) exit "$(cat "$FX/tmux-has.rc" 2>/dev/null || echo 0)" ;;
  list-windows) cat "$FX/tmux-windows" 2>/dev/null ;;
  # -P prints the new window's id; $FX/tmux-pane is what capture-pane shows.
  new-window) case " $* " in *' -P '*) echo '@7' ;; esac ;;
  capture-pane) cat "$FX/tmux-pane" 2>/dev/null ;;
esac
exit 0
SH

for s in gortex; do
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$WT_TEST_LOG"\n' "$s" > "$STUB/$s"
done
printf '#!/usr/bin/env bash\nprintf "setup %%s\\n" "$(pwd -P)" >> "$WT_TEST_LOG"\n' > "$STUB/setup"
printf '#!/usr/bin/env bash\nprintf "teardown %%s\\n" "$(pwd -P)" >> "$WT_TEST_LOG"\n' > "$STUB/teardown"
chmod +x "$STUB"/*

# The Orca board's status set (board.sh), never this box's real Orca database.
printf 'todo\tMains\nin-progress\tIn progress\nst-rev\tIn review\nst-qa\tQA\ncompleted\tDone\nst-rq\tReview queue\n' > "$FX/board.tsv"
export HI_ORCA_BOARD="$FX/board.tsv"
export HI_ORCA="$STUB/orca" HI_TMUX="$STUB/tmux" HI_GORTEX="$STUB/gortex" HI_CLAUDE=claude \
       HI_WT_RM_WAIT=0 HI_WT_SETUP="$STUB/setup" HI_WT_TEARDOWN="$STUB/teardown" HI_WT_ROOT="$SANDBOX/wt" \
       HI_UUID=11111111-2222-3333-4444-555555555555 HI_SEND_READS=1 HI_LAUNCH_READS=1 PATH="$STUB:$PATH"

orca_on()  { printf '%s\n' '{"ok":true,"result":{"runtime":{"state":"ready","reachable":true,"appVersion":"1.4.252"}}}' > "$FX/status.json"; unset HI_WT_BACKEND; }
orca_off() { rm -f "$FX/status.json"; export HI_WT_BACKEND=git; }
orca_off

# mk_repo: repo "app" (main branch) with a bare origin and origin/HEAD set. Sets R and UP.
mk_repo() {
  UP="$SANDBOX/up.git"; git init -q --bare "$UP"
  R="$SANDBOX/app"; git init -q -b main "$R"
  git -C "$R" commit -q --allow-empty -m base
  git -C "$R" remote add origin "$UP"
  git -C "$R" push -q origin main
  git -C "$R" remote set-head origin main >/dev/null
  export FX_REPO="$R"
}
