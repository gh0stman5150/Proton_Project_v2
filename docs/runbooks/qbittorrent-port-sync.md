# Runbook: qBittorrent and Proton port synchronization

## Objective

For every managed instance, prove that the active Proton NAT-PMP lease, qBittorrent listen port, persistent port artifact, Docker container environment, and both Docker protocol mappings are identical—while keeping the five instances isolated from one another.

## Scope

This runbook applies to:

```text
lidarr prowlarr radarr sonarr whisparr
```

Run commands from the host. Root access is required for files under `/etc/proton` and `/run/proton`.

## Host readiness and availability

Port parity is not sufficient if storage or boot ordering is wrong:

- `mnt-data.mount` and `mnt-plex.mount` require and follow `nas-network-online.service`, which waits for both NAS routing and TCP port 445.
- Docker wants and follows all five `proton-wg@<instance>.service` units. This orders activation attempts but does not replace tunnel-health checks or the host kill switch.
- The live `/mnt/data` mount uses SMB 3.1.1 with `cache=none`. This is the active shared containment policy, not a port-sync setting or a demonstrated kernel fix.
- After reboot, verify the leaf mount, all five tunnels, Docker, and full runtime parity before accepting the fleet.

A lease change recreates only its owning qBittorrent client, so the other four continue downloading, uploading, and seeding. A shared structural change uses the sequential fleet reconciler for the same reason. Do not globally pause torrents or add active-upload, seeding, or queueing limits as part of port synchronization.

## Non-negotiable state model

### Static project `.env`

Path:

```text
/opt/qbittorrent-<instance>/.env
```

Exactly one assignment is allowed:

```dotenv
QBT_HOST_BIND_IP=10.<subnet>.0.2
```

This file is read automatically by Docker Compose. It does not store a port.

### Live Proton lease

Path:

```text
/run/proton/<instance>/proton-port.state
```

Expected data:

```dotenv
CURRENT_PORT=<active-port>
CURRENT_IP=<tunnel-ip>
LEASE_EXPIRES_AT=<unix-expiry-seconds>
LEASE_BOOT_ID=<current-kernel-boot-id>
LEASE_GENERATION=<current-tunnel-generation>
PORT_CHANGED_AT=<unix-seconds-of-last-port-or-address-change>
```

The writer publishes this file atomically with mode `0600` only after successful
UDP and TCP mappings return the same valid port. Expiry is measured conservatively
from the start of the request pair using the shortest of the requested and both
granted lifetimes. Missing, malformed, expired, wrong-address, wrong-boot, or
wrong-generation leases are not usable. The generation must match the sibling
`tunnel-generation` file created by successful WireGuard bring-up.

Publication takes the per-instance `lifecycle.lock` followed by `natpmp.lock`,
with bounded waits, so teardown and other writers cannot overlap publication.
Stopping just the producer leaves an unexpired lease to age out; its exit trap
must not delete a newer one-shot writer's state. Tunnel teardown invalidates the
lease and generation. A lock pathname is never removed to release a lock.

Source status, 2026-09-11: these lease changes have not been installed or live
validated as part of this work. Existing two-field state is rejected. Deployment
requires separately authorized sequential activation and verification across all
five instances; a running legacy tunnel needs a generation from the updated
lifecycle before the updated producer can publish. Do not manufacture generation
files or copy another instance's lease to bypass this gate.

### Renewal and allocation budgets

`CHECK_INTERVAL` is a maximum start-to-start renewal interval, not a sleep after
all work. With the defaults (60-second lease, two 15-second NAT-PMP limits,
two 2-second termination allowances, two 5-second lock waits, and a 5-second
margin), the next attempt is due no later than 11 seconds after the previous
attempt started. Work time is subtracted from that delay; a shorter granted
lifetime can bring renewal forward further. Expired state is rejected even if
renewal or host scheduling fails to meet the budget.

The loop keeps at most one sync child running. Sync has a default 120-second
limit (`QBT_SYNC_TIMEOUT_SECONDS`) plus a 2-second forced-termination allowance;
slow recreation does not block lease renewal. Loop shutdown signals its owned
sync process group through the timeout monitor. These deadlines cannot repair
kernel-blocked tasks and do not override the host recovery boundary.

