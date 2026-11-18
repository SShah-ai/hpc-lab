# Node DOWN: clock skew breaks MUNGE

## Symptom

A job sent to the node fails straight away:
```
srun: error: slurm_receive_msgs: [[node02.hpc.lab]:6818] failed: Zero Bytes were transmitted or received
srun: error: Task launch for StepId=16.0 failed on node node02: Zero Bytes were transmitted or received
```
A few minutes later `sinfo` shows the node as `down*`. This is the same user-facing error as a stopped MUNGE. Only the node's own log tells the two apart.

## Checks

1. The node's slurmd log:
   ```
   tail -10 /var/log/slurm/slurmd.log
   ```
   I saw:
   ```
   error: Munge decode failed: Expired credential
   auth/munge: _print_cred: ENCODED: Tue Nov 17 22:49:03 2026
   auth/munge: _print_cred: DECODED: Tue Nov 17 22:59:03 2026
   ```
   The encode and decode times are ten minutes apart.
2. The clocks on every node, from the Ansible host:
   ```
   ansible cluster -a 'timedatectl'
   ```
   node02 was ten minutes ahead and showed `System clock synchronized: no` and `NTP service: inactive`.
3. Time sync on the node:
   ```
   chronyc tracking
   ```
   It returned `506 Cannot talk to daemon`: chronyd was not running.
4. MUNGE between nodes, in both directions:
   ```
   ssh sayed@ctl01 munge -n | ssh sayed@node02 unmunge
   ssh sayed@node02 munge -n | ssh sayed@ctl01 unmunge
   ```
   The first returned `Expired credential (15)` and the second `Rewound credential (16)`.

## Cause

chronyd was stopped on node02 and its clock was ten minutes ahead. A MUNGE credential is valid for 300 seconds, and the node decoding it checks the time against its own clock. A credential that looks older than 300 seconds is expired. One that looks as if it was made in the future is rewound.

## Fix

1. Start chronyd on the node:
   ```
   sudo systemctl start chronyd
   ```
   SUSE's `/etc/chrony.conf` has `makestep 1.0 3`: if the clock is off by more than one second during the first three updates after chronyd starts, it sets the time at once instead of correcting it slowly. In my test, 30 seconds after the start `chronyc tracking` showed `0.000082263 seconds slow`, so the restart alone fixed the clock. `chronyc makestep` forces the same correction if a clock is still off.
2. Restart slurmd on the node so it registers again:
   ```
   sudo systemctl restart slurmd
   ```
   The node went from `down*` straight back to `idle`, without `scontrol resume`.

## Verify

- `date` shows the same time on every node.
- `chronyc tracking` on the node shows `Leap status : Normal` and an offset well under a second.
- Both `unmunge` tests return `Success (0)`.
- `srun -w node02 hostname` prints `node02`.

## Notes

- `date -s` changed only the system clock. `timedatectl` still showed the hardware clock (RTC) at the correct time.
- After the restart, node02 synced to a different time server than ctl01 and node01. Each node picks its own servers from the public pool.

## Prevention

- The common role keeps chronyd enabled and running, so a playbook run would have started it again.
- A monitoring check on each node for `System clock synchronized: yes`, or on the offset in `chronyc tracking`, would catch this before users do.
- On a production cluster, every node should use the same internal time servers, so the nodes never drift apart from each other even if the outside source is wrong.
