#!/bin/bash
set -e
WS=/home/xtl/cxlfork-ws

cd ${WS}/images
qemu-img create -f qcow2 -b base.qcow2 -F qcow2 vm0.qcow2 50G
qemu-img create -f qcow2 -b base.qcow2 -F qcow2 vm1.qcow2 50G
echo "VM disks created (CXL shared mem uses /dev/shm at runtime, no pre-allocation needed)"
