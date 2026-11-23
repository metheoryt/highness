---
name: account
description: Move the live agent sessions on this machine (the coordinator, hi-crew workers, other work sessions) onto the Claude account Orca has selected, each resuming its own chat in its own Orca pane. Use after switching the Claude account in Orca (`orca account select` or the UI), when the user says "move my sessions to the new account", "switch the account for all agents", «перенеси сессии на новый аккаунт», «переключи агентов на другой аккаунт», or when the hi-crew agenda offered a switch and the person said yes.
---

# /hi:account

**Session rules** (`${CLAUDE_PLUGIN_ROOT}/reference/session.md`, read before the first reply): chat
in the user's language (no words of theirs yet: `session.language` in their config), Read one file
per call, 2–4 options per question.

Every shell call starts with `L="${CLAUDE_PLUGIN_ROOT}/lib"` (if that path does not exist:
`L="$("$HOME/.local/bin/highness" root)/lib"`). Orca only: without it, `account.sh` says so and
there is nothing to move.

After `orca account select`, a session already running stays on the old account. `account.sh
move` moves each one: it waits until the session is idle, types `/exit` into its Orca pane, then
`claude --resume <its session> <its own flags>`. Orca's pane shell starts `claude` on the
selected account. The pane keeps its terminal handle and the session its chat. An orchestration
worker's Dispatch does not survive the `/exit`, though: Orca fails it as soon as the worker's
Claude exits (measured on Orca 1.4.271, highness#110). For a hi-crew worker, the coordinator's
`crew.sh resume <KEY>` then gives the moved session a new Dispatch in the same pane; say so in
the report for each worker moved.

**Orca's own restart loses workers.** On a switch Orca can restart the sessions itself, but in a
new pane with a new terminal handle: the chat survives, a hi-crew worker's Dispatch does not
(orchestration reports it lost and fails it). Its setting "When you switch accounts while Claude
is running in terminals" decides: **Never restart** leaves every session for this skill; **Always
restart** restarts them on every switch; **Ask** shows a dialog only for a switch in the status
bar (untick the workers there) and restarts with no dialog for a switch made anywhere else,
`orca account select` included. `bash "$L/account.sh" restart-mode` reads it (`keep`, `restart`,
`ask`). Orca's restart also skipped some panes (measured: two started with `orca agent launch`
stayed on the old account), so run step 2 after any switch.

1. **Which account.** `bash "$L/account.sh" target` gives the selected account's config dir,
   email and organization. If the person wants another account and has not selected it yet, the
   switch is theirs to confirm (it changes which plan pays). Before you propose one,
   `bash "$L/account.sh" health` shows whether each of Orca's accounts can run: one row each,
   `*` on the selected one, then id, email, state and detail. `ok` (with the plan's figures),
   `limited` (a window spent, with its reset, or the usage limit reached), `dead` (why: payment
   past due, account disabled, not logged in), `unknown` (no figures, no verdict). Show the
   person each account's state; never propose a `dead` one. An account whose usage endpoint gives
   no figures costs one tiny `claude -p` to find out (`claude auth status` cannot tell: it says
   logged in for a past-due account). On their yes:
   `bash "$L/account.sh" select <id|email>`. It selects only when the setting is Never restart;
   otherwise it exits 4, selects nothing, and says why. Then give the person the choice: set Never
   restart in Orca's Settings → Accounts and you run `select` again, or they switch in the status
   bar and untick every worker in the dialog. Never write Orca's settings yourself. It also
   checks the account first: `dead` or `limited` exits 5 with the reason and selects nothing.
   Say why to the person; `select --force` only on their word, after they heard the reason.
2. **What would move.** `bash "$L/account.sh" move --dry-run` (add `--only <handle|session>` for
   some of them): `would-move` rows (handle, session, the relaunch line) and `self` for this
   session. Show the person the sessions as a short list: the workspace (from `account.sh
   sessions`, its cwd) and whether it is idle. Moving all of them is the default; ask only
   when they named some.
3. **Move.** `bash "$L/account.sh" move [--only …] [--wait <seconds>]` (default wait 600). Each
   row:
   - `moved`: running again on the new account. `lost connectors:` names the claude.ai
     connectors the new account does not have; the session has been told.
   - `busy`: still mid-turn when the wait ran out. Nothing was typed into it (that could answer
     a permission prompt). Offer to run the move again later.
   - `skipped`: not in an Orca pane with Orca's claude wrapper. The person restarts it by hand.
   - `failed` / `unconfirmed`: what the row says, with the pane to look at. Never retype into a
     pane without looking at it first.
   - `self`: this session. It moves in the background once this turn ends, so end the turn
     right after the report. Its log is the path the row names.
4. **Report.** Say how many moved, which are busy or need a hand, and the lost connectors. When
   the move crossed organizations, add one line: the first turn of each moved session rereads its
   chat, so it is slower and costs more (Claude cannot reuse thinking written under another
   organization).

MCP servers configured in the repo or the user's settings (gortex and the like) do not change
with the account. Only the claude.ai connectors and the plan's usage do.
