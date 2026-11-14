#!/usr/bin/env bash
# Removes the lab VMs and their disks so build-vms.sh can rebuild them cleanly
set -uo pipefail
IMGDIR=/var/lib/libvirt/images

for n in ctl01 node01 node02; do
  virsh destroy  "$n" 2>/dev/null
  virsh undefine "$n" 2>/dev/null
  sudo rm -f "$IMGDIR/$n.qcow2" "$IMGDIR/$n-seed.iso"
  ssh-keygen -R "$n" >/dev/null 2>&1
done
for ip in 192.168.56.10 192.168.56.11 192.168.56.12; do
  ssh-keygen -R "$ip" >/dev/null 2>&1
done
echo "Lab VMs removed."
