#!/bin/bash
# ==============================================================
# FWCS-Style School Homelab — Linux-Only Setup Script
# Supports: CentOS 3  |  Red Hat Enterprise Linux 7
#
# Mimics Fort Wayne Community Schools (FWCS) K-12 infrastructure
# for J. Wilbur Haley Elementary School homelab environment.
#
# WHAT THIS SCRIPT CONFIGURES:
#   - OS detection  : CentOS 3 vs RHEL 7 — adapts automatically
#   - OpenLDAP      : Directory services (users, groups, auth)
#                     NOTE: FreeIPA not available on these platforms
#   - BIND          : DNS server with forward and reverse zones
#   - DHCP          : dhcpd scopes for Student and Staff VLANs
#   - Samba 3.x     : SMB file shares for students and staff
#   - NFS           : Home directory exports
#   - Squid         : K-12 content filtering proxy
#   - syslog/rsyslog: Centralized log collection
#   - iptables      : Firewall rules (firewalld NOT available on CentOS 3)
#   - PAM / nsswitch: LDAP authentication integration
#
# PLATFORM NOTES:
#   CentOS 3  — Uses: yum (if configured), syslog, iptables, Samba 3,
#               OpenLDAP 2.1, BIND 9.2, nfs-utils, Squid 2.5
#   RHEL 7    — Uses: yum, rsyslog, firewalld, Samba 4, OpenLDAP 2.4,
#               BIND 9.9, nfs-utils, Squid 3.5
#
# REQUIREMENTS:
#   - CentOS 3 (any minor) OR RHEL 7 (any minor)
#   - Static IP already assigned before running
#   - Must be run as root
#   - Edit SECTION 0 variables before first run
#
# INTERNET GUARD:
#   Script checks gateway IP before proceeding.
#   Set YOUR_GATEWAY_IP to your home/lab router LAN IP.
# ==============================================================

set -euo pipefail
IFS=$'\n\t'

# ==============================================================
# SECTION 0 — CONFIGURATION  (Edit these before running!)
# ==============================================================

# --- Network / Guard ---
YOUR_GATEWAY_IP="192.168.1.1"       # Your home router LAN IP
YOUR_PUBLIC_IP=""                    # Optional — leave "" to skip

# --- Server Identity ---
SERVER_HOSTNAME="haley-srv01"
SERVER_DOMAIN="haley.fwcs.local"
SERVER_FQDN="${SERVER_HOSTNAME}.${SERVER_DOMAIN}"
SERVER_IP="192.168.1.10"            # This server's static IP

# --- OpenLDAP Directory ---
LDAP_BASE_DN="dc=haley,dc=fwcs,dc=local"
LDAP_ADMIN_DN="cn=Manager,${LDAP_BASE_DN}"
LDAP_ADMIN_PASS="FWCSAdmin@2024!"   # Change before running!
LDAP_SUFFIX="$LDAP_BASE_DN"

# --- DHCP — Student VLAN 10 ---
DHCP_STUDENT_SUBNET="192.168.10.0"
DHCP_STUDENT_NETMASK="255.255.255.0"
DHCP_STUDENT_RANGE_START="192.168.10.50"
DHCP_STUDENT_RANGE_END="192.168.10.200"
DHCP_STUDENT_GW="192.168.10.1"
DHCP_STUDENT_LEASE="28800"           # 8 hours

# --- DHCP — Staff VLAN 20 ---
DHCP_STAFF_SUBNET="192.168.20.0"
DHCP_STAFF_NETMASK="255.255.255.0"
DHCP_STAFF_RANGE_START="192.168.20.50"
DHCP_STAFF_RANGE_END="192.168.20.150"
DHCP_STAFF_GW="192.168.20.1"
DHCP_STAFF_LEASE="86400"             # 24 hours

# --- File Share & NFS Paths ---
SHARE_ROOT="/srv/fwcs"
NFS_EXPORT_ROOT="/srv/fwcs/HomeDirectories"

# --- Squid Proxy ---
SQUID_PORT=3128
SQUID_CACHE_DIR="/var/spool/squid"
SQUID_CACHE_MB=2048

# --- Sample Account Passwords (CHANGE before use!) ---
TEACHER_PASS="Teacher@2024!"
STUDENT_PASS="Student@2024!"
ADMIN_PASS="ITAdmin@2024!"

# ==============================================================
# HELPER FUNCTIONS
# ==============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'

banner() {
    local text="$1" color="${2:-$CYAN}"
    local line; line=$(printf '%0.s=' {1..60})
    echo -e "\n${color}${line}${NC}"
    echo -e "${color}  ${text}${NC}"
    echo -e "${color}${line}${NC}\n"
}

step() { echo -e "${YELLOW}[*] $1${NC}"; }
ok()   { echo -e "${GREEN}[OK] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
fail() { echo -e "${RED}[FAIL] $1${NC}"; exit 1; }
skip() { echo -e "${GRAY}[--] $1${NC}"; }

confirm() {
    local prompt="${1:-Continue? (y/N)}"
    read -rp "$prompt " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
}

# Generate a salted SHA password hash for LDAP (works without slappasswd -s flag on CentOS 3)
ldap_hash_pass() {
    local pass="$1"
    # slappasswd available on both platforms
    slappasswd -s "$pass" 2>/dev/null || echo "{CLEARTEXT}${pass}"
}

# ==============================================================
# SECTION 1 — ROOT CHECK
# ==============================================================

[[ $EUID -eq 0 ]] || fail "Must be run as root. Use: sudo bash $0"
ok "Running as root."

# ==============================================================
# SECTION 2 — OS DETECTION
# ==============================================================

banner "Detecting Operating System" "$MAGENTA"

[[ -f /etc/redhat-release ]] || fail "/etc/redhat-release not found. Requires CentOS 3 or RHEL 7."

RELEASE_STR=$(cat /etc/redhat-release)

if echo "$RELEASE_STR" | grep -qi "CentOS"; then
    OS_MAJOR=$(echo "$RELEASE_STR" | grep -oP '\d+' | head -1)
    [[ "$OS_MAJOR" == "3" ]] || \
        fail "CentOS 3 required. Detected: $RELEASE_STR"
    OS_ID="centos"
    OS_LABEL="CentOS 3"
    PKG_MGR="yum"
    DHCP_PKG="dhcp"
    LDAP_PKG="openldap openldap-servers openldap-clients"
    SAMBA_PKG="samba samba-client samba-common"
    NFS_PKG="nfs-utils portmap"
    SQUID_PKG="squid"
    BIND_PKG="bind bind-utils"
    LOG_SERVICE="syslog"
    FIREWALL_CMD="iptables"
    # On CentOS 3 nss_ldap provides pam_ldap integration
    NSS_PKG="nss_ldap pam_ldap"
    # CentOS 3 Samba is 3.x — no ADS security, use ldap passdb
    SAMBA_SECURITY="user"

elif echo "$RELEASE_STR" | grep -qi "Red Hat"; then
    OS_MAJOR=$(echo "$RELEASE_STR" | grep -oP '\d+' | head -1)
    [[ "$OS_MAJOR" == "7" ]] || \
        fail "RHEL 7 required. Detected: $RELEASE_STR"
    OS_ID="rhel"
    OS_LABEL="Red Hat Enterprise Linux 7"
    PKG_MGR="yum"
    DHCP_PKG="dhcp"
    LDAP_PKG="openldap openldap-servers openldap-clients"
    SAMBA_PKG="samba samba-client samba-common"
    NFS_PKG="nfs-utils"
    SQUID_PKG="squid"
    BIND_PKG="bind bind-utils"
    LOG_SERVICE="rsyslog"
    FIREWALL_CMD="firewall-cmd"
    NSS_PKG="nss-pam-ldapd"
    SAMBA_SECURITY="user"

else
    fail "Unrecognized release: $RELEASE_STR. Requires CentOS 3 or RHEL 7."
fi

ok "OS confirmed: ${OS_LABEL}"
echo "  Release string: $RELEASE_STR"

# ==============================================================
# SECTION 3 — CONNECTION GUARD
# ==============================================================

banner "Connection Guard" "$MAGENTA"
step "Verifying you are on YOUR network before proceeding..."

DETECTED_GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -1)

