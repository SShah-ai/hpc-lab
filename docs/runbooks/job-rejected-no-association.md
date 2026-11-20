# Job rejected: user has no association

## Symptom

A user's job is refused at submission:
```
sbatch: error: Batch job submission failed: Invalid account or account/partition combination specified
```
The user did not ask for any account, so the message does not point to the real cause.

## Checks

1. Whether associations are enforced, on ctl01:
   ```
   scontrol show config | grep -i AccountingStorageEnforce
   ```
   It showed `AccountingStorageEnforce = associations`. This shows the setting the running controller is using, which can differ from the file on disk if the daemon was not restarted.
2. Whether the user has an association:
   ```
   sacctmgr show assoc format=Cluster,Account,User
   ```
   There was no row for `labuser`.
3. Whether the same job works for a user who has one. My own job (`sayed`) was accepted at the same time.

## Cause

`slurm.conf` sets `AccountingStorageEnforce=associations`, so Slurm only accepts jobs from users with an association (cluster, account and user). `labuser` had none.

## Fix

Add the user to `slurm_user_list` in `ansible/group_vars/controller/vars.yml` and run the playbook. The `slurm_accounts` role adds the missing association:
```
ansible-playbook site.yml
```
By hand, the same change is:
```
sudo sacctmgr -i add user labuser Account=lab
```
No restart was needed. The next job from `labuser` was accepted straight away.

## Verify

- `sacctmgr show assoc` lists `hpclab | lab | labuser`.
- The user's job is accepted and runs.
- `sacct -X -u labuser --format=JobID,User,Account,State` shows the job under account `lab`.

## Before and after

| Job | When | Result |
|---|---|---|
| 24 | Before enforcement | `COMPLETED`, no account |
| (none) | Enforcement on, no association | Rejected at submission |
| 26 | After the association was added | `COMPLETED`, account `lab` |

## Notes

- A job runs on the compute node as the user's UID, so the Linux account must exist on every node with the same UID. I created `labuser` (UID 2001) with Ansible ad hoc commands. That user is not in the repository yet, so a rebuild would bring back the association but not the Linux user. LDAP with SSSD is the usual fix.
- `associations` only requires that an association exists. Limits set on associations are applied with `limits`.

## Prevention

- Manage associations in code, as the `slurm_accounts` role does, so adding a user is one entry in a list.
- Create the Linux account and the association in the same change, so neither exists without the other.

## Second cause: association created before the Linux user existed

Found during the rebuild test. The error was the same, but the user did have an association.

### Checks

1. The association exists in the database:
   ```
   sacctmgr -n -P show assoc where user=labuser format=Cluster,Account,User
   ```
   It returned `hpclab|lab|labuser`.
2. The controller's own copy of the user:
   ```
   scontrol show assoc_mgr flags=users users=labuser,sayed
   ```
   ```
   UserName=sayed(1000) DefAccount=lab
   UserName=labuser(4294967294) DefAccount=(null)
   ```
   `sayed` is linked to UID 1000. `labuser` shows 4294967294 (0xFFFFFFFE), the value Slurm uses for "no value": the controller never linked the name to a UID.
3. The controller log had nothing about `labuser`. Only `scontrol show assoc_mgr` showed the problem.

### Cause

During the rebuild, the association was created before the Linux user `labuser` existed on ctl01. slurmctld turns user names into UIDs when it loads associations, and jobs arrive with a UID. Creating the user afterwards did not update the controller's copy.

### Fix

`sudo scontrol reconfigure` was not enough. It set the UID to 2001, but the user still had `DefAccount=(null)` and jobs were still rejected. Restarting the controller fixed it:
```
sudo systemctl restart slurmctld
```
The next job from `labuser` was accepted and ran under account `lab`.

### Prevention

- Create the Linux user before the association. The common role, which creates local users, runs in the first play, and the `slurm_accounts` role runs in the last, so a fresh build now does them in the right order.
- With users from LDAP, the same failure can happen if an association is added before the directory is reachable from the controller. Check `id <user>` on ctl01 first.
