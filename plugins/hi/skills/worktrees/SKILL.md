---
name: worktrees
description: Show, find, create and clean up this repo's workspaces (Orca workspaces, or plain git worktrees when there is no Orca) — one table with lineage, what each is for, its PR, whether it is safe to remove, and "remove the N marked?". Use when the user asks about worktrees or workspaces ("clean up worktrees", "where is <KEY>'s workspace", "what workspaces do I have", "make me a scratch workspace for X") or wants to resume a session started in one — and whenever the agent itself needs a new tree to edit in.
---

# /hi:worktrees

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language, Read one file per call, 2–4 options per question.

Every shell call starts with `L="${CLAUDE_PLUGIN_ROOT}/lib"` (if that path does not exist:
`L="$("$HOME/.local/bin/highness" root)/lib"`) and runs from inside the repo: the main checkout or
any of its workspaces. Outside a repo `wt.sh` exits 2; say so and stop.

A workspace is the home of one piece of work, of one of three kinds: `ticket` (a ticket key such
as `AB-123`, or `<repo>#<n>` for an issue), `review` (a PR number, the tree detached at its head)
or `work` (a slug, for anything without a ticket). Its record (name, parent, session, base) lives
in `<git-common-dir>/hi/`, shared by every worktree of the repo and never committed.

In an umbrella repo (`bash "$L/umbrella.sh" root` succeeds: a `repos.txt` at the top lists nested
clones) work on a nested clone runs per clone as `bash "$L/wt.sh" --repo <clone> …`, the clones
from `bash "$L/umbrella.sh" repos --paths`. The table is one table across clones (and the
umbrella's own) with a repo column; a create goes to the clone the work belongs to (ask when that
is unclear). Only a change to the umbrella's own files (`repos.txt`, its docs and config) gets a
workspace of the umbrella: `wt.sh create --umbrella …` from the umbrella — a plain `create` there
refuses, so a nested change never lands in it. A nested workspace made from a workspace of the
umbrella records `umbrella: <that workspace>` (`rec get … umbrella`) and goes under it with `↳`.

## 1. The table (the default answer)

```bash
bash "$L/wt.sh" list --state
```

One TSV row per workspace. Read fields with `cut -f` (never `IFS=$'\t' read`: empty fields shift
the columns). Columns: 1 path · 2 sel · 3 branch · 4 head · 5 kind · 6 key · 7 name · 8 parent ·
9 session · 10 backend · 11 dirty · 12 pushed · 13 memory · 14 pr · 15 terminal · 16 age (days) ·
17 safe · 18 reasons.

Render one table. A child (its col 8 is another row's col 1) goes right under its parent, with `↳`:

| | workspace | kind | age | PR | state |
|---|---|---|---|---|---|
| 🗑 | AB-101 · Retry lock ordering | ticket | 3d | merged #11 | safe to remove |
| ❓ | AB-103 · Epic sync | ticket | 9d | merged #13 | HEAD not on any remote |
| | ↳ review #4480 · AB-101 retry | review | 1d | open #4480 | Claude idle |

- 🗑: col 17 is `yes` and col 14 is `merged#…`, `closed#…` or `landed` (no PR, its own commits in
  `origin/HEAD`). ❓: merged, closed or landed, but col 17 is `no`. No mark: work still going on.
  A 🗑 `ticket` or `review` row at `merged#…`/`landed` is removed unasked: `remove-if-safe`.
- The state column is col 18 in plain words: `cwd` you are in it · `pr-open` PR open · `pr-unknown`
  PR state unknown · `no-pr` no PR, nothing of its own in trunk yet · `pr-stale` an old PR on this
  branch, new work since · `dirty` uncommitted changes · `unpushed` HEAD not on any remote ·
  `memory` a gitignored file under `.claude/memory` is a copy, not a link to the main checkout's ·
  `busy` an agent (an Orca terminal or chat) is busy there · `open-window` its tmux window is open.
  Empty: col 15 (`idle` → "Claude idle").
- Nothing else: no paths, no shas. A path is shown only when the user asks where something is.

Then, only when a 🗑 or ❓ row is left, one `AskUserQuestion`: **"Remove the <N> marked?"** with
the options "Remove the <n> safe ones" (recommended, only the 🗑 rows), "Let me pick"
(`multiSelect`, the 🗑 and ❓ rows, each ❓ with its reasons in the description), "Keep all".

- 🗑 picked → `bash "$L/wt.sh" remove-if-safe <path>`. It checks again; exit 3 → show its `unsafe`
  lines in words and keep the workspace.
- ❓ picked → the user chose it knowing the reasons: `bash "$L/wt.sh" remove <path>`.
- Exit 4 → print the `LEAKED` line verbatim; its `sudo rm -rf` is the user's; never run it yourself.
- Report one line per workspace from `wt.sh`'s own `removed "…"` announce (what happened to the
  branch — a merged or landed one is deleted, any other kept — and how to resume the chat).

