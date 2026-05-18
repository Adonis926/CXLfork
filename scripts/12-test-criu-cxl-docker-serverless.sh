#!/bin/bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
POC=${POC:-${WS}/criu-cxl-poc}
VM_WORK=${VM_WORK:-/tmp/criu-cxl-poc}
IMAGE=${IMAGE:-criu-cxl-poc:local}
NAME=${NAME:-cxl-docker-fn}
CKPT=${CKPT:-ckpt1}
DAX=${DAX:-/dev/dax0.0}
MB=${MB:-4}
ITERS=${ITERS:-50000}
CRIU_SRC=${CRIU_SRC:-/home/ubuntu/criu-cxl}

vm0() {
  "${WS}/scripts/ssh-vm0.sh" "$@"
}

vm1() {
  "${WS}/scripts/ssh-vm1.sh" "$@"
}

copy_to_vm() {
  local port=$1

  scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_ed25519 \
    -P "${port}" \
    "${POC}/criu-cxl-poc-static" \
    "${POC}/Dockerfile" \
    ubuntu@localhost:"${VM_WORK}/"
}

configure_vm() {
  local vm=$1

  "${vm}" "set -e
sudo mkdir -p /etc/docker
printf '%s\n' '{\"experimental\":true,\"iptables\":false,\"ip6tables\":false,\"bridge\":\"none\",\"storage-driver\":\"vfs\"}' | sudo tee /etc/docker/daemon.json >/dev/null
sudo systemctl restart docker
test -x '${CRIU_SRC}/criu/criu'
sudo rm -f /usr/sbin/criu /usr/sbin/criu-cxl-real
sudo install -m 0755 '${CRIU_SRC}/criu/criu' /usr/sbin/criu-cxl-real
sudo mkdir -p /usr/local/lib/criu-cxl-noop-net
printf '#!/bin/sh\nexit 0\n' | sudo tee /usr/local/lib/criu-cxl-noop-net/iptables-restore >/dev/null
sudo cp /usr/local/lib/criu-cxl-noop-net/iptables-restore /usr/local/lib/criu-cxl-noop-net/ip6tables-restore
sudo chmod +x /usr/local/lib/criu-cxl-noop-net/iptables-restore /usr/local/lib/criu-cxl-noop-net/ip6tables-restore
printf '#!/bin/sh\nexport CRIU_CXL_IMAGE=\${CRIU_CXL_IMAGE:-${DAX}}\nexport CRIU_CXL_SIZE_MB=\${CRIU_CXL_SIZE_MB:-4096}\nexport PATH=/usr/local/lib/criu-cxl-noop-net:\$PATH\nexec /usr/sbin/criu-cxl-real \"\$@\"\n' | sudo tee /usr/sbin/criu >/dev/null
sudo chmod +x /usr/sbin/criu
mkdir -p '${VM_WORK}'
cd '${VM_WORK}'
sudo docker build -q -t '${IMAGE}' .
sudo docker rm -f '${NAME}' >/dev/null 2>&1 || true"
}

echo "[1/9] building static serverless container payload"
make -C "${POC}" clean static

echo "[2/9] preparing VM work directories"
vm0 "rm -rf '${VM_WORK}' && mkdir -p '${VM_WORK}'"
vm1 "rm -rf '${VM_WORK}' && mkdir -p '${VM_WORK}'"

echo "[3/9] copying Docker build context"
copy_to_vm 2200
copy_to_vm 2201

echo "[4/9] configuring Docker + CRIU-CXL wrapper on both VMs"
configure_vm vm0
configure_vm vm1

echo "[5/9] launching serverless container on VM0"
vm0 "sudo docker rm -f '${NAME}' >/dev/null 2>&1 || true
sudo docker run -d --name '${NAME}' --network host --privileged --device '${DAX}:${DAX}' '${IMAGE}' serve --mb '${MB}' --iters '${ITERS}' >/tmp/${NAME}.cid
sleep 1
sudo docker logs --tail 4 '${NAME}'"

echo "[6/9] checkpointing VM0 container into CXL-backed CRIU image"
CHECKPOINT_NS=$(vm0 "start=\$(date +%s%N)
sudo docker checkpoint create '${NAME}' '${CKPT}' >/dev/null
end=\$(date +%s%N)
echo \$((end - start))")
echo "docker_checkpoint_ns=${CHECKPOINT_NS}"
vm0 "sudo docker ps -a --format '{{.Names}} {{.Status}}' | grep '${NAME}'"

echo "[7/9] copying Docker checkpoint descriptor to VM1"
VM0_CID=$(vm0 "sudo docker inspect -f '{{.Id}}' '${NAME}'")
vm0 "sudo cat '/var/lib/docker/containers/${VM0_CID}/checkpoints/${CKPT}/descriptors.json'" > /tmp/cxlfork-docker-descriptors.json
vm1 "sudo docker rm -f '${NAME}' >/dev/null 2>&1 || true
sudo docker create --name '${NAME}' --network host --privileged --device '${DAX}:${DAX}' '${IMAGE}' serve --mb '${MB}' --iters '${ITERS}' >/tmp/${NAME}.cid
VM1_CID=\$(sudo docker inspect -f '{{.Id}}' '${NAME}')
sudo mkdir -p \"/var/lib/docker/containers/\${VM1_CID}/checkpoints/${CKPT}\""
scp \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -i ~/.ssh/id_ed25519 \
  -P 2201 \
  /tmp/cxlfork-docker-descriptors.json \
  ubuntu@localhost:/tmp/cxlfork-docker-descriptors.json
vm1 "VM1_CID=\$(sudo docker inspect -f '{{.Id}}' '${NAME}')
sudo cp /tmp/cxlfork-docker-descriptors.json \"/var/lib/docker/containers/\${VM1_CID}/checkpoints/${CKPT}/descriptors.json\"
sudo find \"/var/lib/docker/containers/\${VM1_CID}/checkpoints/${CKPT}\" -maxdepth 1 -type f -printf '%f %s bytes\n'"

echo "[8/9] restoring VM0 checkpoint on VM1 from CXL"
RESTORE_NS=$(vm1 "start=\$(date +%s%N)
sudo docker start --checkpoint '${CKPT}' '${NAME}' >/dev/null
end=\$(date +%s%N)
echo \$((end - start))")
echo "docker_restore_ns=${RESTORE_NS}"
sleep 1

echo "[9/9] verifying restored container continued serverless work"
vm1 "sudo docker ps --format '{{.Names}} {{.Status}}' | grep '${NAME}'
sudo docker logs --tail 8 '${NAME}'"

echo "docker_criu_cxl_serverless=ok checkpoint_ns=${CHECKPOINT_NS} restore_ns=${RESTORE_NS}"
