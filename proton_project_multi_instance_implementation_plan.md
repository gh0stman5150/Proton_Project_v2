# Proton Project Multi Instance Implementation and Test Plan

## Purpose

This plan updates Proton Project from a single Proton VPN tunnel and single qBittorrent instance into a multi instance design with one isolated Proton tunnel, one NAT PMP forwarded port, and one qBittorrent instance per workload.

The target workloads are:

```text
lidarr
radarr
sonarr
whisparr
prowlarr
```

Prowlarr will be used as the manual downloads lane.

## Current State

The uploaded Proton Project is currently designed around a single Proton tunnel and a single qBittorrent target.

Current design:

```text
one Proton tunnel
one VPN interface
one NAT PMP forwarded port
one qBittorrent env file
one qBittorrent port state file
one systemd service set
```

Examples from the current design:

```text
WG_PROFILE=proton
VPN_INTERFACE=proton
STATE_DIR=/run/proton
```

```text
QBITTORRENT_ENV_FILE=/etc/proton/qbittorrent.env
STATE_FILE=/run/proton/proton-port.state
```

The current implementation does not yet support five simultaneous Proton VPN tunnels, five isolated WireGuard interfaces, or five independent qBittorrent port sync targets.

## Target Architecture

New design:

```text
one Proton tunnel per workload
one forwarded Proton port per workload
one qBittorrent instance per workload
one healthcheck per workload
one failure domain per workload
```

Final service map:

```text
proton-wg@lidarr       -> proton-port-forward@lidarr       -> qbittorrent-lidarr
proton-wg@radarr       -> proton-port-forward@radarr       -> qbittorrent-radarr
proton-wg@sonarr       -> proton-port-forward@sonarr       -> qbittorrent-sonarr
proton-wg@whisparr     -> proton-port-forward@whisparr     -> qbittorrent-whisparr
proton-wg@prowlarr     -> proton-port-forward@prowlarr     -> qbittorrent-prowlarr
```

Each qBittorrent instance receives its own Proton forwarded port through its own Proton tunnel.

## Design Principles

1. No shared runtime port state between instances.
2. No shared qBittorrent env file between instances.
3. No shared WireGuard interface between instances.
4. No shared qBittorrent config directory between instances.
5. No shared qBittorrent WebUI port between instances.
6. One failed instance must not restart or disrupt the other instances.
7. Installer changes must be idempotent and must preserve existing live config files.
8. The old single instance setup must remain available until the new setup is fully proven.

## Proton Connection Model

Each workload needs its own Proton VPN session.

Recommended model:

```text
lidarr    -> unique WireGuard config -> unique VPN interface -> qbittorrent-lidarr
radarr    -> unique WireGuard config -> unique VPN interface -> qbittorrent-radarr
sonarr    -> unique WireGuard config -> unique VPN interface -> qbittorrent-sonarr
whisparr  -> unique WireGuard config -> unique VPN interface -> qbittorrent-whisparr
prowlarr  -> unique WireGuard config -> unique VPN interface -> qbittorrent-prowlarr
```

Proton supports multiple simultaneous connections depending on plan limits. This design uses five simultaneous connections.

## Same VPN Server Handling

Multiple instances may connect to the same Proton VPN server, but they must still be independent VPN sessions.

The implementation must support this:

```text
Proton P2P server A
  connection 1 -> proton-wg@lidarr    -> qbittorrent-lidarr
  connection 2 -> proton-wg@radarr    -> qbittorrent-radarr
  connection 3 -> proton-wg@sonarr    -> qbittorrent-sonarr
  connection 4 -> proton-wg@whisparr  -> qbittorrent-whisparr
  connection 5 -> proton-wg@prowlarr  -> qbittorrent-prowlarr
```

This only works cleanly if each instance has:

```text
unique WireGuard config
unique WireGuard private key or profile identity
unique VPN interface name
unique NAT PMP refresh loop
unique qBittorrent port env file
unique runtime state directory
```

Do not reuse one WireGuard config for all five instances unless it has been confirmed safe. WireGuard peers are identified by key pairs. Reusing the same key pair against the same Proton endpoint can cause endpoint roaming behavior, session flapping, or confusing port forwarding behavior.

Preferred approach:

```text
same region
separate Proton P2P servers when practical
separate WireGuard configs always
```

Acceptable approach:

```text
same Proton P2P server
separate WireGuard configs
separate interfaces
separate state
```

Bad approach:

```text
same Proton server
same WireGuard config
same interface
same NAT PMP state
```

That is not isolation. That is a future outage wearing a fake mustache.

