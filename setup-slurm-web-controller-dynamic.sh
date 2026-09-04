#!/bin/bash
set -e

# ===================================================
# রঙিন আউটপুটের জন্য
# ===================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ===================================================
# ১. ইউজারের কাছ থেকে সব কনফিগ ইনপুট নেওয়া
# ===================================================
echo "============================================================"
echo "       Slurm + OpenLDAP Interactive Setup (Fully Dynamic)"
echo "============================================================"
echo ""

# Cluster Name
read -p "Enter Cluster Name [labcluster]: " CLUSTER_NAME
CLUSTER_NAME=${CLUSTER_NAME:-labcluster}

# Database Name
read -p "Enter Database Name [slurm_acct_db]: " DB_NAME
DB_NAME=${DB_NAME:-slurm_acct_db}

# Database User
read -p "Enter Database Username [slurm]: " DB_USER
DB_USER=${DB_USER:-slurm}

# Database Password
read -s -p "Enter Database Password: " DB_PASS
echo ""
if [ -z "$DB_PASS" ]; then
    print_error "Database password cannot be empty!"
    exit 1
fi

# LDAP Admin Password
read -s -p "Enter LDAP Admin Password: " LDAP_PASS
echo ""
if [ -z "$LDAP_PASS" ]; then
    print_error "LDAP password cannot be empty!"
    exit 1
fi

# LDAP Domain
read -p "Enter LDAP Domain (e.g., diu.edu.bd): " LDAP_DOMAIN
if [ -z "$LDAP_DOMAIN" ]; then
    print_error "Domain cannot be empty!"
    exit 1
fi

# LDAP Organization
read -p "Enter Organization Name (e.g., Daffodil): " LDAP_ORG
if [ -z "$LDAP_ORG" ]; then
    print_error "Organization cannot be empty!"
    exit 1
fi

# Default User
read -p "Enter default username [john]: " DEFAULT_USER
DEFAULT_USER=${DEFAULT_USER:-john}

read -s -p "Enter password for '$DEFAULT_USER': " DEFAULT_USER_PASS
echo ""
if [ -z "$DEFAULT_USER_PASS" ]; then
    DEFAULT_USER_PASS=$LDAP_PASS
    print_warning "Using LDAP password for default user"
fi

# Slurm Admin User
read -p "Enter Slurm admin username [admin]: " SLURM_ADMIN
SLURM_ADMIN=${SLURM_ADMIN:-admin}

read -s -p "Enter password for '$SLURM_ADMIN': " SLURM_ADMIN_PASS
echo ""
if [ -z "$SLURM_ADMIN_PASS" ]; then
    SLURM_ADMIN_PASS=$LDAP_PASS
    print_warning "Using LDAP password for admin user"
fi

# Partition Name
read -p "Enter Partition Name [debug]: " PARTITION_NAME
PARTITION_NAME=${PARTITION_NAME:-debug}

# ===================================================
# ২. স্বয়ংক্রিয় ডিটেক্ট
# ===================================================
HOST_IP=$(hostname -I | awk '{print $1}')
HOST_NAME=$(hostname)
UBUNTU_RELEASE="ubuntu$(lsb_release -rs)"
LDAP_BASE_DN="dc=${LDAP_DOMAIN//./,dc=}"

echo ""
print_info "Detected IP: $HOST_IP"
print_info "Detected Hostname: $HOST_NAME"
print_info "Detected Ubuntu: $UBUNTU_RELEASE"
print_info "LDAP Base DN: $LDAP_BASE_DN"
print_info "Cluster Name: $CLUSTER_NAME"
print_info "Database: $DB_NAME"
print_info "Database User: $DB_USER"
echo ""

read -p "Press ENTER to continue or Ctrl+C to cancel..."

# ===================================================
# ৩. Slurm + Slurm-web ইনস্টল
# ===================================================
print_info "Installing Slurm and dependencies..."
sudo apt update
sudo apt install -y slurm-wlm slurmdbd slurmrestd slurm-wlm-jwt-plugin mariadb-server munge curl gpg debconf-utils openssl
sudo systemctl disable --now slurmd 2>/dev/null || true
sudo install -d -o slurm -g slurm -m 0755 /var/spool/slurmctld /var/log/slurm

# ===================================================
# ৪. slurm.conf
# ===================================================
print_info "Configuring slurm.conf..."
sudo tee /etc/slurm/slurm.conf > /dev/null <<EOF
ClusterName=$CLUSTER_NAME
SlurmctldHost=$HOST_NAME
SlurmUser=slurm
AuthType=auth/munge
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/var/lib/slurm-web/jwt.key
StateSaveLocation=/var/spool/slurmctld
SlurmctldPidFile=/run/slurmctld.pid
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SwitchType=switch/none
MpiDefault=none
ProctrackType=proctrack/cgroup
ReturnToService=2
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
EOF

