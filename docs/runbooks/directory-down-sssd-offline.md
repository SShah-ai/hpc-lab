# Directory down: SSSD answers from its cache

## Symptom

Some directory users can log in and others cannot, with the right password. On node02 during the outage:
```
sayed@node02:~> su - lala -c 'id'
Password:
su: Permission denied
```
aaba logged in on the same node without a problem. `id` and `getent` still returned every user, and jobs for known users kept running, so the outage is easy to miss. Local accounts such as root and sayed were not affected.

## Checks

1. Whether the directory answers, from any node:
   ```
   ldapsearch -x -LLL -s base -b "" namingContexts
   ```
   Normally `namingContexts: dc=hpc,dc=lab`. If the server is down, it fails with `Can't contact LDAP server (-1)`. This reads the root DSE, the only thing anonymous clients may still read. In the drill this check was `ldapwhoami -x`, which returned `anonymous` normally and `ldap_sasl_bind(SIMPLE): Can't contact LDAP server (-1)` during the outage. Since anonymous reads were limited (commit `e3f2d28`), `ldapwhoami -x` fails with `Inappropriate authentication (48)` even when the server is fine.
2. Whether lookups still work:
   ```
   time id lala
   ```
   It answered in 4 ms, from SSSD's cache.
3. Why the login was refused:
   ```
   sudo journalctl --since "10 min ago" --no-pager | grep -E "pam_sss|su\["
   ```
   ```
   pam_sss(su-l:auth): authentication failure; ... user=lala
   pam_sss(su-l:auth): received for user lala: 6 (Permission denied)
   ```
   Code 6 (`Permission denied`) with the right password means SSSD was offline and had no cached password for that user on that node. A wrong password while the directory is up gives `Authentication failure` instead.
   The `pam_unix ... authentication failure` line before it shows up for every directory user login, successful or not. pam_unix runs first and does not find the user in the local files. It is not the problem.
4. SSSD's own log:
   ```
   sudo tail -n 20 /var/log/sssd/sssd_hpc.lab.log
   ```
   ```
   [fo_resolve_service_send] (0x0020): No available servers for service 'LDAP'
   [sbus_issue_request_done] (0x0040): sssd.dataprovider.getAccountInfo: Error [1432158212]: SSSD is offline
   ```
   The lines marked `*` above these are SSSD's backtrace: recent detailed messages it keeps in memory and writes out when an error is logged.
5. The directory server, on ctl01:
   ```
   systemctl is-active dirsrv@hpclab
   ```

## Cause

389 Directory Server on ctl01 was stopped. SSSD switched to offline mode and answered from its cache:
- identities of users the node had looked up before (UID, groups, home);
- logins, checked against a password hash that SSSD stores after each successful online login (`cache_credentials = true`).

aaba had logged in on node02 before, so her hash was cached there. lala had never logged in on node02, so SSSD had nothing to check her password against.

## Fix

1. Start the directory server on ctl01:
   ```
   sudo systemctl start dirsrv@hpclab
   ```
2. SSSD retries the server on its own schedule. I did not wait for that. To bring every node back online at once, from the `ansible` folder:
   ```
   ansible cluster -b -m command -a "systemctl kill -s SIGUSR2 sssd"
   ```
   SIGUSR2 tells SSSD to go online immediately.

## Verify

```
ldapsearch -x -LLL -s base -b "" namingContexts
su - lala -c 'id'
```
After SIGUSR2, the directory answered on both compute nodes (`ldapwhoami -x` returned `anonymous`, before anonymous reads were limited), and lala logged in on node02. That login went to the directory, which shows her password was right all along, and it stored her password hash on node02.

## Timeline from the lab

| Time | Event |
|---|---|
| 22:52:17 | dirsrv@hpclab stopped |
| 22:54:01 | aaba logs in on node02 from the cache |
| 22:54:17 | lala refused on node02; SSSD logs `No available servers for service 'LDAP'` |
| Shortly after 22:55 | Job 7 submitted as aaba on ctl01, runs on node01 and node02 |
| 23:00:24 | dirsrv@hpclab started |
| Right after | SIGUSR2 sent to SSSD on every node; `ldapwhoami` answers again |
| Then | lala logs in on node02 |

## Notes

- Offline login only works on nodes where the user has logged in while the directory was up. A user who has only ever used node01 cannot log in to node02 during an outage.
- Jobs need the user's identity on each node, not the password. Job 7 ran on both compute nodes because both had looked up aaba before. I did not test a user that a node had never looked up.
- I did not measure how long SSSD takes to reconnect by itself without SIGUSR2.
- Cached passwords do not expire. `offline_credentials_expiration` in the `[pam]` section defaults to 0, which means no limit.
- A cached hash is only updated by the next online login. If a password is changed in the directory, a node that cached the old one accepts the old one while offline.
- Users added to the directory during the outage cannot be looked up anywhere.
- Local accounts never depended on the directory. SSH as sayed worked throughout.

## Prevention

- With one directory server, ctl01 is a single point of failure for logins. A production cluster would run a second 389 DS server with replication and list both in `ldap_uri`, so SSSD fails over to the second.
- Monitoring should alert when `dirsrv@hpclab` is down or nothing answers on port 636.
- Keep at least one local admin account on every node that does not depend on the directory.
- To practise this without stopping the server, `systemctl kill -s SIGUSR1 sssd` makes SSSD act as if it were offline for the length of `offline_timeout`.
