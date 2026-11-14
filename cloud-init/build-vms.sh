#!/usr/bin/env bash
# Builds the lab VMs: ctl01, node01, node02 on openSUSE Leap 15.6
set -euo pipefail

BASE=/var/lib/libvirt/images/base/openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2
IMGDIR=/var/lib/libvirt/images
PUBKEY=$(cat ~/.ssh/id_ed25519.pub)
OSVARIANT=opensuse15.6

# name  last-octet  memory(MB)
NODES=("ctl01 10 1536" "node01 11 1024" "node02 12 1024")

for entry in "${NODES[@]}"; do
  read -r NAME OCT MEM <<< "$entry"
  mkdir -p "$NAME" && cd "$NAME"

  # meta-data: identity of this instance
  cat > meta-data <<EOF
instance-id: ${NAME}-001
local-hostname: ${NAME}
EOF

  # user-data: hostname, admin user, SSH key
  cat > user-data <<EOF
#cloud-config
hostname: ${NAME}
fqdn: ${NAME}.hpc.lab
timezone: America/Toronto
users:
  - name: sayed
    groups: [wheel]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - ${PUBKEY}
packages:
  - python311
EOF

  # network-config: NIC 1 = DHCP on default (internet), NIC 2 = static on hpc-net
  cat > network-config <<EOF
version: 2
ethernets:
  ext0:
    match:
      macaddress: "52:54:00:aa:00:${OCT}"
    dhcp4: true
  int0:
    match:
      macaddress: "52:54:00:56:00:${OCT}"
    addresses: [192.168.56.${OCT}/24]
EOF

  cloud-localds --network-config=network-config seed.iso user-data meta-data
  sudo cp seed.iso "${IMGDIR}/${NAME}-seed.iso"

  # overlay disk on top of the read-only base image
  sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE" "${IMGDIR}/${NAME}.qcow2" 20G

  sudo virt-install \
    --name "$NAME" \
    --memory "$MEM" --vcpus 2 \
    --os-variant "$OSVARIANT" \
    --disk path="${IMGDIR}/${NAME}.qcow2",format=qcow2,bus=virtio \
    --disk path="${IMGDIR}/${NAME}-seed.iso",device=cdrom \
    --network network=default,mac="52:54:00:aa:00:${OCT}",model=virtio \
    --network network=hpc-net,mac="52:54:00:56:00:${OCT}",model=virtio \
    --import --graphics spice --video virtio --noautoconsole

  cd ..
done
