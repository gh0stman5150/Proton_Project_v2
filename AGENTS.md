# Proton Project Agent Guide

## Purpose And Instruction Scope

This Bash project manages host Proton WireGuard routing, firewall protection,
and NAT-PMP port synchronization for five Docker-hosted qBittorrent clients.
This file is the authoritative project guide; task prompts and workflow guidance
never replace its safety boundaries. Instruction-file maintenance notes live in
`.github/copilot-instructions.md`.

## Repository Layout And Tooling

- `Archive/`: git-ignored legacy helpers kept on the host only; `Archive/verify_serialized_sync.sh` invokes allocation and sync and can mutate runtime state despite its name. See `Archive/README.md`.
- `qbittorrent-compose.common.yml` and `qbittorrent-instances.tsv`: shared container policy and fleet identity manifest.
- `bats-core/`: pinned upstream test runner, not project code; change it only when explicitly asked. There is no package-manager build step; CI installs ShellCheck, shfmt, and Bats through apt.

Match the owning script's Bash conventions and reuse shared helpers. Keep host
commands mocked in behavioral tests (temporary fixtures, PATH-injected stubs)
and use synthetic credentials in fixtures. CI checks tracked shell scripts with
shfmt and `shellcheck -x`, then runs Bats.

## Authority And Repository Location

- The canonical source repository is `/usr/local/bin/proton_project`.
- Treat `/opt/proton_project_work` as a non-authoritative working copy that may be stale. Do not patch, validate, or quote it as current unless the user explicitly asks to synchronize or inspect it.
- Installed production entrypoints live under `/usr/local/bin/proton`. Never edit installed copies directly; change canonical source, validate it, then run `install-proton-systemd.sh` with administrator approval.
- The worktree may already contain user changes. Preserve them and keep edits scoped.

## Safety Boundaries

- Never print or commit qBittorrent passwords, WireGuard private keys, cookie jars, or complete protected environment files.
- Do not reboot, restart Docker/containerd, force-unmount CIFS, kill shims, write `cgroup.kill`, or perform fleet/container recreation without explicit outage or runtime authorization.
- Administrator passwords must be entered by the user directly in the terminal. Never request or relay them through chat tools.
- Chain dependent activation commands with `&&`. A newline-separated verifier can mask an earlier failed installer or rollout because the shell reports only the final command's status.
- If `/archive` is absent or empty, say so explicitly and proceed without archive-based root-cause claims.
- Keep uploading and seeding enabled. Do not introduce torrent queueing, active-upload limits, seeding limits, or a one-instance storage exception as an incident workaround. Shared changes roll sequentially so the other four clients remain available while one member is reconciled.

## qBittorrent Fleet Contract

- Managed instances: `lidarr`, `prowlarr`, `radarr`, `sonarr`, and `whisparr`.
- `qbittorrent-compose.common.yml` owns shared image, environment, volume, health, restart, shutdown, and network policy.
- `qbittorrent-instances.tsv` owns instance identity: Web UI port, bind IP, interface, subnet, route table, and qBittorrent rule priority.
- Each `/opt/qbittorrent-<instance>/docker-compose.yml` remains a thin wrapper around the shared policy.
- Each project `.env` contains exactly one assignment: `QBT_HOST_BIND_IP`.
- Each protected dynamic artifact contains exactly one assignment: `QBT_PUBLISHED_PORT`. `QBT_FORWARDED_PORT` is prohibited.
- Compose must require an explicitly injected Proton port and VPN bind IP. Never add a stale-port or `0.0.0.0` fallback.
- A lease change recreates only its owning container. A shared structural change rolls all five sequentially through the fleet reconciler.
- Never copy a complete `qBittorrent.conf` or one instance's lease to another instance.

## Installer And Runtime Invariants

- `install-proton-systemd.sh` installs executables under `/usr/local/bin/proton`, units under `/etc/systemd/system`, and shared fleet files under `/opt/qbittorrent-common`.
- The installer preserves secrets while reconciling required non-secret keys in existing instance configs: `VPN_TABLE`, `QBT_VPN_RULE_PRIORITY`, and `QBT_INSTANCE_NAME`.
- Existing port artifacts are atomically normalized to one valid `QBT_PUBLISHED_PORT` while preserving the port.
- Systemd `ExecStart` paths must never target the source checkout.
- Shared policy-route mutation uses `/run/proton/policy-routing.lock`; host-wide firewall mutation uses `/run/proton/killswitch.lock`.
- Ordinary per-instance sync is non-blocking and may skip when its lock is busy. Forced fleet sync waits for the lock and fails on timeout; it must never silently report success without recreating the instance.

## Host Storage And Boot Invariants

