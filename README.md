# Slurm Cluster Lab Guide

This document describes a reusable Slurm cluster setup with a controller, login node, multiple GPU workers, LDAP users, NFS shared homes, Slurm Web, QoS limits, roles, and job management. It includes the supported case where two workers each provide one GPU to a single distributed job.

It intentionally contains no real IP addresses, usernames, passwords, or private keys. Replace every placeholder enclosed by angle brackets before use.

## Architecture

| Component | Role |
|---|---|
| Controller | Runs Slurm controller, accounting database, LDAP, NFS, and optionally Slurm Web |
| Login node | Accepts normal-user SSH login and submits Slurm jobs |
| Worker nodes | Run allocated jobs and expose CPU, RAM, and optional GPU resources |
| LDAP | Central user/group identity store |
| NFS | Shared user homes mounted at `/shared/home` |

```text
User -> Login node -> Slurm controller -> Worker node
          |               |              |
          +--------- NFS shared home ----+

LDAP: controller -> login node and worker via SSSD
MUNGE: same authentication key on controller, login, and workers
```

The login and worker nodes may be on different routed subnets. NFS exports must explicitly allow every client IP or permitted client subnet.

## Scripts

| Script | Run on | Purpose |
|---|---|---|
| [`setup-slurm-web-controller-dynamic.sh`](./setup-slurm-web-controller-dynamic.sh) | Controller | Fresh controller installation: Slurm, database, LDAP, and Web UI |
| [`setup_shared_home_controller_dynamic.sh`](./setup_shared_home_controller_dynamic.sh) | Controller | Creates the NFS server and exports `/shared/home` |
| [`setup-login-node-dynamic.sh`](./setup-login-node-dynamic.sh) | Login node | Installs Slurm client, MUNGE, and initial LDAP login setup |
| [`setup_ldap_identity_client_dynamic.sh`](./setup_ldap_identity_client_dynamic.sh) | Login and worker | Configures LDAP/SSSD identity resolution |
| [`setup_shared_home_login_dynamic.sh`](./setup_shared_home_login_dynamic.sh) | Login node | Mounts the NFS shared home persistently |
| [`setup-worker-node-gpu-dynamic.sh`](./setup-worker-node-gpu-dynamic.sh) | Worker | Configures Slurmd and NVIDIA GPU auto-detection |
| [`add_slurm_worker_dynamic.sh`](./add_slurm_worker_dynamic.sh) | Controller | Safely registers or updates one worker and adds it to the partition |
| [`setup_shared_home_worker_dynamic.sh`](./setup_shared_home_worker_dynamic.sh) | Worker | Mounts the NFS shared home persistently |
| [`create_ldap_slurm_user_dynamic.sh`](./create_ldap_slurm_user_dynamic.sh) | Controller | Creates LDAP user, Slurm account, QoS association, and private home |
| [`manage_ldap_slurm_users_groups_dynamic.sh`](./manage_ldap_slurm_users_groups_dynamic.sh) | Controller | Edits/deletes users and manages LDAP groups |
| [`submit_slurm_job_dynamic.sh`](./submit_slurm_job_dynamic.sh) | Login node, as user | Generates and submits a Slurm batch job |
| [`slurm_superadmin_menu.sh`](./slurm_superadmin_menu.sh) | Controller | Interactive job-cancel, reservation, and QoS menu |
| [`setup-worker-node-with-gpu-dynamic.sh`](./setup-worker-node-with-gpu-dynamic.sh) | Legacy | Older duplicate; do not use for a new setup |

## Before running scripts copied from Windows

Shell scripts must use Linux LF line endings. On the Linux VM, run:

```bash
sed -i 's/\r$//' <script>.sh
chmod +x <script>.sh
```

This prevents the `bash\r: No such file or directory` error.

## Installation order

### Exact execution sequence

Run the scripts in this order. Commands shown on the same node must be run in the listed sequence.

