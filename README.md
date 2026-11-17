# hpc-lab

A small HPC cluster built on a single PC, used to practise Linux HPC administration on the SUSE family of operating systems.

Three KVM virtual machines run openSUSE Leap 15.6. They are built from a cloud image with cloud-init and configured with Ansible. MUNGE handles authentication, Slurm 23.02 schedules jobs, and slurmdbd with MariaDB keeps the job history.

## Architecture

```
                  Ubuntu host (KVM / libvirt, Ansible control node)
          virbr0 192.168.122.1                virbr1 192.168.56.1
          "default": NAT, DHCP, internet      "hpc-net": isolated, static IPs
               |                                   |
   ctl01  -----+------------------------------ 192.168.56.10   slurmctld, slurmdbd, MariaDB, munge
   node01 -----+------------------------------ 192.168.56.11   slurmd, munge
   node02 -----+------------------------------ 192.168.56.12   slurmd, munge
```

| Node | Role | vCPU | RAM | Disk |
|---|---|---|---|---|
| ctl01 | Slurm controller, accounting, login node | 2 | 1.5 GB | 20 GB qcow2 overlay |
| node01 | Compute | 2 | 1 GB | 20 GB qcow2 overlay |
| node02 | Compute | 2 | 1 GB | 20 GB qcow2 overlay |

Each VM disk is a copy-on-write overlay on one read-only base image, so a node can be rebuilt in seconds.

## Repository layout

```
cloud-init/build-vms.sh            creates the three VMs (overlay disk, cloud-init seed, virt-install)
cloud-init/destroy-vms.sh          removes the VMs, their disks and old SSH host keys
libvirt/hpc-net.xml                the isolated cluster network
ansible/ansible.cfg
ansible/inventory/hosts.ini        groups: controller, compute, cluster
ansible/group_vars/cluster.yml     cluster-wide variables
ansible/group_vars/controller/     accounting settings; vault.yml holds the encrypted database password
ansible/site.yml                   four plays: base setup, accounting, Slurm, accounts
ansible/roles/common               packages, /etc/hosts from inventory, chrony, persistent journal, unused repos disabled
ansible/roles/munge                one key generated on ctl01, copied to every node (munge:munge, 0400)
ansible/roles/slurmdbd             MariaDB, the accounting database and user, slurmdbd.conf, slurmdbd
ansible/roles/slurm                Slurm packages, slurm.conf from a template, slurmctld and slurmd
ansible/roles/slurm_accounts       registers the cluster, accounts and users with sacctmgr
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
5. Create your own vault. The `vault.yml` in this repository is encrypted with my vault password, which is not published, so a fresh clone needs its own password file and its own secret:
   ```
   openssl rand -base64 32 > ~/.ansible/hpc-lab-vault-pass && chmod 600 ~/.ansible/hpc-lab-vault-pass
   cd ansible
   cat > group_vars/controller/vault.yml <<EOF
   ---
   vault_slurmdbd_db_password: "$(openssl rand -base64 24)"
   EOF
   ansible-vault encrypt group_vars/controller/vault.yml
   ```
6. Accept the nodes' SSH host keys, then run the playbook:
   ```
   for ip in 192.168.56.10 192.168.56.11 192.168.56.12; do ssh -o StrictHostKeyChecking=accept-new sayed@$ip true; done
   ansible-playbook site.yml
   ```

## Verify

```
ssh sayed@192.168.56.10 sinfo
ssh sayed@192.168.56.10 'srun -N2 hostname'
ssh sayed@192.168.56.10 'sacct -X --format=JobID,JobName,User,Account,State,ExitCode,Elapsed'
ssh sayed@192.168.56.10 'seff <jobid>'
```

Expected: the `debug` partition with `node01` and `node02` idle, one hostname from each node, and the finished jobs listed under the `lab` account.

## Accounting

When a job starts and ends, slurmctld sends a record to slurmdbd on ctl01 (port 6819), and slurmdbd writes it to MariaDB. Only slurmdbd knows the database password. It is in `/etc/slurm/slurmdbd.conf`, owned by `slurm` with mode 0600, and in this repository it is encrypted with Ansible Vault. The template task that writes the file has diff output turned off, so the password does not show up in `--diff` runs.

MariaDB listens only on 127.0.0.1, and its root account can only log in through the Unix socket as Linux root. The role removes the anonymous accounts and the `test` database that a default install leaves behind.

The `slurm_accounts` role registers cluster `hpclab`, account `lab` and user `sayed`. Each one is checked with `sacctmgr show` first and only added if missing, so the play can run any number of times.

`sacct` shows each job and step with its state, exit code, run time and peak memory. `seff` compares what a job used with what it asked for, which is the quickest way to answer "why was my job slow?" or "how much memory should I request?". A job keeps the association it had when it ran. Jobs submitted before a user was added show no account, and adding the user later does not change them.

## Problems I hit and how I fixed them

**VMs never came up on the network.** No VM requested a DHCP address, and the serial console showed nothing. I checked the VM disk offline with `virt-cat` and found that cloud-init had written correct network files. In a controlled test, node02 came up after I added a virtual video device and changed nothing else. The VMs had been created with `--graphics none`. The fix is in `build-vms.sh`: every VM gets `--graphics spice --video virtio`. I have not confirmed exactly where the boot stalled without it.

**Ansible could not use the system Python.** Leap 15.6 ships Python 3.6, which current ansible-core no longer supports on managed nodes. cloud-init now installs `python311`, and the inventory sets `ansible_python_interpreter=/usr/bin/python3.11`. SLES 15 has the same issue.

**The persistent journal did not appear.** After adding `Storage=persistent` and restarting journald, `/var/log/journal` still did not exist. journald starts in memory and only moves to disk when it gets a flush request, which normally happens during boot. The role now runs `journalctl --flush` in a handler after the restart. I confirmed it by rebooting a node and seeing two boots in `journalctl --list-boots`.

**My first slurm.conf dropped SUSE defaults.** The `--diff` output showed that my template removed three settings from SUSE's default file:
- `CommunicationParameters=block_null_hash`, the mitigation for CVE-2022-29500
- `PropagateResourceLimitsExcept=MEMLOCK`, which matters for RDMA and InfiniBand jobs
- the PID file paths used by SUSE's packages

All three are back in the template. Now I diff vendor defaults before replacing a config file.

**slurmdbd logged "Database settings not recommended values".** It flags `innodb_buffer_pool_size` and `innodb_lock_wait_timeout` when they are below half of the values in Slurm's accounting documentation (1024M and 900 seconds). MariaDB's defaults were 128M and 50 seconds. The role now adds a drop-in file at `/etc/my.cnf.d/slurm.cnf` with a 512M buffer pool, which is as far as ctl01's 1.5 GB of memory allows, and a 900-second lock wait. After the restart, the error no longer appears in the log.

## Notes

- openSUSE Leap 15.6 reached end of life in April 2026 and gets no more updates. That is acceptable here because the cluster network is isolated, but it is not a setup for production.
- The MUNGE key is fetched into `ansible/.secrets/`, which is in `.gitignore` and never committed.
- The vault password file lives at `~/.ansible/hpc-lab-vault-pass`, outside the repository. `ansible.cfg` points to it.
- Process tracking uses `proctrack/linuxproc` for now. Moving to cgroups is on the list below.

## Next

- Association enforcement, partitions, limits, and node drain and resume drills
- LDAP logins through SSSD, and NFS home directories with AutoFS (job output currently lands on the compute node's local disk)
- A cluster migration with a written method of procedure and rollback plan
- A Redfish health-check script and an NVIDIA XID error reference
