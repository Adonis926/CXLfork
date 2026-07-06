#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}

stop_one() {
	local name=$1
	local pidfile=$2
	if [[ ! -f "$pidfile" ]]; then
		echo "$name not running: no pidfile"
		return
	fi
	local pid
	pid=$(cat "$pidfile")
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "$name not running: stale pidfile pid=$pid"
		rm -f "$pidfile"
		return
	fi
	echo "stopping $name pid=$pid"
	kill "$pid" 2>/dev/null || true
	for _ in $(seq 1 30); do
		if ! kill -0 "$pid" 2>/dev/null; then
			rm -f "$pidfile"
			echo "stopped $name"
			return
		fi
		sleep 1
	done
	echo "forcing $name pid=$pid"
	kill -9 "$pid" 2>/dev/null || true
	rm -f "$pidfile"
}

case "${1:-all}" in
	all)
		stop_one vm0 "$WS/pids/vm0.pid"
		stop_one vm1 "$WS/pids/vm1.pid"
		stop_one localfork "$WS/pids/local.pid"
		;;
	cxl)
		stop_one vm0 "$WS/pids/vm0.pid"
		stop_one vm1 "$WS/pids/vm1.pid"
		;;
	vm0) stop_one vm0 "$WS/pids/vm0.pid" ;;
	vm1) stop_one vm1 "$WS/pids/vm1.pid" ;;
	local|localfork) stop_one localfork "$WS/pids/local.pid" ;;
	*)
		echo "usage: $0 [all|cxl|vm0|vm1|localfork]" >&2
		exit 2
		;;
esac
