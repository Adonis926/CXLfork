#!/usr/bin/env bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork/cxlfork-repro}
SOURCE_VM0=${SOURCE_VM0:-$WS/images/vm0.qcow2}
SOURCE_VM1=${SOURCE_VM1:-$WS/images/vm1.qcow2}
PAPER_VM0=${PAPER_VM0:-$WS/images/paper-vm0.qcow2}
PAPER_VM1=${PAPER_VM1:-$WS/images/paper-vm1.qcow2}
PAPER_DISK_SIZE=${PAPER_DISK_SIZE:-40G}

for pidfile in "$WS/pids/vm0.pid" "$WS/pids/vm1.pid" \
	"$WS/pids/paper-vm0.pid" "$WS/pids/paper-vm1.pid"; do
	if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
		echo "refusing to copy a live VM disk: active pidfile=$pidfile" >&2
		exit 1
	fi
done

for source in "$SOURCE_VM0" "$SOURCE_VM1"; do
	[[ -f "$source" ]] || {
		echo "missing source image: $source" >&2
		exit 1
	}
done
for target in "$PAPER_VM0" "$PAPER_VM1"; do
	[[ ! -e "$target" ]] || {
		echo "paper image already exists; refusing to overwrite: $target" >&2
		exit 1
	}
done

cp --reflink=auto --sparse=always "$SOURCE_VM0" "$PAPER_VM0"
cp --reflink=auto --sparse=always "$SOURCE_VM1" "$PAPER_VM1"
qemu-img resize "$PAPER_VM0" "$PAPER_DISK_SIZE"
qemu-img resize "$PAPER_VM1" "$PAPER_DISK_SIZE"

qemu-img info "$PAPER_VM0"
qemu-img info "$PAPER_VM1"
echo "paper_images_ready size=$PAPER_DISK_SIZE verify=ok"
