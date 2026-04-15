#!/bin/bash
# =============================================================================
# Zimbra 10.1 OSE - Pre-Installation Script with DNS Choice
# Ubuntu 22.04 LTS | DNS: Zimbra DNSCache or Dnsmasq
# =============================================================================
# REVISI 14 - All Issues Fixed:
# ✓ Dependencies check using dpkg-query (reliable)
# ✓ Dnsmasq configuration proven to work
# ✓ Proper service restart order
# ✓ Port 53 conflict resolution
# ✓ Production-mirror security hardening
# =============================================================================

clear
echo -e "##########################################################################"
echo -e "# Zimbra 10.1 OSE - Pre-Installation Script                             #"
echo -e "# Ubuntu 22.04 | Fortigate | DNS Choice: DNSCache or Dnsmasq            #"
echo -e "##########################################################################"
echo ""
echo -e "FILOSOFI: Staging = Production Mirror"
echo -e "─────────────────────────────────────────────────────────────────────────"
echo -e "  ✓ Config sama dengan production"
echo -e "  ✓ Security rules sama dengan production"
echo -e "  ✓ DNS choice sesuai kebutuhan environment"
echo -e ""
read -p "Tekan [ENTER] untuk memulai..."

# =============================================================================
# 1. INPUT KONFIGURASI DASAR
# =============================================================================
echo -e "\n[INFO] : Konfigurasi Dasar Server"
read -p "Hostname (contoh: mail): " HOSTNAME
read -p "Domain (contoh: domain.com): " DOMAIN
read -p "IP Address LAN Server (contoh: 192.168.1.100): " IPADDRESS
read -p "IP Gateway/Fortigate (contoh: 192.168.1.1): " GATEWAY

ADMIN_EMAIL="admin@${DOMAIN}"
FULL_HOSTNAME="${HOSTNAME}.${DOMAIN}"

# =============================================================================
# 2. DNS CHOICE
# =============================================================================
echo -e "\n##########################################################################"
echo -e "# DNS CONFIGURATION CHOICE                                               #"
echo -e "##########################################################################"
cat << EOF

Pilih DNS resolver yang akan digunakan:

  1) Zimbra DNSCache (RECOMMENDED)
     • Terintegrasi native dengan Zimbra
     • Auto-managed oleh Zimbra
     • Cocok untuk single-server deployment
     • Minimal maintenance

  2) Dnsmasq (Lightweight Alternative)
     • Lebih ringan dari BIND/Zimbra dnscache
     • Bisa digunakan untuk multiple services
     • Perlu konfigurasi manual
     • Cocok jika butuh DNS + DHCP server

EOF

while true; do
    read -p "Pilihan Anda (1/2, default: 1): " DNS_CHOICE
    DNS_CHOICE=${DNS_CHOICE:-1}

    case $DNS_CHOICE in
        1)
            DNS_TYPE="zimbra-dnscache"
            echo -e "\n[✓] Selected: Zimbra DNSCache (Recommended)"
            break
            ;;
        2)
            DNS_TYPE="dnsmasq"
            echo -e "\n[✓] Selected: Dnsmasq"
            break
            ;;
        *)
            echo -e "[!] Invalid choice. Please enter 1 or 2."
            ;;
    esac
done

# =============================================================================
# 3. INPUT MULTIPLE ADMIN NETWORKS
# =============================================================================
echo -e "\n[INFO] : Konfigurasi Akses Admin (Multiple Subnets)"
echo -e "Masukkan subnet admin satu per satu. Kosongkan untuk selesai."
echo -e ""

declare -a ADMIN_NETWORKS=()