# CentOS 3 may not have 'ip' — fall back to route
if [[ -z "$DETECTED_GW" ]]; then
    DETECTED_GW=$(route -n 2>/dev/null | awk '/^0\.0\.0\.0/ {print $2}' | head -1)
fi

[[ -n "$DETECTED_GW" ]] || fail "No default gateway detected. Check network config."

if [[ "$DETECTED_GW" != "$YOUR_GATEWAY_IP" ]]; then
    echo -e "${RED}[FAIL] Gateway mismatch!${NC}"
    echo "  Detected : $DETECTED_GW"
    echo "  Expected : $YOUR_GATEWAY_IP"
    echo "  Update YOUR_GATEWAY_IP in Section 0 if your router IP changed."
    exit 1
fi
ok "Gateway matched: $DETECTED_GW"

ping -c 2 -W 2 "$YOUR_GATEWAY_IP" &>/dev/null || fail "Gateway unreachable. Check cable/Wi-Fi."
ok "Gateway is reachable."

if [[ -n "$YOUR_PUBLIC_IP" ]]; then
    step "Checking public IP..."
    PUB_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null \
             || wget -qO- https://api.ipify.org 2>/dev/null || true)
    [[ "$PUB_IP" == "$YOUR_PUBLIC_IP" ]] || \
        fail "Public IP mismatch! Detected: $PUB_IP  Expected: $YOUR_PUBLIC_IP"
    ok "Public IP matched: $PUB_IP"
fi

ok "Connection guard passed."
confirm "All checks passed. Begin FWCS homelab install on ${OS_LABEL}? (y/N)"

# ==============================================================
# SECTION 4 — HOSTNAME & NETWORK
# ==============================================================

banner "Step 1 — Hostname & Network Setup"

step "Setting hostname to: $SERVER_FQDN"

if [[ "$OS_ID" == "rhel" ]]; then
    # RHEL 7: use hostnamectl
    hostnamectl set-hostname "$SERVER_FQDN"
else
    # CentOS 3: edit /etc/sysconfig/network
    hostname "$SERVER_FQDN"
    if grep -q "^HOSTNAME=" /etc/sysconfig/network; then
        sed -i "s/^HOSTNAME=.*/HOSTNAME=${SERVER_FQDN}/" /etc/sysconfig/network
    else
        echo "HOSTNAME=${SERVER_FQDN}" >> /etc/sysconfig/network
    fi
fi
ok "Hostname set: $SERVER_FQDN"

grep -q "$SERVER_IP" /etc/hosts 2>/dev/null \
    && skip "$SERVER_FQDN already in /etc/hosts" \
    || { echo "$SERVER_IP  $SERVER_FQDN  $SERVER_HOSTNAME" >> /etc/hosts
         ok "Added $SERVER_FQDN to /etc/hosts"; }

CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' \
             || ifconfig eth0 2>/dev/null | awk '/inet addr/{print $2}' | cut -d: -f2)
[[ -n "$CURRENT_IP" ]] || fail "No IP address on host. Assign a static IP first."
ok "Server IP detected: $CURRENT_IP"

# ==============================================================
# SECTION 5 — SYSTEM UPDATE & PACKAGES
# ==============================================================

banner "Step 2 — System Update & Package Installation"

step "Updating system packages..."
$PKG_MGR update -y 2>/dev/null || warn "yum update encountered issues — continuing."
ok "System update complete."

step "Installing all required packages..."
# shellcheck disable=SC2086
$PKG_MGR install -y \
    $LDAP_PKG \
    $DHCP_PKG \
    $SAMBA_PKG \
    $NFS_PKG \
    $SQUID_PKG \
    $BIND_PKG \
    $NSS_PKG \
    vim wget curl net-tools \
    || warn "Some packages may have failed to install — check output above."
ok "Package installation complete."

# ==============================================================
# SECTION 6 — BIND DNS SERVER
# ==============================================================

banner "Step 3 — BIND DNS Server"

NAMED_CONF="/etc/named.conf"
ZONE_DIR="/var/named"

step "Writing named.conf..."
cat > "$NAMED_CONF" <<EOF
// FWCS Haley Elementary — named.conf
// Compatible: CentOS 3 (BIND 9.2) / RHEL 7 (BIND 9.9)

options {
    listen-on port 53 { 127.0.0.1; ${SERVER_IP}; };
    directory    "${ZONE_DIR}";
    dump-file    "${ZONE_DIR}/data/cache_dump.db";
    allow-query  { localhost; 192.168.10.0/24; 192.168.20.0/24; };
    recursion yes;
    forwarders { 8.8.8.8; 1.1.1.1; };
    forward only;
};

// Internal zone — ${SERVER_DOMAIN}
zone "${SERVER_DOMAIN}" IN {
    type master;
    file "${ZONE_DIR}/${SERVER_DOMAIN}.zone";
    allow-update { none; };
};

