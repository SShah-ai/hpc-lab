# Procedure: move a local user to the directory

Moves `labuser` from a local account on every node (UID 2001) to a directory account (UID 10003) with its home on NFS. The UID changes, so the files, the SSSD caches and Slurm all need attention. All `ansible` commands run from the `ansible` folder.

## Impact

- labuser cannot log in or run jobs during the change window (about 10 minutes).
- The UID changes from 2001 to 10003, and the primary group from `labuser` (2001) to `hpcusers` (10000).
- labuser logs in with the directory password from now on.
- The home moves from `/home/labuser` on each node to `/nfs/home/labuser`.
- Jobs recorded before the change keep UID 2001. `sacct -u labuser` no longer lists them (see Findings).
- slurmctld restarts. Running jobs are not affected.

## Pre-checks

1. labuser is the same on every node:
   ```
   ansible cluster -m command -a "id labuser"
   ```
   Expect `uid=2001(labuser) gid=2001(labuser)` on all three.
2. The new UID is free, locally and in the directory:
   ```
   ansible cluster -m shell -a "getent passwd 10003 || echo 'UID 10003 is free'"
   ```
3. labuser has no processes and no jobs:
   ```
   ansible cluster -b -m shell -a "pgrep -l -u labuser || echo 'no labuser processes'"
   ansible controller -m command -a "squeue -h -u labuser"
   ```
4. Every file owned by UID or GID 2001:
   ```
   ansible cluster -b -m shell -a "find / \( -path /proc -o -path /sys -o -path /run -o -path /nfs \) -prune -o \( -uid 2001 -o -gid 2001 \) -print 2>/dev/null; true"
   ```
   Expect `/home/labuser` and `/var/spool/mail/labuser`. Anything else needs a decision before going on.
5. The Slurm baseline, on ctl01:
   ```
   sacctmgr --noheader --parsable2 show assoc where user=labuser format=User,Account
   scontrol show assoc_mgr users=labuser flags=users
   sacct -u labuser -X --starttime=2026-11-01 --format=JobID,JobName,User,UID,Account,State
   ```
   Expect `labuser(2001)` in assoc_mgr. Write down the job IDs and the UID.

## Backups

1. Archive labuser's home on every node with numeric owners, copy the archives to the laptop, and record their checksums:
   ```
   mkdir -p -m 700 ~/hpc-lab-backups/labuser-migration
   ansible cluster -b -m shell -a "tar --numeric-owner -czf /root/labuser-home-{{ inventory_hostname }}.tar.gz -C /home labuser && tar -tvzf /root/labuser-home-{{ inventory_hostname }}.tar.gz"
   ansible cluster -b -m fetch -a "src=/root/labuser-home-{{ inventory_hostname }}.tar.gz dest=$HOME/hpc-lab-backups/labuser-migration/ flat=yes"
   sha256sum ~/hpc-lab-backups/labuser-migration/*.tar.gz
   ```
   `--numeric-owner` keeps the raw 2001 in the archive, so a restore puts back the same owner whatever names exist at that time.

## Procedure

1. Add the directory account. This step only adds things, and the local account still wins.
   - In `group_vars/cluster/vars.yml`, set `cluster_local_users: []`.
   - In `group_vars/controller/vars.yml`, add `labuser` to the `hpcusers` members and add the user:
     ```
     - name: labuser
       uid: 10003
       gid: 10000
       display_name: Lab User
     ```
   - Add `labuser` to `vault_ldap_user_passwords` with `ansible-vault edit group_vars/controller/vault.yml`.
   - Run the playbook twice:
     ```
     ansible-playbook site.yml
     ansible-playbook site.yml
     ```
     Expect 3 changes on ctl01 (directory user, group member, NFS home), then `changed=0`.
   - `ansible cluster -m command -a "id labuser"` still shows 2001. `nsswitch.conf` checks local files before SSSD.
2. Start the change window. Record the time and check that labuser is still idle:
   ```
   date
   ansible cluster -b -m shell -a "pgrep -l -u labuser || echo 'no labuser processes'"
   ansible controller -m command -a "squeue -h -u labuser"
   ```
3. Build the new home on ctl01. ctl01 is the NFS server, so root writes there locally and `root_squash` does not apply. The dotfiles were the same on every node, so ctl01's copy is used, plus the one file that only node01 had:
   ```
   ansible controller -b -m copy -a "src=$HOME/hpc-lab-backups/labuser-migration/labuser-home-node01.tar.gz dest=/root/labuser-home-node01.tar.gz mode=0600"
   ansible controller -b -m shell -a "cp -a /home/labuser/. /nfs/home/labuser/ && tar -xzf /root/labuser-home-node01.tar.gz --strip-components=1 -C /nfs/home/labuser labuser/slurm-3.out && chown -R 10003:10000 /nfs/home/labuser && ls -lan /nfs/home/labuser"
   ```
   Every file must show `10003 10000`.
4. Remove the local account. The old homes are renamed, not deleted, for rollback:
   ```
   ansible cluster -b -m shell -a "mv /home/labuser /home/labuser.pre-migration"
   ansible cluster -b -m user -a "name=labuser state=absent"
   ansible cluster -b -m group -a "name=labuser state=absent"
   ansible cluster -b -m shell -a "find /var/spool/mail/labuser -maxdepth 0 -size 0 -delete; ls -l /var/spool/mail/labuser 2>/dev/null || echo 'mail spool removed'"
   ```
   The mail spool is deleted only if it is empty.
