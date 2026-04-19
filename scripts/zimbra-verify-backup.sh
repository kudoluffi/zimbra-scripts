#!/bin/bash
# zimbra-verify-backup.sh v1.1
# Verify Zimbra backup integrity with Telegram notification
# Usage: sudo bash zimbra-verify-backup.sh [BACKUP_DATE]

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

# ─────────────────────────────────────────────────────────────────────────────
# TELEGRAM CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
# Get from: https://t.me/BotFather (create bot)
# Get Chat ID from: https://t.me/userinfobot
# Or set via environment variables: export TG_BOT_TOKEN="xxx" TG_CHAT_ID="xxx"

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
TG_ENABLED="${TG_ENABLED:-true}"  # Set to "false" to disable

# ─────────────────────────────────────────────────────────────────────────────
# TELEGRAM FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
send_telegram() {
  local message="$1"
  local parse_mode="HTML"
  
  if [ "$TG_ENABLED" = "false" ] || [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    log "   Telegram notification disabled (set TG_BOT_TOKEN & TG_CHAT_ID to enable)"
    return 0
  fi
  
  # Send via Telegram API
  local response=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "text=${message}" \
    -d "parse_mode=${parse_mode}" \
    -d "disable_web_page_preview=true" \
    2>/dev/null)
  
  if echo "$response" | grep -q '"ok":true'; then
    log "   Telegram notification sent successfully"
    return 0
  else
    warn "   Failed to send Telegram notification: $response"
    return 1
  fi
}

send_telegram_backup_status() {
  local backup_date="$1"
  local pass_count="$2"
  local fail_count="$3"
  local warn_count="$4"
  local status="$5"  # PASSED, FAILED, WARNING
  local server_name="$6"
  
  # Emoji based on status
  local emoji="✅"
  if [ "$status" = "FAILED" ]; then
    emoji="❌"
  elif [ "$status" = "WARNING" ]; then
    emoji="⚠️"
  fi
  
  # Format message (HTML)
  local message="🔐 <b>Zimbra Backup Verification</b>
${emoji} Status: <b>${status}</b>

📅 Backup Date: <code>${backup_date}</code>
🖥️ Server: <code>${server_name}</code>

📊 Results:
✅ Passed: ${pass_count}
❌ Failed: ${fail_count}
⚠️ Warnings: ${warn_count}

$(if [ "$status" = "FAILED" ]; then
echo "🚨 <b>ACTION REQUIRED!</b> Backup verification failed!"
echo "Review logs and fix issues immediately."
elif [ "$status" = "WARNING" ]; then
echo "⚠️ <b>Review Recommended</b> Some warnings detected."
else
echo "✅ Backup is healthy and ready for disaster recovery."
fi)

📁 Backup Location: <code>/backup/zimbra/mailboxes/${backup_date}/</code>
📝 Log: <code>/var/log/zimbra-backup-${backup_date}.log</code>"

  send_telegram "$message"
}

# ─────────────────────────────────────────────────────────────────────────────
# GET BACKUP DATE
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_ROOT="/backup/zimbra"
SERVER_NAME=$(hostname -f)

if [ -n "${1:-}" ]; then
  BACKUP_DATE="$1"
else
  # Auto-detect latest backup
  BACKUP_DATE=$(ls -1 "$BACKUP_ROOT/mailboxes/" 2>/dev/null | grep -E "^[0-9]{8}$" | sort -r | head -1)
  
  if [ -z "$BACKUP_DATE" ]; then
    echo -e "\n${RED}No backup found!${NC}\n"
    echo "Usage: sudo bash zimbra-verify-backup.sh [BACKUP_DATE]"
    echo ""
    echo "Available backups:"
    ls -la "$BACKUP_ROOT/mailboxes/" 2>/dev/null | grep "^d" | awk '{print $9}' | grep -E "^[0-9]{8}$"
    
    # Send notification
    send_telegram_backup_status "NOT_FOUND" "0" "1" "0" "FAILED" "$SERVER_NAME"
    exit 1
  fi
  
  log "Auto-detected latest backup: $BACKUP_DATE"
fi

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra Backup Verification${NC}"
echo -e "${GREEN}========================================================${NC}\n"

log "Backup Date: $BACKUP_DATE"
log "Server: $SERVER_NAME"
log "Backup Root: $BACKUP_ROOT"
echo ""

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# ─────────────────────────────────────────────────────────────────────────────
# 1. CHECK BACKUP DIRECTORY EXISTS
# ─────────────────────────────────────────────────────────────────────────────
log "1. Checking backup directory..."

MAILBOX_DIR="$BACKUP_ROOT/mailboxes/$BACKUP_DATE"
if [ -d "$MAILBOX_DIR" ]; then
  pass "   Backup directory exists: $MAILBOX_DIR"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "   Backup directory NOT found: $MAILBOX_DIR"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo ""
  echo -e "${RED}❌ Backup verification FAILED - directory missing${NC}\n"
  send_telegram_backup_status "$BACKUP_DATE" "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "FAILED" "$SERVER_NAME"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. CHECK CONFIG FILES