# ===================================================
# ৫. slurmdbd.conf
# ===================================================
print_info "Configuring slurmdbd.conf..."
sudo tee /etc/slurm/slurmdbd.conf > /dev/null <<EOF
AuthType=auth/munge
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/var/lib/slurm-web/jwt.key
DbdHost=localhost
DbdPort=6819
SlurmUser=slurm
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=$DB_USER
StoragePass=$DB_PASS
StorageLoc=$DB_NAME
EOF

sudo chown slurm:slurm /etc/slurm/slurm.conf /etc/slurm/slurmdbd.conf
sudo chmod 600 /etc/slurm/slurmdbd.conf

# ===================================================
# ৬. MariaDB Setup
# ===================================================
print_info "Setting up MariaDB..."
sudo systemctl enable --now mariadb munge
sudo systemctl is-active --quiet mariadb || { print_error "MariaDB failed to start"; sudo journalctl -u mariadb -n 80 --no-pager; exit 1; }

sudo mariadb <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ===================================================
# ৭. Rackslab Repository
# ===================================================
print_info "Adding Rackslab repository..."
curl -fsSL https://pkgs.rackslab.io/keyring.asc | sudo gpg --dearmor -o /usr/share/keyrings/rackslab.gpg
sudo tee /etc/apt/sources.list.d/rackslab.sources > /dev/null <<EOF
Types: deb
URIs: https://pkgs.rackslab.io/deb
Suites: $UBUNTU_RELEASE
Components: main slurmweb-7
Architectures: amd64
Signed-By: /usr/share/keyrings/rackslab.gpg
EOF

sudo apt update
sudo apt install -y slurm-web-agent slurm-web-gateway

# ===================================================
# ৮. JWT & Session Keys
# ===================================================
print_info "Generating JWT and Session keys..."
sudo mkdir -p /var/lib/slurm-web
# Slurm auth/jwt and Slurm-web both use HS256.  This must be a shared
# symmetric secret, NOT an RSA private key.  An RSA key causes PyJWT to
# reject login-token creation with "asymmetric key ... HMAC secret".
sudo openssl rand -base64 48 > /var/lib/slurm-web/jwt.key
sudo chown slurm:slurm-web /var/lib/slurm-web/jwt.key
sudo chmod 640 /var/lib/slurm-web/jwt.key

sudo openssl rand -base64 32 > /var/lib/slurm-web/session.key
sudo chown slurm-web:slurm-web /var/lib/slurm-web/session.key
sudo chmod 640 /var/lib/slurm-web/session.key

sudo useradd --system --no-create-home --shell /usr/sbin/nologin slurmrestd 2>/dev/null || true
sudo usermod -aG slurm-web slurmrestd

# ===================================================
# ৯. Slurm-web Agent
# ===================================================
print_info "Configuring Slurm-web Agent..."
sudo mkdir -p /etc/slurm-web
sudo tee /etc/slurm-web/agent.ini > /dev/null <<EOF
[service]
cluster=$CLUSTER_NAME

[slurmrestd]
uri=http://127.0.0.1:6820
auth=jwt
jwt_mode=auto
jwt_user=slurm
jwt_key=/var/lib/slurm-web/jwt.key
EOF

# ===================================================
# ১০. Slurm-web Policy
# ===================================================
# Use only actions supported by Slurm-web 7.  Unsupported actions make the
# slurm-web-agent service fail at startup, leaving the web UI unusable.
sudo tee /etc/slurm-web/policy.ini > /dev/null <<'EOF'
[roles]
user=ALL
admin=@slurm-superadmins

[user]
actions=stats-view,jobs-view,jobs-view-past,nodes-view,partitions-view,qos-view,accounts-view,associations-view,reservations-view

[admin]
actions=stats-view,jobs-view,jobs-view-past,nodes-view,partitions-view,qos-view,accounts-view,associations-view,reservations-view,cache-view,cache-reset
EOF

sudo chown slurm-web:slurm-web /etc/slurm-web/policy.ini
sudo chmod 640 /etc/slurm-web/policy.ini

# ===================================================
# ১১. Slurm-web Gateway
# ===================================================
sudo tee /etc/slurm-web/gateway.ini > /dev/null <<EOF
[service]
interface=$HOST_IP
port=5011
session_key=/var/lib/slurm-web/session.key

[ui]
host=http://$HOST_IP:5011

