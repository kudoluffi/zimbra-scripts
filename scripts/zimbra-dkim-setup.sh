#!/bin/bash
# zimbra-dkim-setup.sh v1.6
# Configure DKIM signing for Zimbra OSE (FINAL: Handle existing selector)
# Usage: sudo bash zimbra-dkim-setup.sh

set -u

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
echo -e "${GREEN}  Zimbra DKIM Setup (OSE - Handle Existing Selector)${NC}"
echo -e "${GREEN}========================================================${NC}\n"

# ─────────────────────────────────────────────────────────────────────────────
# USER INPUT
# ─────────────────────────────────────────────────────────────────────────────
read -rp "Masukkan domain email (contoh: newbienotes.my.id): " DOMAIN
read -rp "Masukkan selector DKIM (contoh: mail, default: mail): " SELECTOR

SELECTOR=${SELECTOR:-mail}

[ -z "$DOMAIN" ] && { echo "Domain wajib diisi."; exit 1; }

log "Domain: $DOMAIN"
log "Selector: $SELECTOR"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Check existing DKIM keys
# ─────────────────────────────────────────────────────────────────────────────
log "1. Checking existing DKIM keys..."

EXISTING_DKIM=$(su - zimbra -c "/opt/zimbra/libexec/zmdkimkeyutil -q -d $DOMAIN" 2>&1)
echo "$EXISTING_DKIM" | tee -a /tmp/dkim_setup.log

if echo "$EXISTING_DKIM" | grep -qi "DKIM not configured\|no DKIM"; then
  log "   No existing DKIM found for $DOMAIN"
  ACTION="create"
else
  warn "   Existing DKIM found!"
  
  # Extract existing selectors
  EXISTING_SELECTORS=$(echo "$EXISTING_DKIM" | grep -A1 "DKIM Selector:" | tail -1 | tr -d ' ')
  
  if [ -n "$EXISTING_SELECTORS" ]; then
    echo ""
    echo -e "${YELLOW}   Existing selector(s):${NC}"
    echo "$EXISTING_SELECTORS" | while read sel; do
      [ -n "$sel" ] && echo "      - $sel"
    done
    echo ""
    
    # Check if requested selector already exists
    if echo "$EXISTING_SELECTORS" | grep -qw "$SELECTOR"; then
      warn "   ⚠️  Selector '$SELECTOR' ALREADY EXISTS!"
      echo ""
      echo "   Pilih tindakan:"
      echo "   1) Keep existing (skip - DNS records tetap sama)"
      echo "   2) Remove & regenerate (hapus lama, buat baru)"
      echo "   3) Cancel"
      echo ""
      read -rp "   Pilihan (1/2/3, default: 1): " USER_CHOICE
      USER_CHOICE=${USER_CHOICE:-1}
      
      case $USER_CHOICE in
        1)
          log "   Keeping existing selector '$SELECTOR'"
          ACTION="skip"
          ;;
        2)
          log "   Removing existing selector '$SELECTOR'..."
          su - zimbra -c "/opt/zimbra/libexec/zmdkimkeyutil -r -d $DOMAIN -s $SELECTOR" 2>&1 | tee -a /tmp/dkim_setup.log
          pass "   Removed selector: $SELECTOR"
          ACTION="create"
          ;;
        3)
          log "   Cancelled by user"
          exit 0
          ;;
        *)
          log "   Invalid choice, keeping existing"
          ACTION="skip"
          ;;
      esac
    else
      # Different selector exists, ask to remove
      echo ""
      read -rp "   Hapus DKIM yang lama dan buat selector baru? (y/n, default: n): " REMOVE_OLD
      REMOVE_OLD=${REMOVE_OLD:-n}
      
      if [ "$REMOVE_OLD" = "y" ] || [ "$REMOVE_OLD" = "Y" ]; then
        echo "$EXISTING_SELECTORS" | while read OLD_SELECTOR; do
          if [ -n "$OLD_SELECTOR" ]; then
            log "   Removing old selector: $OLD_SELECTOR"
            su - zimbra -c "/opt/zimbra/libexec/zmdkimkeyutil -r -d $DOMAIN -s $OLD_SELECTOR" 2>&1 | tee -a /tmp/dkim_setup.log
            pass "   Removed selector: $OLD_SELECTOR"
          fi
        done
        ACTION="create"
      else
        log "   Keeping existing DKIM, not creating new one"
        ACTION="skip"
      fi
    fi
  else
    warn "   Could not extract selector from output"
    ACTION="skip"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Generate DKIM Keys (if needed)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$ACTION" = "create" ]; then
  log "2. Generating DKIM keys with selector '$SELECTOR'..."
  
  DKIM_OUTPUT=$(su - zimbra -c "/opt/zimbra/libexec/zmdkimkeyutil -a -d $DOMAIN -s $SELECTOR" 2>&1)
  echo "$DKIM_OUTPUT" | tee -a /tmp/dkim_setup.log
  
  if echo "$DKIM_OUTPUT" | grep -q "DKIM Data added to LDAP"; then
    pass "DKIM keys generated successfully with selector: $SELECTOR"
  else
    fail "Failed to generate DKIM keys"
    exit 1
  fi