## Instance Names

Allowed instances:

```text
lidarr
radarr
sonarr
whisparr
prowlarr
```

Every instance aware script must reject missing or invalid instance names.

## Phase 1: Preserve the Current Project

Before changing anything, create a safe baseline.

### Tasks

1. Commit or archive the current project.
2. Back up live configs.
3. Back up current systemd units.
4. Back up current qBittorrent state.
5. Document current working ports and service names.

### Backup Commands

```bash
sudo mkdir -p /root/proton-project-backup

sudo cp -a /etc/proton /root/proton-project-backup/etc-proton
sudo cp -a /etc/systemd/system/proton* /root/proton-project-backup/systemd 2>/dev/null || true
sudo cp -a /opt/qbittorrent /root/proton-project-backup/opt-qbittorrent 2>/dev/null || true
```

### Acceptance Criteria

```text
Current single instance setup can be restored.
Existing qBittorrent data is untouched.
Existing Proton services are not deleted yet.
```

## Phase 2: Create Instance Based Configuration

Add a new instance directory model.

### New Directory Layout

```text
/etc/proton/instances/lidarr/
/etc/proton/instances/radarr/
/etc/proton/instances/sonarr/
/etc/proton/instances/whisparr/
/etc/proton/instances/prowlarr/
```

Each directory should contain:

```text
proton.env
qbittorrent.env
qbittorrent-port.env
wireguard.conf
```

### Shared Config Files

Keep global shared config here:

```text
/etc/proton/proton-common.env
/etc/proton/proton-port-forward.env
/etc/proton/proton-healthcheck.env
```

Only settings that truly apply to all instances should live in shared config files.

### Example Prowlarr proton.env

```bash
INSTANCE_NAME=prowlarr
WG_PROFILE=pvprowl
VPN_INTERFACE=pvprowl
WG_CONFIG=/etc/proton/instances/prowlarr/wireguard.conf
STATE_DIR=/run/proton/prowlarr
```

### Example Prowlarr qbittorrent.env

```bash
QBT_INSTANCE_NAME=prowlarr
QBITTORRENT_URL=http://192.168.237.78:8085
QBITTORRENT_USER=your_user
QBITTORRENT_PASS=your_password

QBT_CONTAINER_NAME=qbittorrent-prowlarr
QBT_COMPOSE_PROJECT_DIR=/opt/qbittorrent-prowlarr
QBT_COMPOSE_SERVICE=qbittorrent
QBT_PORT_APPLY_MODE=compose-recreate
QBT_INTERNAL_PORT=6881
QBT_PORT_ENV_FILE=/etc/proton/instances/prowlarr/qbittorrent-port.env
QBT_NETWORK_NAME=starr-prowlarr
```

### WebUI Port Assignment

| Workload | qBittorrent Instance | WebUI Port |
|---|---:|---:|
| Lidarr | `qbittorrent-lidarr` | `8081` |
| Radarr | `qbittorrent-radarr` | `8082` |
| Sonarr | `qbittorrent-sonarr` | `8083` |
| Whisparr | `qbittorrent-whisparr` | `8084` |
| Prowlarr Manual | `qbittorrent-prowlarr` | `8085` |

### WireGuard Interface Names

Use short names:

```text
pvlidarr
pvradarr
pvsonarr
pvwhisp
pvprowl
```

### Acceptance Criteria

```text
All five instance directories exist.
Each instance has its own proton.env.
Each instance has its own qbittorrent.env.
Each instance has its own qbittorrent-port.env.
Each instance has its own WireGuard config path.
No instance shares runtime state files with another.
```

## Phase 3: Add Instance Validation

Every script that accepts an instance name must validate it.

### Validation Function

Add this to a shared helper, preferably:

```text
proton-instance-common.sh
```

Example:

```bash
validate_instance_name() {
  case "${1:-}" in
    lidarr|radarr|sonarr|whisparr|prowlarr)
      return 0
      ;;
    *)
      echo "Invalid Proton instance: ${1:-empty}" >&2
      return 1
      ;;
  esac
}
```

### Common Resolver Function

