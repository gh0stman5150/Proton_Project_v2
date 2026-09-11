# Documentation review — 2026-09-10

## Scope and evidence

Reviewed first-party Markdown against the canonical installer, runtime helpers,
systemd units, shared Compose policy, manifest, Bats tests, and GitHub CI.
This was a documentation-only change; it did not install files or operate the
live fleet. Earlier agent-hierarchy changes were preserved.

`/archive` is absent. No archive-based root-cause claim was made. Upstream
`bats-core` is a pinned test dependency, not first-party documentation to rewrite.
External kernel/CVE sources and gh-aw resources were not refreshed; existing
incident evidence retains its recorded time scope.

## Files changed in this review

| File | Improvement |
| --- | --- |
| `README.md` | Prerequisites, protected authentication, installer limits, service names and state paths, recreation exceptions, development and support guidance |
| `AGENTS.md` | Shared-helper, error/logging, documentation ownership, evidence and PR standards |
| `.github/copilot-instructions.md` | Navigation to authoritative guidance without duplicate policy |
| `.github/prompts/documentation-governance.prompt.md` | Bash scope, safety precedence, historical evidence and compatibility preservation |
| `.github/agents/agentic-workflows.md` | Upstream prompt resources distinguished from local files |
| `docs/README.md` | Recorded baseline distinguished from fresh runtime verification |
| `docs/architecture/qbittorrent-fleet-contract.md` | Missing-port forced-repair exception and dated kernel observations |
| `docs/runbooks/qbittorrent-port-sync.md` | Read-only API verification, recreation exceptions, chained allocator example |
| `docs/runbooks/qbittorrent-fleet-changes.md` | Correct all-script syntax checking and CI lint expectations |
| `docs/runbooks/qbittorrent-wedge-recovery.md` | Stop-on-failure recovery, affected-instance selection, chained scratch check, dated kernel evidence |
| `docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md` | Historical observation-window note; original evidence retained |
| `docs/documentation-review-2026-09-10.md` | Review findings and follow-ups |

## Outdated content corrected

- Removed unfinished singleton migration language and command-line password
  examples from onboarding; retained supported compatibility behavior.
- Replaced singleton service and runtime-state examples with the instance model.
- Corrected the claim that an unchanged artifact always prevents recreation:
  mapping drift, guarded self-heal and forced rollout are distinct cases.
- Removed the implication that Docker IPv6 enforcement is unimplemented.
- Replaced a mutating synchronizer under verification instructions with the
  read-only fleet runtime verifier.
- Corrected multi-file `bash -n` examples to check each script separately.

## Assumptions, gaps and follow-ups

- Source and the AGENTS safety contract remain authoritative. Source tests do
  not prove installed provenance, live health, kernel repair, or a longer
  recurrence-free observation period.
- No support owner, on-call contact or SLA is declared. A maintainer should add
  confirmed details; none were invented.
- A validated clean-host bootstrap procedure is missing: the installer does
  not create the NAS, external Docker network or all five Compose wrappers.
  Document those prerequisites before treating this as turnkey provisioning.
- Preference differences recorded in the architecture remain follow-up work;
  this review did not normalize application settings.
- The sync script's no-published-port error still suggests cgroup/shim cleanup.
  That message conflicts with the recovery boundary unless tasks have first
  been classified. Follow the wedge runbook; correct the diagnostic in a
  separate source change with behavioral validation.
- Optional gh-aw resources are upstream and absent locally. The router now
  states this explicitly; upstream compatibility was not audited.
- shfmt is not installed locally. No shell source changed; its CI formatting
  gate remains required for future shell changes.

## Quality assessment

Validation passed: the focused documentation contract tests, full Bats suite,
ShellCheck (including `-x`), individual Bash syntax checks, relative Markdown
file links, and `git diff --check`. The revised recovery example also passed
syntax and mocked-command checks for successful sequencing and stopping at
failures in both the first and second instance. No live commands were executed.

Before: detailed safety and incident coverage, but onboarding mixed legacy and
named-instance operation, verification examples could mutate state, and recovery
examples did not consistently preserve failure status.

After: requirements and gaps are explicit, examples better match source,
instruction ownership remains centralized, and historical observations are
distinguished from live verification. The repository is clearer for maintaining
the existing fleet; it is not yet a validated clean-host provisioning guide.
