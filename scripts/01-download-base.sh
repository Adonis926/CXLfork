#!/bin/bash

set -e
WS=/home/xtl/cxlfork-ws
cd $WS/images
echo "[1] 下载 Ubuntu 24.04 cloud image..."
wget -c https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img -O base-orig.img
echo "[2] 转换为 qcow2 格式..."
qemu-img convert -f qcow2 -O qcow2 base-orig.img base.qcow2
qemu-img resize base.qcow2 50G
echo "[done] base.qcow2 ready"
qemu-img info base.qcow2
