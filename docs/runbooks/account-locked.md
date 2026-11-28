# Account locked: the directory refuses the user

## Symptom

A directory user cannot log in with the right password:
```
sayed@node01:~> su - lala -c 'id'
Password:
su: Authentication failure
```
This is the same message as a wrong password. `id lala` and `getent passwd lala` still work, so the account looks normal from the outside.

## Checks

1. The account state, on ctl01:
   ```
   sudo dsidm hpclab -b dc=hpc,dc=lab account entry-status uid=lala,ou=people,dc=hpc,dc=lab
   ```
   A locked account shows `Entry State: directly locked through nsAccountLock`. A normal one shows `activated`. Root on ctl01 uses the local LDAPI socket, so there is no password prompt.
2. The same from any node, as SSSD sees it:
   ```
   sudo sed -n 's/^ldap_default_authtok = //p' /etc/sssd/sssd.conf | tr -d '\n' | ldapsearch -x -D cn=sssd,ou=services,dc=hpc,dc=lab -y /dev/stdin -LLL uid=lala nsAccountLock
   ```
   `nsAccountLock: true` means locked. No `nsAccountLock` line means not locked. This binds as SSSD's account with the password from the node's `sssd.conf`, without showing it. Anonymous searches have been refused since commit `e3f2d28`.
3. A bind as the user, with their password:
   ```
   ldapwhoami -x -D uid=lala,ou=people,dc=hpc,dc=lab -W
   ```
   ```
   ldap_bind: Server is unwilling to perform (53)
       additional info: Account inactivated. Contact system administrator.
   ```
   A wrong password gives `Invalid credentials (49)` instead, so this tells the two apart.
4. SSSD's account check, which needs no password:
   ```
   sudo sssctl user-checks lala -a acct -s login
   sudo sssctl user-checks lala -a acct -s sshd
   ```
   Both returned `pam_acct_mgmt: Permission denied` while the account was locked. Ignore the InfoPipe line.
5. The journal on the node:
   ```
   sudo journalctl --since "15 min ago" --no-pager | grep -E "pam_sss|su\[" | grep lala
   ```
   ```
   pam_sss(su-l:auth): received for user lala: 7 (Authentication failure)
   pam_sss(login:account): Access denied for user lala: 6 (Permission denied)
   ```
   Code 7 in the `auth` step is what a wrong password also gives, so the journal alone does not show a lock. Code 6 in the `account` step is SSSD refusing the account. Use check 1 or 2 to confirm a lock.

## Cause

The account was locked in 389 DS with `dsidm ... account lock`, which sets `nsAccountLock: true` on the entry. Two things then refuse the user:
- 389 DS refuses every bind for the account, so any login that checks the password fails in PAM's `auth` step. That is the `su` failure above.
- SSSD reads `nsAccountLock` in PAM's `account` step (`access_provider = ldap`, `ldap_account_expire_policy = rhds`) and refuses the account. This step runs even when no password is checked, so it is what stops SSH key logins.

## Fix

If the lock was not intended, unlock the account on ctl01:
```
sudo dsidm hpclab -b dc=hpc,dc=lab account unlock uid=lala,ou=people,dc=hpc,dc=lab
sudo dsidm hpclab -b dc=hpc,dc=lab account entry-status uid=lala,ou=people,dc=hpc,dc=lab
```
Expect `Entry State: activated`. No cache needs clearing on the nodes.

## Verify

```
sudo sssctl user-checks lala -a acct -s login
su - lala -c 'id'
```
After the unlock, the account check returned `Success` and lala logged in. Both the lock and the unlock took effect at once, because SSSD fetches the user's entry again for each PAM request (`pam_id_timeout`, 5 seconds by default).

## Locking an account on purpose

```
sudo dsidm hpclab -b dc=hpc,dc=lab account lock uid=lala,ou=people,dc=hpc,dc=lab
```
A lock stops the user logging in. It does not stop everything:
- Root can still become the user. `sudo su - lala` worked while the account was locked, and the journal showed no `pam_sss` line at all. `/etc/pam.d/su-l` has `account sufficient pam_rootok.so`, so root skips the account step entirely.
- SSH is covered. `/etc/pam.d/sshd` includes `common-account` without that rule, and `sshd -T` shows `usepam yes`, so sshd runs the account step after any login. I tested this with `sssctl ... -s sshd`, not with a real key login.
- Slurm does not use PAM to start jobs in this setup, so a lock alone should not stop jobs that are already queued or running. I did not test this. When removing a user, also cancel their jobs with `scancel -u lala` and remove or limit their Slurm association.

## Timeline from the lab

| Time | Event |
|---|---|
| 13:04:26 | lala locked with `dsidm` |
| 13:06:12 | SSSD account check denied (`login` service) |
| 13:15:09 | `su - lala` with the right password: `Authentication failure` (code 7) |
| 13:15:50 | `sudo su - lala` as root: succeeded |
| 13:17:40 | Unlocked; account check `Success`, `su - lala` works |
| 13:22 to 13:27 | Locked again; account check for the `sshd` service denied; unlocked at 13:27:05 |

## Notes

- I did not test a lock made while SSSD is offline. In that state SSSD only has what it cached, so the lock may not apply until the node is back online.
- `dsidm` writes the change straight to the directory. The ldap_accounts role only creates entries and never changes existing ones, so a playbook run does not undo a lock.

## Prevention

- Lock accounts with `dsidm` rather than deleting them, so the UID stays reserved and the user's files keep a known owner.
- Keep root access limited. A lock does not protect a user's files from root on any node.