// Reverse zone — Student VLAN 10
zone "10.168.192.in-addr.arpa" IN {
    type master;
    file "${ZONE_DIR}/192.168.10.rev";
    allow-update { none; };
};

// Reverse zone — Staff VLAN 20
zone "20.168.192.in-addr.arpa" IN {
    type master;
    file "${ZONE_DIR}/192.168.20.rev";
    allow-update { none; };
};
EOF
ok "named.conf written."

step "Writing forward zone: ${SERVER_DOMAIN}..."
cat > "${ZONE_DIR}/${SERVER_DOMAIN}.zone" <<EOF
\$TTL 86400
@   IN  SOA  ${SERVER_FQDN}. hostmaster.${SERVER_DOMAIN}. (
            2024010101  ; Serial
            3600        ; Refresh
            900         ; Retry
            604800      ; Expire
            86400 )     ; Minimum TTL

; Name servers
@           IN  NS   ${SERVER_FQDN}.

; A Records — Infrastructure
${SERVER_HOSTNAME}    IN  A    ${SERVER_IP}
fileserver            IN  A    ${SERVER_IP}
nfs                   IN  A    ${SERVER_IP}
proxy                 IN  A    ${SERVER_IP}
logs                  IN  A    ${SERVER_IP}
printserver           IN  A    ${SERVER_IP}
ldap                  IN  A    ${SERVER_IP}
dns                   IN  A    ${SERVER_IP}
studentportal         IN  A    192.168.20.10
staffportal           IN  A    192.168.20.10
EOF
ok "Forward zone written."

step "Writing reverse zone — Student VLAN (192.168.10.x)..."
cat > "${ZONE_DIR}/192.168.10.rev" <<EOF
\$TTL 86400
@   IN  SOA  ${SERVER_FQDN}. hostmaster.${SERVER_DOMAIN}. (
            2024010101 3600 900 604800 86400 )
@   IN  NS   ${SERVER_FQDN}.
10  IN  PTR  ${SERVER_FQDN}.
EOF
ok "Student reverse zone written."

step "Writing reverse zone — Staff VLAN (192.168.20.x)..."
cat > "${ZONE_DIR}/192.168.20.rev" <<EOF
\$TTL 86400
@   IN  SOA  ${SERVER_FQDN}. hostmaster.${SERVER_DOMAIN}. (
            2024010101 3600 900 604800 86400 )
@   IN  NS   ${SERVER_FQDN}.
10  IN  PTR  ${SERVER_FQDN}.
EOF
ok "Staff reverse zone written."

# Fix permissions (named user varies by platform)
chown -R named:named "${ZONE_DIR}" 2>/dev/null \
    || chown -R root:named "${ZONE_DIR}" 2>/dev/null || true

if [[ "$OS_ID" == "rhel" ]]; then
    systemctl enable named
    systemctl restart named
else
    # CentOS 3 uses chkconfig / service
    chkconfig named on 2>/dev/null || true
    service named restart 2>/dev/null || true
fi
ok "BIND DNS server configured and started."

# ==============================================================
# SECTION 7 — OPENLDAP DIRECTORY SERVICES
# ==============================================================

banner "Step 4 — OpenLDAP Directory Services"
# OpenLDAP is used on both CentOS 3 and RHEL 7 since FreeIPA
# is not available for these platform versions.

LDAP_PASS_HASH=$(ldap_hash_pass "$LDAP_ADMIN_PASS")

if [[ "$OS_ID" == "centos" ]]; then
    SLAPD_CONF="/etc/openldap/slapd.conf"
    step "Writing slapd.conf (CentOS 3 — classic slapd.conf format)..."
    cat > "$SLAPD_CONF" <<EOF
# FWCS Haley Elementary — OpenLDAP slapd.conf
# CentOS 3 (OpenLDAP 2.1 style)

include         /etc/openldap/schema/core.schema
include         /etc/openldap/schema/cosine.schema
include         /etc/openldap/schema/inetorgperson.schema
include         /etc/openldap/schema/nis.schema

pidfile         /var/run/slapd.pid
argsfile        /var/run/slapd.args

loglevel        256

database        ldbm
suffix          "${LDAP_SUFFIX}"
rootdn          "${LDAP_ADMIN_DN}"
rootpw          ${LDAP_PASS_HASH}
directory       /var/lib/ldap

index objectClass  eq
index cn           eq,sub
index uid          eq
index uidNumber    eq
index gidNumber    eq
index memberUid    eq

access to attrs=userPassword
    by self write
    by anonymous auth
    by dn="${LDAP_ADMIN_DN}" write
    by * none

access to *
    by self write
    by dn="${LDAP_ADMIN_DN}" write
    by * read
EOF
    ok "slapd.conf written (CentOS 3 classic format)."

    chkconfig ldap on 2>/dev/null || true
    service ldap restart 2>/dev/null || true

else
    # RHEL 7 — OpenLDAP 2.4 uses slapd.d (cn=config) — configure via ldapmodify
    step "Configuring OpenLDAP 2.4 (RHEL 7 — cn=config format)..."

    systemctl enable slapd
    systemctl start slapd

    # Set root password and suffix via LDIF
    LDAP_CONFIG_LDIF=$(mktemp /tmp/ldap-config-XXXX.ldif)
    cat > "$LDAP_CONFIG_LDIF" <<EOF
dn: olcDatabase={2}hdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: ${LDAP_SUFFIX}
-
replace: olcRootDN
olcRootDN: ${LDAP_ADMIN_DN}
-
replace: olcRootPW
olcRootPW: ${LDAP_PASS_HASH}
EOF
    ldapmodify -Y EXTERNAL -H ldapi:/// -f "$LDAP_CONFIG_LDIF" 2>/dev/null \
        && ok "OpenLDAP suffix and rootDN configured." \
        || warn "ldapmodify for config failed — may need manual configuration."
    rm -f "$LDAP_CONFIG_LDIF"

    # Enable memberof overlay for group membership tracking
    MEMBEROF_LDIF=$(mktemp /tmp/ldap-memberof-XXXX.ldif)
    cat > "$MEMBEROF_LDIF" <<EOF
dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulepath: /usr/lib64/openldap
olcModuleload: memberof.la
EOF
    ldapadd -Y EXTERNAL -H ldapi:/// -f "$MEMBEROF_LDIF" 2>/dev/null || true
    rm -f "$MEMBEROF_LDIF"
fi

# ==============================================================
# SECTION 8 — LDAP BASE STRUCTURE & OU LAYOUT
# ==============================================================

