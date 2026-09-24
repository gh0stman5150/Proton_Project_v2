# Code audit — 2026-09-23

## Scope and evidence

Read-only audit of first-party source for stale, obsolete, and inefficient code:
runtime scripts, `tools/`, the installer, systemd units and drop-ins, env
templates, tests, docs, and repository config. `bats-core/` was excluded.

- Performed on a macOS OneDrive copy of the working tree, not the canonical
  checkout. The tree had uncommitted changes (scripts moved out of `Archive/`,
  sync tests split); findings describe that state.
- Evidence is source-only: grep, `shellcheck -x`, `shfmt -l`, `bash -n`, and a
  Homebrew `bats` run. Nothing was installed and the live fleet was not touched.
  No finding here is a live-host observation.
- `/archive` was not consulted; no root-cause claims are made.
- Line numbers are as of this audit and will drift after edits. Re-locate by
  function or key name before changing anything.

Status legend: **C** = confirmed by grep/reading; **P** = plausible, verify on
the host before acting. Items marked *shared* change fleet structure or
all-five runtime behavior and need the all-five validation and sequential
rollout in `docs/runbooks/qbittorrent-fleet-changes.md`.

No source changes were made during the audit. `CLAUDE.md` was created in the
same session (it imports `AGENTS.md`).

## Suggested order

1. Repository hygiene and CI breakers (section 1) — no runtime impact.
2. Hot-path load reductions (section 2) — *shared*, highest runtime value.
3. Dead-code and obsolete-mode removal (sections 3–5).
4. Test and documentation consolidation (sections 6–7).

Validate each batch with the commands in `AGENTS.md` → Validation, run on Linux
(the suite assumes bash 4+ and GNU tools; roughly half the tests fail under
macOS bash 3.2/BSD tools for environmental reasons).

---

## 1. Repository hygiene and CI breakers

- [x] **1.1 Stage the moved files together (C).** Untracked:
  `proton-killswitch-reset.sh`, `proton-qbt-dnat-cleanup.sh`,
  `deploy-live-ipv6-firewall.sh`, `tests/proton-qbittorrent-sync-{port,recreate,safety}.bats`,
  `tests/proton-qbittorrent-sync-helper.bash`, `docs/reviews/`,
  `docs/architecture/host-routing-and-tunnels.md`,
  `docs/runbooks/{host-verification,ipv6-rollout,server-pool-selection}.md`,
  `CLAUDE.md`. Their `Archive/` and old-test counterparts are deleted. A
  tracked-only commit leaves the installer `SCRIPTS` array, the
  `proton-port-forward@.service` `ExecStop`, and tests referencing files absent
  from the repo. `git add` all of them in the same commit.
- [x] **1.2 `.gitignore` case (C).** `archive/*` only matches `Archive/` on
  case-insensitive filesystems (`git -c core.ignorecase=false check-ignore
  Archive/x.sh` → not ignored). On the Linux host the legacy helpers are not
  ignored, contradicting `AGENTS.md` and `Archive/README.md`. Change to
  `Archive/*` and keep `!Archive/README.md`.
- [x] **1.3 `tests/installer-instance-layout.bats` (~line 84) (C).** Greps
  `Archive/proton-instances-normalize.sh`, which is git-ignored and absent in
  CI. Delete the assertion; the preceding test already checks
  `QBT_COMPOSE_SERVICE=qbittorrent-${instance}` in the installer.
- [x] **1.4 `tests/docs-archive-contract.bats` (~line 83) (C).** Regex
  contains corrupted token `rele/establish-agents-md-hierarchyvant`; restore
  `relevant` or drop that alternative.
- [x] **1.5 `bats-core` gitlink (C).** Mode 160000 entry with no
  `.gitmodules`; the directory is empty in fresh copies, so every documented
  `./bats-core/bin/bats` command fails. Add `.gitmodules` (upstream
  `bats-core/bats-core` at the pinned commit) or vendor the runner, or document
  the system `bats` fallback CI already uses.
- [x] **1.6 Committed public address (C).** `proton-common.env`
  `MANAGEMENT_ALLOWED_CIDRS` contains a real-looking public `/32`. The key is
  unused (see 3.6). Remove the address from the template; consider whether
  history needs rewriting.
- [x] **1.7 Line endings (C).** `.gitattributes`, `.gitignore`,
  `Proton_Project_v2.code-workspace`, `nas-network-online.mount.conf`, and
  `tests/proton-instances.bats` are CRLF in the macOS working tree
  (`git ls-files --eol`). The CRLF drop-in breaks the `systemd-units.bats`
  "NAS mounts wait…" test locally. Re-checkout with LF on the host and add
  `*.json`, `.git*`, `*.code-workspace` rules to `.gitattributes`.

Section 1 resolved, 2026-09-23 (canonical Linux checkout, source-only):

- 1.1 landed with merge `ff4c1c9`.
- 1.2 was masked on the host by `core.ignorecase=true` in `.git/config`
  (since set to `false`); verified with
  `git -c core.ignorecase=false status --ignored Archive`.
- 1.4: the token was corrupt since it was introduced in `3f1f7f1`, so the
  alternative was dropped rather than restored.
- 1.5: `.gitmodules` points at the `gh0stman5150/bats-core` fork, because the
  pinned commit `3799ca3` is not on upstream.
