# Directory TLS: the node does not trust the server's CA

## Symptom

On one node, SSSD goes offline and stays offline while the directory server is running. `ldapwhoami` fails with the same message as when the server is down:
```
ldap_sasl_bind(SIMPLE): Can't contact LDAP server (-1)
```
Lookups still work from the cache, and users with no cached password on that node are refused with `su: Permission denied`. The other nodes work normally.

## Checks

1. One node or all, from the `ansible` folder:
   ```
   ansible cluster -m command -a 'ldapsearch -x -LLL -s base -b "" namingContexts'
   ```
   A node that reaches the server prints `namingContexts: dc=hpc,dc=lab`. In the drill this check was `ldapwhoami -x`: node01 returned `anonymous` and node02 failed, so the server was fine and the problem was on node02. Since anonymous reads were limited (commit `e3f2d28`), `ldapwhoami -x` fails with `Inappropriate authentication (48)` on every node, so it no longer tells a healthy node from a broken one.
2. The TLS check from the node:
   ```
   openssl s_client -connect ctl01.hpc.lab:636 -verify_hostname ctl01.hpc.lab </dev/null 2>/dev/null | grep 'Verify return code'
   ```
   `19 (self-signed certificate in certificate chain)`. Normally `0 (ok)`.
3. SSSD's log on the node:
   ```
   sudo grep "ldap_install_tls failed" /var/log/sssd/sssd_hpc.lab.log | tail -n 1
   ```
   ```
   ldap_install_tls failed: [Connect error] [error:1416F086:SSL routines:tls_process_server_certificate:certificate verify failed (self signed certificate in certificate chain)]
   ```
   This line names the cause. `Can't contact LDAP server` from `ldapwhoami` does not tell a TLS failure from a stopped server.
4. The CA the node trusts, compared with the one on ctl01:
   ```
   openssl x509 -in /etc/pki/trust/anchors/hpclab-ldap-ca.crt -noout -subject -fingerprint -sha256
   sudo openssl x509 -in /etc/dirsrv/slapd-hpclab/ca.crt -noout -subject -fingerprint -sha256
   ```
   Run the first on the node and the second on ctl01. The fingerprints must match. In the drill, node02 showed `CN = wrong-ca.hpc.lab` and a different fingerprint.

## Cause

node02's trusted CA file, `/etc/pki/trust/anchors/hpclab-ldap-ca.crt`, held a certificate from a different CA. Both `ldap.conf` and `sssd.conf` use that file. The server's certificate was valid, but node02 could not verify it, so every TLS connection failed and SSSD went offline. The same happens if the directory on ctl01 is rebuilt (dscreate makes a new CA) and a node keeps the old one.

## Fix

Run the playbook from the `ansible` folder:
```
ansible-playbook site.yml
```
The ldap_client role copies the CA that was fetched from ctl01 (`ansible/.secrets/ldap-ca.crt`), updates the trust store and restarts SSSD. In the drill, only node02 changed (3 changes).

## Verify

```
openssl x509 -in /etc/pki/trust/anchors/hpclab-ldap-ca.crt -noout -subject -fingerprint -sha256
ldapsearch -x -LLL -s base -b "" namingContexts
sudo sss_cache -E
id labuser
sudo grep -E "ldap_install_tls failed|SSSD is offline" /var/log/sssd/sssd_hpc.lab.log | tail -n 2
```
The fingerprint matched the original (`CA:97:1A:...:CC:91`), the directory answered (`ldapwhoami -x` returned `anonymous`, before anonymous reads were limited), and the forced refresh logged no new errors: the last ones were from 14:09:31, before the playbook ran. A second playbook run showed `changed=0`.

`sss_cache -E` followed by `id` makes SSSD go to the directory for that user. A login is not a good test here, because a user with a cached password can log in while SSSD is offline.

## Timeline from the lab

| Time | Event |
|---|---|
| 13:52 | node02's CA replaced with `wrong-ca.hpc.lab`, SSSD restarted |
| 13:54:18 | SSSD: `Backend is offline` |
| 13:55:15 | SSSD: `ldap_install_tls failed ... certificate verify failed` |
| About 13:58 | Playbook restores the CA file (2 changes on node02). `ldapwhoami` works, SSSD stays offline |
| 14:01:07 | SSSD restarted by hand; labuser logs in |
| 14:07:58 | Broken again to test the role fix; TLS failure logged |
| About 14:10 | Playbook with the fixed role: 3 changes on node02, including the SSSD restart |
| 14:11:18 | Forced refresh logs no new errors; `ldapwhoami` works |

## Notes

- The first run of the playbook replaced the CA file but did not restart SSSD. `ldapwhoami` worked at once, because it reads the file each time it runs. SSSD stayed offline after SIGUSR2 and two login attempts, and only `systemctl restart sssd` brought it back. I did not find out why SSSD kept failing. The role now restarts SSSD whenever the CA file changes, and the second test showed the playbook alone is enough.
- To show the failure, SSSD had to be restarted after the CA was replaced. A TLS connection that is already open does not check the certificate again, so on a real node the problem would appear at the next reconnect or reboot.
- The SSSD log line was the quickest way to the cause. The first lines of `ldapwhoami -d 1` only showed the TLS handshake starting.

## Prevention

- The CA is fetched from ctl01 and copied to every node on each playbook run, so a rebuilt directory is picked up by the next run.
- The CA task restarts SSSD when the file changes (commit `7ccf075`).
- Monitoring could compare the fingerprint of the trusted CA on each node with the one on ctl01, and alert on `ldap_install_tls failed` in SSSD logs.