```bash
load_instance_env() {
  INSTANCE="${1:-}"
  validate_instance_name "$INSTANCE" || exit 1

  INSTANCE_DIR="/etc/proton/instances/${INSTANCE}"
  STATE_DIR="/run/proton/${INSTANCE}"

  [ -r /etc/proton/proton-common.env ] && . /etc/proton/proton-common.env
  [ -r /etc/proton/proton-port-forward.env ] && . /etc/proton/proton-port-forward.env
  [ -r /etc/proton/proton-healthcheck.env ] && . /etc/proton/proton-healthcheck.env

  [ -r "${INSTANCE_DIR}/proton.env" ] || {
    echo "Missing ${INSTANCE_DIR}/proton.env" >&2
    exit 1
  }

  [ -r "${INSTANCE_DIR}/qbittorrent.env" ] || {
    echo "Missing ${INSTANCE_DIR}/qbittorrent.env" >&2
    exit 1
  }

  . "${INSTANCE_DIR}/proton.env"
  . "${INSTANCE_DIR}/qbittorrent.env"

  mkdir -p "$STATE_DIR"
}
```

### Acceptance Criteria

```text
Missing instance name fails safely.
Invalid instance name fails safely.
Valid instance name loads the correct env files.
One instance cannot accidentally load another instance config.
```

## Phase 4: Convert Scripts to Instance Mode

Update each script so it accepts an instance argument.

### Scripts to Update

```text
proton-wg-up-safe.sh
proton-wg-down-safe.sh
proton-port-forward-safe.sh
proton-port-forward-healthcheck.sh
proton-qbittorrent-sync-safe.sh
proton-qbt-dnat-cleanup.sh
proton-healthcheck.sh
proton-docker-network-watcher.sh
proton-killswitch-safe.sh
proton-killswitch-nft.sh
proton-killswitch-reset.sh
proton-killswitch-dispatch.sh
```

### Expected Usage

```bash
proton-wg-up-safe.sh prowlarr
proton-port-forward-safe.sh prowlarr
proton-qbittorrent-sync-safe.sh prowlarr
proton-healthcheck.sh prowlarr
```

### Runtime State Files

Convert shared paths like this:

Old:

```text
/run/proton/proton-port.state
/run/proton/qbt-port.cache
/run/proton/recovery.lock
```

New:

```text
/run/proton/${INSTANCE}/proton-port.state
/run/proton/${INSTANCE}/qbt-port.cache
/run/proton/${INSTANCE}/recovery.lock
/run/proton/${INSTANCE}/qbt-sync.lock
/run/proton/${INSTANCE}/docker-config/
```

### Important Rule

No script should write to a shared port file.

Bad:

```text
/etc/proton/qbittorrent-port.env
```

Good:

```text
/etc/proton/instances/prowlarr/qbittorrent-port.env
```

### Acceptance Criteria

```text
prowlarr sync updates only prowlarr qBittorrent.
sonarr sync updates only sonarr qBittorrent.
radarr sync does not touch lidarr, sonarr, whisparr, or prowlarr.
Each instance writes only to its own /run/proton/${INSTANCE} directory.
```

## Phase 5: Convert systemd Units to Templates

Replace single instance units with templated units.

### Current Units

```text
proton-wg.service
proton-port-forward.service
proton-healthcheck.service
proton-docker-watch.service
proton-killswitch.service
```

### New Units

```text
proton-wg@.service
proton-port-forward@.service
proton-healthcheck@.service
proton-docker-watch@.service
proton-killswitch@.service
```

### Example proton-wg@.service

```ini
[Unit]
Description=Proton WireGuard tunnel for %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/proton/proton-wg-up-safe.sh %i
ExecStop=/usr/local/bin/proton/proton-wg-down-safe.sh %i

[Install]
WantedBy=multi-user.target
```

### Example proton-port-forward@.service

```ini
[Unit]
Description=Proton port forwarding for %i
After=proton-wg@%i.service
Requires=proton-wg@%i.service

[Service]
Type=simple
ExecStartPre=/usr/local/bin/proton/proton-port-forward-healthcheck.sh %i
ExecStart=/usr/local/bin/proton/proton-port-forward-safe.sh %i
ExecStop=/usr/local/bin/proton/proton-qbt-dnat-cleanup.sh %i
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### Example proton-healthcheck@.service

```ini
[Unit]
Description=Proton healthcheck for %i
After=proton-wg@%i.service proton-port-forward@%i.service
Requires=proton-wg@%i.service proton-port-forward@%i.service

[Service]
Type=simple
ExecStart=/usr/local/bin/proton/proton-healthcheck.sh %i
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

### Acceptance Criteria

```text
systemctl start proton-wg@prowlarr works.
systemctl start proton-port-forward@prowlarr works.
systemctl start proton-healthcheck@prowlarr works.
Starting prowlarr does not start or restart sonarr.
Stopping prowlarr does not stop lidarr, radarr, sonarr, or whisparr.
```

## Phase 6: Update Installer

Update:

```text
install-proton-systemd.sh
```