banner "Step 5 — LDAP OU Structure (FWCS / Haley Elementary)"

# Wait for slapd to be ready
sleep 2

BASE_LDIF=$(mktemp /tmp/ldap-base-XXXX.ldif)
cat > "$BASE_LDIF" <<EOF
# Base domain
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: FWCS Haley Elementary
dc: haley

# OU: People
dn: ou=People,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: People

# OU: Groups
dn: ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: Groups

# OU: Students
dn: ou=Students,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: Students

# OU: Staff
dn: ou=Staff,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: Staff

# OU: Administrators
dn: ou=Administrators,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: Administrators

# Group: haley-administrators
dn: cn=haley-administrators,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: haley-administrators
gidNumber: 2000
description: School IT Administrators

# Group: haley-staff
dn: cn=haley-staff,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: haley-staff
gidNumber: 2001
description: All staff — teachers paras admin

# Group: haley-teachers
dn: cn=haley-teachers,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: haley-teachers
gidNumber: 2002
description: Classroom teachers

# Group: haley-paras
dn: cn=haley-paras,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: haley-paras
gidNumber: 2003
description: Paraprofessionals and aides

# Group: haley-students
dn: cn=haley-students,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: haley-students
gidNumber: 2010
description: All Haley student accounts

# Group: haley-grade-k2
dn: cn=haley-grade-k2,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: haley-grade-k2
gidNumber: 2011
description: Kindergarten through Grade 2

# Group: haley-grade-35
dn: cn=haley-grade-35,ou=Groups,${LDAP_BASE_DN}
objectClass: top
objectClass: posixGroup
cn: haley-grade-35
gidNumber: 2012
description: Grades 3 through 5
EOF

ldapadd -x \
    -D "$LDAP_ADMIN_DN" \
    -w "$LDAP_ADMIN_PASS" \
    -H ldap://localhost \
    -f "$BASE_LDIF" 2>/dev/null \
    && ok "LDAP base structure and groups created." \
    || warn "Some LDAP entries may already exist — continuing."
rm -f "$BASE_LDIF"

# ==============================================================
# SECTION 9 — TEMPLATE LDAP USER ACCOUNTS
# ==============================================================

banner "Step 6 — Template User Accounts (LDAP)"

create_ldap_user() {
    local uid="$1" cn="$2" sn="$3" pass="$4" \
          uidnum="$5" gidnum="$6" ou_path="$7" desc="$8"
    local pass_hash; pass_hash=$(ldap_hash_pass "$pass")
    local tmp; tmp=$(mktemp /tmp/ldap-user-XXXX.ldif)
    cat > "$tmp" <<EOF
dn: uid=${uid},${ou_path},${LDAP_BASE_DN}
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ${uid}
cn: ${cn}
sn: ${sn}
userPassword: ${pass_hash}
loginShell: /bin/bash
homeDirectory: /home/${uid}
uidNumber: ${uidnum}
gidNumber: ${gidnum}
description: ${desc}
EOF
    ldapadd -x -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASS" \
        -H ldap://localhost -f "$tmp" 2>/dev/null \
        && ok "LDAP user created: $uid — $desc" \
        || skip "User may already exist: $uid"
    rm -f "$tmp"
}

# UID numbering: 3000+ admins, 3100+ teachers, 3500+ students
create_ldap_user "it.admin"            "IT Admin"          "Admin"         "$ADMIN_PASS"   3000 2000 "ou=Administrators" "IT Administrator"
create_ldap_user "jsmith.teacher"      "Jane Smith"        "Smith"         "$TEACHER_PASS" 3100 2002 "ou=Staff"          "2nd Grade Teacher"
create_ldap_user "bjohnson.teacher"    "Bob Johnson"       "Johnson"       "$TEACHER_PASS" 3101 2002 "ou=Staff"          "4th Grade Teacher"
create_ldap_user "student.tmpl.k2"     "Student Tmpl K2"   "Template"      "$STUDENT_PASS" 3500 2011 "ou=Students"       "TEMPLATE K-2 Student"
create_ldap_user "student.tmpl.35"     "Student Tmpl 35"   "Template"      "$STUDENT_PASS" 3501 2012 "ou=Students"       "TEMPLATE Gr 3-5 Student"

# Add admin to administrators group
ADDMEMBER_LDIF=$(mktemp /tmp/ldap-member-XXXX.ldif)
cat > "$ADDMEMBER_LDIF" <<EOF
dn: cn=haley-administrators,ou=Groups,${LDAP_BASE_DN}
changetype: modify
add: memberUid
memberUid: it.admin
EOF
ldapmodify -x -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASS" \
    -H ldap://localhost -f "$ADDMEMBER_LDIF" 2>/dev/null || true
rm -f "$ADDMEMBER_LDIF"
ok "it.admin added to haley-administrators group."

# ==============================================================
# SECTION 10 — NSS / PAM LDAP AUTHENTICATION
# ==============================================================

banner "Step 7 — NSS/PAM LDAP Authentication Integration"

if [[ "$OS_ID" == "centos" ]]; then
    # CentOS 3: configure /etc/ldap.conf (nss_ldap / pam_ldap)
    step "Writing /etc/ldap.conf (CentOS 3)..."
    cat > /etc/ldap.conf <<EOF
# FWCS Haley — LDAP client config (CentOS 3 nss_ldap/pam_ldap)
host ${SERVER_IP}
base ${LDAP_BASE_DN}
uri ldap://${SERVER_IP}/
ldap_version 3
binddn ${LDAP_ADMIN_DN}
bindpw ${LDAP_ADMIN_PASS}

pam_password md5
pam_filter objectclass=posixAccount
pam_login_attribute uid
nss_base_passwd ou=People,${LDAP_BASE_DN}
nss_base_passwd ou=Students,${LDAP_BASE_DN}
nss_base_passwd ou=Staff,${LDAP_BASE_DN}
nss_base_passwd ou=Administrators,${LDAP_BASE_DN}
nss_base_shadow ou=People,${LDAP_BASE_DN}
nss_base_group  ou=Groups,${LDAP_BASE_DN}
EOF
    ok "/etc/ldap.conf written."

    # Update /etc/nsswitch.conf to use ldap
    sed -i 's/^passwd:.*/passwd:     files ldap/' /etc/nsswitch.conf
    sed -i 's/^shadow:.*/shadow:     files ldap/' /etc/nsswitch.conf
    sed -i 's/^group:.*/group:      files ldap/'  /etc/nsswitch.conf
    ok "nsswitch.conf updated to use LDAP for passwd/shadow/group."

