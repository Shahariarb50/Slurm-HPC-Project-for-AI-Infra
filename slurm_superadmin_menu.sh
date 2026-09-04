#!/usr/bin/env bash
# Interactive Slurm administrator menu. Run on controller as Super Admin.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

ask() {
  local label="$1" default="$2" value
  read -r -p "$label [$default]: " value
  if [[ -z "$value" ]]; then printf '%s' "$default"; else printf '%s' "$value"; fi
}
pause(){ read -r -p 'Press Enter to continue...'; }
confirm(){ local value; read -r -p "Type $1 to confirm: " value; [[ "$value" == "$1" ]]; }

show_jobs(){ echo; squeue -o '%.18i %.10u %.9T %.18j %.3C %.10m %.24R'; }

cancel_job(){
  local job
  show_jobs
  job="$(ask 'Job ID to cancel' '')"
  [[ "$job" =~ ^[0-9]+([_.][0-9]+)?$ ]] || { echo '[ERROR] Invalid job ID.'; return; }
  confirm "CANCEL-$job" || { echo 'Cancelled by operator.'; return; }
  scancel "$job"; echo "[OK] Cancel request sent for job $job."
}

cancel_user_jobs(){
  local user
  user="$(ask 'Username whose jobs will be cancelled' '')"
  [[ "$user" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] || { echo '[ERROR] Invalid username.'; return; }
  squeue -u "$user" -o '%.18i %.10u %.9T %.18j %.24R'
  confirm "CANCEL-ALL-$user" || { echo 'Cancelled by operator.'; return; }
  scancel -u "$user"; echo "[OK] Cancel request sent for all jobs of $user."
}

create_reservation(){
  local name user node start end cpus memory gpu tres
  name="$(ask 'Reservation name' '')"; user="$(ask 'Username' '')"; node="$(ask 'Node name' 'worker1')"
  start="$(ask 'Start time (YYYY-MM-DDTHH:MM:SS)' '')"; end="$(ask 'End time (YYYY-MM-DDTHH:MM:SS)' '')"
  cpus="$(ask 'CPU cores' '2')"; memory="$(ask 'RAM (for example 1G)' '1G')"; gpu="$(ask 'GPUs (0 or 1)' '1')"
  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_.-]{1,60}$ && "$user" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] || { echo '[ERROR] Invalid name or username.'; return; }
  [[ "$cpus" =~ ^[1-9][0-9]*$ && "$gpu" =~ ^[0-9]+$ ]] || { echo '[ERROR] Invalid CPU or GPU number.'; return; }
  [[ "$start" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ && "$end" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || { echo '[ERROR] Use full controller-local timestamps.'; return; }
  tres="cpu=$cpus,mem=$memory"
  (( gpu > 0 )) && tres="$tres,gres/gpu=$gpu"
  echo "Reservation: $name | $user | $node | $start to $end | $tres"
  confirm "CREATE-$name" || { echo 'Cancelled by operator.'; return; }
  scontrol create reservation ReservationName="$name" StartTime="$start" EndTime="$end" Users="$user" Nodes="$node" TRES="$tres" Flags=PART_NODES
  scontrol show reservation "$name"
}

delete_reservation(){
  local name
  scontrol show reservation
  name="$(ask 'Reservation name to delete' '')"
  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_.-]{1,60}$ ]] || { echo '[ERROR] Invalid reservation name.'; return; }
  confirm "DELETE-$name" || { echo 'Cancelled by operator.'; return; }
  scontrol delete ReservationName="$name"; echo "[OK] Reservation $name deleted."
}

show_limits(){
  echo '=== QoS limits ==='
  sacctmgr -n show qos format=Name,Priority,MaxWall,MaxTRESPerUser,MaxJobsPU
  echo; echo '=== User associations ==='
  sacctmgr -n show user withassoc format=User,Account,Partition,DefaultQOS,QOS,AdminLevel
}

while true; do
  clear
  echo '========== Slurm Super Admin Menu =========='
  echo '1) Show active jobs'
  echo '2) Cancel one job'
  echo '3) Cancel all jobs of a user'
  echo '4) Create reservation'
  echo '5) Delete reservation'
  echo '6) Show reservations'
  echo '7) Show QoS limits and user associations'
  echo '0) Exit'
  choice="$(ask 'Choose option' '1')"
  case "$choice" in
    1) show_jobs; pause ;;
    2) cancel_job; pause ;;
    3) cancel_user_jobs; pause ;;
    4) create_reservation; pause ;;
    5) delete_reservation; pause ;;
    6) scontrol show reservation; pause ;;
    7) show_limits; pause ;;
    0) exit 0 ;;
    *) echo '[ERROR] Invalid option.'; pause ;;
  esac
done