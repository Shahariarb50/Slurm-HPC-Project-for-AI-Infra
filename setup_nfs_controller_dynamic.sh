#!/usr/bin/env bash
# Dynamic NFS shared-home setup for a Slurm controller.
# Supports clients on multiple routed VLANs/subnets.
set -Eeuo pipefail
umask 077

info(){ printf '[INFO] %s\n' "$*"; }
ok(){ printf '[OK] %s\n' "$*"; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run with: sudo bash $0"

ask() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value
  printf '%s' "${value:-$default}"
}

# Read the LDAP suffix when OpenLDAP is installed; otherwise use the lab default.
detect_ldap_domain() {
  local suffix
  suffix="$(slapcat -n 0 2>/dev/null | awk '/^olcSuffix: / {print $2; exit}' || true)"
  if [[ "$suffix" =~ ^dc= ]]; then
    sed -E 's/^dc=//; s/,dc=/./g' <<<"$suffix"
  else
    printf '%s' 'slurm.local'
  fi
}

normalise_client() {
  local client="$1"
  # A bare IPv4 address is made a single-host NFS export.
  if [[ "$client" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s/32' "$client"
  elif [[ "$client" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
    printf '%s' "$client"
  else
    die "Invalid client network/IP: $client"
  fi
}

SHARE_PATH="$(ask 'Shared home path' '/shared/home')"
[[ "$SHARE_PATH" == /* ]] || die "Shared home path must start with / (example: /shared/home)."
DEFAULT_NETS='192.168.43.0/24,192.168.182.0/24'
CLIENTS_RAW="$(ask 'Allowed client networks/IPs (comma separated)' "$DEFAULT_NETS")"
LDAP_DOMAIN="$(ask 'LDAP domain' "$(detect_ldap_domain)")"
BASE_DN="dc=${LDAP_DOMAIN//./,dc=}"
LDAP_ADMIN_DN="$(ask 'LDAP admin DN' "cn=admin,$BASE_DN")"
read -r -s -p 'LDAP admin password: ' LDAP_PASSWORD; echo
[[ -n "$LDAP_PASSWORD" ]] || die 'LDAP admin password is required.'

IFS=', ' read -r -a requested_clients <<<"$CLIENTS_RAW"
(( ${#requested_clients[@]} > 0 )) || die 'At least one allowed client network/IP is required.'
client_specs=()
for client in "${requested_clients[@]}"; do
  [[ -n "$client" ]] && client_specs+=("$(normalise_client "$client")")
done
(( ${#client_specs[@]} > 0 )) || die 'No valid client network/IP was supplied.'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nfs-kernel-server ldap-utils

install -d -m 0755 "$SHARE_PATH"
BACKUP_DIR="/root/nfs-home-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
[[ -e /etc/exports ]] && cp -a /etc/exports "$BACKUP_DIR/exports"

mapfile -t users < <(
  ldapsearch -LLL -x -D "$LDAP_ADMIN_DN" -w "$LDAP_PASSWORD" \
    -b "ou=people,$BASE_DN" '(objectClass=posixAccount)' uid uidNumber gidNumber homeDirectory |
  awk -F': ' '
    /^uid: / {u=$2}
    /^uidNumber: / {id=$2}
    /^gidNumber: / {g=$2}
    /^homeDirectory: / {
      h=$2
      if (u && id && g) print u "|" id "|" g "|" h
      u=id=g=h=""
    }'
)
(( ${#users[@]} > 0 )) || die "No LDAP posix users found under ou=people,$BASE_DN."

for entry in "${users[@]}"; do
  IFS='|' read -r user uid gid old_home <<<"$entry"
  new_home="$SHARE_PATH/$user"
  # LDAP UID/GID can be valid numeric IDs even when no local passwd entry exists.
  install -d -m 0700 "$new_home"
  chown "$uid:$gid" "$new_home"
  if [[ -d "$old_home" && "$old_home" != "$new_home" ]]; then
    cp -a -n "$old_home/." "$new_home/" || true
    chown -R "$uid:$gid" "$new_home"
  fi
  ldapmodify -x -D "$LDAP_ADMIN_DN" -w "$LDAP_PASSWORD" <<EOF
dn: uid=$user,ou=people,$BASE_DN
changetype: modify
replace: homeDirectory
homeDirectory: $new_home
EOF
done

# Replace only this script's managed export block; unrelated exports stay intact.
tmp_exports="$(mktemp)"
awk '/^# BEGIN SLURM-NFS-MANAGED$/ {skip=1; next} /^# END SLURM-NFS-MANAGED$/ {skip=0; next} !skip {print}' /etc/exports >"$tmp_exports"
{
  echo '# BEGIN SLURM-NFS-MANAGED'
  printf '%s' "$SHARE_PATH"
  for network in "${client_specs[@]}"; do
    printf ' %s(rw,sync,no_subtree_check,root_squash)' "$network"
  done
  printf '\n# END SLURM-NFS-MANAGED\n'
} >>"$tmp_exports"
install -m 0644 "$tmp_exports" /etc/exports
rm -f "$tmp_exports"

exportfs -ra
systemctl enable --now nfs-server
echo
showmount -e localhost
ok "NFS shared home ready: $SHARE_PATH"
ok "Allowed client networks/IPs: ${client_specs[*]}"
ok "Backup of prior exports: $BACKUP_DIR/exports"
