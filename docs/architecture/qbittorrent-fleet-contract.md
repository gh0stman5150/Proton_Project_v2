# qBittorrent fleet architecture and invariants

## Purpose

This document defines what must be identical across the five managed qBittorrent instances, what must remain instance-specific, and how Proton's dynamic port is applied without allowing configuration drift.

The fleet consists of:

- `qbittorrent-lidarr`
- `qbittorrent-prowlarr`
- `qbittorrent-radarr`
- `qbittorrent-sonarr`
- `qbittorrent-whisparr`

The phrase **change one, change all** applies to fleet-controlled structure and behavior. It does not mean that all five instances share one Proton port, one WireGuard identity, one qBittorrent configuration file, or one runtime state directory.

## Architecture overview

```text
                         one host-wide kill-switch policy
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
  Proton tunnel 1               Proton tunnel ...             Proton tunnel 5
  10.2.0.2                      independent address           10.6.0.2
        │                             │                             │
  NAT-PMP lease                  NAT-PMP lease                  NAT-PMP lease
        │                             │                             │
  /run/proton/lidarr/...         /run/proton/<name>/...        /run/proton/prowlarr/...
        │                             │                             │
        └──── proton-qbittorrent-sync-safe.sh (same code) ─────────┘
                                      │
             ┌────────────────────────┼────────────────────────┐
             │                        │                        │
      qBittorrent API       one-key persistent artifact    Compose recreation
       listen_port          QBT_PUBLISHED_PORT=<n>       TCP+UDP on tunnel IP
             │                        │                        │
             └────────────────────────┼────────────────────────┘
                                      │
                           post-recreate verification
```

## Host availability and storage contract

The five clients share one host and one `/mnt/data` CIFS mount, but they must not share one outage when a rolling operation can isolate it.

- Shared changes recreate one qBittorrent member at a time. The other four remain available for downloading, uploading, and seeding while the changed member passes its health gate.
- Do not globally pause torrents or add queueing, active-upload, or seeding limits as a rollout or incident mitigation. The reconciled member resumes its existing workload after its own gate passes.
- The live SMB 3.1.1 `/mnt/data` mount uses `cache=none`. The policy applies to all five clients and every other `/mnt/data` consumer; it is an active containment measure, not a Sonarr override or a demonstrated kernel repair.
- The recorded 2026-08-17 oops occurred at 19:05 under `cache=strict`; fstab changed at 20:01 and the 20:16 reboot created the first live `cache=none` mount.
- Local incomplete storage is not currently capacity-safe for the fleet. A future layout change belongs in shared policy and requires capacity plus all-five migration and rollback design.

Boot follows two explicit dependency edges. `mnt-data.mount` and `mnt-plex.mount` require and follow `nas-network-online.service`, which waits for a NAS route and TCP port 445. Docker wants and follows all five Proton WireGuard units. `Wants=` provides ordering and activation attempts, not a guarantee of tunnel health, so the host kill switch and final runtime verification remain mandatory.

Kernel package numbers are not part of the fleet contract. The following package observations are retained from the August 2026 investigation and require fresh verification before a kernel change. Ubuntu `7.0.0-30.30` has no relevant netfs correction, `7.0.0-31.31` remains proposed-only, and the related Linux 7.1.8/7.2 repairs have not been proven on this workload. A replacement kernel must retain a rollback path and pass the storage gate plus all-five runtime and workload validation.

## Canonical instance catalog

The machine-readable source is `qbittorrent-instances.tsv`. The installed copy is `/opt/qbittorrent-common/qbittorrent-instances.tsv`.

| Instance | Web UI | Legacy port reference | Tunnel bind IP | Interface | Address subnet | Route table | qB rule priority |
| --- | ---: | ---: | --- | --- | ---: | ---: | ---: |
| `lidarr` | 8081 | 51058 | 10.2.0.2 | `pvlidarr` | 2 | 51802 | 112 |
| `prowlarr` | 8082 | 51057 | 10.6.0.2 | `pvprowlarr` | 6 | 51806 | 116 |
| `radarr` | 8083 | 51056 | 10.3.0.2 | `pvradarr` | 3 | 51803 | 113 |
| `sonarr` | 8084 | 51055 | 10.4.0.2 | `pvsonarr` | 4 | 51804 | 114 |
| `whisparr` | 8085 | 51054 | 10.5.0.2 | `pvwhisparr` | 5 | 51805 | 115 |

