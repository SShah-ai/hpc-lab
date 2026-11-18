# Node DOWN: MUNGE not running on the node

## Symptom

A job sent to the node fails straight away:
```
srun: error: slurm_receive_msgs: [[node01.hpc.lab]:6818] failed: Zero Bytes were transmitted or received
srun: error: Task launch for StepId=14.0 failed on node node01: Zero Bytes were transmitted or received
```
The error does not mention MUNGE. `sinfo` first showed the node as `comp*` (a step stuck completing, node not responding), and a few minutes later as `down*`.

## Checks

1. The controller's view, on ctl01:
   ```
   scontrol show node node01 | grep -E "State|Reason"
   sudo grep -i node01 /var/log/slurm/slurmctld.log | tail -5
   ```
   I saw `State=DOWN+NOT_RESPONDING`, `Reason=Not responding`, and log lines ending in `Nodes node01 not responding, setting DOWN`.
2. The node's own log:
   ```
   tail -15 /var/log/slurm/slurmd.log
   ```
   This named the cause:
   ```
   Munge decode failed: Failed to access "/run/munge/munge.socket.2": No such file or directory (Did you start munged?)
   REQUEST_PING has authentication error: Invalid authentication credential
   ```
3. The service on the node:
   ```
   systemctl is-active munge
   ```
   It returned `inactive`.

Start with the controller, then the node's log, then the service. The user-facing error alone does not point to MUNGE.

## Cause

`munged` was stopped on node01. Every message between slurmctld and slurmd carries a MUNGE credential. Without munged, slurmd could not decode the controller's pings, so the controller stopped hearing from the node.

## Fix

1. Start MUNGE on the node:
   ```
   sudo systemctl start munge
   ```
2. The node did not come back by itself. `ReturnToService=2` returns a DOWN node when it registers again, and slurmd had been running throughout, so it never re-registered. Resume it by hand on ctl01:
   ```
   sudo scontrol update nodename=node01 state=resume
   ```
   Restarting slurmd on the node should also work, because slurmd registers when it starts. I have not tested that yet.

## Verify

```
srun -w node01 hostname
sinfo
```
The job printed `node01`, and the node was back in the partition.

## Timeline from the lab

| Time | Event |
|---|---|
| 21:34:06 | First authentication errors in both logs |
| 21:36:27 | Controller logs `Nodes node01 not responding` |
| 21:38:37 | Controller sets node01 `DOWN` |

About four and a half minutes passed before the node went DOWN. That fits the default `SlurmdTimeout` of 300 seconds. Until then, the node can look normal while jobs sent to it fail.

## Prevention

- The munge role enables munge at boot, and running `ansible-playbook site.yml` starts it again if it has stopped.
- A monitoring check on munged on every node would catch this before users do.
- When a node goes DOWN, check munge, the MUNGE key and time sync first. Those three cause most authentication failures between Slurm daemons.
