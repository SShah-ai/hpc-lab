# hpc-lab

A small HPC cluster built on a laptop, used to practise Linux HPC administration on the SUSE family of operating systems.

Three KVM virtual machines run openSUSE Leap 15.6. They are built from a cloud image with cloud-init and configured with Ansible. MUNGE handles authentication and Slurm 23.02 schedules jobs.

## Architecture

```
                  Ubuntu host (KVM / libvirt, Ansible control node)
          virbr0 192.168.122.1                virbr1 192.168.56.1
          "default": NAT, DHCP, internet      "hpc-net": isolated, static IPs
               |                                   |
   ctl01  -----+------------------------------ 192.168.56.10   slurmctld, munge
   node01 -----+------------------------------ 192.168.56.11   slurmd, munge
   node02 -----+------------------------------ 192.168.56.12   slurmd, munge
```

| Node | Role | vCPU | RAM | Disk |
|---|---|---|---|---|
| ctl01 | Slurm controller, login node | 2 | 1.5 GB | 20 GB qcow2 overlay |
| node01 | Compute | 2 | 1 GB | 20 GB qcow2 overlay |
| node02 | Compute | 2 | 1 GB | 20 GB qcow2 overlay |

Each VM disk is a copy-on-write overlay on one read-only base image so a node can be rebuilt in seconds.

## Repository layout

```
cloud-init/build-vms.sh     creates the three VMs (overlay disk, cloud-init seed, virt-install)
cloud-init/destroy-vms.sh   removes the VMs, their disks and old SSH host keys
libvirt/hpc-net.xml         the isolated cluster network
ansible/ansible.cfg
ansible/inventory/hosts.ini groups: controller, compute, cluster
ansible/group_vars/         cluster-wide variables
ansible/site.yml            applies the roles below in order
ansible/roles/common        packages, /etc/hosts from inventory, chrony, persistent journal, unused repos disabled
ansible/roles/munge         one key generated on ctl01, copied to every node (munge:munge, 0400)
ansible/roles/slurm         Slurm packages, slurm.conf from a template, slurmctld and slurmd
```

## Build

Tested on Ubuntu 26.04 with 8 GB of RAM.

1. Install the host tools and add yourself to the `libvirt` and `kvm` groups, then log out and back in:
   ```
   sudo apt install qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst qemu-utils cloud-image-utils ansible ansible-lint
   sudo usermod -aG libvirt,kvm $USER
   ```
2. Create the cluster network:
   ```
   virsh net-define libvirt/hpc-net.xml && virsh net-start hpc-net && virsh net-autostart hpc-net
   ```
3. Download the base image into `/var/lib/libvirt/images/base/` and check its SHA-256 against the published `.sha256` file:
   `openSUSE-Leap-15.6-Minimal-VM.x86_64-Cloud.qcow2` from https://download.opensuse.org/distribution/leap/15.6/appliances/
4. Build the VMs (needs an SSH key at `~/.ssh/id_ed25519`):
   ```
   cd cloud-init && ./build-vms.sh
   ```
5. Accept the nodes' SSH host keys, then run the playbook:
   ```
   for ip in 192.168.56.10 192.168.56.11 192.168.56.12; do ssh -o StrictHostKeyChecking=accept-new shah@$ip true; done
   cd ansible && ansible-playbook site.yml
   ```

## Verify

```
ssh shah@192.168.56.10 sinfo
ssh shah@192.168.56.10 'srun -N2 hostname'
```

Expected: the `debug` partition with `node01` and `node02` idle, and one hostname from each node.

## Problems I hit and how I fixed them

**VMs never came up on the network.** No VM requested a DHCP address and the serial console showed nothing. I checked the VM disk offline with `virt-cat` and found that cloud-init had written correct network files. In a controlled test, node02 came up after I added a virtual video device and changed nothing else. The VMs had been created with `--graphics none`. The fix is in `build-vms.sh`: every VM gets `--graphics spice --video virtio`. I have not confirmed exactly where the boot stalled without it.

**Ansible could not use the system Python.** Leap 15.6 ships Python 3.6, which current ansible-core no longer supports on managed nodes. cloud-init now installs `python311`, and the inventory sets `ansible_python_interpreter=/usr/bin/python3.11`. SLES 15 has the same issue.

**The persistent journal did not appear.** After adding `Storage=persistent` and restarting journald, `/var/log/journal` still did not exist. journald starts in memory and only moves to disk when it gets a flush request, which normally happens during boot. The role now runs `journalctl --flush` in a handler after the restart. I confirmed it by rebooting a node and seeing two boots in `journalctl --list-boots`.

**My first slurm.conf dropped SUSE defaults.** The `--diff` output showed that my template removed three settings from SUSE's default file:
- `CommunicationParameters=block_null_hash`, the mitigation for CVE-2022-29500
- `PropagateResourceLimitsExcept=MEMLOCK`, which matters for RDMA and InfiniBand jobs
- the PID file paths used by SUSE's packages

All three are back in the template. Now I diff vendor defaults before replacing a config file.

## Notes

- openSUSE Leap 15.6 reached end of life in April 2026 and gets no more updates. That is acceptable here because the cluster network is isolated, but it is not a setup for production.
- The MUNGE key is fetched into `ansible/.secrets/`, which is in `.gitignore` and never committed.
- Process tracking uses `proctrack/linuxproc` for now. Moving to cgroups is on the list below.

## Next

- Slurm accounting with slurmdbd and MariaDB
- Partitions, limits, and node drain and resume drills
- LDAP logins through SSSD, and NFS home directories with AutoFS (job output currently lands on the compute node's local disk)
- A cluster migration with a written method of procedure and rollback plan
- A Redfish health-check script and an NVIDIA XID error reference
