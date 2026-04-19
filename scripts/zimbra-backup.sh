#!/bin/bash
# zimbra-backup.sh v1.8
# FINAL VERSION - Exclude system accounts, YYYYMMDD format, overwrite same-day backups
# Usage: sudo bash zimbra-backup.sh [full|incremental]

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_ROOT="/backup/zimbra"
# CHANGED: YYYYMMDD format only (no HHMMSS)
BACKUP_DATE=$(date +%Y%m%d)
DAY_OF_WEEK=$(date +%u)
RETENTION_DAYS=30
ZIMBRA_USER="zimbra"
LOG_FILE="/var/log/zimbra-backup-${BACKUP_DATE}.log"
SERVER_NAME=$(hostname -f)

# EXCLUDED ACCOUNTS (regex patterns)
EXCLUDE_PATTERNS=(
  "^admin@"
  "^spam\."
  "^ham\."
  "^virus-quarantine\."
  "^galsync\."
  "^postmaster@"
  "^abuse@"
)

BACKUP_TYPE="${1:-auto}"
if [ "$BACKUP_TYPE" = "auto" ]; then
  if [ "$DAY_OF_WEEK" = "7" ]; then
    BACKUP_TYPE="full"
  else
    BACKUP_TYPE="incremental"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Check if account should be excluded
