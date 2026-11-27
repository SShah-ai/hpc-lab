# Home directories down: NFS server stopped

## Symptom

Jobs and logins that use a home directory freeze. Nothing fails and Slurm logs nothing: job 8 showed `R` in `squeue` for 11 minutes while it did no work. On the compute node, any command that touches `/nfs/home` hangs, including plain `df`. Local accounts such as sayed log in and work normally.

## Checks

1. Whether the mount answers, without hanging the shell:
   ```
   timeout -s KILL 10 ls /nfs/home/aaba; echo "exit code $?"
   ```
   Exit code 137 (128 + 9) means `ls` was stuck and SIGKILL ended it. Plain `timeout` sends SIGTERM, which a process stuck on a hard NFS mount ignores, so the shell would hang.
2. Disk usage without touching NFS:
   ```
   df -h -x nfs4 -x autofs
   ```
   Plain `df -h` hung, because it checks every mounted file system.
3. Stuck processes:
   ```
   sudo ps -o pid,stat,wchan:32,cmd -u aaba
   ```
   One job process was in state `D`, waiting in the kernel. It was the shell's child for `date >> writer.log`, stuck opening the file. Without `sudo`, `WCHAN` shows `-` for another user's processes.
4. The kernel log:
   ```
   sudo journalctl -k --since "30 min ago" --no-pager | grep -i nfs
   ```
   ```
   23:18:29 node01 kernel: nfs: server ctl01.hpc.lab not responding, still trying
   23:19:15 node01 kernel: nfs: server ctl01.hpc.lab not responding, timed out
   ```
   The first message came about 3 minutes after the server stopped.
5. The server, on ctl01:
   ```
   systemctl is-active nfs-server
   ```

## Cause

nfs-server on ctl01 was stopped. The homes are mounted `hard`, so the client kept retrying each request instead of returning an error, and every process that touched the mount waited in the kernel until the server came back.

## Fix

Start the server on ctl01:
```
sudo systemctl start nfs-server
```
Nothing is needed on the clients. They keep retrying until the server answers.

## Verify

- node01's kernel logged `nfs: server ctl01.hpc.lab OK` at 23:26:32.
- `writer.log` on ctl01:
  ```
  23:15:23
  23:26:32
  23:26:37
  ```
  The write that was stuck since 23:15 finished at 23:26:32, the same second the client logged `OK`, and the job went on writing every 5 seconds.
- `slurm-8.out` contained only the cancellation notice, so the stuck write did not fail.
- After the job was cancelled, `ps -u aaba` on node01 showed nothing.

## Timeline from the lab

| Time | Event |
|---|---|
| 23:14:08 | Job 8 starts on node01, writing the time to `writer.log` every 5 seconds |
| 23:15:19 | nfs-server stopped; last write 23:15:23 |
| 23:18:29 | node01: `not responding, still trying` |
| 23:19:15 to 23:25:26 | node01: five `not responding, timed out` lines |
| 23:24:03 | `squeue` still shows job 8 as `R` (9:36) |
| 23:26:32 | node01: `server ctl01.hpc.lab OK`; the stuck write completes |
| 23:29:20 | Job cancelled with `scancel` (`CANCELLED by 0`, root) |

## Notes

- Slurm cannot see this. The job stayed `R` the whole time, and a job frozen on storage uses up its time limit while doing nothing.
- `hard` means wait, not fail, and nothing was lost. A `soft` mount returns errors after its retries, and a program that ignores write errors can leave half-written files. That is why homes are mounted `hard`.
- Only SIGKILL interrupts a process waiting on a hard NFS mount (`man 5 nfs`). Ctrl+C and plain `kill` do not.
- The first `still trying` message took about 3 minutes. With `timeo=600` the client waits 60 seconds, the wait grows with each retry, and the message comes after `retrans=2` retries.
- The kernel prints `timed out` for requests that are allowed to give up. I did not find out which requests these were. The job's own write was not one of them.
- The server's grace period (`NFSV4GRACETIME="90"`) did not delay recovery here: the stuck write completed the same second the client logged `OK`. I did not look into why.
- Local accounts were not affected. My session as sayed on node01 worked throughout.
- I did not test a home that was not already mounted when the server stopped. AutoFS would try a new mount instead of retrying an existing one.

## Prevention

- The home server is a single point of failure for every job that uses a home directory. Production clusters use a highly available NFS service, or a parallel file system for job data.
- Monitoring should alert when nfs-server is down on ctl01 and when clients log `not responding`.
- Jobs should write large or busy data to scratch storage, not to home directories.
- Health checks and scripts that may run during an outage should use `df -x nfs4` and `timeout -s KILL`, so they do not hang themselves.
