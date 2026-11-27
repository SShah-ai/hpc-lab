# Local account shadows a directory user

## Symptom

A directory user logs in to one node and cannot open their own home directory. The password is accepted, but the session starts in the wrong home:
```
sayed@node01:~> su - aaba -c 'id; pwd; ls -ld /nfs/home/aaba; ls /nfs/home/aaba'
Password:
uid=1001(aaba) gid=1001(aaba) groups=1001(aaba),10000(hpcusers)
/home/aaba
drwx------ 2 aaba hpcusers 98 Nov 26 23:14 /nfs/home/aaba
ls: cannot open directory '/nfs/home/aaba': Permission denied
```
`ls -ld` shows aaba as the owner of the directory she was refused. Her Slurm jobs on the same node run normally, and the other nodes work. The likely report is "my files are missing on node01, but my jobs are fine".

## Checks

1. The UID on every node, from the `ansible` folder:
   ```
   ansible cluster -m command -a "id aaba"
   ```
   node01 returned `uid=1001(aaba)`. ctl01 and node02 returned `uid=10001(aaba)`. Directory users are in the range 10000 to 19999, so a lower number on one node means a local account.
2. Every local account that hides a directory user, on all nodes:
   ```
   ansible cluster -m shell -a "for u in \$(getent -s files passwd | cut -d: -f1); do getent -s sss passwd \$u >/dev/null && echo collision: \$u; done; true"
   ```
   Only node01 printed `collision: aaba`. The `\$` stops the local shell from expanding the variables before Ansible sends the command. `; true` keeps the exit code at 0, so Ansible does not report the last failed lookup as an error. The playbook runs the same check (see Prevention).
3. The two entries side by side, on the node:
   ```
   getent -s files passwd aaba
   getent -s sss passwd aaba
   ```
   ```
   aaba:x:1001:1001:local test account:/home/aaba:/bin/bash
   aaba:*:10001:10000:Aaba Lab:/nfs/home/aaba:/bin/bash
   ```
   `-s` asks one source only. A normal lookup returns only the first entry, because `/etc/nsswitch.conf` has `passwd: compat sss`, so local files come first.
4. Who created the local account, and when:
   ```
   sudo journalctl --since today --no-pager | grep -E 'useradd|userdel' | grep aaba
   ```
   ```
   Nov 27 14:34:23 node01 sudo[28103]:    sayed : TTY=pts/0 ; PWD=/home/sayed ; USER=root ; COMMAND=/usr/bin/env SSS_NSS_USE_MEMCACHE=NO useradd -m -c 'local test account' aaba
   Nov 27 14:34:23 node01 useradd[28105]: new group: name=aaba, GID=1001
   Nov 27 14:34:23 node01 useradd[28105]: new user: name=aaba, UID=1001, GID=1001, home=/home/aaba, shell=/bin/bash, from=/dev/pts/1
   ```
   sudo logs who ran the command and the full command line. useradd logs what it created. For an older account, widen `--since`. The same search showed two earlier attempts that failed with `exit code: 9` (see Notes).

## Cause

node01 had a local account named aaba, UID 1001, in `/etc/passwd`. NSS reads local files before SSSD, so every lookup of the name `aaba` on node01 returned the local account:
- **Login:** pam_unix could not check the password, because the local account has no usable password. pam_sss checked it against the directory and accepted it. The session then started as the account NSS returned for the name: UID 1001, home `/home/aaba`.
- **Files:** the NFS home is owned by UID 10001 with mode 0700, so the kernel refused UID 1001. `ls -ld` still printed `aaba`, because node01 has no local UID 10001 and SSSD maps that number to aaba. Two accounts print the same name. `ls -ldn` prints the numbers, which can be compared with `id`.
- **Groups:** the local account also got `hpcusers` (10000). Group membership is looked up by name, and the directory group lists aaba as a member. The local account gets the directory user's group access, which makes this a security problem and not only a broken login.
- **Slurm:** jobs carry the UID, not the name. `su - aaba -c 'srun -w node01 id; srun -w node02 id'` on ctl01 returned `uid=10001(aaba)` on both nodes.

useradd refuses a name that NSS already knows, including SSSD's users, so shadowing needs one of these:
- The local account existed before the directory user was added. This happened with labuser before its migration (see `docs/procedures/migrate-labuser.md`).
- The local account was created while SSSD could not answer: stopped, not set up yet, or with its memory cache bypassed, as in this drill.
- Someone edited `/etc/passwd` directly.

## Fix

On the affected node:
1. Confirm the local entry is the one to remove. It has a UID below 10000 and a home under `/home`:
   ```
   getent -s files passwd aaba
   ```