- 1.6: the address was removed from the template and from history.
  `main` and `copilot/fix-shfmt-shellcheck-bats-job` were rewritten with
  `git filter-branch --index-filter` touching only `proton-common.env`; commit
  hashes from `b9feb91` onward changed. Clones made before the rewrite still
  hold the address and must be re-cloned or hard-reset, not merged. The
  unused key is 3.6.
- 1.7: on the host the CRLF files were `.vscode/*.json` and
  `proton-port-forward.env` (working copy only); the installed
  `/etc/proton/proton-port-forward.env` was already LF.

## 2. Hot-path inefficiencies (*shared*)

- [x] **2.1 Sync after every renewal (C).** `proton-port-forward-safe.sh`
  renewal branch (~369–379) launches `proton-qbittorrent-sync-safe.sh` after
  every successful renewal, even with an unchanged port. With shipped defaults
  `RENEW_INTERVAL` ≈ 11 s, so ~5 syncs per 11 s fleet-wide. Each unchanged
  sync re-sources env files, logs in to qBittorrent, reads preferences, makes
  ~6 `docker` calls, and runs `proton-docker-network-watcher.sh <i> --once`,
  which takes `/run/proton/policy-routing.lock` and deletes/re-adds shared
  policy rules (brief rule absence, lock contention; a slow reconcile holding
  `lifecycle.lock` can fail the next renewal's 5 s lock wait).
  **Change:** sync immediately when port/IP changed or the previous sync
  failed; otherwise run a drift check at a slower cadence. In the sync, run the
  route reconcile only when container ID/IP differs from the cached value.
  Forced fleet sync semantics (wait, fail on timeout) must not change.
- [x] **2.2 `mark-capable` every renewal (C).** Same branch runs
  `proton-server-manager.sh mark-capable` each time: global
  `server-select.lock`, rewrites of `/etc/proton/pf-capable-profiles.tsv` and
  related files, a log line; silently dropped by its 3 s timeout during
  `select`. **Change:** call only when a new port is obtained or the profile
  changes.
- [x] **2.3 Watcher periodic reconcile (C).**
  `proton-docker-network-watcher.sh` (~484–489) re-runs route reconcile,
  kill-switch rebuild, and allocate+sync every ~65 s per instance even when
  nothing changed (≈5 firewall rebuilds/min). The periodic route reconcile is
  documented in `host-routing-and-tunnels.md`; keep it, but skip kill switch
  and allocation when CIDR, CIDR6, and qBittorrent IPs match the persisted
  state.
- [x] **2.4 Watcher debounce (C).** The per-event loop sleeps
  `DEBOUNCE_SECONDS` but does not drain queued events, so one container
  recreate (destroy/create/start/disconnect/connect) triggers several full
  reconciles. Drain with `read -t 0` after the sleep, then reconcile once.
- [x] **2.5 Healthcheck login per tick (C).** `proton-healthcheck.sh` calls
  `qbt_login` every `CHECK_INTERVAL`; `proton-qbittorrent-common.sh` truncates
  the cookie jar and POSTs `/auth/login` each time. Reuse a per-instance 0600
  cookie jar under `STATE_DIR`; re-login on 403.
- [x] **2.6 Healthcheck active-transfer probe (C/P).** `has_active_transfers`
  downloads the full active-torrent JSON to test emptiness; add `&limit=1`
  (verify the parameter on the deployed qBittorrent version).
- [x] **2.7 Repeated `docker inspect` in sync (C).**
  `compose_container_status` (2 inspects), `compose_current_published_port`
  and `compose_service_publishes_port` (each ref lookup + ports inspect).
  Inspect once per phase with a combined template; refresh after recreate.
- [x] **2.8 Small per-renewal forks (C, low).** `proton-port-forward-safe.sh`:
  `get_ip` twice, three `awk` passes in `save_state`, `boot_id` read on every
  save/read, several `date +%s` forks, NAT-PMP output re-parsed. Use one `awk`
  pass, `printf '%(%s)T'`, cache `boot_id` per process.
- [x] **2.9 Double env sourcing (C).** `proton-qbittorrent-sync-safe.sh` and
  `proton-healthcheck.sh` call `qbt_source_env_file` after `proton_instance_init`
  already stat-checked and sourced the same file. Keep only the URL trim.

Section 2 resolved, 2026-09-23 (canonical Linux checkout, source-only, not
installed):

- 2.1: the renewal loop syncs when the port differs from the last successfully
  synced port, after a failed sync, or every `QBT_SYNC_DRIFT_INTERVAL_SECONDS`
  (default 300). The in-sync route reconcile was left unconditional; with the
  sync now rare, caching container ID/IP did not justify another state file.
  Forced fleet sync is unchanged.
- 2.2: `mark-capable` runs once per profile and port, and again after a failed
  call. Capability records have no age check, so nothing relied on the refresh.
- 2.3: operator decision — every periodic pass still reasserts routes and the
  kill switch (firewall-drift repair unchanged); only allocation+sync is skipped
  when CIDRs and qBittorrent addresses are unchanged and the last queue attempt
  succeeded. The allocated state is kept in `qbt-allocated-routing` under the
  instance state directory because event handling runs in a pipeline subshell.
- 2.4: queued events are drained after the debounce and logged as coalesced.
- 2.5: the healthcheck keeps its per-process cookie jar and re-authenticates
  once on a failed request; no new state file was needed.
- 2.6: `limit=1` added; the fleet image `linuxserver/qbittorrent:libtorrentv1`
  is well past Web API 2.0, which introduced the parameter.
- 2.9: `qbt_source_env_file` had no other callers and was removed.
- 2.7 and 2.8 were first deferred by operator decision, then resolved later
  on 2026-09-23 at the operator's request.
- 2.7: an unchanged sync now runs two `docker inspect` calls instead of six.
  `compose_container_inspect` renders the template against
  `QBT_CONTAINER_NAME` in one call and falls back to the Compose lookup only
  when the name is unset or unknown. The published ports are read once for the
  drift check, with a fresh read after a recreate and in the wedge check. The
  templates are unchanged, so no test stubs were rewritten. A new test counts
  the inspect calls, and it fails against the old code.
- 2.8:
  - NAT-PMP output is parsed by one builtin function instead of four `awk`
    runs, one of them fed by `echo`.
  - `save_state` reads the state file in one builtin pass instead of three
    `awk` runs.
  - The boot ID is read once per process into `PROTON_BOOT_ID`. That covers
    the port-forward loop and `proton_lease_read` in the long-running loop.
    The value is cleared when the helper is sourced, so an inherited value is
    never trusted, and a new test covers that.
  - `get_ip` dropped its `cut` stage.
  - `date +%s` stays, because a safety test injects the clock through a
    `date` stub to prove an expired lease is never saved.
  - The second `get_ip` call stays too: it re-checks the tunnel address after
    the NAT-PMP request.
  - Mutation checks on the parser fields, the state-file keys, and the
    boot-ID reset each fail a test.

## 3. Dead code and unused configuration

- [x] **3.1 `command -v docker` always true (C).** `proton-instance-common.sh`
  line 3 defines a `docker()` function, which `command -v` reports. Unreachable
  "docker CLI not present" branches: `proton-docker-network-watcher.sh`
  (~78, 86, 124, 203, 226, 460; else-branch ~493–505), `proton-wg-up-safe.sh`
  (~329, 356, 719), `proton-wg-down-safe.sh` (~123, 146),
  `tools/verify-qbittorrent-fleet.sh` (~194). Remove, or use `type -P docker`
  where a real binary check is intended.
- [x] **3.2 Kill-switch scripts (C).** Never called: `server_pool_requested`,
  `load_selected_server` and their variables (`SERVER_SELECTION_FILE`,
  `SERVER_RESELECT_FILE`, `SERVER_POOL_ENABLED`, `SERVER_MANAGER_SCRIPT`,
  `WG_POOL_DIR`) in both `proton-killswitch-safe.sh` and
  `proton-killswitch-nft.sh`; `ensure_chain`, `ensure_jump_rule`,
  `ensure_nat_chain` in `proton-killswitch-safe.sh` (pre-`iptables-restore`
  leftovers); "applied without Docker CIDR state" log branches (both scripts
  already exit on empty CIDR). Then drop the no-op `SERVER_POOL_ENABLED=off`
  settings in `tests/proton-killswitch-contract.bats`.
- [x] **3.3 Installer dead functions (C).** Defined, never called:
  `validate_wireguard_config`, `secure_wireguard_config`, `path_dirname`,
  `restart_enabled_optional_services`, `reset_runtime_state_for_redeploy`.
  `load_common_env`/`load_port_forward_env` calls before
  `enable_and_start_services` feed nothing. `stop_proton_services_for_redeploy`
  only logs. Note: `host-routing-and-tunnels.md` claims the installer secures
  WireGuard files; only per-instance `wireguard.conf` is chmod'd — either
  restore `secure_wireguard_config` for pool configs or fix the doc.
- [x] **3.4 wg-up / wg-down (C).** `uses_nftables_backend` unused (and so
  `KILLSWITCH_BACKEND` in wg-up); unreachable `QBT_SNAPSHOT_READY` early return
  in wg-up; in wg-down, unused `KILLSWITCH_BACKEND`,
  `DOCKER_LOCAL_RULE_PRIORITY`, `DOCKER_LAN_RULE_PRIORITY`,
  `RESOLVED_DNS_ROUTE_DOMAIN`, a `detect_lan_cidr` call whose results are
  never read, and unreachable `SELECTED_WG_PROFILE`/`SELECTED_VPN_INTERFACE`
  fallbacks.
- [x] **3.5 Watcher and server manager (C).** Watcher: `load_selected_server`
  sources `current-server.env` every reconcile but reads none of it;
  `QBT_SYNC_SCRIPT`, `QBITTORRENT_ENV_FILE` unused; `LAST_FILE`/`STATE_DIR`
  defaults always overridden. Server manager: `port_claimed_by`,
  `endpoint_claimed_by` never called (so the claim record's port column is
  never read); `SELECTED_VPN_INTERFACE=$profile` has no live consumer and is
  the wrong value for `pv<instance>` interfaces.
- [x] **3.6 Unused env keys (C).** `proton-common.env`: `BYPASS_TCP_PORTS`,
  `BYPASS_UDP_PORTS`, `MANAGEMENT_ALLOWED_CIDRS`, `MANAGEMENT_TCP_PORTS`,
  `MANAGEMENT_UDP_PORTS` — no script reads them. Remove, and remove the
  `MANAGEMENT_ALLOWED_CIDRS` step in `host-routing-and-tunnels.md`.
- [x] **3.7 Write-only `CACHE_FILE` (C).** `qbt-port.cache` is written by the
  sync (and overwritten with the rollback port on failure) but never read.
  Remove, or document as diagnostic-only and fix the port-sync runbook wording
  that implies it has a function.
- [x] **3.8 `legacy_reference_port` TSV column (C, *shared*).** No code reads
  column 3 of `qbittorrent-instances.tsv`. Dropping it means renumbering the
  installer's field reads, the verifier `read`, the test fixture, and the doc
  table in `qbittorrent-fleet-contract.md`.
- [x] **3.9 Misc (C).** `proton_allowed_instances` unused (either delete it or
  make it the single allowlist; the five names are hard-coded in ~6 places,
  plus `docker-proton-tunnels.conf` and the kill-switch interface lists);
  `trim_field` subshells on already-split CIDRs; `$(vpn_interfaces)` in nft
  script; `proton-port-forward-healthcheck.sh` requires `ip`, `natpmpc`,
  `systemd-cat` it doesn't use (keep only if intended as a preflight and say
  so); `verify-qbittorrent-fleet.sh` re-sources `QBT_COMMON_SCRIPT` in a
  subshell.

