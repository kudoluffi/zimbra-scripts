#!/bin/bash
# zimbra-restore.sh v1.1
# Hybrid restore script for Zimbra 10.1.x OSE
# Features: Modular restore with status filter + distribution list restore
# Usage: sudo bash zimbra-restore.sh [OPTIONS] BACKUP_DATE

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Script must be run as root. Use: sudo bash $0"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_ROOT="/backup/zimbra"
ZIMBRA_USER="zimbra"
DEFAULT_STATUS="active,locked,lockout"

# ─────────────────────────────────────────────────────────────────────────────
# PARSE OPTIONS
# ─────────────────────────────────────────────────────────────────────────────
RESTORE_MODE=""
STATUS_FILTER=""
EXCLUDE_FILTER=""
SINGLE_USER=""
BACKUP_DATE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --all)
      RESTORE_MODE="all"
      shift
      ;;
    --config)
      RESTORE_MODE="config"
      shift
      ;;
    --passwords)
      RESTORE_MODE="passwords"
      shift
      ;;
    --mailboxes)
      RESTORE_MODE="mailboxes"
      shift
      ;;
    --distribution-lists)
      RESTORE_MODE="distribution-lists"
      shift
      ;;
    --user)
      SINGLE_USER="$2"
      shift 2
      ;;
    --status)
      STATUS_FILTER="$2"
      shift 2
      ;;
    --exclude)
      EXCLUDE_FILTER="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: sudo bash zimbra-restore.sh [OPTIONS] BACKUP_DATE"
      echo ""
      echo "MODES (Mutually Exclusive - Pick One):"
      echo "  --all                 Restore everything (config + passwords + mailboxes + DL)"
      echo "  --config              Restore Zimbra configuration only"
      echo "  --passwords           Restore password hashes only"
      echo "  --mailboxes           Restore user mailboxes only (with status filter)"
      echo "  --distribution-lists  Restore distribution lists only"
      echo "  --user USER           Restore single user (bypass all filters)"
      echo ""
      echo "FILTERS (Only valid with --mailboxes):"
      echo "  --status LIST         Restore accounts with status in LIST (comma-separated)"
      echo "                        Default: active,locked,lockout"
      echo "  --exclude LIST        Restore accounts NOT in LIST (comma-separated)"
      echo ""
      echo "EXAMPLES:"
      echo "  sudo bash zimbra-restore.sh --all 20260419"
      echo "  sudo bash zimbra-restore.sh --mailboxes --status active 20260419"
      echo "  sudo bash zimbra-restore.sh --mailboxes --exclude closed,disabled 20260419"
      echo "  sudo bash zimbra-restore.sh --user admin@example.com 20260419"
      echo "  sudo bash zimbra-restore.sh --distribution-lists 20260419"
      exit 0
      ;;
    *)
      if [ -z "$BACKUP_DATE" ]; then
        BACKUP_DATE="$1"
      else
        err "Unknown option: $1"
      fi
      shift
      ;;
  esac
done

# Validate backup date
if [ -z "$BACKUP_DATE" ]; then
  err "Backup date required. Use: sudo bash zimbra-restore.sh [OPTIONS] BACKUP_DATE"
fi

# Validate restore mode
if [ -z "$RESTORE_MODE" ]; then
  err "Restore mode required. Use --all, --config, --passwords, --mailboxes, --distribution-lists, or --user"
fi

# Validate mutually exclusive options
MODE_COUNT=0
[ -n "$STATUS_FILTER" ] && MODE_COUNT=$((MODE_COUNT + 1))
[ -n "$EXCLUDE_FILTER" ] && MODE_COUNT=$((MODE_COUNT + 1))
[ -n "$SINGLE_USER" ] && MODE_COUNT=$((MODE_COUNT + 1))

if [ "$MODE_COUNT" -gt 1 ]; then
  err "Options --status, --exclude, and --user are mutually exclusive. Use only one."
fi

# Validate filters only with --mailboxes
if [ "$RESTORE_MODE" != "mailboxes" ] && [ "$RESTORE_MODE" != "all" ]; then
  if [ -n "$STATUS_FILTER" ] || [ -n "$EXCLUDE_FILTER" ]; then
    warn "--status and --exclude only work with --mailboxes mode"
  fi
fi

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra Restore Script${NC}"
echo -e "${GREEN}========================================================${NC}\n"

log "Backup Date: $BACKUP_DATE"
log "Restore Mode: $RESTORE_MODE"
[ -n "$STATUS_FILTER" ] && log "Status Filter: $STATUS_FILTER"
[ -n "$EXCLUDE_FILTER" ] && log "Exclude Filter: $EXCLUDE_FILTER"
[ -n "$SINGLE_USER" ] && log "Single User: $SINGLE_USER"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
get_account_status() {
  local account="$1"
  local safe_name=$(echo "$account" | tr '@' '_')
  local pref_file="$BACKUP_ROOT/mailboxes/$BACKUP_DATE/${safe_name}-preferences.txt"
  
  if [ -f "$pref_file" ]; then
    grep "^zimbraAccountStatus:" "$pref_file" 2>/dev/null | awk '{print $2}' || echo "active"
  else
    echo "active"
  fi
}

