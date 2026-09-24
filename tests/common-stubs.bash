# shellcheck shell=bash
# Shared PATH stubs and fixtures. Load with `load common-stubs` and call the
# stub helpers after TMPBIN exists.

# stub_command NAME [BODY]: an executable bash stub in TMPBIN. BODY is read
# from stdin when omitted, so a quoted heredoc can supply longer stubs.
stub_command() {
  local name="$1"
  {
    printf '#!/usr/bin/env bash\n'
    if (($# > 1)); then
      printf '%s\n' "$2"
    else
      cat
    fi
  } > "$TMPBIN/$name"
  chmod +x "$TMPBIN/$name"
}

# stub_systemd_cat [discard|stdout|LOG]: the journal logger. LOG may be a
# literal path or a quoted variable reference such as '$SYSTEMD_LOG'.
stub_systemd_cat() {
  case "${1:-discard}" in
  discard) stub_command systemd-cat 'cat - >/dev/null' ;;
  stdout) stub_command systemd-cat 'cat -' ;;
  *) stub_command systemd-cat "cat - >> \"$1\"" ;;
  esac
}

# stub_curl: a curl stub whose request handling is read from stdin. The
# prelude finds any `-o FILE` and defines write_body, which writes a response
# body there or to stdout as curl would.
stub_curl() {
  {
    cat <<'EOF'
#!/usr/bin/env bash
output_file=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "-o" ]]; then
    next_index=$((i + 1))
    output_file="${!next_index}"
  fi
done

write_body() {
  if [[ -n "$output_file" ]]; then
    printf '%s' "$1" > "$output_file"
  else
    printf '%s' "$1"
  fi
}

EOF
    cat
  } > "$TMPBIN/curl"
  chmod +x "$TMPBIN/curl"
}

# write_lease_fixture STATE_FILE PORT [IP]: a current NAT-PMP lease for this
# boot, bound to a fixture tunnel generation beside STATE_FILE. Callers may
# append further keys.
write_lease_fixture() {
  local state_file="$1"
  printf 'fixture-generation\n' > "${state_file%/*}/tunnel-generation"
  cat > "$state_file" <<EOF
CURRENT_PORT=$2
CURRENT_IP=${3:-10.4.0.2}
LEASE_EXPIRES_AT=$(( $(date +%s) + 600 ))
LEASE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
LEASE_GENERATION=fixture-generation
EOF
}
