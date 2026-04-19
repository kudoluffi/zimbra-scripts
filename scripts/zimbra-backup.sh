#!/bin/bash
# zimbra-backup.sh v1.0
# Automated backup script for Zimbra 10.1.x OSE
# Features: Weekly full + Daily incremental, 30-day retention
# Tested on: Ubuntu 22.04 LTS + Zimbra 10.1.x OSE
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
BACKUP_DATE=$(date +%Y%m%d-%H%M%S)
DAY_OF_WEEK=$(date +%u)  # 1=Monday, 7=Sunday
RETENTION_DAYS=30
ZIMBRA_USER="zimbra"
LOG_FILE="/var/log/zimbra-backup-${BACKUP_DATE}.log"

# Determine backup type
BACKUP_TYPE="${1:-auto}"
if [ "$BACKUP_TYPE" = "auto" ]; then
  # Sunday = full backup, other days = incremental
  if [ "$DAY_OF_WEEK" = "7" ]; then
    BACKUP_TYPE="full"
  else
    BACKUP_TYPE="incremental"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PRE-CHECKS
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "Script must be run as root. Use: sudo bash $0"
  exit 1
fi

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra Backup Script${NC}"
echo -e "${GREEN}========================================================${NC}\n"

log "Backup Date: $BACKUP_DATE"
log "Backup Type: $BACKUP_TYPE"
log "Retention: $RETENTION_DAYS days"
log "Backup Root: $BACKUP_ROOT"
log "Log File: $LOG_FILE"
echo ""

# Check Zimbra status
log "Checking Zimbra status..."
if ! su - $ZIMBRA_USER -c "zmcontrol status" &>/dev/null; then
  warn "Zimbra may not be running. Some backup operations may fail."
  read -rp "Continue anyway? (y/n, default: n): " CONTINUE
  if [ "${CONTINUE:-n}" != "y" ]; then
    exit 1
  fi
else
  pass "Zimbra is running"
fi

# Create backup directories
log "Creating backup directories..."
mkdir -p "$BACKUP_ROOT"/{config,mailboxes,distribution-lists,logs}
mkdir -p "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}"
pass "Backup directories created"

# ─────────────────────────────────────────────────────────────────────────────
# 1. CONFIG BACKUP (LDAP + Local Config)
# ─────────────────────────────────────────────────────────────────────────────
log "1. Backing up Zimbra configuration..."

# LDAP configuration
log "   Exporting LDAP configuration..."
su - $ZIMBRA_USER -c "zmprov -l > $BACKUP_ROOT/config/ldap-config-${BACKUP_DATE}.txt" 2>&1 | tee -a "$LOG_FILE"
if [ $? -eq 0 ]; then
  pass "   LDAP config exported"
else
  warn "   LDAP config export may have issues"
fi

# Local configuration
log "   Exporting local configuration..."
zmlocalconfig -m > "$BACKUP_ROOT/config/local-config-${BACKUP_DATE}.txt" 2>&1 | tee -a "$LOG_FILE"
if [ $? -eq 0 ]; then
  pass "   Local config exported"
else
  warn "   Local config export may have issues"
fi

# Zimbra version info
log "   Saving Zimbra version info..."
su - $ZIMBRA_USER -c "zmcontrol -v > $BACKUP_ROOT/config/zimbra-version-${BACKUP_DATE}.txt" 2>&1 | tee -a "$LOG_FILE"
su - $ZIMBRA_USER -c "zmprov -v >> $BACKUP_ROOT/config/zimbra-version-${BACKUP_DATE}.txt" 2>&1 | tee -a "$LOG_FILE"
pass "   Version info saved"

# ─────────────────────────────────────────────────────────────────────────────
# 2. ACCOUNTS & DISTRIBUTION LISTS
# ─────────────────────────────────────────────────────────────────────────────
log "2. Backing up accounts and distribution lists..."