Section 3 resolved except 3.8, 2026-09-23 (canonical Linux checkout,
source-only, not installed):

- 3.1: the always-true guards were removed, including the watcher's
  no-Docker polling loop. Checks that must find a real binary now use
  `type -P`: `require_command` in the sync script, and the `proton-ipv6-rollout.sh`
  preflight and status. The fleet verifier already exits early without Docker.
- 3.2: the pool-selection helpers, their variables, the `ensure_*` chain
  helpers, and the empty-CIDR log branches were removed from both backends.
- 3.3: the dead installer functions and the `load_*_env` calls were removed;
  the "leaving services running" message is now logged inline. The doc was
  corrected rather than restoring `secure_wireguard_config`: the installer
  secures per-instance `wireguard.conf`, `proton.env`, and `qbittorrent.env`,
  and keeps `/etc/wireguard/proton-pool` `root:root` 0700. Individual pool
  configs are not re-moded.
- 3.4: all listed items removed. wg-down's `LAN_IF`/`LAN_CIDR` defaults went
  with `detect_lan_cidr`, their only reader.
- 3.5: the watcher's selection loader, `QBT_SYNC_SCRIPT`,
  `QBITTORRENT_ENV_FILE`, and the `LAST_FILE`/`STATE_DIR` defaults were
  removed (`proton_instance_init` sets both). The server manager no longer
  writes `SELECTED_VPN_INTERFACE`. The claim record keeps its port column, which
  is still logged and counted by `cleanup_claims`; nothing reads it back.
