#!/usr/bin/env bash
# Configure LDAP identity lookup on a Slurm login node or worker node.
# Run once on every client node. Required for LDAP users to run Slurm jobs.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

ask(){ local label="$1" default="$2" value; read -r -p "$label [$default]: " value; printf '%s' "${value:-$default}"; }
secret(){ local value; read -r -s -p 'LDAP bind password: ' value; echo; [[ -n "$value" ]] || { echo '[ERROR] Password is required.' >&2; exit 1; }; printf '%s' "$value"; }

ldap_server="$(ask 'LDAP server IP/hostname' '192.168.43.44')"
ldap_domain="$(ask 'LDAP domain' 'slurm.local')"
base_dn="dc=${ldap_domain//./,dc=}"
bind_dn="$(ask 'LDAP bind DN' "cn=admin,$base_dn")"
bind_password="$(secret)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y sssd-ldap libnss-sss libpam-sss ldap-utils
install -d -m 0755 /etc/sssd
cat >/etc/sssd/sssd.conf <<EOF
[sssd]
config_file_version = 2
services = nss, pam, ssh
domains = ldap

[domain/ldap]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap
ldap_uri = $ldap_server
ldap_search_base = $base_dn
ldap_default_bind_dn = $bind_dn
ldap_default_authtok_type = password
ldap_default_authtok = $bind_password
ldap_schema = rfc2307
ldap_id_use_start_tls = false
ldap_auth_disable_tls_never_use_in_production = true
cache_credentials = true
enumerate = false
override_homedir = /shared/home/%u
default_shell = /bin/bash
EOF
unset bind_password
chmod 600 /etc/sssd/sssd.conf
for database in passwd group shadow; do
  grep -Eq "^$database:.*\bsss\b" /etc/nsswitch.conf || sed -i -E "s/^($database:.*)/\1 sss/" /etc/nsswitch.conf
done
systemctl enable sssd
systemctl restart sssd
echo '[OK] LDAP identity service is ready.'
echo 'Verify with: getent passwd <username>'