[agents]
url=http://localhost:5012

[authentication]
enabled=no
EOF

sudo chown slurm-web:slurm-web /etc/slurm-web/agent.ini /etc/slurm-web/gateway.ini

# ===================================================
# ১২. slurmrestd Override
# ===================================================
sudo tee /etc/default/slurmrestd > /dev/null <<'EOF'
SLURMRESTD_OPTIONS="-u slurmrestd"
EOF

sudo mkdir -p /etc/systemd/system/slurmrestd.service.d
sudo tee /etc/systemd/system/slurmrestd.service.d/override.conf > /dev/null <<'EOF'
[Service]
ExecStartPre=/usr/bin/install -d -o slurmrestd -g slurmrestd -m 0755 /run/slurmrestd
ExecStart=
ExecStart=/usr/sbin/slurmrestd $SLURMRESTD_OPTIONS unix:/run/slurmrestd/slurmrestd.socket 127.0.0.1:6820
EOF
sudo systemctl daemon-reload

# ===================================================
# ১৩. Services Start
# ===================================================
print_info "Starting services..."
sudo systemctl enable --now munge mariadb
sudo systemctl restart slurmdbd
sleep 5

sudo sacctmgr -i add cluster $CLUSTER_NAME || true
sudo sacctmgr -i add account default Description=Default Organization=Default || true
sudo sacctmgr -i add user $SLURM_ADMIN Account=default || true

sudo systemctl restart slurmctld
sudo systemctl restart slurmrestd
sudo systemctl restart slurm-web-agent
sudo systemctl restart slurm-web-gateway
sudo systemctl enable slurmdbd slurmctld slurmrestd slurm-web-agent slurm-web-gateway

# ===================================================
# ১৪. OpenLDAP Setup
# ===================================================
print_info "Setting up OpenLDAP..."
echo "slapd slapd/internal/adminpw password $LDAP_PASS" | debconf-set-selections
echo "slapd slapd/internal/generated_adminpw password $LDAP_PASS" | debconf-set-selections
echo "slapd slapd/password1 password $LDAP_PASS" | debconf-set-selections
echo "slapd slapd/password2 password $LDAP_PASS" | debconf-set-selections
echo "slapd slapd/domain string $LDAP_DOMAIN" | debconf-set-selections
echo "slapd slapd/organization string $LDAP_ORG" | debconf-set-selections
echo "slapd slapd/backend select MDB" | debconf-set-selections
echo "slapd slapd/purge_database boolean false" | debconf-set-selections
echo "slapd slapd/move_old_database boolean true" | debconf-set-selections
echo "slapd slapd/allow_ldap_v2 boolean false" | debconf-set-selections

sudo DEBIAN_FRONTEND=noninteractive apt install slapd ldap-utils -y

# ===================================================
# ১৫. LDAP Base Structure
# ===================================================
cat <<EOF > /tmp/base.ldif
dn: ou=people,$LDAP_BASE_DN
objectClass: organizationalUnit
ou: people

dn: ou=group,$LDAP_BASE_DN
objectClass: organizationalUnit
ou: group

dn: cn=engineers,ou=group,$LDAP_BASE_DN
objectClass: posixGroup
cn: engineers
gidNumber: 5001

dn: cn=researchers,ou=group,$LDAP_BASE_DN
objectClass: posixGroup
cn: researchers
gidNumber: 5002

dn: cn=slurm-users,ou=group,$LDAP_BASE_DN
objectClass: posixGroup
cn: slurm-users
gidNumber: 21000

dn: cn=slurm-admins,ou=group,$LDAP_BASE_DN
objectClass: posixGroup
cn: slurm-admins
gidNumber: 21001

dn: cn=slurm-superadmins,ou=group,$LDAP_BASE_DN
objectClass: posixGroup
cn: slurm-superadmins
gidNumber: 21002
EOF

sudo ldapadd -x -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_PASS" -f /tmp/base.ldif 2>/dev/null || print_warning "Base OU/Groups already exist"

# ===================================================
# ১৬. Create Default User
# ===================================================
NEXT_UID=10001
cat <<EOF > /tmp/default_user.ldif
dn: uid=$DEFAULT_USER,ou=people,$LDAP_BASE_DN
objectClass: inetOrgPerson
objectClass: posixAccount
uid: $DEFAULT_USER
sn: $DEFAULT_USER
givenName: $DEFAULT_USER
cn: $DEFAULT_USER
uidNumber: $NEXT_UID
gidNumber: 5001
userPassword: {CRYPT}x
loginShell: /bin/bash
homeDirectory: /home/$DEFAULT_USER
EOF

