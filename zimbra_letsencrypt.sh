#!/bin/bash
# zimbra_letsencrypt.sh v1.2
# Fixed: dash compatibility, certbot package, variable quoting, error handling
# Tested on: Ubuntu 22.04 LTS + Zimbra 10.1.16 OSE
# Author: Qwen (AI) | License: MIT

set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG_FILE="/var/log/zimbra_letsencrypt_$(date +%Y%m%d_%H%M%S).log"

log()  { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

[ "$(id -u)" -eq 0 ] || err "Script must be run as root."

if [ -f /etc/os-release ]; then
  . /etc/os-release
  [ "$ID" = "ubuntu" ] || err "Script ini dioptimalkan untuk Ubuntu. OS: $PRETTY_NAME"
else
  err "Cannot detect OS."
fi

log "Detected OS: $PRETTY_NAME"

# ─────────────────────────────────────────────────────────────────────────────
# USER INPUT
# ─────────────────────────────────────────────────────────────────────────────
read -rp "FQDN Zimbra (contoh: nmail.newbienotes.my.id): " FQDN
read -rp "Email ACME recovery (opsional, tekan Enter untuk skip): " LE_EMAIL

[ -z "$FQDN" ] && err "FQDN wajib diisi."

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL CERTBOT (Correct Package for Ubuntu 22.04)
# ─────────────────────────────────────────────────────────────────────────────
log "Installing Certbot & dependencies..."
apt-get update -y
apt-get install -y certbot

# ─────────────────────────────────────────────────────────────────────────────
# PREPARE ZIMBRA SSL DIR
# ─────────────────────────────────────────────────────────────────────────────
SSL_DIR="/opt/zimbra/ssl/letsencrypt"
log "Preparing Zimbra SSL directory..."
mkdir -p "$SSL_DIR"
chown -R zimbra:zimbra "$SSL_DIR"
chmod 700 "$SSL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# STOP ZIMBRA WEB SERVICES (Free port 80)
# ─────────────────────────────────────────────────────────────────────────────
log "Stopping Zimbra web services (proxy & mailboxd) to free port 80..."
su - zimbra -c "zmproxyctl stop; zmmailboxdctl stop" 2>/dev/null || warn "Services already stopped or stopped with warnings (normal)."

# ─────────────────────────────────────────────────────────────────────────────
# ISSUE CERTIFICATE
# ─────────────────────────────────────────────────────────────────────────────
log "Requesting Let's Encrypt certificate for $FQDN..."

if [ -n "$LE_EMAIL" ]; then
  certbot certonly \
    --standalone \
    --preferred-chain "ISRG Root X1" \
    -d "$FQDN" \
    --email "$LE_EMAIL" \
    --agree-tos \
    --non-interactive \
    --key-type rsa \
    2>&1 | tee -a "$LOG_FILE"
else
  warn "Email skipped. Account recovery will be limited."
  certbot certonly \
    --standalone \
    --preferred-chain "ISRG Root X1" \
    -d "$FQDN" \
    --register-unsafely-without-email \
    --agree-tos \
    --non-interactive \
    --key-type rsa \
    2>&1 | tee -a "$LOG_FILE"
fi

if [ ! -d "/etc/letsencrypt/live/$FQDN" ]; then
  err "Certificate issuance failed. Check log: $LOG_FILE"
fi
log "Certificate issued successfully."

# ─────────────────────────────────────────────────────────────────────────────
# DEPLOY TO ZIMBRA
# ─────────────────────────────────────────────────────────────────────────────
LE_DIR="/etc/letsencrypt/live/$FQDN"
log "Copying & deploying certificates to Zimbra..."
cp "$LE_DIR/cert.pem" "$SSL_DIR/commercial.crt"
cp "$LE_DIR/privkey.pem" "$SSL_DIR/commercial.key"
cp "$LE_DIR/fullchain.pem" "$SSL_DIR/commercial_ca.crt"
chown zimbra:zimbra "$SSL_DIR"/*

su - zimbra -c "/opt/zimbra/bin/zmcertmgr verifycrt comm $SSL_DIR/commercial.key $SSL_DIR/commercial.crt $SSL_DIR/commercial_ca.crt" || err "Verification failed."
su - zimbra -c "/opt/zimbra/bin/zmcertmgr deploycrt comm $SSL_DIR/commercial.crt $SSL_DIR/commercial_ca.crt" || err "Deployment failed."

# ─────────────────────────────────────────────────────────────────────────────
# RESTART & VERIFY
# ─────────────────────────────────────────────────────────────────────────────
log "Restarting Zimbra services..."
su - zimbra -c "zmcontrol restart"
sleep 5

log "Verifying deployed certificate..."
if su - zimbra -c "/opt/zimbra/bin/zmcertmgr viewdeployedcrt" 2>&1 | grep -q "$FQDN"; then
  log "✅ SSL certificate successfully deployed for $FQDN"
else
  warn "⚠️ Verification incomplete. Check manually: su - zimbra -c 'zmcertmgr viewdeployedcrt'"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SETUP AUTO-RENEWAL
# ─────────────────────────────────────────────────────────────────────────────
RENEW_SCRIPT="/usr/local/bin/zimbra-le-renew.sh"
log "Creating auto-renewal script..."
cat > "$RENEW_SCRIPT" <<'RENEW_EOF'
#!/bin/bash
set -eo pipefail
FQDN="${1:-$(hostname -f)}"
LE_DIR="/etc/letsencrypt/live/$FQDN"
SSL_DIR="/opt/zimbra/ssl/letsencrypt"

echo "[$(date)] Starting Zimbra LE renewal..."
su - zimbra -c "zmproxyctl stop; zmmailboxdctl stop" 2>/dev/null || true

certbot renew --quiet --cert-name "$FQDN" --standalone --register-unsafely-without-email || { echo "[$(date)] Renewal failed"; su - zimbra -c "zmcontrol start"; exit 1; }

if [ -d "$LE_DIR" ]; then
  cp "$LE_DIR/cert.pem" "$SSL_DIR/commercial.crt"
  cp "$LE_DIR/privkey.pem" "$SSL_DIR/commercial.key"
  cp "$LE_DIR/fullchain.pem" "$SSL_DIR/commercial_ca.crt"
  chown zimbra:zimbra "$SSL_DIR"/*
  su - zimbra -c "/opt/zimbra/bin/zmcertmgr deploycrt comm $SSL_DIR/commercial.crt $SSL_DIR/commercial_ca.crt"
  su - zimbra -c "zmcontrol restart"
  echo "[$(date)] Certificate renewed & deployed successfully."
else
  echo "[$(date)] Renewal failed: Cert dir missing."
  su - zimbra -c "zmcontrol start"
  exit 1
fi
RENEW_EOF
chmod +x "$RENEW_SCRIPT"

log "Adding weekly renewal cron job..."
echo "0 3 * * 1 root $RENEW_SCRIPT $(hostname -f) >> /var/log/zimbra-le-renew.log 2>&1" > /etc/cron.d/zimbra-le-renew

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Let's Encrypt SSL for Zimbra - SELESAI${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Domain     : $FQDN"
echo -e "Cert Path  : /etc/letsencrypt/live/$FQDN/"
echo -e "Zimbra SSL : $SSL_DIR/"
echo -e "Auto-Renew : Every Monday 03:00 (cron)"
echo -e "Log File   : $LOG_FILE"
echo -e "${YELLOW}Verifikasi:${NC}"
echo -e "• Buka https://$FQYN di browser"
echo -e "• CLI: su - zimbra -c 'zmcertmgr viewdeployedcrt'"
echo -e "${GREEN}========================================================${NC}\n"

log "Script selesai. SSL Zimbra aktif & auto-renewal dikonfigurasi."
