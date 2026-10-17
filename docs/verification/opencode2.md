# Verification: the OpenCode 2.x (`opencode2`) crewmate adapter

Active empirical evidence for firstmate's OpenCode 2.x worker adapter.
The operating facts live in [`.agents/skills/harness-adapters/references/harness/opencode.md`](../../.agents/skills/harness-adapters/references/harness/opencode.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `opencode v2.0.32` (`@opencode/cli`), PATH-shadowed by `opencode 1.18.31` (`~/.opencode/bin/opencode`) |
| Verified | 2026-10-17 |
| Platform | Linux x86_64, Herdr 0.9.1 lab session for TUI driving, tmux for the live guard |
| Binary | `~/.local/bin/opencode` and `~/.local/bin/opencode2` (both symlinked to the same 2.x executable) |
| Platform origin | `https://ai.simplifying.cloud` (org config from its `/.well-known/opencode` manifest) |

All TUI lifecycle runs below drove the real 2.x TUI inside an isolated `fm-lab-*` Herdr session through `bin/fm-herdr-lab.sh`, against a localhost Anthropic-compatible mock provider so no model tokens were spent; the platform-traffic proof at the end ran the real platform.

## Standalone and config isolation

Run from a scratch git project with `OPENCODE_CONFIG_DIR` pointed at an empty directory and `OPENCODE_CONFIG_CONTENT` carrying only permission, policies, model, and a mock provider:

```sh
OPENCODE_CONFIG_DIR=/tmp/…/wcfg OPENCODE_DISABLE_AUTOUPDATE=1 \
  OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"},"model":"…","policies":[…]}' \
  ~/.local/bin/opencode models --standalone
```

Observed on 2.0.32:

- With `--standalone` the provider list contained exactly the policy-allowed providers.
- Without `--standalone` the same environment listed every provider on the machine, including the operator's personal `minimax-coding-plan`, `zai-coding-plan`, `openai`, and `ollama`: the shared background server (127.0.0.1:49374, `serve --service`) was started with the operator's environment and ignores this launch's `OPENCODE_CONFIG_CONTENT` entirely, which is why the adapter launch is `--standalone`.
- The server log confirmed the isolated config dir was watched (`watcher subscribe path=/tmp/…/wcfg`), the org document still loaded from the credential store's cached well-known KV outside it, and `OPENCODE_DISABLE_AUTOUPDATE=1` produced `update check skipped reason=disabled`.

## Platform-only traffic

The launch-content policies deny `provider.use` for `*` and allow exactly the providers whose org-config `baseURL` routes through the platform origin (discovered via `debug config`, which redacts secrets).

- `opencode run --standalone --model openai/gpt-5.5 …` answered `Error: Model unavailable: openai/gpt-5.5` and exited without any network request; `minimax-coding-plan/MiniMax-M3`, `zai-coding-plan/glm-5.3`, and `ollama/deepseek-coder-v2:16b` were refused the same way (all four are the operator's personal or local providers).
- A worker-posture standalone run on `zai/glm-5.3-flash` completed at 2026-10-17T06:45:34Z, and the AI Gateway log (read through the audited `cf-api.sh` helper with GET requests) shows the two corresponding requests:

```text
2026-10-17T06:45:39.545Z custom-zai glm-5.3-flash 200 auth=True wholesale=False
2026-10-17T06:45:39.544Z custom-zai glm-5.3-flash 200 auth=True wholesale=False
```

An earlier same-day investigation that looked like an expired Access session was actually the shared background server wedged by a location whose plugin `setup` never returned (below); the standalone posture reached the platform fine with the same stored credential.

## Plugin form and busy state

A project `.opencode/plugins/fm-busy-state.js` exporting `default { id, setup }` loaded in the standalone server and received `{ type, data }` events through `ctx.event.subscribe()`.
Facts established live:

- A `setup` that never returns blocks the whole location: every subsequent API call (including `/api/model`) fails with `ServiceUnavailableError: Location plugins did not finish activating` after five seconds, and the TUI footer parks on `No provider selected`. The shipped plugin therefore consumes its event stream in a detached loop and aborts it from the returned cleanup.
- A complete turn emitted exactly `session.created`, `session.inbox.enqueued`/`delivered`, `session.execution.started`, `session.step.*`/`session.text.*`, `session.usage.updated`, `session.execution.succeeded`.
- `session.status` and `session.idle` never appeared in any turn on 2.0.32; the 2.0.32 source ships them only in the event schema, so the plugin's arms for them are forward-compat no-ops and busy/idle ride the execution events. `session.execution.interrupted` carries `reason:"user"` for a manual cancel, and `session.retry.scheduled` fires while the execution stays open (provider `ConnectionRefused` retries were observed recovering once the mock returned).
- Driving the real generated plugin through the real fm-spawn and a real TUI turn (the live guard below) recorded `busy opencode-plugin` on execution start and `idle opencode-plugin` with `event=execution-succeeded`, and touched the turn-end notification marker.

## Lifecycle

Driven through the Herdr lab pane against the delayed mock:

- Exit: `/exit` plus Enter left the TUI to the shell prompt; two Ctrl-C presses also exit.
- Interrupt: the first Escape renders `esc again to interrupt` in the footer; a second press about 0.5s later interrupted (`session.execution.interrupted reason=user`, composer left empty), while a second press about 1.5s later left the armed hint standing without interrupting, so the control table arms on that hint and keeps the devin-grade 0.5s gap.
- Resume: relaunching with `--continue --prompt …` restored the previous session's transcript and auto-submitted the prompt (the busy record opened and settled with no manual send), unlike 1.x where `--prompt` does not auto-submit alongside `--continue`.
- Busy-queued Enter: while a turn ran, typed text stayed in the composer after Enter and the message was enqueued (`session.inbox.enqueued` with `delivery:"steer"`), then delivered when the turn ended - the same shape as 1.18.4.
- The 2.x TUI process `comm` is `opencode` (launched through either symlink name), so ancestry detection and the process-name evidence tables need no 2.x entry.

## Guards

```sh
bin/fm-test-run.sh tests/fm-opencode2-harness.test.sh
FM_OPENCODE2_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-opencode2-signals-live-e2e.test.sh
```

Observed output:

```text
ok - opencode2 launch is standalone, config-isolated, and platform-only
ok - opencode2 refuses a model outside the discovered platform providers
ok - opencode2 plugin classifies from session.execution events, scoped to the latched worker session
ok - opencode2 opencode v2.0.32 live: standalone TUI turn drove the generated plugin busy->idle with the notification touch, and /exit left the pane
```

The portable suite pins binary selection, the platform-only launch line, the isolated config dir, model refusals, the pin refusal, the secondmate refusal, the generated plugin's latch scoping, and the control tables against fake binaries; the live guard is token-free (localhost mock) and runs by default wherever `opencode2`, `tmux`, `python3`, `node`, and `curl` are installed, capability-skipping elsewhere.

## Not verified

- No 2.x primary supervision integration (turn-end guard, watch-arm, session-start nudge in the 2.x plugin form), which is why a secondmate on `opencode2` is refused.
- No sandbox placement: a sandbox host has none of the operator's OpenCode 2.x platform sign-in, so the org providers cannot resolve there.
- No effort mapping: no platform model exposes a variant list on 2.0.32, so the record-and-omit posture is untestable beyond its omission.
- The gateway-log identity metadata (`user_id` UUID stamping) was read but not modified or stress-tested; that surface belongs to the platform project.