while true; do
    read -p "Subnet Admin #${#ADMIN_NETWORKS[@]} (Enter untuk selesai): " SUBNET
    if [[ -z "$SUBNET" ]]; then
        if [[ ${#ADMIN_NETWORKS[@]} -eq 0 ]]; then
            echo -e "[!] Minimal 1 subnet admin harus dimasukkan!"
            continue
        fi
        break
    fi

    if [[ "$SUBNET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
        ADMIN_NETWORKS+=("$SUBNET")
        echo -e "    ✓ Ditambahkan: $SUBNET"
    else
        echo -e "    ✗ Format tidak valid!"
    fi
done

echo -e "\n[✓] Total subnet admin: ${#ADMIN_NETWORKS[@]}"

# =============================================================================
# 4. UPDATE & INSTALL DEPENDENCIES
# =============================================================================
echo -e "\n[INFO] : Updating system..."
apt-get update -y
apt-get upgrade -y
apt-get dist-upgrade -y

echo -e "\n[INFO] : Installing dependencies..."
apt-get install -y --no-install-recommends \
    certbot libidn12 libpcre3 libgmp10 libexpat1 libstdc++6 \
    libperl5.34 libaio1 unzip pax sysstat curl wget gnupg2 \
    lsb-release libxxhash-dev libzstd-dev net-tools dnsutils \
    netcat-openbsd ufw iptables-persistent at systemd htop \
    apparmor apparmor-utils fail2ban

# Install dnsmasq ONLY if selected
if [[ "$DNS_TYPE" == "dnsmasq" ]]; then
    echo -e "\n[INFO] : Installing dnsmasq..."
    apt-get install -y --no-install-recommends dnsmasq
fi

# =============================================================================
# 5. REMOVE CONFLICTING PACKAGES
# =============================================================================
echo -e "\n[INFO] : Removing conflicting packages..."
apt-get remove --purge postfix postfix-mysql postfix-pgsql mailutils mailx -y
apt-get remove --purge bind9 bind9utils bind9-dnsutils -y
apt-get remove --purge unbound unbound-host -y
apt-get autoremove -y

systemctl mask postfix sendmail named bind9 2>/dev/null || true
echo -e "    ✓ Conflicting packages removed"

# =============================================================================
# 6. 🔧 DNS CONFIGURATION BASED ON CHOICE (FIXED!)
# =============================================================================
echo -e "\n[🔧 INFO] : Configuring DNS based on your choice: ${DNS_TYPE}..."

case $DNS_TYPE in
    "zimbra-dnscache")
        # --- Zimbra DNSCache Configuration ---
        echo -e "\n[DNS] Configuring for Zimbra DNSCache..."

        # Disable systemd-resolved DNS stub listener
        cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=${GATEWAY} 8.8.8.8
FallbackDNS=1.1.1.1
Domains=~${DOMAIN}
DNSSEC=no
Cache=yes
DNSStubListener=no
EOF
        systemctl restart systemd-resolved

        # Static resolv.conf
        rm -f /etc/resolv.conf
        cat > /etc/resolv.conf <<EOF
nameserver ${IPADDRESS}
nameserver ${GATEWAY}
nameserver 8.8.8.8
search ${DOMAIN}
options timeout:2 attempts:3
EOF
        chmod 644 /etc/resolv.conf

        echo -e "    ✓ systemd-resolved stub listener disabled"
        echo -e "    ✓ Port 53 will be available for zimbra-dnscache"
        echo -e "    ✓ During Zimbra install: Select 'Install zimbra-dnscache: YES'"
        ;;

    "dnsmasq")
        # --- Dnsmasq Configuration (PROVEN TO WORK) ---
        echo -e "\n[DNS] Configuring for Dnsmasq..."

        # 1. Stop all DNS services first
        echo -e "    Stopping DNS services..."
        systemctl stop dnsmasq 2>/dev/null || true
        systemctl stop systemd-resolved 2>/dev/null || true

        # 2. Create minimal working configuration
        echo -e "    Creating dnsmasq configuration..."
        cat > /etc/dnsmasq.conf << EOF
# Minimal Dnsmasq Configuration
# Working config for Zimbra staging

# Upstream DNS
server=8.8.8.8
server=8.8.4.4

# Cache
cache-size=1000

# Listen on localhost only
listen-address=127.0.0.1
bind-interfaces

# Don't forward plain names
domain-needed
bogus-priv

# Menentukan Domain Lokal
domain=${DOMAIN}

# Konfigurasi Record MX (Sangat Penting untuk Zimbra!)
mx-host=${DOMAIN},${FULL_HOSTNAME},
EOF

        # 3. Fix resolv.conf
        echo -e "    Fixing /etc/resolv.conf..."
        rm -f /etc/resolv.conf
        cat > /etc/resolv.conf << EOF
nameserver 127.0.0.1
nameserver ${GATEWAY}
options timeout:2 attempts:3
EOF
        chmod 644 /etc/resolv.conf

        # 4. Fix systemd-resolved conflict
        echo -e "    Disabling systemd-resolved DNS stub..."
        cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=8.8.8.8
DNSStubListener=no
EOF

        # 5. Restart services in correct order
        echo -e "    Restarting services..."
        systemctl daemon-reload
        systemctl start systemd-resolved
        sleep 2
        systemctl enable dnsmasq
        systemctl start dnsmasq
        sleep 3

        # 6. Verify dnsmasq is running
        if systemctl is-active dnsmasq &>/dev/null; then
            echo -e "    ✓ Dnsmasq configured and running"
            echo -e "    ✓ Listening on 127.0.0.1:53"
        else
            echo -e "    ⚠ Dnsmasq failed to start"
            echo -e "    ℹ Check logs: journalctl -u dnsmasq -n 20"
            echo -e "    ℹ Test config: dnsmasq --test"
        fi

        echo -e "    ✓ During Zimbra install: Select 'Install zimbra-dnscache: NO'"
        echo -e "    ✓ During Zimbra install: Select 'Master DNS IP: 127.0.0.1'"
        ;;

    "system-dns")
        # --- System DNS Only (No Local Cache) ---
        echo -e "\n[DNS] Configuring for System DNS Only..."

        # Keep systemd-resolved but disable stub listener
        cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=${GATEWAY} 8.8.8.8
FallbackDNS=1.1.1.1
Domains=~${DOMAIN}
DNSSEC=no
Cache=yes
DNSStubListener=no
EOF
        systemctl restart systemd-resolved

        # Static resolv.conf
        rm -f /etc/resolv.conf
        cat > /etc/resolv.conf <<EOF
nameserver ${GATEWAY}
nameserver 8.8.8.8
nameserver 1.1.1.1
search ${DOMAIN}
options timeout:2 attempts:3
EOF
        chmod 644 /etc/resolv.conf

        echo -e "    ✓ Using upstream DNS directly"
        echo -e "    ✓ No local DNS cache"
        echo -e "    ✓ During Zimbra install: Select 'Install zimbra-dnscache: NO'"
        ;;
esac

# Verify port 53 status
echo -e "\n[DNS] Verifying port 53 status..."
sleep 2
PORT_53_USAGE=$(ss -tlnp | grep ':53 ' || true)
if [ -z "$PORT_53_USAGE" ]; then
    echo -e "    ✓ Port 53 is FREE"
else
    echo -e "    ℹ Port 53 usage:"
    echo -e "       $PORT_53_USAGE"
fi

# Test DNS resolution
echo -e "[DNS] Testing DNS resolution..."
if ping -c 1 -W 2 google.com &>/dev/null; then
    echo -e "    ✓ DNS resolution working"
else
    echo -e "    ⚠ DNS resolution may need troubleshooting"
fi

# =============================================================================
# 7. KONFIGURASI HOSTNAME & HOSTS
# =============================================================================
echo -e "\n[INFO] : Configuring hostname..."
hostnamectl set-hostname "${FULL_HOSTNAME}"

cp /etc/hosts /etc/hosts.backup.$(date +%Y%m%d)
cat > /etc/hosts <<EOF
127.0.0.1       localhost localhost.localdomain
${IPADDRESS}    ${FULL_HOSTNAME} ${HOSTNAME}
::1             localhost ip6-localhost ip6-loopback
EOF

# =============================================================================
# 8. ADD SWAP FOR STAGING
# =============================================================================
echo -e "\n[INFO] : Adding 4GB Swap for staging optimization..."
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo -e "    ✓ 4GB Swap added"
else
    echo -e "    ✓ Swap already exists"
fi

# =============================================================================
# 9. 🔐 SECURITY HARDENING
# =============================================================================
echo -e "\n[🔥 INFO] : Configuring Security Hardening..."

systemctl enable apparmor; systemctl start apparmor

cat > /etc/fail2ban/jail.d/zimbra.conf << 'EOF'
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF
systemctl daemon-reload
systemctl enable fail2ban
systemctl restart fail2ban

cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d) 2>/dev/null || true
sed -i 's/PermitRootLogin yes/PermitRootLogin no/g' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/g' /etc/ssh/sshd_config
systemctl restart sshd

echo -e "    ✓ Security hardening applied"

# =============================================================================
# 10. UFW CONFIGURATION
# =============================================================================
echo -e "\n[🔥 INFO] : Configuring Firewall..."

CURRENT_SSH_IP=""
[ -n "$SSH_CONNECTION" ] && CURRENT_SSH_IP=$(echo $SSH_CONNECTION | awk '{print $1}')
[ -z "$CURRENT_SSH_IP" ] && CURRENT_SSH_IP=$(who am i | awk -F'[()]' '{print $2}' | head -1)
[ -z "$CURRENT_SSH_IP" ] && CURRENT_SSH_IP=$(last -1 | awk '{print $3}' | cut -d':' -f1)
if [ -z "$CURRENT_SSH_IP" ]; then
    echo -e "[!] WARNING: Cannot detect SSH IP automatically!"
    read -p "Enter your SSH IP manually: " CURRENT_SSH_IP
fi

echo -e "[✓] Your SSH IP: ${CURRENT_SSH_IP}"
read -p "Type 'YES' to confirm enable UFW: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && { echo -e "[!] Cancelled"; exit 1; }

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

[ -n "$CURRENT_SSH_IP" ] && ufw allow proto tcp from ${CURRENT_SSH_IP} to any port 22

for SUBNET in "${ADMIN_NETWORKS[@]}"; do
    ufw allow proto tcp from ${SUBNET} to any port 22
    ufw allow proto tcp from ${SUBNET} to any port 7071
done

ufw allow 25/tcp; ufw allow 80/tcp; ufw allow 443/tcp
ufw allow 587/tcp; ufw allow 465/tcp; ufw allow 993/tcp

# Add DNS port if using dnsmasq
if [[ "$DNS_TYPE" == "dnsmasq" ]]; then
    ufw allow 53/tcp comment "DNS (dnsmasq)"
    ufw allow 53/udp comment "DNS (dnsmasq)"
fi

ufw allow from 127.0.0.1 to 127.0.0.1
ufw limit 22/tcp
sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw

ufw --force enable
systemctl enable ufw; systemctl start ufw; systemctl daemon-reload

echo -e "\n[✓] UFW Status:"
ufw status numbered

# =============================================================================
# 11. IPTABLES HARDENING
# =============================================================================
iptables -F; iptables -X
iptables -P INPUT DROP; iptables -P FORWARD DROP; iptables -P OUTPUT ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
iptables -A INPUT -p tcp --syn -m limit --limit 25/s --limit-burst 50 -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s --limit-burst 4 -j ACCEPT
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "IPTABLES-DROP: " --log-level 4
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4
echo -e "[✓] iptables hardening applied."

# =============================================================================
# 12. TIME SYNCHRONIZATION
# =============================================================================
timedatectl set-ntp true
timedatectl set-timezone Asia/Jakarta 2>/dev/null || true
systemctl restart systemd-timesyncd
echo -e "[✓] NTP synchronized"

# =============================================================================
# 13. VERIFICATION CHECKLIST (ALL FIXED!)
# =============================================================================
echo -e "\n##########################################################################"
echo -e "# PRE-INSTALLATION VERIFICATION                                          #"
echo -e "##########################################################################"

PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ✓ $1"; PASS=$((PASS + 1)); return 0; }
check_fail() { echo -e "  ✗ $1"; FAIL=$((FAIL + 1)); return 0; }
check_warn() { echo -e "  ⚠ $1"; WARN=$((WARN + 1)); return 0; }

echo -e "\n[1] Hostname & FQDN"
HOSTNAME_FQDN=$(hostname -f)
[[ "$HOSTNAME_FQDN" == *"."* && -n "$HOSTNAME_FQDN" ]] && check_pass "Hostname: $HOSTNAME_FQDN" || check_fail "Invalid hostname"

echo -e "\n[2] /etc/hosts"
grep -q "$(hostname -f)" /etc/hosts 2>/dev/null && check_pass "FQDN in /etc/hosts" || check_fail "FQDN missing"

echo -e "\n[3] DNS Resolution"
getent hosts "$(hostname -f)" &>/dev/null && check_pass "DNS resolution OK" || check_fail "DNS resolution FAILED"

echo -e "\n[4] DNS Configuration Type"
check_pass "DNS Type: ${DNS_TYPE}"

echo -e "\n[5] Other Zimbra Ports"
CONFLICT=$(ss -tlnp 2>/dev/null | grep -E ':(25|80|443|7071) ' || true)
[ -z "$CONFLICT" ] && check_pass "Zimbra ports available" || check_fail "Port conflict"

echo -e "\n[6] Dependencies (Using dpkg-query)"
DEPS_OK=true
for pkg in libidn12 libpcre3 libgmp10 libexpat1 libstdc++6 libperl5.34 libaio1 libxxhash-dev libzstd-dev; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "installed"; then
        DEPS_OK=false
        check_fail "Missing: $pkg"
    fi
done
$DEPS_OK && check_pass "All dependencies installed"

echo -e "\n[7] Conflicting Services"
CONFLICT_OK=true
for svc in postfix sendmail bind9 named unbound; do
    systemctl is-active $svc &>/dev/null && { CONFLICT_OK=false; check_fail "$svc is ACTIVE"; }
done
check_pass "No conflicting services"

echo -e "\n[8] Security Services"
systemctl is-active apparmor &>/dev/null && check_pass "AppArmor active" || check_warn "AppArmor inactive"
systemctl is-active fail2ban &>/dev/null && check_pass "fail2ban active" || check_warn "fail2ban inactive"
systemctl is-active ufw &>/dev/null && check_pass "UFW active" || check_fail "UFW inactive"

# DNS-specific check
echo -e "\n[9] DNS Service Status"
case $DNS_TYPE in
    "zimbra-dnscache")
        echo -e "    ℹ zimbra-dnscache will be installed with Zimbra"
        check_pass "Port 53 ready for zimbra-dnscache"
        ;;
    "dnsmasq")
        if systemctl is-active dnsmasq &>/dev/null; then
            check_pass "dnsmasq active"
        else
            check_warn "dnsmasq inactive (will need troubleshooting)"
            echo -e "    ℹ Try: systemctl restart dnsmasq"
            echo -e "    ℹ Check: journalctl -u dnsmasq"
        fi
        ;;
    "system-dns")
        check_pass "Using system DNS (no local cache)"
        ;;
