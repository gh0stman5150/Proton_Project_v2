# Runbook: server pool and latency selection

Related: [host routing and tunnels](../architecture/host-routing-and-tunnels.md),
[port synchronization](qbittorrent-port-sync.md).

## Pool selection

If `/etc/wireguard/proton-pool` contains one or more `*.conf` files, the active path treats that directory as a rotation pool. Reconnect or bad node recovery may select the lowest latency candidate by probing the endpoint IP from each config.

The selector stores the active choice in `/run/proton/<instance>/current-server.env` and tracks cooldowns in `/run/proton/bad-servers.tsv`. It uses hysteresis so the current server is kept unless a replacement is meaningfully better or the current server is degraded.

When `PORT_FORWARD_REQUIRED=on`, the pool also learns which profiles have actually returned a Proton forwarded port. Successful profiles are recorded in `PF_CAPABLE_PROFILES_FILE`, failed profiles can be recorded in `PF_INCAPABLE_PROFILES_FILE`, and the selector effectively treats the pool as three categories:

1. `proven-good` which are in `PF_CAPABLE_PROFILES_FILE`
2. `unproven` which are in neither file yet
3. `port-forward incapable` which are in `PF_INCAPABLE_PROFILES_FILE`

`port-forward incapable` remains a hard exclusion until the profile is proven again or the incapable state is reset. When the proven-good set is non-empty, the selector prefers those proven-good nodes first. If every proven-good node is temporarily cooling down or otherwise unavailable, the selector can temporarily widen to healthy unproven nodes instead of immediately recycling a cooling-down proven-good node.

## Transient failures versus quarantine

The port-forward loop distinguishes a temporary NAT-PMP hiccup from a genuinely port-forward incapable server:

1. When a **proven-good** server (one already in `PF_CAPABLE_PROFILES_FILE`) hits `MAX_FAILURES`, the failure is treated as transient. The tunnel is kept and retried in place so the forwarded port stays stable and qBittorrent's published port -- and therefore its container -- is not recreated. Only after `PROVEN_TRANSIENT_MAX_KEEPS` consecutive transient windows without a successful port does it fall back to a full reconnect.
2. When an **unproven** server hits `MAX_FAILURES`, the port-forward loop records a consecutive incapability strike via `proton-server-manager.sh mark-incapable-attempt` and reconnects to a different server. Strikes accumulate in `/run/proton/pf-incapable-strikes.tsv` and reset the instant the server proves it can forward a port (`mark-capable`).
3. Once an unproven server accumulates `PF_INCAPABLE_STRIKE_THRESHOLD` consecutive strikes (default 3), the server manager quarantines it in `PF_INCAPABLE_PROFILES_FILE`. Its pool config remains in `WG_POOL_DIR` for review. A proven-good server is not quarantined by transient strikes; it is only cooled down.

This avoids unnecessary rotation during transient failures without deleting
operator-managed pool configurations. Claims reserve profiles, not endpoint IPs
or numeric ports. Interrupted selection publication may retain a conservative
claim until retry or expiry; do not bypass it by deleting shared state.

The port-forward service must be able to write both `/etc/proton` for the learned PF-capable/incapable lists and the directory containing `QBT_PORT_ENV_FILE` for Compose port-artifact updates.

By default the selector lints each candidate before selection. It rejects configs that contain `PreUp`, `PostUp`, `PreDown`, `PostDown`, or `SaveConfig`, and it expects `DNS` to match `WG_EXPECTED_DNS` unless `WG_LINT_ALLOW_MISSING_DNS=on`.

Useful knobs:

1. `WG_POOL_DIR=/etc/wireguard/proton-pool`
2. `SERVER_POOL_ENABLED=auto`
3. `BAD_SERVER_COOLDOWN=900`
4. `SERVER_SWITCH_MIN_IMPROVEMENT_MS=10`
5. `SERVER_SWITCH_DEGRADED_LATENCY_MS=75`
6. `PING_TIMEOUT_SECONDS=1`
7. `PING_COUNT=1`
8. `SERVER_POOL_STRICT_LINT=on`
9. `WG_EXPECTED_DNS=10.2.0.1` (script default; the template sets `10.2.0.1,2a07:b944::2:1`, and the IPv6 entry applies only with WireGuard IPv6 enabled)
10. `WG_LINT_ALLOW_MISSING_DNS=off`
11. `PORT_FORWARD_REQUIRED=on`
12. `PF_CAPABLE_PROFILES_FILE=/etc/proton/pf-capable-profiles.tsv`
13. `PF_INCAPABLE_PROFILES_FILE=/etc/proton/pf-incapable-profiles.tsv`
14. `PF_INCAPABLE_STRIKES_FILE=/run/proton/pf-incapable-strikes.tsv`
15. `PF_INCAPABLE_STRIKE_THRESHOLD=3`
16. `PROVEN_TRANSIENT_MAX_KEEPS=5` (set in `proton-port-forward.env`)

Manual helpers:

1. `proton-server-manager.sh select`
2. `proton-server-manager.sh current`
3. `proton-server-manager.sh mark-bad <profile> <reason>`
4. `proton-server-manager.sh show-bad`
5. `proton-server-manager.sh reset-bad`
6. `proton-server-manager.sh mark-capable <profile> <port>`
7. `proton-server-manager.sh mark-incapable <profile> <reason>`
8. `proton-server-manager.sh mark-incapable-attempt <profile> <reason>`
9. `proton-server-manager.sh show-capable`
10. `proton-server-manager.sh show-incapable`
11. `proton-server-manager.sh show-incapable-strikes`
12. `proton-server-manager.sh reset-capable`
13. `proton-server-manager.sh reset-incapable`
14. `proton-server-manager.sh reset-incapable-strikes`

Any server rotation logic must preserve the repository routing rules, kill switch behavior, qBittorrent port synchronization, and DNS policy after reconnect.