- 3.6: keys removed from the template and from both WireGuard-defaults lists.
  Installed `/etc/proton/proton-common.env` copies are preserved by the
  installer and keep the inert keys until edited by hand.
- 3.7: kept as diagnostic-only and documented that way in the port-sync
  runbook and fleet contract. Its directory still anchors the
  `qbt-recreate.pending` record and legacy path inference.
- 3.8: first deferred, then resolved later on 2026-09-23 at the operator's
  request.
  - The column was dropped from the manifest. The installer's field numbers,
    the verifier's `read`, the fixture rows, and the fleet-contract table were
    updated.
  - The old port values are kept as a dated sentence in the fleet contract
    for incident comparison.
  - The installer's grep-only column-number checks were replaced by a test
    that runs its accessors and checks each value against the column named in
    the manifest header.
  - A verifier test does the same for the bind IP and Web UI port. Both fail
    against the old column numbers.
  - This is a *shared* format change. The installer installs the manifest and
    the tools that read it together.
- 3.9: `proton_allowed_instances` is now the allowlist for instance
  validation, the error message, the nft interface list, and the fleet
  verifier's manifest check. `proton-killswitch-safe.sh`,
  `proton-qbittorrent-common.sh`, and `proton-ipv6-rollout.sh` do not load the
  instance helper and keep their literal lists. The no-op `trim_field` calls on
  already-split CIDRs, `vpn_interfaces`, and the verifier's subshell
  re-source were removed. The port-forward preflight keeps its command list,
  now commented as an `ExecStartPre` check for the loop that follows.

## 4. Obsolete modes and migration shims

- [x] **4.1 Remove `legacy-dnat` mode (C, *shared*).** In
  `proton-qbittorrent-sync-safe.sh`: `restart_qbt_container_legacy`,
  `container_network_mode`, `resolve_container_ip`, `replace_qbt_dnat_rules`,
  `refresh_qbt_dnat_legacy`, `DNAT_CHANGED`, and `QBT_INTERNAL_PORT`
  validation used only there. The verifier requires `compose-recreate` for all
  five and bootstrap refuses anything else; the mode also uses `docker restart`,
  bypassing the injected-port Compose model. Reject `legacy-dnat` explicitly.
  Update `tests/proton-qbittorrent-sync-port.bats`,
  `docs/runbooks/host-verification.md`, the "Legacy DNAT mode only" comments in
  the installer template and `proton-qbittorrent.env`, and the healthcheck
  "DNAT refresh" wording in `host-routing-and-tunnels.md`.
