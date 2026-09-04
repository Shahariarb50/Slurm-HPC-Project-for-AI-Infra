#!/usr/bin/env bash
# Safe LDAP + Slurm user and group manager. Run only on the controller.
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
ask(){ local label="$1" default="$2" value; read -r -p "$label [$default]: " value; printf '%s' "${value:-$default}"; }
secret(){ local value; read -r -s -p "$1: " value; echo >&2; [[ -n "$value" ]] || die "$1 is required."; printf '%s' "$value"; }
valid_name(){ [[ "$1" =~ ^[a-z][a-z0-9_-]{1,30}$ ]]; }
user_dn(){ printf 'uid=%s,ou=people,%s' "$1" "$base_dn"; }
group_dn(){ printf 'cn=%s,ou=%s,%s' "$1" "$group_ou" "$base_dn"; }
user_exists(){ ldapsearch -LLL -x -D "$admin_dn" -y "$bind_file" -b "$base_dn" "(uid=$1)" dn | grep -q '^dn:'; }
group_exists(){ ldapsearch -LLL -x -D "$admin_dn" -y "$bind_file" -b "$(group_dn "$1")" '(objectClass=posixGroup)' dn | grep -q '^dn:'; }
role_group(){ [[ "$1" == slurm-users || "$1" == slurm-admins || "$1" == slurm-superadmins ]]; }
add_member(){
  local group="$1" user="$2"
  ldapsearch -LLL -x -D "$admin_dn" -y "$bind_file" -b "$(group_dn "$group")" '(objectClass=posixGroup)' memberUid |
    grep -Fqx "memberUid: $user" && return 0
  ldapmodify -x -D "$admin_dn" -y "$bind_file" <<EOF
dn: $(group_dn "$group")
changetype: modify
add: memberUid
memberUid: $user
EOF
}
remove_member(){
  local group="$1" user="$2"
  ldapsearch -LLL -x -D "$admin_dn" -y "$bind_file" -b "$(group_dn "$group")" '(objectClass=posixGroup)' memberUid |
    grep -Fqx "memberUid: $user" || return 0
  ldapmodify -x -D "$admin_dn" -y "$bind_file" <<EOF
dn: $(group_dn "$group")
changetype: modify
delete: memberUid
memberUid: $user
EOF
}

domain_default='slurm.local'
suffix="$(slapcat -n 0 2>/dev/null | awk '/^olcSuffix: / {print $2; exit}' || true)"
[[ "$suffix" =~ ^dc= ]] && domain_default="$(sed -E 's/^dc=//;s/,dc=/./g' <<<"$suffix")"
ldap_domain="$(ask 'LDAP domain' "$domain_default")"
base_dn="dc=${ldap_domain//./,dc=}"
admin_dn="$(ask 'LDAP admin DN' "cn=admin,$base_dn")"
bind_password="$(secret 'LDAP admin password')"
bind_file="$(mktemp)"
trap 'rm -f "$bind_file"' EXIT
printf '%s' "$bind_password" >"$bind_file"
chmod 600 "$bind_file"
unset bind_password
group_ou="$(ldapsearch -LLL -x -D "$admin_dn" -y "$bind_file" -b "$base_dn" '(|(ou=group)(ou=groups))' dn | awk -F'[=,]' '/^dn: ou=/{print $2;exit}')"
[[ -n "$group_ou" ]] || die "LDAP group container missing."

ensure_role_groups(){
  local n gid
  for n in slurm-users slurm-admins slurm-superadmins; do
    case "$n" in slurm-users) gid=21000;; slurm-admins) gid=21001;; *) gid=21002;; esac
    group_exists "$n" || ldapadd -x -D "$admin_dn" -y "$bind_file" <<EOF
dn: $(group_dn "$n")
objectClass: top
objectClass: posixGroup
cn: $n
gidNumber: $gid
EOF
  done
}

edit_user(){
  local u choice full_name pass qos role
  u="$(ask 'Username to edit' '')"; valid_name "$u" || die 'Invalid username.'
  user_exists "$u" || die "User $u does not exist."
  echo '1) Change full name  2) Change password  3) Change QoS  4) Change role'
  choice="$(ask 'Edit option' '1')"
  case "$choice" in
    1) full_name="$(ask 'New full name' "$u")"
       ldapmodify -x -D "$admin_dn" -y "$bind_file" <<EOF
dn: $(user_dn "$u")
changetype: modify
replace: cn
cn: $full_name
-
replace: sn
sn: $u
EOF
       ;;
    2) pass="$(secret "New password for $u")"; pf="$(mktemp)"; printf '%s' "$pass" >"$pf"; chmod 600 "$pf"
       ldappasswd -x -D "$admin_dn" -y "$bind_file" -T "$pf" "$(user_dn "$u")"; rm -f "$pf"; unset pass ;;
    3) qos="$(ask 'New default QoS' 'normal')"
       sacctmgr -i modify user where name="$u" set DefaultQOS="$qos"
       sacctmgr -i modify user where name="$u" account="$u" set QOS="$qos" ;;
    4) role="$(ask 'Role: user, admin, or superadmin' 'user')"
       case "$role" in user) role=slurm-users;; admin) role=slurm-admins;; superadmin) role=slurm-superadmins;; *) die 'Invalid role.';; esac
       for g in slurm-users slurm-admins slurm-superadmins; do remove_member "$g" "$u"; done
       add_member "$role" "$u"
       if [[ "$role" == slurm-superadmins ]]; then sacctmgr -i modify user where name="$u" set AdminLevel=Admin
       elif [[ "$role" == slurm-admins ]]; then sacctmgr -i modify user where name="$u" set AdminLevel=Operator
       else sacctmgr -i modify user where name="$u" set AdminLevel=None
       fi ;;
    *) die 'Invalid option.' ;;
  esac
  echo "[OK] User $u updated."
}