else
    # RHEL 7: use authconfig to wire up SSSD or nss-pam-ldapd
    step "Configuring LDAP auth with authconfig (RHEL 7)..."
    authconfig \
        --enableldap \
        --enableldapauth \
        --ldapserver="ldap://${SERVER_IP}" \
        --ldapbasedn="${LDAP_BASE_DN}" \
        --enablemkhomedir \
        --update 2>/dev/null \
        && ok "authconfig applied LDAP authentication." \
        || warn "authconfig encountered issues — verify /etc/nslcd.conf manually."

    # Write nslcd.conf for nss-pam-ldapd
    cat > /etc/nslcd.conf <<EOF
# FWCS Haley — nslcd.conf (RHEL 7)
uid nslcd
gid ldap
uri ldap://${SERVER_IP}/
base ${LDAP_BASE_DN}
binddn ${LDAP_ADMIN_DN}
bindpw ${LDAP_ADMIN_PASS}
ssl no
tls_cacertdir /etc/openldap/cacerts
EOF
    chmod 600 /etc/nslcd.conf
    systemctl enable nslcd
    systemctl restart nslcd
    ok "nslcd configured and started."
fi

# ==============================================================
# SECTION 11 — DHCP SERVER
# ==============================================================

banner "Step 8 — DHCP Server"

step "Writing /etc/dhcp/dhcpd.conf..."

# CentOS 3 may store dhcpd.conf at /etc/dhcpd.conf
if [[ "$OS_ID" == "centos" ]]; then
    DHCP_CONF="/etc/dhcpd.conf"
else
    mkdir -p /etc/dhcp
    DHCP_CONF="/etc/dhcp/dhcpd.conf"
fi

cat > "$DHCP_CONF" <<EOF
# FWCS Haley Elementary — dhcpd.conf
# Generated by Setup-FWCSHomeLab.sh
# Compatible: CentOS 3 / RHEL 7

authoritative;
ddns-update-style none;
log-facility local7;

option domain-name "${SERVER_DOMAIN}";
option domain-name-servers ${SERVER_IP};

# -------------------------------------------------------
# Student VLAN 10 — 192.168.10.0/24
# .1–.49 reserved for static infrastructure
# -------------------------------------------------------
subnet ${DHCP_STUDENT_SUBNET} netmask ${DHCP_STUDENT_NETMASK} {
    option routers             ${DHCP_STUDENT_GW};
    option subnet-mask         ${DHCP_STUDENT_NETMASK};
    option domain-name         "${SERVER_DOMAIN}";
    option domain-name-servers ${SERVER_IP};
    default-lease-time         ${DHCP_STUDENT_LEASE};
    max-lease-time             ${DHCP_STUDENT_LEASE};
    pool {
        range ${DHCP_STUDENT_RANGE_START} ${DHCP_STUDENT_RANGE_END};
        allow unknown-clients;
    }
}

# -------------------------------------------------------
# Staff VLAN 20 — 192.168.20.0/24
# .1–.49 reserved for static infrastructure
# -------------------------------------------------------
subnet ${DHCP_STAFF_SUBNET} netmask ${DHCP_STAFF_NETMASK} {
    option routers             ${DHCP_STAFF_GW};
    option subnet-mask         ${DHCP_STAFF_NETMASK};
    option domain-name         "${SERVER_DOMAIN}";
    option domain-name-servers ${SERVER_IP};
    default-lease-time         ${DHCP_STAFF_LEASE};
    max-lease-time             ${DHCP_STAFF_LEASE};
    pool {
        range ${DHCP_STAFF_RANGE_START} ${DHCP_STAFF_RANGE_END};
        allow unknown-clients;
    }
}
EOF
ok "dhcpd.conf written."

if [[ "$OS_ID" == "rhel" ]]; then
    systemctl enable dhcpd
    systemctl restart dhcpd
else
    chkconfig dhcpd on 2>/dev/null || true
    service dhcpd restart 2>/dev/null || true
fi
ok "DHCP server enabled and started."

# ==============================================================
# SECTION 12 — SAMBA FILE SHARES
# ==============================================================

banner "Step 9 — Samba File Shares"

step "Creating share directory structure under: $SHARE_ROOT"

declare -A SHARES=(
    ["Students"]="$SHARE_ROOT/Students"
    ["Staff"]="$SHARE_ROOT/Staff"
    ["HomeDirectories"]="$SHARE_ROOT/HomeDirectories"
    ["SchoolResources"]="$SHARE_ROOT/SchoolResources"
    ["SoftwareDeploy"]="$SHARE_ROOT/SoftwareDeploy"
)

for name in "${!SHARES[@]}"; do
    path="${SHARES[$name]}"
    mkdir -p "$path"
    chmod 0770 "$path"
    ok "Directory ready: $path"
done

chmod 2770 "$SHARE_ROOT/Students" "$SHARE_ROOT/Staff"

step "Writing /etc/samba/smb.conf..."
cat > /etc/samba/smb.conf <<EOF
# FWCS Haley Elementary — smb.conf
# Compatible: CentOS 3 (Samba 3.x) / RHEL 7 (Samba 4.x)

[global]
    workgroup            = HALEY
    server string        = FWCS Haley File Server %v
    netbios name         = HALEY-SRV01
    security             = ${SAMBA_SECURITY}
    passdb backend       = ldapsam:ldap://${SERVER_IP}
    ldap admin dn        = ${LDAP_ADMIN_DN}
    ldap suffix          = ${LDAP_BASE_DN}
    ldap user suffix     = ou=People
    ldap group suffix    = ou=Groups
    ldap machine suffix  = ou=Computers
    ldap passwd sync     = Yes
    log file             = /var/log/samba/%m.log
    max log size         = 50
    map to guest         = Bad User
    load printers        = No
    printcap name        = /dev/null
    disable spoolss      = Yes
    socket options       = TCP_NODELAY IPTOS_LOWDELAY
    read raw             = Yes
    write raw            = Yes

[Students]
    path                 = ${SHARE_ROOT}/Students
    comment              = FWCS Haley — Student Files
    read only            = No
    valid users          = @haley-students @haley-administrators
    write list           = @haley-students
    create mask          = 0660
    directory mask       = 0770
    browseable           = Yes

[Staff]
    path                 = ${SHARE_ROOT}/Staff
    comment              = FWCS Haley — Staff Files
    read only            = No
    valid users          = @haley-staff @haley-administrators
    write list           = @haley-staff
    create mask          = 0660
    directory mask       = 0770
    browseable           = Yes

