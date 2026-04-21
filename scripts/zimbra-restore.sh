#!/bin/bash
# zimbra-restore.sh v1.9
# FINAL: Fixed mailbox restore (postRestURL) + preferences value extraction
# Usage: sudo bash zirma-restore.sh --mode MODES [FILTERS] BACKUP_DATE

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $1"; }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

[ "$(id -u)" -ne 0 ] && { echo "Run as root: sudo bash $0"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_ROOT="/backup/zimbra"
ZIMBRA_USER="zimbra"
DEFAULT_STATUS="active,locked,lockout"

# ─────────────────────────────────────────────────────────────────────────────
# PARSE OPTIONS FIRST
# ─────────────────────────────────────────────────────────────────────────────
MODES=""
STATUS_FILTER=""
SINGLE_USER=""
BACKUP_DATE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode) MODES="$2"; shift 2 ;;
    --status) STATUS_FILTER="$2"; shift 2 ;;
    --user) SINGLE_USER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: sudo bash zimbra-restore.sh --mode MODES [FILTERS] BACKUP_DATE"
      echo "MODES: passwords, mailboxes, preferences, distribution-lists, all"
      exit 0
      ;;
    *)
      [ -z "$BACKUP_DATE" ] && BACKUP_DATE="$1" || err "Unknown: $1"
      shift
      ;;
  esac
done

[ -z "$BACKUP_DATE" ] && err "Backup date required"
[ -z "$MODES" ] && err "Mode required"
[ "$MODES" = "all" ] && MODES="passwords,mailboxes,preferences,distribution-lists"

# ─────────────────────────────────────────────────────────────────────────────
# GET DOMAIN
# ─────────────────────────────────────────────────────────────────────────────
get_backup_domain() {
  local domain_file="$BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt"
  if [ -f "$domain_file" ] && [ -s "$domain_file" ]; then
    local domain=$(grep -v '^$' "$domain_file" | head -1 | tr -d '[:space:]')
    [ -n "$domain" ] && echo "$domain" | grep -q '\.' && { echo "$domain"; return 0; }
  fi
  hostname -d 2>/dev/null || echo "newbienotes.my.id"
}

DOMAIN=$(get_backup_domain)

echo -e "\n${GREEN}========================================================${NC}"
echo -e "${GREEN}  Zimbra Restore Script v1.9${NC}"
echo -e "${GREEN}========================================================${NC}\n"

log "Backup: $BACKUP_DATE | Domain: $DOMAIN | Modes: $MODES"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# FILENAME PARSING
# ─────────────────────────────────────────────────────────────────────────────
password_filename_to_account() {
  echo "$1" | sed 's/_/@/'
}

