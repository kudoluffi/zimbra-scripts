#!/bin/bash
# zimbra-restore.sh v1.6
# FINAL FIXED: Correct filename parsing for format: user_domain_com.tgz
# Usage: sudo bash zimbra-restore.sh --mode MODES [FILTERS] BACKUP_DATE

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
MODES=""
STATUS_FILTER=""
EXCLUDE_FILTER=""
SINGLE_USER=""
BACKUP_DATE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode) MODES="$2"; shift 2 ;;
    --user) SINGLE_USER="$2"; shift 2 ;;
    --status) STATUS_FILTER="$2"; shift 2 ;;
    --exclude) EXCLUDE_FILTER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo bash zimbra-restore.sh --mode MODES [FILTERS] BACKUP_DATE"
      echo ""
      echo "MODES: config, passwords, mailboxes, preferences, distribution-lists, all"
      echo "FILTERS: --status LIST, --exclude LIST, --user USER@DOMAIN"
      echo ""
      echo "EXAMPLES:"
      echo "  sudo bash zimbra-restore.sh --mode all 20260420"
      echo "  sudo bash zimbra-restore.sh --mode mailboxes --status all 20260420"
      exit 0
      ;;
    *)
      [ -z "$BACKUP_DATE" ] && BACKUP_DATE="$1" || err "Unknown option: $1"
      shift
      ;;
  esac
done

[ -z "$BACKUP_DATE" ] && err "Backup date required"
[ -z "$MODES" ] && err "Mode required"
[ "$MODES" = "all" ] && MODES="config,passwords,mailboxes,distribution-lists"

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra Restore Script v1.6${NC}"
echo -e "${GREEN}========================================================${NC}\n"