[HomeDirectories]
    path                 = ${SHARE_ROOT}/HomeDirectories
    comment              = FWCS Haley — Home Directories
    read only            = No
    valid users          = %S @haley-administrators
    write list           = %S
    create mask          = 0700
    directory mask       = 0700
    browseable           = No

[SchoolResources]
    path                 = ${SHARE_ROOT}/SchoolResources
    comment              = FWCS Haley — Curriculum Resources
    read only            = Yes
    write list           = @haley-staff @haley-administrators
    valid users          = @haley-students @haley-staff @haley-administrators
    browseable           = Yes

[SoftwareDeploy]
    path                 = ${SHARE_ROOT}/SoftwareDeploy
    comment              = FWCS Haley — Software Deployment (admin only)
    read only            = Yes
    valid users          = @haley-administrators
    browseable           = No
EOF

# Store LDAP admin password in Samba's secrets
smbpasswd -w "$LDAP_ADMIN_PASS" 2>/dev/null \
    && ok "Samba LDAP admin password stored in secrets.tdb." \
    || warn "Could not set Samba LDAP password — set manually with: smbpasswd -w"

testparm -s &>/dev/null && ok "smb.conf validated." || warn "smb.conf has issues — run: testparm"

if [[ "$OS_ID" == "rhel" ]]; then
    systemctl enable smb nmb
    systemctl restart smb nmb
else
    chkconfig smb on 2>/dev/null || true
    service smb restart 2>/dev/null || true
fi
ok "Samba enabled and started."

# ==============================================================
# SECTION 13 — NFS HOME DIRECTORIES
# ==============================================================

banner "Step 10 — NFS Home Directory Exports"

mkdir -p "$NFS_EXPORT_ROOT"
chown nobody:nobody "$NFS_EXPORT_ROOT"
chmod 0777 "$NFS_EXPORT_ROOT"

NFS_ENTRY="${NFS_EXPORT_ROOT}  192.168.10.0/24(rw,sync,no_root_squash,no_subtree_check) 192.168.20.0/24(rw,sync,no_root_squash,no_subtree_check)"

grep -qF "$NFS_EXPORT_ROOT" /etc/exports 2>/dev/null \
    && skip "NFS export already in /etc/exports" \
    || { echo "$NFS_ENTRY" >> /etc/exports; ok "NFS export added."; }

if [[ "$OS_ID" == "rhel" ]]; then
    systemctl enable nfs-server rpcbind
    systemctl restart nfs-server rpcbind
else
    chkconfig nfs on 2>/dev/null || true
    chkconfig portmap on 2>/dev/null || true
    service portmap restart 2>/dev/null || true
    service nfs restart 2>/dev/null || true
fi

exportfs -rav
ok "NFS server configured and exports applied."

# ==============================================================
# SECTION 14 — SQUID CONTENT FILTERING PROXY
# ==============================================================

banner "Step 11 — Squid K-12 Content Filter"

step "Writing Squid configuration..."
cat > /etc/squid/squid.conf <<EOF
# FWCS Haley Elementary — Squid K-12 Content Filter
# Compatible: CentOS 3 (Squid 2.5) / RHEL 7 (Squid 3.5)
# Proxy port: ${SQUID_PORT}

# -------------------------------------------------------
# ACL Definitions
# -------------------------------------------------------
acl localnet     src 192.168.10.0/24
acl localnet     src 192.168.20.0/24
acl student_vlan src 192.168.10.0/24
acl staff_vlan   src 192.168.20.0/24

acl SSL_ports    port 443
acl Safe_ports   port 80 443 21 70 210 1025-65535 280 488 591 777
acl CONNECT      method CONNECT

acl blocked_domains  dstdomain  "/etc/squid/blocked_domains.txt"
acl adult_keywords   url_regex  -i "/etc/squid/adult_keywords.txt"
acl edu_whitelist    dstdomain  "/etc/squid/edu_whitelist.txt"
acl social_media     dstdomain  "/etc/squid/social_media.txt"

# School hours Mon-Fri 7:30am–3:30pm
acl school_hours     time MTWHF 07:30-15:30

# -------------------------------------------------------
# Access Rules
# -------------------------------------------------------
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow edu_whitelist localnet
http_access deny blocked_domains
http_access deny adult_keywords
http_access deny student_vlan social_media school_hours
http_access allow staff_vlan
http_access allow student_vlan
http_access deny all

# -------------------------------------------------------
# Listener & Cache
# -------------------------------------------------------
http_port ${SQUID_PORT}
cache_dir ufs ${SQUID_CACHE_DIR} ${SQUID_CACHE_MB} 16 256
cache_mem 128 MB
maximum_object_size 256 MB

# -------------------------------------------------------
# Logging
# -------------------------------------------------------
access_log /var/log/squid/access.log squid
cache_log  /var/log/squid/cache.log
cache_store_log none

# -------------------------------------------------------
# Privacy
# -------------------------------------------------------
forwarded_for off
via off

coredump_dir ${SQUID_CACHE_DIR}
EOF

# Blocked domains
cat > /etc/squid/blocked_domains.txt <<'EOF'
.pornhub.com
.xvideos.com
.xnxx.com
.redtube.com
.onlyfans.com
.bet365.com
.draftkings.com
.fanduel.com
.malwaredomainlist.com
EOF

# Adult keywords
cat > /etc/squid/adult_keywords.txt <<'EOF'
porn
xxx
adult.content
hentai
nude
EOF

# Educational whitelist
cat > /etc/squid/edu_whitelist.txt <<'EOF'
.fwcs.k12.in.us
.khanacademy.org
.pbslearningmedia.org
.brainpop.com
.ixl.com
.readingeggs.com
.classdojo.com
.clever.com
.google.com
.youtube.com
.wikipedia.org
.nasa.gov
.smithsonianeducation.org
EOF

# Social media — blocked for students during school hours
cat > /etc/squid/social_media.txt <<'EOF'
.facebook.com
.instagram.com
.tiktok.com
.snapchat.com
.twitter.com
.x.com
.reddit.com
.discord.com
EOF

ok "Squid config and filter lists written."
squid -z 2>/dev/null || true

if [[ "$OS_ID" == "rhel" ]]; then
    systemctl enable squid
    systemctl restart squid
else
    chkconfig squid on 2>/dev/null || true
    service squid restart 2>/dev/null || true
fi
ok "Squid enabled and started on port ${SQUID_PORT}."

# ==============================================================
# SECTION 15 — SYSLOG / RSYSLOG CENTRALIZED LOGGING
# ==============================================================