sudo ldapadd -x -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_PASS" -f /tmp/default_user.ldif 2>/dev/null || print_warning "User $DEFAULT_USER already exists"
sudo ldappasswd -x -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_PASS" -s "$DEFAULT_USER_PASS" "uid=$DEFAULT_USER,ou=people,$LDAP_BASE_DN" 2>/dev/null || print_warning "Password already set"

cat <<EOF > /tmp/add_default.ldif
dn: cn=slurm-users,ou=group,$LDAP_BASE_DN
changetype: modify
add: memberUid
memberUid: $DEFAULT_USER
EOF
sudo ldapmodify -x -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_PASS" -f /tmp/add_default.ldif 2>/dev/null || print_warning "Already member"

# ===================================================
# ১৭. Create Admin User
# ===================================================
NEXT_UID=$((NEXT_UID + 1))
cat <<EOF > /tmp/admin_user.ldif
dn: uid=$SLURM_ADMIN,ou=people,$LDAP_BASE_DN
objectClass: inetOrgPerson
objectClass: posixAccount
uid: $SLURM_ADMIN
sn: $SLURM_ADMIN
givenName: $SLURM_ADMIN
cn: $SLURM_ADMIN
uidNumber: $NEXT_UID
gidNumber: 5003
userPassword: {CRYPT}x
loginShell: /bin/bash
homeDirectory: /home/$SLURM_ADMIN
EOF

sudo ldapadd -x -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_PASS" -f /tmp/admin_user.ldif 2>/dev/null || print_warning "User $SLURM_ADMIN already exists"
sudo ldappasswd -x -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_PASS" -s "$SLURM_ADMIN_PASS" "uid=$SLURM_ADMIN,ou=people,$LDAP_BASE_DN" 2>/dev/null || print_warning "Password already set"

cat <<EOF > /tmp/add_admin.ldif
dn: cn=slurm-superadmins,ou=group,$LDAP_BASE_DN
changetype: modify
add: memberUid
memberUid: $SLURM_ADMIN
EOF
sudo ldapmodify -x -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_PASS" -f /tmp/add_admin.ldif 2>/dev/null || print_warning "Already member"

# ===================================================
# ১৮. Enable LDAP Authentication in Gateway
# ===================================================
sudo tee /etc/slurm-web/gateway.ini > /dev/null <<EOF
[service]
interface=$HOST_IP
port=5011
session_key=/var/lib/slurm-web/session.key

[ui]
host=http://$HOST_IP:5011

[agents]
url=http://localhost:5012

[authentication]
enabled=yes
method=ldap

[ldap]
uri=ldap://localhost
user_base=ou=people,$LDAP_BASE_DN
group_base=ou=group,$LDAP_BASE_DN
bind_dn=cn=admin,$LDAP_BASE_DN
bind_password=$LDAP_PASS
EOF

sudo chown slurm-web:slurm-web /etc/slurm-web/gateway.ini

# ===================================================
# ১৯. Add Node to Slurm
# ===================================================
print_info "Adding node to Slurm..."
# Slurm needs RealMemory in MiB.  If it is omitted, the controller can
# register only the 1 MiB default, making ordinary --mem requests impossible.
# Reserve 512 MiB for Ubuntu and Slurm itself, with a safe 256 MiB minimum.
TOTAL_MEMORY_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
OS_RESERVE_KB=$((512 * 1024))
REAL_MEMORY_MB=$(((TOTAL_MEMORY_KB - OS_RESERVE_KB) / 1024))
if [ "$REAL_MEMORY_MB" -lt 256 ]; then
    print_error "Detected RAM is too low (${TOTAL_MEMORY_KB} KiB) after the 512 MiB OS reserve."
    exit 1
fi
print_info "Slurm job memory set to ${REAL_MEMORY_MB} MiB (512 MiB reserved for OS)"
sudo sed -i '/^NodeName=/d' /etc/slurm/slurm.conf
sudo sed -i '/^PartitionName=/d' /etc/slurm/slurm.conf
sudo tee -a /etc/slurm/slurm.conf > /dev/null <<EOF
NodeName=$HOST_NAME CPUs=$(nproc) RealMemory=$REAL_MEMORY_MB State=UNKNOWN
PartitionName=$PARTITION_NAME Nodes=$HOST_NAME Default=YES MaxTime=INFINITE State=UP
EOF

# ===================================================
# ২০. Final Restart
# ===================================================
print_info "Final restart of all services..."
sudo systemctl restart slapd
sudo systemctl restart slurmdbd
sleep 5
sudo systemctl restart slurmctld
sudo systemctl restart slurmd
sudo systemctl restart slurmrestd
sudo systemctl reset-failed slurm-web-agent
sudo systemctl restart slurm-web-agent
sudo systemctl restart slurm-web-gateway