### Installer Must Install

```text
proton-wg@.service
proton-port-forward@.service
proton-healthcheck@.service
proton-docker-watch@.service
proton-killswitch@.service
```

### Installer Must Create

```text
/etc/proton/instances/
/etc/proton/instances/lidarr/
/etc/proton/instances/radarr/
/etc/proton/instances/sonarr/
/etc/proton/instances/whisparr/
/etc/proton/instances/prowlarr/
```

### Installer Must Preserve

```text
/etc/proton/instances/*/proton.env
/etc/proton/instances/*/qbittorrent.env
/etc/proton/instances/*/qbittorrent-port.env
/etc/proton/instances/*/wireguard.conf
```

### Installer Should Install Examples

```text
/etc/proton/instances/lidarr/proton.env.example
/etc/proton/instances/lidarr/qbittorrent.env.example
/etc/proton/instances/radarr/proton.env.example
/etc/proton/instances/radarr/qbittorrent.env.example
/etc/proton/instances/sonarr/proton.env.example
/etc/proton/instances/sonarr/qbittorrent.env.example
/etc/proton/instances/whisparr/proton.env.example
/etc/proton/instances/whisparr/qbittorrent.env.example
/etc/proton/instances/prowlarr/proton.env.example
/etc/proton/instances/prowlarr/qbittorrent.env.example
```

### Permissions

```bash
sudo chown -R root:root /etc/proton
sudo find /etc/proton -type d -exec chmod 755 {} \;
sudo find /etc/proton -type f -name "*.env" -exec chmod 600 {} \;
sudo find /etc/proton -type f -name "*.conf" -exec chmod 600 {} \;
```

### Acceptance Criteria

```text
Installer does not overwrite real env files.
Installer does not overwrite WireGuard configs.
Installer installs templated units.
Installer can be safely rerun.
```

## Phase 7: Create qBittorrent Compose Stacks

Create one qBittorrent project per workload.

```text
/opt/qbittorrent-lidarr
/opt/qbittorrent-radarr
/opt/qbittorrent-sonarr
/opt/qbittorrent-whisparr
/opt/qbittorrent-prowlarr
```

Each stack should have:

```text
unique container name
unique WebUI port
unique config volume
unique download root
unique Proton forwarded port file
```

### Download Roots

```text
/data/torrents/lidarr
/data/torrents/radarr
/data/torrents/sonarr
/data/torrents/whisparr
/data/torrents/prowlarr
```

### Prowlarr Manual Folders

```text
/data/torrents/prowlarr/incomplete
/data/torrents/prowlarr/complete
/data/torrents/prowlarr/manual
/data/torrents/prowlarr/watch
```

### Permissions

Use a shared media group:

```bash
sudo groupadd media 2>/dev/null || true

sudo usermod -aG media lidarr
sudo usermod -aG media radarr
sudo usermod -aG media sonarr
sudo usermod -aG media whisparr
sudo usermod -aG media prowlarr 2>/dev/null || true

sudo chown -R root:media /data/torrents
sudo chmod -R 2775 /data/torrents
```

### Acceptance Criteria

```text
Each qBittorrent instance starts independently.
Each WebUI is reachable on its assigned port.
Each instance uses its own config directory.
Each instance writes downloads only to its own path.
```

## Phase 8: Decide Container Networking

Use the cleaner model:

```text
one Proton VPN container per qBittorrent container
qBittorrent shares the matching Proton container network namespace
```

Example pattern:

```text
proton-prowlarr
qbittorrent-prowlarr network_mode service:proton-prowlarr
```

Repeat for:

```text
lidarr
radarr
sonarr
whisparr
prowlarr
```

This is safer than host level policy routing because each qBittorrent instance is trapped inside its matching VPN namespace.

### Acceptance Criteria

```text
qBittorrent prowlarr traffic exits only through proton prowlarr.
qBittorrent sonarr traffic exits only through proton sonarr.
Stopping one Proton VPN container kills only its matching qBittorrent network.
No qBittorrent instance uses the host default route for torrent traffic.
```

## Phase 9: Update Port Forward Behavior

Each instance must run its own NAT PMP loop through its own tunnel.

### Per Instance Flow

```text
proton-port-forward@prowlarr starts
NAT PMP requests a port through pvprowl
port is written to /etc/proton/instances/prowlarr/qbittorrent-port.env
proton-qbittorrent-sync-safe.sh prowlarr updates qbittorrent-prowlarr
qbittorrent-prowlarr listens on the new forwarded port
```

### Port File Format