- [x] **4.2 Retire `proton-qbt-dnat-cleanup.sh` (P, after 4.1).** On the host,
  confirm `nft -a list chain ip proton_nat prerouting` has no `qbt-dnat-*`
  rules. Then remove the script, the `ExecStop` in `proton-port-forward@.service`,
  its installer `SCRIPTS` entry, `tests/proton-qbt-dnat-cleanup.bats`, and the
  related assertions in `systemd-units.bats` and `installer-instance-layout.bats`.
  Keep the nft helpers `proton-killswitch-reset.sh` uses.
- [x] **4.3 Retire `deploy-live-ipv6-firewall.sh` (P).** It copies seven
  scripts directly into `/usr/local/bin/proton`, bypassing the installer; all
  seven are already in installer `SCRIPTS`, and `proton-ipv6-rollout.sh
  snapshot`/rollback covers recovery. Replace with installer + rollout
  snapshot in `docs/runbooks/ipv6-rollout.md` (which also says "six" scripts;
  there are seven), and remove `tests/deploy-live-ipv6-firewall.bats`. Keep
  `proton-ipv6-rollout.sh`; de-duplicate its `firewall_scripts` list.
- [ ] **4.4 Legacy singleton paths (P, *shared*).** Templates still ship
  singleton values (`STATE_DIR`, `STATE_FILE`, `QBITTORRENT_ENV_FILE`,
  `SERVER_SELECTION_FILE`, `RECOVERY_LOCK_FILE`, `VPN_TABLE=51820`,
  `VPN_INTERFACE=proton`, `NATPMP_GATEWAY`) that
  `proton_rebase_legacy_runtime_paths` always rewrites per instance. The
  installer still writes singleton `/etc/proton/qbittorrent.env` and
  `/etc/proton/qbittorrent-port.env` and accepts `--qb-*` flags that don't
  configure the fleet; its heredoc also drops `QBT_RESPECT_MANUAL_STOP` and
  `QBT_MANUAL_STOP_EVENT_GRACE_SECONDS` present in the template. Singleton
  template has stale `QBT_NETWORK_NAME=starr` (fleet uses `starr_network`).
  Plan: remove singleton values from templates → then shrink the shim (keep
  the tested inferred-`STATE_DIR` behavior until installed `/etc/proton` files
  are cleaned). Also delete the duplicate `QBITTORRENT_ENV_FILE` block in
  `proton_instance_init` (C) and the dead `${VAR:-default}` fallbacks for these
  paths in port-forward, sync, and healthcheck (C).
- [ ] **4.5 `VPN_TABLE==51820` rewrite / `QBT_VPN_RULE_PRIORITY` default (P).**
  Installer now reconciles both keys and the verifier requires them; the
  fallback in `proton-instance-common.sh` could become a hard error.
- [ ] **4.6 Policy-rule cleanup for rules nothing creates (P).** wg-up/wg-down
  delete priority-100 `fwmark` rules and `DOCKER_VPN_RULE_PRIORITY` (110) rules;
  the watcher does so every tick. `VPN_FWMARK` is read only by these deletes;
  `RULE_PRIORITY` is a legacy alias. Remove once every host is past migration
  (check `ip rule` on the host first).
- [x] **4.7 `proton-killswitch-reset.sh` legacy chains (P).** Removes
  `PROTON_INPUT`/`PROTON_OUTPUT`, which nothing creates since commit `937d876`.
  Keep only if upgraded hosts may still carry them.
- [x] **4.8 `Archive/` fallbacks (C).** `SCRIPT_DIR/..` helper fallback in
  `proton-killswitch-reset.sh` and `proton-qbt-dnat-cleanup.sh` existed only
  for running from `Archive/`. Remove.
- [x] **4.9 `proton-qbittorrent.env.example` (C).** Unreferenced near-duplicate
  of `proton-qbittorrent.env`. Delete.

Section 4 progress, 2026-09-23 (canonical Linux checkout, source-only, not
installed). Resolved: 4.1, 4.2, 4.3, 4.7, 4.8, and 4.9. 4.4 is partly done.
4.5 and 4.6 are deferred on host evidence.

- 4.1: the sync script has no DNAT refresh, `docker restart`, or
  `QBT_INTERNAL_PORT` path left. `QBT_PORT_APPLY_MODE=legacy-dnat` exits with
  an explicit error before any API, Docker, or nft call, and a mutation-checked
  test covers this. The "Legacy DNAT mode only" comments were wrong:
  `QBT_CONTAINER_NAME` and `QBT_NETWORK_NAME` are also used by the route
  scripts, so those keys stay. The docs were updated.
- 4.3: the helper and its test were removed. The IPv6 runbook now takes a
  rollout snapshot before running the installer, and names the seven scripts.
  With the helper gone, `docker-preflight` holds the only copy of the list.
- 4.4, done:
  - The singleton values were removed from the `proton-common.env`,
    `proton-port-forward.env`, and `proton-healthcheck.env` templates.
  - The installer no longer writes the singleton `qbittorrent.env` or
    `qbittorrent-port.env`, and its `--qb-*` flags were removed.
  - The singleton `proton-qbittorrent.env` template was deleted (4.9 deleted
    its `.example`). The per-instance example now carries the manual-stop keys.
  - The duplicate `QBITTORRENT_ENV_FILE` block was removed. So were the dead
    post-init path fallbacks in port-forward, sync, and both healthchecks, and
    the same fallbacks in wg-up, wg-down, and the watcher.
