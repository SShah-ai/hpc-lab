# Node drained: Low RealMemory

## Symptom

`sinfo` shows the nodes as `inval`, and later as `drain`. `sinfo -R` gives the reason as `Low RealMemory`. Jobs do not fail, they wait:
```
srun: Required node not available (down, drained or reserved)
srun: job 18 queued and waiting for resources
```

## Checks

1. The node's state and reason, on ctl01:
   ```
   scontrol show node node01 | grep -E "State|Reason|RealMemory"
   ```
   I saw:
   ```
   RealMemory=1159 AllocMem=0 FreeMem=602
   State=UNKNOWN+DRAIN+INVALID_REG
   Reason=Low RealMemory (reported:966 < 100.00% of configured:1159)
   ```
   The node reports 966 MB, and `slurm.conf` says it has 1159 MB.
2. The controller log:
   ```
   sudo grep -iE "memory|node01" /var/log/slurm/slurmctld.log | tail -5
   ```
   ```
   error: Setting node node01 state to INVAL with reason:Low RealMemory (reported:966 < 100.00% of configured:1159)
   drain_nodes: node node01 state set to DRAIN
   error: _slurm_rpc_node_registration node=node01: Invalid argument
   ```
   The controller rejected the registration and drained the node itself, so `sinfo -R` shows the user as `slurm`.
3. What the node really has. `free -m` on the node shows total memory. `slurmd -C` prints the node's hardware as slurmd sees it, in `slurm.conf` format, which is the quickest way to compare with the config.
4. What changed in the config. Here, the `--diff` output of the Ansible run showed `RealMemory` going from `869` to `1159`.

## Cause

`slurm.conf` promised more memory than the nodes have. I caused it on purpose by overriding the memory fraction for one run:
```
ansible-playbook site.yml --diff -e '{"slurm_mem_fraction": 1.2}'
```
In real clusters the usual causes are a node definition copied from a bigger server, a failed memory module, or a kernel or firmware change that leaves less memory available.

## Fix

1. Correct `RealMemory`. Here, a normal playbook run without the override put back `869` and restarted the daemons:
   ```
   ansible-playbook site.yml --diff
   ```
2. The corrected registration cleared the `inval` state, but the nodes stayed `drain`. A drain stays until an admin resumes the node:
   ```
   sudo scontrol update nodename=node[01-02] state=resume
   ```

## Verify

- `sinfo` shows the nodes as `idle`.
- `scontrol show node node01` shows `RealMemory=869` and no `Reason`.
- `srun hostname` runs straight away.

## Notes

- `-e slurm_mem_fraction=1.2` would pass the text "1.2", not a number. The JSON form `-e '{"slurm_mem_fraction": 1.2}'` keeps it a number.
- The role sets `RealMemory` to 90% of the memory Ansible measures, to leave room for the operating system. A node that reports less than its configured `RealMemory` is drained.
- The controller log also showed `No memory enforcing mechanism configured.` Requested memory is used for scheduling only. Nothing stops a job using more than it asked for until memory limits are enforced, for example with cgroups.

## Prevention

- Generate `RealMemory` from what the node actually has, as the role does from Ansible facts, rather than typing it by hand.
- Before adding a new type of node, run `slurmd -C` on it and use its numbers.
- After any hardware work on a node, check `sinfo -R` before returning it to users.
