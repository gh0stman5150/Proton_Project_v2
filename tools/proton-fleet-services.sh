#!/usr/bin/env bash
set -euo pipefail

SYSTEMCTL="${PROTON_SYSTEMCTL:-systemctl}"
SETTLE_SECONDS="${PROTON_SERVICES_SETTLE_SECONDS:-5}"
KILLSWITCH_UNIT="proton-killswitch.service"
MANAGED_INSTANCES=(lidarr prowlarr radarr sonarr whisparr)
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: proton-fleet-services.sh [--dry-run] start|stop|restart|status [INSTANCE...]

  start    Ensure the kill switch is active, then bring up each instance in
           dependency order (wg, docker-watch, port-forward, healthcheck) and
           confirm every unit is active before moving to the next instance.
  stop     Stop each instance in reverse order (healthcheck, port-forward,
           docker-watch, wg). The kill switch is never stopped, so containers
           stay blocked from the WAN while their tunnel is down.
  restart  Stop then start each instance, one instance at a time.
  status   Show the kill switch and per-instance unit states (read-only).

INSTANCE defaults to all five: lidarr prowlarr radarr sonarr whisparr.
Instances are handled sequentially; the first failure stops the run so the
remaining instances are left untouched.

  --dry-run  Print the systemctl commands without running them.
EOF
}

log() {
	printf '%s\n' "$*"
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

run_systemctl() {
	if ((DRY_RUN)); then
		printf 'DRY-RUN: %s %s\n' "$SYSTEMCTL" "$*"
		return 0
	fi
	"$SYSTEMCTL" "$@"
}

instance_units_start_order() {
	local instance="$1"
	printf '%s\n' \
		"proton-wg@${instance}.service" \
		"proton-docker-watch@${instance}.service" \
		"proton-port-forward@${instance}.service" \
		"proton-healthcheck@${instance}.service"
}

instance_units_stop_order() {
	local instance="$1"
	printf '%s\n' \
		"proton-healthcheck@${instance}.service" \
		"proton-port-forward@${instance}.service" \
		"proton-docker-watch@${instance}.service" \
		"proton-wg@${instance}.service"
}

ensure_killswitch() {
	if ((DRY_RUN)); then
		run_systemctl start "$KILLSWITCH_UNIT"
		return 0
	fi
	if ! "$SYSTEMCTL" is-active --quiet "$KILLSWITCH_UNIT"; then
		log "Starting $KILLSWITCH_UNIT"
		"$SYSTEMCTL" reset-failed "$KILLSWITCH_UNIT" >/dev/null 2>&1 || true
		"$SYSTEMCTL" start "$KILLSWITCH_UNIT" ||
			die "$KILLSWITCH_UNIT failed to start; no tunnel was started (journalctl -u $KILLSWITCH_UNIT)"
	fi
	"$SYSTEMCTL" is-active --quiet "$KILLSWITCH_UNIT" ||
		die "$KILLSWITCH_UNIT is not active; no tunnel was started"
}

start_instance() {
	local instance="$1" unit
	local -a units

	mapfile -t units < <(instance_units_start_order "$instance")
	log "Starting $instance"
	run_systemctl reset-failed "${units[@]}" >/dev/null 2>&1 || true
	for unit in "${units[@]}"; do
		run_systemctl start "$unit" ||
			die "$unit failed to start; later units and instances were not started (journalctl -u $unit)"
	done

	((DRY_RUN)) && return 0
	sleep "$SETTLE_SECONDS"
	for unit in "${units[@]}"; do
		"$SYSTEMCTL" is-active --quiet "$unit" ||
			die "$unit is not active ${SETTLE_SECONDS}s after start; later instances were not started (journalctl -u $unit)"
	done
	log "$instance is up"
}

stop_instance() {
	local instance="$1" unit

	log "Stopping $instance"
	while IFS= read -r unit; do
		run_systemctl stop "$unit" ||
			die "$unit failed to stop; later units and instances were not stopped (journalctl -u $unit)"
	done < <(instance_units_stop_order "$instance")
	log "$instance is stopped"
}

show_status() {
	local instance unit state
	local -a units=("$KILLSWITCH_UNIT")

	for instance in "$@"; do
		mapfile -t -O "${#units[@]}" units < <(instance_units_start_order "$instance")
	done
	for unit in "${units[@]}"; do
		state="$("$SYSTEMCTL" is-active "$unit" 2>/dev/null || true)"
		printf '%-40s %s\n' "$unit" "${state:-unknown}"
	done
}

validate_instance() {
	local candidate="$1" instance

	for instance in "${MANAGED_INSTANCES[@]}"; do
		[[ "$candidate" == "$instance" ]] && return 0
	done
	die "Unknown instance '$candidate' (expected one of: ${MANAGED_INSTANCES[*]})"
}

if [[ "${1:-}" == "--dry-run" ]]; then
	DRY_RUN=1
	shift
fi

action="${1:-}"
case "$action" in
start | stop | restart | status) shift ;;
--help | -h)
	usage
	exit 0
	;;
*)
	usage >&2
	exit 2
	;;
esac

if (($# == 0)); then
	set -- "${MANAGED_INSTANCES[@]}"
fi
for instance in "$@"; do
	validate_instance "$instance"
done

[[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] || die "PROTON_SERVICES_SETTLE_SECONDS must be a non-negative integer"

if [[ "$action" == status ]]; then
	show_status "$@"
	exit 0
fi

if ((!DRY_RUN && EUID != 0)); then
	die "$action must run as root (or use --dry-run)"
fi

case "$action" in
start)
	ensure_killswitch
	for instance in "$@"; do
		start_instance "$instance"
	done
	;;
stop)
	for instance in "$@"; do
		stop_instance "$instance"
	done
	;;
restart)
	ensure_killswitch
	for instance in "$@"; do
		stop_instance "$instance"
		start_instance "$instance"
	done
	;;
esac

log "Done: $action ${*}"
