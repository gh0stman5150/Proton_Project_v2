# Incident: shared Docker Proton fallback route churn

## Document status

- Incident date: 2026-09-13
- Host timezone: America/Chicago (CDT, UTC-05:00)
- Primary affected services: `prowlarr`, `qui`
- Potential scope: every container attached to `starr_network`
- Docker network: `starr_network`, IPv4 `192.168.96.0/20`
- Severity: intermittent external DNS and TLS failure across application containers
- Root-cause status: confirmed by live routing, journal, container, and application evidence
- Source resolution: implemented and validated in the canonical repository on 2026-09-13
- Production activation: pending interactive administrator deployment as of 2026-09-13 15:57 CDT
- Archive comparison: `/archive` was absent; no archive-based behavior comparison was possible

Do not treat this record as proof that the live host is repaired until the
post-deployment acceptance checks below are completed and this status is
updated with dated results.

## Executive summary

Prowlarr reported DNS/SSL-style indexer failures while Qui independently timed
out during a TLS handshake. The names resolved correctly and direct HTTPS
requests sometimes succeeded, but repeated requests from a container changed
between Proton public egress addresses. Fresh Prowlarr tests reproduced
connection resets, timeouts, and incomplete HTTP/2 handshakes.

All five Proton instance watchers installed a lower-priority policy rule for
the complete `192.168.96.0/20` Docker subnet. Each rule had priority `130`, but
each pointed to a different per-instance VPN routing table. The watchers
regularly deleted and re-added their own rules while reconciling Docker state.
Consequently, the first matching priority-130 rule changed among tables 51802
through 51806. Ordinary containers such as Prowlarr and Qui changed Proton
tunnels while connections were active. The resulting path and public-source
address changes invalidated TLS sessions and produced the misleading generic
Prowlarr DNS/SSL message.

The correction retains the required policy that all Docker application traffic
uses Proton. Exactly one instance now owns the IPv4 subnet fallback rule,
matching the existing single-owner IPv6 design. The default owner is Sonarr,
whose VPN table is 51804. Every qBittorrent container retains its higher-
priority `/32` source rule to its own independent Proton tunnel.

## User-visible symptoms

Prowlarr displayed:

```text
Unable to connect to indexer. This is typically caused by DNS/SSL issues.
An error occurred while sending the request.
```

Its logs contained several transport variants:

```text
System.Net.Sockets.SocketException (104): Connection reset by peer
An HTTP/2 connection could not be established because the server did not
complete the HTTP/2 handshake. (InvalidResponse)
Http request timed out
```

Qui logged this independent failure in the same incident window:

```text
2026-09-13T14:51:13-05:00
component=update
error checking new release
Get https://api.autobrr.com/repos/autobrr/qui/releases/latest:
net/http: TLS handshake timeout
```

Prowlarr also accumulated disabled-indexer and long-term-indexer warnings.
Some remaining HTTP 404, HTTP 429, authentication, rate-limit, or genuinely
unavailable-indexer errors are separate from this transport incident and must
not be declared fixed solely by repairing routing.

## Impact and scope

- Prowlarr could not reliably query or test unrelated indexers.
- Qui could not reliably reach its update service.
- Any long-lived external TCP/TLS connection from `starr_network` could reset
  or time out when fallback-rule ownership changed.
- Docker's embedded resolver intermittently timed out while forwarding selected
  queries to the host resolver.
- qBittorrent's higher-priority per-container routes remained distinct, but the
  shared fallback implementation made ordinary Docker application egress
  unstable.

Prowlarr and Qui were both healthy at the container level. Container health did
not establish external route stability.

## Timeline

- 2026-09-13 00:50:51 CDT (05:50:51 UTC): the current Prowlarr and Qui
  containers started on `starr_network`; both later remained Docker-healthy.
- Around 14:50 CDT: Prowlarr recorded failures across multiple unrelated
  indexers, including endpoints behind different providers.
- 14:51:13 CDT: Qui recorded a TLS handshake timeout reaching
  `api.autobrr.com`.
- 14:54-15:00 CDT: Qui received Prowlarr errors and rate-limit responses for
  several searches while Prowlarr's indexer status accumulated failures.
- 15:03-15:04 CDT: the host journal recorded repeated Docker external-DNS
  forwarding timeouts while Proton route and kill-switch reconciliation was
  active.
- 15:11-15:36 CDT: Prowlarr continued logging TLS resets against unrelated
  indexers, including NZB and torrent endpoints.
- 15:41 CDT: container inspection confirmed correct A and AAAA answers; Docker
  IPv6 was disabled; forced IPv4 certificate verification succeeded
  intermittently.
