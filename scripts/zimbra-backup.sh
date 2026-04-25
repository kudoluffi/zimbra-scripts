#!/bin/bash
# zimbra-backup.sh v2.4
# FIXED: Status extraction logic + Added Backup Duration Timing
# Usage: sudo bash zimbra-backup.sh [weekly|daily]

set -u

#RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; MAGENTA='\033[1;35m'; CYAN='\033[1;36m'; WHITE='\033[1;37m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# TIMING & LOGGING
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_ROOT="/backup/zimbra"
BACKUP_DATE=$(date +%Y%m%d)
DAY_OF_WEEK=$(date +%u)
RETENTION_DAYS=30
ZIMBRA_USER="zimbra"
LOG_FILE="/var/log/zimbra-backup-${BACKUP_DATE}.log"
SERVER_NAME=$(hostname -f)

# Record Start Time
START_TIME=$(date +%s)
START_TIME_FMT=$(date '+%Y-%m-%d %H:%M:%S')

# Redirect ALL output to log file AND terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
DAILY_ALLOWED_STATUSES="active locked lockout"

# System accounts that are NEVER backed up
EXCLUDE_PATTERNS=(
  "^admin@"
  "^spam\."
  "^ham\."
  "^virus-quarantine\."
  "^galsync\."
  "^postmaster@"
  "^abuse@"
)

# ─────────────────────────────────────────────────────────────────────────────
# MODE SELECTION
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_TYPE="${1:-auto}"

if [ "$BACKUP_TYPE" = "auto" ]; then
  if [ "$DAY_OF_WEEK" = "7" ]; then
    BACKUP_TYPE="weekly"
  else
    BACKUP_TYPE="daily"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────

# Cek apakah akun adalah system account
should_exclude_system() {
  local account="$1"
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    if echo "$account" | grep -qE "$pattern"; then
      return 0
    fi
  done
  return 1
}