should_restore_account() {
  local account="$1"
  
  # Single user mode: always restore
  if [ -n "$SINGLE_USER" ]; then
    if [ "$account" = "$SINGLE_USER" ]; then
      return 0
    else
      return 1
    fi
  fi
  
  # Get account status
  local status=$(get_account_status "$account")
  
  # Status filter mode
  if [ -n "$STATUS_FILTER" ]; then
    if echo ",$STATUS_FILTER," | grep -q ",$status,"; then
      return 0
    else
      log "   Skipping $account (status: $status, not in filter)"
      return 1
    fi
  fi
  
  # Exclude filter mode
  if [ -n "$EXCLUDE_FILTER" ]; then
    if echo ",$EXCLUDE_FILTER," | grep -q ",$status,"; then
      log "   Skipping $account (status: $status, in exclude list)"
      return 1
    else
      return 0
    fi
  fi
  
  # Default: restore active, locked, lockout
  if echo ",$DEFAULT_STATUS," | grep -q ",$status,"; then
    return 0
  else
    log "   Skipping $account (status: $status, not in default filter)"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTORE FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
restore_config() {
  log "Restoring Zimbra configuration..."
  
  CONFIG_DIR="$BACKUP_ROOT/config"
  
  # Global config
  if [ -f "$CONFIG_DIR/global-config-${BACKUP_DATE}.txt" ]; then
    log "   Restoring global config..."
    warn "   ⚠️  Global config restore requires manual review!"
    log "   File: $CONFIG_DIR/global-config-${BACKUP_DATE}.txt"
    pass "   Global config file ready for review"
  else
    warn "   Global config file not found"
  fi
  
  # Server config
  if [ -f "$CONFIG_DIR/server-config-${BACKUP_DATE}.txt" ]; then
    log "   Restoring server config..."
    warn "   ⚠️  Server config restore requires manual review!"
    log "   File: $CONFIG_DIR/server-config-${BACKUP_DATE}.txt"
    pass "   Server config file ready for review"
  else
    warn "   Server config file not found"
  fi
  
  # Local config
  if [ -f "$CONFIG_DIR/local-config-${BACKUP_DATE}.txt" ]; then
    log "   Restoring local config..."
    warn "   ⚠️  Local config restore requires manual review!"
    log "   File: $CONFIG_DIR/local-config-${BACKUP_DATE}.txt"
    pass "   Local config file ready for review"
  else
    warn "   Local config file not found"
  fi
  
  log "   Configuration files extracted. Review and apply manually."
  pass "   Configuration restore completed (manual review required)"
}

restore_passwords() {
  log "Restoring password hashes..."
  
  PASSWORD_DIR="$BACKUP_ROOT/passwords/$BACKUP_DATE"
  
  if [ ! -d "$PASSWORD_DIR" ]; then
    warn "   Password backup directory not found"
    return 1
  fi
  
  RESTORE_SUCCESS=0
  RESTORE_FAILED=0
  
  for shadow_file in "$PASSWORD_DIR"/*.shadow; do
    if [ -f "$shadow_file" ]; then
      # Extract account from filename
      local filename=$(basename "$shadow_file" .shadow)
      local account=$(echo "$filename" | tr '_' '@' | sed 's/@\([^.]*\)\./@\1./')
      
      # Check if should restore this account
      if ! should_restore_account "$account"; then
        continue
      fi
      
      # Read password hash
      local password_hash=$(cat "$shadow_file")
      
      if [ -n "$password_hash" ] && [ -n "$account" ]; then
        log "   Restoring password for: $account"
        
        # Set password hash
        su - $ZIMBRA_USER -c "zmprov ma '$account' userPassword '$password_hash'" 2>&1 | tee -a /tmp/zimbra-restore.log >/dev/null
        
        if [ $? -eq 0 ]; then
          RESTORE_SUCCESS=$((RESTORE_SUCCESS + 1))
          pass "      ✓ $account"
        else
          RESTORE_FAILED=$((RESTORE_FAILED + 1))
          fail "      ✗ $account"
        fi
      fi
    fi
  done
  
  echo ""
  pass "   Password restore: $RESTORE_SUCCESS success, $RESTORE_FAILED failed"
}

restore_mailboxes() {
  log "Restoring user mailboxes..."
  
  MAILBOX_DIR="$BACKUP_ROOT/mailboxes/$BACKUP_DATE"
  
  if [ ! -d "$MAILBOX_DIR" ]; then
    warn "   Mailbox backup directory not found"
    return 1
  fi
  
  RESTORE_SUCCESS=0
  RESTORE_FAILED=0
  SKIPPED_COUNT=0
  
  for tgz_file in "$MAILBOX_DIR"/*.tgz; do
    if [ -f "$tgz_file" ]; then
      # Extract account from filename
      local filename=$(basename "$tgz_file" .tgz)
      local account=$(echo "$filename" | tr '_' '@' | sed 's/@\([^.]*\)\./@\1./')
      
      # Skip if not a valid email
      if ! echo "$account" | grep -q "@"; then
        continue
      fi
      
      # Check if should restore this account
      if ! should_restore_account "$account"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
      fi
      
      log "   Restoring mailbox: $account"
      
      # Restore mailbox
      su - $ZIMBRA_USER -c "zmrestore -a '$account' '$tgz_file'" 2>&1 | tee -a /tmp/zimbra-restore.log >/dev/null
      
      if [ $? -eq 0 ]; then
        RESTORE_SUCCESS=$((RESTORE_SUCCESS + 1))
        pass "      ✓ $account"
      else
        RESTORE_FAILED=$((RESTORE_FAILED + 1))
        fail "      ✗ $account"
      fi
    fi
  done
  
  echo ""
  pass "   Mailbox restore: $RESTORE_SUCCESS success, $RESTORE_FAILED failed, $SKIPPED_COUNT skipped"
}

restore_distribution_lists() {
  log "Restoring distribution lists..."
  
  DL_LIST_FILE="$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt"
  
  if [ ! -f "$DL_LIST_FILE" ]; then
    warn "   Distribution list file not found"
    return 1
  fi
  
  DL_COUNT=$(wc -l < "$DL_LIST_FILE")
  log "   Found $DL_COUNT distribution list(s) to restore"
  
  DL_RESTORED=0
  DL_FAILED=0
  DL_MEMBER_COUNT=0
  
  while IFS= read -r dl_email; do
    if [ -n "$dl_email" ] && echo "$dl_email" | grep -q "@"; then
      log "   Restoring DL: $dl_email"
      
      # Create DL if not exists (ignore error if already exists)
      su - $ZIMBRA_USER -c "zmprov cdl '$dl_email'" 2>/dev/null || true
      
      # Restore members from member file
      DL_SAFE_NAME=$(echo "$dl_email" | tr '@' '_' | tr '.' '_')
      DL_MEMBER_FILE="$BACKUP_ROOT/distribution-lists/dl-members-${DL_SAFE_NAME}-${BACKUP_DATE}.txt"
      
      if [ -f "$DL_MEMBER_FILE" ]; then
        # Extract members (skip header lines, only lines with @)
        MEMBERS_ADDED=0
        while IFS= read -r member; do
          if [ -n "$member" ] && echo "$member" | grep -q "@"; then
            su - $ZIMBRA_USER -c "zmprov adlm '$dl_email' '$member'" 2>/dev/null && \
              MEMBERS_ADDED=$((MEMBERS_ADDED + 1))
          fi
        done < "$DL_MEMBER_FILE"
        
        DL_MEMBER_COUNT=$((DL_MEMBER_COUNT + MEMBERS_ADDED))
        DL_RESTORED=$((DL_RESTORED + 1))
        pass "      ✓ $dl_email ($MEMBERS_ADDED members)"
      else
        DL_FAILED=$((DL_FAILED + 1))
        warn "      ✗ $dl_email (member file not found)"
      fi
    fi
  done < "$DL_LIST_FILE"
  
  echo ""
  pass "   Distribution lists restored: $DL_RESTORED success, $DL_FAILED failed"
  log "   Total members restored: $DL_MEMBER_COUNT"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN RESTORE LOGIC
# ─────────────────────────────────────────────────────────────────────────────
case $RESTORE_MODE in
  all)
    log "Starting full restore (config + passwords + mailboxes + distribution lists)..."
    echo ""
    restore_config
    echo ""
    restore_passwords
    echo ""
    restore_mailboxes
    echo ""
    restore_distribution_lists
    ;;
  config)
    restore_config
    ;;
  passwords)
    restore_passwords
    ;;
  mailboxes)
    restore_mailboxes
    ;;
  distribution-lists)
    restore_distribution_lists
    ;;
  *)
    err "Unknown restore mode: $RESTORE_MODE"
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  RESTORE COMPLETED${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Backup Date : $BACKUP_DATE"
echo -e "Restore Mode: $RESTORE_MODE"
echo -e "Log File    : /tmp/zimbra-restore.log"
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "1. Review restore log: cat /tmp/zimbra-restore.log"
echo -e "2. Test user login and mailbox access"
echo -e "3. Verify configuration settings"
echo -e "4. Test distribution list email delivery"
echo -e "${GREEN}========================================================${NC}\n"

exit 0
