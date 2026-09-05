#!/usr/bin/env bash
# Dynamic NFS shared-home server setup. Run on the Slurm controller.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

ask() { local label="$1" default="$2" value; read -r -p "$label [$default]: " value; printf '%s' "${value:-$default}"; }
die() { echo "[ERROR] $*" >&2; exit 1; }
normalise() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s/32' "$1"; return; }
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] && { printf '%s' "$1"; return; }
  die "Invalid client IP/CIDR: $1"
}

share="$(ask 'Shared path' '/shared/home')"
[[ "$share" == /* ]] || die 'Shared path must start with /.'
clients_raw="$(ask 'Allowed client IPs/CIDRs (comma-separated; include every login/worker subnet)' '')"
[[ -n "$clients_raw" ]] || die 'Enter every login/worker IP or subnet. Example: 10.0.10.0/24,10.0.20.0/24'
IFS=', ' read -r -a clients <<<"$clients_raw"
specs=()
for c in "${clients[@]}"; do [[ -n "$c" ]] && specs+=("$(normalise "$c")"); done
(( ${#specs[@]} )) || die 'No client IP/CIDR supplied.'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nfs-kernel-server
install -d -m 0755 "$(dirname "$share")

chmod 0755 "$(dirname "$share")

install -d -m 0755 "$share"

chmod 0755 "$share"

tmp="$(mktemp)"
awk '/^# BEGIN SLURM-SHARED-HOME$/ {skip=1;next} /^# END SLURM-SHARED-HOME$/ {skip=0;next} !skip {print}' /etc/exports >"$tmp"
{
  echo '# BEGIN SLURM-SHARED-HOME'
  printf '%s' "$share"
  for spec in "${specs[@]}"; do printf ' %s(rw,sync,no_subtree_check,root_squash)' "$spec"; done
  printf '\n# END SLURM-SHARED-HOME\n'
} >>"$tmp"
install -m 0644 "$tmp" /etc/exports
rm -f "$tmp"
exportfs -ra
systemctl enable --now nfs-server
echo '[OK] NFS server is ready.'
showmount -e localhost