# Generate Account List (Filtered)
generate_filtered_account_list() {
  local output_file="$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt"
  local raw_list
  
  # Get all accounts from LDAP
  log "   Fetching all accounts from LDAP..."
  raw_list=$(su - $ZIMBRA_USER -c "zmprov -l gaa" 2>/dev/null)
  
  if [ -z "$raw_list" ]; then
    warn "   Failed to get account list!"
    return 1
  fi

  > "$output_file"
  local processed=0

  while IFS= read -r account; do
    [ -z "$account" ] && continue
    
    # 1. Skip system accounts (admin, spam, etc.)
    if should_exclude_system "$account"; then
      continue
    fi

    # 2. If DAILY mode, check status
    if [ "$BACKUP_TYPE" = "daily" ]; then
      # FIXED: Use grep to filter specifically for the attribute line
      local status
      status=$(su - $ZIMBRA_USER -c "zmprov ga '$account' zimbraAccountStatus" 2>/dev/null | grep "zimbraAccountStatus:" | awk '{print $2}')
      
      # If status is NOT in allowed list, skip
      if ! echo "$DAILY_ALLOWED_STATUSES" | grep -qw "$status"; then
        log "   ⏭️  Skip $account (Status: $status)"
        continue
      fi
    fi

    # Add to list
    echo "$account" >> "$output_file"
    processed=$((processed + 1))
    
  done <<< "$raw_list"

  if [ -s "$output_file" ]; then
    ACCOUNT_COUNT=$(wc -l < "$output_file")
    pass "   Account list generated: $ACCOUNT_COUNT accounts (Processed: $processed, Mode: $BACKUP_TYPE)"
    return 0
  else
    warn "   No accounts found to backup!"
    ACCOUNT_COUNT=0
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-CHECKS
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "Script must be run as root. Use: sudo bash $0"
  exit 1
fi

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra Backup Script (v2.4 - Fixed Logs & Timing)${NC}"
echo -e "${GREEN}========================================================${NC}\n"

log "Backup Start: $START_TIME_FMT"
log "Backup Date: $BACKUP_DATE"
log "Server: $SERVER_NAME"
log "Backup Type: $BACKUP_TYPE"
log "Backup Root: $BACKUP_ROOT"
log "Log File: $LOG_FILE"
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
# 1. CONFIG BACKUP (ONLY FOR WEEKLY)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$BACKUP_TYPE" = "weekly" ]; then
  log "[$(date '+%Y-%m-%d %H:%M:%S')] 1. Backing up Zimbra configuration..."

  log "   Exporting global config..."
  su - $ZIMBRA_USER -c "zmprov gacf > $BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt" 2>&1
  [ -s "$BACKUP_ROOT/config/global-config-${BACKUP_DATE}.txt" ] && pass "   Global config exported" || fail "   Global config export failed"

  log "   Exporting server config..."
  su - $ZIMBRA_USER -c "zmprov gs $SERVER_NAME > $BACKUP_ROOT/config/server-config-${BACKUP_DATE}.txt" 2>&1
  [ -s "$BACKUP_ROOT/config/server-config-${BACKUP_DATE}.txt" ] && pass "   Server config exported" || fail "   Server config export failed"

  log "   Exporting local config..."
  zmlocalconfig -m > "$BACKUP_ROOT/config/local-config-${BACKUP_DATE}.txt" 2>&1
  [ -s "$BACKUP_ROOT/config/local-config-${BACKUP_DATE}.txt" ] && pass "   Local config exported" || fail "   Local config export failed"

  log "   Saving Zimbra version info..."
  su - $ZIMBRA_USER -c "zmcontrol -v > $BACKUP_ROOT/config/zimbra-version-${BACKUP_DATE}.txt" 2>&1
  pass "   Version info saved"
else
  log "[$(date '+%Y-%m-%d %H:%M:%S')] 1. Skipping Config Backup (Daily Mode - User Data Only)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. DOMAINS & DISTRIBUTION LISTS (ONLY FOR WEEKLY)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$BACKUP_TYPE" = "weekly" ]; then
  log "[$(date '+%Y-%m-%d %H:%M:%S')] 2. Backing up Domains & Distribution Lists..."

  log "   Exporting domain list..."
  su - $ZIMBRA_USER -c "zmprov gad > $BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt" 2>&1
  [ -s "$BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt" ] && pass "   Domain list exported" || fail "   Domain list export failed"

  log "   Exporting distribution lists..."
  DL_LIST_FILE="$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt"
  su - $ZIMBRA_USER -c "zmprov gadl > '$DL_LIST_FILE'" 2>&1

  if [ -s "$DL_LIST_FILE" ]; then
    DL_COUNT=$(wc -l < "$DL_LIST_FILE")
    pass "   Found $DL_COUNT distribution list(s)"
    
    log "   Exporting distribution list members..."
    DL_MEMBER_COUNT=0
    while IFS= read -r dl_email; do
      if [ -n "$dl_email" ] && echo "$dl_email" | grep -q "@"; then
        DL_SAFE_NAME=$(echo "$dl_email" | tr '@' '_' | tr '.' '_')
        DL_MEMBER_FILE="$BACKUP_ROOT/distribution-lists/dl-members-${DL_SAFE_NAME}-${BACKUP_DATE}.txt"
        su - $ZIMBRA_USER -c "zmprov gdlm '$dl_email' > '$DL_MEMBER_FILE'" 2>&1
        [ -s "$DL_MEMBER_FILE" ] && DL_MEMBER_COUNT=$((DL_MEMBER_COUNT + $(grep -c "@" "$DL_MEMBER_FILE" 2>/dev/null || echo 0)))
      fi
    done < "$DL_LIST_FILE"
    pass "   Distribution list members exported: $DL_MEMBER_COUNT total members"
  else
    warn "   No distribution lists found"
    DL_COUNT=0
    DL_MEMBER_COUNT=0
  fi
else
  log "[$(date '+%Y-%m-%d %H:%M:%S')] 2. Skipping Domains & DLs Backup (Daily Mode - User Data Only)"
  DOMAIN_COUNT=0
  DL_COUNT=0
  DL_MEMBER_COUNT=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. GENERATE FILTERED ACCOUNT LIST
# ─────────────────────────────────────────────────────────────────────────────
log "[$(date '+%Y-%m-%d %H:%M:%S')] 3. Generating Account List (Filtered by Mode & Status)..."
ACCOUNT_COUNT=0
if ! generate_filtered_account_list; then
  fail "   Critical Error: Cannot generate account list. Aborting."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. PASSWORD HASH BACKUP
