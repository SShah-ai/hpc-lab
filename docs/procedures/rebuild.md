# Procedure: rebuild the lab cluster from the repository

Destroys all three VMs and rebuilds them from a fresh clone of this repository. It proves that the cluster can be recreated from code alone, with nothing done by hand.

## Impact

- All three VMs and their disks are deleted.
- Job history in the accounting database is lost unless it is restored from the backup below.
- New SSH host keys and a new MUNGE key are generated.

## Pre-checks

1. The repository is clean and pushed:
   ```
   git status
   git fetch && git status -sb
   ```
   Expect `nothing to commit, working tree clean` and `## main...origin/main`.
2. The vault password file exists:
   ```
   ls -l ~/.ansible/hpc-lab-vault-pass
   ```
3. A snapshot of the current cluster, to compare against afterwards:
   ```
   mkdir -p -m 700 ~/hpc-lab-backups
   ssh sayed@192.168.56.10 'sinfo; sacctmgr -n -P show assoc format=Cluster,Account,User' > ~/hpc-lab-backups/before.txt
   ssh sayed@192.168.56.10 'scontrol show config' | grep -E "ClusterName|AccountingStorageEnforce|DefMemPerCPU" >> ~/hpc-lab-backups/before.txt
   ```

## Backups

1. The accounting database, from the `ansible` folder:
   ```
   ansible controller -b -m ansible.builtin.shell -a 'mariadb-dump --single-transaction slurm_acct_db | gzip > /root/slurm_acct_db.sql.gz'
   ansible controller -b -m ansible.builtin.fetch -a "src=/root/slurm_acct_db.sql.gz dest=$HOME/hpc-lab-backups/ flat=true"
   zcat ~/hpc-lab-backups/slurm_acct_db.sql.gz | grep -c "CREATE TABLE"
   ```
   The count should match the number of tables in the database (31 here).
2. Make the backups private:
   ```
   chmod 600 ~/hpc-lab-backups/*
   ```

The MUNGE key does not need to be restored. A new ctl01 creates a new key, and the munge role copies it to every node.

## Procedure

1. Clone the repository into a new folder:
   ```
   git clone git@github.com:SShah-ai/hpc-lab.git ~/hpc-lab-rebuild
   ```
2. Destroy and rebuild the VMs:
   ```
   cd ~/hpc-lab-rebuild/cloud-init
   ./destroy-vms.sh
   ./build-vms.sh
   ```
   `destroy-vms.sh` asks for the host's sudo password to delete the disks.
3. Wait about 90 seconds, accept the new host keys, and check the first boot:
   ```
   for ip in 192.168.56.10 192.168.56.11 192.168.56.12; do ssh -o StrictHostKeyChecking=accept-new sayed@$ip true; done
   cd ~/hpc-lab-rebuild/ansible
   ansible cluster -m ansible.builtin.raw -a 'python3.11 --version; cloud-init status'
   ```
   The `raw` module does not need Python on the node, so it works even if cloud-init failed to install Python 3.11.
4. Run the playbook twice:
   ```
   mkdir -m 700 .secrets
   ansible-playbook site.yml
   ansible-playbook site.yml
   ```
   The second run must show `changed=0`.

If any step fails, do not fix it by hand on the VMs. Fix the code, commit, and run the playbook again.

## Post-checks

1. Compare with the snapshot:
   ```
   ssh sayed@192.168.56.10 'sinfo; sacctmgr -n -P show assoc format=Cluster,Account,User' > ~/hpc-lab-backups/after.txt
   ssh sayed@192.168.56.10 'scontrol show config' | grep -E "ClusterName|AccountingStorageEnforce|DefMemPerCPU" >> ~/hpc-lab-backups/after.txt
   diff ~/hpc-lab-backups/before.txt ~/hpc-lab-backups/after.txt && echo "cluster matches the snapshot"
   ```
2. Jobs, accounting and MUNGE:
   ```
   ssh sayed@192.168.56.10 'srun -N2 hostname'
   ssh sayed@192.168.56.10 'sbatch --wrap="sleep 5"; sleep 10; sacct -X --format=JobID,User,Account,State'
   ssh sayed@192.168.56.10 munge -n | ssh sayed@192.168.56.11 unmunge | head -1
   ```
   Expect both hostnames, jobs under account `lab`, and `STATUS: Success (0)`.

## Rollback

There is no way back to the old VMs. To bring back the old job history, stop slurmdbd on ctl01 and load the dump:
```
zcat ~/hpc-lab-backups/slurm_acct_db.sql.gz | ssh sayed@192.168.56.10 'sudo mariadb slurm_acct_db'
```

## Results: 2026-11-19

| Step | Result |
|---|---|
| `build-vms.sh` | 6 seconds |
| First boot | Python 3.11.15 and `cloud-init status: done` on all three VMs |
| First playbook run | 2 min 13 s, no failures |
| Second playbook run | 43 s, `changed=0` |
| Snapshot comparison | Identical |
| MUNGE | New key, `Success (0)` between nodes |

One gap found: the `labuser` association came back, but the Linux account did not, because it had been created with ad hoc commands. The common role now creates local users from `cluster_local_users` with the same UID on every node.

A second problem followed from the first. The `labuser` association had been created while the Linux user did not exist, so slurmctld held it with no UID, and jobs from `labuser` were still rejected after the user was created. Restarting slurmctld fixed it, and the play order now creates users before associations. Details are in [the association runbook](../runbooks/job-rejected-no-association.md).