The legacy port column records the pre-migration static values for incident comparison only. The wrappers do not use them as fallbacks. Compose refuses to render unless the synchronizer explicitly injects the current `QBT_PUBLISHED_PORT`; after boot or reconnect, only a successful NAT-PMP lease is authoritative.

## Sources of truth

### Shared static service policy

Repository source:

```text
qbittorrent-compose.common.yml
```

Installed file:

```text
/opt/qbittorrent-common/docker-compose.common.yml
```

It controls every setting that should be identical across the fleet:

- image and tag;
- UID, GID, umask, and timezone;
- s6 shutdown grace settings;
- Docker stop grace period;
- `/mnt/data:/data` mount;
- health-check command, timing, and thresholds;
- restart policy;
- external Docker network attachment.

Each instance's `docker-compose.yml` extends this service. A wrapper is prohibited from duplicating or overriding these fields unless the fleet architecture document and manifest explicitly classify the field as instance-specific.

### Static project environment

Each file `/opt/qbittorrent-<instance>/.env` contains exactly one assignment:

```dotenv
QBT_HOST_BIND_IP=10.<instance-subnet>.0.2
```

It must not contain:

- `QBT_PUBLISHED_PORT`;
- `QBT_FORWARDED_PORT`;
- a qBittorrent credential;
- a Proton lease;
- a runtime state path.

Comments are permitted. A second assignment is a fleet-verification failure.

### Live Proton lease

The volatile lease for an instance is:

```text
/run/proton/<instance>/proton-port.state
```

Its relevant values are:

```dotenv
CURRENT_PORT=<active NAT-PMP port>
CURRENT_IP=<active tunnel address>
LEASE_EXPIRES_AT=<unix-expiry-seconds>
LEASE_BOOT_ID=<current-kernel-boot-id>
LEASE_GENERATION=<current-tunnel-generation>
PORT_CHANGED_AT=<unix-seconds-of-last-port-or-address-change>
```

`/run` is not persistent. An old persistent artifact must not be treated as a renewed lease after reboot. The port-forward service must obtain or refresh NAT-PMP state first.

Both protocol requests must succeed on the same port. The mode-0600 state is
published by atomic rename, with expiry bounded by the shorter granted lifetime
and measured from the start of the request pair. Consumers validate expiry,
boot, tunnel address, and the sibling `tunnel-generation` before accepting it.
The writer holds the per-instance lifecycle lock before the NAT-PMP lock;
teardown cannot change the generation during publication. Producer exit leaves
valid state to expire rather than deleting another writer's lease.

