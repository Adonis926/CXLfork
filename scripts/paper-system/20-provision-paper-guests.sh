#!/usr/bin/env bash
set -euo pipefail

VM0_PORT=${VM0_PORT:-2400}
VM1_PORT=${VM1_PORT:-2401}
SSH_USER=${SSH_USER:-ubuntu}
SSH_HOST=${SSH_HOST:-127.0.0.1}

ssh_guest() {
	ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
		-p "$1" "$SSH_USER@$SSH_HOST" "${@:2}"
}

for port in "$VM0_PORT" "$VM1_PORT"; do
	ssh_guest "$port" 'set -e
		if command -v growpart >/dev/null 2>&1; then
			sudo growpart /dev/vda 1 || true
			sudo resize2fs /dev/vda1 || true
		fi
		sudo env DEBIAN_FRONTEND=noninteractive apt-get update
		sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
			docker.io openjdk-17-jre-headless
		sudo install -d -m 0755 /etc/docker
		printf "%s\n" \
			"{" \
			"  \"storage-driver\": \"vfs\"," \
			"  \"iptables\": false," \
			"  \"bridge\": \"none\"" \
			"}" | sudo tee /etc/docker/daemon.json >/dev/null
		# docker.io 的 postinst 会在 daemon.json 写入前尝试启动一次；
		# 当前内核未启用 nftables，该次启动预期失败。写入无网络的
		# 实验配置后必须显式清除 start-limit 并重启，而不能只用
		# enable --now（服务已 enable 时它可能保持 failed 状态）。
		sudo systemctl enable docker
		sudo systemctl reset-failed docker || true
		sudo systemctl restart docker
		sudo docker info --format \
			"docker_ready driver={{.Driver}} cgroup={{.CgroupVersion}}"
		java -version
		test -c /dev/cxlfork
		df -h /
	'
done

echo "paper_guests_provisioned verify=ok"
