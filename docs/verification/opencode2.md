# Verification: the OpenCode 2.x (`opencode2`) crewmate adapter

Active empirical evidence for firstmate's OpenCode 2.x worker adapter.
The operating facts live in [`.agents/skills/harness-adapters/references/harness/opencode.md`](../../.agents/skills/harness-adapters/references/harness/opencode.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `opencode v2.0.32` (`@opencode/cli`), PATH-shadowed by `opencode 1.18.31` (`~/.opencode/bin/opencode`) |
| Verified | 2026-10-17; config isolation 2026-10-19; shared-server confinement 2026-10-22 |
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

## Shared-server reach and the service setting

Verified on 2026-10-19 against `opencode v2.0.32` from scratch git projects, reading only source paths, MCP server names, and provider ids.
On 2.0.32, `debug config`, `debug agents`, `mcp list`, `mcp auth`, `mcp logout`, `plugin list`, and `plugin inspect` resolve their server with no `--standalone` or `--server` option, while `run`, `models`, `api`, and the TUI default to the per-user background server unless given `--standalone`.
That server was started with the operator's environment, so it answered this command, run with `OPENCODE_CONFIG_DIR` at an empty directory, from the operator's own config:

```sh
OPENCODE_CONFIG_DIR=<empty dir> OPENCODE_DISABLE_AUTOUPDATE=1 \
  OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' ~/.local/bin/opencode debug config
```

It listed the org document, `~/.config/opencode/opencode.json`, and the `~/.config/opencode` directory, with no document for the launch's own `OPENCODE_CONFIG_CONTENT`.
A bare `opencode models` under a launch allowlist of `zai` and `minimax` listed eight providers, because the shared server ignored the launch's policies.

2.x reads its service setting from `service.json` in the active config dir: `opencode service get disabled` printed `true` with `OPENCODE_CONFIG_DIR` at a directory holding `{"disabled":true}` and `false` with it at an empty one, and a disabled service makes every such command start a private server that inherits the caller's environment.
With that file in the config dir, the same `debug config` listed only the org document, the config dir itself, and the launch-content document; the bare `models` listed exactly `zai` and `minimax`; and the bare `run` spawned its own `serve --stdio --port 0` child.
No new listener appeared on 127.0.0.1:49374, which stayed the operator's own `serve --service` process.
`opencode service set disabled true` would write the same file but first stops the running background server, so the adapter writes it directly.

## MCP servers and other sources

A private server started the way `--standalone` starts one (`serve --stdio --port 0` with the caller's environment) registered config-defined MCP servers about two seconds after it reported its URL.
An immediate `opencode mcp list` therefore printed `No MCP servers configured` even with an MCP server in the launch content, so MCP evidence comes from polling a server that stays up.
With a stand-in operator global config under `XDG_CONFIG_HOME` defining `fm-operator-sentinel` and the launch content defining `fm-launch-sentinel`, both registered without the per-task config dir and only `fm-launch-sentinel` registered with it.
In the real operator environment from a firstmate worktree, the per-task config dir again left only the launch's server registered.
The operator's global config currently defines no MCP servers, and the credential store holds no OpenCode Console connection, so no personal MCP server was present to leak when this was verified.

In the isolated environment from a firstmate worktree, the skill list held 20 skills from `~/.claude` and 1 from `~/.agents` alongside the worktree's own, and adding `OPENCODE_DISABLE_CLAUDE_CODE=1` removed the `~/.claude` ones while keeping the rest.
An `opencode.json` in a directory above a scratch git project, and a `.opencode` directory there, each loaded as a config source in the isolated environment, so project discovery walks past the repository root.

## Platform-only traffic

The launch-content policies deny `provider.use` for `*` and allow exactly the providers whose org-config `baseURL` routes through the platform origin (discovered via `debug config`, which redacts secrets).

- `opencode run --standalone --model openai/gpt-5.5 …` answered `Error: Model unavailable: openai/gpt-5.5` and exited without any network request; `minimax-coding-plan/MiniMax-M3`, `zai-coding-plan/glm-5.3`, and `ollama/deepseek-coder-v2:16b` were refused the same way (all four are the operator's personal or local providers).
- A worker-posture standalone run on `zai/glm-5.3-flash` completed at 2026-10-17T06:45:34Z, and the AI Gateway log (read through the audited `cf-api.sh` helper with GET requests) shows the two corresponding requests:

```text
2026-10-17T06:45:39.545Z custom-zai glm-5.3-flash 200 auth=True wholesale=False
2026-10-17T06:45:39.544Z custom-zai glm-5.3-flash 200 auth=True wholesale=False
```

An earlier same-day investigation that looked like an expired Access session was actually the shared background server wedged by a location whose plugin `setup` never returned (below); the standalone posture reached the platform fine with the same stored credential.

The worker posture with the per-task service setting still reached the platform on 2026-10-19.
A bare `opencode run "Reply with exactly OK." </dev/null`, with no `--standalone`, under `OPENCODE_CONFIG_DIR` at a directory from `fm_opencode2_isolate_config_dir` and launch content carrying the discovered policies and `zai/glm-5.3-flash`, printed `OK` at 2026-10-19T05:05:44Z.
A non-interactive `opencode run` reads piped stdin until end of file, so without the `</dev/null` it never sent the prompt.
The real fm-spawn launch line, staged with the real binary and real discovery into a throwaway home and run in a throwaway tmux server, settled its first turn at 2026-10-19T05:09:04Z with `OK` under the footer `Build auto · GLM-5.3-Flash GLM via organization gateway`.
During that turn, `debug config` from the worker environment listed only the org document, the per-task config dir, the worktree's `.opencode` directory, and the launch-content document, a polled private server in that environment registered no MCP server, and the shared OpenCode log held no MCP line for that worktree.
`/exit` left the pane with exit status 0, and 127.0.0.1:49374 still belonged only to the operator's own server.

## Plugin form and busy state

A project `.opencode/plugins/fm-busy-state.js` exporting `default { id, setup }` loaded in the standalone server and received `{ type, data }` events through `ctx.event.subscribe()`.
Facts established live:

- A `setup` that never returns blocks the whole location: every subsequent API call (including `/api/model`) fails with `ServiceUnavailableError: Location plugins did not finish activating` after five seconds, and the TUI footer parks on `No provider selected`. The shipped plugin therefore consumes its event stream in a detached loop and aborts it from the returned cleanup.
- A complete turn emitted exactly `session.created`, `session.inbox.enqueued`/`delivered`, `session.execution.started`, `session.step.*`/`session.text.*`, `session.usage.updated`, `session.execution.succeeded`.
- `session.status` and `session.idle` never appeared in any turn on 2.0.32; the 2.0.32 source ships them only in the event schema, so busy/idle ride the execution events. `session.execution.interrupted` carries `reason:"user"` for a manual cancel, and `session.retry.scheduled` fires while the execution stays open (provider `ConnectionRefused` retries were observed recovering once the mock returned).
- Driving the real generated plugin through the real fm-spawn and a real TUI turn (the live guard below) recorded `busy opencode-plugin` on execution start and `idle opencode-plugin` with `event=execution-succeeded`, and touched the turn-end notification marker.

### Shared-server event scope (2026-10-22)

Established with probe plugins under `opencode v2.0.32`:

- Two processes with per-task config dirs (service disabled) never see each other's sessions: two `run` clients in separate projects, each with its own `OPENCODE_CONFIG_DIR`, received only their own session's events on their private servers. The shared data directory does not carry sessions across servers.
- The `session.execution.*` events carry no `location` on the bus, while `session.inbox.enqueued`, `session.instructions.updated`, `session.step.*`, and `session.usage.updated` carry `location.directory` naming the session's directory, and the plugin context exposes `ctx.location`.
- One per-user background server (`serve --service`) hosts sessions from many directories, and every location plugin loaded in it receives every hosted session's execution events: two `run` clients from two project directories sharing one background server (stand-in operator under isolated XDG dirs) each loaded their project's plugin into that one server process, and each plugin received the other project's `session.execution.started`/`succeeded`. The managed service port is machine-global (the default 49374 belongs to whichever context started first), so the live guard's stand-in gets its own `opencode service set port` value and marks every process it starts for exact cleanup.
- That is the 2026-10-19 cross-task defect's carrier: a bare `opencode` command that overrides the launch's per-task config dir loads the worktree's plugin into the long-lived shared server, where the pre-gate plugin latched any session that started an execution, so one settle flipped busy records and touched turn-ended notifications for every loaded task within milliseconds - including a task still mid-turn (its record had been flipped busy by the foreign start) and, through the pre-#34 plugin's unguarded direct touch, a task torn down hours earlier. The generated plugin now admits a session only after a location-carrying event names its own worktree, so a shared-server instance stays silent for every foreign session while still serving its own worktree's sessions; the live guard below proves both sides with two workers on one stand-in shared server.

## Lifecycle

Driven through the Herdr lab pane against the delayed mock:

- Exit: `/exit` plus Enter left the TUI to the shell prompt; two Ctrl-C presses also exit. The shared cursorless composer proof is owned by [runtime backends](runtime-backends.md#opencode-2-auto-mode-composer-2026-10-17-2026-10-18).
- Interrupt: the first Escape renders `esc again to interrupt` in the footer; a second press about 0.5s later interrupted (`session.execution.interrupted reason=user`, composer left empty), while a second press about 1.5s later left the armed hint standing without interrupting, so the control table arms on that hint and keeps the devin-grade 0.5s gap.
- Resume: relaunching with `--continue --prompt …` restored the previous session's transcript and auto-submitted the prompt (the busy record opened and settled with no manual send), unlike 1.x where `--prompt` does not auto-submit alongside `--continue`.
- Busy-queued Enter: while a turn ran, typed text stayed in the composer after Enter and the message was enqueued (`session.inbox.enqueued` with `delivery:"steer"`), then delivered when the turn ended - the same shape as 1.18.4.
- The 2.x TUI process `comm` is `opencode` (launched through either symlink name), so ancestry detection and the process-name evidence tables need no 2.x entry.

## Guards

```sh
bin/fm-test-run.sh tests/fm-opencode2-harness.test.sh
FM_OPENCODE2_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-opencode2-signals-live-e2e.test.sh
FM_OPENCODE2_ISOLATION_LIVE=1 bin/fm-test-run.sh tests/fm-opencode2-isolation-live-e2e.test.sh
```

Observed output on 2026-10-22:

```text
ok - opencode2 launch is standalone, config-isolated, and platform-only
ok - opencode2 worker gets a per-task OPENCODE_CONFIG_DIR that keeps OpenCode off the operator's shared background server
ok - opencode2 refuses a model outside the discovered platform providers
ok - opencode2 plugin classifies from session.execution events, scoped to the latched worker session
ok - an opencode2 plugin in a shared server ignores foreign-directory sessions
ok - an opencode2 settle racing teardown cannot resurrect task records
ok - opencode2 control mechanics match the verified 2.x facts
ok - opencode2 opencode v2.0.32 live: standalone TUI turn drove the generated plugin busy->idle with the notification touch, and /exit left the pane
ok - opencode2 opencode v2.0.32 live: two workers on one shared background server kept each task busy record and turn-ended notification confined to its own worktree
```

The portable suite pins binary selection, the platform-only launch line, the worker environment's isolated config dir and its service setting (by running the staged launch line against a fake 2.x binary), model refusals, the secondmate refusal, the generated plugin's directory-confined latch (a foreign-directory session's full cycle writes nothing; an own-directory session still drives busy->idle and the notification touch; both pins fail on the pre-fix generator), the teardown-racing settle refusal, and the control tables against fake binaries.
Both live guards are token-free and run by default wherever their tools are installed, capability-skipping elsewhere: the signals guard needs `opencode2`, `tmux`, `python3`, `node`, and `curl` and drives the TUI against a localhost mock, and the isolation guard needs `opencode2` and `python3` and runs the real binary against a stand-in operator under the XDG directories, with each isolated verdict paired with a control run that must see the stand-in operator's config.

## Not verified

- No 2.x primary supervision integration (turn-end guard, watch-arm, session-start nudge in the 2.x plugin form), which is why a secondmate on `opencode2` is refused.
- No sandbox placement: a sandbox host has none of the operator's OpenCode 2.x platform sign-in, so the org providers cannot resolve there.
- No effort mapping: no platform model exposes a variant list on 2.0.32, so the record-and-omit posture is untestable beyond its omission.
- No OpenCode Console sign-in: the 2.0.32 source loads a signed-in Console account's MCP servers and policies from the credential store, outside any config dir, and registers those MCP servers ahead of config-defined ones, but no Console connection exists here to exercise it.
- The gateway-log identity metadata (`user_id` UUID stamping) was read but not modified or stress-tested; that surface belongs to the platform project.
