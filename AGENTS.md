# Proton Project Agent Guide

## Purpose And Instruction Scope

This Bash project manages host Proton WireGuard routing, firewall protection,
and NAT-PMP port synchronization for five Docker-hosted qBittorrent clients.

- `Proton_Project_v2.code-workspace` opens only this repository (`.`). This file serves as both workspace and repository guidance; `/usr/local/bin` is not a declared multi-repository workspace.
- This file is the authoritative project guide. `.github/copilot-instructions.md` remains a compatibility pointer to it; task prompts and workflow-specific guidance do not replace its safety boundaries.
- `bats-core/` is a pinned upstream Git dependency used as the test runner, not another application maintained by this project. Follow its `docs/CONTRIBUTING.md` if explicitly changing that dependency; ordinary Proton changes belong outside it.
- No separate workspace conventions or nested project instruction files are needed for the current single-repository layout. Reassess scope if the workspace gains another maintained repository or a distinct subproject.

## Repository Layout And Tooling

- Root `proton-*.sh`: tunnel lifecycle, shared helpers, routing/firewall policy, port allocation and synchronization, and health checks.
- `install-proton-systemd.sh`, root `*.service`, and `*.conf`: installation, systemd units, and boot-ordering drop-ins.
- `qbittorrent-compose.common.yml` and `qbittorrent-instances.tsv`: shared container policy and fleet identity manifest.
- `tools/`: fleet verification and sequential reconciliation.
- `Archive/`: relocated legacy and maintenance scripts; see `Archive/README.md`. Two archived cleanup scripts still supply installed runtime entrypoints. `Archive/verify_serialized_sync.sh` invokes allocation and sync and can mutate runtime state despite its name.
- `tests/`: Bats behavioral and contract tests. Existing tests use temporary fixtures and PATH-injected command stubs to isolate host operations.
- `docs/` and `README.md`: architecture, operator procedures, and historical incident evidence; see the documentation map below.
- `.github/`: CI, compatibility instructions, task prompts, and optional Agentic Workflows guidance.
- `bats-core/`: checked-out Bash test runner. The Proton application has no package-manager build step; CI installs ShellCheck, shfmt, and Bats through apt.

Match the owning script's Bash conventions and reuse shared helpers. Keep host
commands mocked in behavioral tests and use synthetic credentials in fixtures.
CI checks tracked shell scripts with shfmt and `shellcheck -x`, then runs Bats.

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

- The live SMB 3.1.1 `/mnt/data` mount uses `cache=none`. This is the active fleet-wide mitigation for all five qBittorrent clients and every other `/mnt/data` consumer, not a staged option or a demonstrated kernel fix.
- The third oops occurred at 19:05 CDT on 2026-08-17 under `cache=strict`; fstab changed at 20:01, and the 20:16 reboot created the first live `cache=none` mount. Never attribute that oops to `cache=none`.
- `mnt-data.mount` and `mnt-plex.mount` require and follow `nas-network-online.service`, which checks both NAS route availability and TCP port 445 before succeeding.
- Docker wants and follows all five `proton-wg@<instance>.service` units. This is startup ordering, not proof of tunnel health; the kill switch and runtime verifier remain required.
- `install-proton-systemd.sh` owns both the NAS mount drop-ins and the Docker tunnel-ordering drop-in. Update and validate the installer source rather than editing installed drop-ins as one-off fixes.
- Local incomplete storage is not capacity-safe for the current fleet. Any future storage-layout change is shared fleet structure and requires capacity, import/move, permissions, cleanup, rollback, and all-five validation.

## Wedge Detection

- A zombie is an immediate recreation refusal.
- A single `D`-state snapshot can be normal transient CIFS I/O. Automation samples LWP IDs and treats only the same task remaining in `D` state across samples as a persistent wedge.
- Persistent `D` state, especially with `folio_wait_bit_common` plus CIFS/netfs errors or a kernel oops, is a host-kernel recovery boundary. Preserve evidence and require a coordinated reboot; repeated signals or Docker cleanup cannot repair it.
- Human incident triage may stop mutation on the first observed `D` state while sampling and kernel evidence are collected. Do not weaken the persistent-wedge guard to bypass a real blocked task.
- Do not call a kernel version the fix without exact patch provenance and workload validation. Ubuntu `7.0.0-30.30` has no relevant netfs change, `7.0.0-31.31` is proposed-only, and the related Linux 7.1.8 and 7.2 repairs have not been demonstrated to prevent this exact oops.

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
shellcheck ./*.sh tools/*.sh Archive/*.sh
for script in ./*.sh tools/*.sh Archive/*.sh; do bash -n "$script" || exit; done
git diff --check
```

Fleet gates:

```bash
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The `--recreate` command performs final runtime verification. Do not append a separate newline-delimited verifier as a substitute for checking its exit status.

## Documentation Map

- Architecture and invariants: `docs/architecture/qbittorrent-fleet-contract.md`
- Port synchronization: `docs/runbooks/qbittorrent-port-sync.md`
- Shared fleet changes: `docs/runbooks/qbittorrent-fleet-changes.md`
- Kernel/storage wedge recovery: `docs/runbooks/qbittorrent-wedge-recovery.md`
- Sonarr incident record: `docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md`

Keep historical evidence intact, but add dated recovery updates when operational status changes. Avoid hard-coded documentation or test line totals that become stale after ordinary edits.

## Contributor And Documentation Standards

- Reuse `proton-instance-common.sh` for instance loading and route locks, and `proton-qbittorrent-common.sh` for protected configuration and API authentication. Keep error exits and cleanup behavior consistent with the owning script; do not mask failed activation with a later successful check.
- Preserve existing logging conventions: runtime scripts generally use their `LOG_TAG` and `systemd-cat`, with stderr fallback where implemented; installer and verification tools report to the terminal. Log the instance, operation, and failure without credentials or complete environment dumps.
- Treat implementation and tests as evidence of behavior, and this guide as the required safety contract. If code conflicts with a safety invariant, report the defect rather than weakening the invariant to match code.
- Keep README onboarding concise, architecture in `docs/architecture`, operations in `docs/runbooks`, and dated evidence in `docs/incidents`. Link to the owning document instead of copying a second procedure into Copilot guidance.
- Check documented paths, flags, service names, configuration precedence, and mutation effects against source. Distinguish source validation, installation, and live verification. Label historical package/health observations with their evidence period; documentation edits do not extend it.
- PRs or change records should explain the concrete problem, scope, final behavior, validation, documentation impact, and any deployment/rollback requirements. No additional branch or commit naming convention is established here.
