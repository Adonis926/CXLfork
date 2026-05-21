#!/usr/bin/env bash
set -euo pipefail

MODE=${1:-process}
shift || true

PYTHON_USER_SITE=${PYTHON_USER_SITE:-/home/ubuntu/.local/lib/python3.12/site-packages}
CGROUP_ROOT=${CGROUP_ROOT:-/sys/fs/cgroup/cxlfork-bench}
ROOTFS=${ROOTFS:-/tmp/cxlfork-rootfs}

usage() {
	echo "usage: $0 process|namespace|cgroup|rootfs -- command..." >&2
	exit 2
}

if [[ "${1:-}" == "--" ]]; then
	shift
fi
if [[ $# -lt 1 ]]; then
	usage
fi

run_process() {
	exec "$@"
}

run_namespace() {
	exec sudo env PYTHONPATH="$PYTHON_USER_SITE" \
		unshare --fork --pid --mount-proc --uts --ipc --mount -- "$@"
}

run_cgroup() {
	local name="run-$$-$RANDOM"
	local dir="$CGROUP_ROOT/$name"

	sudo mkdir -p "$dir"
	sudo sh -c "echo $$ > '$dir/cgroup.procs'"
	exec "$@"
}

run_rootfs() {
	local quoted_cmd=""
	local arg
	local workdir

	for arg in "$@"; do
		printf -v arg "%q" "$arg"
		quoted_cmd+=" $arg"
	done
	workdir=$(pwd)

	exec sudo env \
		PYTHON_USER_SITE="$PYTHON_USER_SITE" \
		CGROUP_ROOT="$CGROUP_ROOT" \
		ROOTFS="$ROOTFS" \
		CHROOT_WORKDIR="$workdir" \
		unshare --fork --pid --uts --ipc --mount -- bash -lc '
set -euo pipefail
mount --make-rprivate /
mkdir -p "$ROOTFS"/{usr,lib,lib64,bin,etc,tmp,dev,proc,home/ubuntu}
mkdir -p "$ROOTFS/home/ubuntu/.local" "$ROOTFS/sys/fs/cgroup"
mountpoint -q "$ROOTFS/usr" || mount --bind /usr "$ROOTFS/usr"
mountpoint -q "$ROOTFS/lib" || mount --bind /lib "$ROOTFS/lib"
mountpoint -q "$ROOTFS/lib64" || mount --bind /lib64 "$ROOTFS/lib64"
mountpoint -q "$ROOTFS/bin" || mount --bind /bin "$ROOTFS/bin"
mountpoint -q "$ROOTFS/etc" || mount --bind /etc "$ROOTFS/etc"
mountpoint -q "$ROOTFS/tmp" || mount --bind /tmp "$ROOTFS/tmp"
mountpoint -q "$ROOTFS/dev" || mount --bind /dev "$ROOTFS/dev"
mountpoint -q "$ROOTFS/home/ubuntu/.local" || mount --bind /home/ubuntu/.local "$ROOTFS/home/ubuntu/.local"
mountpoint -q "$ROOTFS/sys/fs/cgroup" || mount --bind /sys/fs/cgroup "$ROOTFS/sys/fs/cgroup"
mountpoint -q "$ROOTFS/proc" || mount -t proc proc "$ROOTFS/proc"
mkdir -p "$CGROUP_ROOT/rootfs-$$"
echo $$ > "$CGROUP_ROOT/rootfs-$$/cgroup.procs"
exec chroot "$ROOTFS" /bin/bash -lc "cd \"\$CHROOT_WORKDIR\" && exec /usr/bin/env PYTHONPATH=\"\$PYTHON_USER_SITE\"'"$quoted_cmd"'"
'
}

case "$MODE" in
	process)
		run_process "$@"
		;;
	namespace)
		run_namespace "$@"
		;;
	cgroup)
		run_cgroup "$@"
		;;
	rootfs)
		run_rootfs "$@"
		;;
	*)
		usage
		;;
esac