delete_user(){
  local u confirm uid archive
  u="$(ask 'Username to delete' '')"; valid_name "$u" || die 'Invalid username.'
  user_exists "$u" || die "User $u does not exist."
  echo "This disables LDAP and Slurm access. Home data will be archived, not deleted."
  confirm="$(ask "Type DELETE-$u to confirm" '')"
  [[ "$confirm" == "DELETE-$u" ]] || die 'Confirmation did not match.'
  uid="$(ldapsearch -LLL -x -D "$admin_dn" -y "$bind_file" -b "$(user_dn "$u")" '(objectClass=posixAccount)' uidNumber | awk -F': ' '/^uidNumber:/{print $2;exit}')"
  for g in slurm-users slurm-admins slurm-superadmins; do remove_member "$g" "$u"; done
  # Remove both the user association and its dedicated Slurm account.
  sacctmgr -i delete user where name="$u" || true
  sacctmgr -i delete account where name="$u" || true
  archive="/shared/home-archive/$u-$(date +%Y%m%d-%H%M%S)"
  if [[ -d "/shared/home/$u" ]]; then
    install -d -m 0750 /shared/home-archive
    mv "/shared/home/$u" "$archive"
    echo "Archived home: $archive"
  fi
  group_exists "$u" && ldapdelete -x -D "$admin_dn" -y "$bind_file" "$(group_dn "$u")"
  ldapdelete -x -D "$admin_dn" -y "$bind_file" "$(user_dn "$u")"

  # Fail loudly if any LDAP or Slurm identity remains; do not claim success.
  user_exists "$u" && die "LDAP user $u still exists; deletion is incomplete."
  sacctmgr -n show user where name="$u" format=User | grep -q '[^[:space:]]' && die "Slurm user $u still exists; deletion is incomplete."
  sacctmgr -n show account "$u" format=Account | grep -q '[^[:space:]]' && die "Slurm account $u still exists; deletion is incomplete."
  echo "[OK] User $u fully deleted. UID was $uid. Restart SSSD on login/worker before reusing this username."
}

create_group(){
  local g gid
  g="$(ask 'New group name' '')"; valid_name "$g" || die 'Invalid group name.'
  role_group "$g" && die 'Reserved Slurm role group name.'
  group_exists "$g" && die "Group $g already exists."
  gid="$(ask 'Group GID' "$(ldapsearch -LLL -x -D "$admin_dn" -y "$bind_file" -b "ou=$group_ou,$base_dn" '(gidNumber=*)' gidNumber | awk -F': ' '/^gidNumber:/{if($2>m)m=$2} END{print (m>=22000?m+1:22000)}')")"
  [[ "$gid" =~ ^[0-9]+$ ]] || die 'GID must be numeric.'
  ldapadd -x -D "$admin_dn" -y "$bind_file" <<EOF
dn: $(group_dn "$g")
objectClass: top
objectClass: posixGroup
cn: $g
gidNumber: $gid
EOF
  echo "[OK] Group $g created."
}

delete_group(){
  local g confirm
  g="$(ask 'Group to delete' '')"; valid_name "$g" || die 'Invalid group name.'
  role_group "$g" && die 'Reserved Slurm role groups cannot be deleted here.'
  group_exists "$g" || die "Group $g does not exist."
  confirm="$(ask "Type DELETE-$g to confirm" '')"
  [[ "$confirm" == "DELETE-$g" ]] || die 'Confirmation did not match.'
  ldapdelete -x -D "$admin_dn" -y "$bind_file" "$(group_dn "$g")"
  echo "[OK] Group $g deleted."
}

member_action(){
  local action g u
  action="$(ask 'Action: add or remove' 'add')"
  g="$(ask 'Group name' '')"; u="$(ask 'Username' '')"
  valid_name "$g" && valid_name "$u" || die 'Invalid username/group name.'
  group_exists "$g" || die "Group $g does not exist."
  user_exists "$u" || die "User $u does not exist."
  [[ "$action" == add ]] && add_member "$g" "$u" || [[ "$action" == remove ]] && remove_member "$g" "$u" || die 'Action must be add or remove.'
  echo "[OK] Membership updated."
}

ensure_role_groups
echo '=== LDAP + Slurm User/Group Manager ==='
echo '1) Edit user'
echo '2) Delete user (archive home)'
echo '3) Create custom group'
echo '4) Delete custom group'
echo '5) Add/remove group member'
echo '6) List users and groups'
action="$(ask 'Choose action' '6')"
case "$action" in
  1) edit_user ;;
  2) delete_user ;;
  3) create_group ;;
  4) delete_group ;;
  5) member_action ;;
  6) ldapsearch -LLL -x -D "$admin_dn" -y "$bind_file" -b "$base_dn" '(|(objectClass=posixAccount)(objectClass=posixGroup))' uid cn gidNumber memberUid ;;
  *) die 'Invalid action.' ;;
esac