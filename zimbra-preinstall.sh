#!/usr/bin/env bash
# zimbra_preinstall.sh v14.5
# Fixed: Broken apt-get chain, safe chrony fallback, Ubuntu 22.04 + Zimbra 10.1.16 OSE (Maldua)
# Author: Qwen (AI) | License: MIT | Use at your own risk in production!

set -uo pipefail  # set -e dihapus agar script tidak berhenti di non-critical warning
set -E
trap 'err "Script failed at line $LINENO with exit code $?"' ERR

VERSION="14.5"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG_FILE="/var/log/zimbra_preinstall_$(date +%Y%m%d_%H%M%S).log"

log()  { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

[[ $EUID -eq 0 ]] || err "Script must be run as root (use sudo or su -)"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS="${ID,,}"
else
    err "Cannot detect OS."
fi
[[ "$OS" == "ubuntu" ]] || err "Script ini dioptimalkan untuk Ubuntu. OS terdeteksi: $PRETTY_NAME"

log "Detected OS: $PRETTY_NAME"

# ─────────────────────────────────────────────────────────────────────────────
# USER INPUT
# ─────────────────────────────────────────────────────────────────────────────
read -rp "FQDN (mail.example.com): " FQDN
read -rp "IP Internal Server: " SERVER_IP
read -rp "IP Gateway: " GATEWAY_IP
read -rp "Upstream DNS (8.8.8.8/1.1.1.1): " UPSTREAM_DNS
read -rp "Domain Email (example.com): " MAIL_DOMAIN

[[ -z "$FQDN" || -z "$SERVER_IP" || -z "$GATEWAY_IP" || -z "$UPSTREAM_DNS" || -z "$MAIL_DOMAIN" ]] && err "Semua field wajib diisi."
HOSTNAME_SHORT="${FQDN%%.*}"

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM PREP & DEPENDENCIES (FIXED CHAIN)
# ─────────────────────────────────────────────────────────────────────────────
log "Updating system & installing core dependencies..."
apt-get update -y
apt-get upgrade -y
apt-get install -y \
  dnsutils net-tools sysstat unzip pax sqlite3 perl libperl5.34 libdbi-perl chrony \
  libnet-dns-perl libexpat1 libssl-dev libxml2-dev libgomp1 libpq5 libpcre2-8-0

# Install optional/legacy packages safely
apt-get install -y libpcre3 2>/dev/null || warn "libpcre3 tidak tersedia di repo (biasanya tidak wajib di Zimbra 10.x)"

# Install security & firewall packages
log "Installing UFW, Fail2Ban & Chrony..."
apt-get install -y ufw fail2ban

# ─────────────────────────────────────────────────────────────────────────────
# DISABLE CONFLICTING SERVICES
# ─────────────────────────────────────────────────────────────────────────────
log "Stopping & disabling conflicting services..."
for svc in postfix sendmail apache2 nginx; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

# ─────────────────────────────────────────────────────────────────────────────
# HOSTNAME & /etc/hosts
# ─────────────────────────────────────────────────────────────────────────────
log "Configuring hostname & /etc/hosts..."
hostnamectl set-hostname "$FQDN"
cat > /etc/hosts <<EOF
127.0.0.1   localhost
$SERVER_IP  $FQDN $HOSTNAME_SHORT
::1         localhost ip6-localhost ip6-loopback
EOF

# ─────────────────────────────────────────────────────────────────────────────
# DNSMASQ & systemd-resolved (Ubuntu 22.04 + Zimbra MX Ready)
# ─────────────────────────────────────────────────────────────────────────────
log "Configuring dnsmasq & handling systemd-resolved..."
apt-get install -y dnsmasq
cp -f /etc/dnsmasq.conf /etc/dnsmasq.conf.bak

cat > /etc/dnsmasq.conf <<EOF
listen-address=127.0.0.1,${SERVER_IP}
bind-dynamic
except-interface=lo
domain=${MAIL_DOMAIN}
mx-host=${MAIL_DOMAIN},${FQDN},10
local=/${MAIL_DOMAIN}/
server=${UPSTREAM_DNS}
server=${GATEWAY_IP}
addn-hosts=/etc/hosts
cache-size=1000
dns-forward-max=150
no-poll
no-resolv
log-queries
log-facility=/var/log/dnsmasq.log
EOF

cat > /etc/logrotate.d/dnsmasq <<EOF
/var/log/dnsmasq.log { daily rotate 7 compress missingok notifempty create 0640 dnsmasq dnsmasq }
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq

if systemctl is-active --quiet systemd-resolved; then
    warn "Disabling systemd-resolved to prevent port 53/resolv.conf conflicts..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
fi

# ─────────────────────────────────────────────────────────────────────────────
# SYSCTL TUNING
# ─────────────────────────────────────────────────────────────────────────────
log "Applying sysctl tuning..."
cat > /etc/sysctl.d/99-zimbra.conf <<EOF
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
vm.swappiness = 10
fs.file-max = 65536
EOF
sysctl -p /etc/sysctl.d/99-zimbra.conf

# ─────────────────────────────────────────────────────────────────────────────
# UFW FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
log "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing

ufw allow ssh/tcp
ufw allow 25/tcp
ufw allow 80/tcp
ufw allow 110/tcp
ufw allow 143/tcp
ufw allow 443/tcp
ufw allow 587/tcp
ufw allow 993/tcp
ufw allow 995/tcp
ufw allow 7071/tcp

echo "y" | ufw enable 2>/dev/null || ufw --force enable
sleep 2
log "UFW configured. Status: $(ufw status | head -1)"

# ─────────────────────────────────────────────────────────────────────────────
# FAIL2BAN (SAFE PRE-INSTALL)
# ─────────────────────────────────────────────────────────────────────────────
log "Pre-configuring Fail2Ban for Zimbra..."
cat > /etc/fail2ban/filter.d/zimbra-auth.conf <<'FILTEREOF'
[Definition]
failregex = ^.*protocol=(soap|imap|pop3|smtp);\s+error=authentication failed for.*\s+ip=<HOST>
ignoreregex =
FILTEREOF

cat > /etc/fail2ban/jail.d/zimbra.conf <<'JAILEOF'
[zimbra-auth]
enabled  = false
filter   = zimbra-auth
action   = ufw
logpath  = /opt/zimbra/log/audit.log
maxretry = 3
findtime = 3600
bantime  = 86400
ignoremissing = true
backend  = auto
JAILEOF

systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2Ban installed & running. JAIL ZIMBRA-AUTH masih DISABLED (aktifkan post-install)."

# ─────────────────────────────────────────────────────────────────────────────
# TIME SYNC (SAFE FALLBACK)
# ─────────────────────────────────────────────────────────────────────────────
log "Configuring time synchronization..."
# Fix: Unmask service yang sering diblokir di image VPS/cloud tertentu
systemctl unmask systemd-timesyncd 2>/dev/null || true

if systemctl list-unit-files | grep -q chrony.service; then
    systemctl enable chrony
    systemctl restart chrony
    log "Chrony enabled & running."
elif systemctl list-unit-files | grep -q systemd-timesyncd.service; then
    systemctl enable systemd-timesyncd
    systemctl restart systemd-timesyncd
    log "Using default systemd-timesyncd (chrony not available)."
else
    warn "No NTP service found. Time sync might not be active."
fi

# ─────────────────────────────────────────────────────────────────────────────
# DNS VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────
log "Verifying DNS resolution..."
dig +short "$FQDN" A >/dev/null 2>&1 || warn "Forward DNS (A record) belum terdeteksi publik."
dig +short -x "$SERVER_IP" >/dev/null 2>&1 || warn "Reverse DNS (PTR) belum terdeteksi."

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra Pre-Install v${VERSION} - SELESAI${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Hostname   : ${FQDN}"
echo -e "IP Address : ${SERVER_IP}"
echo -e "Domain     : ${MAIL_DOMAIN}"
echo -e "DNS Local  : dnsmasq (bind-dynamic)"
echo -e "Resolv.conf: Set to 127.0.0.1"
echo -e "Firewall   : UFW active"
echo -e "Brute-Force: Fail2Ban ready (aktifkan post-install)"
echo -e "Log File   : ${LOG_FILE}"
echo -e "${YELLOW}Langkah selanjutnya:${NC}"
echo -e "1. Extract & jalankan Zimbra installer (./install.sh)"
echo -e "2. Setelah install selesai, aktifkan Fail2Ban:"
echo -e "   sudo sed -i 's/enabled  = false/enabled  = true/' /etc/fail2ban/jail.d/zimbra.conf"
echo -e "   sudo systemctl restart fail2ban"
echo -e "${GREEN}========================================================${NC}\n"

log "Script selesai. Server siap untuk instalasi Zimbra 10.1.16 OSE."
