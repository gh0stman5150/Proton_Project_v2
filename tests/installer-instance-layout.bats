#!/usr/bin/env bats

@test "installer bundle includes instance helper and templated units" {
  grep -Fq 'proton-instance-common.sh' install-proton-systemd.sh
  grep -Fq 'proton-wg@.service' install-proton-systemd.sh
  grep -Fq 'proton-port-forward@.service' install-proton-systemd.sh
  grep -Fq 'proton-healthcheck@.service' install-proton-systemd.sh
  grep -Fq 'proton-docker-watch@.service' install-proton-systemd.sh
}

@test "installer creates instance examples and preserves real configs" {
  grep -Fq '${ETC_PROTON_DIR}/instances/${instance}' install-proton-systemd.sh
  grep -Fq 'proton.env.example' install-proton-systemd.sh
  grep -Fq 'qbittorrent.env.example' install-proton-systemd.sh
  grep -Fq 'Preserved ${instance_dir}/${real_config}' install-proton-systemd.sh
  grep -Fq 'chmod 0600 "${instance_dir}/${real_config}"' install-proton-systemd.sh
}