# ─────────────────────────────────────────────────────────────────────────────
log "[$(date '+%Y-%m-%d %H:%M:%S')] 4. Backing up password hashes..."

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  mkdir -p "$BACKUP_ROOT/passwords/${BACKUP_DATE}"
  chown zimbra:zimbra "$BACKUP_ROOT/passwords/${BACKUP_DATE}"
  chmod 700 "$BACKUP_ROOT/passwords/${BACKUP_DATE}"
  
  PASSWORD_BACKUP_COUNT=0
  
  while IFS= read -r account; do
    SAFE_NAME=$(echo "$account" | tr '@' '_')
    su - $ZIMBRA_USER -c "zmprov -l ga '$account' userPassword" 2>/dev/null | \
      grep "userPassword:" | awk '{print $2}' > "$BACKUP_ROOT/passwords/${BACKUP_DATE}/${SAFE_NAME}.shadow"
    
    if [ -s "$BACKUP_ROOT/passwords/${BACKUP_DATE}/${SAFE_NAME}.shadow" ]; then
      PASSWORD_BACKUP_COUNT=$((PASSWORD_BACKUP_COUNT + 1))
      chown zimbra:zimbra "$BACKUP_ROOT/passwords/${BACKUP_DATE}/${SAFE_NAME}.shadow"
      chmod 600 "$BACKUP_ROOT/passwords/${BACKUP_DATE}/${SAFE_NAME}.shadow"
    fi
  done < "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt"
  
  pass "   Password hashes backed up: $PASSWORD_BACKUP_COUNT accounts"
  warn "   ⚠️  PASSWORD FILES ARE SENSITIVE!"
  warn "   ⚠️  Location: $BACKUP_ROOT/passwords/${BACKUP_DATE}/"
else
  warn "   Skipping password backup (no accounts found)"
  PASSWORD_BACKUP_COUNT=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. MAILBOX BACKUP
# ─────────────────────────────────────────────────────────────────────────────
log "[$(date '+%Y-%m-%d %H:%M:%S')] 5. Backing up mailboxes ($BACKUP_TYPE)..."

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  BACKUP_SUCCESS=0
  BACKUP_FAILED=0
  
  mkdir -p "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}"
  chown zimbra:zimbra "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}"
  
  while IFS= read -r account; do
    ACCOUNT_NAME=$(echo "$account" | cut -d@ -f1)
    log "   Backing up: $account"
    
    MAILBOX_BACKUP_FILE="$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}.tgz"
    
    su - $ZIMBRA_USER -c "zmmailbox -z -m '$account' getRestURL '//?fmt=tgz' > '$MAILBOX_BACKUP_FILE'" 2>&1
    
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
  pass "   Mailbox backup: $BACKUP_SUCCESS success, $BACKUP_FAILED failed"
else
  warn "   Skipping mailbox backup (no valid accounts found)"
  BACKUP_SUCCESS=0
  BACKUP_FAILED=0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. USER PREFERENCES
# ─────────────────────────────────────────────────────────────────────────────
log "[$(date '+%Y-%m-%d %H:%M:%S')] 6. Backing up user preferences..."

if [ "$ACCOUNT_COUNT" -gt 0 ]; then
  USER_PREF_COUNT=0
  
  while IFS= read -r account; do
    ACCOUNT_NAME=$(echo "$account" | cut -d@ -f1)
    su - $ZIMBRA_USER -c "zmprov ga '$account' > '$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-preferences.txt'" 2>/dev/null
    
    if [ -s "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/${ACCOUNT_NAME}-preferences.txt" ]; then
      USER_PREF_COUNT=$((USER_PREF_COUNT + 1))
    fi
  done < "$BACKUP_ROOT/distribution-lists/accounts-${BACKUP_DATE}.txt"
  
  pass "   User preferences exported: $USER_PREF_COUNT accounts"
  log "   ℹ️  preferences.txt includes signatures, filters, and status"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. RETENTION POLICY
# ─────────────────────────────────────────────────────────────────────────────
log "[$(date '+%Y-%m-%d %H:%M:%S')] 7. Applying retention policy ($RETENTION_DAYS days)..."

OLD_BACKUPS=$(find "$BACKUP_ROOT/mailboxes" -type d -name "20*" -mtime +$RETENTION_DAYS 2>/dev/null)
if [ -n "$OLD_BACKUPS" ]; then
  while IFS= read -r old_dir; do rm -rf "$old_dir"; done <<< "$OLD_BACKUPS"
  pass "   Deleted old mailbox backups"
fi

OLD_PASS_BACKUPS=$(find "$BACKUP_ROOT/passwords" -type d -name "20*" -mtime +$RETENTION_DAYS 2>/dev/null)
if [ -n "$OLD_PASS_BACKUPS" ]; then
  while IFS= read -r old_dir; do rm -rf "$old_dir"; done <<< "$OLD_PASS_BACKUPS"
  pass "   Deleted old password backups"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. CALCULATE DURATION
# ─────────────────────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Format duration
MINS=$((DURATION / 60))
SECS=$((DURATION % 60))
HOURS=$((MINS / 60))
MINS=$((MINS % 60))

if [ $HOURS -gt 0 ]; then
  DURATION_FMT="${HOURS}h ${MINS}m ${SECS}s"
elif [ $MINS -gt 0 ]; then
  DURATION_FMT="${MINS}m ${SECS}s"