5. Clear the SSSD caches, so every node looks labuser up again:
   ```
   ansible cluster -b -m command -a "sss_cache -E"
   ansible cluster -m command -a "id labuser"
   ```
   Expect `uid=10003(labuser) gid=10000(hpcusers)` on all three. This is the cut-over.
6. Restart slurmctld, so it drops the cached UID 2001:
   ```
   ansible controller -b -m systemd_service -a "name=slurmctld state=restarted"
   ansible controller -m command -a "scontrol show assoc_mgr users=labuser flags=users"
   ```
   Expect `UserName=labuser(10003) DefAccount=lab`. `scontrol reconfigure` is not enough (see [the association runbook](../runbooks/job-rejected-no-association.md)).

## Post-checks

1. No files are left with UID or GID 2001 except the renamed homes:
   ```
   ansible cluster -b -m shell -a "find / \( -path /proc -o -path /sys -o -path /run -o -path /nfs \) -prune -o \( -uid 2001 -o -gid 2001 \) -print 2>/dev/null; true"
   ```
2. A login and a job as labuser, on ctl01:
   ```
   su - labuser -c 'pwd; ls -la; sbatch -N2 -J post-migration --wrap="srun -l hostname; srun -l id"'
   su - labuser -c 'sleep 5; cat slurm-*.out'
   ```
   Expect `/nfs/home/labuser`, files owned by `labuser hpcusers`, and `uid=10003(labuser)` from both nodes.
3. The job history, including the jobs from before the change:
   ```
   sacct -a -X --starttime=2026-11-01 --format=JobID,JobName,User,UID,Account,State
   systemctl show slurmctld -p ActiveEnterTimestamp
   date
   ```

## Rollback

1. Recreate the local account with the old numbers:
   ```
   ansible cluster -b -m group -a "name=labuser gid=2001"
   ansible cluster -b -m user -a "name=labuser uid=2001 group=labuser shell=/bin/bash create_home=no"
   ```
2. Put the old homes back:
   ```
   ansible cluster -b -m shell -a "mv /home/labuser.pre-migration /home/labuser"
   ```
   If a renamed home is lost, restore it from the archive with `tar --numeric-owner -xzf /root/labuser-home-<node>.tar.gz -C /home`.
3. Clear the caches and restart slurmctld:
   ```
   ansible cluster -b -m command -a "sss_cache -E"
   ansible controller -b -m systemd_service -a "name=slurmctld state=restarted"
   ```
4. Revert the three `group_vars` files with git, and delete the directory entry with `ldapdelete`. The ldap_accounts role only creates entries, so reverting the code leaves the entry in place.

## Close-out

After sign-off, remove the rollback copies from the cluster. The archives on the laptop stay.
```
ansible cluster -b -m shell -a "rm -rf /home/labuser.pre-migration /root/labuser-home-*.tar.gz"
```

## Results: 2026-11-26

| Step | Result |
|---|---|
| Pre-checks | UID 2001 on all nodes, UID 10003 free, no processes, no jobs |
| Files owned by 2001 | `/home/labuser` and an empty mail spool on each node, plus `slurm-3.out` on node01 only |
| Baseline | `labuser(2001)` in assoc_mgr, job 3 recorded with UID 2001 |
| First playbook run | 3 changes on ctl01, then `changed=0` on the second run |
| Change window | 22:04 to 22:14 EST, 10 minutes including post-checks |
| slurmctld restart | 22:09:49 |
| Identity after the change | `uid=10003(labuser) gid=10000(hpcusers)` on all three nodes |
| assoc_mgr | `labuser(10003) DefAccount=lab` |
| Test job 6 | Ran on node01 and node02 as UID 10003, output in `/nfs/home/labuser` |
| Files left with UID 2001 | Only `/home/labuser.pre-migration` |
| Close-out | Rollback copies removed the same evening; no files left with UID or GID 2001 |

Backup checksums (SHA-256):
```
b338a09db2b53dc0416c51e815a5eeff96a4376d7a54210e7f059c1e0cad4e33  labuser-home-ctl01.tar.gz
ee4de2813e0b848f4a7a6f34490ad0b239c361221986a83e8d3ee3c787616456  labuser-home-node01.tar.gz
1025774431677b63a9816f2875a0655ba98d219c3eb777778511aa7388a21da7  labuser-home-node02.tar.gz
```

## Findings

**Local files win.** After step 1 the directory entry with UID 10003 existed, but `id labuser` still returned 2001, because `nsswitch.conf` checks local files before SSSD. Nothing changed for labuser until the local account was removed, so step 4 is the real cut-over.

**Job output was spread across nodes.** Job 3 was submitted from ctl01, but its output was only on node01's local disk. NFS homes fix this. The procedure kept the one unique file and did not copy the identical dotfiles three times.

**Job history is keyed by UID.** After the change, `sacct -u labuser` listed only job 6, because sacct converts the name to the current UID (10003). `sacct -u 2001` failed with `Invalid user id: 2001`, because that UID no longer exists on the system. `sacct -a` still lists job 3 with UID 2001 and user `labuser`, even though no node knows UID 2001 any more, so that name comes from the accounting database. Any UID migration should record the old UID so earlier jobs can still be found.

**userdel removed the private group.** The group task found nothing to remove, because userdel deletes the user's own group when it has no other members (`USERGROUPS_ENAB` in `/etc/login.defs`). The group task stays in the procedure for systems where that setting is off.

**root_squash decided where the copy runs.** Root on a compute node cannot write into an NFS home, so the new home was built on ctl01, where the files are local.
