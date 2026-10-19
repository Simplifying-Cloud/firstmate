# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4.
`opencode2` (OpenCode 2.x, the separate @opencode/cli package) is verified on 2026-10-17 on 2.0.32 for crewmate and scout launches only; the "OpenCode 2.x" section below owns its differences.

## OpenCode 1.x operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin's semantic `session.status`: `busy` and `retry` are active, `idle` is inactive, latched to the worker's own session. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Relaunch with `--continue` to resume the most recent session for the current directory, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside `--continue`. |
| Model flag | `--model <provider/model>`. |
| Effort flag | None for Firstmate's interactive `opencode --prompt` launch; `opencode run` has `--variant`, but that is not this path. The effort instead rides the launch's `OPENCODE_CONFIG_CONTENT` JSON as the `build` agent's `variant` keyed to the resolved model, the config schema's per-model reasoning-effort field verified on 1.18.32. It is emitted only when the resolved model's provider is known to expose that effort as a variant (`anthropic/*`: high, max; `openai/*`: low, medium, high, xhigh); with no model resolved, another provider, or an effort outside its family's list, the variant is omitted and the permission-only launch is unchanged. |
| Model discovery | Run `opencode models [provider]` to list available provider/model identifiers. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

The primary integration was verified on 2026-07-08 with OpenCode 1.17.6.
`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `client.session.promptAsync`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `tool.execute.before`.

## OpenCode 2.x (harness `opencode2`)

Verified live on 2026-10-17 against `opencode v2.0.32` (installed as `~/.local/bin/opencode` and `~/.local/bin/opencode2`, PATH-shadowed by a 1.18.31 `~/.opencode/bin/opencode`), with config isolation re-verified on 2026-10-19.
`opencode2` is a CREWMATE and SCOUT adapter only: no 2.x primary supervision integration is verified, so a secondmate on it is refused, and `bin/fm-harness.sh` detection still answers the `opencode` family for both majors because the 2.x process comm is `opencode` too.

| Fact | Value |
|---|---|
| Binary | [The resolver](../../../../../bin/fm-opencode2-lib.sh) owns version-gated executable selection independently of the bare `opencode` on PATH. |
| Platform traffic | Every model request must go through the governed platform (`https://ai.simplifying.cloud`). The launch discovers the org config's providers whose `baseURL` routes through the origin (`<binary> debug config`), and `OPENCODE_CONFIG_CONTENT` carries `policies` denying `provider.use` for `*` and allowing exactly those providers. Selecting any other model (the operator's personal `openai/*`, `minimax-coding-plan/*`, `zai-coding-plan/*`, `ollama/*`) is refused locally with `Error: Model unavailable: <model>`, and `fm-spawn` refuses a `--model` outside the discovered set before launch. |
| Server isolation | `--standalone` is load-bearing: without it the worker joins the operator's per-user background server, which was started with the operator's environment, answers from the operator's own global config, and ignores this launch's `OPENCODE_CONFIG_CONTENT`, so the policies, model, and project plugin would silently not apply. With it the worker gets a private server inheriting exactly the launch environment. Other OpenCode commands run in the worker's environment would still reach that shared server (`debug config`, `debug agents`, `mcp list`, and `plugin list` take no `--standalone` flag, and a bare `run` or `models` defaults to it), so the per-task config directory below turns it off for all of them. |
| Config isolation | `OPENCODE_CONFIG_DIR` points at a firstmate-owned per-task directory that replaces the operator's global `~/.config/opencode` (its `opencode.json`, MCP servers, plugins, and `cli.json`) for every OpenCode process in the worker's environment. The directory holds only `service.json` set to `{"disabled":true}`, OpenCode's own service setting, so every such command starts a private server inheriting the launch environment instead of using the shared one. The org config and the credential store live in the data directory outside it and still reach the worker. |
| Not isolated | The data and state directories (platform sign-in, credential store, sessions, recent models) are shared with the operator by design. Skills in the operator's `~/.claude` and `~/.agents` still load through OpenCode's Claude Code compatibility (`OPENCODE_DISABLE_CLAUDE_CODE=1` drops the `~/.claude` ones), as would `/etc/opencode` system config, any `opencode.json` or `.opencode` in a directory above the worktree (for a worktree under the home directory, that walk reaches `~`), and MCP servers or policies that a signed-in OpenCode Console account delivers through the credential store. |
| Busy state | The Firstmate-owned plugin at `.opencode/plugins/fm-busy-state.js` in the 2.x DEFAULT-EXPORT form (`{ id, setup }`): `session.execution.started` is busy and `succeeded`, `failed`, and `interrupted` all close the turn, so a manual cancel can never leave a stale busy record. `setup` must return; one that never returns blocks the whole location and every API call then fails with `Location plugins did not finish activating` after five seconds. 2.0.32 never publishes the legacy `session.status`/`session.idle` events (they exist only in the API schema). Provider errors surface as `session.retry.scheduled` while the execution stays open. |
| Exit command | `/exit`. Two Ctrl-C presses also exit the TUI (verified; useful as a wedge fallback). |
| Interrupt | Double Escape with an ARMED second press: the first press renders `esc again to interrupt` in the footer, and the second press must follow promptly inside that window (verified: 0.5s gap interrupted with `session.execution.interrupted reason=user`; 1.5s re-armed without firing). A wide gap can also open an integrations dialog on an idle pane; Escape closes it. |
| Resume | Relaunch with `--continue` resumes the most recent session for the directory, and unlike 1.x the 2.x `--continue --prompt` combination auto-submits the prompt (verified: the busy record opened and settled without any manual send). |
| Model | The 2.x TUI has no `--model` flag; the resolved model rides `OPENCODE_CONFIG_CONTENT` as `"model": "provider/model"` (verified as the session's model in `session.created`). |
| Effort | No platform model exposes a variant list on 2.0.32 (`opencode debug config` shows capabilities and limits only), so the effort axis is recorded in task metadata but omitted from the launch (record-and-omit). |
| Trust dialog | None observed on any fresh worktree launch. |
| Marker | None, same as 1.x; ancestry through the `opencode` comm covers it. |
| Busy-queued Enter | Same shape as 1.18.4: while mid-turn the composer keeps the typed text and Enter enqueues the message (`session.inbox.enqueued` with `delivery: steer`), delivered when the turn ends. |
| Auto-update | `OPENCODE_DISABLE_AUTOUPDATE=1` in the launch keeps a background self-upgrade from exiting the worker mid-task (log line `update check skipped reason=disabled`). |

For the sandbox refusal and credential boundary, see [remote sandboxes](../../../../../docs/remote-sandboxes.md).