The allocator queues `systemctl --no-block start` and requires both an active
producer and a fresh lease before syncing. Lock acquisition, startup, polling,
diagnostics, and sync share `ALLOCATION_TIMEOUT_SECONDS` (default and maximum
150 seconds), below the unit's 180-second start limit. A client timeout or
allocator failure does **not** cancel an already queued systemd job.

### Selector and firewall failures

Selection, profile claims, capability records, strikes, and cooldown changes
share the bounded global selector lock. A failed state read or write aborts the
operation. A profile claim is reserved before publishing a selection; if
publication is interrupted, the old selection remains and the reservation may
persist until retry or expiry. Do not delete lock files or pool configurations
to bypass this condition. Quarantine retains unproven configurations for review;
proven profiles are cooled down after transient port-forward failures.

The global firewall lock covers both backends, raw/MSS changes, legacy DNAT, and
manual reset. A failed firewall read is not proof that a table, chain, or rule is
absent. Bring-up refuses a missing or failed kill switch before tunnel mutation;
the watcher does not queue allocation after failed firewall reconciliation.

In legacy DNAT mode, replacement is an atomic TCP/UDP pair scoped to the owning
VPN interface and exact instance comment. Cleanup removes only that instance's
handles, never a shared NAT table. Equal numeric forwarded ports on different
tunnels are valid. The manual reset utility removes Proton filter protection and
owned masquerade rules, but retains DNAT and host default policies; it is not a
single-instance port-repair command and still needs fleet outage authorization.

Source status, 2026-09-11: fixture and disposable-network-namespace tests passed.
No host firewall, service, or installed script was changed. Deploy the shared
instance helper with the callers, not individual executables copied in isolation.
The separate documentation/deployment gates and all-five live validation remain
required before accepting this behavior on the host.

### Last applied Docker port

Path:

```text
/etc/proton/instances/<instance>/qbittorrent-port.env
```

Exactly one assignment is allowed:

```dotenv
QBT_PUBLISHED_PORT=<last-applied-port>
```

`QBT_FORWARDED_PORT` is obsolete and must not exist. The artifact is persistent evidence of what was last applied; it is not proof that Proton renewed the same lease after reboot.

### Protected instance orchestration config

Path:

```text
/etc/proton/instances/<instance>/qbittorrent.env
```

It defines identity, credentials, Compose project/service, network, apply mode, and artifact path. It must not define either dynamic port key.

## Instance matrix

| Instance | Web UI | Bind IP | Interface | State/artifact namespace |
| --- | ---: | --- | --- | --- |
| Lidarr | 8081 | 10.2.0.2 | `pvlidarr` | `lidarr` |
| Prowlarr | 8082 | 10.6.0.2 | `pvprowlarr` | `prowlarr` |
| Radarr | 8083 | 10.3.0.2 | `pvradarr` | `radarr` |
| Sonarr | 8084 | 10.4.0.2 | `pvsonarr` | `sonarr` |
| Whisparr | 8085 | 10.5.0.2 | `pvwhisparr` | `whisparr` |

## Normal automatic flow

1. `proton-wg@<instance>` establishes that instance's tunnel.
2. `proton-port-forward@<instance>` requests or refreshes a NAT-PMP lease through that instance's derived gateway.
3. The port-forward loop atomically publishes the validated lease and freshness metadata in `/run/proton/<instance>`.
4. It starts at most one bounded `proton-qbittorrent-sync-safe.sh <instance>` child while renewal continues independently.
5. The synchronizer acquires `/run/proton/<instance>/qbt-sync.lock`; ordinary lease sync skips if busy, while forced fleet sync waits and fails on timeout.
6. It rejects invalid ports, expired leases, and state from a different boot, tunnel address, or generation.
7. It rejects `QBT_PORT_ENV_FILE` if it points to the Compose project's static `.env`.
8. It honors an intentional manual stop.
9. It refuses normal Compose work for zombie, no-port, or persistent same-LWP kernel `D`-state wedges after allowing transient CIFS waits to clear.
10. It authenticates to the correct qBittorrent Web API.
11. It disables qBittorrent random-port selection.
12. It applies the active port to qBittorrent.
13. It writes the one-key port artifact atomically using a temporary file, mode `0600`, and rename.
14. It injects `QBT_PUBLISHED_PORT` into the matching Compose process.
15. It stops/recreates only `qbittorrent-<instance>`.
16. It waits for the Web UI.
17. It verifies qBittorrent reports the target port.
18. It verifies Docker publishes the port for both TCP and UDP.
19. It commits the per-instance cache and reports success.

