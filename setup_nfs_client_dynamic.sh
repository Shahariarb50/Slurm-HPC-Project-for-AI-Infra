#!/usr/bin/env bash
# Run on every Slurm login/worker node after setup_nfs_controller.sh.
set -Eeuo pipefail
umask 077
info(){ printf '[INFO] %s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo bash $0"

read -r -p "NFS server IP/hostname [192.168.10.112]: " NFS_SERVER
NFS_SERVER=${NFS_SERVER:-192.168.10.112}
read -r -p "Shared home path [/shared/home]: " SHARE_PATH
SHARE_PATH=${SHARE_PATH:-/shared/home}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nfs-common sssd-tools
mkdir -p "$SHARE_PATH"

if ! mountpoint -q "$SHARE_PATH"; then
  mount -t nfs4 -o rw,hard,timeo=600,retrans=2 "$NFS_SERVER:$SHARE_PATH" "$SHARE_PATH"
fi
FSTAB_LINE="$NFS_SERVER:$SHARE_PATH $SHARE_PATH nfs4 rw,hard,timeo=600,retrans=2,_netdev 0 0"
grep -Fqx "$FSTAB_LINE" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
mountpoint -q "$SHARE_PATH" || die "NFS mount failed."
# Flush stale LDAP entries so changed homeDirectory values are visible now.
sss_cache -E 2>/dev/null || true
systemctl restart sssd 2>/dev/null || true
# nscd can retain obsolete LDAP homeDirectory values after an LDAP migration.
systemctl disable --now nscd 2>/dev/null || true
ok "Shared homes mounted at $SHARE_PATH"