log "Backup Date: $BACKUP_DATE"
log "Restore Modes: $MODES"
[ -n "$STATUS_FILTER" ] && log "Status Filter: $STATUS_FILTER"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# FIXED: Filename to Account Conversion
# Format: admin.noob_newbienotes.my.id → admin.noob@newbienotes.my.id
# ─────────────────────────────────────────────────────────────────────────────
filename_to_account() {
  local filename="$1"
  # Remove extension if present
  filename=$(echo "$filename" | sed 's/\.[^.]*$//')
  
  # Replace FIRST underscore with @ (localpart_domain.com → localpart@domain.com)
  # This handles: admin.noob_newbienotes.my.id → admin.noob@newbienotes.my.id
  echo "$filename" | sed 's/_/@/' 
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
get_account_status() {
  local account="$1"
  local safe_name=$(echo "$account" | tr '@' '_')
  local pref_file="$BACKUP_ROOT/mailboxes/$BACKUP_DATE/${safe_name}-preferences.txt"
  
  [ -f "$pref_file" ] && grep "^zimbraAccountStatus:" "$pref_file" 2>/dev/null | awk '{print $2}' || echo "active"
}

should_restore_account() {
  local account="$1"
  
  [ -n "$SINGLE_USER" ] && { [ "$account" = "$SINGLE_USER" ]; return $?; }
  [ "$STATUS_FILTER" = "all" ] && return 0
  
  local status=$(get_account_status "$account")
  
  if [ -n "$STATUS_FILTER" ]; then
    echo ",$STATUS_FILTER," | grep -q ",$status," && return 0
    log "   Skipping $account (status: $status)"
    return 1
  fi
  
  [ -n "$EXCLUDE_FILTER" ] && { echo ",$EXCLUDE_FILTER," | grep -q ",$status," && { log "   Skipping $account (excluded)"; return 1; }; return 0; }
  
  echo ",$DEFAULT_STATUS," | grep -q ",$status," && return 0
  log "   Skipping $account (status: $status)"
  return 1
}

account_exists() {
  su - $ZIMBRA_USER -c "zmprov ga '$1' &>/dev/null" 2>/dev/null
  return $?
}

create_account() {
  local account="$1"
  local password="$2"
  
  log "   Creating account: $account"
  su - $ZIMBRA_USER -c "zmprov ca '$account' '$password'" 2>&1 | tee -a /tmp/zimbra-restore.log >/dev/null
  return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTORE FUNCTIONS
# ─────────────────────────────────────────────────────────────────────────────
restore_passwords() {
  log "Restoring password hashes..."
  
  PASSWORD_DIR="$BACKUP_ROOT/passwords/$BACKUP_DATE"
  [ ! -d "$PASSWORD_DIR" ] && { warn "   Password directory not found"; return 1; }
  
  RESTORE_SUCCESS=0
  RESTORE_FAILED=0
  
  for shadow_file in "$PASSWORD_DIR"/*.shadow; do
    [ -f "$shadow_file" ] || continue
    
    local filename=$(basename "$shadow_file" .shadow)
    local account=$(filename_to_account "$filename")
    
    should_restore_account "$account" || continue
    
    # Create account if not exists (with temp password)
    if ! account_exists "$account"; then
      create_account "$account" "TempRestore123!" || { RESTORE_FAILED=$((RESTORE_FAILED + 1)); continue; }
    fi
    
    # Set password hash
    local password_hash=$(cat "$shadow_file")
    if [ -n "$password_hash" ]; then
      log "   Setting password: $account"
      su - $ZIMBRA_USER -c "zmprov ma '$account' userPassword '$password_hash'" 2>&1 | tee -a /tmp/zimbra-restore.log >/dev/null
      [ $? -eq 0 ] && { RESTORE_SUCCESS=$((RESTORE_SUCCESS + 1)); pass "      ✓ $account"; } || { RESTORE_FAILED=$((RESTORE_FAILED + 1)); fail "      ✗ $account"; }
    fi
  done
  
  echo ""
  pass "   Password restore: $RESTORE_SUCCESS success, $RESTORE_FAILED failed"
}

restore_mailboxes() {
  log "Restoring user mailboxes..."
  
  MAILBOX_DIR="$BACKUP_ROOT/mailboxes/$BACKUP_DATE"
  [ ! -d "$MAILBOX_DIR" ] && { warn "   Mailbox directory not found"; return 1; }
  
  shopt -s nullglob
  local tgz_files=("$MAILBOX_DIR"/*.tgz)
  shopt -u nullglob
  
  log "   Found ${#tgz_files[@]} mailbox backup file(s)"
  [ ${#tgz_files[@]} -eq 0 ] && { warn "   No .tgz files found!"; ls -la "$MAILBOX_DIR/"; return 1; }
  
  RESTORE_SUCCESS=0
  RESTORE_FAILED=0
  
  for tgz_file in "${tgz_files[@]}"; do
    local filename=$(basename "$tgz_file" .tgz)
    local account=$(filename_to_account "$filename")
    
    log "   Processing: $filename → $account"
    
    echo "$account" | grep -q "@" || { warn "   Invalid account: $account"; continue; }
    should_restore_account "$account" || continue
    
    # Ensure account exists BEFORE restore
    if ! account_exists "$account"; then
      create_account "$account" "TempRestore123!" || continue
    fi
    
    # Restore mailbox
    log "   Restoring mailbox: $account"
    local restore_output=$(su - $ZIMBRA_USER -c "zmrestore -a '$account' '$tgz_file'" 2>&1)
    local restore_status=$?
    
    echo "$restore_output" >> /tmp/zimbra-restore.log
    
    if [ $restore_status -eq 0 ]; then
      RESTORE_SUCCESS=$((RESTORE_SUCCESS + 1))
      pass "      ✓ $account"
    else
      RESTORE_FAILED=$((RESTORE_FAILED + 1))
      fail "      ✗ $account"
      log "   Error: $restore_output"
    fi
  done
  
  echo ""
  pass "   Mailbox restore: $RESTORE_SUCCESS success, $RESTORE_FAILED failed"
}

restore_distribution_lists() {
  log "Restoring distribution lists..."
  
  DL_LIST_FILE="$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt"
  [ ! -f "$DL_LIST_FILE" ] && { warn "   DL list file not found"; return 1; }
  
  DL_COUNT=$(wc -l < "$DL_LIST_FILE")
  log "   Found $DL_COUNT distribution list(s)"
  
  DL_RESTORED=0
  DL_MEMBER_COUNT=0
  
  while IFS= read -r dl_email; do
    [ -z "$dl_email" ] && continue
    echo "$dl_email" | grep -q "@" || continue
    
    log "   Restoring DL: $dl_email"
    
    # Create DL if not exists
    su - $ZIMBRA_USER -c "zmprov cdl '$dl_email'" 2>/dev/null || true
    
    # Get member file
    local dl_safe=$(echo "$dl_email" | tr '@' '_' | tr '.' '_')
    local member_file="$BACKUP_ROOT/distribution-lists/dl-members-${dl_safe}-${BACKUP_DATE}.txt"
    
    if [ -f "$member_file" ]; then
      local members_added=0
      
      while IFS= read -r member; do
        # Skip comments, headers, empty lines
        [ -z "$member" ] && continue
        [[ "$member" =~ ^# ]] && continue
        [ "$member" = "members" ] && continue
        
        # Only process valid email addresses
        if echo "$member" | grep -qE "^[^@]+@[^@]+\.[^@]+$"; then
          # Ensure member account exists before adding to DL
          if account_exists "$member"; then
            su - $ZIMBRA_USER -c "zmprov adlm '$dl_email' '$member'" 2>/dev/null && \
              members_added=$((members_added + 1))
          else
            log "      ⚠ Member not found: $member (skipped)"
          fi
        fi
      done < "$member_file"
      
      DL_MEMBER_COUNT=$((DL_MEMBER_COUNT + members_added))
      DL_RESTORED=$((DL_RESTORED + 1))
      pass "      ✓ $dl_email ($members_added members)"
    else
      warn "      ✗ $dl_email (member file not found: $member_file)"
    fi
  done < "$DL_LIST_FILE"
  
  echo ""
  pass "   Distribution lists restored: $DL_RESTORED success"
  log "   Total members added: $DL_MEMBER_COUNT"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
log "Starting restore..."
echo ""

echo ",$MODES," | grep -q ",passwords," && { restore_passwords; echo ""; }
echo ",$MODES," | grep -q ",mailboxes," && { restore_mailboxes; echo ""; }
echo ",$MODES," | grep -q ",distribution-lists," && { restore_distribution_lists; echo ""; }

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  RESTORE COMPLETED${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Log File: /tmp/zimbra-restore.log"
echo -e "${YELLOW}Verify:${NC}"
echo -e "1. List accounts: su - zimbra -c 'zmprov gaa | grep newbienotes'"
echo -e "2. Check mailbox: su - zimbra -c 'zmmailbox -z -m user@domain.com getRestURL \"//?query=*&fmt=tsv\"'"
echo -e "3. Check DL: su - zimbra -c 'zmprov gdlm officer@newbienotes.my.id'"
echo -e "${GREEN}========================================================${NC}\n"

exit 0
