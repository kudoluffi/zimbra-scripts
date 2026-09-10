#!/bin/bash
#
# zimbra-letsencrypt.sh v2.0.0
#
# Rewrite of the v1.3.8 script. Fixes:
#   1. CRITICAL: the old renewal script embedded a SECOND copy of the ISRG
#      Root X1 PEM inline in a heredoc, and that copy was corrupted (one
#      base64 line contained literal text "Root X" instead of "Um9vdCBY").
#      That produced an invalid commercial_ca.crt on every auto-renewal.
#      Fix: the Root CA is written to disk ONCE and every consumer
#      (initial install + renewal hook) reads that single file. No more
#      duplicated blobs to get out of sync.
#   2. The old custom cron script stopped zmproxyctl/zmmailboxdctl BEFORE
#      checking whether certbot actually needed to renew anything, causing
#      a pointless outage every week even when nothing renewed.
#      Fix: uses certbot's native systemd timer + renewal-hooks
#      (pre/deploy/post), which only fire when a certificate is actually
#      due for renewal. No custom cron, no needless downtime.
#   3. The old renewal path deployed straight to zmcertmgr with no
#      verifycrt step, so a broken chain could get pushed to production
#      unattended. Fix: deploy hook always runs verifycrt first and
#      refuses to deploy (and logs loudly) if verification fails.
#   4. Tested against Ubuntu 24.04 + Zimbra 10.1.x OSE.
#
# Usage: sudo bash zimbra-letsencrypt-v2.sh
#
set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
LOG_FILE="/var/log/zimbra_letsencrypt_$(date +%Y%m%d_%H%M%S).log"

