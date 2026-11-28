# Directory refuses SSSD's bind password

## Symptom

On one node, SSSD goes offline while the directory server is running and the other nodes work. Lookups still answer from the cache: `id lala` worked even after `sss_cache -E`. SSSD's log at its default level does not say why:
```
(2026-11-27 18:36:18): [be[hpc.lab]] [sbus_issue_request_done] (0x0040): sssd.dataprovider.getAccountInfo: Error [1432158212]: SSSD is offline
```
This is the same message as when the server is down. As in [directory-down-sssd-offline.md](directory-down-sssd-offline.md), users with no cached password on that node cannot log in. I did not test logins again in this drill.

## Checks

1. The password each node has stored, tested against the directory, from the `ansible` folder:
   ```
   ansible cluster -b -m shell -a "sed -n 's/^ldap_default_authtok = //p' /etc/sssd/sssd.conf | tr -d '\n' | ldapwhoami -x -D cn=sssd,ou=services,dc=hpc,dc=lab -y /dev/stdin"
   ```
   ```
   ctl01 | CHANGED | rc=0 >>
   dn: cn=sssd,ou=services,dc=hpc,dc=lab
   node02 | FAILED | rc=49 >>
   ldap_bind: Invalid credentials (49)non-zero return code
   node01 | CHANGED | rc=0 >>
   dn: cn=sssd,ou=services,dc=hpc,dc=lab
   ```
   This reads the bind password from the node's own `sssd.conf` and binds with it, as SSSD does. The password goes through the pipe and never appears on screen or in a command line. `-y` sends the whole input as the password, including a trailing newline, so `tr -d '\n'` removes it. `rc=49` means the directory refused the password. A TLS or network problem gives `Can't contact LDAP server (-1)` instead (see [directory-tls-untrusted-ca.md](directory-tls-untrusted-ca.md)).
2. The directory's view, on ctl01. Every bind by the SSSD account, with the time, the client address and the result:
   ```
   log=/var/log/dirsrv/slapd-hpclab/access
   sudo awk '/ connection from / { ip[$3] = $(NF-2); op[$3] = "" }
             /BIND dn="cn=sssd,/ { op[$3] = $4 }
             / RESULT / && $4 == op[$3] { print substr($1, 2, 20), ip[$3], $6 }' $log | tail -n 25
   ```
   ```
   27/Nov/2026:18:49:40 192.168.56.12 err=49
   27/Nov/2026:18:49:40 192.168.56.12 err=49
   27/Nov/2026:18:49:46 192.168.56.11 err=0
   27/Nov/2026:18:49:54 192.168.56.10 err=0
   27/Nov/2026:18:50:55 192.168.56.12 err=49
   27/Nov/2026:18:50:57 192.168.56.12 err=49
   27/Nov/2026:18:51:02 192.168.56.12 err=49
   27/Nov/2026:18:51:02 192.168.56.12 err=49
   ```
   The `awk` follows each connection from its `connection from` line. 389 DS numbers connections from 1 again every time it starts, so a plain `grep` for one connection number can also match an older connection. 389 DS buffers this log, so the newest lines can take a few seconds to appear.

## Cause

node02's `sssd.conf` held a password the directory did not have. In the drill, the vault got a new password and `ansible-playbook site.yml --limit node02` pushed it to node02 only. The directory play runs on ctl01, so the run skipped it (`skipping: no hosts matched`). node02 failed as soon as the handler restarted SSSD.

Before commit `36b1835`, the ldap_accounts role only created the bind account. On every later run, `ldapadd` returned 68 (entry already exists), so a full run would also have left the directory with the old password and pushed the new one to every node. The opposite also breaks every node: a password changed in the directory by hand, with the old one left in the vault and on the nodes.

## Fix

Make the vault, the directory and every node agree. Since commit `36b1835`, a full playbook run does this:
```
ansible-playbook site.yml
```
- In the directory play, the role binds as `cn=sssd` with the vault password. If the directory refuses it (49), the role replaces `userPassword` with it, and "Set the SSSD bind account password from the vault" shows `changed`.
- In the LDAP clients play, any node whose `sssd.conf` differs from the vault gets the new file and restarts SSSD.

Do not use `--limit` with a compute node for this, because it skips the directory play.

A node whose `sssd.conf` already matches the vault is not restarted. It reconnects at its next retry: node02 bound successfully 39 seconds after the directory changed. To skip the wait, `ansible node02 -b -m command -a "systemctl kill -s SIGUSR2 sssd"` tells SSSD to go online now. It was not needed in the drill.

## Verify

Run check 1 again. All three nodes returned `dn: cn=sssd,ou=services,dc=hpc,dc=lab`. The report from check 2 showed the change and each node's first successful bind:
```
27/Nov/2026:18:54:55 192.168.56.12 err=49
27/Nov/2026:18:55:17 local err=49
27/Nov/2026:18:55:33 192.168.56.10 err=0
27/Nov/2026:18:55:40 192.168.56.11 err=0
27/Nov/2026:18:55:57 192.168.56.12 err=0
27/Nov/2026:18:55:58 192.168.56.12 err=0
```
`local` is the role's check over the local socket, refused before the role set the new password. The entry's `modifyTimestamp` moved to `20261127235518Z` (UTC, 18:55:18 local):
```
sudo ldapsearch -Q -Y EXTERNAL -H ldapi://%2Fvar%2Frun%2Fslapd-hpclab.socket -LLL -s base -b cn=sssd,ou=services,dc=hpc,dc=lab modifyTimestamp
```
A second playbook run showed `changed=0`, with the "Set" task skipped.

## Rotating the password on purpose

From the `ansible` folder:
1. Put a new password in the vault. It never appears on screen:
   ```
   ansible-vault view group_vars/cluster/vault.yml \
     | NEWPW="$(openssl rand -base64 24)" awk '/^vault_ldap_sssd_bind_password:/ { print "vault_ldap_sssd_bind_password: \"" ENVIRON["NEWPW"] "\""; next } { print }' \
     | ansible-vault encrypt --output group_vars/cluster/vault.yml.new -
   head -1 group_vars/cluster/vault.yml.new
   ansible-vault view group_vars/cluster/vault.yml.new | awk -F'"' '/^vault_ldap_sssd_bind_password:/ { print length($2) }'
   mv group_vars/cluster/vault.yml.new group_vars/cluster/vault.yml
   ```
   `head -1` must show `$ANSIBLE_VAULT;1.1;AES256` and the length must be 32. Nothing is written to disk unencrypted, and `NEWPW` exists only inside the `awk` process.
2. Run the playbook on all nodes, without `--limit`:
   ```
   ansible-playbook site.yml
   ```
   The directory play runs before the LDAP clients play, so the directory changes first and each node then gets the new `sssd.conf` and restarts SSSD. In the drill, ctl01 and node01 bound with the new password 15 and 22 seconds after the directory changed.
3. Before committing, while `HEAD` still holds the old vault, prove the old password is refused:
   ```
   git show HEAD:./group_vars/cluster/vault.yml | ansible-vault view - | sed -n 's/^vault_ldap_sssd_bind_password: *//p' | tr -d "\"'\n" | ssh sayed@192.168.56.10 'ldapwhoami -x -D cn=sssd,ou=services,dc=hpc,dc=lab -y /dev/stdin'
   ```
   Expect `ldap_bind: Invalid credentials (49)`.
4. Run check 1 (every node `rc=0`), run the playbook again (`changed=0`), then commit the vault.

To roll back before committing, `git checkout -- group_vars/cluster/vault.yml` and a full run should set the old password again in the directory and on every node. I did not test the rollback.

## Timeline from the lab

| Time | Event |
|---|---|
| Before 18:36 | New password in the vault. `ansible-playbook site.yml --limit node02` updates node02's `sssd.conf` and restarts SSSD |
| 18:36:02 | node02's SSSD log: `SSSD is offline` |
| 18:37:18 | Directory: bind as `cn=sssd` from 192.168.56.12, `err=49` |
| 18:49:40 | Check 1: node02 `rc=49`, ctl01 and node01 accepted |
| 18:50:55 to 18:54:55 | node02 retries: 4 failed binds per round, a round every 70 to 85 seconds |
| 18:55:17 | Full run with the fixed role: its check is refused (`local err=49`) |
| 18:55:18 | Directory password replaced |
| 18:55:33 and 18:55:40 | ctl01 and node01 restart SSSD and bind with the new password |
| 18:55:57 | node02 binds successfully, without a restart |
| 18:56:06 | Playbook finished |
| After 18:56 | Old password refused, every node accepts the new one, second run `changed=0`, commit `36b1835` |

## Notes

- SSSD's log at its default level did not name the cause, only `SSSD is offline`. In the TLS drill it logged `ldap_install_tls failed`. Check 1 or the directory's access log is the quickest way to the cause.
- node02's retry gap stayed between 70 and 85 seconds over four rounds. As far as I know, sssd.conf(5) describes the delay between offline retries as growing after each failure. I do not know why it did not grow here.
- node02 made 18 failed binds between 18:49:40 and 18:54:55 alone. `sudo dsconf hpclab pwpolicy get` shows `passwordlockout: off`, which is why that was harmless. With lockout on, one node with a stale password could lock the account that every node uses.
- The `--limit node02` run also failed later, in the slurm play (`object of type 'dict' has no attribute 'processor_vcpus'`), because `slurm.conf` is built from every compute node's facts. Fixed in commit `7e0272b` and tested with `--limit node02` and `--limit ctl01`.

## Prevention

- The ldap_accounts role sets the directory password from the vault when a bind with it fails (commit `36b1835`), so the vault is the only place to change it.
- Rotate with a full playbook run, never with `--limit`.
- If a lockout policy is turned on later, give the bind account a separate password policy without lockout.
- Monitoring could alert on `err=49` for `cn=sssd` in the directory's access log.
