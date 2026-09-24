# Incident: installer-triggered Docker restarts and policy-rule sweep conflict

## Document status

- Incident date: 2026-09-23
- Host timezone: America/Chicago (CDT, UTC-05:00)
- Affected services: every Docker container on the host (two Docker restarts);
  `qbittorrent-prowlarr` and `qbittorrent-whisparr` (extended outage);
  `mousehole` (egress tunnel); `qbittorrent-whisparr` and later the Sonarr app
  (misrouted through prowlarr's tunnel)
- Docker network: `starr_network`, IPv4 `192.168.96.0/20`
- Root-cause status: confirmed by the systemd journal, Docker container
  timestamps, `ip rule` listings, and source inspection
- Source resolution: commit `9d98932` (installer reload, sweep revert),
  installed 2026-09-23 21:11 and 21:14 CDT
- Live verification: installer reload confirmed at 21:11:22 and 21:14:55 CDT
  with no Docker restart; see [Remaining actions](#remaining-actions) for items
  still open at the time of writing
- Archive comparison: not used; the evidence is from the live journal and
  current source history

## Executive summary

On 2026-09-23 two runs of `install-proton-systemd.sh` each restarted Docker,
stopping every container on the host. The installer ended with
`systemctl restart proton-killswitch.service`. The installer's own
`docker-proton-tunnels.conf` drop-in gives `docker.service`
`Requires=proton-killswitch.service`, and systemd restarts every running unit
that requires a unit being restarted. Each install therefore restarted Docker.
After the second restart, the prowlarr and whisparr qBittorrent containers
stayed exited for about ten minutes. Their port sync treated them as manually
stopped, so they did not recover on their own. The documented bootstrap
restored them.

The second install deployed commit `1ce8ae1`, which deleted every policy rule in
an instance's route table at a priority the instance did not own. Rules `110`
and `117` in prowlarr's table 51806 had been described to the operator as
leftovers, one of them with no known owner. In fact, the separate `mousehole`
project adds both on purpose to route mousehole through prowlarr's tunnel. No
one had looked for rule owners outside this repository. The sweep and
mousehole's route helper then deleted and re-added the same rules repeatedly.
`1ce8ae1` was reverted in `9d98932`.

Rule `110` was also genuinely wrong, for a different reason. It hard-coded
`192.168.96.8`, a Docker-assigned address. Before the second Docker restart
that address belonged to whisparr's qBittorrent, whose traffic therefore left
through prowlarr's tunnel. After the restart it belonged to the Sonarr app. At
the operator's request, the rule was removed from mousehole's configuration.

## Impact and scope

- 19:58:35–20:00:09 CDT: Docker was stopped and restarted. All containers on the
  host restarted, and all five qBittorrent clients returned.
- 20:55:10–20:57:06 CDT: Docker was stopped and restarted again. lidarr, radarr,
  and sonarr returned. prowlarr and whisparr stayed exited until the bootstrap
  recreated them at 21:06:31 and 21:09:27, an outage of about ten and twelve
  minutes.
- While prowlarr's qBittorrent was exited, `proton-docker-watch@prowlarr` failed
  every reconciliation and restarted more than 25 times, and its qBittorrent
  host rule (priority 116) was absent.
- From 20:56:41, the sweep repeatedly removed mousehole's rules `110` and `117`.
  Between removals and the helper's five-minute re-add, mousehole's traffic
  used the Docker fallback rule (priority 130, sonarr's tunnel) instead of
  prowlarr's. It stayed inside a Proton tunnel.
- While rule `110` was present and `192.168.96.8` was whisparr's qBittorrent,
  whisparr's traffic left through prowlarr's tunnel while its forwarded port was
  on whisparr's tunnel. That breaks inbound connectability. The start of this
  period is not established; the rule was first observed earlier on 2026-09-23.
- No traffic reached the WAN outside a Proton tunnel: the kill switch stayed
  active throughout.

## Timeline

All times are CDT on 2026-09-23.

- 19:58:33: the operator ran `install-proton-systemd.sh`.
- 19:58:35: systemd began stopping `docker.service`; it stopped at 20:00:05 and
  started at 20:00:09.
- 20:02:05: sequential `proton-fleet-services.sh restart` of all five instances.
- 20:04:10: the operator deleted `from 192.168.96.8 lookup 51806 priority 110`.
  Mousehole's helper later re-added it.
- 20:55:08: the operator ran the installer to deploy `1ce8ae1`.
- 20:55:10: systemd began stopping `docker.service`; it stopped at 20:56:40.
- 20:56:41: the operator ran `proton-fleet-services.sh restart prowlarr`. Docker
  began starting. prowlarr's WireGuard bring-up removed rules `110` and `117`
  through the new sweep and could not resolve the stopped qBittorrent
  container, so it installed no qBittorrent rule 116.
- 20:56:44 and 20:57:04: `qbittorrent-prowlarr` and `qbittorrent-whisparr`
  finished (exit 0) during the Docker shutdown.
- 20:57:06: Docker started. lidarr, radarr, and sonarr qBittorrent returned;
  prowlarr and whisparr stayed exited. prowlarr's sync logged
  `container qbittorrent-prowlarr is exited; skipping sync because
  QBT_RESPECT_MANUAL_STOP=1`. `proton-fleet-services.sh` stopped with
  `proton-docker-watch@prowlarr.service is not active 5s after start`.
- About 20:57: mousehole's helper, restarted with Docker, re-added rules `110`
  and `117`.
- 21:04:12: the first `proton-qbt-fleet-recreate.sh --bootstrap` refused the
  rollout: `Unsafe or unknown task state for lidarr`. A sample shortly after
  showed one lidarr thread in `D` state in `wait_for_response` (CIFS), gone
  from the next two samples: transient share I/O, not a wedge.
- 21:05:12: the second bootstrap recreated all five sequentially (lidarr
  21:06:25, prowlarr 21:06:31, radarr 21:08:01, sonarr 21:09:21, whisparr
  21:09:27). Fleet verification passed for all five.
- 21:06:31, 21:07:23, 21:13:00: prowlarr's watcher, started at 21:06:33 with
  the sweep code, removed rules `110` and `117` each time they reappeared.
- 21:11:20 and 21:14:53: the operator installed `9d98932`. The kill switch was
  reloaded at 21:11:22 and 21:14:55, and Docker kept running.
- 21:15:26: the operator deleted rule `110` again.

## Evidence

### Docker restarts follow the installer

The installer's `sudo` entries and the Docker stop entries are two seconds
apart both times (19:58:33 → 19:58:35, 20:55:08 → 20:55:10). There are no other
Docker stops in the incident window. The installer's final step was:

```bash
systemctl restart proton-killswitch.service
```

`docker-proton-tunnels.conf`, installed as
`/etc/systemd/system/docker.service.d/proton-tunnels.conf`, contains:

```ini
[Unit]
Requires=proton-killswitch.service
After=proton-killswitch.service
```

`systemctl show docker.service` listed `proton-killswitch.service` under
`Requires=`.

### Rules 110 and 117 belong to mousehole

`/opt/mousehole/docker-compose.yml` defines a `mousehole-route` service with
`network_mode: host` and `NET_ADMIN`. Every 300 seconds it re-adds:

```text
ip rule add from 192.168.96.8/32 lookup 51806 priority 110
ip rule add from 192.168.111.250/32 lookup 51806 priority 117
```

The `mousehole` service is pinned to `192.168.111.250` on `starr_network`.
Container addresses on `starr_network` after the bootstrap:

```text
qbittorrent-lidarr 192.168.96.4    qbittorrent-prowlarr 192.168.96.26
sonarr             192.168.96.8    qbittorrent-whisparr 192.168.96.27
qbittorrent-sonarr 192.168.96.19   mousehole            192.168.111.250
qbittorrent-radarr 192.168.96.22
```

Before the 20:55 restart, `qbittorrent-whisparr` held `192.168.96.8`, and
`ip rule` showed `110: from 192.168.96.8 lookup 51806` ahead of whisparr's own
`115: from 192.168.96.8 lookup 51805`.

### The sweep removed them repeatedly

prowlarr's WireGuard and watcher journals logged, for example:

```text
Removed IPv4 policy rules at unowned priorities in table 51806:
110: from 192.168.96.8 lookup 51806; 117: from 192.168.111.250 lookup 51806
```

at 20:56:41, 21:06:31, 21:07:23, and 21:13:00.

## Root cause

### Confirmed: the installer restart propagated to Docker

`systemctl restart` on a unit also restarts every active unit that `Requires=`
it. The `Requires=` edge is intentional, because Docker must not run without
the kill switch. The installer's restart turned every install into a Docker
restart. That contradicts the project rule that Docker is not restarted without
explicit authorization. The README said only that the installer "restarts the
host kill switch", which did not reveal the Docker restart.

### Confirmed: the sweep assumed exclusive ownership of the route tables

The sweep in `1ce8ae1` treated every rule in an instance table at another
priority as stale. Other host services legitimately add rules to these tables.
The design decision relied on an unverified claim that rule `117` had no known
owner. No one had searched outside this repository for services that create
policy rules.

### Contributing: exited containers are treated as manual stops

With `QBT_RESPECT_MANUAL_STOP=1`, the sync skips an exited container. It cannot
tell a container that stopped during a Docker daemon restart from one an
operator stopped. Why prowlarr and whisparr stayed exited while the other three
returned under `unless-stopped` is not established. Both finished last, 20:56:44
and 20:57:04, after the other three (20:56:18–20:56:30).

## Corrective changes

Commit `9d98932`:

- `proton-killswitch.service` gains
  `ExecReload=/usr/local/bin/proton/proton-killswitch-dispatch.sh`, which re-runs
  the idempotent firewall dispatcher in place.
- The installer reloads the kill switch when it is active and starts it
  otherwise. It never restarts it. A reload does not propagate through
  `Requires=`, and starting an inactive required unit does not restart Docker.
  The `Requires=` edge is kept.
- A behavioral test runs the installer's `enable_and_start_services` against a
  stubbed `systemctl` in both states. It fails if any restart form returns.
- `1ce8ae1` is reverted. Instance scripts again delete only the rules they
  create. Audit item 4.6 is reopened.
- The README and the routing, fleet-change, and IPv6 documents describe the
  reload.

Outside this repository, at the operator's request: the three
`192.168.96.8` lines were removed from the `mousehole-route` loop in
`/opt/mousehole/docker-compose.yml`. The rule-117 lines were kept.

## Source validation

- 214 of 214 Bats tests passed; ShellCheck, shfmt, `bash -n`, and
  `git diff --check` were clean.
- The new installer test fails when the reload is replaced with a restart.
- `docker compose config --quiet` accepted the edited mousehole file.

## Post-deployment verification

Observed on 2026-09-23:

- Installs at 21:11:20 and 21:14:53 logged `Reloading proton-killswitch.service`
  and `Reloaded`, with no `docker.service` stop.
- `systemctl show proton-killswitch.service` lists the new `ExecReload`, and
  `ActiveEnterTimestamp` stayed at 20:56:41.
- The installed `proton-instance-common.sh`, `proton-wg-up-safe.sh`,
  `proton-docker-network-watcher.sh`, and `proton-killswitch-dispatch.sh` match
  source.
- All five qBittorrent containers were running and healthy after the bootstrap.

## Remaining actions

Open when this record was written:

1. Restart `proton-docker-watch@prowlarr.service`. It started at 21:06:33,
   before the revert was installed, and still runs the sweep in memory. A
   watcher restart does not stop the tunnel, port forwarding, or any container.
2. Recreate `mousehole-route` so the edited loop takes effect, then confirm
   `ip rule show table 51806` lists only rules 116 and 117.
3. Decide how the sync should treat a container that exited because of a
   Docker daemon restart. Today `QBT_RESPECT_MANUAL_STOP=1` leaves it down.
4. Audit item 4.6: any future stale-rule cleanup must identify this project's
   own rules, not assume the whole table.
5. Before changing any unit that other units `Requires=`, check the effect of
   restart propagation on those dependents.