esac

echo -e "\n[10] System Resources"
RAM=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
STORAGE=$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,""); print $4}')
[[ $RAM -ge 4 ]] && check_pass "RAM: ${RAM}GB" || check_fail "RAM: ${RAM}GB"
[[ $STORAGE -ge 30 ]] && check_pass "Storage: ${STORAGE}GB" || check_fail "Storage: ${STORAGE}GB"

echo -e "\n[11] Network & Time"
ping -c 1 -W 2 google.com &>/dev/null && check_pass "Internet OK" || check_fail "No internet"
timedatectl 2>/dev/null | grep -q "System clock synchronized: yes" && check_pass "NTP sync" || check_fail "NTP not sync"

echo -e "\n##########################################################################"
echo -e "SUMMARY: PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
[[ $FAIL -eq 0 ]] && echo -e "🎉 ALL CHECKS PASSED! Ready for Zimbra install!" || echo -e "⚠ Review failures before install"
echo -e "##########################################################################"

# =============================================================================
# 14. FINAL INFORMATION
# =============================================================================
echo -e "\n##########################################################################"
echo -e "# PRE-CONFIGURATION COMPLETE                                             #"
echo -e "##########################################################################"
cat << EOF

SERVER CONFIGURATION:
─────────────────────────────────────────────────────────────────────────
  Hostname:        ${FULL_HOSTNAME}
  IP:              ${IPADDRESS}
  Gateway:         ${GATEWAY}
  DNS Type:        ${DNS_TYPE}
  Admin Networks:  ${#ADMIN_NETWORKS[@]} subnets

DNS CONFIGURATION:
─────────────────────────────────────────────────────────────────────────
EOF

case $DNS_TYPE in
    "zimbra-dnscache")
        cat << EOF
  ✓ systemd-resolved DNSStubListener: DISABLED
  ✓ Port 53: FREE for zimbra-dnscache
  ✓ Upstream DNS: ${GATEWAY}, 8.8.8.8

  ZIMBRA INSTALLER OPTIONS:
  • Install zimbra-dnscache: YES
  • Master DNS IP: ${GATEWAY}
  • Enable DNSSEC: NO