- 15:43-15:45 CDT: Prowlarr's built-in test-all operation reproduced fresh TLS
  resets, timeouts, resource-unavailable errors, and HTTP/2 handshake failures.
- 15:45 CDT: repeated route-order and egress sampling confirmed that the first
  priority-130 VPN table changed and that Prowlarr used more than one public
  Proton egress address during eight requests. The sample itself produced one
  TLS reset and one connection timeout.
- 15:57 CDT: the single-owner source correction had passed the complete source
  validation suite. Production installation remained blocked on interactive
  administrator authentication.

## Evidence

### DNS and protocol checks

Inside Prowlarr, `/etc/resolv.conf` correctly used Docker's embedded resolver:

```text
nameserver 127.0.0.11
search lan
options edns0 trust-ad ndots:0
```

The resolver returned valid IPv4 and IPv6 records for multiple failing names.
The Docker network had `EnableIPv6=false`, so the application used IPv4.
HTTPS probes negotiated HTTP/2 with successful certificate verification when
the selected path remained usable. Prowlarr had no generic HTTP proxy; its only
indexer proxy definition was a tagged FlareSolverr helper.

These checks ruled out an NXDOMAIN condition, missing CA trust, and broken
container IPv6 as the common cause. They did not imply a healthy route because
the route could change immediately after a successful request.

### Correlated host activity

During the 14:45-15:05 CDT incident sample, the host journal contained:

```text
policy route reapplications:    733
kill-switch reapplications:     100
Docker external DNS timeouts:    28
```

The watcher messages repeatedly stated that Docker policy routing was being
applied for each qBittorrent role on the same `192.168.96.0/20` source subnet.

### Conflicting policy rules

The live routing policy contained five rules with the same source and priority:

```text
130: from 192.168.96.0/20 lookup 51802
130: from 192.168.96.0/20 lookup 51803
130: from 192.168.96.0/20 lookup 51804
130: from 192.168.96.0/20 lookup 51805
130: from 192.168.96.0/20 lookup 51806
```

Each table had a usable default through a different interface:

| Table | Proton interface | Dedicated qBittorrent role |
| ---: | --- | --- |
| 51802 | `pvlidarr` | Lidarr |
| 51803 | `pvradarr` | Radarr |
| 51804 | `pvsonarr` | Sonarr |
| 51805 | `pvwhisparr` | Whisparr |
| 51806 | `pvprowlarr` | Prowlarr |

Eight one-second route samples observed this leading-table sequence:

```text
51802, 51802, 51802, 51804, 51803, 51806, 51806, 51806
```

The other same-priority entries also reordered. Because every table supplied a
default route, the first entry selected the tunnel for non-qBittorrent Docker
traffic. Reconciliation changed that selection while connections were active.

### Container identities

At diagnosis time:

```text
prowlarr              192.168.96.23
qui                   192.168.96.4
qbittorrent-prowlarr  192.168.96.11
```

Prowlarr and Qui did not match a qBittorrent-specific `/32` rule, so they fell
through to the unstable priority-130 subnet rules.

## Root cause

### Confirmed cause

`DOCKER_FALLBACK_VPN_ROUTING` defaulted to `on`. Both
`proton-wg-up-safe.sh` and `proton-docker-network-watcher.sh` treated every
instance as an IPv4 fallback owner. For each instance they added:

```text
from 192.168.96.0/20 lookup <that instance VPN table> priority 130
```

The global route lock prevented simultaneous mutation corruption, but it did
not solve semantic multi-ownership. Serially deleting and re-adding five
equally preferred defaults still reordered the route policy and changed the
selected tunnel.

### Why the message looked like DNS or SSL

Prowlarr uses a generic message for failures below the indexer protocol layer.
DNS resolution completed successfully in many failing requests. The actual
exceptions occurred during TLS reads, HTTP/2 setup, or response transfer after
the route or public egress identity changed.

Docker did record some true upstream DNS-forwarding timeouts. They were part of
the same unstable container networking period, not evidence that the indexer
records or configured resolver addresses were wrong.

### Excluded common causes

- DNS names resolved to valid addresses from the affected container.
- Docker IPv6 was disabled, eliminating a broken IPv6 route as the shared path.
- TLS certificate verification succeeded during stable samples.
- Prowlarr and Qui had no environment HTTP/HTTPS proxy.
- Prowlarr's application and Docker health checks passed.
- The failure affected unrelated endpoints simultaneously and therefore was
  not explained by one indexer's DNS, certificate, or availability.

## Corrective design

The repository now defines:

```dotenv
DOCKER_FALLBACK_VPN_ROUTING=on
DOCKER_FALLBACK_INSTANCE=sonarr
```

The behavior is:

1. Every instance removes stale priority-130 rules that point to its own table.
2. Only `DOCKER_FALLBACK_INSTANCE` adds the IPv4 subnet-wide fallback rule.
3. Sonarr is the default stable fallback owner, matching
   `DOCKER_IPV6_FALLBACK_INSTANCE=sonarr`.
4. Each qBittorrent container continues to receive a higher-priority `/32`
   source rule for its own table and tunnel.
5. Docker-to-Docker and Docker-to-LAN exceptions remain on the main table at
   their existing higher priorities.
6. The kill switch continues to constrain Docker WAN traffic to managed Proton
   interfaces. A missing fallback owner is intended to fail closed rather than
   send Docker application traffic directly to the WAN.

This keeps all containers behind Proton without moving established application
connections among five different public egress identities.

## Source changes

The canonical change updates:

- `proton-common.env`: declares the stable IPv4 fallback owner.
- `proton-docker-network-watcher.sh`: limits IPv4 fallback insertion to that
  owner while retaining per-qBittorrent reconciliation.
- `proton-wg-up-safe.sh`: applies the same ownership rule during initial tunnel
  bring-up and logs owner versus non-owner behavior.
- `install-proton-systemd.sh`: includes the owner in generated instance examples.
- `tests/proton-docker-network-watcher.bats`: proves owner and non-owner watcher
  behavior.
- `tests/proton-wg-up.bats`: proves owner and non-owner startup behavior.
- `README.md`: documents stable IPv4 and IPv6 fallback ownership.

No Prowlarr, Qui, indexer, Docker DNS, or IPv6 configuration was changed.

## Source validation

The following completed successfully on 2026-09-13:

- complete Bats suite: 199 tests passed;
- ShellCheck over root, tool, and archive shell scripts;
- shfmt difference check;
- Bash syntax validation;
- `git diff --check`;
- installed static qBittorrent fleet verifier: all five contracts passed.

The privileged `--config` and `--runtime` verifier modes could not run because
the session had no passwordless administrator credential. This was an access
limitation, not a passing production result.

## Deployment procedure

Deployment briefly restarts the Proton service chains and requires an operator
to authenticate directly with `sudo`. From the canonical repository:

```bash
cd /usr/local/bin/proton_project
sudo ./install-proton-systemd.sh &&
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config &&
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

Do not report the incident resolved merely because the installer copied files.
The live acceptance checks below are required.

## Post-deployment acceptance

Record dated output or a concise result for every check:

1. Exactly one priority-130 IPv4 fallback exists:

   ```bash
   ip -4 rule show | awk '$1 == "130:"'
   ```

   With the default owner, the expected rule is:

   ```text
   130: from 192.168.96.0/20 lookup 51804
   ```

2. All five higher-priority qBittorrent `/32` rules still point to their own
   route tables.
3. Repeated one-second samples leave table 51804 as the sole fallback owner.
4. Repeated Prowlarr HTTPS requests use one public Proton egress address; do not
   publish the address in incident notes.
5. Prowlarr's built-in indexer test no longer produces route-related TLS resets,
   handshake timeouts, or HTTP/2 setup failures.
6. Qui reaches `https://api.autobrr.com/repos/autobrr/qui/releases/latest`
   without a TLS timeout.
7. Docker logs no new external-resolver timeouts attributable to route churn.
8. All five WireGuard, port-forward, watcher, healthcheck, and qBittorrent
   instance chains are healthy.
9. Both privileged fleet verifier modes pass.
10. Existing indexer 404, 429, authentication, or site-availability failures are
    triaged separately.

## Rollback

If activation breaks routing:

1. Stop the rollout and preserve the installer output and current `ip rule`,
   route-table, WireGuard, nftables, and unit-status evidence without printing
   protected configuration.
2. Follow the fleet change runbook and restore the installer-created backup or
   revert the canonical source change, then reinstall the complete matching
   bundle. Do not patch only one installed instance script.
3. Re-run protected-config and runtime fleet verification.

Rolling back this change restores the known multi-owner route-churn defect. It
is an emergency restoration action, not a stable long-term configuration.

## Remaining risks and follow-up

- Sonarr becomes the availability dependency for ordinary Docker application
  egress. Its tunnel must be health-monitored and fail closed if unavailable.
- Automatic transfer of fallback ownership is not implemented. Adding it later
  requires an atomic, health-gated owner-election design; multiple concurrent
  owners must remain prohibited.
- Indexer-specific rate limits, authentication failures, Cloudflare challenges,
  and site outages remain possible after transport stability is restored.
- Live closure evidence is still required after privileged deployment.

Use the shared fleet change runbook for activation and rollback. Update this
incident record with the deployment time, exact acceptance results, and final
recovery status after live validation.
