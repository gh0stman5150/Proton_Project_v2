#!/usr/bin/env bats

@test "all tracked shell scripts have a shebang and pass bash -n syntax check" {
  cd "$BATS_TEST_DIRNAME/.."
  failed=0
  checked=0
  while IFS= read -r -d '' script; do
    checked=$((checked + 1))
    [ -f "$script" ] || { echo "MISSING: $script"; failed=1; continue; }
    first=$(sed -n '1p' "$script" 2>/dev/null || true)
    if [ "${first:0:2}" != "#!" ]; then
      echo "NO_SHEBANG: $script"
      failed=1
      continue
    fi
    run bash -n "$script"
    if [ "$status" -ne 0 ]; then
      echo "SYNTAX_ERROR in $script: $output"
      failed=1
    fi
  done < <(git ls-files -z '*.sh')

  # An empty listing (for example outside a git checkout) must not pass.
  [ "$checked" -gt 0 ]
  [ "$failed" -eq 0 ]
}
