#!/usr/bin/env bash
# Dynamic NFS shared-home client setup. Run on the Slurm login node.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

ask() { local label="$1" default="$2" value; read -r -p "$label [$default]: " value; printf '%s' "${value:-$default}"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

server="$(ask 'NFS controller IP/hostname' '192.168.43.44')"
share="$(ask 'Shared path' '/shared/home')"
[[ "$share" == /* ]] || die 'Shared path must start with /.'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nfs-common
install -d -m 0755 "$(dirname "$share")
chmod 0755 "$(dirname "$share")
install -d -m 0755 "$share"
if mountpoint -q "$share"; then
  current="$(findmnt -n -o SOURCE --target "$share")"
  [[ "$current" == "$server:$share" ]] || die "$share is already mounted from $current; unmount it first."
else
  mount -t nfs4 -o rw,hard,timeo=600,retrans=2 "$server:$share" "$share"
fi

tmp="$(mktemp)"
awk -v target="$share" '!($2 == target && $3 ~ /^nfs/) {print}' /etc/fstab >"$tmp"
printf '%s %s nfs4 rw,hard,timeo=600,retrans=2,_netdev 0 0\n' "$server:$share" "$share" >>"$tmp"
install -m 0644 "$tmp" /etc/fstab
rm -f "$tmp"
findmnt "$share"
echo '[OK] Shared home mounted and persisted in /etc/fstab.'