- `cache=none` on `/mnt/data` is the active fleet-wide mitigation for all five clients; never attribute a past oops to it or treat it as a demonstrated kernel fix. Boot ordering (NAS mount, Docker-vs-tunnel) is startup sequencing only, not proof of tunnel health — the kill switch and runtime verifier remain required.
- `install-proton-systemd.sh` owns the NAS mount and tunnel-ordering drop-ins; fix the installer source, not installed drop-ins.
- Local incomplete storage is not capacity-safe. Treat any storage-layout change as shared fleet structure requiring all-five validation and rollback.
- Full mount/oops timeline, dependency edges, and kernel-package evidence: `docs/architecture/qbittorrent-fleet-contract.md`.

## Wedge Detection

- A zombie is an immediate recreation refusal. A single `D`-state snapshot can be normal transient CIFS I/O. Only the same task remaining in `D` across samples is a persistent wedge.
- A persistent wedge (especially `folio_wait_bit_common` plus CIFS/netfs errors or a kernel oops) is a host-kernel recovery boundary: preserve evidence, require a coordinated reboot, and never escalate through signals/Docker cleanup as a repair.
- Do not weaken the persistent-wedge guard to bypass a real blocked task, and do not call any specific kernel version the fix without exact patch provenance and workload validation.
- Full decision table and kernel-package evidence: `docs/runbooks/qbittorrent-wedge-recovery.md`.

## Change Workflow

1. Start from canonical source and inspect the owning script, nearby tests, and relevant runbook.
2. State whether the change is per-instance runtime behavior, shared fleet structure, or an intentional role override.
3. Make the smallest shared-source change. Do not create instance forks for common behavior.
4. Add behavioral tests for control-flow and safety changes; grep-only assertions are supplementary.
5. Run focused tests immediately after the first edit, then the full suite and static checks.
6. Update architecture, runbooks, incident status, and operator commands when behavior or recovery boundaries change.
7. Deploy only after explicit authorization. Verify source/installed checksums when installation provenance matters.

## Validation

From `/usr/local/bin/proton_project`:

```bash
./bats-core/bin/bats tests
shellcheck ./*.sh tools/*.sh
for script in ./*.sh tools/*.sh; do bash -n "$script" || exit; done
git diff --check
```

Fleet gates:

```bash
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

`--recreate` performs final runtime verification; check its exit status rather
than appending a separate newline-delimited verifier.

If containers were removed, bootstrap with the installed tool, never raw Docker.
It restores all five sequentially through the live lease and Compose
synchronizer, then verifies; it must not bypass zombie or persistent `D`-state
gates:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-recreate.sh --bootstrap
```

## Documentation Map

- Architecture and invariants: `docs/architecture/qbittorrent-fleet-contract.md`
- Port synchronization: `docs/runbooks/qbittorrent-port-sync.md`
- Shared fleet changes: `docs/runbooks/qbittorrent-fleet-changes.md`
- Kernel/storage wedge recovery: `docs/runbooks/qbittorrent-wedge-recovery.md`
- Host routing, tunnels, DNS, healthcheck, installer: `docs/architecture/host-routing-and-tunnels.md`
- Server pool, IPv6 rollout, host verification: `docs/runbooks/{server-pool-selection,ipv6-rollout,host-verification}.md`
- Sonarr incident record: `docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md`

Read the incident record only for incident history or root-cause questions; the
wedge runbook holds the current decision table. Prefer the owning runbook over
the full README once the task area is known.

Keep historical evidence intact, but add dated recovery updates when operational status changes. Avoid hard-coded documentation or test line totals that become stale after ordinary edits.

## Contributor And Documentation Standards

- Reuse `proton-instance-common.sh` for instance loading and route locks, and `proton-qbittorrent-common.sh` for protected configuration and API authentication. Keep error exits and cleanup behavior consistent with the owning script; do not mask failed activation with a later successful check.
- Logging: runtime scripts use their `LOG_TAG` with `systemd-cat` (stderr fallback where implemented); installer and verification tools report to the terminal. Log instance, operation, and failure without credentials or environment dumps.
- Treat implementation and tests as evidence of behavior, and this guide as the required safety contract. If code conflicts with a safety invariant, report the defect rather than weakening the invariant to match code.
- Keep README onboarding concise, architecture in `docs/architecture`, operations in `docs/runbooks`, dated evidence in `docs/incidents`, and dated reviews in `docs/reviews`. Link to the owning document instead of restating a procedure.
- Verify documented paths, flags, service names, config precedence, and mutation effects against source. Distinguish source validation, installation, and live verification. Label historical package/health observations with their evidence period; doc edits do not extend it.
- PRs and change records state the problem, scope, final behavior, validation, documentation impact, and deployment/rollback needs. No branch or commit naming convention is established.