| Step | Node | Script | Command/action |
|---:|---|---|---|
| 1 | Controller | [`setup-slurm-web-controller-dynamic.sh`](./setup-slurm-web-controller-dynamic.sh) | `sudo bash setup-slurm-web-controller-dynamic.sh` |
| 2 | Controller | [`setup_shared_home_controller_dynamic.sh`](./setup_shared_home_controller_dynamic.sh) | `sudo bash setup_shared_home_controller_dynamic.sh` |
| 3 | Login node | [`setup-login-node-dynamic.sh`](./setup-login-node-dynamic.sh) | `sudo bash setup-login-node-dynamic.sh` |
| 4 | Login node | [`setup_ldap_identity_client_dynamic.sh`](./setup_ldap_identity_client_dynamic.sh) | `sudo bash setup_ldap_identity_client_dynamic.sh` |
| 5 | Login node | [`setup_shared_home_login_dynamic.sh`](./setup_shared_home_login_dynamic.sh) | `sudo bash setup_shared_home_login_dynamic.sh` |
| 6 | Worker 1 | - | Copy the controller MUNGE key to `/root/controller-munge.key` |
| 7 | Worker 1 | [`setup-worker-node-gpu-dynamic.sh`](./setup-worker-node-gpu-dynamic.sh) | `sudo bash setup-worker-node-gpu-dynamic.sh` |
| 8 | Worker 1 | [`setup_ldap_identity_client_dynamic.sh`](./setup_ldap_identity_client_dynamic.sh) | `sudo bash setup_ldap_identity_client_dynamic.sh` |
| 9 | Worker 1 | [`setup_shared_home_worker_dynamic.sh`](./setup_shared_home_worker_dynamic.sh) | `sudo bash setup_shared_home_worker_dynamic.sh` |
| 10 | Controller | [`add_slurm_worker_dynamic.sh`](./add_slurm_worker_dynamic.sh) | Run with `sudo bash` and enter Worker 1 details |
| 11 | Worker 2 | Steps 6-9 above | Repeat with the Worker 2 hostname and IP |
| 12 | Controller | [`add_slurm_worker_dynamic.sh`](./add_slurm_worker_dynamic.sh) | Run again and enter Worker 2 details |
| 13 | Controller | [`create_ldap_slurm_user_dynamic.sh`](./create_ldap_slurm_user_dynamic.sh) | Run once for every required user |
| 14 | Login node, as the LDAP user | [`submit_slurm_job_dynamic.sh`](./submit_slurm_job_dynamic.sh) | `bash submit_slurm_job_dynamic.sh` |

Run `setup-slurm-web-controller-dynamic.sh` only for a new or intentionally rebuilt controller. Do not rerun it on an operating cluster just to add a worker. The similarly named `setup-worker-node-with-gpu-dynamic.sh` is an older duplicate; use `setup-worker-node-gpu-dynamic.sh` in the sequence above.

After steps 10 and 12, verify from the controller:

```bash
sinfo -N -o '%N %T %c %m %G'
scontrol show nodes
```

After steps 8 and 9, verify from each worker:

```bash
getent passwd <ldap-user>
findmnt /shared/home
systemctl is-active munge slurmd sssd
nvidia-smi -L
slurmd -G
```

User/group editing is not part of initial installation. Run `sudo bash manage_ldap_slurm_users_groups_dynamic.sh` on the controller whenever an administrator needs to change or delete a user, role, or group. Run `sudo bash slurm_superadmin_menu.sh` on the controller for job cancellation, reservations, and QoS administration.

### 1. Build the controller

Run the full controller script only on a new or intentionally rebuilt controller:

```bash
sudo bash setup-slurm-web-controller-dynamic.sh
```

During setup, define a cluster name, LDAP domain, LDAP organization, partition name, database credentials, and administrator credentials.

After completion, check essential services:

```bash
sudo systemctl is-active munge mariadb slapd slurmdbd slurmctld slurmrestd slurm-web-agent slurm-web-gateway
sinfo
```

### 2. Configure NFS shared home on controller

```bash
sudo bash setup_shared_home_controller_dynamic.sh
```

Use `/shared/home` as the shared path. Permit either exact client IPs or routed CIDR networks.

```bash
sudo exportfs -v
systemctl is-active nfs-server
```

The parent directories must be traversable by users:

```bash
sudo chmod 755 /shared /shared/home
```

Personal home directories remain private with `700` permissions.

### 3. Configure login node

Run:

```bash
sudo bash setup-login-node-dynamic.sh
sudo bash setup_ldap_identity_client_dynamic.sh
sudo bash setup_shared_home_login_dynamic.sh
```

Use the controller hostname/IP for Slurm, LDAP, and NFS prompts. The login node needs the same MUNGE key as controller and worker.

Verify:

```bash
getent passwd <ldap-user>
findmnt /shared/home
sinfo
systemctl is-active munge sssd
```

### 4. Configure each worker node

Every worker must use the exact MUNGE key from the controller. Copy it securely to the worker as a temporary root-only file before starting Slurmd:

```bash
sudo chown root:root /root/controller-munge.key
sudo chmod 400 /root/controller-munge.key
```

Then run:

```bash
sudo bash setup-worker-node-gpu-dynamic.sh
sudo bash setup_ldap_identity_client_dynamic.sh
sudo bash setup_shared_home_worker_dynamic.sh
```

The worker script reports its detected CPU, memory, and GPU GRES values. On the controller, register that worker with:

```bash
sudo bash add_slurm_worker_dynamic.sh
```

Enter the worker hostname, IP, CPU count, `RealMemory`, and the detected GRES value, for example `gpu:nvidia_geforce_rtx_3060:1`. The registration script backs up `slurm.conf`, avoids duplicate node entries, updates the partition, and reconfigures Slurm.