Renewal is scheduled from attempt start and reserves request and lock time.
A single bounded asynchronous sync child cannot delay subsequent renewals.
An unchanged renewal re-runs the sync only at the drift interval; a port change
or failed sync is synced on the next renewal.
Allocation uses one overall deadline and verifies an active producer and fresh
lease after queued startup. The timing defaults, migration requirements, and
source-only deployment status are maintained in the
[port synchronization runbook](../runbooks/qbittorrent-port-sync.md#renewal-and-allocation-budgets).

### Last successfully applied Docker port

The persistent per-instance artifact is:

```text
/etc/proton/instances/<instance>/qbittorrent-port.env
```

It contains exactly:

```dotenv
QBT_PUBLISHED_PORT=<last successfully applied port>
```

The optional managed comment does not count as an assignment. `QBT_FORWARDED_PORT` is obsolete and prohibited.

The artifact is not automatically loaded as the project `.env`. The synchronizer reads it for comparison and injects the active `QBT_PUBLISHED_PORT` into the specific `docker compose` process. This preserves the project `.env` as a one-key static file.

### qBittorrent application value

qBittorrent's application-level listen port is its Web API `listen_port` preference and its persisted `Session\Port`. Random port selection is disabled by the synchronizer.

### Docker runtime value

The active container must satisfy all of these simultaneously:

```text
container TORRENTING_PORT
= TCP target and published host port
= UDP target and published host port
= QBT_PUBLISHED_PORT
= CURRENT_PORT
= qBittorrent listen_port
```

TCP and UDP deliberately use the same number. Those two protocol mappings are not duplicate environment values.

## Port synchronization transaction

```text
Proton NAT-PMP response
  │
  ├─ validate 1..65535
  ├─ write /run/proton/<instance>/proton-port.state
  └─ invoke proton-qbittorrent-sync-safe.sh <instance>
       │
      ├─ acquire per-instance qB sync lock
      │    normal sync: skip if busy
      │    forced fleet sync: wait, then fail on timeout
       ├─ read CURRENT_PORT
       ├─ validate protected qB environment
       ├─ refuse project .env as QBT_PORT_ENV_FILE
      ├─ inspect container for manual stop, zombie, and persistent D state
       ├─ authenticate to the instance Web API
       ├─ disable random port and set listen_port
       ├─ atomically write one-key persistent artifact
       ├─ QBT_PUBLISHED_PORT=<active> docker compose up --force-recreate
       ├─ wait for the instance Web UI
       ├─ verify qBittorrent listen_port
       ├─ verify Docker TCP mapping
       ├─ verify Docker UDP mapping
       └─ record the port in the diagnostic qbt-port.cache only after success
```

On a failed port-changing recreation, the script attempts to restore the previous published artifact and service port. A forced same-port structural recreation has no different port to restore. It must never substitute another instance's port.

## Two kinds of synchronization

### Per-instance runtime synchronization

A Proton lease belongs to one tunnel address. When the lease for Sonarr changes, only `qbittorrent-sonarr` is recreated. Recreating the unrelated four clients would introduce avoidable downtime and CIFS load, and copying Sonarr's port to them would violate Proton's independent NAT-PMP sessions.

This rule is tested and documented as:

```text
one lease change -> one matching qBittorrent recreation
```

### Fleet-wide structural synchronization

A shared image, health check, s6 setting, stop policy, volume policy, init hook, security setting, or shared qBittorrent behavior change applies to all five.

The required workflow is:

```text
edit shared source once
  -> deploy shared source
  -> static parity verification
  -> protected-config preflight
      -> refuse if any member is unhealthy/zombie/persistent-D-state
  -> rolling recreation of all five
  -> per-instance health gate
  -> full runtime parity verification
```

Fleet consistency does not require simultaneous restarts. Sequential, health-gated recreation is safer and is the canonical method.

## Allowed instance differences

Only the following categories are intrinsically per-instance:

- instance/service/container/project name;
- Web UI port;
- legacy port reference in the manifest (never an automatic Compose fallback);
- tunnel subnet and bind IP;
- WireGuard interface and identity;
- NAT-PMP gateway derived from the subnet;
- route table and qBittorrent source-rule priority;
- runtime and persistent state paths;
- qBittorrent credentials;
- category, tag, save path, and workload-specific automation;
- the current Proton lease;
- instance-local config volume.

Any new exception must be added to the manifest or documented as an explicit preference override. “This instance happened to be edited manually” is not an acceptable exception.

## Fleet-controlled qBittorrent preferences

Whole `qBittorrent.conf` files must never be copied between instances. They contain legitimate per-instance paths, Web UI ports, credentials, categories, tags, and live ports.

Shared preferences should instead be managed as a declared key list. During the 2026-08-14 audit, these unexplained differences were found and remain follow-up maintenance work:

- Sonarr `ConnectionSpeed=200`; four-instance baseline `150`.
- Sonarr `FilePoolSize=0`; four-instance baseline `5000`.
- Sonarr `RequestQueueSize=1410065407`; four-instance baseline `2000`.
- Sonarr Web UI UPnP differed from the other four.
- Radarr had an additional-tracker URL not present elsewhere.
- Lidarr had excluded-file filtering not present elsewhere.
- AutoRun behavior differed by workload.

Do not automatically normalize these by copying files. Classify each preference as fleet-controlled or an explicit role override, apply it through a declarative API/config reconciler, and validate the result on all five.

## Routing concurrency model

### Shared route lock

All policy-route mutation uses:

```text
/run/proton/policy-routing.lock
```

It is global and must not derive from per-instance `STATE_DIR`. It covers:

- WireGuard route injection;
- WireGuard route cleanup;
- Docker watcher route reconciliation;
- related raw/mangle rule changes and route-state persistence.

WireGuard setup and teardown treat lock timeout as fatal before route mutation. The long-running watcher logs and skips one reconciliation if it cannot acquire the lock; it remains alive for the next event.

The per-instance `lifecycle.lock` precedes the global route lock. Watcher address
snapshots are collected before taking the route lock; WireGuard boot paths do not
query Docker until its daemon is active. A configured Docker network must supply
the watcher's container address: another attached network is not a substitute.
Missing required IPv4 or IPv6 snapshots refuse reconciliation before mutation.

Reconciliation restores the instance table's default routes before owner source
rules. Rule replacement removes exact duplicates; only an explicit absent-rule
response is treated as idempotent success. Permission and other netlink errors
propagate. Cache files are individually written by mode-0600 temporary file and
rename after route work succeeds; they are not a multi-file transaction or proof
of current kernel state. Reconciliation reasserts routes even when caches match.

Per-instance teardown removes only rules referring to that instance's table or
interface. It leaves shared main-table destination/local/LAN rules and legacy
singleton rules untouched. Old shared rules require a separately reviewed fleet
migration, not deletion during one member's start or stop. Failed teardown keeps
address caches available for retry and reports failure rather than claiming the
interface stopped. A successful WireGuard interface query must establish absence
before repeated teardown skips `wg-quick down`.

### Repeatable tunnel lifecycle

Bring-up stages and validates a replacement config without overwriting the active
runtime config. An unchanged config, existing generation, and recent handshake
keep the current tunnel and lease while routes are reconciled. Otherwise, the old
runtime config is used for teardown before the new config is promoted. Explicit
force reconnect bypasses the keep decision.

A changed start publishes a generation only after route injection and expected
IPv4 address validation. Failure or TERM/INT after mutation invokes bounded
instance teardown while retaining the lifecycle lock, preventing a new producer
or watcher from racing cleanup. SIGKILL and kernel-blocked tasks cannot guarantee
trap cleanup; generation validation, kill-switch enforcement, and subsequent
reconciliation remain necessary. Lock ownership is descriptor-based and no lock
path is unlinked to recover it.

Health recovery bounds sync and NAT-PMP child commands and queues full restarts
with `systemctl --no-block`. The healthcheck follows both WireGuard and producer
restarts through `PartOf=`. A queued restart is not proof of completed recovery.

Source status, 2026-09-11: these routing/lifecycle changes are tested in isolated
fixtures but have not been installed or validated against live host routing.
Final deployment gates remain separate work.

### Shared kill-switch lock

Both nftables and iptables backends use:

```text
/run/proton/killswitch.lock
```

The rulesets are host-wide, so per-instance kill-switch locks would not provide
mutual exclusion. The same lock covers legacy DNAT refresh/cleanup, maintenance
reset, and raw return-path/MSS-clamp changes. Lock waits are bounded; failure
does not authorize mutation or lock-file deletion.

When locks are nested, the order is instance lifecycle, global policy route,
then global firewall. Raw/mangle helpers may take the firewall lock under the
route lock; they do not call routing or selector code. Full kill-switch applies
run outside the route critical section. Legacy DNAT resolves Docker state before
taking the firewall lock and does not recursively invoke the cleanup executable
while holding it. Raw-rule reconciliation restores the exact ACCEPT rule ahead
of Docker drops; unexpected inspection/deletion/insertion errors propagate.

Both backends cover `pvlidarr`, `pvprowlarr`, `pvradarr`, `pvsonarr`, and
`pvwhisparr`, plus an explicitly configured legacy interface. They do not discover
or authorize unrelated WireGuard interfaces. Empty or separator-only Docker CIDR
scope is a failure. Bring-up requires a successful kill-switch apply before
tunnel mutation, including a healthy repeated start. A watcher firewall failure
does not queue allocation for that attempt.

The nft backend replaces its `inet proton` filter table and its exact-comment
masquerade rules in one transaction. Shared NAT tables and foreign rules remain.
The iptables backend validates an `iptables-restore --noflush` batch before apply;
it replaces owned chains under the lock, with one commit per table, not a
cross-table transaction. Raw/mangle changes are serialized command sequences,
not atomic with route updates or the full firewall apply. Docker and unrelated
administrators do not participate in this project lock.

Legacy DNAT uses the owning VPN interface, destination port, and exact
`qbt-dnat-<instance>` comment. TCP/UDP replacement is one nft transaction, so
equal numeric ports on different tunnels remain isolated. Cleanup deletes only
handles with that exact comment. A successful table/chain snapshot establishes
absence; a failed read is never interpreted as absence. The manual kill-switch
reset removes Proton filter protection and owned masquerade rules, but preserves
shared NAT tables, DNAT, unrelated rules, and host default policies. It is still
a disruptive fleet operation requiring separate authorization, not routine
per-instance recovery.

### Shared selector state

All selector commands serialize through `/run/proton/server-select.lock`, with
a bounded wait. Profile claims are published before selection files; the old
claim is released only after publication and only when owned by the selecting
instance. Profiles remain exclusive, but shared endpoints and equal numeric
ports are allowed. Active selection snapshots also exclude another instance's
profile after its ephemeral claim expires.

State files use same-directory temporary files and rename. Read/write failures
are reported, not treated as empty state or successful publication. Interrupted
publication retains the prior selection; a conservative new reservation may
remain until retry or claim expiry. This is not a multi-file transaction. Failed
promotion to capable state retains the quarantine record. Repeated failures of
an unproven profile quarantine it without deleting pool configuration; transient
failures of proven profiles trigger cooldown instead. Trappable exits remove
owned temporary files; SIGKILL cannot guarantee temporary-file cleanup.

Source status, 2026-09-11: selector and firewall changes passed fixture tests and
real nft/iptables apply, repeatability, all-five concurrency, and reset tests in
disposable unprivileged network namespaces. These tests did not change host
networking. No installation, live traffic/leak test, or systemd activation was
performed. The shared instance helper must be deployed with its callers; the
legacy IPv6 copy/rollback bundle and parity preflight now include it.

### Per-instance locks

The following remain isolated by instance:

- recovery lock;
- qBittorrent sync lock;
- allocator coalescing lock;
- state files and caches.

An allocator for Lidarr must not block Prowlarr merely because both need reconciliation; their Proton gateways and leases are independent.

Ordinary lease-driven synchronization takes its per-instance lock non-blocking and may skip because the long-running port-forward loop will retry. A forced fleet recreation waits up to `QBT_SYNC_LOCK_WAIT_SECONDS` and exits nonzero on timeout. It must never report a skipped instance as a successful structural rollout.

## Failure boundaries

### Normal application failure

If the Web UI is unavailable but processes are killable and the container is not manually stopped, one guarded recreation may be attempted.

### Docker/runtime wedge

If the named container remains running with no published ports or contains a zombie, normal self-heal is refused to prevent orphan/name-conflict loops. Missing port metadata alone does not prove a kernel wedge: an authorized forced fleet reconciliation may repair it after lifecycle safety checks. Zombie and persistent same-LWP `D`-state refusals still apply.

### Kernel I/O wedge

Transient `D` state can occur during ordinary CIFS I/O. Automation samples LWP IDs and refuses recreation only when the same task remains uninterruptible across the configured samples. Persistent `D` state, especially with `folio_wait_bit_common` and a netfs/CIFS kernel trace, makes the host kernel the recovery boundary. Automation must not keep issuing Compose, Docker remove, cgroup kill, shim kill, or signal operations.

## Verification layers

### Static layer

```bash
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only
```

This verifies the shared policy, wrappers, one-key project `.env` files, Compose resolution, and identical init hooks.

### Protected configuration layer

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config
```

This additionally validates each root-owned Proton/qBittorrent env and one-key persistent artifact.

### Runtime layer

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

This additionally requires runtime state, tunnel IP, container environment, qBittorrent persisted port, authenticated API listen port, exact TCP mapping, exact UDP mapping, container source policy rule, running state, and healthy state to agree.

### Fleet structural rollout

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The reconciler preflights the entire fleet before changing the first member, refuses unhealthy/zombie/persistent-`D`-state baselines, waits for forced per-instance sync locks, recreates sequentially, stops at the first failed health gate, and runs final runtime verification itself.

## Security invariants

- No torrent port may bind to `0.0.0.0`; it binds to the instance tunnel IP.
- The Web UI publication remains separate from the torrent bind address.
- Protected credentials and instance env files remain root-owned mode `0600`.
- Dynamic port artifacts remain root-owned mode `0600`.
- Systemd executes installed programs under `/usr/local/bin/proton`, never a writable development checkout.
- Docker application egress remains subject to the host kill-switch.
- A configuration verifier must not print credentials.

## Archive status

`/archive` was absent when this contract was written. No architectural conclusion here depends on an archived implementation.