```bash
QBT_PUBLISHED_PORT=45678
QBT_FORWARDED_PORT=45678
```

Use the naming already present in the project if it differs, but keep it per instance.

### Acceptance Criteria

```text
Each instance receives a different forwarded Proton port.
Each instance writes its own forwarded port file.
Each qBittorrent listen port matches its own Proton forwarded port.
A port change for prowlarr does not recreate sonarr.
```

## Phase 10: Update Arr and Prowlarr Clients

### Arr Download Clients

| App | qBittorrent URL | Category |
|---|---|---|
| Lidarr | `http://192.168.237.78:8081` | `lidarr` |
| Radarr | `http://192.168.237.78:8082` | `radarr` |
| Sonarr | `http://192.168.237.78:8083` | `sonarr` |
| Whisparr | `http://192.168.237.78:8084` | `whisparr` |

### Prowlarr Manual Downloads

Prowlarr should use:

```text
http://192.168.237.78:8085
```

Category:

```text
manual
```

Save path:

```text
/data/torrents/prowlarr/complete
```

### Acceptance Criteria

```text
Lidarr sends only music downloads to qbittorrent-lidarr.
Radarr sends only movie downloads to qbittorrent-radarr.
Sonarr sends only TV downloads to qbittorrent-sonarr.
Whisparr sends only its downloads to qbittorrent-whisparr.
Prowlarr manual searches send only manual downloads to qbittorrent-prowlarr.
```

## Phase 11: Add Automated Tests

Extend the existing Bats tests rather than adding a second test framework.

### Existing Test Files to Update

```text
tests/all-scripts.bats
tests/proton-healthcheck.bats
tests/proton-port-forward.bats
tests/proton-qbittorrent-auth.bats
tests/proton-qbittorrent-sync.bats
tests/proton-qbt-dnat-cleanup.bats
tests/proton-wg-up.bats
tests/systemd-units.bats
```

### New Test File

Add:

```text
tests/proton-instances.bats
```

## Detailed Test Plan

## Test Group 1: Instance Validation

### Tests

```text
missing instance name fails
empty instance name fails
invalid instance name fails
lidarr is accepted
radarr is accepted
sonarr is accepted
whisparr is accepted
prowlarr is accepted
```

### Expected Result

```text
Only the five approved instance names are accepted.
```

## Test Group 2: Config Loading

### Tests

```text
lidarr loads /etc/proton/instances/lidarr/proton.env
radarr loads /etc/proton/instances/radarr/proton.env
sonarr loads /etc/proton/instances/sonarr/proton.env
whisparr loads /etc/proton/instances/whisparr/proton.env
prowlarr loads /etc/proton/instances/prowlarr/proton.env
```

### Negative Tests

```text
prowlarr does not load sonarr env
sonarr does not load prowlarr env
missing qbittorrent.env fails safely
missing proton.env fails safely
missing wireguard.conf fails safely
```

## Test Group 3: Runtime Isolation

### Tests

```text
prowlarr writes /run/proton/prowlarr/proton-port.state
prowlarr does not write /run/proton/sonarr/proton-port.state
sonarr writes /run/proton/sonarr/qbt-port.cache
sonarr does not write /run/proton/prowlarr/qbt-port.cache
```

### Expected Result

```text
Every lock, cache, state file, and generated Docker config lives under /run/proton/${INSTANCE}.
```

## Test Group 4: qBittorrent Sync

### Tests

```text
prowlarr sync reads prowlarr qbittorrent.env
prowlarr sync writes prowlarr qbittorrent-port.env
prowlarr sync calls qbittorrent-prowlarr WebUI
sonarr sync calls only qbittorrent-sonarr WebUI
```

### Mock Values

Use fake ports:

```text
lidarr     41001
radarr     41002
sonarr     41003
whisparr   41004
prowlarr   41005
```

### Expected Result

```text
Each instance updates only its own configured qBittorrent URL.
No sync command touches another instance.
```

## Test Group 5: NAT PMP Port Forwarding

### Tests

```text
proton-port-forward-safe.sh prowlarr writes prowlarr port state
proton-port-forward-safe.sh sonarr writes sonarr port state
port refresh loop preserves instance isolation
failed NAT PMP for prowlarr does not affect sonarr
```

### Expected Result

```text
Port forwarding is instance specific.
A failed Prowlarr tunnel does not restart every tunnel.
```

## Test Group 6: WireGuard Setup

### Tests

```text
proton-wg-up-safe.sh prowlarr uses pvprowl
proton-wg-up-safe.sh sonarr uses pvsonarr
proton-wg-down-safe.sh prowlarr removes only pvprowl
proton-wg-down-safe.sh sonarr does not remove pvprowl
```