## 2. Plain requests

- **"Where is X?"** → `bash "$L/wt.sh" find --ticket <KEY>` (or `--review <n>`, `--branch <b>`,
  `--work <slug>`). Answer with the name, the path (col 1), and, when col 9 is set,
  `cd <path> && claude --resume <session>`. With Orca (col 10 `orca`), it is also in the sidebar
  under that name.
- **"Make me a scratch workspace for X"** → name: 3–5 words from the user's own description;
  slug: that name lowercased with `-` for spaces. Base: the branch `origin/HEAD` points at, unless
  the user or the repo's docs name another trunk. Creating it is automatic; announce it, do not
  ask:

  ```bash
  bash "$L/wt.sh" create --kind work --key <slug> --name '<name>' --base origin/<trunk> --branch work/<slug>
  ```

- **A workspace for a ticket** → `create --kind ticket --key <KEY> --name '<KEY> · <title>'
  --base origin/<trunk> --branch <a branch carrying KEY>` (or `--adopt <existing branch>`). For a
  review → `bash "$L/wt.sh" review-head --pr <n> --base-ref <base>` prints `base<TAB>head`, then
  `create --kind review --key <n> --name 'review #<n> · <title>' --detach <head>`.

  Every new workspace is a child: without `--parent` its parent is the workspace the call runs in —
  the main checkout, a tree `wt.sh` made, or one made in Orca's UI. Run it from where the work was
  asked for; pass `--parent <path>` only to hang it elsewhere. Never make an orphan (Orca's
  `--no-parent`, a bare `git worktree add`): it loses its lineage in the sidebar and in this table.

  When the user also said what to do there, write that as a brief (Write tool, a temp file) and run
  `bash "$L/wt.sh" dispatch <path> --brief <file>` (returns at once, or within ~25 s when a live
  session there gets the brief: `via=send` once Orca or the terminal's screen shows the turn
  started; exit 5, `via=unconfirmed`: typed in but not seen taken — show the user the screen tail
  stderr prints and never resend blindly, it could submit twice; exit 3: it is mid-turn,
  `via=busy`, or an Orca chat is open there, `via=chat`: Orca cannot type into a chat, so tell the
  user to paste the line stderr names into it). Stdout:
  `session<TAB>via<TAB>handle`; `via=print` → line 2 is the command for the user to run.
- **"Clean up"** → §1, with the question.

## 3. Rules

- A workspace is removed only by `remove-if-safe`, by `remove <path>` after the user said yes to it
  this turn, or by a caller's `remove-if-landed` (a ticket workspace whose work merged; never
  work/scratch).
- `wt.sh` refuses to remove the workspace this session stands in; say so, offer the main checkout.
- `wt.sh create` runs the worktree setup (`highness worktree-setup`: gortex tracking when gortex is
  installed, local config links, the repo's own setup script) on both backends; a fresh tree is
  ready when `create` returns, though gortex may still index it in the background.
- Nothing here edits files in a workspace.
