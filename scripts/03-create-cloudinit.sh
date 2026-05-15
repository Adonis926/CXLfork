#!/bin/bash
set -e

WS=/home/xtl/cxlfork-ws
CI=$WS/cloudinit
mkdir -p $CI

# ---- VM0 ----
cat > $CI/vm0-meta-data << 'EOF'
instance-id: vm0
local-hostname: cxlfork-node0
EOF

cat > $CI/vm0-user-data << 'EOF'
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false

chpasswd:
  expire: false
  users:
    - name: ubuntu
      password: cxlfork
      type: text
    - name: root
      password: cxlfork
      type: text

ssh_pwauth: true
disable_root: false

# 静态网络配置（data 网卡 ens4）
write_files:
  - path: /etc/netplan/99-cxl-data.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          ens4:
            addresses: [192.168.100.10/24]

runcmd:
  - netplan apply
  - echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
EOF

# ---- VM1 ----
cat > $CI/vm1-meta-data << 'EOF'
instance-id: vm1
local-hostname: cxlfork-node1
EOF

cat > $CI/vm1-user-data << 'EOF'
#cloud-config
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false

chpasswd:
  expire: false
  users:
    - name: ubuntu
      password: cxlfork
      type: text
    - name: root
      password: cxlfork
      type: text

ssh_pwauth: true
disable_root: false

write_files:
  - path: /etc/netplan/99-cxl-data.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          ens4:
            addresses: [192.168.100.11/24]

runcmd:
  - netplan apply
  - echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
EOF

echo "[building ISOs]"
cloud-localds $CI/vm0-seed.iso $CI/vm0-user-data $CI/vm0-meta-data
cloud-localds $CI/vm1-seed.iso $CI/vm1-user-data $CI/vm1-meta-data

echo "[done]"
ls -lh $CI/*.iso