### Expected Result

```text
Each WireGuard interface is managed independently.
```

## Test Group 7: Same VPN Server Isolation

### Purpose

Confirm that multiple instances can point to the same Proton VPN server without collapsing into shared state.

### Tests

```text
lidarr and radarr may reference the same Proton endpoint
lidarr and radarr must use different WG_CONFIG values
lidarr and radarr must use different VPN_INTERFACE values
lidarr and radarr must use different STATE_DIR values
lidarr and radarr must write different qbittorrent-port.env files
stopping proton-wg@radarr does not stop proton-wg@lidarr
restarting proton-port-forward@prowlarr does not change sonarr's forwarded port file
```

### Expected Result

```text
Same server does not mean same tunnel.
Same server does not mean same WireGuard identity.
Same server does not mean shared NAT PMP state.
```

## Test Group 8: DNAT Cleanup

### Tests

```text
proton-qbt-dnat-cleanup.sh prowlarr removes only prowlarr rules
proton-qbt-dnat-cleanup.sh sonarr removes only sonarr rules
cleanup is safe when no rules exist
cleanup rejects invalid instance names
```

### Expected Result

```text
Cleanup is idempotent and scoped to one instance.
```

## Test Group 9: Healthcheck

### Tests

```text
proton-healthcheck.sh prowlarr checks prowlarr tunnel
proton-healthcheck.sh prowlarr checks qbittorrent-prowlarr
proton-healthcheck.sh prowlarr validates prowlarr forwarded port
sonarr healthcheck does not check prowlarr state
```

### Failure Tests

```text
missing qBittorrent WebUI fails instance healthcheck
wrong qBittorrent listen port fails instance healthcheck
missing WireGuard interface fails instance healthcheck
stale forwarded port fails instance healthcheck
```

### Expected Result

```text
Healthcheck failure is local to one instance.
```

## Test Group 10: systemd Unit Tests

### Tests

```text
proton-wg@.service exists
proton-port-forward@.service exists
proton-healthcheck@.service exists
proton-docker-watch@.service exists
proton-killswitch@.service exists
```

### Template Tests

Verify `%i` is used correctly:

```text
ExecStart includes %i
ExecStop includes %i
proton-port-forward@.service requires proton-wg@%i.service
proton-healthcheck@.service requires proton-port-forward@%i.service
```

### Expected Result

```text
All systemd services are instance aware.
No templated service calls old single instance scripts without %i.
```

## Test Group 11: Installer Tests

### Tests

```text
installer creates /etc/proton/instances
installer creates lidarr instance directory
installer creates radarr instance directory
installer creates sonarr instance directory
installer creates whisparr instance directory
installer creates prowlarr instance directory
installer installs templated units
installer preserves existing proton.env
installer preserves existing qbittorrent.env
installer preserves existing wireguard.conf
installer is idempotent
```

### Expected Result

```text
The installer can be safely rerun without damaging live configs.
```

## Test Group 12: Docker Compose Tests

### Tests

```text
qbittorrent-lidarr compose project exists
qbittorrent-radarr compose project exists
qbittorrent-sonarr compose project exists
qbittorrent-whisparr compose project exists
qbittorrent-prowlarr compose project exists
```

### Configuration Checks

```text
each qBittorrent container has unique name
each qBittorrent WebUI port is unique
each qBittorrent config volume is unique
each qBittorrent download path is unique
each qBittorrent stack reads the correct qbittorrent-port.env
```

### Expected Result

```text
No duplicate WebUI ports.
No duplicate container names.
No shared qBittorrent config folders.
```

## Test Group 13: End to End Live Tests

Run these manually after automated tests pass.

### Prowlarr First

Start only Prowlarr:

```bash
sudo systemctl start proton-wg@prowlarr
sudo systemctl start proton-port-forward@prowlarr
sudo systemctl start proton-healthcheck@prowlarr
```

Check status:

```bash
sudo systemctl status proton-wg@prowlarr
sudo systemctl status proton-port-forward@prowlarr
sudo systemctl status proton-healthcheck@prowlarr
```

Verify files:

```bash
sudo cat /etc/proton/instances/prowlarr/qbittorrent-port.env
sudo ls -la /run/proton/prowlarr
```

Verify qBittorrent:

```text
qBittorrent WebUI opens on port 8085.
qBittorrent listen port matches Proton forwarded port.
Manual download starts.
Manual download completes.
Manual download seeds.
```

### Then Sonarr

Repeat for Sonarr:

```bash
sudo systemctl start proton-wg@sonarr
sudo systemctl start proton-port-forward@sonarr
sudo systemctl start proton-healthcheck@sonarr
```

Verify:

```text
Sonarr can send to qbittorrent-sonarr.
Sonarr import works.
Sonarr seeding works.
Prowlarr remains running.
Prowlarr port does not change because Sonarr started.
```

### Then Radarr, Lidarr, Whisparr

Add each one only after the previous one is stable.

Recommended order:

```text
prowlarr
sonarr
radarr
lidarr
whisparr
```

Prowlarr comes first because manual downloads are the lowest risk test lane.

## Cutover Plan

## Step 1: Build and Test Code Offline

Run:

```bash
shellcheck *.sh
bats tests
```

Expected:

```text
All shellcheck tests pass.
All Bats tests pass.
```

## Step 2: Install Templated Services

```bash
sudo ./install-proton-systemd.sh
sudo systemctl daemon-reload
```

Verify:

```bash
systemctl list-unit-files 'proton*@.service'
```

## Step 3: Configure Prowlarr Instance

Create:

```text
/etc/proton/instances/prowlarr/proton.env
/etc/proton/instances/prowlarr/qbittorrent.env
/etc/proton/instances/prowlarr/wireguard.conf
```

Start:

```bash
sudo systemctl start proton-wg@prowlarr
sudo systemctl start proton-port-forward@prowlarr
sudo systemctl start proton-healthcheck@prowlarr
```

## Step 4: Configure qBittorrent Prowlarr

Verify:

```text
WebUI port 8085 works.
Manual category exists.
Save path is /data/torrents/prowlarr/complete.
Incomplete path is /data/torrents/prowlarr/incomplete.
```

## Step 5: Connect Prowlarr Manual Downloads

In Prowlarr, configure download client:

```text
Host: 192.168.237.78
Port: 8085
Category: manual
```

Run one small manual download.

## Step 6: Repeat for Sonarr, Radarr, Lidarr, Whisparr

For each:

1. Create instance config.
2. Start Proton services.
3. Start qBittorrent.
4. Confirm forwarded port.
5. Configure matching Arr app.
6. Test one download.
7. Test import.
8. Test seeding.

## Step 7: Disable Old Single Instance Services

Only after all five are working:

```bash
sudo systemctl disable --now proton-wg.service 2>/dev/null || true
sudo systemctl disable --now proton-port-forward.service 2>/dev/null || true
sudo systemctl disable --now proton-healthcheck.service 2>/dev/null || true
sudo systemctl disable --now proton-docker-watch.service 2>/dev/null || true
```

Do not delete the old files immediately.

## Rollback Plan

Rollback should be simple.

### Stop New Instance Services

```bash
sudo systemctl stop proton-healthcheck@prowlarr proton-port-forward@prowlarr proton-wg@prowlarr
sudo systemctl stop proton-healthcheck@sonarr proton-port-forward@sonarr proton-wg@sonarr
sudo systemctl stop proton-healthcheck@radarr proton-port-forward@radarr proton-wg@radarr
sudo systemctl stop proton-healthcheck@lidarr proton-port-forward@lidarr proton-wg@lidarr
sudo systemctl stop proton-healthcheck@whisparr proton-port-forward@whisparr proton-wg@whisparr
```

### Restart Old Services

```bash
sudo systemctl start proton-wg.service
sudo systemctl start proton-port-forward.service
sudo systemctl start proton-healthcheck.service
```

### Restore Old Config if Needed

```bash
sudo rsync -a /root/proton-project-backup/etc-proton/ /etc/proton/
sudo systemctl daemon-reload
```

### Rollback Acceptance Criteria

```text
Old single qBittorrent instance is reachable.
Old Proton tunnel is active.
Old Proton port forwarding works.
Existing torrents are not deleted.
```

## Completion Checklist

The implementation is complete when all of this is true:

```text
Five Proton WireGuard tunnels exist.
Five Proton NAT PMP loops run independently.
Five qBittorrent instances run independently.
Five qBittorrent instances each receive their own forwarded Proton port.
Each qBittorrent listen port matches its own forwarded Proton port.
Each Arr app talks only to its matching qBittorrent instance.
Prowlarr manual downloads go only to qbittorrent-prowlarr.
Multiple instances can point to the same Proton server without sharing state.
Healthcheck failure for one instance does not restart the other four.
Installer can be rerun safely.
Automated tests pass.
Manual end to end tests pass.
Old single instance services are disabled but not immediately deleted.
```

## Recommended Work Order

