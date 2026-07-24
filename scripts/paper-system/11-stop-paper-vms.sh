#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}

stop_one() {
	local name=$1
	local pidfile=$WS/pids/$name.pid
	local pid

	if [[ ! -f "$pidfile" ]]; then
		echo "$name not running"
		return
	fi
	pid=$(cat "$pidfile")
	if ! kill -0 "$pid" 2>/dev/null; then
		rm -f "$pidfile"
		echo "$name stale pidfile removed"
		return
	fi
	kill "$pid"
	for _ in $(seq 1 30); do
		if ! kill -0 "$pid" 2>/dev/null; then
			rm -f "$pidfile"
			echo "stopped $name"
			return
		fi
		sleep 1
	done
	kill -9 "$pid"
	rm -f "$pidfile"
	echo "forced $name"
}

case "${1:-all}" in
all)
	stop_one paper-vm0
	stop_one paper-vm1
	;;
vm0) stop_one paper-vm0 ;;
vm1) stop_one paper-vm1 ;;
*)
	echo "usage: $0 [all|vm0|vm1]" >&2
	exit 2
	;;
esac