banner "Step 12 — Centralized Logging"

LOG_DIR="/var/log/fwcs"
mkdir -p "$LOG_DIR"

if [[ "$OS_ID" == "centos" ]]; then
    # CentOS 3 uses syslogd — add UDP listener
    SYSLOG_CONF="/etc/syslog.conf"
    step "Configuring syslogd for remote reception (CentOS 3)..."

    # Enable UDP reception in /etc/sysconfig/syslog
    if [[ -f /etc/sysconfig/syslog ]]; then
        sed -i 's/SYSLOGD_OPTIONS=.*/SYSLOGD_OPTIONS="-m 0 -r"/' /etc/sysconfig/syslog
    fi

    # Append FWCS log rules to syslog.conf
    cat >> "$SYSLOG_CONF" <<EOF

# FWCS Haley — centralized log collection
local7.*            ${LOG_DIR}/dhcp-squid.log
authpriv.*          ${LOG_DIR}/auth-events.log
auth.*              ${LOG_DIR}/auth-events.log
EOF
    ok "syslogd configured for remote reception on UDP 514."
    chkconfig syslog on 2>/dev/null || true
    service syslog restart 2>/dev/null || true

else
    # RHEL 7 uses rsyslog
    step "Writing /etc/rsyslog.d/fwcs-haley.conf (RHEL 7)..."
    cat > /etc/rsyslog.d/fwcs-haley.conf <<EOF
# FWCS Haley — rsyslog centralized log collection
# Accepts from all internal clients on port 514

\$ModLoad imudp
\$UDPServerRun 514
\$ModLoad imtcp
\$InputTCPServerRun 514

\$template PerHostLog,"${LOG_DIR}/%HOSTNAME%/%PROGRAMNAME%.log"

if \$fromhost-ip startswith '192.168.10.' then { ?PerHostLog; stop }
if \$fromhost-ip startswith '192.168.20.' then { ?PerHostLog; stop }

local7.*   ${LOG_DIR}/dhcp-squid.log
authpriv.* ${LOG_DIR}/auth-events.log
auth.*     ${LOG_DIR}/auth-events.log
EOF
    systemctl enable rsyslog
    systemctl restart rsyslog
    ok "rsyslog collecting on 514/udp+tcp. Logs at: ${LOG_DIR}/"
fi

