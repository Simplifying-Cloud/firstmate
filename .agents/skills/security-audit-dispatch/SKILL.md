---
name: security-audit-dispatch
description: >-
  Load when the captain requests a security audit, vulnerability review, or pen test of a project,
  or when classifying such a request at intake: owns the scout classification for audits, pointing
  the audit worker at the vendored skills/security-audit skill by absolute path, the findings flow
  into ship tasks, needs_validation lead tracking, and the sandbox gate for target-code execution.
user-invocable: false
metadata:
  internal: true
---

# Security-audit dispatch

A security audit is a scout task under section 7 of `AGENTS.md`, never a ship and never a PR.
The deliverable is the audit itself: the worker runs the vendored skill with its output directory pinned under the dispatching home's `data/<task-id>/` tree (for example `data/<task-id>/security-audit/`), and the scout report points at the skill's `REPORT.md`, `findings.json`, and coverage ledger there.
The audit brief must extend the scout write allowance (scaffold Rule 2) to exactly that pinned output tree `data/<task-id>/security-audit/` in the dispatching home, alongside `report.md` and the status file, and nothing else.

Audit placement must be local: a remote-sandbox placement is refused for audits until a later change defines how the pinned skill reaches the sandbox and how `findings.json` and the coverage ledger come back to the supervising home.

## Pointing the worker at the skill

The skill is vendored, pinned, and read-only at `skills/security-audit/` in this repository's checkout (`PROVENANCE.md` there owns the pinned commit and deliberate-update procedure).
The scout brief passes the absolute path to `skills/security-audit/SKILL.md` in the firstmate checkout that dispatches the task, and tells the worker to resolve the skill directory from that file.
Never copy the skill into the target project, install it into any user-level agent directory, or let the worker edit it.
The brief states the operating mode: full audit mode only for an explicit audit request, guidance mode for a security question or focused review.

## Findings flow

Confirmed findings are evidence, not fixes: each confirmed finding the captain wants addressed becomes its own ship task under section 7, seeded from the finding's remediation and trace.
`needs_validation` leads are not findings and carry no severity: keep them tracked as backlog items or notes referencing the audit output so a later run or owner observation can resolve them.
Rejected claims stay in the audit output and need no task.

## Sandbox gate

The skill requires an OS-enforced sandbox (no external network, empty allowlisted environment, read-only target, scratch-only writes, explicit resource limits) before any target-controlled execution, and its own rule is to skip execution and record a `needs_validation` blocker when any control is missing.
Firstmate holds the same line: until the captain approves a sandbox that meets those controls, audit workers do not execute target code at all, and the audit proceeds source-only with its execution-dependent claims recorded as `needs_validation` leads.
Proposing or building that sandbox is a separate task for the captain to decide, not something an audit worker improvises.