2. Check that nothing runs as the local account, and whether it owns files outside its home:
   ```
   pgrep -u 1001 -l
   sudo find / \( -path /proc -o -path /sys -o -path /nfs \) -prune -o -uid 1001 -print
   ```
   userdel refuses to remove an account that has processes running. I did not run these checks in the drill, because the account was a test account.
3. Remove the local account, its home and its private group:
   ```
   sudo userdel -r aaba
   ```
   `-r` deletes `/home/aaba`, so copy anything worth keeping first. If the local account is needed, for example as a service account, rename it with `usermod -l` and its group with `groupmod -n` instead.

No SSSD cache needs clearing. NSS reads `/etc/passwd` on every lookup, so once the local line is gone, the next lookup goes to SSSD.

## Verify

```
sayed@node01:~> id aaba
uid=10001(aaba) gid=10000(hpcusers) groups=10000(hpcusers)
sayed@node01:~> su - aaba -c 'id; pwd; ls /nfs/home/aaba'
Password:
uid=10001(aaba) gid=10000(hpcusers) groups=10000(hpcusers)
/nfs/home/aaba
hello.txt  slurm-5.out  slurm-7.out  slurm-8.out  writer.log
sayed@node01:~> getent -s files group aaba; echo "exit $?"
exit 2
sayed@node01:~> ls -d /home/aaba
ls: cannot access '/home/aaba': No such file or directory
```
`exit 2` means not found: userdel also removed the private group, because `USERGROUPS_ENAB` is on in `/etc/login.defs`. The journal showed `delete user 'aaba'` and `removed group 'aaba' owned by 'aaba'`. The next playbook run passed the shadowing check on all nodes with `changed=0`.

## Timeline from the lab

All events on node01, 27 November.

| Time | Event |
|---|---|
| 14:28:20 | `useradd aaba` with SSSD running: `user 'aaba' already exists` |
| 14:30:40 | SSSD stopped |
| 14:30:48 | `useradd` refused again |
| 14:31:01 | SSSD started |
| 14:33:38 | SSSD stopped. `getent passwd aaba` still answers. With `SSS_NSS_USE_MEMCACHE=NO` it finds nothing |
| 14:34:23 | `useradd` with `SSS_NSS_USE_MEMCACHE=NO`: local aaba created, UID and GID 1001 |
| 14:34:36 | SSSD started. `id aaba` on node01 shows UID 1001 |
| After 14:36 | Collision check flags node01. `su` lands as UID 1001. `srun` jobs run as 10001 |
| Before 14:50 | Playbook with the new checks: node01 fails with `Local accounts hide directory users: aaba` |
| 14:50:19 | `userdel -r aaba`: user, home and private group removed |
| 14:50:56 | `id aaba` returns 10001. `su` lands in `/nfs/home/aaba` |
| After 14:51 | Playbook passes with `changed=0`. Commit `858117d` |

## Notes

- **useradd's guard and SSSD's memory cache.** With SSSD running, useradd refused with `user 'aaba' already exists`, logged as `exit code: 9` (name already in use). It refused again 8 seconds after SSSD was stopped. The NSS library reads SSSD's memory cache in `/var/lib/sss/mc/` directly, without the daemon. With SSSD stopped, `getent passwd aaba` still returned the directory entry, and `SSS_NSS_USE_MEMCACHE=NO getent passwd aaba` returned nothing (exit code 2). useradd went ahead only with that variable set. So stopping SSSD does not stop directory lookups on a node straight away.
- **The check is a hard stop.** In the first playbook run with the check, node01 failed at the assert, and Ansible dropped it from the remaining plays: the AutoFS and Slurm plays ran on node02 only. Until the account is fixed, no playbook run changes that node. I chose a failure over a warning, because a warning is easy to miss in a long run.
- **The check asks SSSD.** If the directory is unreachable, SSSD only knows the users it has cached, so a collision with a user it has not cached would go unnoticed until SSSD is back online. I did not test this.

## Prevention

- **The playbook fails on any shadowing account** (ldap_client role, commit `858117d`). It catches both orders: a local account created after the directory user, and a directory user added with a name that already exists locally on a node. It runs only when the playbook runs. Monitoring could run the same loop more often.
- **New local UIDs and GIDs stay below 10000** (common role, same commit). `UID_MAX` and `GID_MAX` in `/etc/login.defs` went from 60000 to 9999. By default useradd gives a new account the next ID above the highest one in use, up to `UID_MAX`. With 60000, one local account given a high ID by hand would push the next ones into the directory's range. This protects numbers, not names: this drill's account got 1001, which is still allowed.
- **Local accounts the cluster needs go in `cluster_local_users`**, with fixed UIDs below 10000, rather than being created by hand on a node.