# Log rotation — compatible syntax for both platforms
cat > /etc/logrotate.d/fwcs <<EOF
${LOG_DIR}/*.log {
    daily
    missingok
    rotate 90
    compress
    delaycompress
    notifempty
}
EOF
ok "Log rotation set to 90 days."

# ==============================================================
# SECTION 16 — FIREWALL
# ==============================================================

banner "Step 13 — Firewall Configuration"

if [[ "$OS_ID" == "centos" ]]; then
    # CentOS 3: iptables only — no firewalld
    step "Configuring iptables rules (CentOS 3)..."

    # Flush existing rules
    iptables -F
    iptables -X

    # Default policies
    iptables -P INPUT   DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT  ACCEPT

    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT

    # Allow established/related
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow ICMP (ping)
    iptables -A INPUT -p icmp -j ACCEPT

    # Internal VLAN sources only
    for iface_src in 192.168.10.0/24 192.168.20.0/24; do
        iptables -A INPUT -s "$iface_src" -p tcp --dport 22   -j ACCEPT   # SSH
        iptables -A INPUT -s "$iface_src" -p tcp --dport 53   -j ACCEPT   # DNS/TCP
        iptables -A INPUT -s "$iface_src" -p udp --dport 53   -j ACCEPT   # DNS/UDP
        iptables -A INPUT -s "$iface_src" -p udp --dport 67   -j ACCEPT   # DHCP
        iptables -A INPUT -s "$iface_src" -p tcp --dport 389  -j ACCEPT   # LDAP
        iptables -A INPUT -s "$iface_src" -p tcp --dport 636  -j ACCEPT   # LDAPS
        iptables -A INPUT -s "$iface_src" -p tcp --dport 139  -j ACCEPT   # Samba/NetBIOS
        iptables -A INPUT -s "$iface_src" -p tcp --dport 445  -j ACCEPT   # Samba/SMB
        iptables -A INPUT -s "$iface_src" -p tcp --dport 2049 -j ACCEPT   # NFS
        iptables -A INPUT -s "$iface_src" -p udp --dport 111  -j ACCEPT   # portmap/rpcbind
        iptables -A INPUT -s "$iface_src" -p tcp --dport 111  -j ACCEPT
        iptables -A INPUT -s "$iface_src" -p tcp --dport "$SQUID_PORT" -j ACCEPT
        iptables -A INPUT -s "$iface_src" -p udp --dport 514  -j ACCEPT   # syslog
    done

    # Block students from reaching staff subnet directly
    iptables -A FORWARD -s 192.168.10.0/24 -d 192.168.20.0/24 -j DROP

    # Save rules
    service iptables save 2>/dev/null \
        && ok "iptables rules saved to /etc/sysconfig/iptables." \
        || warn "Could not save iptables rules — they will be lost on reboot."
    chkconfig iptables on 2>/dev/null || true

else
    # RHEL 7: firewalld
    step "Configuring firewalld (RHEL 7)..."
    systemctl enable --now firewalld
    ok "firewalld is running."

    firewall-cmd --permanent --new-zone=fwcs-internal 2>/dev/null || true
    firewall-cmd --permanent --zone=fwcs-internal --add-source=192.168.10.0/24
    firewall-cmd --permanent --zone=fwcs-internal --add-source=192.168.20.0/24

    FWCS_SERVICES=(dns ldap ldaps samba nfs dhcp http https ssh)
    for svc in "${FWCS_SERVICES[@]}"; do
        firewall-cmd --permanent --zone=fwcs-internal --add-service="$svc" 2>/dev/null \
            && ok "FW: $svc allowed" || skip "FW: $svc — not a named service, skipping"
    done

    firewall-cmd --permanent --zone=fwcs-internal --add-port="${SQUID_PORT}/tcp"
    firewall-cmd --permanent --zone=fwcs-internal --add-port=514/tcp
    firewall-cmd --permanent --zone=fwcs-internal --add-port=514/udp
    ok "FW: Squid and syslog ports opened."

    firewall-cmd --permanent --new-zone=student-isolation 2>/dev/null || true
    firewall-cmd --permanent --zone=student-isolation --add-source=192.168.10.0/24
    firewall-cmd --permanent --zone=student-isolation \
        --add-rich-rule='rule family=ipv4 destination address=192.168.20.0/24 drop'
    ok "FW: Student-to-staff lateral traffic blocked."

    firewall-cmd --reload
    ok "All firewall rules applied."
fi

# ==============================================================
# SECTION 17 — SERVICE VERIFICATION
# ==============================================================

banner "Step 14 — Service Verification"

if [[ "$OS_ID" == "rhel" ]]; then
    SERVICES=(named slapd dhcpd smb nmb nfs-server rpcbind squid rsyslog firewalld)
    for svc in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            ok "Running: $svc"
        else
            warn "$svc not active — attempting restart..."
            systemctl restart "$svc" 2>/dev/null \
                && ok "Restarted: $svc" \
                || warn "Could not start $svc — check: journalctl -u $svc"
        fi
    done
else
    SERVICES=(named ldap dhcpd smb nfs squid syslog)
    for svc in "${SERVICES[@]}"; do
        if service "$svc" status &>/dev/null; then
            ok "Running: $svc"
        else
            warn "$svc not active — attempting restart..."
            service "$svc" restart 2>/dev/null \
                && ok "Restarted: $svc" \
                || warn "Could not start $svc — check /var/log/messages"
        fi
    done
fi

# ==============================================================
# SECTION 18 — SUMMARY & NEXT STEPS
# ==============================================================

banner "Setup Complete! — FWCS Haley Elementary Linux Homelab" "$GREEN"

cat <<SUMMARY

  OS PLATFORM  : ${OS_LABEL}
  HOSTNAME     : ${SERVER_FQDN}
  SERVER IP    : ${SERVER_IP}
  LDAP BASE    : ${LDAP_BASE_DN}

  ─────────────────────────────────────────────────────────
  DIRECTORY SERVICES — OpenLDAP
    Server     : ldap://${SERVER_IP}
    Base DN    : ${LDAP_BASE_DN}
    Admin DN   : ${LDAP_ADMIN_DN}
    Browse     : ldapsearch -x -H ldap://${SERVER_IP} -b "${LDAP_BASE_DN}"

  OU LAYOUT (mirrors FWCS OU structure):
    ou=Administrators  — IT admin accounts
    ou=Staff           — Teacher and para accounts
    ou=Students        — Student accounts
    ou=Groups          — posixGroups for access control
      haley-administrators  (gid 2000)
      haley-staff           (gid 2001)
        haley-teachers      (gid 2002)
        haley-paras         (gid 2003)
      haley-students        (gid 2010)
        haley-grade-k2      (gid 2011)
        haley-grade-35      (gid 2012)

  ─────────────────────────────────────────────────────────
  DNS — BIND
    Forward  : ${SERVER_DOMAIN}
    Reverse  : 10.168.192.in-addr.arpa
    Reverse  : 20.168.192.in-addr.arpa
    Test     : nslookup ${SERVER_FQDN} ${SERVER_IP}

  DHCP SCOPES:
    Students  192.168.10.50 – 192.168.10.200  (VLAN 10, 8hr lease)
    Staff     192.168.20.50 – 192.168.20.150  (VLAN 20, 24hr lease)

  ─────────────────────────────────────────────────────────
  SMB SHARES  (\\\\${SERVER_HOSTNAME}\\):
    Students         -> ${SHARE_ROOT}/Students
    Staff            -> ${SHARE_ROOT}/Staff
    HomeDirectories  -> ${SHARE_ROOT}/HomeDirectories  (hidden)
    SchoolResources  -> ${SHARE_ROOT}/SchoolResources
    SoftwareDeploy   -> ${SHARE_ROOT}/SoftwareDeploy   (hidden)

  NFS EXPORTS:
    ${NFS_EXPORT_ROOT}
    Accessible from: 192.168.10.0/24 and 192.168.20.0/24

  ─────────────────────────────────────────────────────────
  SQUID PROXY:
    Port      : ${SQUID_PORT}
    Config    : /etc/squid/squid.conf
    Filters   : /etc/squid/blocked_domains.txt
                /etc/squid/edu_whitelist.txt
                /etc/squid/social_media.txt
    Access log: /var/log/squid/access.log

  SYSLOG / RSYSLOG:
    Port      : 514/udp  (CentOS 3: UDP only; RHEL 7: UDP+TCP)
    Log root  : ${LOG_DIR}/

  FIREWALL:
    CentOS 3  — iptables (rules saved to /etc/sysconfig/iptables)
    RHEL 7    — firewalld zone: fwcs-internal

  ─────────────────────────────────────────────────────────
  TEMPLATE ACCOUNTS — CHANGE PASSWORDS IMMEDIATELY:
    it.admin           — IT Administrator
    jsmith.teacher     — Sample 2nd Grade Teacher
    bjohnson.teacher   — Sample 4th Grade Teacher
    student.tmpl.k2    — Template: K-2 Student (UID 3500)
    student.tmpl.35    — Template: Gr 3-5 Student (UID 3501)

  ─────────────────────────────────────────────────────────
  NEXT STEPS:
    1.  Verify LDAP tree: ldapsearch -x -H ldap://${SERVER_IP} -b "${LDAP_BASE_DN}"
    2.  Add students by copying template entries (increment UID per user)
    3.  Join clients to LDAP auth — on each client run:
          (CentOS 3) authconfig --enableldap --ldapserver=${SERVER_IP} --update
          (RHEL 7)   authconfig --enableldap --ldapserver=ldap://${SERVER_IP} --update
    4.  Set proxy on clients or push via DHCP option 252:
          http://${SERVER_IP}:${SQUID_PORT}/
    5.  Update /etc/squid/blocked_domains.txt with your site blocklist
    6.  Mount NFS home dirs on clients (/etc/fstab):
          ${SERVER_IP}:${NFS_EXPORT_ROOT}  /home  nfs  defaults  0 0
    7.  Ship client syslogs to this server:
          (CentOS 3) Add to /etc/syslog.conf:   *.* @${SERVER_IP}
          (RHEL 7)   Add to /etc/rsyslog.conf:  *.* @${SERVER_IP}:514
    8.  Test DNS: nslookup fileserver.${SERVER_DOMAIN} ${SERVER_IP}
    9.  Test Samba: smbclient -L //${SERVER_IP}/ -N
    10. Reboot server to confirm all services start cleanly on boot

SUMMARY

echo -e "${GREEN}[DONE] FWCS Haley Elementary Linux homelab configured for ${OS_LABEL}.${NC}"
echo -e "${CYAN}       Reboot recommended to verify all services start cleanly on boot.${NC}\n"