- 4.4, not done: shrinking the shim. On 2026-09-23 the installed
  `/etc/proton/proton-common.env` (dated Jul 23) still set `STATE_DIR`,
  `VPN_TABLE`, `VPN_INTERFACE`, and `SERVER_SELECTION_FILE`. The installed
  role env files still carried their singleton paths. The installer preserves
  those files, so the shim is required until they are cleaned by hand.
- 4.5 and 4.6 deferred on live evidence from 2026-09-23. `ip rule` showed a
  priority-110 rule, `from 192.168.96.8 lookup 51806`, which is prowlarr's
  table at the old `QBT_VPN_RULE_PRIORITY` fallback. The manifest priority is
  116, and the installed `proton-instance-common.sh` differed from source.
  The fallback and the 110 cleanup deletes are still reachable on this host.
  Re-check after installing and restarting.
- Correction, later on 2026-09-23: rule 110 is not a leftover of the old
  fallback. `/opt/mousehole/docker-compose.yml`, a separate host-network
  service with `NET_ADMIN`, adds
  `from 192.168.96.8/32 lookup 51806 priority 110` and
  `from 192.168.111.250/32 lookup 51806 priority 117` to route mousehole
  through prowlarr's tunnel.
  - Rule 117 is intentional: mousehole is pinned to 192.168.111.250 and must
    exit through prowlarr's tunnel.
  - Rule 110 hard-coded a Docker-assigned address. Before the 20:55 Docker
    restart, 192.168.96.8 belonged to whisparr's qBittorrent, which was
    therefore misrouted through prowlarr's tunnel. After the restart it
    belonged to the Sonarr app container.
  - At the operator's request, the three 192.168.96.8 lines were removed from
    the `mousehole-route` loop in `/opt/mousehole/docker-compose.yml`, outside
    this repo. The live rule and the helper recreate are left to the
    operator.
  - Commit `1ce8ae1` added a sweep that deleted every rule in an instance's
    table at an unowned priority. The operator chose "any source" after being
    told 117 had no known owner, which was wrong: no one had looked for rule
    owners outside this repo. The sweep conflicts with mousehole's
    intentional rules, so it was reverted.
  - Instance scripts again delete only the rules they create. 4.6 stays open.
    Any future cleanup must identify this project's own rules, not assume it
    owns the table.
- Finding, 2026-09-23: the installer restarted Docker.
  - `enable_and_start_services` ran `systemctl restart
    proton-killswitch.service`. The installer's `docker-proton-tunnels.conf`
    drop-in makes `docker.service` `Requires=` that unit, and systemd restarts
    every running unit that requires a restarted unit.
  - The 20:55 install therefore stopped Docker at 20:55:10 and started it
    again at 20:57:06, taking all five clients down together.
  - prowlarr and whisparr stayed exited, and their sync skipped them as
    manual stops.
  - The unit now has an `ExecReload` that re-runs the idempotent dispatcher.
    The installer reloads the unit when it is active and starts it otherwise,
    and never restarts it. A behavioral test checks both states, and it fails
    if the restart is put back.
  - The `Requires=` edge stays, so Docker still cannot run without the kill
    switch.
- 4.2 and 4.7 resolved later on 2026-09-23 from root checks on the live host:
  - `nft -a list chain ip proton_nat prerouting` failed with "No such file or
    directory". The chain does not exist; only `legacy-dnat` ever created it,
    and the kill switch creates only `postrouting`.
  - `iptables -S` showed no `PROTON_INPUT` or `PROTON_OUTPUT` chains.
  - The cleanup script, its test, the port-forward `ExecStop`, and the installer
    entry were removed. The unit test now asserts that the unit does not
    reference the script. The installer does not delete retired files, so an
    installed `/usr/local/bin/proton/proton-qbt-dnat-cleanup.sh` stays behind
    unused and can be removed by hand.
  - The reset script no longer removes `PROTON_INPUT`/`PROTON_OUTPUT`. It still
    removes `PROTON_DOCKER_FORWARD` and `PROTON_POSTROUTING`, which the
    iptables backend creates.

## 5. Duplication to consolidate

- [x] **5.1 Helpers copied across wg-up, wg-down, watcher (C).**
  `resolve_qbt_container_ip`/`ipv6`, `read_cached_*`, `persist_*`,
  `detect_lan_cidr`, `trim_field`, `normalize_*_rule_source`,
  `docker_fallback_vpn_routing_enabled`, `run_wg_quick`/`filter_wg_quick_stderr`,
  `resolved_dns_enabled`. Copies have drifted: wg-down's
  `normalize_ipv4_rule_source` skips validation the others do; the watcher's
  `resolve_qbt_container_ip` fails hard where the others fall back. Move into
  `proton-instance-common.sh` and add behavioral tests for the unified version.
- [x] **5.2 Kill-switch lock and interface list (C).**
  `proton-killswitch-nft.sh` hand-rolls `flock -w 30` on `killswitch.lock`
  instead of `proton_with_firewall_lock`; both backends hard-code the five
  `pv*` interfaces.
- [x] **5.3 `proton-port-forward-healthcheck.sh` (C).** Re-implements env
  existence/mode/owner checks and sourcing already done by
  `proton_instance_init`, and duplicates `qbt_webui_http_status`.
