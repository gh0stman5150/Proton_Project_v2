# Archived scripts

This directory holds six legacy helpers that nothing installs, no unit runs,
and no test covers. They are git-ignored and exist only on the host checkout;
this README is the only tracked file here (`.gitignore`: `Archive/*` with
`!Archive/README.md`). This source directory is distinct from the external
`/archive` location used for historical incident comparisons.

| Script | Role |
| --- | --- |
| `deploy-live-healthcheck.sh` | Ad hoc healthcheck deployment and service restart |
| `deploy-live-wg-filter.sh` | Ad hoc WireGuard script deployment and service restart |
| `proton-runtime-refresh.sh` | Legacy runtime-config refresh; can expose WireGuard secrets and ignores restart failures |
| `proton-instances-normalize.sh` | Legacy instance normalization from shared templates |
| `proton-wg-pool-dedupe.sh` | Manual pool-profile deduplication |
| `verify_serialized_sync.sh` | Manual allocation and synchronization; can mutate runtime state despite its name |

Archiving changes source location, not operational authorization. The safety
requirements in the root `AGENTS.md` still apply. Do not run these scripts
merely to inspect them, and prefer the canonical installer and fleet runbooks
for maintenance. Relocation does not repair the helpers' behavioral
limitations.

## History

- 2026-09-10: nine scripts were moved here at the operator's request.
- 2026-09-23: three were found in use and returned to the repository root.
  `proton-killswitch-reset.sh` remains there and is installed to
  `/usr/local/bin/proton`. `proton-qbt-dnat-cleanup.sh` was later removed with
  the retired legacy-DNAT mode (code audit 4.2), and
  `deploy-live-ipv6-firewall.sh` was removed in favor of
  `proton-ipv6-rollout.sh snapshot`/`rollback` (code audit 4.3; see
  `docs/runbooks/ipv6-rollout.md`). Existing snapshots under
  `/var/backups/proton-ipv6-firewall` were not touched.