mailbox_filename_to_account() {
  echo "${1}@${DOMAIN}"
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────
get_account_status() {
  local acc="$1"
  local safe=$(echo "$acc" | tr '@' '_')
  local pref="$BACKUP_ROOT/mailboxes/$BACKUP_DATE/${safe}-preferences.txt"
  [ -f "$pref" ] && grep "^zimbraAccountStatus:" "$pref" 2>/dev/null | awk '{print $2}' || echo "active"
}

should_restore() {
  local acc="$1"
  [ -n "$SINGLE_USER" ] && { [ "$acc" = "$SINGLE_USER" ]; return $?; }
  [ "$STATUS_FILTER" = "all" ] && return 0
  local status=$(get_account_status "$acc")
  [ -n "$STATUS_FILTER" ] && { echo ",$STATUS_FILTER," | grep -q ",$status,"; return $?; }
  echo ",$DEFAULT_STATUS," | grep -q ",$status,"
}

account_exists() {
  su - $ZIMBRA_USER -c "zmprov ga '$1' &>/dev/null" 2>/dev/null
}

create_account() {
  local acc="$1" pwd="$2"
  log "   Creating: $acc"
  su - $ZIMBRA_USER -c "zmprov ca '$acc' '$pwd'" 2>&1 | tee -a /tmp/zimbra-restore.log >/dev/null
}

# Extract attribute value from preferences file (handle multi-line)
get_pref_value() {
  local file="$1"
  local attr="$2"
  # Use zmprov ga to get current value from backup preferences (more reliable than grep)
  # But since we can't query backup file directly, use awk for multi-line
  awk -v attr="$attr:" '$0 ~ "^"attr {found=1; sub(/^'"$attr"': */, ""); printf "%s", $0; next} found && /^[a-zA-Z]/ {exit} found {printf " %s", $0}' "$file" 2>/dev/null | sed 's/^ *//;s/ *$//'
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTORE: PASSWORDS
# ─────────────────────────────────────────────────────────────────────────────
restore_passwords() {
  log "Restoring passwords..."
  local dir="$BACKUP_ROOT/passwords/$BACKUP_DATE"
  [ ! -d "$dir" ] && { warn "   Not found"; return 1; }
  
  local ok=0 fail=0
  for f in "$dir"/*.shadow; do
    [ -f "$f" ] || continue
    local fn=$(basename "$f" .shadow)
    local acc=$(password_filename_to_account "$fn")
    
    should_restore "$acc" || continue
    account_exists "$acc" || create_account "$acc" "TempRestore123!"
    
    local hash=$(cat "$f")
    if [ -n "$hash" ]; then
      log "   Setting password: $acc"
      su - $ZIMBRA_USER -c "zmprov ma '$acc' userPassword '$hash'" 2>&1 | tee -a /tmp/zimbra-restore.log >/dev/null
      [ $? -eq 0 ] && { ok=$((ok+1)); pass "      ✓ $acc"; } || { fail=$((fail+1)); fail "      ✗ $acc"; }
    fi
  done
  echo ""; pass "   Passwords: $ok ok, $fail fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTORE: MAILBOXES (FIXED: Use postRestURL for OSE)
# ─────────────────────────────────────────────────────────────────────────────
restore_mailboxes() {
  log "Restoring mailboxes (OSE mode: postRestURL)..."
  local dir="$BACKUP_ROOT/mailboxes/$BACKUP_DATE"
  [ ! -d "$dir" ] && { warn "   Not found"; return 1; }
  
  shopt -s nullglob
  local files=("$dir"/*.tgz)
  shopt -u nullglob
  log "   Found ${#files[@]} backup file(s)"
  [ ${#files[@]} -eq 0 ] && { warn "   No .tgz files!"; ls "$dir/"; return 1; }
  
  local ok=0 fail=0
  for f in "${files[@]}"; do
    local fn=$(basename "$f" .tgz)
    local acc=$(mailbox_filename_to_account "$fn")
    
    log "   Processing: $fn → $acc"
    echo "$acc" | grep -q "@" || { warn "   Invalid: $acc"; continue; }
    should_restore "$acc" || continue
    
    account_exists "$acc" || create_account "$acc" "TempRestore123!"
    
    log "   Restoring mailbox: $acc"
    
    # FIX: Use zmmailbox postRestURL for OSE TGZ imports
    # Format: zmmailbox -z -m user@domain postRestURL '//?fmt=tgz&resolve=skip' < backup.tgz
    local restore_output=$(su - $ZIMBRA_USER -c "zmmailbox -z -m '$acc' postRestURL '//?fmt=tgz&resolve=skip' < '$f'" 2>&1)
    local restore_status=$?
    
    echo "$restore_output" >> /tmp/zimbra-restore.log
    
    # Check for success indicators
    if [ $restore_status -eq 0 ] && ! echo "$restore_output" | grep -qi "error\|fail\|exception"; then
      ok=$((ok+1)); pass "      ✓ $acc"
    else
      fail=$((fail+1)); fail "      ✗ $acc"
      log "   Error output: $(echo "$restore_output" | head -3)"
    fi
  done
  echo ""; pass "   Mailboxes: $ok ok, $fail fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTORE: PREFERENCES (FIXED: Better value extraction)
# ─────────────────────────────────────────────────────────────────────────────
restore_preferences() {
  log "Restoring user preferences (signatures, forwarding, status)..."
  local dir="$BACKUP_ROOT/mailboxes/$BACKUP_DATE"
  [ ! -d "$dir" ] && { warn "   Not found"; return 1; }
  
  local ok=0 fail=0
  for pref_file in "$dir"/*-preferences.txt; do
    [ -f "$pref_file" ] || continue
    local fn=$(basename "$pref_file" -preferences.txt)
    local acc=$(mailbox_filename_to_account "$fn")
    
    echo "$acc" | grep -q "@" || continue
    should_restore "$acc" || continue
    account_exists "$acc" || continue
    
    log "   Restoring preferences: $acc"
    
    local applied=0 failed_attrs=""
    
    # Attributes to restore (in order)
    for attr in "zimbraAccountStatus" "zimbraPrefMailForwardingAddress" "zimbraPrefSignature"; do
      # Extract value using awk (handles multi-line values)
      local value=$(awk -v a="$attr:" '
        $0 ~ "^"a { 
          found=1; 
          sub(/^'"$a"': */, ""); 
          printf "%s", $0; 
          next 
        } 
        found && /^[a-zA-Z]/ {exit} 
        found {printf " %s", $0}
      ' "$pref_file" 2>/dev/null | sed 's/^ *//;s/ *$//')
      
      if [ -n "$value" ] && [ "$value" != "$attr" ]; then
        # Escape single quotes in value for safe command execution
        local escaped_value=$(echo "$value" | sed "s/'/\\\\'/g")
        
        log "     Setting $attr"
        if su - $ZIMBRA_USER -c "zmprov ma '$acc' '$attr' '$escaped_value'" 2>/dev/null; then
          applied=$((applied+1))
        else
          failed_attrs="$failed_attrs $attr"
        fi
      fi
    done
    
    if [ $applied -gt 0 ]; then
      ok=$((ok+1))
      local msg="✓ $acc ($applied settings)"
      [ -n "$failed_attrs" ] && msg="$msg, failed:$failed_attrs"
      pass "      $msg"
    else
      fail=$((fail+1)); warn "      ✗ $acc (no settings applied)"
    fi
  done
  echo ""; pass "   Preferences: $ok ok, $fail fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTORE: DISTRIBUTION LISTS
# ─────────────────────────────────────────────────────────────────────────────
restore_dls() {
  log "Restoring distribution lists..."
  local dl_file="$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt"
  [ ! -f "$dl_file" ] && { warn "   Not found"; return 1; }
  
  local count=$(wc -l < "$dl_file")
  log "   Found $count DL(s)"
  
  local dl_ok=0 member_ok=0
  while IFS= read -r dl; do
    [ -z "$dl" ] && continue
    log "   Restoring DL: $dl"
    su - $ZIMBRA_USER -c "zmprov cdl '$dl'" 2>/dev/null || true
    
    local dl_safe=$(echo "$dl" | tr '@' '_' | tr '.' '_')
    local member_file="$BACKUP_ROOT/distribution-lists/dl-members-${dl_safe}-${BACKUP_DATE}.txt"
    
    if [ -f "$member_file" ]; then
      local m_ok=0
      while IFS= read -r member; do
        [ -z "$member" ] && continue
        [[ "$member" =~ ^# ]] && continue
        [ "$member" = "members" ] && continue
        echo "$member" | grep -qE "^[^@]+@[^@]+\.[^@]+$" || continue
        
        if account_exists "$member"; then
          su - $ZIMBRA_USER -c "zmprov adlm '$dl' '$member'" 2>/dev/null && m_ok=$((m_ok+1))
        else
          log "      ⚠ Member not found: $member"
        fi
      done < "$member_file"
      member_ok=$((member_ok + m_ok))
      pass "      ✓ $dl ($m_ok members)"
      dl_ok=$((dl_ok+1))
    else
      warn "      ✗ $dl (no member file)"
    fi
  done < "$dl_file"
  
  echo ""; pass "   DLs: $dl_ok restored, $member_ok total members"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
log "Starting restore..."
echo ""

echo ",$MODES," | grep -q ",passwords," && { restore_passwords; echo ""; }
echo ",$MODES," | grep -q ",mailboxes," && { restore_mailboxes; echo ""; }
echo ",$MODES," | grep -q ",preferences," && { restore_preferences; echo ""; }
echo ",$MODES," | grep -q ",distribution-lists," && { restore_dls; echo ""; }

echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN}  RESTORE COMPLETED${NC}"
echo -e "${GREEN}========================================================${NC}"
echo -e "Log: /tmp/zimbra-restore.log"
echo -e "${YELLOW}Verify:${NC}"
echo -e "  su - zimbra -c 'zmprov gaa | grep $DOMAIN'"
echo -e "  su - zimbra -c 'zmmailbox -z -m user@$DOMAIN getRestURL \"//?query=*&fmt=tsv\"'"
echo -e "  su - zimbra -c 'zmprov gdlm officer@$DOMAIN'"
echo -e "${GREEN}========================================================${NC}\n"
