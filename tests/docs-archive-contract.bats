#!/usr/bin/env bats

# Safety invariants are pinned once, in AGENTS.md, which owns them. Other
# documents link to it rather than restating these sentences, so they are not
# pinned here. Historical incident prose and dated status notes are evidence,
# not invariants, and are deliberately left unpinned.

@test "AGENTS pins the fleet safety invariants" {
  local invariant
  while IFS= read -r invariant; do
    if ! grep -Fq -- "$invariant" AGENTS.md; then
      echo "AGENTS.md no longer states: $invariant"
      return 1
    fi
  done <<'EOF'
The canonical source repository is `/usr/local/bin/proton_project`.
Treat `/opt/proton_project_work` as a non-authoritative working copy that may be stale.
Never edit installed copies directly
If `/archive` is absent or empty, say so explicitly and proceed without archive-based root-cause claims.
Chain dependent activation commands with `&&`.
Keep uploading and seeding enabled.
Forced fleet sync waits for the lock and fails on timeout
A single `D`-state snapshot can be normal transient CIFS I/O.
Only the same task remaining in `D` across samples is a persistent wedge.
never escalate through signals/Docker cleanup as a repair
do not call any specific kernel version the fix without exact patch provenance
`cache=none` on `/mnt/data` is the active fleet-wide mitigation for all five clients
Local incomplete storage is not capacity-safe.
EOF
}

@test "copilot instructions point to the AGENTS authority" {
  grep -Fq 'The authoritative project instructions are in `../AGENTS.md`.' .github/copilot-instructions.md
}

@test "every document in the AGENTS documentation map exists" {
  local ref path checked=0
  while IFS= read -r ref; do
    # Expand the {a,b} shorthand; refs are limited to plain path characters.
    [[ "$ref" =~ ^[A-Za-z0-9/_.,{}-]+$ ]] || { echo "unexpected reference: $ref"; return 1; }
    for path in $(eval "printf '%s\n' $ref"); do
      checked=$((checked + 1))
      [[ -f "$path" ]] || { echo "missing: $path"; return 1; }
    done
  done < <(sed -n '/^## Documentation Map$/,/^## /p' AGENTS.md | grep -o '`docs/[^`]*`' | tr -d '`')
  [ "$checked" -ge 5 ]
}
