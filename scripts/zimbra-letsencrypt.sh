#!/bin/bash
# zimbra-letsencrypt.sh v1.3.7
# FINAL FIX: Check for "OK" instead of "success" in zmcertmgr output
# Usage: sudo bash zimbra-letsencrypt.sh
# Author: Qwen (AI) | License: MIT

set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG_FILE="/var/log/zimbra_letsencrypt_$(date +%Y%m%d_%H%M%S).log"

log()  { echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  err "Script must be run as root. Use: sudo bash $0"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PREREQUISITE CHECKS
# ─────────────────────────────────────────────────────────────────────────────
if [ -f /etc/os-release ]; then
  . /etc/os-release
  [ "$ID" = "ubuntu" ] || warn "Script tested on Ubuntu. OS: $PRETTY_NAME"
else
  err "Cannot detect OS."
fi
log "Detected OS: $PRETTY_NAME"

if [ ! -x /opt/zimbra/bin/zmcontrol ]; then
  err "Zimbra not installed or not found at /opt/zimbra."
fi

# ─────────────────────────────────────────────────────────────────────────────
# USER INPUT
# ─────────────────────────────────────────────────────────────────────────────
read -rp "FQDN Zimbra (contoh: mail.example.com): " FQDN
read -rp "Email ACME recovery (opsional, tekan Enter untuk skip): " LE_EMAIL
[ -z "$FQDN" ] && err "FQDN wajib diisi."

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL CERTBOT
# ─────────────────────────────────────────────────────────────────────────────
log "Installing Certbot & dependencies..."
apt-get update -y
apt-get install -y certbot curl

# ─────────────────────────────────────────────────────────────────────────────
# PREPARE DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────
SSL_DIR="/opt/zimbra/ssl/letsencrypt"
ZIMBRA_SSL_DIR="/opt/zimbra/ssl/zimbra/commercial"
log "Preparing Zimbra SSL directories..."
mkdir -p "$SSL_DIR" "$ZIMBRA_SSL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# STOP ZIMBRA WEB SERVICES
# ─────────────────────────────────────────────────────────────────────────────
log "Stopping Zimbra web services (proxy & mailboxd) to free port 80..."
su - zimbra -c "zmproxyctl stop; zmmailboxdctl stop" 2>/dev/null || warn "Services already stopped."

# ─────────────────────────────────────────────────────────────────────────────
# ISSUE CERTIFICATE
# ─────────────────────────────────────────────────────────────────────────────
log "Requesting Let's Encrypt certificate for $FQDN..."

if [ -n "$LE_EMAIL" ]; then
  certbot certonly --standalone --preferred-challenges http -d "$FQDN" \
    --email "$LE_EMAIL" --agree-tos --non-interactive --expand \
    --keep-until-expiring --cert-name "$FQDN" 2>&1 | tee -a "$LOG_FILE"
else
  warn "Email skipped. Account recovery will be limited."
  certbot certonly --standalone --preferred-challenges http -d "$FQDN" \
    --register-unsafely-without-email --agree-tos --non-interactive --expand \
    --keep-until-expiring --cert-name "$FQDN" 2>&1 | tee -a "$LOG_FILE"
fi

if [ ! -d "/etc/letsencrypt/live/$FQDN" ]; then
  err "Certificate issuance failed. Check log: $LOG_FILE"
fi
log "Certificate issued successfully."

# ─────────────────────────────────────────────────────────────────────────────
# DEPLOY TO ZIMBRA (v1.3.7: Check for "OK" instead of "success")
# ─────────────────────────────────────────────────────────────────────────────
LE_DIR="/etc/letsencrypt/live/$FQDN"
log "Preparing certificates for Zimbra..."

# Hardcoded Root CA ISRG X1
ROOTCA="-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----"

# Copy & Append Root CA to ALL directories
for dir in "$SSL_DIR" "$ZIMBRA_SSL_DIR"; do
  mkdir -p "$dir"
  cp "$LE_DIR/fullchain.pem" "$dir/commercial.crt"
  cp "$LE_DIR/privkey.pem" "$dir/commercial.key"
  cp "$LE_DIR/chain.pem" "$dir/commercial_ca.crt"
  echo "$ROOTCA" >> "$dir/commercial_ca.crt"
  
  chown zimbra:zimbra "$dir"/*
  chmod 600 "$dir/commercial.key"
  chmod 644 "$dir/commercial.crt" "$dir/commercial_ca.crt"
  log "  ✓ Processed: $dir"
done

# Verify & Deploy - FIXED: Check for "OK" instead of "success"
log "Verifying certificate with zmcertmgr..."
VERIFY_OUTPUT=$(su - zimbra -c "/opt/zimbra/bin/zmcertmgr verifycrt comm $SSL_DIR/commercial.key $SSL_DIR/commercial.crt $SSL_DIR/commercial_ca.crt" 2>&1)
echo "$VERIFY_OUTPUT" | tee -a "$LOG_FILE"

if echo "$VERIFY_OUTPUT" | grep -q "OK"; then
  log "✅ Verification successful."
  log "Deploying certificate..."
  su - zimbra -c "/opt/zimbra/bin/zmcertmgr deploycrt comm $ZIMBRA_SSL_DIR/commercial.crt $ZIMBRA_SSL_DIR/commercial_ca.crt" 2>&1 | tee -a "$LOG_FILE"
  log "✅ Certificate deployed."
else
  log "❌ Verification output: $VERIFY_OUTPUT"
  err "Verification failed. Check zmcertmgr output above."
fi

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
  warn "⚠️ Verification incomplete. Check manually."
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
ZIMBRA_SSL_DIR="/opt/zimbra/ssl/zimbra/commercial"

echo "[$(date)] Starting Zimbra LE renewal..."
su - zimbra -c "zmproxyctl stop; zmmailboxdctl stop" 2>/dev/null || true

certbot renew --quiet --cert-name "$FQDN" --standalone --register-unsafely-without-email || { echo "[$(date)] Renewal failed"; su - zimbra -c "zmcontrol start"; exit 1; }

if [ -d "$LE_DIR" ]; then
  ROOTCA="-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----"
  
  for dir in "$SSL_DIR" "$ZIMBRA_SSL_DIR"; do
    cp "$LE_DIR/fullchain.pem" "$dir/commercial.crt"
    cp "$LE_DIR/privkey.pem" "$dir/commercial.key"
    cp "$LE_DIR/chain.pem" "$dir/commercial_ca.crt"
    echo "$ROOTCA" >> "$dir/commercial_ca.crt"
    chown zimbra:zimbra "$dir"/*
    chmod 600 "$dir/commercial.key"
    chmod 644 "$dir/commercial.crt" "$dir/commercial_ca.crt"
  done
  
  su - zimbra -c "/opt/zimbra/bin/zmcertmgr deploycrt comm $ZIMBRA_SSL_DIR/commercial.crt $ZIMBRA_SSL_DIR/commercial_ca.crt"
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
echo "0 3 * * 1 root $RENEW_SCRIPT $FQDN >> /var/log/zimbra-le-renew.log 2>&1" > /etc/cron.d/zimbra-le-renew

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Let's Encrypt SSL for Zimbra - SELESAI${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Domain     : $FQDN"
echo -e "Cert Path  : /etc/letsencrypt/live/$FQDN/"
echo -e "Zimbra SSL : $SSL_DIR/ & $ZIMBRA_SSL_DIR/"
echo -e "Auto-Renew : Every Monday 03:00 (cron)"
echo -e "Log File   : $LOG_FILE"
echo -e "${YELLOW}Verifikasi:${NC}"
echo -e "• Buka https://$FQDN di browser"
echo -e "• CLI: su - zimbra -c 'zmcertmgr viewdeployedcrt'"
echo -e "${GREEN}========================================================${NC}\n"

log "Script selesai. SSL Zimbra aktif & auto-renewal dikonfigurasi."