```text
1. Add instance config loading.
2. Add instance validation.
3. Convert qBittorrent sync.
4. Convert port forward logic.
5. Convert WireGuard up and down scripts.
6. Convert healthcheck.
7. Convert DNAT cleanup.
8. Add same VPN server isolation handling and tests.
9. Convert systemd units to templates.
10. Update installer.
11. Add automated tests.
12. Build Prowlarr first.
13. Test manual downloads.
14. Add Sonarr.
15. Add Radarr.
16. Add Lidarr.
17. Add Whisparr.
18. Disable old single instance services.
```

## Final Notes

Prowlarr should be the first live instance because manual downloads are the lowest risk test lane. Once Prowlarr is stable, move to Sonarr, Radarr, Lidarr, and Whisparr.

The critical technical requirement is isolation. Five tunnels pointed at one Proton server can work, but only if they are truly five VPN sessions with separate identities, interfaces, runtime state, NAT PMP loops, and qBittorrent targets. Anything less is fake separation, and fake separation is where outages go to breed.

## Live Changes (2026-06-06)

This document is the source of truth for implementation. The following live changes were applied during the current session; record them here so the plan and the running system remain in sync.

- Files edited (high level):
  - [/usr/local/bin/proton_project/proton-wg-up-safe.sh](usr/local/bin/proton_project/proton-wg-up-safe.sh) — now invokes the server-manager with `PROTON_COMMON_ENV_FILE=/dev/null` so the per-instance `STATE_DIR` is respected during selection.
  - [/usr/local/bin/proton_project/proton-server-manager.sh](usr/local/bin/proton_project/proton-server-manager.sh) — added a claims mechanism to avoid duplicate port/endpoint selection across instances. New defaults: `PF_CLAIMS_FILE=/run/proton/pf-claims.tsv`, `CLAIM_TTL=3600`. New helper functions: `cleanup_claims`, `get_profile_forward_port`, `port_claimed_by`, `claim_profile_port`, `remove_claim_for_profile`, `profile_claimed_by`, `endpoint_claimed_by`. The selection flow now cleans expired claims, skips claimed profiles/endpoints, and writes the chosen selection to the instance `current-server.env`.
  - Per-instance qbittorrent envs: several files under `/etc/proton/instances/*/qbittorrent.env` were updated to avoid host-port collisions during initial rollout (non-Sonarr instances were set to `QBT_PORT_APPLY_MODE=legacy-dnat`).

  - Server-manager will now claim a selected backend's endpoint IP when no Proton forwarded port is known. This prevents other instances from selecting the same backend server even when port-forward state is not yet available.

- Runtime state created or observed:
  - `/run/proton/pf-claims.tsv` — claims file (ephemeral) records profile -> claimed port -> instance.
  - `/run/proton/<instance>/current-server.env` — server-manager writes per-instance selection here.
  - `/run/proton/<instance>/proton-port.state` — shows `CURRENT_PORT` / `CURRENT_IP` per instance (distinct ports observed).

- Actions attempted during the session:
  - Populated `/etc/wireguard/proton-pool` from runtime configs so server-manager can choose different profiles.
  - Implemented server-manager claim logic and exercised per-instance selection and `proton-wg@<inst>` restarts so each instance can claim a distinct forwarded port.
  - Switched non-Sonarr instances to `legacy-dnat` as a safe immediate mitigation for host-port collisions.
  - Attempted to run an automated duplicate-removal over `/etc/wireguard/proton-pool` to move identical PrivateKey/Address configs to a backup directory; this cleanup attempt failed due to a quoting/shell invocation syntax error and must be rerun safely.

- Known issues and next steps:
  1. Ensure `/etc/wireguard/proton-pool` contains unique profiles (unique private keys and addresses) for each instance; remove or archive duplicates.
  2. If Proton's pool cannot provide unique identities, generate per-instance WireGuard configs with unique keypairs and appropriate endpoints.
  3. Re-run `proton-wg@<inst>` restart after pool cleanup and confirm `/etc/wireguard/proton-runtime/pv<inst>.conf` reflects the selected profile (unique `PrivateKey` / `Address`).
  4. Re-run `/usr/local/bin/proton_project/proton-qbittorrent-sync-safe.sh <inst>` for each instance and verify qBittorrent WebUI reachability and that each qB instance listens only on its VPN path.
  5. Rerun the WG pool duplicate cleanup with a corrected backup-and-move script and record the backup directory under `/run/proton/last-pool-dup-backup`.

Record any further live edits here so this file remains authoritative for both planning and post-change auditing.