# List all accounts
log "   Exporting account list..."
su - $ZIMBRA_USER -c "zmprov gaa > $BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt" 2>&1 | tee -a "$LOG_FILE"
ACCOUNT_COUNT=$(wc -l < "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt")
pass "   Found $ACCOUNT_COUNT accounts"

# List all distribution lists
log "   Exporting distribution lists..."
su - $ZIMBRA_USER -c "zmprov gad > $BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt" 2>&1 | tee -a "$LOG_FILE"
DL_COUNT=$(su - $ZIMBRA_USER -c "zmprov gad" 2>/dev/null | wc -l)
pass "   Found $DL_COUNT distribution lists"

# Export DL members
log "   Exporting distribution list members..."
while IFS= read -r dl; do
  if [ -n "$dl" ]; then
    su - $ZIMBRA_USER -c "zmprov gdl '$dl' > '$BACKUP_ROOT/distribution-lists/dl-members-${dl//\//_}-${BACKUP_DATE}.txt'" 2>/dev/null
  fi
done < "$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt"
pass "   DL members exported"

# ─────────────────────────────────────────────────────────────────────────────
# 3. MAILBOX BACKUP
# ─────────────────────────────────────────────────────────────────────────────
log "3. Backing up mailboxes ($BACKUP_TYPE)..."

# Get all account emails
ACCOUNTS=$(su - $ZIMBRA_USER -c "zmprov gaa" 2>/dev/null)

if [ -z "$ACCOUNTS" ]; then
  warn "   No accounts found for mailbox backup"
else
  BACKUP_SUCCESS=0
  BACKUP_FAILED=0
  
  while IFS= read -r account; do
    if [ -n "$account" ]; then
      ACCOUNT_NAME=$(echo "$account" | cut -d@ -f1)
      ACCOUNT_DOMAIN=$(echo "$account" | cut -d@ -f2)
      
      log "   Backing up: $account"
      
      if [ "$BACKUP_TYPE" = "full" ]; then
        # Full backup
        su - $ZIMBRA_USER -c "zmbackup -f '$account' -p '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/$ACCOUNT_NAME'" 2>&1 | tee -a "$LOG_FILE"
      else
        # Incremental backup
        su - $ZIMBRA_USER -c "zmbackup -i '$account' -p '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/$ACCOUNT_NAME'" 2>&1 | tee -a "$LOG_FILE"
      fi
      
      if [ $? -eq 0 ]; then
        BACKUP_SUCCESS=$((BACKUP_SUCCESS + 1))
        pass "      ✓ $account"
      else
        BACKUP_FAILED=$((BACKUP_FAILED + 1))
        warn "      ✗ $account (failed)"
      fi
    fi
  done <<< "$ACCOUNTS"
  
  echo ""
  pass "   Mailbox backup complete: $BACKUP_SUCCESS success, $BACKUP_FAILED failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. USER DATA (Filters, Signatures, Preferences)
# ─────────────────────────────────────────────────────────────────────────────
log "4. Backing up user data (filters, signatures, preferences)..."

while IFS= read -r account; do
  if [ -n "$account" ]; then
    ACCOUNT_NAME=$(echo "$account" | cut -d@ -f1)
    
    # Export user preferences
    su - $ZIMBRA_USER -c "zmprov ga '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-preferences.txt'" 2>/dev/null
    
    # Export filters (if any)
    su - $ZIMBRA_USER -c "zmprov gf '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-filters.txt'" 2>/dev/null
    
    # Export signatures (if any)
    su - $ZIMBRA_USER -c "zmprov gas '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-signatures.txt'" 2>/dev/null
  fi
done <<< "$ACCOUNTS"

pass "   User data exported"

# ─────────────────────────────────────────────────────────────────────────────
# 5. RETENTION POLICY (Delete Old Backups)
# ─────────────────────────────────────────────────────────────────────────────
log "5. Applying retention policy ($RETENTION_DAYS days)..."