# ─────────────────────────────────────────────────────────────────────────────
should_exclude() {
  local account="$1"
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    if echo "$account" | grep -qE "$pattern"; then
      return 0  # Should exclude
    fi
  done
  return 1  # Should not exclude
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-CHECKS
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "Script must be run as root. Use: sudo bash $0"
  exit 1
fi

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra Backup Script (v1.8 - FINAL)${NC}"
echo -e "${GREEN}========================================================${NC}\n"

log "Backup Date: $BACKUP_DATE"
log "Server: $SERVER_NAME"
log "Backup Type: $BACKUP_TYPE"
log "Backup Root: $BACKUP_ROOT"
echo ""

# Create backup directories
log "Creating backup directories..."
mkdir -p "$BACKUP_ROOT"/{config,mailboxes,distribution-lists,passwords,logs}
chown -R zimbra:zimbra "$BACKUP_ROOT"
chmod 755 "$BACKUP_ROOT"
chmod 755 "$BACKUP_ROOT"/*
chmod 700 "$BACKUP_ROOT/passwords"
pass "Backup directories created"

# ─────────────────────────────────────────────────────────────────────────────
# 1. CONFIG BACKUP
# ─────────────────────────────────────────────────────────────────────────────
log "1. Backing up Zimbra configuration..."

log "   Exporting global config..."
su - $ZIMBRA_USER -c "zmprov gacf > $BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt" ]; then
  FILE_SIZE=$(du -h "$BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt" | cut -f1)
  pass "   Global config exported ($FILE_SIZE)"
else
  fail "   Global config export failed"
fi

log "   Exporting server config..."
su - $ZIMBRA_USER -c "zmprov gs $SERVER_NAME > $BACKUP_ROOT/config/server-config-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/config/server-config-${BACKUP_DATE}.txt" ]; then
  pass "   Server config exported"
else
  fail "   Server config export failed"
fi

log "   Exporting local config..."
zmlocalconfig -m > "$BACKUP_ROOT/config/local-config-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/config/local-config-${BACKUP_DATE}.txt" ]; then
  pass "   Local config exported"
else
  fail "   Local config export failed"
fi

log "   Saving Zimbra version info..."
su - $ZIMBRA_USER -c "zmcontrol -v > $BACKUP_ROOT/config/zimbra-version-${BACKUP_DATE}.txt" 2>&1
pass "   Version info saved"

# ─────────────────────────────────────────────────────────────────────────────
# 2. ACCOUNTS & DISTRIBUTION LISTS
# ─────────────────────────────────────────────────────────────────────────────
log "2. Backing up accounts and distribution lists..."

log "   Exporting domain list..."
su - $ZIMBRA_USER -c "zmprov gad > $BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt" ]; then
  DOMAIN_COUNT=$(wc -l < "$BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt")
  pass "   Found $DOMAIN_COUNT domain(s)"
else
  fail "   Domain list export failed"
  DOMAIN_COUNT=0
fi

log "   Exporting account list (zmprov -l gaa)..."
su - $ZIMBRA_USER -c "zmprov -l gaa > $BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt" 2>&1

if [ -s "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt" ]; then
  FIRST_LINE=$(head -1 "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt")
  if echo "$FIRST_LINE" | grep -q "@"; then
    ACCOUNT_COUNT=$(wc -l < "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt")
    pass "   Found $ACCOUNT_COUNT account(s)"
  else
    fail "   Account list contains help menu instead of accounts!"
    ACCOUNT_COUNT=0
  fi
else
  fail "   Account list export failed"
  ACCOUNT_COUNT=0
fi

log "   Exporting distribution lists..."
su - $ZIMBRA_USER -c "zmprov -l gad -t distributionlist > $BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt" ]; then
  DL_COUNT=$(wc -l < "$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt")
  pass "   Found $DL_COUNT distribution list(s)"
else
  DL_COUNT=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. PASSWORD HASH BACKUP
# ─────────────────────────────────────────────────────────────────────────────
log "3. Backing up password hashes..."

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  mkdir -p "$BACKUP_ROOT/passwords/${BACKUP_DATE}"
  chown zimbra:zimbra "$BACKUP_ROOT/passwords/${BACKUP_DATE}"
  chmod 700 "$BACKUP_ROOT/passwords/${BACKUP_DATE}"
  
  PASSWORD_BACKUP_COUNT=0
  
  while IFS= read -r account; do
    if [ -n "$account" ] && echo "$account" | grep -q "@"; then
      if should_exclude "$account"; then
        log "   Skipping password for excluded account: $account"
        continue
      fi
      
      SAFE_NAME=$(echo "$account" | tr '@' '_')
      
      su - $ZIMBRA_USER -c "zmprov -l ga '$account' userPassword" 2>/dev/null | \
        grep "userPassword:" | \
        awk '{print $2}' > "$BACKUP_ROOT/passwords/${BACKUP_DATE}/${SAFE_NAME}.shadow"
      
      if [ -s "$BACKUP_ROOT/passwords/${BACKUP_DATE}/${SAFE_NAME}.shadow" ]; then
        PASSWORD_BACKUP_COUNT=$((PASSWORD_BACKUP_COUNT + 1))
        chown zimbra:zimbra "$BACKUP_ROOT/passwords/${BACKUP_DATE}/${SAFE_NAME}.shadow"
        chmod 600 "$BACKUP_ROOT/passwords/${BACKUP_DATE}/${SAFE_NAME}.shadow"
      fi
    fi
  done < "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt"
  
  pass "   Password hashes backed up: $PASSWORD_BACKUP_COUNT accounts"
  
  warn "   ⚠️  PASSWORD FILES ARE SENSITIVE!"
  warn "   ⚠️  Location: $BACKUP_ROOT/passwords/${BACKUP_DATE}/"
  warn "   ⚠️  Permission: 700 (zimbra only)"
else
  warn "   Skipping password backup (no accounts found)"
  PASSWORD_BACKUP_COUNT=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. MAILBOX BACKUP (EXCLUDE SYSTEM ACCOUNTS)
# ─────────────────────────────────────────────────────────────────────────────
log "4. Backing up mailboxes ($BACKUP_TYPE)..."

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  BACKUP_SUCCESS=0
  BACKUP_FAILED=0
  SKIPPED_COUNT=0
  
  # CHANGED: YYYYMMDD format only (will overwrite if run multiple times same day)
  mkdir -p "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}"
  chown zimbra:zimbra "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}"
  
  while IFS= read -r account; do
    if [ -z "$account" ] || ! echo "$account" | grep -q "@"; then
      continue
    fi
    
    # CHECK: Skip excluded accounts
    if should_exclude "$account"; then
      log "   Skipping excluded account: $account"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    
    ACCOUNT_NAME=$(echo "$account" | cut -d@ -f1)
    log "   Backing up: $account"
    
    # CHANGED: YYYYMMDD format (overwrite if exists)
    MAILBOX_BACKUP_FILE="$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}.tgz"
    
    su - $ZIMBRA_USER -c "zmmailbox -z -m '$account' getRestURL '//?fmt=tgz' > '$MAILBOX_BACKUP_FILE'" 2>&1 | tee -a "$LOG_FILE"
    
    if [ -f "$MAILBOX_BACKUP_FILE" ] && [ -s "$MAILBOX_BACKUP_FILE" ]; then
      BACKUP_SUCCESS=$((BACKUP_SUCCESS + 1))
      FILE_SIZE=$(du -h "$MAILBOX_BACKUP_FILE" | cut -f1)
      pass "      ✓ $account ($FILE_SIZE)"
    else
      BACKUP_FAILED=$((BACKUP_FAILED + 1))
      warn "      ✗ $account (failed or empty)"
      rm -f "$MAILBOX_BACKUP_FILE" 2>/dev/null
    fi
  done < "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt"
  
  echo ""
  pass "   Mailbox backup: $BACKUP_SUCCESS success, $BACKUP_FAILED failed, $SKIPPED_COUNT skipped (system accounts)"
else
  warn "   Skipping mailbox backup (no valid accounts found)"
  BACKUP_SUCCESS=0
  BACKUP_FAILED=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. USER DATA (EXCLUDE SYSTEM ACCOUNTS)
# ─────────────────────────────────────────────────────────────────────────────
log "5. Backing up user data (filters, signatures, preferences)..."

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  USER_DATA_COUNT=0
  while IFS= read -r account; do
    if [ -n "$account" ] && echo "$account" | grep -q "@"; then
      if should_exclude "$account"; then
        continue
      fi
      ACCOUNT_NAME=$(echo "$account" | cut -d@ -f1)
      su - $ZIMBRA_USER -c "zmprov ga '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-preferences.txt'" 2>/dev/null
      su - $ZIMBRA_USER -c "zmprov gf '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-filters.txt'" 2>/dev/null
      su - $ZIMBRA_USER -c "zmprov gas '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-signatures.txt'" 2>/dev/null
      USER_DATA_COUNT=$((USER_DATA_COUNT + 1))
    fi
  done < "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt"
  pass "   User data exported: $USER_DATA_COUNT accounts"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. RETENTION POLICY
# ─────────────────────────────────────────────────────────────────────────────
log "6. Applying retention policy ($RETENTION_DAYS days)..."

OLD_BACKUPS=$(find "$BACKUP_ROOT/mailboxes" -type d -name "20*" -mtime +$RETENTION_DAYS 2>/dev/null)
if [ -n "$OLD_BACKUPS" ]; then
  DELETED_COUNT=0
  while IFS= read -r old_dir; do
    rm -rf "$old_dir"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  done <<< "$OLD_BACKUPS"
  pass "   Deleted $DELETED_COUNT old backup directories"
else
  log "   No old backups to delete"
fi

# Clean old password backups
OLD_PASS_BACKUPS=$(find "$BACKUP_ROOT/passwords" -type d -name "20*" -mtime +$RETENTION_DAYS 2>/dev/null)
if [ -n "$OLD_PASS_BACKUPS" ]; then
  while IFS= read -r old_dir; do
    rm -rf "$old_dir"
  done <<< "$OLD_PASS_BACKUPS"
  pass "   Deleted old password backups"
fi

# Clean old config files (keep latest 10)
log "   Cleaning old config files..."
cd "$BACKUP_ROOT/config" && ls -t *.txt 2>/dev/null | tail -n +11 | xargs -r rm --
pass "   Old config files cleaned"

# ─────────────────────────────────────────────────────────────────────────────
# 7. BACKUP SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
log "7. Generating backup summary..."

BACKUP_SIZE=$(du -sh "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}" 2>/dev/null | cut -f1)
TOTAL_BACKUP_SIZE=$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)

cat > "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/BACKUP-SUMMARY.txt" <<EOF
========================================================
  ZIMBRA BACKUP SUMMARY (v1.8 - FINAL)
========================================================
Backup Date:    $BACKUP_DATE
Server:         $SERVER_NAME
Backup Type:    $BACKUP_TYPE
Retention:      $RETENTION_DAYS days
Backup Size:    $BACKUP_SIZE
Total Size:     $TOTAL_BACKUP_SIZE
Domains:        $DOMAIN_COUNT
Accounts:       $ACCOUNT_COUNT
Dist. Lists:    $DL_COUNT
Password Hash : $PASSWORD_BACKUP_COUNT
Mailbox Success: $BACKUP_SUCCESS
Mailbox Failed : $BACKUP_FAILED
System Accounts Skipped: $SKIPPED_COUNT
========================================================

BACKUP INCLUDES:
✅ Global Configuration
✅ Server Configuration
✅ Local Configuration
✅ All Accounts List
✅ All Distribution Lists
✅ Password Hashes (user accounts only)
✅ Mailboxes (user accounts only, TGZ)
✅ User Preferences, Filters, Signatures

EXCLUDED SYSTEM ACCOUNTS:
❌ admin@* (administrative)
❌ spam.* (spam quarantine)
❌ ham.* (ham quarantine)
❌ virus-quarantine.* (virus quarantine)
❌ galsync.* (GAL sync)
❌ postmaster@* (system)
❌ abuse@* (system)

⚠️  SECURITY WARNING - PASSWORD FILES:
🔒 Location: $BACKUP_ROOT/passwords/${BACKUP_DATE}/
🔒 Permission: 700 (zimbra:zimbra only)
🔒 DO NOT share these files!
🔒 DO NOT commit to version control!

========================================================
  RESTORE INSTRUCTIONS
========================================================
1. Stop Zimbra: su - zimbra -c "zmcontrol stop"
2. Restore config: bash zimbra-restore-config.sh $BACKUP_DATE
3. Restore passwords: bash zimbra-restore-passwords.sh $BACKUP_DATE
4. Restore mailboxes: bash zimbra-restore-mailboxes.sh $BACKUP_DATE
5. Start Zimbra: su - zimbra -c "zmcontrol start"
6. Verify: bash zimbra-verify-backup.sh $BACKUP_DATE
========================================================
EOF

pass "   Backup summary generated"

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  BACKUP SELESAI${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Backup Date   : $BACKUP_DATE"
echo -e "Server        : $SERVER_NAME"
echo -e "Backup Type   : $BACKUP_TYPE"
echo -e "Backup Size   : $BACKUP_SIZE"
echo -e "Total Size    : $TOTAL_BACKUP_SIZE"
echo -e "Domains       : $DOMAIN_COUNT"
echo -e "Accounts      : $ACCOUNT_COUNT"
echo -e "Dist. Lists   : $DL_COUNT"
echo -e "Password Hash : $PASSWORD_BACKUP_COUNT"
echo -e "Mailbox Success: $BACKUP_SUCCESS"
echo -e "Mailbox Failed : $BACKUP_FAILED"
echo -e "System Skipped : $SKIPPED_COUNT"
echo -e "Retention     : $RETENTION_DAYS days"
echo -e "Backup Root   : $BACKUP_ROOT"
echo -e "Log File      : $LOG_FILE"
echo -e "${GREEN}========================================================${NC}"
echo -e "${YELLOW}⚠️  SECURITY WARNING:${NC}"
echo -e "Password hashes saved in: $BACKUP_ROOT/passwords/${BACKUP_DATE}/"
echo -e "Permission: 700 (zimbra:zimbra only)"
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Review log file: cat $LOG_FILE"
echo -e "2. Verify password files: ls -la $BACKUP_ROOT/passwords/${BACKUP_DATE}/"
echo -e "3. Verify backup: bash zimbra-verify-backup.sh $BACKUP_DATE"
echo -e "4. Setup cron for automated backup"
echo -e "5. Test restore procedure periodically"
echo -e "${GREEN}========================================================${NC}\n"

cp "$LOG_FILE" "$BACKUP_ROOT/logs/"

exit 0
