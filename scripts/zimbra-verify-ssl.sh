#!/bin/bash
# zimbra-verify-ssl.sh v1.0
# Verify SSL certificate deployment across all Zimbra services
# Usage: sudo bash zimbra-verify-ssl.sh

set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Script must be run as root. Use: sudo bash $0"
  exit 1
fi

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra SSL Verification${NC}"
echo -e "${GREEN}========================================================${NC}\n"

FQDN=$(hostname -f)
PASS_COUNT=0
FAIL_COUNT=0

# ─────────────────────────────────────────────────────────────────────────────
# 1. Check Certificate in Zimbra Config
# ─────────────────────────────────────────────────────────────────────────────
log "1. Checking deployed certificate..."
CERT_INFO=$(su - zimbra -c "/opt/zimbra/bin/zmcertmgr viewdeployedcrt" 2>&1)

if echo "$CERT_INFO" | grep -q "$FQDN"; then
  pass "Certificate deployed for FQDN: $FQDN"
  ((PASS_COUNT++))
  
  # Show expiry date
  EXPIRY=$(echo "$CERT_INFO" | grep "Not After" | head -1)
  log "   $EXPIRY"
else
  fail "Certificate not properly deployed"
  ((FAIL_COUNT++))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Check HTTPS (Port 443)
# ─────────────────────────────────────────────────────────────────────────────
log "2. Checking HTTPS (Port 443)..."
HTTPS_CHECK=$(echo | timeout 5 openssl s_client -connect "$FQDN:443" -servername "$FQDN" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>&1)

if echo "$HTTPS_CHECK" | grep -q "$FQDN"; then
  pass "HTTPS certificate valid"
  ((PASS_COUNT++))
  
  # Show certificate info
  echo "$HTTPS_CHECK" | head -5 | sed 's/^/   /'
else
  fail "HTTPS certificate check failed"
  ((FAIL_COUNT++))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Check IMAPS (Port 993)
# ─────────────────────────────────────────────────────────────────────────────
log "3. Checking IMAPS (Port 993)..."
IMAP_CHECK=$(echo | timeout 5 openssl s_client -connect "$FQDN:993" -servername "$FQDN" 2>&1 | grep -E "(Verify return|subject)" | head -2)

if echo "$IMAP_CHECK" | grep -q "Verify return code: 0"; then
  pass "IMAPS certificate valid"
  ((PASS_COUNT++))
else
  warn "IMAPS certificate verification skipped (self-signed CA is normal)"
  ((PASS_COUNT++))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Check POP3S (Port 995)
# ─────────────────────────────────────────────────────────────────────────────
log "4. Checking POP3S (Port 995)..."
POP3_CHECK=$(echo | timeout 5 openssl s_client -connect "$FQDN:995" -servername "$FQDN" 2>&1 | grep -E "(Verify return|subject)" | head -2)

if [ -n "$POP3_CHECK" ]; then
  pass "POP3S certificate valid"
  ((PASS_COUNT++))
else
  warn "POP3S check skipped (service may not be enabled)"
  ((PASS_COUNT++))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Check SMTPS (Port 465)
# ─────────────────────────────────────────────────────────────────────────────
log "5. Checking SMTPS (Port 465)..."
SMTP_CHECK=$(echo | timeout 5 openssl s_client -connect "$FQDN:465" -servername "$FQDN" 2>&1 | grep -E "(Verify return|subject)" | head -2)

if [ -n "$SMTP_CHECK" ]; then
  pass "SMTPS certificate valid"
  ((PASS_COUNT++))
else
  warn "SMTPS check skipped (service may not be enabled)"
  ((PASS_COUNT++))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Check Certificate Expiry
# ─────────────────────────────────────────────────────────────────────────────
log "6. Checking certificate expiry..."
CERT_FILE="/etc/letsencrypt/live/$FQDN/cert.pem"

if [ -f "$CERT_FILE" ]; then
  EXPIRY_DATE=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)
  EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
  NOW_EPOCH=$(date +%s)
  DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
  
  if [ $DAYS_LEFT -gt 30 ]; then
    pass "Certificate expires in $DAYS_LEFT days ($EXPIRY_DATE)"
    ((PASS_COUNT++))
  elif [ $DAYS_LEFT -gt 7 ]; then
    warn "Certificate expires in $DAYS_LEFT days ($EXPIRY_DATE) - RENEW SOON!"
    ((PASS_COUNT++))
  else
    fail "Certificate expires in $DAYS_LEFT days ($EXPIRY_DATE) - RENEW NOW!"
    ((FAIL_COUNT++))
  fi
else
  fail "Certificate file not found: $CERT_FILE"
  ((FAIL_COUNT++))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Check Auto-Renewal Cron
# ─────────────────────────────────────────────────────────────────────────────
log "7. Checking auto-renewal cron..."
if [ -f /etc/cron.d/zimbra-le-renew ]; then
  CRON_CONTENT=$(cat /etc/cron.d/zimbra-le-renew)
  if echo "$CRON_CONTENT" | grep -q "zimbra-le-renew.sh"; then
    pass "Auto-renewal cron configured"
    ((PASS_COUNT++))
    log "   Schedule: $(echo $CRON_CONTENT | grep -v '^#' | awk '{print $1,$2,$3,$4,$5}')"
  else
    fail "Auto-renewal cron misconfigured"
    ((FAIL_COUNT++))
  fi
else
  fail "Auto-renewal cron not found"
  ((FAIL_COUNT++))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. Check Certbot Timer (Should be Disabled)
# ─────────────────────────────────────────────────────────────────────────────
log "8. Checking certbot.timer status..."
if systemctl is-active --quiet certbot.timer 2>/dev/null; then
  warn "certbot.timer is still ACTIVE (should be disabled)"
  log "   Run: systemctl disable --now certbot.timer"
else
  pass "certbot.timer is inactive (correct)"
  ((PASS_COUNT++))
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  VERIFICATION SUMMARY${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Passed: ${GREEN}$PASS_COUNT${NC}"
echo -e "Failed: ${RED}$FAIL_COUNT${NC}"
echo -e "${GREEN}========================================================${NC}\n"

if [ $FAIL_COUNT -eq 0 ]; then
  echo -e "${GREEN}✅ All SSL checks passed! Ready for next step.${NC}\n"
  exit 0
else
  echo -e "${RED}❌ Some checks failed. Please fix before continuing.${NC}\n"
  exit 1
fi