# ─────────────────────────────────────────────────────────────────────────────
log "2. Checking configuration files..."

CONFIG_FILES=(
  "global-config-${BACKUP_DATE}.txt"
  "server-config-${BACKUP_DATE}.txt"
  "local-config-${BACKUP_DATE}.txt"
  "zimbra-version-${BACKUP_DATE}.txt"
)

CONFIG_OK=0
for file in "${CONFIG_FILES[@]}"; do
  FILE_PATH="$BACKUP_ROOT/config/$file"
  if [ -f "$FILE_PATH" ] && [ -s "$FILE_PATH" ]; then
    FILE_SIZE=$(du -h "$FILE_PATH" | cut -f1)
    CONFIG_OK=$((CONFIG_OK + 1))
  else
    warn "   Missing or empty: $file"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
done

if [ "$CONFIG_OK" -eq "${#CONFIG_FILES[@]}" ]; then
  pass "   All config files present ($CONFIG_OK files)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  fail "   Some config files missing ($CONFIG_OK/${#CONFIG_FILES[@]})"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. CHECK ACCOUNT LIST
# ─────────────────────────────────────────────────────────────────────────────
log "3. Checking account list..."

ACCOUNTS_FILE="$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt"
if [ -f "$ACCOUNTS_FILE" ] && [ -s "$ACCOUNTS_FILE" ]; then
  FIRST_LINE=$(head -1 "$ACCOUNTS_FILE")
  if echo "$FIRST_LINE" | grep -q "@"; then
    ACCOUNT_COUNT=$(wc -l < "$ACCOUNTS_FILE")
    pass "   Account list valid: $ACCOUNT_COUNT accounts"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "   Account list contains help menu instead of emails!"
    log "   First line: $FIRST_LINE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  fail "   Account list missing or empty"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. CHECK DISTRIBUTION LISTS
# ─────────────────────────────────────────────────────────────────────────────
log "4. Checking distribution lists..."

DL_FILE="$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt"
DOMAINS_FILE="$BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt"

DL_OK=0
if [ -f "$DL_FILE" ]; then
  DL_OK=$((DL_OK + 1))
fi
if [ -f "$DOMAINS_FILE" ]; then
  DL_OK=$((DL_OK + 1))
fi

if [ "$DL_OK" -eq 2 ]; then
  pass "   Distribution list files present"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  warn "   Some distribution list files missing ($DL_OK/2)"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. CHECK PASSWORD FILES
# ─────────────────────────────────────────────────────────────────────────────
log "5. Checking password hash files..."

PASSWORD_DIR="$BACKUP_ROOT/passwords/$BACKUP_DATE"
if [ -d "$PASSWORD_DIR" ]; then
  DIR_PERM=$(stat -c "%a" "$PASSWORD_DIR" 2>/dev/null)
  if [ "$DIR_PERM" = "700" ]; then
    pass "   Password directory permission correct (700)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    fail "   Password directory permission WRONG: $DIR_PERM (should be 700)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  
  PASS_FILES=$(ls "$PASSWORD_DIR"/*.shadow 2>/dev/null | wc -l)
  if [ "$PASS_FILES" -gt 0 ]; then
    pass "   Password hash files found: $PASS_FILES files"
    PASS_COUNT=$((PASS_COUNT + 1))
    
    PERM_OK=0
    PERM_FAIL=0
    for pfile in "$PASSWORD_DIR"/*.shadow; do
      if [ -f "$pfile" ]; then
        FILE_PERM=$(stat -c "%a" "$pfile" 2>/dev/null)
        if [ "$FILE_PERM" = "600" ]; then
          PERM_OK=$((PERM_OK + 1))
        else
          PERM_FAIL=$((PERM_FAIL + 1))
          warn "   Wrong permission on $(basename $pfile): $FILE_PERM (should be 600)"
        fi
      fi
    done
    
    if [ "$PERM_FAIL" -eq 0 ]; then
      pass "   All password file permissions correct (600)"
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      fail "   $PERM_FAIL password files with wrong permissions"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  else
    warn "   No password hash files found"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
else
  warn "   Password backup directory not found"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. CHECK MAILBOX BACKUPS
# ─────────────────────────────────────────────────────────────────────────────
log "6. Checking mailbox backups..."

TGZ_FILES=$(ls "$MAILBOX_DIR"/*.tgz 2>/dev/null | wc -l)
if [ "$TGZ_FILES" -gt 0 ]; then
  pass "   Mailbox backup files found: $TGZ_FILES files"
  PASS_COUNT=$((PASS_COUNT + 1))
  
  EMPTY_FILES=0
  for tgz in "$MAILBOX_DIR"/*.tgz; do
    if [ -f "$tgz" ] && [ ! -s "$tgz" ]; then
      EMPTY_FILES=$((EMPTY_FILES + 1))
      warn "   Empty mailbox backup: $(basename $tgz)"
    fi
  done
  
  if [ "$EMPTY_FILES" -eq 0 ]; then
    pass "   All mailbox backups have content"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    warn "   $EMPTY_FILES empty mailbox backup files"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
  
  BACKUP_SIZE=$(du -sh "$MAILBOX_DIR" 2>/dev/null | cut -f1)
  log "   Total mailbox backup size: $BACKUP_SIZE"
else
  warn "   No mailbox backup files found"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. CHECK USER PREFERENCES
# ─────────────────────────────────────────────────────────────────────────────
log "7. Checking user preferences..."

PREF_FILES=$(ls "$MAILBOX_DIR"/*-preferences.txt 2>/dev/null | wc -l)
if [ "$PREF_FILES" -gt 0 ]; then
  pass "   User preference files found: $PREF_FILES files"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  warn "   No user preference files found"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. CHECK BACKUP SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
log "8. Checking backup summary..."

SUMMARY_FILE="$MAILBOX_DIR/BACKUP-SUMMARY.txt"
if [ -f "$SUMMARY_FILE" ] && [ -s "$SUMMARY_FILE" ]; then
  pass "   Backup summary exists"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  warn "   Backup summary missing or empty"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 9. CHECK LOG FILE
# ─────────────────────────────────────────────────────────────────────────────
log "9. Checking backup log..."

LOG_FILE="/var/log/zimbra-backup-${BACKUP_DATE}.log"
LOG_FILE_BACKUP="$BACKUP_ROOT/logs/zimbra-backup-${BACKUP_DATE}.log"

if [ -f "$LOG_FILE" ] || [ -f "$LOG_FILE_BACKUP" ]; then
  pass "   Backup log exists"
  PASS_COUNT=$((PASS_COUNT + 1))
  
  ERROR_COUNT=$(grep -ci "fail\|error" "$LOG_FILE" 2>/dev/null || grep -ci "fail\|error" "$LOG_FILE_BACKUP" 2>/dev/null || echo "0")
  if [ "$ERROR_COUNT" -gt 0 ]; then
    warn "   Log contains $ERROR_COUNT error/fail entries"
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
else
  warn "   Backup log not found"
  WARN_COUNT=$((WARN_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# 10. CHECK BACKUP AGE
# ─────────────────────────────────────────────────────────────────────────────
log "10. Checking backup age..."

BACKUP_EPOCH=$(date -d "$BACKUP_DATE" +%s 2>/dev/null || echo "0")
NOW_EPOCH=$(date +%s)
AGE_DAYS=$(( (NOW_EPOCH - BACKUP_EPOCH) / 86400 ))

if [ "$AGE_DAYS" -lt 1 ]; then
  pass "   Backup is fresh (< 1 day old)"
  PASS_COUNT=$((PASS_COUNT + 1))
elif [ "$AGE_DAYS" -lt 2 ]; then
  log "   Backup is $AGE_DAYS day(s) old"
  PASS_COUNT=$((PASS_COUNT + 1))
elif [ "$AGE_DAYS" -lt 7 ]; then
  warn "   Backup is $AGE_DAYS days old"
  WARN_COUNT=$((WARN_COUNT + 1))
else
  fail "   Backup is $AGE_DAYS days old (TOO OLD!)"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  VERIFICATION SUMMARY${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Backup Date : ${BLUE}$BACKUP_DATE${NC}"
echo -e "Passed      : ${GREEN}$PASS_COUNT${NC}"
echo -e "Failed      : ${RED}$FAIL_COUNT${NC}"
echo -e "Warnings    : ${YELLOW}$WARN_COUNT${NC}"
echo -e "${GREEN}========================================================${NC}"
echo ""

# Determine status
if [ "$FAIL_COUNT" -eq 0 ]; then
  if [ "$WARN_COUNT" -eq 0 ]; then
    STATUS="PASSED"
    echo -e "${GREEN}✅ BACKUP VERIFICATION PASSED${NC}\n"
    EXIT_CODE=0
  else
    STATUS="WARNING"
    echo -e "${YELLOW}⚠️  BACKUP VERIFICATION PASSED WITH WARNINGS${NC}\n"
    EXIT_CODE=0
  fi
else
  STATUS="FAILED"
  echo -e "${RED}❌ BACKUP VERIFICATION FAILED${NC}\n"
  EXIT_CODE=1
fi

# Send Telegram notification
log "Sending Telegram notification..."
send_telegram_backup_status "$BACKUP_DATE" "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$STATUS" "$SERVER_NAME"

exit $EXIT_CODE