elif [ "$ACTION" = "skip" ]; then
  log "2. Skipping DKIM generation (using existing keys)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Query and Display Public Key
# ─────────────────────────────────────────────────────────────────────────────
log "3. Extracting public key for DNS record..."

DKIM_QUERY=$(su - zimbra -c "/opt/zimbra/libexec/zmdkimkeyutil -q -d $DOMAIN" 2>&1)

if echo "$DKIM_QUERY" | grep -q "$SELECTOR"; then
  pass "DKIM key found with selector: $SELECTOR"
  
  # Extract the public key from query output
  PUBLIC_KEY=$(echo "$DKIM_QUERY" | grep -A3 "DKIM Public signature:" | tail -3 | tr -d '\n' | sed 's/.*DKIM Public signature:[^p]*p=/v=DKIM1; k=rsa; p=/' | sed 's/ )  ;.*//' | sed 's/"//g')
  
  echo ""
  echo -e "${GREEN}=== COPY DNS RECORDS INI KE PROVIDER ANDA ===${NC}"
  echo ""
  
  SERVER_IP=$(hostname -I | awk '{print $1}')
  
  echo -e "${BLUE}1. SPF Record (TXT)${NC}"
  echo "   Host/Name: @ (atau ${DOMAIN})"
  echo "   Type: TXT"
  echo "   Value: v=spf1 mx ip4:$SERVER_IP -all"
  echo ""
  
  echo -e "${BLUE}2. DKIM Record (TXT)${NC}"
  echo "   Host/Name: ${SELECTOR}._domainkey.${DOMAIN}"
  echo "   Type: TXT"
  echo "   Value: $PUBLIC_KEY"
  echo ""
  
  echo -e "${BLUE}3. DMARC Record (TXT)${NC}"
  echo "   Host/Name: _dmarc.${DOMAIN}"
  echo "   Type: TXT"
  echo "   Value: v=DMARC1; p=quarantine; rua=mailto:dmarc@${DOMAIN}; pct=100"
  echo ""
  
  echo -e "${GREEN}========================================${NC}"
  echo -e "${YELLOW}⚠️  PENTING:${NC}"
  echo "   • Selector DKIM Anda: ${SELECTOR}"
  echo "   • DNS Host untuk DKIM: ${SELECTOR}._domainkey.${DOMAIN}"
  echo "   • Copy semua record di atas ke DNS provider"
  echo "   • Tunggu 5-60 menit untuk propagasi DNS"
  echo ""
else
  fail "DKIM key not found"
  echo ""
  echo "Debug info:"
  echo "$DKIM_QUERY"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Show Verification Instructions
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${GREEN}=== CARA VERIFIKASI (PAKAI EXTERNAL TOOLS) ===${NC}"
echo ""
echo "Setelah DNS propagate (tunggu 5-60 menit), verifikasi di:"
echo ""
echo "1. DKIM Checker (MXToolbox):"
echo "   https://mxtoolbox.com/dkim.aspx"
echo "   Masukkan: ${SELECTOR}._domainkey.${DOMAIN}"
echo ""
echo "2. SPF Checker:"
echo "   https://mxtoolbox.com/spf.aspx"
echo "   Masukkan: $DOMAIN"
echo ""
echo "3. DMARC Checker:"
echo "   https://mxtoolbox.com/dmarc.aspx"
echo "   Masukkan: $DOMAIN"
echo ""
echo "4. Mail Server Tester (All-in-One):"
echo "   https://www.mail-tester.com/"
echo "   Kirim email test dari server ke address yang diberikan"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  DKIM SETUP SELESAI${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Domain           : $DOMAIN"
echo -e "DKIM Selector    : $SELECTOR"
echo -e "DNS DKIM Host    : ${SELECTOR}._domainkey.${DOMAIN}"
echo -e "Status           : $([ "$ACTION" = "skip" ] && echo 'Using existing keys' || echo 'New keys generated')"
echo -e "Storage          : LDAP (no file created)"
echo -e "Log File         : /tmp/dkim_setup.log"
echo -e "${YELLOW}Langkah Selanjutnya:${NC}"
echo -e "1. Tambahkan SPF, DKIM, DMARC ke DNS provider"
echo -e "2. Tunggu DNS propagate (5-60 menit)"
echo -e "3. Verifikasi dengan external tools di atas"
echo -e "4. Setelah semua OK, lanjut ke STEP 3 (Security Hardening)"
echo -e "${GREEN}========================================================${NC}\n"
