# Archived scripts

These nine scripts were moved here on 2026-09-10 at the operator's request.
This source directory is distinct from the external `/archive` location used
for historical incident comparisons.

| Script | Role |
| --- | --- |
| `deploy-live-healthcheck.sh` | Ad hoc healthcheck deployment and service restart |
| `deploy-live-wg-filter.sh` | Ad hoc WireGuard script deployment and service restart |
| `proton-runtime-refresh.sh` | Legacy runtime-config refresh; can expose WireGuard secrets and ignores restart failures |
| `proton-instances-normalize.sh` | Legacy instance normalization from shared templates |
| `proton-wg-pool-dedupe.sh` | Manual pool-profile deduplication |
| `verify_serialized_sync.sh` | Manual allocation and synchronization with verification |
| `proton-killswitch-reset.sh` | Installed manual firewall reset utility |
| `deploy-live-ipv6-firewall.sh` | Documented IPv6 bundle deployment and rollback helper |
| `proton-qbt-dnat-cleanup.sh` | Installed port-forward `ExecStop` and legacy-DNAT cleanup |

Archiving changes source location, not operational authorization. Existing
runtime and deployment safety requirements in the root `AGENTS.md` still apply.
Do not run these scripts merely to inspect them.

The installer continues to install `proton-killswitch-reset.sh` and
`proton-qbt-dnat-cleanup.sh` from this directory to their existing flat paths
under `/usr/local/bin/proton`. Units continue to use those installed paths.
The source synchronizer, IPv6 deployment helper and preflight account for the
new source layout. No installed production files were changed by this move.

Prefer the canonical installer and fleet runbooks for normal maintenance.
Relocation does not repair the historical helpers' behavioral limitations.

Source update, 2026-09-11: the installed reset and DNAT cleanup sources now share
the host firewall lock and fail on inspection or mutation errors. DNAT cleanup
deletes only exact owning-instance handles in one transaction. Reset removes
Proton filter protection and owned masquerade rules without deleting shared NAT
tables, DNAT, foreign rules, or changing host default policies. Reset remains a
disruptive fleet operation requiring authorization. The IPv6 copy/rollback bundle
includes `proton-instance-common.sh`, which its firewall/lifecycle callers require.
Older snapshots without that helper are incomplete for the updated bundle.

These sources, the bundle helper, and this README are explicitly exempted from
the archive ignore rule so reviewed changes are visible to Git. They remain
unstaged until explicitly added. Fixture and isolated network-namespace tests do
not establish installation provenance or live-host safety; no deployment was
performed as part of this update.