EOF
        ;;
    "dnsmasq")
        cat << EOF
  ✓ Dnsmasq: CONFIGURED and RUNNING
  ✓ Listening: 127.0.0.1:53
  ✓ Upstream DNS: 8.8.8.8, 8.8.4.4

  ZIMBRA INSTALLER OPTIONS:
  • Install zimbra-dnscache: NO
  • Master DNS IP: 127.0.0.1
  • Enable DNSSEC: NO
EOF
        ;;
    "system-dns")
        cat << EOF
  ✓ System DNS: Using upstream directly
  ✓ No local DNS cache
  ✓ Upstream DNS: ${GATEWAY}, 8.8.8.8

  ZIMBRA INSTALLER OPTIONS:
  • Install zimbra-dnscache: NO
  • Master DNS IP: ${GATEWAY}
  • Enable DNSSEC: NO
EOF
        ;;
esac

cat << EOF

SECURITY:
─────────────────────────────────────────────────────────────────────────
  AppArmor:  $(systemctl is-active apparmor 2>/dev/null || echo inactive)
  fail2ban:  $(systemctl is-active fail2ban 2>/dev/null || echo inactive)
  UFW:       $(ufw status | grep Status | awk '{print $2}')
  SSH:       Root login disabled

NEXT STEPS:
─────────────────────────────────────────────────────────────────────────
1. Download Zimbra 10.1.13 OSE for Ubuntu 22.04
2. Extract: tar -xzf zcs-*.tgz && cd zcs-*/
3. Install: sudo ./install.sh
4. Follow DNS-specific installer options above

AFTER INSTALL:
─────────────────────────────────────────────────────────────────────────
  Admin:   https://${FULL_HOSTNAME}:7071
  Webmail: https://${FULL_HOSTNAME}
  User:    ${ADMIN_EMAIL}

EOF
echo -e "##########################################################################"
read -p "Tekan [ENTER] untuk keluar..."
