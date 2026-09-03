#!/usr/bin/env bash
# Dynamic Slurm LOGIN NODE setup. This host is a client, not a compute node.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo "Run: sudo bash $0"; exit 1; }
ask(){ local x; read -r -p "$1 [$2]: " x; printf '%s' "${x:-$2}"; }
secret(){ local x; read -r -s -p "$1: " x; echo >&2; [[ -n $x ]] || { echo 'Password cannot be empty' >&2; exit 1; }; printf '%s' "$x"; }
info(){ echo "[INFO] $*"; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
trap 'echo "[ERROR] Failed at line $LINENO; inspect: journalctl -u munge -u sssd --no-pager" >&2' ERR

LOGIN_IP=$(hostname -I | awk '{print $1}')
echo "Slurm login-node installer: $(hostname -s) ($LOGIN_IP)"
CONTROLLER=$(ask 'Controller IP or hostname' '192.168.43.44')
CLUSTER=$(ask 'Slurm cluster name' 'labcluster')
LDAP_DOMAIN=$(ask 'LDAP domain' 'slurm.local')
BASE="dc=${LDAP_DOMAIN//./,dc=}"
LDAP_URI=$(ask 'LDAP URI' "ldap://$CONTROLLER")
LDAP_BIND_DN=$(ask 'LDAP bind DN' "cn=admin,$BASE")
LDAP_BIND_PASS=$(secret 'LDAP bind password')
LDAP_TEST_USER=$(ask 'LDAP user to test' 'master')
COPY_KEY=$(ask 'Copy MUNGE key automatically over SSH? (Y/n)' 'Y')
if [[ $COPY_KEY =~ ^[Yy]$ ]]; then
  CONTROLLER_SSH_USER=$(ask 'Controller SSH username' 'master')
  CONTROLLER_SSH_PASS=$(secret 'Controller SSH and sudo password')
fi

info 'Checking network access to controller...'
ping -c 1 -W 2 "$CONTROLLER" >/dev/null 2>&1 || die "Cannot reach $CONTROLLER"
nc -z -w 4 "$CONTROLLER" 6817 || die 'Slurm controller port 6817 is unavailable'
LDAP_HOST=${LDAP_URI#ldap://}; LDAP_HOST=${LDAP_HOST#ldaps://}; LDAP_HOST=${LDAP_HOST%%/*}; LDAP_HOST=${LDAP_HOST%%:*}
LDAP_PORT=389; [[ $LDAP_URI == ldaps://* ]] && LDAP_PORT=636
nc -z -w 4 "$LDAP_HOST" "$LDAP_PORT" || die "LDAP port $LDAP_PORT is unavailable"

info 'Installing Slurm client, MUNGE, and SSSD...'
apt-get update
apt-get install -y slurm-client munge sssd-ldap libnss-sss libpam-sss ldap-utils netcat-openbsd sshpass
BACKUP="/root/login-node-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BACKUP"
for f in /etc/slurm/slurm.conf /etc/sssd/sssd.conf /etc/nsswitch.conf; do [[ -e $f ]] && cp -a "$f" "$BACKUP/"; done

install -d -m 0755 /etc/slurm
cat >/etc/slurm/slurm.conf <<EOF2
# Managed by setup-login-node-dynamic.sh
ClusterName=$CLUSTER
SlurmctldHost=$CONTROLLER
SlurmctldPort=6817
SlurmUser=slurm
AuthType=auth/munge
MpiDefault=none
EOF2

if [[ $COPY_KEY =~ ^[Yy]$ ]]; then
  info "Copying the shared MUNGE key from $CONTROLLER_SSH_USER@$CONTROLLER..."
  install -d -o munge -g munge -m 0700 /etc/munge
  export SSHPASS="$CONTROLLER_SSH_PASS"
  printf '%s\n' "$CONTROLLER_SSH_PASS" | sshpass -e ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no "$CONTROLLER_SSH_USER@$CONTROLLER" 'sudo -S -p "" cat /etc/munge/munge.key' >/etc/munge/munge.key
  unset SSHPASS CONTROLLER_SSH_PASS
  chown munge:munge /etc/munge/munge.key; chmod 0400 /etc/munge/munge.key
else
  [[ -s /etc/munge/munge.key ]] || die 'No local MUNGE key; use automatic copy or place the controller key first.'
fi
systemctl enable --now munge
systemctl restart munge

info 'Configuring LDAP/SSSD login...'
install -d -m 0755 /etc/sssd
cat >/etc/sssd/sssd.conf <<EOF2
[sssd]
config_file_version = 2
services = nss, pam, ssh
domains = ldap

[domain/ldap]
id_provider = ldap
auth_provider = ldap
chpass_provider = ldap
ldap_uri = $LDAP_URI
ldap_search_base = $BASE
ldap_default_bind_dn = $LDAP_BIND_DN
ldap_default_authtok_type = password
ldap_default_authtok = $LDAP_BIND_PASS
ldap_schema = rfc2307
ldap_id_use_start_tls = false
ldap_auth_disable_tls_never_use_in_production = true
cache_credentials = true
enumerate = false
fallback_homedir = /home/%u
default_shell = /bin/bash
EOF2
chown root:root /etc/sssd/sssd.conf; chmod 0600 /etc/sssd/sssd.conf
for db in passwd group shadow; do grep -Eq "^${db}:.*\bsss\b" /etc/nsswitch.conf || sed -Ei "s|^(${db}:[[:space:]]*.*)|\1 sss|" /etc/nsswitch.conf; done
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/60-sssd.conf <<'EOF2'
UsePAM yes
PasswordAuthentication yes
EOF2
grep -q 'pam_mkhomedir.so' /etc/pam.d/common-session || echo 'session required pam_mkhomedir.so skel=/etc/skel umask=0022' >>/etc/pam.d/common-session
systemctl enable --now sssd
systemctl restart ssh

info 'Verifying LDAP, MUNGE, and Slurm client...'
ldapsearch -LLL -x -H "$LDAP_URI" -D "$LDAP_BIND_DN" -w "$LDAP_BIND_PASS" -b "ou=people,$BASE" "(uid=$LDAP_TEST_USER)" dn | grep -q '^dn:' || die "LDAP user $LDAP_TEST_USER was not found"
getent passwd "$LDAP_TEST_USER" >/dev/null || die "SSSD cannot resolve LDAP user $LDAP_TEST_USER"
munge -n | unmunge >/dev/null || die 'Local MUNGE test failed'
sinfo >/dev/null || die 'Slurm query failed: check controller version, network, and shared MUNGE key'
echo
echo '============================================================'
echo "LOGIN NODE READY: $(hostname -s) ($LOGIN_IP)"
echo "Controller: $CONTROLLER | Cluster: $CLUSTER"
echo "LDAP login test user: $LDAP_TEST_USER"
echo "Backup directory: $BACKUP"
echo 'Note: login nodes do not appear in sinfo; only Slurm compute nodes do.'
echo '============================================================'