else
  DURATION_FMT="${SECS}s"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 9. BACKUP SUMMARY (RESTORED)
# ─────────────────────────────────────────────────────────────────────────────
log "[$(date '+%Y-%m-%d %H:%M:%S')] 8. Generating BACKUP-SUMMARY.txt..."

BACKUP_SIZE=$(du -sh "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}" 2>/dev/null | cut -f1)
TOTAL_BACKUP_SIZE=$(du -sh "$BACKUP_ROOT" 2>/dev/null | cut -f1)

# Ensure directory exists
mkdir -p "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}"

END_TIME_FMT=$(date '+%Y-%m-%d %H:%M:%S')

#cat > "$BACKUP_ROOT/mailboxes/${BACKUP_DATE}/BACKUP-SUMMARY.txt" <<EOF
cat > "$BACKUP_ROOT/BACKUP-SUMMARY.txt" <<EOF
========================================================
  ZIMBRA BACKUP SUMMARY (v2.4)
========================================================
Backup Date:    $BACKUP_DATE
Start Time:     $START_TIME_FMT
End Time:       $END_TIME_FMT
Duration:       $DURATION_FMT
Server:         $SERVER_NAME
Backup Type:    $BACKUP_TYPE (Weekly=All, Daily=Active Only)
Retention:      $RETENTION_DAYS days
Backup Size:    $BACKUP_SIZE
Total Size:     $TOTAL_BACKUP_SIZE
Accounts Total: $ACCOUNT_COUNT
Dist. Lists:    $DL_COUNT
DL Members:     $DL_MEMBER_COUNT
Password Hash : $PASSWORD_BACKUP_COUNT
Mailbox Success: $BACKUP_SUCCESS
Mailbox Failed : $BACKUP_FAILED
User Preferences: $USER_PREF_COUNT
========================================================

BACKUP INCLUDES:
✅ Global/Server/Local Configuration (Weekly Only)
✅ All Domains & Distribution Lists (Weekly Only)
✅ Password Hashes (Filtered by Mode)
✅ Mailboxes (Filtered by Mode)
✅ User Preferences (Filtered by Mode)

DAILY BACKUP FILTER:
🔹 Only accounts with status: $DAILY_ALLOWED_STATUSES
🔹 Accounts with status 'closed' are skipped in daily mode.
🔹 Run 'weekly' mode on Sunday to backup everything.

⚠️  SECURITY WARNING - PASSWORD FILES:
🔒 Location: $BACKUP_ROOT/passwords/${BACKUP_DATE}/
🔒 Permission: 700 (zimbra:zimbra only)

========================================================
RESTORE INSTRUCTIONS:
1. Restore Config (if weekly): bash zimbra-restore.sh --mode config $BACKUP_DATE
2. Restore Passwords: bash zimbra-restore.sh --mode passwords $BACKUP_DATE
3. Restore Mailboxes: bash zimbra-restore.sh --mode mailboxes $BACKUP_DATE
4. Restore Preferences: bash zimbra-restore.sh --mode preferences $BACKUP_DATE
========================================================
EOF

#pass "   Backup summary generated at: $BACKUP_ROOT/mailboxes/${BACKUP_DATE}/BACKUP-SUMMARY.txt"
pass "   Backup summary generated at: $BACKUP_ROOT/BACKUP-SUMMARY.txt"

# ─────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  BACKUP SELESAI${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Duration      : ${YELLOW}$DURATION_FMT${NC}"
echo -e "Date          : $BACKUP_DATE"
echo -e "Mode          : $BACKUP_TYPE"
echo -e "Backup Size   : $BACKUP_SIZE"
echo -e "Total Size    : $TOTAL_BACKUP_SIZE"
echo -e "Accounts      : $ACCOUNT_COUNT (Filtered)"
echo -e "Mailbox Done  : $BACKUP_SUCCESS"
echo -e "Mailbox Fail  : $BACKUP_FAILED"
echo -e "Passwords     : $PASSWORD_BACKUP_COUNT"
echo -e "Retention     : $RETENTION_DAYS days"
echo -e "Log File      : $LOG_FILE"
echo -e "${GREEN}========================================================${NC}\n"

if [ "$BACKUP_TYPE" = "daily" ]; then
  echo -e "${YELLOW}ℹ️  NOTE:${NC} Daily backup contains User Data only (Active users)."
  echo -e "    Config & DLs are skipped. Use Weekly backup for full system restore."
fi

# Copy log to backup root just in case
cp "$LOG_FILE" "$BACKUP_ROOT/logs/" 2>/dev/null

exit 0
