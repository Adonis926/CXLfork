#!/bin/bash
set -euo pipefail

WS=${WS:-/home/xtl/cxlfork-ws}
VM_WORK=${VM_WORK:-/tmp/criu-simple-loop}
IMG_DIR=${IMG_DIR:-${VM_WORK}/img}
CXL_DEV=${CXL_DEV:-/dev/dax0.0}
CRIU_BIN=${CRIU_BIN:-/home/ubuntu/criu-cxl/criu/criu}

vm0() {
  "${WS}/scripts/ssh-vm0.sh" "$@"
}

vm1() {
  "${WS}/scripts/ssh-vm1.sh" "$@"
}

cleanup_vm() {
  local vm=$1

  "${vm}" "if [ -d '${VM_WORK}' ]; then cd '${VM_WORK}' && ps -eo pid=,args= | awk '/\\/bin\\/sh \\.\\/test.sh/ { print \$1 }' | xargs -r sudo kill -TERM; fi"
  sleep 1
  "${vm}" "if [ -d '${VM_WORK}' ]; then cd '${VM_WORK}' && ps -eo pid=,args= | awk '/\\/bin\\/sh \\.\\/test.sh/ { print \$1 }' | xargs -r sudo kill -KILL; fi"
  "${vm}" "sudo rm -rf '${VM_WORK}'"
}

echo "[1/8] checking VM access and CRIU"
vm0 "test -x '${CRIU_BIN}' && test -c '${CXL_DEV}'"
vm1 "test -x '${CRIU_BIN}' && test -c '${CXL_DEV}'"

echo "[2/8] cleaning old Simple_loop state"
cleanup_vm vm0
cleanup_vm vm1

echo "[3/8] creating Simple_loop process on VM0"
vm0 "mkdir -p '${IMG_DIR}' && cd '${VM_WORK}' && cat > test.sh <<'EOF'
#!/bin/sh
while :; do
	sleep 1
	date
done
EOF
chmod +x test.sh
setsid ./test.sh < /dev/null > test.log 2>&1 &
"

sleep 3

LOOP_PID=$(vm0 "cd '${VM_WORK}' && ps -eo pid=,args= | awk '/\\/bin\\/sh \\.\\/test.sh/ { print \$1; exit }'")
if [ -z "${LOOP_PID}" ]; then
  echo "failed to find Simple_loop process on VM0" >&2
  exit 1
fi

echo "[4/8] dumping PID ${LOOP_PID} from VM0 into ${CXL_DEV}"
vm0 "cd '${VM_WORK}' && sudo CRIU_CXL_IMAGE='${CXL_DEV}' '${CRIU_BIN}' dump -t '${LOOP_PID}' -D '${IMG_DIR}' -v4 -o dump.log"

echo "[5/8] preparing VM1 external log file expected by CRIU"
SCRIPT_CONTENT=$(vm0 "cat '${VM_WORK}/test.sh'")
SCRIPT_MODE=$(vm0 "stat -c %a '${VM_WORK}/test.sh'")
LOG_CONTENT=$(vm0 "cat '${VM_WORK}/test.log'")
LOG_MODE=$(vm0 "stat -c %a '${VM_WORK}/test.log'")
vm1 "mkdir -p '${IMG_DIR}' && cat > '${VM_WORK}/test.sh' <<'EOF_SCRIPT'
${SCRIPT_CONTENT}
EOF_SCRIPT
chmod '${SCRIPT_MODE}' '${VM_WORK}/test.sh'
cat > '${VM_WORK}/test.log' <<'EOF_LOG'
${LOG_CONTENT}
EOF_LOG
chmod '${LOG_MODE}' '${VM_WORK}/test.log'"

echo "[6/8] restoring Simple_loop on VM1 from ${CXL_DEV}"
vm1 "cd '${VM_WORK}' && sudo CRIU_CXL_IMAGE='${CXL_DEV}' '${CRIU_BIN}' restore -D '${IMG_DIR}' --restore-detached -v4 -o restore.log"

sleep 4

echo "[7/8] verifying restored process and continued output"
RESTORED_PID=$(vm1 "cd '${VM_WORK}' && ps -eo pid=,ppid=,args= | awk '/\\/bin\\/sh \\.\\/test.sh/ { print \$1; exit }'")
if [ -z "${RESTORED_PID}" ]; then
  echo "restore did not leave a Simple_loop shell process on VM1" >&2
  vm1 "tail -80 '${VM_WORK}/restore.log' || true"
  exit 1
fi

LINE_COUNT=$(vm1 "wc -l < '${VM_WORK}/test.log'")
if [ "${LINE_COUNT}" -lt 4 ]; then
  echo "restored process did not append enough log lines; got ${LINE_COUNT}" >&2
  vm1 "cat '${VM_WORK}/test.log' || true"
  exit 1
fi

echo "[8/8] success"
echo "VM1 restored PID: ${RESTORED_PID}"
echo "VM1 log tail:"
vm1 "tail -8 '${VM_WORK}/test.log'"
