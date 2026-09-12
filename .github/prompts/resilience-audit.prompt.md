Before doing anything else, read AGENTS.md in full — it is the authoritative 
source of truth for this repo's conventions, safety boundaries, and the 
qBittorrent fleet contract. Do not propose anything that conflicts with it 
(e.g. do not introduce a VPN sidecar container, do not add torrent queueing 
or upload/seeding limits, do not bypass the lock files under /run/proton, 
do not touch Archive/ as if it's dead code).

If any referenced file or README.md's "Active Service Path" list is missing,
or if the referenced documents contradict each other, stop and report the
discrepancy rather than inferring the intended behavior. AGENTS.md takes
precedence over README.md and the runbooks.

Goal: find and fix the specific causes of fragility when systemd services 
restart or qBittorrent containers are recreated, without changing the 
architecture described in AGENTS.md and README.md.

## 1. Map the actual failure surface first
Trace the real dependency graph across the *.service units (After/Requires/
PartOf/Wants), not an assumed one. For each unit:
- What does it assume is already true when it starts (state files in 
  /run/proton, env files in /etc/proton, a live WireGuard interface, a 
  running Docker daemon)?
- What happens if that assumption is false because a *different* unit was 
  the one that got restarted or the container was recreated out of band 
  (e.g. `docker compose up -d` on one instance without going through 
  proton-qbt-allocate-and-sync.sh)?
- Where is state written to /run/proton (tmpfs, cleared on reboot) vs 
  /etc/proton (persistent) — and is anything that should survive a restart 
  currently living in the wrong place?

## 2. Audit idempotency and self-healing, not just "does it error"
This repo already has *-safe.sh wrappers and a docker-network-watcher meant 
to reconcile drift. For each entrypoint in the "Active Service Path" list 
in README.md:
- Confirm it's actually idempotent if re-run against state it already 
  applied (re-running proton-wg-up-safe.sh when the tunnel is already up, 
  re-running proton-port-forward-safe.sh when the DNAT rule already exists).
- Confirm cleanup on ExecStop / SIGTERM correctly reverses only what that 
  instance's ExecStart applied — check for cross-instance blast radius, 
  since a bad ExecStop in a PartOf=proton-wg@%i.service chain can cascade.
- Where a lock file is used (policy-routing.lock, killswitch.lock), verify 
  what happens to a process that dies while holding it — stale lock 
  detection, not just acquisition.

## 3. Reconcile against the incident/runbook history
Cross-check docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md 
and docs/runbooks/qbittorrent-wedge-recovery.md against current code: has 
anything regressed since that incident? Confirm the wedge-detection logic 
(D-state sampling, not single-snapshot) is still consistently applied 
anywhere containers get recreated, not just in the one script it was 
originally added to.

## 4. Extend the existing Bats suite — don't invent a new test framework
You may add and run isolated Bats tests before my go-ahead; keep host operations
mocked. Production script and unit edits require my go-ahead under section 5.
Add cases to tests/ (matching the existing PATH-stub/fixture style already 
used, e.g. in proton-wg-up.bats) for:
- A unit restarting while a dependent unit's state file is missing/stale
- A container recreated directly via Docker, bypassing 
  proton-qbt-allocate-and-sync.sh, then reconciled by
  tools/reconcile-qbittorrent-fleet.sh (installed as proton-qbt-fleet-reconcile.sh)
- Re-running each *-safe.sh entrypoint twice in a row with no state change
- A killed process leaving a stale lock in /run/proton
Run `shfmt` and `shellcheck -x` per the CI config before considering any 
script fixed.

## 5. Report before patching
For each fragility found, tell me: which file, what breaks, why (state 
location, missing idempotency check, ordering assumption), and the minimal 
fix — then wait for my go-ahead before editing production scripts or units.
The isolated test additions in section 4 are allowed before that approval.
Deployment and live fleet/container recreation still require explicit
authorization under AGENTS.md.