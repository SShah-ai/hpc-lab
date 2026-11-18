# Drain and resume a compute node

Use this to take a node out of service for maintenance without killing the jobs already running on it.

## Background

A drained node finishes the jobs it is running but gets no new work. A down node is unusable, and its jobs fail or are requeued. Slurm requires a reason when a node is drained, and records who set it and when.

## Steps

All commands run on ctl01. Changing node state needs sudo. Run each sudo command on its own line: when I pasted several lines at once, the lines after sudo did not run.

1. Drain the node:
   ```
   sudo scontrol update nodename=node01 state=drain reason="maintenance test"
   ```
2. Check its state and the recorded reason:
   ```
   sinfo
   sinfo -R
   ```
   While jobs are still running, the state is `drng`. Once they finish, it is `drain`.
3. Do the maintenance once the node shows `drain`.
4. Return it to service:
   ```
   sudo scontrol update nodename=node01 state=resume
   ```

## What users see

A job that asks for the drained node stays pending with:
```
(ReqNodeNotAvail, UnavailableNodes:node01)
```
Jobs that do not name a node run on the other nodes as normal.

## Verify

- `sinfo` shows the node as `idle`, or `mix`/`alloc` if jobs start on it.
- A job pinned to the node runs: `srun -w node01 hostname`.

## Notes

- Resuming does not affect jobs that were already running. In my test, the job running on node01 kept going through the drain and the resume.
- After the resume, a waiting job stayed pending with `(Resources)` even though node01 had a free CPU. The running job had not asked for memory, so Slurm had given it all of the node's memory. Setting `DefMemPerCPU` in `slurm.conf` would stop one small job taking a whole node.
