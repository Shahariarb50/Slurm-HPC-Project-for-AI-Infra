# Slurm Lab Guide

## Lab nodes

| Node | IP | Role |
|---|---:|---|
| Controller | `192.168.43.44` | Slurm, LDAP, NFS, database, Slurm Web |
| Login | `192.168.43.45` | SSH login and job submission |
| Worker | `192.168.182.253` | Job execution and RTX 3060 GPU |

Different IP subnets work because routing is enabled. NFS exports allow the login and worker client IPs.

## Service connection

```text
User -> Login node -> Controller -> Worker
          |             |           |
          +--------- NFS /shared/home

LDAP: controller -> login and worker through SSSD
MUNGE: identical /etc/munge/munge.key on every Slurm node
```

## Scripts in D:\\SH

| Script | Run on | Use |
|---|---|---|
| `setup-slurm-web-controller-dynamic.sh` | Controller | Full fresh controller installation |
| `setup_shared_home_controller_dynamic.sh` | Controller | NFS server/export |
| `setup-login-node-dynamic.sh` | Login | Slurm client, MUNGE, basic LDAP |
| `setup_ldap_identity_client_dynamic.sh` | Login and worker | LDAP/SSSD identity lookup |
| `setup_shared_home_login_dynamic.sh` | Login | NFS client mount |
| `setup-worker-node-gpu-dynamic.sh` | Worker | Slurmd and GPU setup |
| `setup_shared_home_worker_dynamic.sh` | Worker | NFS client mount |
| `create_ldap_slurm_user_dynamic.sh` | Controller | New user, home, Slurm account/QoS |
| `submit_slurm_job_dynamic.sh` | Login as user | Create and submit job |
| `manage_ldap_slurm_users_groups_dynamic.sh` | Controller | Edit/delete users and manage LDAP groups |

After copying a script from Windows to Linux:

```bash
sed -i 's/\r$//' script.sh
chmod +x script.sh
```

## Fresh setup order

### Controller

Run the full controller script only on a new controller VM:

```bash
sudo bash setup-slurm-web-controller-dynamic.sh
```

Use these values:

```text
Cluster: labcluster
LDAP domain: slurm.local
Base DN: dc=slurm,dc=local
Partition: cluster
```

Then run NFS server setup:

```bash
sudo bash setup_shared_home_controller_dynamic.sh
```

Use:

```text
Shared path: /shared/home
Clients: 192.168.43.45,192.168.182.253
```

Or permit whole routed subnets:

```text
192.168.43.0/24,192.168.182.0/24
```

Verify:

```bash
sudo exportfs -v
systemctl is-active nfs-server
sinfo
```

### Login node

Run in this order:

```bash
sudo bash setup-login-node-dynamic.sh
sudo bash setup_ldap_identity_client_dynamic.sh
sudo bash setup_shared_home_login_dynamic.sh
```

Use controller/LDAP/NFS IP `192.168.43.44`, cluster `labcluster`, LDAP domain `slurm.local`, and shared path `/shared/home`.

Verify:

```bash
getent passwd master
findmnt /shared/home
sinfo
systemctl is-active munge sssd
```

### GPU worker

First copy the MUNGE key. On controller:

```bash
sudo scp /etc/munge/munge.key worker1@192.168.182.253:/tmp/munge.key
```

On worker:

```bash
sudo install -o munge -g munge -m 400 /tmp/munge.key /etc/munge/munge.key
sudo rm /tmp/munge.key
sudo systemctl restart munge
```

Run:

```bash
sudo bash setup-worker-node-gpu-dynamic.sh
sudo bash setup_ldap_identity_client_dynamic.sh
sudo bash setup_shared_home_worker_dynamic.sh
```

Worker values:

```text
Controller: 192.168.43.44
Cluster: labcluster
Worker name: worker1
Worker IP: 192.168.182.253
```

Copy the exact GPU node line printed by the worker script into controller `/etc/slurm/slurm.conf`. Controller config must have:

```ini
GresTypes=gpu
```

Then:

```bash
sudo scontrol reconfigure
sudo scontrol update NodeName=worker1 State=IDLE
sinfo -N -o '%N %T %G'
```

Expected GPU: `gpu:nvidia_geforce_rtx_3060:1`.

## LDAP, NFS, and roles

```text
LDAP domain: slurm.local
LDAP admin DN: cn=admin,dc=slurm,dc=local
Shared home: /shared/home
```

`/shared` and `/shared/home` must be `755`. Each user home is private `700`.

| Role | LDAP group | Current member |
|---|---|---|
| User | `slurm-users` | `it14` |
| Admin | `slurm-admins` | none |
| Super Admin | `slurm-superadmins` | `master` |

`master` also has Slurm `AdminLevel=Admin`.

## Create an LDAP and Slurm user

On controller:

```bash
sudo bash create_ldap_slurm_user_dynamic.sh
```

Example:

```text
Username: it14
Full name: Md. Shahariar Rahaman
LDAP domain: slurm.local
LDAP admin DN: cn=admin,dc=slurm,dc=local
Cluster: labcluster
Partition: cluster
QoS: normal
Shared home root: /shared/home
```

The script creates LDAP identity, private NFS home, Slurm account/QoS association, and `slurm-users` membership.

Verify:

```bash
getent passwd it14
id it14
sudo sacctmgr show user it14 format=User,DefaultAccount,AdminLevel,DefaultQOS
```

## Edit/delete users and manage groups

Run this only on the controller:

```bash
sudo bash manage_ldap_slurm_users_groups_dynamic.sh
```

It provides this menu:

```text
1) Edit user: full name, password, QoS, or role
2) Delete user: archive home, then remove LDAP/Slurm access
3) Create custom LDAP group
4) Delete custom LDAP group
5) Add/remove a user from an LDAP group
6) List users and groups
```

For a user deletion, the confirmation must be exactly `DELETE-USERNAME`. The script preserves data by moving `/shared/home/USERNAME` to `/shared/home-archive/USERNAME-TIMESTAMP`; it does not permanently erase home files.

Do not delete the reserved role groups: `slurm-users`, `slurm-admins`, and `slurm-superadmins`. Use the edit-user role option to move a user between these roles. Assigning `superadmin` also sets Slurm `AdminLevel=Admin`; assigning `admin` sets `AdminLevel=Operator`; assigning `user` removes Slurm administration.

## Login and test shared home

From PC:

```bash
ssh USERNAME@192.168.43.45
```

Then:

```bash
pwd
touch ~/shared-home-test.txt
ls -l ~/shared-home-test.txt
rm ~/shared-home-test.txt
findmnt /shared/home
```

Expected home: `/shared/home/USERNAME`.

Expected NFS source: `192.168.43.44:/shared/home`.

## Submit a job from login node

As the LDAP user:

```bash
chmod +x submit_slurm_job_dynamic.sh
./submit_slurm_job_dynamic.sh
```

For requested resources enter:

```text
Job name: it14-gpu-test
Partition: cluster
Slurm account: it14
CPU cores: 2
RAM: 4G
Number of GPUs: 1
Maximum run time: 01:00:00
Reservation: blank unless created
Start time: blank to run now
Command: nvidia-smi
```

Check job:

```bash
squeue -u "$USER"
squeue -j JOB_ID
scontrol show job JOB_ID
```

Cancel:

```bash
scancel JOB_ID
```

## One-hour reservation

Controller admin checks time first:

```bash
date
timedatectl
```

Then creates reservation using controller time:

```bash
sudo scontrol create reservation \
  ReservationName=it14-evening \
  StartTime=YYYY-MM-DDTHH:MM:SS \
  EndTime=YYYY-MM-DDTHH:MM:SS \
  Users=it14 \
  Nodes=worker1 \
  TRES=cpu=2,mem=4G,gres/gpu=1 \
  Flags=PART_NODES
```

Check it:

```bash
scontrol show reservation it14-evening
```

User enters `it14-evening` at the reservation prompt in the submit script.

## GPU limitation

RTX 3060 is one Slurm GPU:

```bash
#SBATCH --gres=gpu:1
```

It cannot be split into strict 2 GB VRAM slices because RTX 3060 has no MIG support. MPS can share compute but cannot enforce a 2 GB VRAM limit.

## Daily checks

Controller:

```bash
sinfo -N -l
squeue
sudo systemctl is-active munge slapd nfs-server slurmdbd slurmctld slurmrestd slurm-web-agent slurm-web-gateway
sudo exportfs -v
```

Login:

```bash
getent passwd it14
findmnt /shared/home
sinfo
systemctl is-active munge sssd
```

Worker:

```bash
getent passwd it14
findmnt /shared/home
systemctl is-active munge slurmd sssd
nvidia-smi -L
slurmd -G
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `bash\r` error | `sed -i 's/\r$//' script.sh` |
| Cannot enter shared home | `sudo chmod 755 /shared /shared/home` on controller and clients |
| User missing on worker | Run LDAP identity script on worker; restart `sssd` |
| NFS fails | Check `sudo exportfs -v`, permitted IP/subnet, and routing |
| Worker absent in `sinfo` | Check MUNGE key, port 6817, `slurmd`, node definition |
| GPU missing | NVML plugin, `AutoDetect=nvml`, then restart `slurmd` |
| Job pending | `squeue -j JOB_ID -o '%.18i %.9T %.80R'` |

## Security

- Keep controller, LDAP admin, database, and user passwords separate in production.
- Never share the MUNGE key or LDAP admin password with ordinary users.
- Production LDAP should use TLS/LDAPS and a read-only bind account.