- [x] **5.4 Redundant wedge gates (P).** In the sync, zombie/persistent-D
  checks repeat right after `qbt_container_safe_for_recreate` on the same
  container, and self-heal calls `compose_container_is_wedged_for_recreate`
  twice (up to 4 D-state samplings). `tools/reconcile-qbittorrent-fleet.sh`
  repeats checks `qbt_fleet_preflight` already ran. Keep exactly one shared
  gate per path — the gate itself is an `AGENTS.md` invariant; only the copies
  go. Preserve the no-published-ports refusal and the LWP error text a test
  greps for.
- [x] **5.5 Other (C).** `compose_container_ref_all` vs `compose_container_ref`
  differ only by `--all`; `once` mode in `proton-port-forward-safe.sh` copies
  the loop body and calls `load_selected_server` twice; the seven-script
  firewall list appears in `deploy-live-ipv6-firewall.sh`,
  `proton-ipv6-rollout.sh`, and both of their tests; `proton-ipv6-rollout.sh`
  hard-codes `starr_network` in three places instead of `DOCKER_NETWORK_NAME`
  and checks a meaningless sibling `archive` directory.
- [x] **5.6 Server-manager selection loop (P, low).** Loop-invariant
  `normalize_dns_csv` and `port_forward_allowlist_active` recomputed per
  candidate; configs parsed with several passes. Possible bug worth a separate
  look: retries share one `selection_deadline`, so a slow first pass can leave
  retries no time and end with "No pools available" despite candidates.

Section 5 resolved, 2026-09-23 (canonical Linux checkout, source-only, not
installed). Every item has behavioral tests, and each new test was
mutation-checked: it fails when the change is reverted or the code is broken.

- 5.1: the fourteen helpers now live once in `proton-instance-common.sh`
  under their existing names. Each drifted copy was settled on one version:
  - Rule-source normalization validates addresses everywhere. wg-down used
    to accept any cached value unchecked.
  - Container address lookup uses only `QBT_NETWORK_NAME` when it is set, as
    the watcher did. wg-up and wg-down used to fall back to another network's
    address; they now fall back to the cached address instead.
  - `run_wg_quick` reads `WG_QUICK_TIMEOUT_SECONDS`, which each caller sets:
    45 s for start, 90 s for stop, as before. It secures only runtime configs.
- 5.2: both backends take the firewall lock through
  `proton_firewall_lock_acquire`, which `proton_with_firewall_lock` also
  uses. The iptables backend now sources the common library and builds its
  interface list from `proton_allowed_instances`. The grep-only lock test was
  replaced with a contention test for both backends.
- 5.3: the preflight relies on `proton_instance_init` for the env checks and
  uses the shared Web UI probe. The status list now lives only in
  `qbt_webui_status_reachable`, which `proton-healthcheck.sh` uses too. The
  role env path accepts the same `PROTON_PORT_FORWARD_ENV` override as the
  loop, and the script has its first behavioral tests.
- 5.4: `qbt_container_safe_for_recreate` is the only zombie/persistent-D gate.
  - The sync's separate D-state sampler and zombie probe are gone.
  - The self-heal pre-check is gone. `recreate_qbt_service_compose` now
    writes the port artifact only after the gate passes, so a refusal still
    leaves the artifact unchanged.
  - The reconciler's repeated checks are gone. It keeps its absent and
    healthy-baseline checks, which the preflight does not make.
  - The gate sets `QBT_RECREATE_REFUSAL`, and every refusal message names it,
    including the persistent-D LWP list. The no-published-ports refusal is
    unchanged. The reconciler grep test became a behavioral test of the fleet
    preflight.
- 5.5:
  - `compose_container_ref` had already been folded into its `--all` form
    under 2.7.
  - `deploy-live-ipv6-firewall.sh` went under 4.3, so the firewall list now
    appears only in `docker_preflight` and its test fixture.
  - `once` and `loop` share `renew_mapping`, which loads the selected server
    once per renewal.
  - `proton-ipv6-rollout.sh` uses `DOCKER_NETWORK_NAME` everywhere. It
    reports `/archive` as absent or empty and no longer checks a sibling
    `archive` directory.
- 5.6: the proven-only constraint and the normalized expected DNS are computed
  once per pass, and each config's `Endpoint` line is read once.
  - The retry concern was real in a narrow case: when the budget expired
    before any candidate qualified, both retries stopped at once and reported
    "No pools available".
  - That case now fails with its own message. Retries still share the budget
    by design, because the budget bounds WireGuard start.

## 6. Tests

- [ ] **6.1 Missing behavioral coverage (C).**
  `tools/reconcile-qbittorrent-fleet.sh` (fleet D-state/zombie gate) is covered
  only by string greps; `nas-network-online.sh` only by greps;
  `proton-killswitch-dispatch.sh` has no test. Add PATH-stubbed behavioral
  tests.
- [ ] **6.2 Healthcheck defaults (P — verify).** `CHECK_INTERVAL`,
  `MIN_COMBINED_SPEED_BPS`, `MAX_LOW_SPEED_CHECKS` reportedly have no built-in
  defaults while the env file is optional (`EnvironmentFile=-` and
  `proton_source_env_if_present`); under `set -u` a missing
  `/etc/proton/proton-healthcheck.env` would crash the loop. Add defaults
  matching the template, plus a test.
- [ ] **6.3 Shared stubs (C).** `systemd-cat` stub recreated in ~10 files;
  `flock`/`nft`/`ip`/`docker` stubs repeated; `write_body` duplicated in
  `proton-qbittorrent-auth.bats` and the sync helper; lease writers duplicated.
  Create `tests/common-stubs.bash` loaded with `load`.
