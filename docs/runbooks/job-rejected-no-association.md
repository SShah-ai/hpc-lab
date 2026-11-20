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
