#!/usr/bin/env bash
# Run on the controller. Persists one worker in slurm.conf and reconfigures Slurm.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
ask(){ local v; read -r -p "$1${2:+ [$2]}: " v; printf '%s' "${v:-$2}"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
conf=/etc/slurm/slurm.conf; [[ -r "$conf" ]] || die 'Run on controller.'
part="$(sed -n 's/^PartitionName=\([^ ]*\).*/\1/p' "$conf" | head -1)"; part="${part:-cluster}"
node="$(ask 'Worker hostname')"; ip="$(ask 'Worker IPv4')"
cpu="$(ask 'CPUs from worker slurmd -C')"; ram="$(ask 'RealMemory MiB from worker slurmd -C')"
gres="$(ask 'GPU GRES, e.g. gpu:nvidia_geforce_rtx_3060:1 (blank CPU-only)' '')"
[[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Invalid hostname or IP.'
[[ "$cpu" =~ ^[1-9][0-9]*$ && "$ram" =~ ^[1-9][0-9]*$ ]] || die 'CPU/RAM must be positive numbers.'
[[ -z "$gres" || "$gres" =~ ^gpu:[A-Za-z0-9_.-]+:[1-9][0-9]*$ ]] || die 'Invalid GRES format.'
cp -a "$conf" "$conf.bak.$(date +%Y%m%d%H%M%S)"
sed -i "/^NodeName=$node[[:space:]]/d" "$conf"
if [[ -n "$gres" ]] && ! grep -q '^GresTypes=.*gpu' "$conf"; then echo GresTypes=gpu >>"$conf"; fi
line="$(grep -m1 "^PartitionName=$part " "$conf" || true)"; [[ -n "$line" ]] || die "Partition $part missing."
nodes="$(sed -n 's/.*Nodes=\([^ ]*\).*/\1/p' <<<"$line")"
case ",$nodes," in *",$node,"*) ;; *) nodes="$nodes,$node";; esac
sed -i "s|^PartitionName=$part Nodes=[^ ]*|PartitionName=$part Nodes=$nodes|" "$conf"
printf 'NodeName=%s NodeAddr=%s CPUs=%s RealMemory=%s%s State=UNKNOWN\n' "$node" "$ip" "$cpu" "$ram" "${gres:+ Gres=$gres}" >>"$conf"
scontrol reconfigure
sleep 2
scontrol show node "$node" | grep -E 'NodeName=|State=|Gres=|Reason=' || true
echo '[OK] Controller updated. Worker must use this controller MUNGE key before slurmd starts.'
