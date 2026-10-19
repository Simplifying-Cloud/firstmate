# Remote task sandboxes

This page covers how to configure and operate the provider that runs Firstmate task sandboxes: short-lived, disposable virtual machines that host one task's working home.
It is for operators who wire a sandbox provider into a firstmate home and for anyone checking the adapter's safety behavior.

Sandbox placement runs an ordinary ship or scout in a one-task Firstmate home on a disposable VM, with the supervising home as its only supervisor.
Spawn places and launches such a task, its status is mirrored, the watcher supervises it and lifecycle control runs through its host, and teardown destroys its sandbox behind the landed-work gate; [current status](#current-status) lists what remains.

## Find a topic

| Task | Start here |
| --- | --- |
| Check what is wired today | [Current status](#current-status) |
| Understand the safety rules | [Principles](#principles) and [network profiles](#network-profiles) |
| Configure a provider | [Configure a provider](#configure-a-provider) |
| Drive the lifecycle by hand | [Operate](#operate) |
| Place a task in a sandbox | [Placement](#placement) |
| Understand task routes and readiness | [Task routes](#task-routes) and [task readiness](#task-readiness) |
| Read, steer, or check a placed task | [Status mirror and routed verbs](#status-mirror-and-routed-verbs) |
| Understand how a placed task is supervised, interrupted, stopped, or relaunched | [Supervision and lifecycle control](#supervision-and-lifecycle-control) |
| Understand what a sandbox host runs | [Host-side task control](#host-side-task-control) |
| Tear down a placed task, renew TTLs, or find orphans | [Teardown, TTL, and orphans](#teardown-ttl-and-orphans) |
| Handle capacity or failures | [Capacity and failures](#capacity-and-failures) |
| Run the tests | [Verification](#verification) |

## Current status

The sandbox placement plan ships in stages.
What is wired today:

- The provider adapter `bin/fm-sandbox.sh` and its configuration: an operator can configure a provider and drive every lifecycle verb by hand.
- [Task routes](#task-routes): the transport reaches a sandbox task's one-task home from that task's own record, and every command that branches on remote placement recognizes a sandbox task record.
- [Task readiness](#task-readiness): the readiness doctor checks a sandbox host against a task profile.
- [Host-side task control](#host-side-task-control): everything a sandbox host runs for its one task, from provisioning its home to retiring it, and briefs rendered for that home.
- [Placement](#placement): `bin/fm-spawn.sh --placement sandbox` creates a sandbox, converges and gates it, provisions its home with the task's credentials, launches the task, and records its route.
- [Status mirror and routed verbs](#status-mirror-and-routed-verbs): the worker's status lines reach this home's status log and wake Firstmate, scout terminal lines follow the report-fetch policy, and peek, steering, and current-state reads route to the task's host.
- [Teardown, TTL, and orphans](#teardown-ttl-and-orphans): teardown destroys a placed task's sandbox only behind its landed-work gate, PR registration reads a sandbox ship's heads without its worktree, and session start retries pending destroys, renews TTLs, and reports orphans.
- [Supervision and lifecycle control](#supervision-and-lifecycle-control): the watcher observes each placed task through its host on its own cadence for stale, dead-record, and unreachable wakes and the steering re-ring ladder; interrupt, exit, and relaunch run on the host, a relaunch republishes the record, and a rebooted host relaunches from the brief on disk; the fleet view shows a placed task's sandbox fields.
- [Credentials](#credentials): a GitHub credential can be a GitHub App installation token minted at spawn for the task's one repository, refreshed while the task runs, and revoked at retirement.

Real-cluster verification has passed for the reference provider on a full task lifecycle; [the verification record](verification/remote-sandboxes.md) owns its scope.
A launch that never published its final record still needs operator reconciliation; follow [orphan handling](../.agents/skills/bootstrap-diagnostics/SKILL.md) before removing a sandbox that may hold work.

## Principles

- [Placement](#placement) owns per-task selection, backlog recording, and the no-fallback rule.
- The feature is default-off.
  Provider operations require [provider configuration](configuration.md#sandbox-provider-configsandbox-provider); task transport requires an explicit [task route](#task-routes).
- The contract is provider-neutral.
  It names verbs and labels, not Proxmox, so an LXC or microVM provider can implement it later.
  The reference provider `pve-sandbox` lives in the proxmox-lab project.
- Firstmate never holds the Proxmox token and never calls the Proxmox API.
  Every provider effect and observation flows through `bin/fm-sandbox.sh`, which invokes the provider with argv only, never a shell string.
- Every sandbox carries two labels: `fm_task=<task-id>` and `fm_home=<home tag>`.
  `extend`, `hold`, `release`, `policy`, `exec`, `snapshot`, and `rollback` require an existing sandbox belonging to this home, enforced by the [adapter's shared status guard](../bin/fm-sandbox.sh).
  Destroying a sandbox refuses when the labels disagree, so one home can never destroy another home's sandbox, and an already-absent sandbox is success, so cleanup is idempotent.
- The adapter checks no landing evidence, so only [teardown](#teardown-ttl-and-orphans) destroys a placed task's sandbox behind its landed-work gate.
  Preserve unlanded work before invoking `destroy` by hand.

## Network profiles

- The `default` profile allows DNS and HTTPS egress, blocks LAN and RFC1918 destinations, and allows inbound SSH from the primary only.
- The `open` profile lifts those restrictions and requires explicit per-task `--profile open`; configuring `default_profile=open` is refused.
- `fm-sandbox.sh policy <name>` prints a sandbox's effective rules for visibility.

## Credentials

Sandbox credentials are Pi API-key providers plus per-repository GitHub tokens only.
They reach a sandbox only in its provisioning manifest, or for a refreshed GitHub App token on the stdin of its host's `cred-refresh` verb, are written only on the sandbox host with mode 0600, and never appear in output, logs, or task records; [host-side task control](#host-side-task-control) owns where they land.
Project origins containing embedded passwords are refused before sandbox creation.
The local, captain-owned `config/sandbox-credentials` selects which of them each task receives, by harness, model provider, delivery mode, and project; [the configuration reference](configuration.md#sandbox-credentials-configsandbox-credentials) owns its format.
Host keys are pinned by the provider, not trusted on first use, and the SSH configuration the sandbox aliases live in is provider-managed.

A GitHub credential whose source is `app` is a GitHub App installation token instead of a stored one, so the sandbox never holds a long-lived GitHub token.
[`bin/fm-cred-broker.sh`](../bin/fm-cred-broker.sh) mints it at spawn, before the sandbox exists, for exactly the task's repository: read-only for a scout and read-write for a ship, expiring within an hour.
The App's private key never leaves this home; [the configuration reference](configuration.md#github-app-configgithub-app) owns `config/github-app` and the App's permissions.

- While the task runs, the watcher refreshes the token about 15 minutes before it expires, pushing a fresh one to the host's `cred-refresh` verb, which stores it the way provisioning did.
The supervisor retains every minted token in a private pending-revoke set, revokes superseded tokens after confirmed delivery, and attempts revocation after refused or unknown delivery.
- A failed refresh is retried every few minutes and queues one `check: sandbox <id> credential refresh failed` wake per token, before that token expires; the [broker's header](../bin/fm-cred-broker.sh) owns the fixed cadence and bounds.
- A ship's retirement remains retryable until the supervisor's pending-revoke set is empty: each entry must be confirmed revoked or reach its own expiry, with the closure reason recorded.
The [broker's header](../bin/fm-cred-broker.sh) owns the protected storage and retirement contract.
A token minted for a spawn that never launched is revoked before the spawn exits.
- A scout's token, and a ship's under `--force`, are not revoked on the host: they end with the sandbox's destruction and their own expiry.
- Every mint, refresh, and revoke is recorded in this home's `state/cred-ledger` with its repository, access, expiry, and a fingerprint, never the token.

## Configure a provider

`config/sandbox-provider` is local and gitignored, selected by `FM_HOME` like every other config file; [the configuration reference](configuration.md#sandbox-provider-configsandbox-provider) owns its exact format.
The provider command must satisfy the invocation, record framing, ownership-label validation, and exit contracts that [the `fm-sandbox.sh` header](../bin/fm-sandbox.sh) owns.

## Operate

`bin/fm-sandbox.sh` is the single entry point, and its `--help` prints the verb list.

- `config` prints the validated settings - the provider's name, default profile, TTL, and the sandbox template's code root and home - without invoking the provider.
- `create <task-id>` asks the provider for a sandbox and prints its `name`, `vmid`, `node`, `ssh_alias`, `user`, `profile`, `ttl_expires`, and `hostkey`.
- `status <name>` prints the sandbox's `state` (`running`, `stopped`, or `absent`); running and stopped records require both `fm_task` and `fm_home`, while absent records may omit labels.
- `list` prints this home's sandboxes only, one record line per sandbox, requiring both ownership labels for running and stopped records it retains.
  Records without this home's `fm_home` label are dropped.
- `extend <name> --ttl <duration>` renews the TTL; `hold <name>` and `release <name>` manage the reap-blocking hold label.
- `policy <name>` prints the effective firewall rules.
- `exec <name> -- <argv>` runs one bootstrap command inside the sandbox; its argv is never a shell string.
- `snapshot <name> <label>` and `rollback <name> <label>` are an optional safety net the provider may implement.
- `destroy <name> --expect-task <task-id>` removes the sandbox, refusing when the labels disagree and treating an absent sandbox as success.

## Placement

`bin/fm-spawn.sh <task-id> <project> --mode <mode> --yolo <on|off> --placement sandbox` places a ship in a sandbox, and `--scout --placement sandbox` places a scout; [the spawn header](../bin/fm-spawn.sh) owns the exact refusals, sequence, and record fields.

- Placement is chosen per task, recorded with its reason in the task's backlog note, and passed explicitly; nothing infers it, and a refusal or an unavailable provider is a blocker, never a local fallback.
- Render the brief for the sandbox home with `bin/fm-brief.sh ... --for-home <remote_home> --for-root <remote_root>`, using the values `bin/fm-sandbox.sh config` prints; spawn refuses a brief that does not name that home's status file.
- `--sandbox-profile <name>` defaults to the provider's default profile.
  Any other profile, such as `open`, needs an explicit captain instruction for that exact task, recorded in its brief with `fm-brief.sh --sandbox-profile <name>`; spawn refuses it otherwise.
- Claude (unsupported by `config/sandbox-credentials` even after the Pi smoke run), second mates, `local-only` ships, backends other than tmux, raw harness commands, opencode2 (a sandbox host has none of the operator's OpenCode 2.x platform sign-in, so its org providers cannot resolve there), and briefs carrying the `--herdr-lab` contract are refused.
- A sandboxed Pi worker needs `--model <provider>/<id>` and a [credential](#credentials) for that provider.
  This home's worker account pins do not apply, because a sandbox's credentials come only from `config/sandbox-credentials`.

Spawn checks the backlog item before anything exists, then creates the sandbox and publishes a provisional task record carrying its [route](#task-routes).
One provider `exec` fast-forwards the sandbox's Firstmate code root to this home's default-branch commit before any `bin/fm-on.sh` call.
Read-only provider exec calls then verify exact HEAD equality and clean tracked files before the [task readiness](#task-readiness) gate checks the host.
The template must use `/opt/firstmate` for its code root and `/home/agent/fm-home` for its task home.
A mismatched or dirty code root refuses the spawn without resetting, checking out, or discarding changes.
[Host-side task control](#host-side-task-control) then provisions the home and launches the task, and spawn checks the route block it returns field by field before it publishes the final record and moves the backlog item to In flight.
Last, spawn arms the task's [status mirror](#status-mirror-and-routed-verbs); an arm that fails keeps the launched task and its record and names the arm command to rerun.

A failure before launch destroys the sandbox, which holds no work yet, and removes the provisional record.
Once launch may have started, including an SSH exit 255 that leaves its completion unknown, the sandbox is held and its record kept so the route stays reachable for reconciliation; spawn never destroys a sandbox that may hold work.
Spawn returns an SSH exit 255 from the transport unchanged, so a caller can tell an unreachable host from a refusal.

## Task routes

A sandbox task's explicit placement and route come from this home's `state/<id>.meta`; [`bin/fm-remote-route-lib.sh`](../bin/fm-remote-route-lib.sh) owns the required fields, validation, and remote dispatch contract.

- `bin/fm-on.sh <task-id> <fm-command>` resolves the route from the task's record, selected by its exact task id.
  It applies the same transport checks as a second-mate registry route, refuses a code root and home that overlap, and refuses a task id that also names a registry route.
  Second-mate registry routes are unchanged.
- Peek, steering, and the current-state read route a sandbox task to [host-side task control](#host-side-task-control), as [status mirror and routed verbs](#status-mirror-and-routed-verbs) describes.
- Teardown takes its [sandbox branch](#teardown-ttl-and-orphans), and lifecycle control and the watcher's supervision reach the host as [supervision and lifecycle control](#supervision-and-lifecycle-control) describes.
  Second-mate liveness and the watcher's queue checks skip it.
  None of them treats a sandbox task as a local task or as a remote second mate.

## Task readiness

`bin/fm-on.sh <task-id> fm-remote-doctor.sh --profile task` checks a sandbox host against the task profile; add `--fix` to repair its automatable gaps.
The [doctor's header and tool declarations](../bin/fm-remote-doctor.sh) own the profile's requirements, Herdr exclusions, repair boundaries, and line protocol.

## Status mirror and routed verbs

The worker appends status lines to its own home's `state/<id>.status` on the sandbox host.
[`bin/fm-procevent-remote-reply.sh`](../bin/fm-procevent-remote-reply.sh) mirrors them into this home's `state/<id>.status`, whose ordinary signal scan wakes Firstmate, and its header owns the route kinds and the mirror contract.

- The mirror is the [remote second-mate mirror](remote-secondmates.md#how-remote-lines-are-mirrored) with the task's status log as its source: the same cursor continuity, byte normalization, replay identity, one wake per mirrored line, and continuity-break escalation.
- This home's copy is the task's authoritative status log, because only it holds the `resolved` lines an answer writes here.
- A task's lines offer no documents and settle no correlated reply, so a `report=` pointer in them mirrors as written.
- For a scout, a mirrored `done` or `failed` line first fetches `data/<id>/report.md`, at most 1 MiB, through the path-confined reader into this home's `data/<id>/report.md`, so a successful fetch makes the report local before the line wakes anyone.
  The shared [document-fetch failure policy](remote-secondmates.md#when-an-offered-document-cannot-be-fetched) applies; a refused scout fetch also removes any older local report so it cannot stand in for the report the terminal line announces.

Peek, steering, and the current-state read route by task id to [host-side task control](#host-side-task-control):

- `bin/fm-peek.sh <task-id>` reads the worker's pane through `capture`; an unreachable host fails loudly and is never a death claim.
- `bin/fm-send.sh <task-id>` delivers through `send` into the worker's durable inbox, unmarked and keyed by a per-request id, so a retry lands on the same record while an identical later steer is a new instruction.
  [Its header](../bin/fm-send.sh) owns the unconfirmed-delivery resend; `--resolve-key` closes the decision in this home's status log, and `--key` crosses to the pane.
- `bin/fm-crew-state.sh <task-id>` combines this home's status fold with the run-step and busy readings `crew-state` reports from the host; [its header](../bin/fm-crew-state.sh) owns the composition.
- A sandbox task's recorded window, `remote:<task-id>`, names no endpoint here, so peek and steering refuse it.

Turn-ended notifications stay on the host, so mirrored status lines remain the primary supervision signal, which the host's observations [supplement](#supervision-and-lifecycle-control).

## Supervision and lifecycle control

The watcher supervises a placed task through its host's `observe` verb rather than through any local read.
[The watcher's sandbox observe branch](../bin/fm-watch.sh) owns the cadence, the bookkeeping, and every wake reason below.

- Each placed task is observed once per `FM_REMOTE_OBSERVE_SECS` (default 60) with one call bounded by `FM_REMOTE_OBSERVE_TIMEOUT` (default 20), so remote calls stay off the 15-second poll.
- An observation feeds the existing supervision rather than a copy of it: its pane hash and busy verdict drive the ordinary stale and wedge logic, its completed-turn or native-progress time drives the busy-turn bound, its newest worktree write drives the wedge timer's write deferral, and its oldest unacknowledged steering record drives the [re-ring ladder](../bin/fm-task-inbox-lib.sh), which rings through the host's `ring` verb.
- A positive `dead` or `missing` verdict from the host takes the once-per-incarnation dead-record report, keyed on the record's `spawn_gen`, and names whether the host has rebooted since the worker launched.
- An unreachable host, a host refusal, or a malformed observation is unknown, never stale and never dead: `FM_REMOTE_UNREACHABLE_COUNT` (default 3) consecutive failures queue one keyed `check: sandbox <id> unreachable` wake per failure streak, and observations retain the configured cadence throughout the outage.
- Lifecycle guards keep a launch or relaunch in flight from being reported as a death; the [watcher's observe branch](../bin/fm-watch.sh) owns deferral and rejection of reads that overlap a lifecycle change.
- In away mode the supervise daemon preserves confirmed-death recovery reports and retains pending stale tracking while observations are invalid, and rechecks it when current observations return ([its stale read](../bin/fm-supervise-daemon.sh)).

[`bin/fm-control.sh`](../bin/fm-control.sh) runs `interrupt`, `exit`, and `relaunch` for a placed task on its host's own copy of the control plane and relays the result; its header owns the sequence.

- SSH exit 255 is unknown completion, returned unchanged, and nothing on the primary changes.
- `relaunch` refuses before the host is touched when the note is missing, the harness would change, or a Pi model would name another provider, because a sandbox holds only the credentials it was provisioned with, and it refuses Claude as [placement](#placement) does.
- `relaunch` first sends this home's brief through the host's `brief-update` when it differs from the brief the host last received, because the replacement is briefed from the brief on the host's disk.
- After the host relaunches, the primary validates the route block the host confirms and invalidates the predecessor’s cached observation and failure streak under the lifecycle lock, and republishes its own record from it, keeping a `pr=` identity block last.
- For recovery after a VM reboot or HA restart, follow the [control plane's absence proof](agent-control.md#reclaiming-a-task-whose-endpoint-is-gone).

The fleet snapshot gives a placed task's row its remote kind, provider, sandbox name, and profile, the watcher's last observation as the endpoint, and its current state through its host; [the snapshot header](../bin/fm-fleet-snapshot.sh) owns the fields.
The inactive-outcome reconciliation never reads a sandbox host: it folds the mirrored status log alone and never probes the recorded worktree path ([its header](../bin/fm-inactive-reconcile.sh)).

## Host-side task control

A sandbox host runs [`bin/fm-remote-task-control.sh`](../bin/fm-remote-task-control.sh) for its one task, reached through `bin/fm-on.sh <task-id> fm-remote-task-control.sh <verb> <task-id>`; its header owns every verb, the provisioning manifest, and the output blocks.

- `provision` builds the one-task home from a manifest on stdin: it clones the project from its origin, writes the brief, launch configuration, and credentials, and marks the home with `.fm-task-home` last.
  The same manifest again changes nothing, another task's home or a different manifest is refused, and a failed attempt removes what it created.
- `launch`, `control`, `crew-state`, and `retire` run the host's own spawn, control plane, current-state read, and teardown, so the landed-work test that guards a local cleanup guards a sandbox's too.
  Host-side retirement supports ships only; scouts are refused because their completion gate belongs to the supervising home.
- `state`, `observe`, `capture`, `send`, `ring`, `key`, `head`, and `brief-update` read the endpoint, steer it through its durable inbox keyed by the primary's request id, ring that inbox's doorbell again for the watcher's re-ring ladder, and replace its brief.
- `cred-refresh` replaces the stored GitHub token with the fresh [minted token](#credentials) the primary pushes, refusing a retired task.
- `control` applies the [control plane's absence proof](agent-control.md#reclaiming-a-task-whose-endpoint-is-gone) on the host before reclaiming a missing endpoint.
- The task home's backlog is manual, because the task's backlog item lives in the supervising home.

Credentials are written only on the host: Pi entries into the account's `~/.pi/agent/auth.json` and the GitHub token into the account's gh credential store for github.com, each mode 0600.
Provision requires gh when a GitHub token is supplied, passes the token to `gh auth login --insecure-storage --with-token` on stdin, and restores the previous gh configuration if provisioning fails.
Storing the repository token in gh deliberately replaces passing `GH_TOKEN`: gh and git authenticate with the stored token exactly as they would with `GH_TOKEN`.
Git uses the absolute `gh auth git-credential` helper scoped to HTTPS github.com for the clone and its worktrees, and a no-mistakes ship's gate repository receives the same helper so the pipeline can fetch a private origin's trusted default branch through it; the token never enters command arguments or the launch environment.

Use the remote-rendered brief described under [placement](#placement); [the brief header](../bin/fm-brief.sh) owns its path substitution contract.
A sandbox brief must be self-contained, because the sandbox cannot read the supervising home's reports.

## Teardown, TTL, and orphans

A placed task's worktree is its sandbox, so destroying the sandbox is its teardown, and the landed-work gate stands in front of that destroy exactly as it stands in front of a local worktree return.
`bin/fm-teardown.sh <task-id>` runs it; [the teardown script's sandbox branch](../bin/fm-teardown.sh) owns the exact sequence and refusals, and [`bin/fm-sandbox-reconcile-lib.sh`](../bin/fm-sandbox-reconcile-lib.sh) owns the inventory read and the destroy.

- Teardown enforces the [sandbox branch's inventory and ownership checks](../bin/fm-teardown.sh), including its narrow records-only exception for `--force` when provider status positively confirms absence.
- A scout needs its report locally, fetched through the status mirror's confined reader when it is missing, and the same captain-call completion gate as a local scout.
  No host-side teardown runs, because a scout's worktree is scratch.
- A ship runs its host's `retire`, the host's own teardown with the full landed-work test.
  A refusal is relayed, and the sandbox, its hold label, the record, and the backlog item stay; an SSH exit 255 is unknown completion and preserves everything for a rerun.
- On a pass, teardown closes this home's records and backlog item and retires the status mirror, and only then destroys the sandbox, once, with `--expect-task` label confirmation.
  A failed destroy leaves `state/<id>.sandbox-destroy-pending`, which session start retries once the task's backlog transition has landed.
- `--force` is the captain's explicit discard: it skips the scout gate and the host's `retire`, because destroying the sandbox discards everything on it.

`bin/fm-pr-check.sh` registers a sandbox ship's PR without reading its worktree locally; [the named-head gate](../bin/fm-dod-lib.sh) owns when forge evidence suffices and when the host's `head` verb must verify the sandbox copy.
A Gerrit change from a sandbox ship cannot pass that gate, because its published-tree check needs the copy itself.

Every Firstmate-owned sandbox carries the reap-blocking hold label from creation until its destroy.
Session start's deferred network checks retry pending destroys, renew the TTL of every sandbox a task record names, and compare this home's inventory with its records.
A sandbox no record names is reported as an orphan and never destroyed automatically, because a crash between launch and publication can leave real work in it.
[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns those reports, and the [bootstrap diagnostics playbook](../.agents/skills/bootstrap-diagnostics/SKILL.md) owns the response to each.

## Capacity and failures

Provider capacity refusals during lifecycle calls and ownership status checks surface as blockers; [the adapter header](../bin/fm-sandbox.sh) owns the exact exit statuses, including the raw relay behavior once `exec` begins.
Treat it like any other infrastructure blocker: surface it, free sandboxes, or wait; never fall back to local placement.

Refusals name the concrete configuration, provider, or output problem, and provider failures include its stderr.
Invalid output is withheld, but refusal does not roll back effects the provider already performed.
Usage errors are rejected before invoking the provider.
After the ownership status check, `exec` relays raw provider output and exit status unchanged, including nonzero statuses; it does not apply lifecycle record validation or capacity translation.

## Verification

```sh
bin/fm-test-run.sh tests/fm-sandbox.test.sh
bin/fm-test-run.sh tests/fm-cred-broker.test.sh
bin/fm-test-run.sh tests/fm-remote-route-lib.test.sh
bin/fm-test-run.sh tests/fm-remote-task-control.test.sh
bin/fm-test-run.sh tests/fm-remote-task-spawn.test.sh
bin/fm-test-run.sh tests/fm-remote-task-lifecycle-e2e.test.sh
bin/fm-test-run.sh tests/fm-teardown-remote-task.test.sh
bin/fm-test-run.sh tests/fm-control-remote-task.test.sh
bin/fm-test-run.sh tests/fm-watch-sandbox-observe.test.sh
```

The adapter suite drives every verb against a fake provider, including the refusal paths, the home-tag filtering, the capacity distinction, and argv-only invocation.
The broker suite drives `bin/fm-cred-broker.sh` against a fake GitHub API: a JWT that verifies with its key, the request and permission set for each access level, refusals of an unsafe key file and malformed configuration, success, a 401, and a repository mismatch, the refresh and its single failure wake, and a search of the ledger, every output, and every argument for a long planted token.
The route suite pins the task record contract and the consumer behavior described under [task routes](#task-routes), checking that routed verbs cross only the transport to the task's own host and that unsupported operations never reach the transport or a local backend, all leaving the task record unchanged.
The task control suite drives every host-side verb against a fixture home with fake tmux, including provision idempotence and rollback, foreign-home refusal, credential file modes, and a search of every output and record for planted credential values.
The placement suite drives `bin/fm-spawn.sh --placement sandbox` against a fake provider and a fake SSH transport that runs the real host-side control plane with fake tmux, covering the refusal matrix, the record fields, destroy before launch, the hold once launch may have started, SSH exit 255, the mirror armed at publish, and a search of every output, record, log, and argument for planted credential values.
The lifecycle suite drives a placed ship and scout on the same harness through the real process-event runner: a mirrored decision, a steer that answers it with `--resolve-key`, peek, the composed current state, and a scout report that is local before its terminal line lands.
The teardown suite drives a placed ship and scout on the same harness through `bin/fm-teardown.sh`: an unlanded refusal that keeps the sandbox, a landed pass that destroys it exactly once with label confirmation and only after the records are gone, SSH exit 255 preserving everything, the scout report and completion gates, `--force`, an identity refusal, a failed destroy that session start later retries, and a backlog close that fails in teardown and again in its replay, which keeps the sandbox until the close lands.
The lifecycle control suite drives `bin/fm-control.sh` against a placed ship whose host is a real provisioned and launched one-task home reached through a fake SSH transport: interrupt and exit on the host, SSH exit 255, the relaunch refusals, the brief sent only when it changed, the republished record with its `pr=` block last, and a rebooted host whose endpoint `exit` reports gone and `relaunch` re-creates.
The watcher suite drives a real watcher against a placed task whose transport answers from canned observations: the observe cadence, an observation-driven stale wake, the once-per-incarnation dead-record report, the one unreachable wake per failure streak, no observation while a spawn or control action holds the task, the re-ring ladder through the host, and the write deferral from the host's write field.
Sandbox PR registration is covered by `tests/fm-pr-check-security.test.sh`, and session start's pending destroys, TTL renewal, and orphan reports by `tests/fm-bootstrap.test.sh`.
Snapshot rows for placed tasks are covered by `tests/fm-fleet-snapshot-view.test.sh`, and the inactive-outcome reconciliation's sandbox handling by `tests/fm-inactive-reconcile.test.sh`.
The status mirror's route kind, peek, steering, and the current-state composition are also covered by `tests/fm-remote-reply.test.sh`, `tests/fm-peek-remote.test.sh`, `tests/fm-send-remote-delivery.test.sh`, and `tests/fm-crew-state.test.sh`.
Brief rendering for a sandbox home and the spawn refusal are covered by `tests/fm-brief.test.sh` and `tests/fm-task-delivery.test.sh`.
Task route resolution and the task readiness profile are covered by `tests/fm-on.test.sh` and `tests/fm-remote-doctor.test.sh`, part of the [remote second-mate suite](remote-secondmates.md#portable-tests).
The real-cluster smoke run behind these guarantees is recorded in [the sandbox verification record](verification/remote-sandboxes.md).