OLD_BACKUPS=$(find "$BACKUP_ROOT/mailboxes" -type d -name "20*" -mtime +$RETENTION_DAYS 2>/dev/null)
if [ -n "$OLD_BACKUPS" ]; then
  DELETED_COUNT=0
  while IFS= read -r old_dir; do
    if [ -d "$old_dir" ]; then
      rm -rf "$old_dir"
      DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
  done <<< "$OLD_BACKUPS"
  pass "   Deleted $DELETED_COUNT old backup directories"
else
  log "   No old backups to delete"
fi

# Also clean old config files (keep only latest 10)
log "   Cleaning old config files..."
cd "$BACKUP_ROOT/config" && ls -t ldap-config-*.txt 2>/dev/null | tail -n +11 | xargs -r rm --
cd "$BACKUP_ROOT/config" && ls -t local-config-*.txt 2>/dev/null | tail -n +11 | xargs -r rm --
pass "   Old config files cleaned"

# ─────────────────────────────────────────────────────────────────────────────
# 6. BACKUP SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
log "6. Generating backup summary..."

BACKUP_SIZE=$(du -sh "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}" 2>/dev/null | cut -f1)
TOTAL_BACKUP_SIZE=$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)

cat > "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/BACKUP-SUMMARY.txt" <<EOF
========================================================
  ZIMBRA BACKUP SUMMARY
========================================================
Backup Date:    $BACKUP_DATE
Backup Type:    $BACKUP_TYPE
Retention:      $RETENTION_DAYS days
Backup Size:    $BACKUP_SIZE
Total Size:     $TOTAL_BACKUP_SIZE
Accounts:       $ACCOUNT_COUNT
Dist. Lists:    $DL_COUNT
Success:        $BACKUP_SUCCESS
Failed:         $BACKUP_FAILED
========================================================

Backup Location: $BACKUP_ROOT
Log File: $LOG_FILE

Files Included:
- LDAP Configuration
- Local Configuration
- Zimbra Version Info
- All Accounts List
- All Distribution Lists
- DL Members
- Mailboxes ($BACKUP_TYPE)
- User Preferences
- User Filters
- User Signatures

========================================================
  RESTORE INSTRUCTIONS
========================================================
1. Stop Zimbra: su - zimbra -c "zmcontrol stop"
2. Run restore script: bash zimbra-restore.sh $BACKUP_DATE
3. Start Zimbra: su - zimbra -c "zmcontrol start"
4. Verify: bash zimbra-verify-backup.sh $BACKUP_DATE
========================================================
EOF

pass "   Backup summary generated"

# ─────────────────────────────────────────────────────────────────────────────
# 7. FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  BACKUP SELESAI${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Backup Date   : $BACKUP_DATE"
echo -e "Backup Type   : $BACKUP_TYPE"
echo -e "Backup Size   : $BACKUP_SIZE"
echo -e "Total Size    : $TOTAL_BACKUP_SIZE"
echo -e "Accounts      : $ACCOUNT_COUNT"
echo -e "Dist. Lists   : $DL_COUNT"
echo -e "Success       : $BACKUP_SUCCESS"
echo -e "Failed        : $BACKUP_FAILED"
echo -e "Retention     : $RETENTION_DAYS days"
echo -e "Backup Root   : $BACKUP_ROOT"
echo -e "Log File      : $LOG_FILE"
echo -e "${GREEN}========================================================${NC}"
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Review log file: cat $LOG_FILE"
echo -e "2. Verify backup: bash zimbra-verify-backup.sh $BACKUP_DATE"
echo -e "3. Setup cron for automated backup (see docs)"
echo -e "4. Test restore procedure periodically"
echo -e "${GREEN}========================================================${NC}\n"

# Copy log to backup directory
cp "$LOG_FILE" "$BACKUP_ROOT/logs/"

exit 0
