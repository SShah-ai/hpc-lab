# Accounting down: slurmdbd not running

## Symptom

Accounting commands fail:
```
sacct: error: slurm_persist_conn_open_without_init: failed to open persistent connection to host:ctl01:6819: Connection refused
sacct: error: Sending PersistInit msg: Connection refused
sacct: error: Problem talking to the database: Connection refused
```
`sacctmgr` fails the same way. Jobs still submit and run normally, so users may not notice.

## Checks

1. Whether scheduling still works:
   ```
   sbatch --wrap="sleep 30"
   squeue
   ```
   In my test, three jobs ran during the outage.
2. The controller's queue of unsent accounting records:
   ```
   sdiag | grep -i dbd
   ```
   `DBD Agent queue size` was above zero and kept growing: 6, then 7, then 10 as more jobs started and ended.
3. The controller log:
   ```
   sudo grep -i dbd /var/log/slurm/slurmctld.log | tail -5
   ```
   ```
   error: DBD_SEND_MULT_JOB_START failure: Connection refused
   ```
   The same line repeated every five seconds while the controller retried.
4. The daemon itself, on ctl01:
   ```
   systemctl is-active slurmdbd
   ```
   "Connection refused" on port 6819 means nothing is listening there. If slurmdbd is running but accounting still fails, check `/var/log/slurm/slurmdbd.log` and whether MariaDB is running.

## Cause

slurmdbd was stopped. slurmctld sends a record when each job starts and ends. When slurmdbd cannot be reached, slurmctld keeps scheduling and holds the records in a queue in memory.

## Fix

Start slurmdbd:
```
sudo systemctl start slurmdbd
```
If it does not start, `/var/log/slurm/slurmdbd.log` and `journalctl -u slurmdbd` show why.

## Verify

- Within about 20 seconds, `sdiag | grep -i dbd` showed `DBD Agent queue size: 0`.
- The controller log showed it reconnecting:
  ```
  accounting_storage/slurmdbd: clusteracct_storage_p_register_ctld: Registering slurmctld at port 6817 with slurmdbd
  ```
- The jobs that ran during the outage appear with their real start and end times:
  ```
  sacct -X --name=dbdown --format=JobID,JobName,State,Start,End,Elapsed
  ```
  All three showed `COMPLETED`, so no records were lost.

## Timeline from the lab

| Time | Event |
|---|---|
| 17:01:04 | First job starts during the outage |
| 17:03 to 17:07 | Controller logs `Connection refused` every five seconds |
| 17:07:30 | slurmctld registers with slurmdbd again |

## Notes

- The queue is held in slurmctld's memory, and its size is limited by `MaxDBDMsgs` in `slurm.conf`. On a busy cluster, a long outage can fill it, and records beyond the limit are lost. An accounting outage is urgent even though jobs still run.
- I have not tested what happens if slurmctld itself restarts during an outage.

## Prevention

- The slurmdbd role enables slurmdbd at boot, and a playbook run starts it again if it has stopped.
- Monitoring should alert when slurmdbd is down, when nothing is listening on port 6819, or when `DBD Agent queue size` stays above zero for more than a few minutes.
- On a production cluster: regular MariaDB backups, and a second slurmdbd (`DbdBackupHost` in `slurmdbd.conf`) so accounting survives the loss of one host.