Repeat the worker setup and controller registration once for every worker. Do not rerun `setup-slurm-web-controller-dynamic.sh` to add a worker; that script is intended for a fresh controller installation.

Verify all registered workers:

```bash
sinfo -N -o '%N %T %c %m %G'
scontrol show node <worker-1>
scontrol show node <worker-2>
```

For NVIDIA GPUs, the worker needs the NVML Slurm plugin and this GRES configuration:

```ini
# /etc/slurm/gres.conf
AutoDetect=nvml
```

Verify GPU discovery:

```bash
nvidia-smi -L
slurmd -G
```

## LDAP and shared-home requirements

Every node that runs a job or accepts LDAP users must resolve identities through SSSD. If a user works on login node but fails on worker, configure or restart SSSD on worker:

```bash
sudo systemctl restart sssd
getent passwd <ldap-user>
```

All job users need the same UID/GID mapping on controller, login node, and worker. LDAP provides this consistency.

Shared-home verification as a normal user:

```bash
pwd
touch ~/shared-home-test.txt
ls -l ~/shared-home-test.txt
rm ~/shared-home-test.txt
findmnt /shared/home
```

Expected home path:

```text
/shared/home/<username>
```

## Roles

Use LDAP groups with names that do not conflict with operating-system groups:

| Role | LDAP group | Intended access |
|---|---|---|
| User | `slurm-users` | SSH to login node and normal job submission |
| Admin | `slurm-admins` | Delegated operational access |
| Super Admin | `slurm-superadmins` | Slurm administration and Slurm Web administrator role |

The Super Admin also needs Slurm `AdminLevel=Admin`. An LDAP group alone does not grant Slurm controller privileges.

Do not let normal LDAP users SSH directly to worker nodes. They should edit code and submit jobs from the login node; Slurm alone should allocate worker CPU, RAM, and GPU resources.

## Create users

On controller:

```bash
sudo bash create_ldap_slurm_user_dynamic.sh
```

The script creates:

1. LDAP user identity;
2. private `/shared/home/<username>` directory;
3. Slurm account and user association;
4. selected partition association and QoS;
5. `slurm-users` role membership.

Verify:

```bash
getent passwd <username>
id <username>
sudo sacctmgr show user <username> format=User,DefaultAccount,AdminLevel,DefaultQOS
```

## Edit, delete, and group management

On controller:

```bash
sudo bash manage_ldap_slurm_users_groups_dynamic.sh
```

The menu supports:

```text
1. Edit user full name, password, QoS, or role
2. Delete user safely
3. Create custom LDAP group
4. Delete custom LDAP group
5. Add or remove group membership
6. List users and groups
```

User deletion requires exact confirmation and performs all of the following:

- removes LDAP user and personal LDAP group;
- removes role-group membership;
- removes Slurm user association and dedicated Slurm account;
- moves the home directory to `/shared/home-archive/` instead of erasing it;
- verifies no LDAP or Slurm record remains.

Before recreating a deleted username, clear old identity caches on controller, login, and worker:

```bash
sudo systemctl restart sssd
```

## QoS resource control

Normal users should never receive unlimited resources. Configure a normal QoS with a defined CPU, RAM, runtime, and concurrency limit. Example:

```bash
sudo sacctmgr -i modify qos normal set \
  MaxTRESPerUser=cpu=2,mem=1G \
  MaxWall=02:00:00 \
  MaxJobsPerUser=1
```

Create a separate unrestricted QoS for Super Admins and set it as their default QoS. Check policy:

```bash
sudo sacctmgr show qos format=Name,Priority,MaxWall,MaxTRESPerUser,MaxJobsPU
```

GPU count is naturally limited by the physical GPU resources registered on each worker. Do not create fake GPU slices.

## User job submission

Normal users SSH only to login node:

```bash
ssh <username>@<login-node>
```

Then submit a job:

```bash
chmod +x submit_slurm_job_dynamic.sh
./submit_slurm_job_dynamic.sh
```

Or submit a known batch file directly:

```bash
sbatch ~/my-job.sbatch
```

Example batch file:

```bash
#!/usr/bin/env bash
#SBATCH --job-name=gpu-test
#SBATCH --partition=<partition>
#SBATCH --account=<username>
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=1G
#SBATCH --gpus=1
#SBATCH --time=02:00:00
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err

nvidia-smi
python train.py
```

### One job using two GPUs on two workers

When each worker has only one GPU, `--gres=gpu:2` is incorrect because it asks for two GPUs on every allocated node. Request two nodes and two GPUs for the whole job instead:

```bash
#!/usr/bin/env bash
#SBATCH --job-name=two-node-gpu-job
#SBATCH --partition=cluster
#SBATCH --account=<username>
#SBATCH --nodes=2
#SBATCH --ntasks=2
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --gpus=nvidia_geforce_rtx_3060:2
#SBATCH --time=01:00:00
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err

srun nvidia-smi -L
```

The interactive `submit_slurm_job_dynamic.sh` script now asks for node count, task count, total GPU count, and optional GPU type. For the topology above, enter `2` nodes, `2` tasks, and `2` total GPUs.

`srun nvidia-smi -L` verifies that a job step runs on both allocated workers. Real multi-node AI training also needs a distributed application launcher such as PyTorch `torchrun`; a single ordinary Python process cannot directly use a GPU located on another worker.

`python train.py` is the real workload command. `sleep` is useful only for testing a running job or demonstrating Web UI visibility.

Monitor jobs:

```bash
squeue -u "$USER"
scontrol show job <job-id>
sacct -j <job-id> --format=JobID,JobName,State,Elapsed,AllocCPUS,ReqMem,AllocTRES
```

Cancel own job:

```bash
scancel <job-id>
```

## Reservations and administrator actions

Slurm Web may be view-only in this setup. Controller Super Admin actions are performed from the controller terminal.

Run the interactive admin menu:

```bash
sudo bash slurm_superadmin_menu.sh
```

It supports active-job listing, single job cancellation, cancel-all for a user, reservation create/delete, and QoS inspection. Destructive actions require typed confirmation.

Manual reservation example:

```bash
sudo scontrol create reservation \
  ReservationName=<name> \
  StartTime=<YYYY-MM-DDTHH:MM:SS> \
  EndTime=<YYYY-MM-DDTHH:MM:SS> \
  Users=<username> \
  Nodes=<worker-name> \
  TRES=cpu=2,mem=1G,gres/gpu=1 \
  Flags=PART_NODES
```

Check or delete:

```bash
scontrol show reservation <name>
sudo scontrol delete ReservationName=<name>
```

## GPU notes

An RTX-class GPU that lacks NVIDIA MIG support is normally one Slurm allocatable GPU:

```bash
#SBATCH --gres=gpu:1
```

For a single node this GRES form is valid. For a total GPU request spanning multiple one-GPU workers, use `--nodes=<count>` together with `--gpus=<type>:<total>` as shown above.

It cannot be split into strict VRAM-sized resources, such as 2 GB per user. NVIDIA MPS can share compute but does not enforce a VRAM limit. Allocate whole GPUs for reliable scheduling.

The worker VM must have enough configured `RealMemory` to satisfy every requested job. A 4 GB job cannot start on a worker with less than 4 GB Slurm-allocatable memory. Increase VM RAM, update worker `RealMemory` in controller configuration, reconfigure, then retry.

## Daily health checks

Controller:

```bash
sinfo -N -l
squeue
sudo exportfs -v
sudo systemctl is-active munge slapd nfs-server slurmdbd slurmctld slurmrestd slurm-web-agent slurm-web-gateway
```

Login node:

```bash
getent passwd <username>
findmnt /shared/home
sinfo
systemctl is-active munge sssd
```

Worker:

```bash
getent passwd <username>
findmnt /shared/home
systemctl is-active munge slurmd sssd
nvidia-smi -L
slurmd -G
```

## Troubleshooting

| Symptom | Resolution |
|---|---|
| `bash\r` error | Convert the script using `sed -i 's/\r$//' <script>.sh` |
| User cannot enter `/shared/home/<user>` | Check NFS mount and run `sudo chmod 755 /shared /shared/home` on controller and clients |
| User resolves on login but not worker | Configure/restart SSSD on worker and verify `getent passwd <user>` |
| NFS mount fails | Check `sudo exportfs -v`, NFS allow-list, routing, and firewall rules |
| Worker absent in `sinfo` | Check MUNGE key, controller reachability, port 6817, Slurmd status, node definition |
| GPU absent | Install NVML plugin, set `AutoDetect=nvml`, restart Slurmd |
| Invalid account/partition | Add matching Slurm account, user, partition association, and QoS |
| Requested node configuration unavailable | Check CPU/RAM/GPU and QoS limits. With one GPU per worker, do not request `--gres=gpu:2`; use two nodes and `--gpus=<type>:2` |
| Job missing from active Web UI | Short jobs complete quickly; use job history/accounting view or a longer test workload |

## Security

- Keep controller SSH, database, LDAP-admin, and normal-user passwords separate.
- Do not share MUNGE keys or LDAP administrator credentials with normal users.
- Use TLS/LDAPS and a restricted read-only service account in production.
- Back up `/etc/slurm`, `/etc/munge/munge.key`, `/etc/sssd`, `/etc/exports`, LDAP data, and Slurm accounting data before major changes.