- [ ] **6.4 Instance tests (C).** `proton-instances.bats` and
  `proton-instance-common.bats` have near-identical `setup()` and overlapping
  cases; fixture ports contradict the manifest (sonarr 8083/prowlarr 8085 vs
  TSV 8084/8082). Merge or share a TSV-driven helper.
- [ ] **6.5 Grep-only installer/unit tests (C).** Most of
  `installer-instance-layout.bats` and `systemd-units.bats` assert source
  strings. Convert key ones (e.g. `upsert_instance_env_value`, port artifact
  normalization) to behavioral tests.
- [ ] **6.6 `docs-archive-contract.bats` (C).** ~45 `grep -Fq` lines pin exact
  prose across seven documents, including a dated status note and the same
  kernel/`cache=none` facts in five places — enforcing duplication `AGENTS.md`
  says to avoid. Keep only true invariants, each pinned in its owning doc.
- [ ] **6.7 Fixed sleeps (C, low).** `proton-port-forward.bats` (`sleep 1` ×2),
  `proton-route-lock.bats` (`sleep 1`), `proton-killswitch-contract.bats`
  (0.2 s). Replace with marker files or polling.
- [ ] **6.8 `all-scripts.bats` (C).** `find . -name '*.sh'` walks `bats-core/`,
  `Archive/`, `.git/`. Use `git ls-files '*.sh'` or drop it (duplicates
  `bash -n` validation).

## 7. Documentation and instructions

- [ ] **7.1 `Archive/README.md` (C).** Still lists the three moved scripts,
  says the installer installs them "from this directory", and claims an
  ignore-rule exemption `.gitignore` no longer has.
- [ ] **7.2 Validation commands in four places (C).** `AGENTS.md`,
  `README.md`, `CLAUDE.md`, `qbittorrent-fleet-changes.md` differ (`AGENTS.md`
  lacks `-x`, `shfmt`, timeout). Make `AGENTS.md` the owner and link.
- [ ] **7.3 Storage/kernel baseline in five places (C).** `README.md`,
  `docs/README.md`, `AGENTS.md`, fleet contract, wedge runbook. Keep in the
  fleet contract and wedge runbook; link elsewhere (update 6.6 together).
- [ ] **7.4 Dated "not deployed" notes in seven places (P).** `README.md`,
  `docs/README.md`, fleet contract, port-sync runbook, fleet-changes runbook.
  Consolidate into one dated status entry; add a dated update after the next
  authorized install.
- [ ] **7.5 Template/doc mismatches (C/P).** `proton-common.env` pins
  `KILLSWITCH_BACKEND=nftables` while docs describe `auto` (the script
  default); `WG_EXPECTED_DNS` template includes an IPv6 resolver while script
  default and docs show only `10.2.0.1`; evicted-server comment says the pool
  config is deleted, but code and runbook keep it; `host-routing-and-tunnels.md`
  lists `1.1.1.1`/`9.9.9.9` as required resolvers that nothing references.
- [ ] **7.6 Undocumented tunables (P).** `LAN_IF`/`LAN_CIDR`,
  `DOCKER_FALLBACK_VPN_ROUTING`, `NATPMP_TIMEOUT_SECONDS`,
  `QBT_DSTATE_SAMPLES`/`QBT_DSTATE_DELAY`, `NAS_HOST`/`NAS_PORT`/`NAS_WAIT_SECONDS`
  (`/etc/default/nas-network-online` has no template; `nas-network-online.sh`
  hard-codes the NAS IP). Add commented template entries.
- [ ] **7.7 README exception (C).** README says installer `SCRIPTS` plus units
  define installed entrypoints; `deploy-live-ipv6-firewall.sh` is an
  intentional exception (moot if 4.3 lands).
- [ ] **7.8 Instance list duplication (P).** `docker-proton-tunnels.conf` and
  `tests/systemd-units.bats` hard-code the five instances in addition to the
  manifest; consider generating the drop-in from the TSV in the installer.
- [ ] **7.9 Repo config (P).** `.gitignore` `.vscode-root/` matches nothing;
  `.gitattributes` `*.lock.yml` rule and gh-aw scaffolding serve no existing
  workflow; `actions/checkout` is v4 in `lint-and-test.yml` but v6 in
  `copilot-setup-steps.yml`; `.github/prompts/resilience-audit.prompt.md`
  "do not touch Archive/" wording predates the move.
- [ ] **7.10 Fleet-verify source parity (C).** `tools/verify-qbittorrent-fleet.sh`
  derives `PROJECT_DIR` from `SCRIPT_DIR/..`; installed as
  `/usr/local/bin/proton/proton-qbt-fleet-verify.sh` that is `/usr/local/bin`,
  so the source-vs-deployed `cmp` of the Compose policy and manifest is
  silently skipped. Default to `/usr/local/bin/proton_project` when installed,
  or fail when the source is unreadable. (Behavior fix, listed here because it
  affects documented verification claims.)

## Deployment and rollback

This record changes no runtime behavior. Items in sections 2, 4, and 5 do;
deploy them only after full validation, with `install-proton-systemd.sh` under
administrator approval, then the fleet gates in `AGENTS.md` → Validation
(`--recreate` checks runtime; check its exit status). Roll back by reinstalling
the previous source revision the same way.