log()  { echo -e "${BLUE}[INFO]${NC} $1"  | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"  | tee -a "$LOG_FILE"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    err "Script must be run as root. Use: sudo bash $0"
fi

# ─────────────────────────────────────────────────────────────────────────
# PREREQUISITE CHECKS
# ─────────────────────────────────────────────────────────────────────────
if [ -f /etc/os-release ]; then
    . /etc/os-release
    [ "$ID" = "ubuntu" ] || warn "Script tested on Ubuntu. OS terdeteksi: $PRETTY_NAME"
else
    err "Cannot detect OS."
fi
log "Detected OS: $PRETTY_NAME"

if [ ! -x /opt/zimbra/bin/zmcontrol ]; then
    err "Zimbra not installed or not found at /opt/zimbra."
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    if ! ufw status | grep -qE "^80(/tcp)?\s+ALLOW"; then
        warn "UFW aktif tapi port 80/tcp tidak terlihat ALLOW. HTTP-01 challenge (certbot) butuh port 80 terbuka dari luar."
        warn "Jalankan: ufw allow 80/tcp   (dan pastikan Fortigate benar-benar forward port 80 ke server ini, bukan cuma 443)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# USER INPUT
# ─────────────────────────────────────────────────────────────────────────
read -rp "FQDN Zimbra (contoh: mail.example.com): " FQDN
read -rp "Email ACME recovery (opsional, tekan Enter untuk skip): " LE_EMAIL
[ -z "$FQDN" ] && err "FQDN wajib diisi."

SSL_DIR="/opt/zimbra/ssl/letsencrypt"
ZIMBRA_SSL_DIR="/opt/zimbra/ssl/zimbra/commercial"
ROOTCA_FILE="$SSL_DIR/isrg-root-x1.pem"
COMMON_LIB="/opt/zimbra/ssl/letsencrypt/zimbra-le-common.sh"
HOOK_PRE="/etc/letsencrypt/renewal-hooks/pre/zimbra-le-pre.sh"
HOOK_DEPLOY="/etc/letsencrypt/renewal-hooks/deploy/zimbra-le-deploy.sh"
HOOK_POST="/etc/letsencrypt/renewal-hooks/post/zimbra-le-post.sh"
RENEW_LOG="/var/log/zimbra-le-renew.log"

mkdir -p "$SSL_DIR" "$ZIMBRA_SSL_DIR"
mkdir -p /etc/letsencrypt/renewal-hooks/{pre,deploy,post}

# ─────────────────────────────────────────────────────────────────────────
# INSTALL CERTBOT (native systemd timer stays ENABLED — we rely on it)
# ─────────────────────────────────────────────────────────────────────────
log "Installing Certbot & dependencies..."
apt-get update -y
apt-get install -y certbot curl

if systemctl list-unit-files | grep -q '^certbot.timer'; then
    systemctl enable --now certbot.timer 2>/dev/null || warn "Tidak bisa enable certbot.timer, cek manual."
    log "certbot.timer aktif (native twice-daily renewal check). Kita TIDAK pakai cron custom lagi."
fi

# ─────────────────────────────────────────────────────────────────────────
# SINGLE SOURCE OF TRUTH FOR THE ROOT CA (fixes the duplicated/corrupted blob)
# ─────────────────────────────────────────────────────────────────────────
log "Menyiapkan ISRG Root X1..."
if curl -fsSL --max-time 15 -o "$ROOTCA_FILE.tmp" https://letsencrypt.org/certs/isrgrootx1.pem 2>>"$LOG_FILE" \
    && grep -q "BEGIN CERTIFICATE" "$ROOTCA_FILE.tmp"; then
    mv "$ROOTCA_FILE.tmp" "$ROOTCA_FILE"
    log "Root CA di-download langsung dari letsencrypt.org."
else
    warn "Gagal download Root CA dari letsencrypt.org, pakai copy embedded di script (fallback)."
    rm -f "$ROOTCA_FILE.tmp"
    cat > "$ROOTCA_FILE" <<'ROOTCA_EOF'
-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----
ROOTCA_EOF
fi

# ─────────────────────────────────────────────────────────────────────────
# COMMON LIB — the single deploy_cert() implementation, sourced by both
# this installer AND the certbot deploy-hook. This is what eliminates the
# duplicated-blob bug class entirely: there is now exactly one place that
# knows how to build commercial.crt/.key/_ca.crt.
# ─────────────────────────────────────────────────────────────────────────
log "Menulis common lib ke $COMMON_LIB..."
cat > "$COMMON_LIB" <<COMMONLIB_EOF
#!/bin/bash
# Shared by zimbra-letsencrypt-v2.sh (initial install) and the certbot
# deploy-hook (renewals). Do not edit copies of this by hand elsewhere.
SSL_DIR="$SSL_DIR"
ZIMBRA_SSL_DIR="$ZIMBRA_SSL_DIR"
ROOTCA_FILE="$ROOTCA_FILE"
RENEW_LOG="$RENEW_LOG"

le_log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" | tee -a "\$RENEW_LOG"; }

# deploy_cert <fqdn> <letsencrypt_live_dir>
# Copies cert material into place, verifies with zmcertmgr, and only
# deploys if verification actually passes. Returns non-zero on failure
# instead of pushing a possibly-broken cert.
deploy_cert() {
    local fqdn="\$1"
    local le_dir="\$2"

    if [ ! -f "\$le_dir/fullchain.pem" ]; then
        le_log "ERROR: \$le_dir/fullchain.pem tidak ada, skip deploy."
        return 1
    fi

    for dir in "\$SSL_DIR" "\$ZIMBRA_SSL_DIR"; do
        mkdir -p "\$dir"
        cp "\$le_dir/fullchain.pem" "\$dir/commercial.crt"
        cp "\$le_dir/privkey.pem"   "\$dir/commercial.key"
        cp "\$le_dir/chain.pem"     "\$dir/commercial_ca.crt"
        cat "\$ROOTCA_FILE" >> "\$dir/commercial_ca.crt"
        chown zimbra:zimbra "\$dir"/*
        chmod 600 "\$dir/commercial.key"
        chmod 644 "\$dir/commercial.crt" "\$dir/commercial_ca.crt"
        le_log "Processed: \$dir"
    done

    le_log "Verifying certificate with zmcertmgr..."
    local verify_output
    verify_output=\$(su - zimbra -c "/opt/zimbra/bin/zmcertmgr verifycrt comm \$SSL_DIR/commercial.key \$SSL_DIR/commercial.crt \$SSL_DIR/commercial_ca.crt" 2>&1)
    echo "\$verify_output" | tee -a "\$RENEW_LOG"

    if ! echo "\$verify_output" | grep -q "OK"; then
        le_log "ERROR: Verifikasi gagal, TIDAK melakukan deploy. Sertifikat lama tetap dipakai."
        return 1
    fi

    le_log "Verifikasi OK. Deploying certificate..."
    su - zimbra -c "/opt/zimbra/bin/zmcertmgr deploycrt comm \$ZIMBRA_SSL_DIR/commercial.crt \$ZIMBRA_SSL_DIR/commercial_ca.crt" 2>&1 | tee -a "\$RENEW_LOG"
    le_log "Certificate deployed for \$fqdn."
    return 0
}
COMMONLIB_EOF
chmod 644 "$COMMON_LIB"

# ─────────────────────────────────────────────────────────────────────────
# INITIAL CERTIFICATE ISSUANCE (standalone HTTP-01, one-time downtime)
# ─────────────────────────────────────────────────────────────────────────
log "Stopping Zimbra web services (proxy & mailboxd) to free port 80..."
su - zimbra -c "zmproxyctl stop; zmmailboxdctl stop" 2>/dev/null || warn "Services already stopped."

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

[ -d "/etc/letsencrypt/live/$FQDN" ] || err "Certificate issuance failed. Check log: $LOG_FILE"
log "Certificate issued successfully."

# ─────────────────────────────────────────────────────────────────────────
# DEPLOY (uses the same shared function the renewal hook will use later)
# ─────────────────────────────────────────────────────────────────────────
source "$COMMON_LIB"
if ! deploy_cert "$FQDN" "/etc/letsencrypt/live/$FQDN"; then
    err "Deploy awal gagal. Cek $RENEW_LOG dan $LOG_FILE."
fi

log "Restarting Zimbra services..."
su - zimbra -c "zmcontrol restart"
sleep 5

log "Verifying deployed certificate..."
if su - zimbra -c "/opt/zimbra/bin/zmcertmgr viewdeployedcrt" 2>&1 | grep -q "$FQDN"; then
    log "✅ SSL certificate successfully deployed for $FQDN"
else
    warn "⚠️ Verification incomplete. Check manually."
fi

# ─────────────────────────────────────────────────────────────────────────
# RENEWAL HOOKS — replace the old custom cron. These only run when
# certbot's OWN check decides a cert is actually due for renewal, so
# there is no more weekly no-op downtime.
# ─────────────────────────────────────────────────────────────────────────
log "Menulis certbot renewal hooks (pre/deploy/post)..."

cat > "$HOOK_PRE" <<'PRE_EOF'
#!/bin/bash
# Runs ONLY when certbot has determined at least one cert needs renewal.
source /opt/zimbra/ssl/letsencrypt/zimbra-le-common.sh
le_log "pre-hook: stopping zmproxy & mailboxd to free port 80..."
su - zimbra -c "zmproxyctl stop; zmmailboxdctl stop" 2>/dev/null || true
PRE_EOF

cat > "$HOOK_DEPLOY" <<'DEPLOY_EOF'
#!/bin/bash
# Runs ONLY for certs that were actually renewed just now.
# Certbot exports $RENEWED_LINEAGE (e.g. /etc/letsencrypt/live/mail.example.com)
# and $RENEWED_DOMAINS.
source /opt/zimbra/ssl/letsencrypt/zimbra-le-common.sh
FQDN="${RENEWED_DOMAINS%% *}"
le_log "deploy-hook: renewed cert for $FQDN, deploying to Zimbra..."
if deploy_cert "$FQDN" "$RENEWED_LINEAGE"; then
    le_log "deploy-hook: deploy sukses untuk $FQDN."
else
    le_log "deploy-hook: DEPLOY GAGAL untuk $FQDN — sertifikat lama tetap dipakai zmcertmgr."
fi
DEPLOY_EOF

cat > "$HOOK_POST" <<'POST_EOF'
#!/bin/bash
# Runs after certbot finishes its renewal attempt, whenever pre-hook ran
# (i.e. whenever a renewal was actually attempted) — success or failure.
source /opt/zimbra/ssl/letsencrypt/zimbra-le-common.sh
le_log "post-hook: restarting Zimbra services..."
su - zimbra -c "zmcontrol restart" 2>&1 | tee -a "$RENEW_LOG"
le_log "post-hook: done."
POST_EOF

chmod +x "$HOOK_PRE" "$HOOK_DEPLOY" "$HOOK_POST"
touch "$RENEW_LOG"

# ─────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN} Let's Encrypt SSL for Zimbra - SELESAI (v2.0.0)${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Domain          : $FQDN"
echo -e "Cert Path       : /etc/letsencrypt/live/$FQDN/"
echo -e "Zimbra SSL      : $SSL_DIR/ & $ZIMBRA_SSL_DIR/"
echo -e "Root CA (shared): $ROOTCA_FILE"
echo -e "Common lib      : $COMMON_LIB"
echo -e "Auto-Renew      : certbot.timer (native, twice daily check, NO custom cron)"
echo -e "Renewal hooks   : $HOOK_PRE"
echo -e "                  $HOOK_DEPLOY"
echo -e "                  $HOOK_POST"
echo -e "Install Log     : $LOG_FILE"
echo -e "Renewal Log     : $RENEW_LOG"
echo -e "${YELLOW}Catatan penting:${NC}"
echo -e "• Pastikan Fortigate forward port 80 (bukan cuma 443) ke server ini,"
echo -e "  atau renewal via HTTP-01 akan gagal saat certbot.timer jalan."
echo -e "• Test alur renewal tanpa downtime real: certbot renew --dry-run"
echo -e "• Cek timer: systemctl list-timers | grep certbot"
echo -e "• Cek hook manual: ls -la /etc/letsencrypt/renewal-hooks/{pre,deploy,post}/"
echo -e "${GREEN}========================================================${NC}\n"

log "Script selesai. SSL Zimbra aktif, auto-renewal via certbot.timer + hooks."