# ===================================================
# ২১. Final Output
# ===================================================
echo ""
echo "============================================================"
print_success "SETUP COMPLETE!"
echo "============================================================"
echo ""
sinfo
echo ""
echo "Service Status:"
sudo systemctl is-active munge mariadb slapd slurmdbd slurmctld slurmrestd slurm-web-agent slurm-web-gateway | paste -d ',' - - - - - - - -
sudo systemctl --quiet is-active slurm-web-agent slurm-web-gateway || {
    print_error "Slurm-web service failed. Check: sudo journalctl -u slurm-web-agent -u slurm-web-gateway -n 100 --no-pager"
    exit 1
}

# Confirm that the LDAP user created by this script can be found by the same
# base DN configured in the gateway.  The login name is DEFAULT_USER, not the
# Ubuntu/SSH account name unless both were deliberately set to the same value.
if sudo ldapsearch -LLL -x -b "ou=people,$LDAP_BASE_DN" "(uid=$DEFAULT_USER)" dn | grep -q '^dn:'; then
    print_success "LDAP login user '$DEFAULT_USER' is ready"
else
    print_error "LDAP user '$DEFAULT_USER' was not found; do not use the web UI until this is fixed."
    exit 1
fi
echo ""
echo "============================================================"
echo "🌐 Web UI: http://$HOST_IP:5011"
echo "👤 Default User: $DEFAULT_USER"
echo "🔑 Default Password: $DEFAULT_USER_PASS"
echo "ℹ️  Use the Default User above to log in. Your Ubuntu/SSH username is not automatically a Slurm-web user."
echo ""
echo "👤 Admin User: $SLURM_ADMIN"
echo "🔑 Admin Password: $SLURM_ADMIN_PASS"
echo "============================================================"
echo ""
print_info "To add more users, run: sudo ./add_user.sh"

# ===================================================
# ২২. Compatibility fixes: Slurm 25 + Slurm-web 7 accounting/RBAC
# ===================================================
print_info "Applying Slurm 25 accounting and Slurm-web compatibility settings..."
# slurmrestd uses JWT when it reads QoS/accounts/reservations from slurmdbd.
# The controller setup must configure the same shared JWT key for slurmdbd.
sudo sed -i '/^AuthAltTypes=auth\/jwt$/d; /^AuthAltParameters=jwt_key=\/var\/lib\/slurm-web\/jwt.key$/d' /etc/slurm/slurmdbd.conf
sudo sed -i '/^AuthType=auth\/munge$/a AuthAltTypes=auth/jwt\nAuthAltParameters=jwt_key=/var/lib/slurm-web/jwt.key' /etc/slurm/slurmdbd.conf
sudo setfacl -m u:slurm:rx /var/lib/slurm-web
sudo setfacl -m u:slurm:r /var/lib/slurm-web/jwt.key
sudo systemctl restart slurmdbd
sleep 3
sudo sacctmgr -i add cluster "$CLUSTER_NAME" || true
sudo sacctmgr -i add account default Description="Default Slurm Account" Organization="$LDAP_ORG" || true
sudo sacctmgr -i add user "$SLURM_ADMIN" account=default || true
sudo sacctmgr -i modify user where name="$SLURM_ADMIN" set AdminLevel=Admin DefaultAccount=default
sudo sacctmgr -i add qos normal Description="Normal user jobs: 2 CPU, 1G RAM, 2h, one job" Priority=100 || true
sudo sacctmgr -i modify qos normal set MaxTRESPerUser=cpu=2,mem=1G MaxWall=02:00:00 MaxJobsPerUser=1
sudo sacctmgr -i add qos high Description="High-priority jobs" Priority=500 || true
sudo sacctmgr -i add qos superadmin Description="Unrestricted Super Admin jobs" Priority=1000 || true
sudo sacctmgr -i modify user where name="$SLURM_ADMIN" account=default set QOS+=normal,high,superadmin DefaultQOS=superadmin
sudo systemctl restart slurmctld slurmd slurmrestd slurm-web-agent slurm-web-gateway
sleep 2
sudo scontrol create reservation ReservationName=training-reservation StartTime=now+1day Duration=01:00:00 Users="$SLURM_ADMIN" Nodes="$HOST_NAME" 2>/dev/null || print_warning "Reservation already exists or could not be created"
echo ""
print_success "Dynamic controller setup verified. QoS: normal, high | Account: default"
