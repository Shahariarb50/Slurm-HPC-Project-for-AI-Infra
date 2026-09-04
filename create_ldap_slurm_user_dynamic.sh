#!/usr/bin/env bash
# Create an LDAP user, NFS shared home, and Slurm account/association.
# Run this on the Slurm controller as root or with sudo.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
ask(){ local label="$1" default="$2" value; read -r -p "$label [$default]: " value; printf '%s' "${value:-$default}"; }
secret(){ local label="$1" value; read -r -s -p "$label: " value; echo >&2; [[ -n "$value" ]] || die "$label is required."; printf '%s' "$value"; }

domain_default='slurm.local'
suffix="$(slapcat -n 0 2>/dev/null | awk '/^olcSuffix: / {print $2; exit}' || true)"
if [[ "$suffix" =~ ^dc= ]]; then domain_default="$(sed -E 's/^dc=//;s/,dc=/./g' <<<"$suffix")"; fi

echo '=== Create LDAP + Slurm user ==='
username="$(ask 'New username (lowercase letters, digits, _ or -)' '')"
[[ "$username" =~ ^[a-z][a-z0-9_-]{1,30}$ ]] || die 'Invalid username.'
full_name="$(ask 'Full name' "$username")"
ldap_domain="$(ask 'LDAP domain' "$domain_default")"
base_dn="dc=${ldap_domain//./,dc=}"
admin_dn="$(ask 'LDAP admin DN' "cn=admin,$base_dn")"
cluster="$(ask 'Slurm cluster name' 'labcluster')"
partition="$(ask 'Default Slurm partition' 'cluster')"
qos="$(ask 'Default QoS' 'normal')"
home_root="$(ask 'Shared home root' '/shared/home')"
[[ "$home_root" == /* ]] || die 'Shared home root must begin with /.'

bind_password="$(secret 'LDAP admin password')"
user_password="$(secret "Password for $username")"
bind_password_file="$(mktemp)"
printf '%s' "$bind_password" >"$bind_password_file"
chmod 600 "$bind_password_file"

command -v ldapadd >/dev/null || { apt-get update; apt-get install -y ldap-utils; }
command -v sacctmgr >/dev/null || die 'sacctmgr is missing; run this on the Slurm controller.'
ldapsearch -LLL -x -D "$admin_dn" -y "$bind_password_file" -b "$base_dn" "(uid=$username)" dn | grep -q '^dn:' && die "LDAP user $username already exists."

# Support either conventional LDAP container name: ou=group or ou=groups.
group_ou="$(ldapsearch -LLL -x -D "$admin_dn" -y "$bind_password_file" -b "$base_dn" '(|(ou=group)(ou=groups))' dn |
  awk -F'[=,]' '/^dn: ou=/{print $2; exit}')"
[[ -n "$group_ou" ]] || die "LDAP group container is missing (expected ou=group or ou=groups under $base_dn)."

uid="$(
  ldapsearch -LLL -x -D "$admin_dn" -y "$bind_password_file" -b "$base_dn" '(uidNumber=*)' uidNumber |
  awk -F': ' '/^uidNumber:/{if($2>max)max=$2} END{print (max>=10000 ? max+1 : 10000)}'
)"
gid="$uid"
password_file="$(mktemp)"
trap 'rm -f "$password_file"' EXIT
printf '%s' "$user_password" >"$password_file"
chmod 600 "$password_file"
password_hash="$(slappasswd -T "$password_file")"
unset user_password bind_password
rm -f "$password_file"; trap - EXIT

tmp_ldif="$(mktemp)"
trap 'rm -f "$tmp_ldif"' EXIT
cat >"$tmp_ldif" <<EOF
dn: cn=$username,ou=$group_ou,$base_dn
objectClass: top
objectClass: posixGroup
cn: $username
gidNumber: $gid

dn: uid=$username,ou=people,$base_dn
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
cn: $full_name
sn: $username
uid: $username
uidNumber: $uid
gidNumber: $gid
homeDirectory: $home_root/$username
loginShell: /bin/bash
userPassword: $password_hash
shadowLastChange: $(($(date +%s)/86400))
EOF

# Ask for bind password only at the commands that need it; it never enters a command line.
ldapadd -x -D "$admin_dn" -y "$bind_password_file" -f "$tmp_ldif"

# Every new account is a normal Slurm user by default.
if ! ldapsearch -LLL -x -D "$admin_dn" -y "$bind_password_file" -b "ou=$group_ou,$base_dn" '(cn=slurm-users)' dn | grep -q '^dn:'; then
  ldapadd -x -D "$admin_dn" -y "$bind_password_file" <<EOF
dn: cn=slurm-users,ou=$group_ou,$base_dn
objectClass: top
objectClass: posixGroup
cn: slurm-users
gidNumber: 21000
EOF
fi
ldapmodify -x -D "$admin_dn" -y "$bind_password_file" <<EOF
dn: cn=slurm-users,ou=$group_ou,$base_dn
changetype: modify
add: memberUid
memberUid: $username
EOF

# NFS clients need execute/traverse access on the shared-home parent paths.
install -d -m 0755 "$(dirname "$home_root")"
chmod 0755 "$(dirname "$home_root")"
install -d -m 0755 "$home_root"
chmod 0755 "$home_root"
install -d -m 0700 "$home_root/$username"
chown "$uid:$gid" "$home_root/$username"
rm -f "$tmp_ldif" "$bind_password_file"; trap - EXIT

# Each user gets a separate Slurm account and permission to submit to the chosen partition/QoS.
sacctmgr -n show account "$username" format=Account | grep -qx "$username" || sacctmgr -i add account "$username" Cluster="$cluster" Description="Account for $username" Organization="$username"
sacctmgr -n show user "$username" format=User | grep -qx "$username" || sacctmgr -i add user "$username" Account="$username" Cluster="$cluster" DefaultAccount="$username" DefaultQOS="$qos"
sacctmgr -i modify user where name="$username" set DefaultAccount="$username" DefaultQOS="$qos"
sacctmgr -i modify user where name="$username" account="$username" set QOS="$qos"
# Explicit partition association is required when AccountingStorageEnforce=associations.
sacctmgr -i add user "$username" Account="$username" Cluster="$cluster" Partition="$partition" || true
sacctmgr -i modify user where name="$username" account="$username" partition="$partition" set QOS="$qos"

echo
echo '[OK] User created.'
echo "Username: $username"
echo "UID/GID: $uid/$gid"
echo "Shared home: $home_root/$username"
echo "Slurm account: $username | QoS: $qos | partition: $partition"
echo "The user can now SSH to the login node and run the submit script."
