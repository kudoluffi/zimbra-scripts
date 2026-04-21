#!/bin/bash
# zimbra-restore.sh v3.3
# FIXED: Multi-line value extraction for Sieve scripts & HTML signatures
# Usage: sudo bash zimbra-restore.sh --mode MODES [FILTERS] BACKUP_DATE

set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING (to stderr)
# ─────────────────────────────────────────────────────────────────────────────
log()  { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
pass() { echo -e "${GREEN}[PASS]${NC} $1" >&2; }
fail() { echo -e "${RED}[FAIL]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] && { echo "Run as root: sudo bash $0"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
BACKUP_ROOT="/backup/zimbra"
ZIMBRA_USER="zimbra"
DEFAULT_STATUS="active,locked,lockout"
ZMPROV_TIMEOUT=30

# ─────────────────────────────────────────────────────────────────────────────
# PARSE OPTIONS
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
      echo ""
      echo "MODES: accounts, passwords, preferences, mailboxes, distribution-lists, all"
      echo "FILTERS: --status LIST (default: active,locked,lockout)"
      exit 0
      ;;
    *)
      if [ -z "$BACKUP_DATE" ]; then
        BACKUP_DATE="$1"
      else
        err "Unknown option or duplicate date: $1"
      fi
      shift
      ;;
  esac
done

[ -z "$BACKUP_DATE" ] && err "Backup date required"
[ -z "$MODES" ] && err "Mode required"
[ "$MODES" = "all" ] && MODES="accounts,passwords,preferences,mailboxes,distribution-lists"

# ─────────────────────────────────────────────────────────────────────────────
# GET DOMAIN
# ─────────────────────────────────────────────────────────────────────────────
get_backup_domain() {
  local domain_file="$BACKUP_ROOT/distribution-lists/domains-${BACKUP_DATE}.txt"
  if [ -f "$domain_file" ] && [ -s "$domain_file" ]; then
    local domain
    domain=$(grep -v '^$' "$domain_file" | head -1 | tr -d '[:space:]')
    if [ -n "$domain" ] && echo "$domain" | grep -q '\.'; then
      echo "$domain"
      return 0
    fi
  fi
  hostname -d 2>/dev/null || echo "newbienotes.my.id"
}

DOMAIN=$(get_backup_domain)

echo -e "\n${GREEN}========================================================${NC}" >&2
echo -e "${GREEN}  Zimbra Restore Script v3.3${NC}" >&2
echo -e "${GREEN}========================================================${NC}" >&2

log "Backup: $BACKUP_DATE | Domain: $DOMAIN | Modes: $MODES"
[ -n "$STATUS_FILTER" ] && log "Status Filter: $STATUS_FILTER"
echo "" >&2

# ─────────────────────────────────────────────────────────────────────────────
# FILENAME PARSING
# ─────────────────────────────────────────────────────────────────────────────
password_filename_to_account() {
  echo "$1" | sed 's/_/@/'
}

email_to_localpart() {
  echo "$1" | cut -d'@' -f1
}

# ─────────────────────────────────────────────────────────────────────────────
# FIXED: Single-line value extractor
# ─────────────────────────────────────────────────────────────────────────────
get_pref_value() {
  local file="$1"
  local attr="$2"
  grep "^${attr}:" "$file" 2>/dev/null | head -1 | sed "s/^${attr}:[[:space:]]*//" || true
}

# ─────────────────────────────────────────────────────────────────────────────
# FIXED: Multi-line value extractor (for Sieve scripts & HTML signatures)
# ─────────────────────────────────────────────────────────────────────────────
get_pref_value_multiline() {
  local file="$1"
  local attr="$2"
  local next_attr="$3"
  
  # Extract from "attr:" to "next_attr:" (or end of relevant section)
  # Using sed range pattern as you suggested
  if [ -n "$next_attr" ]; then
    sed -n "/^${attr}:/,/^${next_attr}:/p" "$file" 2>/dev/null | \
      head -n -1 | \
      sed "1s/^${attr}:[[:space:]]*//" | \
      sed 's/^[[:space:]]*//' | \
      tr '\n' ' ' | \
      sed 's/[[:space:]]*$//' || true
  else
    # Fallback: get until next attribute (any line starting with word:)
    awk -v ATTR="$attr:" '
      $0 ~ "^"ATTR { found=1; sub(/^'"$ATTR"'[[:space:]]*/, ""); printf "%s", $0; next }
      found && /^[a-zA-Z][a-zA-Z0-9_-]*:/ { exit }
      found { printf " %s", $0 }
    ' "$file" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GET ACCOUNT STATUS FROM BACKUP
# ─────────────────────────────────────────────────────────────────────────────
get_account_status_from_backup() {
  local acc="$1"
  local localpart
  localpart=$(email_to_localpart "$acc")
  
  local pref="$BACKUP_ROOT/mailboxes/$BACKUP_DATE/${localpart}-preferences.txt"
  
  log "   Checking preferences file: $pref" >&2
  
  if [ -f "$pref" ]; then
    local status
    status=$(get_pref_value "$pref" "zimbraAccountStatus")
    if [ -n "$status" ]; then
      log "   Found status '$status' for $acc" >&2
      echo "$status"
    else
      echo "active"
    fi
  else
    log "   Preferences file not found, assuming 'active'" >&2
    echo "active"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK IF ACCOUNT SHOULD BE CREATED/RESTORED
# ─────────────────────────────────────────────────────────────────────────────
should_restore() {
  local acc="$1"
  
  if [ -n "${SINGLE_USER:-}" ]; then
    [ "$acc" = "$SINGLE_USER" ] && return 0 || return 1
  fi
  
  if [ "${STATUS_FILTER:-}" = "all" ]; then
    return 0
  fi
  
  local status
  status=$(get_account_status_from_backup "$acc")
  
  if [ -n "${STATUS_FILTER:-}" ]; then
    if echo ",$STATUS_FILTER," | grep -q ",$status,"; then
      return 0
    else
      log "   Skipping $acc (status: $status, filter: $STATUS_FILTER)"
      return 1
    fi
  fi
  
  if echo ",$DEFAULT_STATUS," | grep -q ",$status,"; then
    return 0
  else
    log "   Skipping $acc (status: $status)"
    return 1
  fi
}

account_exists() {
  timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov ga '$1' &>/dev/null" 2>/dev/null || return 1
}

get_zimbra_attr() {
  local acc="$1"
  local attr="$2"
  timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov ga '$acc' '$attr'" 2>/dev/null | grep "^${attr}:" | sed "s/^${attr}:[[:space:]]*//" | head -1 || true
}

set_zimbra_attr() {
  local acc="$1"
  local attr="$2"
  local value="$3"
  timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov ma '$acc' '$attr' '$value'" 2>/dev/null || return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: RESTORE ACCOUNTS
# ─────────────────────────────────────────────────────────────────────────────
restore_accounts() {
  log "Step 1: Restoring user accounts (with status filter)..."
  
  local password_dir="$BACKUP_ROOT/passwords/$BACKUP_DATE"
  if [ ! -d "$password_dir" ]; then
    warn "   Password directory not found"
    return 1
  fi
  
  local ok=0 fail=0
  
  for shadow_file in "$password_dir"/*.shadow; do
    [ -f "$shadow_file" ] || continue
    
    local fn
    fn=$(basename "$shadow_file" .shadow)
    local acc
    acc=$(password_filename_to_account "$fn")
    
    should_restore "$acc" || continue
    
    if account_exists "$acc"; then
      log "   Account exists: $acc"
      local status
      status=$(get_account_status_from_backup "$acc")
      log "   Updating status to: $status"
      set_zimbra_attr "$acc" "zimbraAccountStatus" "$status" && \
        { ok=$((ok+1)); pass "      ✓ $acc (status: $status)"; } || \
        { fail=$((fail+1)); fail "      ✗ $acc"; }
    else
      local status
      status=$(get_account_status_from_backup "$acc")
      local hash
      hash=$(cat "$shadow_file")
      
      log "   Creating: $acc (status: $status)"
      
      if timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov ca '$acc' 'TempRestore123!'" 2>&1 | tee -a /tmp/zimbra-restore.log >/dev/null; then
        set_zimbra_attr "$acc" "userPassword" "$hash"
        set_zimbra_attr "$acc" "zimbraAccountStatus" "$status"
        ok=$((ok+1)); pass "      ✓ $acc (status: $status)"
      else
        fail=$((fail+1)); fail "      ✗ $acc"
      fi
    fi
  done
  
  echo "" >&2
  pass "   Accounts: $ok created/updated, $fail failed"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: RESTORE PASSWORDS
# ─────────────────────────────────────────────────────────────────────────────
restore_passwords() {
  log "Step 2: Restoring password hashes..."
  
  local dir="$BACKUP_ROOT/passwords/$BACKUP_DATE"
  [ ! -d "$dir" ] && { warn "   Not found"; return 1; }
  
  local ok=0 fail=0
  for f in "$dir"/*.shadow; do
    [ -f "$f" ] || continue
    local fn
    fn=$(basename "$f" .shadow)
    local acc
    acc=$(password_filename_to_account "$fn")
    
    if ! account_exists "$acc"; then
      log "   Skipping $acc (account not created)"
      continue
    fi
    
    local hash
    hash=$(cat "$f")
    if [ -n "$hash" ]; then
      log "   Setting password: $acc"
      if set_zimbra_attr "$acc" "userPassword" "$hash"; then
        ok=$((ok+1)); pass "      ✓ $acc"
      else
        fail=$((fail+1)); fail "      ✗ $acc"
      fi
    fi
  done
  echo "" >&2
  pass "   Passwords: $ok ok, $fail fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: RESTORE PREFERENCES (FIXED: Multi-line extraction)
# ─────────────────────────────────────────────────────────────────────────────
restore_preferences() {
  log "Step 3: Restoring preferences (forwarding, filters, signatures)..."
  local dir="$BACKUP_ROOT/mailboxes/$BACKUP_DATE"
  [ ! -d "$dir" ] && { warn "   Not found"; return 1; }
  
  local ok=0 fail=0
  for pref_file in "$dir"/*-preferences.txt; do
    [ -f "$pref_file" ] || continue
    local fn
    fn=$(basename "$pref_file" -preferences.txt)
    local acc
    acc="${fn}@${DOMAIN}"
    
    if ! account_exists "$acc"; then
      log "   Skipping $acc (account not created)"
      continue
    fi
    
    log "   Restoring preferences: $acc"
    
    local applied=0
    local failed_list=""
    
    # ───────────────────────────────────────────────────────────────────────
    # 1. Signature (FIXED: Multi-line HTML extraction)
    # ───────────────────────────────────────────────────────────────────────
    local sig_name sig_html
    sig_name=$(get_pref_value "$pref_file" "zimbraSignatureName")
    
    # FIXED: Use multi-line extractor for HTML signature
    sig_html=$(get_pref_value_multiline "$pref_file" "zimbraPrefMailSignatureHTML" "zimbraPrefMailSignatureStyle")
    
    [ -n "$sig_name" ] && log "     Found signature name: $sig_name"
    [ -n "$sig_html" ] && log "     Found signature HTML: $(echo "$sig_html" | head -c 100)..."
    
    if [ -n "$sig_name" ] && [ -n "$sig_html" ]; then
      log "     Restoring signature: $sig_name"
      
      if set_zimbra_attr "$acc" "zimbraSignatureName" "$sig_name"; then
        log "     ✓ Set signature name"
        sleep 1
        
        local sig_id
        sig_id=$(get_zimbra_attr "$acc" "zimbraSignatureId")
        
        if [ -n "$sig_id" ]; then
          log "     ✓ Got signature ID: $sig_id"
          
          local escaped_html
          escaped_html=$(printf '%s' "$sig_html" | sed "s/'/\\\\'/g" | head -c 10000)
          
          log "     Setting signature HTML (${#escaped_html} chars)"
          if set_zimbra_attr "$acc" "zimbraPrefMailSignatureHTML" "$escaped_html"; then
            log "     ✓ Set signature HTML"
            applied=$((applied+1))
            
            if set_zimbra_attr "$acc" "zimbraPrefDefaultSignatureId" "$sig_id"; then
              log "     ✓ Set default signature ID"
              applied=$((applied+1))
            fi
            
            if set_zimbra_attr "$acc" "zimbraPrefForwardReplySignatureId" "$sig_id"; then
              log "     ✓ Set forward/reply signature ID"
              applied=$((applied+1))
            fi
          else
            log "     ✗ Failed to set signature HTML"
            failed_list="${failed_list}signature_html,"
          fi
        else
          log "     ✗ Could not get signature ID"
          local backup_sig_id
          backup_sig_id=$(get_pref_value "$pref_file" "zimbraPrefDefaultSignatureId")
          if [ -n "$backup_sig_id" ] && [ "$backup_sig_id" != "zimbraPrefDefaultSignatureId" ]; then
            log "     ⚠ Using backup signature ID: $backup_sig_id"
            if set_zimbra_attr "$acc" "zimbraPrefDefaultSignatureId" "$backup_sig_id"; then
              applied=$((applied+1))
              log "     ✓ Set default signature ID from backup"
            fi
          fi
          failed_list="${failed_list}signature_id,"
        fi
      else
        log "     ✗ Failed to set signature name"
        failed_list="${failed_list}signature_name,"
      fi
    fi
    
    # ───────────────────────────────────────────────────────────────────────
    # 2. Forwarding
    # ───────────────────────────────────────────────────────────────────────
    local fwd_addr
    fwd_addr=$(get_pref_value "$pref_file" "zimbraPrefMailForwardingAddress")
    if [ -n "$fwd_addr" ] && [ "$fwd_addr" != "zimbraPrefMailForwardingAddress" ]; then
      log "     Setting forwarding: $fwd_addr"
      if set_zimbra_attr "$acc" "zimbraPrefMailForwardingAddress" "$fwd_addr"; then
        applied=$((applied+1))
        log "     ✓ Applied forwarding"
      else
        failed_list="${failed_list}forwarding,"
        log "     ✗ Failed forwarding"
      fi
    fi
    
    # ───────────────────────────────────────────────────────────────────────
    # 3. Filters (FIXED: Multi-line Sieve script extraction)
    # ───────────────────────────────────────────────────────────────────────
    local sieve_script
    # FIXED: Use multi-line extractor for Sieve script
    sieve_script=$(get_pref_value_multiline "$pref_file" "zimbraMailSieveScript" "zimbraMailSieveScriptMaxSize")
    
    if [ -n "$sieve_script" ] && [ "$sieve_script" != "zimbraMailSieveScript" ]; then
      log "     Restoring filters..."
      log "     Sieve script length: ${#sieve_script} chars"
      
      if echo "$sieve_script" | grep -q "^require"; then
        local escaped_sieve
        escaped_sieve=$(printf '%s' "$sieve_script" | sed "s/'/\\\\'/g" | head -c 15000)
        
        log "     Setting Sieve script (${#escaped_sieve} chars)"
        if timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov ma '$acc' zimbraMailSieveScript '$escaped_sieve'" 2>/dev/null; then
          applied=$((applied+1))
          log "     ✓ Applied Sieve script"
        else
          log "     ✗ Failed to apply Sieve script"
          failed_list="${failed_list}filters,"
        fi
      else
        log "     ⚠ Invalid Sieve script (missing 'require')"
        failed_list="${failed_list}filters,"
      fi
    else
      log "     ⚠ No Sieve script found in backup"
    fi
    
    # Summary
    if [ "$applied" -gt 0 ]; then
      ok=$((ok+1))
      local msg="✓ $acc ($applied settings)"
      [ -n "$failed_list" ] && msg="${msg}, failed:$(echo "$failed_list" | sed 's/,$//')"
      pass "      $msg"
    else
      fail=$((fail+1)); warn "      ✗ $acc (no settings applied)"
    fi
  done
  echo "" >&2
  pass "   Preferences: $ok ok, $fail fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: RESTORE DISTRIBUTION LISTS
# ─────────────────────────────────────────────────────────────────────────────
restore_dls() {
  log "Step 4: Restoring distribution lists..."
  local dl_file="$BACKUP_ROOT/distribution-lists/distribution-lists-${BACKUP_DATE}.txt"
  [ ! -f "$dl_file" ] && { warn "   Not found"; return 1; }
  
  local count
  count=$(wc -l < "$dl_file")
  log "   Found $count DL(s)"
  
  local dl_ok=0 member_ok=0
  while IFS= read -r dl; do
    [ -z "$dl" ] && continue
    log "   Restoring DL: $dl"
    timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov cdl '$dl'" 2>/dev/null || true
    
    local dl_safe
    dl_safe=$(echo "$dl" | tr '@' '_' | tr '.' '_')
    local member_file="$BACKUP_ROOT/distribution-lists/dl-members-${dl_safe}-${BACKUP_DATE}.txt"
    
    if [ -f "$member_file" ]; then
      local m_ok=0
      while IFS= read -r member; do
        [ -z "$member" ] && continue
        [[ "$member" =~ ^# ]] && continue
        [ "$member" = "members" ] && continue
        echo "$member" | grep -qE "^[^@]+@[^@]+\.[^@]+$" || continue
        
        if account_exists "$member"; then
          timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov adlm '$dl' '$member'" 2>/dev/null && m_ok=$((m_ok+1))
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
  
  echo "" >&2
  pass "   DLs: $dl_ok restored, $member_ok total members"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: RESTORE MAILBOXES
# ─────────────────────────────────────────────────────────────────────────────
restore_mailboxes() {
  log "Step 5: Restoring mailboxes (OSE mode: postRestURL)..."
  local dir="$BACKUP_ROOT/mailboxes/$BACKUP_DATE"
  [ ! -d "$dir" ] && { warn "   Not found"; return 1; }
  
  shopt -s nullglob
  local files=("$dir"/*.tgz)
  shopt -u nullglob
  log "   Found ${#files[@]} backup file(s)"
  [ ${#files[@]} -eq 0 ] && { warn "   No .tgz files!"; ls "$dir/"; return 1; }
  
  local ok=0 fail=0
  for f in "${files[@]}"; do
    local fn
    fn=$(basename "$f" .tgz)
    local acc
    acc="${fn}@${DOMAIN}"
    
    log "   Processing: $fn → $acc"
    echo "$acc" | grep -q "@" || { warn "   Invalid: $acc"; continue; }
    
    if ! account_exists "$acc"; then
      log "   Skipping $acc (account not created)"
      continue
    fi
    
    log "   Restoring mailbox: $acc"
    
    local restore_output
    restore_output=$(timeout 120 su - "$ZIMBRA_USER" -c "zmmailbox -z -m '$acc' postRestURL '/?fmt=tgz&resolve=skip' '$f'" 2>&1) || true
    echo "$restore_output" >> /tmp/zimbra-restore.log
    
    if echo "$restore_output" | grep -qi "usage:\|error\|exception\|fail"; then
      fail=$((fail+1)); fail "      ✗ $acc"
      log "   Error: $(echo "$restore_output" | head -2)"
    else
      ok=$((ok+1)); pass "      ✓ $acc"
    fi
  done
  echo "" >&2
  pass "   Mailboxes: $ok ok, $fail fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
log "Starting restore in sequence: Accounts → Passwords → Preferences → DLs → Mailboxes"
echo "" >&2

echo ",$MODES," | grep -q ",accounts," && { restore_accounts; echo "" >&2; }
echo ",$MODES," | grep -q ",passwords," && { restore_passwords; echo "" >&2; }
echo ",$MODES," | grep -q ",preferences," && { restore_preferences; echo "" >&2; }
echo ",$MODES," | grep -q ",distribution-lists," && { restore_dls; echo "" >&2; }
echo ",$MODES," | grep -q ",mailboxes," && { restore_mailboxes; echo "" >&2; }

echo -e "${GREEN}========================================================${NC}" >&2
echo -e "${GREEN}  RESTORE COMPLETED${NC}" >&2
echo -e "${GREEN}========================================================${NC}" >&2
echo -e "Log: /tmp/zimbra-restore.log" >&2
echo -e "${YELLOW}Verify:${NC}" >&2
echo -e "  su - zimbra -c 'zmprov ga user@$DOMAIN zimbraAccountStatus'" >&2
echo -e "  su - zimbra -c 'zmprov ga user@$DOMAIN zimbraPrefMailSignatureHTML' | head -3" >&2
echo -e "  su - zimbra -c 'zmprov ga user@$DOMAIN zimbraMailSieveScript' | head -5" >&2
echo -e "${GREEN}========================================================${NC}" >&2
