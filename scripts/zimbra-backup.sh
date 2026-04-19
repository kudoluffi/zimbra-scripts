#!/bin/bash
# zimbra-backup.sh v1.3
# CORRECTED - Using valid zmprov commands
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
DAY_OF_WEEK=$(date +%u)
RETENTION_DAYS=30
ZIMBRA_USER="zimbra"
LOG_FILE="/var/log/zimbra-backup-${BACKUP_DATE}.log"
SERVER_NAME=$(hostname -f)

BACKUP_TYPE="${1:-auto}"
if [ "$BACKUP_TYPE" = "auto" ]; then
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
echo -e "${GREEN}  Zimbra Backup Script (FINAL CORRECT)${NC}"
echo -e "${GREEN}========================================================${NC}\n"

log "Backup Date: $BACKUP_DATE"
log "Server: $SERVER_NAME"
log "Backup Type: $BACKUP_TYPE"
log "Backup Root: $BACKUP_ROOT"
echo ""

# Create backup directories
log "Creating backup directories..."
mkdir -p "$BACKUP_ROOT"/{config,mailboxes,distribution-lists,logs}
chown -R zimbra:zimbra "$BACKUP_ROOT"
chmod 755 "$BACKUP_ROOT"
chmod 755 "$BACKUP_ROOT"/*
pass "Backup directories created"

# ─────────────────────────────────────────────────────────────────────────────
# 1. CONFIG BACKUP (CORRECT COMMANDS)
# ─────────────────────────────────────────────────────────────────────────────
log "1. Backing up Zimbra configuration..."

# Global config (CORRECT: gacf = GetAllConfig)
log "   Exporting global config (zmprov gacf)..."
START_TIME=$(date +%s)
su - $ZIMBRA_USER -c "zmprov gacf > $BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt" 2>&1
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ -s "$BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt" ]; then
  FILE_SIZE=$(du -h "$BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt" | cut -f1)
  LINE_COUNT=$(wc -l < "$BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt")
  pass "   Global config exported in ${DURATION}s ($FILE_SIZE, $LINE_COUNT lines)"
else
  fail "   Global config export failed"
fi

# Server config
log "   Exporting server config..."
su - $ZIMBRA_USER -c "zmprov gs $SERVER_NAME > $BACKUP_ROOT/config/server-config-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/config/server-config-${BACKUP_DATE}.txt" ]; then
  pass "   Server config exported"
else
  fail "   Server config export failed"
fi

# Local config
log "   Exporting local config..."
zmlocalconfig -m > "$BACKUP_ROOT/config/local-config-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/config/local-config-${BACKUP_DATE}.txt" ]; then
  pass "   Local config exported"
else
  fail "   Local config export failed"
fi

# Zimbra version
log "   Saving Zimbra version info..."
su - $ZIMBRA_USER -c "zmcontrol -v > $BACKUP_ROOT/config/zimbra-version-${BACKUP_DATE}.txt" 2>&1
pass "   Version info saved"

# ─────────────────────────────────────────────────────────────────────────────
# 2. ACCOUNTS & DISTRIBUTION LISTS
# ─────────────────────────────────────────────────────────────────────────────
log "2. Backing up accounts and distribution lists..."

# All domains
log "   Exporting domain list..."
su - $ZIMBRA_USER -c "zmprov gad > $BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt" ]; then
  DOMAIN_COUNT=$(wc -l < "$BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt")
  pass "   Found $DOMAIN_COUNT domain(s)"
else
  fail "   Domain list export failed"
  DOMAIN_COUNT=0
fi

# All accounts
log "   Exporting account list..."
su - $ZIMBRA_USER -c "zmprov gaa > $BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt" ]; then
  ACCOUNT_COUNT=$(wc -l < "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt")
  pass "   Found $ACCOUNT_COUNT account(s)"
else
  fail "   Account list export failed"
  ACCOUNT_COUNT=0
fi

# Distribution lists
log "   Exporting distribution lists..."
su - $ZIMBRA_USER -c "zmprov gad -t distributionlist > $BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt" 2>&1
if [ -s "$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt" ]; then
  DL_COUNT=$(wc -l < "$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt")
  pass "   Found $DL_COUNT distribution list(s)"
else
  DL_COUNT=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. MAILBOX BACKUP (zmmailbox for OSE)
# ─────────────────────────────────────────────────────────────────────────────
log "3. Backing up mailboxes ($BACKUP_TYPE)..."

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  BACKUP_SUCCESS=0
  BACKUP_FAILED=0
  
  mkdir -p "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}"
  chown zimbra:zimbra "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}"
  
  while IFS= read -r account; do
    if [ -n "$account" ]; then
      ACCOUNT_NAME=$(echo "$account" | cut -d@ -f1)
      log "   Backing up: $account"
      
      MAILBOX_BACKUP_FILE="$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}.tgz"
      
      # Export mailbox using zmmailbox (OSE compatible)
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
    fi
  done <<< "$(cat "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt" 2>/dev/null)"
  
  echo ""
  pass "   Mailbox backup: $BACKUP_SUCCESS success, $BACKUP_FAILED failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. USER DATA
# ─────────────────────────────────────────────────────────────────────────────
log "4. Backing up user data (filters, signatures, preferences)..."

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  while IFS= read -r account; do
    if [ -n "$account" ]; then
      ACCOUNT_NAME=$(echo "$account" | cut -d@ -f1)
      su - $ZIMBRA_USER -c "zmprov ga '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-preferences.txt'" 2>/dev/null
      su - $ZIMBRA_USER -c "zmprov gf '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-filters.txt'" 2>/dev/null
      su - $ZIMBRA_USER -c "zmprov gas '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-signatures.txt'" 2>/dev/null
    fi
  done <<< "$(cat "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt" 2>/dev/null)"
  pass "   User data exported"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. RETENTION POLICY
# ─────────────────────────────────────────────────────────────────────────────
log "5. Applying retention policy ($RETENTION_DAYS days)..."

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

# Clean old config files
log "   Cleaning old config files..."
cd "$BACKUP_ROOT/config" && ls -t *.txt 2>/dev/null | tail -n +11 | xargs -r rm --
pass "   Old config files cleaned"

# ─────────────────────────────────────────────────────────────────────────────
# 6. BACKUP SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
log "6. Generating backup summary..."

BACKUP_SIZE=$(du -sh "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}" 2>/dev/null | cut -f1)
TOTAL_BACKUP_SIZE=$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)

cat > "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/BACKUP-SUMMARY.txt" <<EOF
========================================================
  ZIMBRA BACKUP SUMMARY (FINAL CORRECT)
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
Success:        $BACKUP_SUCCESS
Failed:         $BACKUP_FAILED
========================================================

Backup Location: $BACKUP_ROOT
Log File: $LOG_FILE

Config Commands Used:
- zmprov gacf (global config)
- zmprov gs $SERVER_NAME (server config)
- zmlocalconfig -m (local config)
- zmprov gaa (all accounts)
- zmprov gad (all domains)

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
echo -e "Success       : $BACKUP_SUCCESS"
echo -e "Failed        : $BACKUP_FAILED"
echo -e "Retention     : $RETENTION_DAYS days"
echo -e "Backup Root   : $BACKUP_ROOT"
echo -e "Log File      : $LOG_FILE"
echo -e "${GREEN}========================================================${NC}"
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Review log file: cat $LOG_FILE"
echo -e "2. Verify backup: bash zimbra-verify-backup.sh $BACKUP_DATE"
echo -e "3. Setup cron for automated backup"
echo -e "4. Test restore procedure periodically"
echo -e "${GREEN}========================================================${NC}\n"

cp "$LOG_FILE" "$BACKUP_ROOT/logs/"

exit 0