An unchanged lease does not normally recreate the container when the artifact and both Docker mappings match. Stale mappings or an unreachable Web UI can trigger guarded recreation. Forced fleet sync can repair absent port mappings after lifecycle checks, but never bypasses zombie or persistent `D`-state refusal. If the artifact is in the legacy two-key format, the script canonicalizes it to one key without an unnecessary restart.

### Routing and lifecycle recovery

The watcher reconciles routes after Docker events and at the end of each bounded
event window, including recreation performed outside the synchronizer. Its
`--once` path only reconciles routes; it does not recursively invoke allocation.
It requires the configured network's container addresses, restores default and
owner routes, and publishes caches only after routing succeeds. A failed
reconciliation must not queue allocation as though routing were repaired.

Repeated healthy tunnel bring-up retains the lease and generation when the
runtime config matches and the handshake is recent. Changed starts stage the new
config, stop using the previous runtime config, and publish a generation only
after routes and the expected address are established. Failed or interrupted
starts attempt bounded cleanup of that instance. Teardown failure is not success:
retain diagnostics and retry caches, and do not proceed with container recreation.

Per-instance start/stop never deletes shared main-table or legacy singleton
rules. Review any legacy rules as a fleet migration before deployment; do not
remove broad priorities as an ad hoc recovery command. Do not delete lock files.
The detailed ownership and interruption limits are in the
[routing concurrency model](../architecture/qbittorrent-fleet-contract.md#routing-concurrency-model).

Healthcheck recovery uses bounded child calls and nonblocking restart requests
to avoid waiting on its own service group. A producer restart also restarts its
healthcheck. After any authorized restart, verify service completion, fresh
leases, and all-five runtime parity rather than accepting the queued request's
exit status as evidence of recovery. These source changes remain undeployed.

## Preflight

### 1. Verify static fleet shape

```bash
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only
```

Expected result:

```text
Fleet verification passed for all 5 qBittorrent instances.
```

This command must pass before changing a port-sync script, Compose policy, wrapper, project `.env`, or init hook.

### 2. Verify protected configuration

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config
```

This fails if any instance has:

- the wrong identity/path/network/interface/table;
- a project `.env` with more than one assignment;
- a dynamic port in a project `.env`;
- a persistent artifact with more than one assignment;
- the obsolete alias;
- a missing or invalid port;
- a port artifact path that differs from the per-instance path.

### 3. Inspect service state

```bash
for instance in lidarr prowlarr radarr sonarr whisparr; do
  systemctl status "proton-wg@${instance}.service" \
    "proton-port-forward@${instance}.service" \
    "proton-docker-watch@${instance}.service" \
    "proton-healthcheck@${instance}.service" \
    --no-pager -l
done
```

Do not start a forced fleet rollout if one member is already unhealthy. Diagnose it first.

## Manual per-instance synchronization

Use the allocator unit rather than bare Compose:

```bash
sudo systemctl start proton-qbt-allocate@sonarr.service &&
sudo systemctl status proton-qbt-allocate@sonarr.service --no-pager -l
```

Replace `sonarr` with the target instance. The allocator validates the instance name, starts/observes the matching port-forward service, waits for its state file, and invokes the installed sync script.

Direct diagnostic invocation is also possible:

```bash
sudo /usr/local/bin/proton/proton-qbittorrent-sync-safe.sh sonarr
```

Do not run an unqualified `docker compose up` to “fix” a port. The wrappers intentionally refuse to render without an explicitly injected `QBT_PUBLISHED_PORT`; use the allocator/synchronizer so that value comes from the matching live Proton lease.

### Recreating a fleet whose containers were removed

`proton-qbt-fleet-reconcile.sh --recreate` is a rolling replacement command,
not a bootstrap command. It deliberately refuses to start if any managed
container is absent, unhealthy, a zombie, or persistently blocked in kernel
`D` state. Therefore, after all five qBittorrent containers have been removed,
do not retry `--recreate` and do not use `docker run` to create replacements.
There is no supported non-Compose container creation path: the synchronizer
must inject the current per-instance Proton port, configure qBittorrent, clean
stale qBittorrent lock artifacts, and verify the TCP/UDP mappings and health.

Use the installed bootstrap command, which performs this override in a
temporary mode-0600 environment file and does not modify protected instance
configuration:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-recreate.sh --bootstrap
```

The command requires root, validates the protected fleet configuration, starts
or refreshes each instance's Proton port-forward service, and restores the
five containers sequentially through the allocator/synchronizer path. It
temporarily sets `QBT_RESPECT_MANUAL_STOP=0` and `QBT_FORCE_RECREATE=1` only for
the synchronizer invocation; it does not change either protected file.

If the command is not installed yet, install the canonical source first:

```bash
cd /usr/local/bin/proton_project &&
sudo ./install-proton-systemd.sh
```

The bootstrap command requires the same prerequisites as normal port
synchronization: valid per-instance Proton/WireGuard configuration, the
installed Compose wrappers, the external `starr_network`, mounted storage,
and healthy Docker. It stops on the first failed instance; inspect its
port-forward and allocator journal before retrying.

After successful recreation, run the final fleet gate:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

If any instance fails, stop and inspect its port-forward and allocator journal;
do not continue with a partially validated fleet:

```bash
sudo journalctl --no-pager -u "proton-port-forward@${instance}.service" \
  -u "proton-qbt-allocate@${instance}.service" -n 200
```

## Verify one instance manually

The following example uses Sonarr. Substitute the instance matrix values for another client.

### Read state without exposing credentials

```bash
sudo awk -F= '/^(CURRENT_PORT|CURRENT_IP)=/ {print}' \
  /run/proton/sonarr/proton-port.state
sudo awk -F= '/^QBT_PUBLISHED_PORT=/ {print}' \
  /etc/proton/instances/sonarr/qbittorrent-port.env
```

### Confirm artifact schema

```bash
sudo awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ {count++} END {print count+0}' \
  /etc/proton/instances/sonarr/qbittorrent-port.env
```

Expected output is `1`.

```bash
sudo grep -n '^QBT_FORWARDED_PORT=' \
  /etc/proton/instances/sonarr/qbittorrent-port.env
```

Expected: no output and exit status `1`.

### Confirm container environment and bindings

```bash
docker inspect qbittorrent-sonarr --format \
  '{{range .Config.Env}}{{println .}}{{end}}' | grep '^TORRENTING_PORT='

docker inspect qbittorrent-sonarr --format \
  '{{range $port,$items := .HostConfig.PortBindings}}{{range $items}}{{printf "%s %s:%s\n" $port .HostIp .HostPort}}{{end}}{{end}}'
```

Expected:

- `TORRENTING_PORT` equals `CURRENT_PORT`;
- one `<port>/tcp 10.4.0.2:<port>` entry;
- one `<port>/udp 10.4.0.2:<port>` entry;
- no torrent bind on `0.0.0.0`.

### Confirm persisted qBittorrent port

```bash
awk -F= '$1 == "Session\\Port" {print $2}' \
  /opt/qbittorrent-sonarr/config/qBittorrent/qBittorrent.conf
```

The Web API check is stronger because a running qBittorrent may not have flushed every preference to disk yet. For read-only authenticated validation, use the fleet runtime verifier:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

The synchronizer is a mutating operation and can recreate a container; use the manual synchronization procedure only with runtime authorization.

## Verify the complete fleet

After a reboot, reconnect, deployment, or structural rollout:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

This is the acceptance gate. It verifies every instance, not merely the one that was most recently changed.

## Expected behavior on a new Proton port

For an example Sonarr change from `51055` to `54105`:

```text
/run/proton/sonarr/proton-port.state -> CURRENT_PORT=54105
qBittorrent API                    -> listen_port=54105
/etc/proton/.../qbittorrent-port.env -> QBT_PUBLISHED_PORT=54105
Compose process environment        -> QBT_PUBLISHED_PORT=54105
container environment              -> TORRENTING_PORT=54105
Docker host mapping                -> 10.4.0.2:54105 TCP and UDP
```

Only `qbittorrent-sonarr` is recreated. The other four retain their own live ports.

Their uploads and seeding remain active. Do not trade a one-instance lease update for a fleet-wide pause.

## Forced recreation for a shared fleet change

Do not call the per-instance force flag five times manually. Use the health-gated fleet tool:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The tool:

1. validates all protected configuration;
2. refuses before the first change if any member is absent, unhealthy, zombie, or persistently in `D` state across multiple samples;
3. invokes the same synchronizer for each instance with `QBT_FORCE_RECREATE=1`;
4. waits for each per-instance sync lock and fails rather than silently skipping on timeout;
5. preserves each instance's own active port;
6. waits for health before moving to the next instance;
7. runs full runtime verification at the end.

The rolling order preserves availability: four clients remain active while one is reconciled, and the changed client resumes its existing downloads and uploads after its health and port gates pass.

## Failure handling

### No `CURRENT_PORT`

Do not use the persistent artifact as if it were a renewed lease. Inspect the WireGuard and port-forward units:

```bash
sudo systemctl status proton-wg@sonarr.service proton-port-forward@sonarr.service --no-pager -l
sudo journalctl -u proton-wg@sonarr.service -u proton-port-forward@sonarr.service -n 250 --no-pager
```

Repair the tunnel/lease path first.

### `RTNETLINK answers: File exists`

Confirm the installed scripts include the global policy-route lock and match source. Then inspect all instance units; do not fix only the failed instance. Route mutations must be serialized fleet-wide.

### systemd `203/EXEC`

Verify:

```bash
systemctl cat proton-qbt-allocate@.service
stat -c '%a %U:%G %n' /usr/local/bin/proton/proton-qbt-allocate-and-sync.sh
```

Expected:

```text
ExecStart=/usr/local/bin/proton/proton-qbt-allocate-and-sync.sh %i
755 root:root /usr/local/bin/proton/proton-qbt-allocate-and-sync.sh
```

No systemd unit may execute from `/usr/local/bin/proton_project`.

### Web UI unreachable

The synchronizer distinguishes:

- intentional manual stop: skip;
- ordinary running failure: one guarded self-heal;
- running/no published ports: refuse;
- zombie: refuse;
- transient `D` state: sample the LWP and proceed only after it clears;
- persistent same-LWP `D` state: refuse and require host recovery.

Use `docs/runbooks/qbittorrent-wedge-recovery.md` before issuing more Docker commands.

### Compose recreation fails on a busy port

The synchronizer retries only the recognized address-in-use/allocated-port failure. After its configured attempts, it restores the previous artifact and tries to restore the previous service mapping. Investigate the port owner:

```bash
sudo ss -lntup | grep ':<port>'
docker ps -a --format '{{.Names}} {{.Ports}}' | grep ':<port>'
```

Never solve a collision by binding the torrent port to `0.0.0.0`.

## Post-change evidence to retain

For each instance, retain:

- active Proton server/profile;
- interface and tunnel address;
- runtime `CURRENT_PORT` and `CURRENT_IP`;
- persistent `QBT_PUBLISHED_PORT`;
- container health and `TORRENTING_PORT`;
- TCP and UDP host bindings;
- qBittorrent API-reported listen port;
- source policy rule and route table;
- relevant synchronizer journal lines;
- final fleet verifier result.

Do not retain or paste qBittorrent passwords, cookie jars, or WireGuard private keys.
