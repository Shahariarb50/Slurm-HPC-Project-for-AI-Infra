#!/usr/bin/env bash
# Interactive Slurm job creator and submitter. Run on the login node as the LDAP user.
set -Eeuo pipefail

ask(){ local label="$1" default="$2" value; read -r -p "$label [$default]: " value; printf '%s' "${value:-$default}"; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }

echo '=== Interactive Slurm job submission ==='
sbatch_command="${SBATCH_COMMAND:-sbatch}"
command -v "$sbatch_command" >/dev/null 2>&1 || die "Submission command not found: $sbatch_command"
job_name="$(ask 'Job name' 'my-job')"
partition="$(ask 'Partition' 'cluster')"
account="$(ask 'Slurm account' "$USER")"
nodes="$(ask 'Number of worker nodes' '1')"
tasks="$(ask 'Number of tasks' "$nodes")"
cpus="$(ask 'CPU cores' '2')"
memory="$(ask 'RAM (for example 4G)' '4G')"
gpus="$(ask 'Total GPUs for the whole job (0 or more)' '1')"
gpu_type="$(ask 'GPU type (any or a configured GPU name)' 'any')"
walltime="$(ask 'Maximum run time (HH:MM:SS)' '01:00:00')"
reservation="$(ask 'Reservation name (blank if none)' '')"
start_time="$(ask 'Start time, e.g. 2026-09-04T18:00:00 (blank = now)' '')"
command_to_run="$(ask 'Command to run' 'srun nvidia-smi -L')"

[[ "$nodes" =~ ^[1-9][0-9]*$ ]] || die 'Node count must be a positive number.'
[[ "$tasks" =~ ^[1-9][0-9]*$ ]] || die 'Task count must be a positive number.'
[[ "$cpus" =~ ^[1-9][0-9]*$ ]] || die 'CPU cores must be a positive number.'
[[ "$gpus" =~ ^[0-9]+$ ]] || die 'GPU count must be 0 or more.'
[[ "$gpu_type" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'GPU type contains invalid characters.'
[[ "$walltime" =~ ^([0-9]{1,2}-)?[0-9]{1,2}:[0-9]{2}:[0-9]{2}$ ]] || die 'Use HH:MM:SS or D-HH:MM:SS.'

job_file="job-${job_name//[^a-zA-Z0-9_.-]/_}-$(date +%Y%m%d-%H%M%S).sbatch"
{
  echo '#!/usr/bin/env bash'
  echo "#SBATCH --job-name=$job_name"
  echo "#SBATCH --partition=$partition"
  echo "#SBATCH --account=$account"
  echo "#SBATCH --nodes=$nodes"
  echo "#SBATCH --ntasks=$tasks"
  echo "#SBATCH --cpus-per-task=$cpus"
  echo "#SBATCH --mem=$memory"
  echo "#SBATCH --time=$walltime"
  echo "#SBATCH --output=%x-%j.out"
  echo "#SBATCH --error=%x-%j.err"
  if (( gpus > 0 )); then
    if [[ "$gpu_type" != 'any' ]]; then
      echo "#SBATCH --gpus=$gpu_type:$gpus"
    else
      echo "#SBATCH --gpus=$gpus"
    fi
  fi
  [[ -n "$reservation" ]] && echo "#SBATCH --reservation=$reservation"
  [[ -n "$start_time" ]] && echo "#SBATCH --begin=$start_time"
  echo
  echo 'set -Eeuo pipefail'
  echo 'hostname'
  echo 'date'
  printf '%s\n' "$command_to_run"
} >"$job_file"
chmod 700 "$job_file"

echo
echo "Created: $job_file"
"$sbatch_command" "$job_file"
echo "Check: squeue -u $USER"
echo 'For a two-worker cluster with one GPU on each worker, request 2 nodes, 2 tasks and 2 total GPUs.'
echo 'Note: Slurm allocates a whole GPU. A 2 GB VRAM limit needs application/container-level control.'
