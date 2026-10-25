# Provenance

This directory is a reviewed, pinned copy of the `security-audit` skill vendored from [cloudflare/security-audit-skill](https://github.com/cloudflare/security-audit-skill).

- Source: https://github.com/cloudflare/security-audit-skill
- Commit: `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8` ("Clarify guidance and full audit modes", 2026-09-14)
- License: MIT, Cloudflare, Inc.; the upstream `LICENSE` file is vendored unchanged beside this note.
- Vendored content: every file of the upstream `skills/security-audit/` directory, byte-for-byte, plus this note.
- Not vendored: the upstream repository-root `README.md`, whose `npx skills add` instructions install whatever upstream version is current at install time; this copy exists so audits run against a reviewed fixed version instead.

Every upstream file here is pinned verbatim and must never be edited in place, so a future diff against the pinned commit stays meaningful.

To update deliberately: clone the upstream repository, review every changed file for code execution, network access, and agent-facing safety instructions, vendor the new state byte-for-byte, rerun `node --test validate-findings.test.cjs validate-coverage-ledger.test.cjs` and both validators from this directory, then update the commit, date, and review result in this note.

How firstmate dispatches audits with this skill is owned by `.agents/skills/security-audit-dispatch/SKILL.md` in this repository.
