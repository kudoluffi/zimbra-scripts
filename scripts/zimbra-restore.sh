#!/bin/bash
# zimbra-restore.sh v3.10.1
# FINAL: Simple file-based approach (like v3.4) + restore signature name
# Usage: sudo bash zimbra-restore.sh --mode MODES [FILTERS] BACKUP_DATE

set -eo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

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
      echo "MODES: accounts, passwords, preferences, mailboxes, distribution-lists, all"
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
    [ -n "$domain" ] && echo "$domain" | grep -q '\.' && { echo "$domain"; return 0; }
  fi
  hostname -d 2>/dev/null || echo "newbienotes.my.id"
}

DOMAIN=$(get_backup_domain)

echo -e "\n${GREEN}========================================================${NC}" >&2
echo -e "${GREEN}  Zimbra Restore Script v3.10.1${NC}" >&2
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
# VALUE EXTRACTORS
# ─────────────────────────────────────────────────────────────────────────────
get_pref_value() {
  local file="$1"
  local attr="$2"
  grep "^${attr}:" "$file" 2>/dev/null | head -1 | sed "s/^${attr}:[[:space:]]*//" || true
}

get_pref_value_multiline() {
  local file="$1"
  local attr="$2"
  local next_attr="$3"
  local preserve_newlines="${4:-false}"
  
  if [ -n "$next_attr" ]; then
    if [ "$preserve_newlines" = "true" ]; then
      sed -n "/^${attr}:/,/^${next_attr}:/p" "$file" 2>/dev/null | head -n -1 | sed "1s/^${attr}:[[:space:]]*//" | sed 's/^[[:space:]]*//' || true
    else
      sed -n "/^${attr}:/,/^${next_attr}:/p" "$file" 2>/dev/null | head -n -1 | sed "1s/^${attr}:[[:space:]]*//" | sed 's/^[[:space:]]*//' | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true
    fi
  else
    echo ""
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GET ACCOUNT STATUS
# ─────────────────────────────────────────────────────────────────────────────
get_account_status_from_backup() {
  local acc="$1"
  local localpart
  localpart=$(email_to_localpart "$acc")
  local pref="$BACKUP_ROOT/mailboxes/$BACKUP_DATE/${localpart}-preferences.txt"
  
  if [ -f "$pref" ]; then
    local status
    status=$(get_pref_value "$pref" "zimbraAccountStatus")
    [ -n "$status" ] && echo "$status" || echo "active"
  else
    echo "active"
  fi
}

should_restore() {
  local acc="$1"
  [ -n "${SINGLE_USER:-}" ] && { [ "$acc" = "$SINGLE_USER" ]; return $?; }
  [ "${STATUS_FILTER:-}" = "all" ] && return 0
  
  local status
  status=$(get_account_status_from_backup "$acc")
  
  if [ -n "${STATUS_FILTER:-}" ]; then
    echo ",$STATUS_FILTER," | grep -q ",$status," && return 0
    log "   Skipping $acc (status: $status)"
    return 1
  fi
  
  echo ",$DEFAULT_STATUS," | grep -q ",$status,"
}

account_exists() {
  timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov ga '$1' &>/dev/null" 2>/dev/null || return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SIMPLE SET ATTRIBUTE
# ─────────────────────────────────────────────────────────────────────────────
set_zimbra_attr() {
  local acc="$1"
  local attr="$2"
  local value="$3"
  timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov ma '$acc' '$attr' '$value'" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# SET ATTRIBUTE FROM FILE (V3.4 APPROACH - WORKS!)
# ─────────────────────────────────────────────────────────────────────────────
set_zimbra_attr_from_file() {
  local acc="$1"
  local attr="$2"
  local temp_file="$3"
  
  # Read content from file
  local content
  content=$(cat "$temp_file")
  
  # Apply using zmprov
  timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov ma '$acc' '$attr' '$content'" 2>/dev/null
  local result=$?
  
  rm -f "$temp_file"
  return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: RESTORE ACCOUNTS
# ─────────────────────────────────────────────────────────────────────────────
restore_accounts() {
  log "Step 1: Restoring user accounts..."
  
  local password_dir="$BACKUP_ROOT/passwords/$BACKUP_DATE"
  [ ! -d "$password_dir" ] && { warn "   Password directory not found"; return 1; }
  
  local ok=0 fail=0
  for shadow_file in "$password_dir"/*.shadow; do
    [ -f "$shadow_file" ] || continue
    local fn=$(basename "$shadow_file" .shadow)
    local acc=$(password_filename_to_account "$fn")
    
    should_restore "$acc" || continue
    
    if account_exists "$acc"; then
      local status=$(get_account_status_from_backup "$acc")
      set_zimbra_attr "$acc" "zimbraAccountStatus" "$status" && \
        { ok=$((ok+1)); pass "      ✓ $acc (status: $status)"; } || \
        { fail=$((fail+1)); fail "      ✗ $acc"; }
    else
      local status=$(get_account_status_from_backup "$acc")
      local hash=$(cat "$shadow_file")
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
    local fn=$(basename "$f" .shadow)
    local acc=$(password_filename_to_account "$fn")
    
    account_exists "$acc" || { log "   Skipping $acc (not created)"; continue; }
    
    local hash=$(cat "$f")
    [ -n "$hash" ] && { log "   Setting password: $acc"; set_zimbra_attr "$acc" "userPassword" "$hash" && { ok=$((ok+1)); pass "      ✓ $acc"; } || { fail=$((fail+1)); fail "      ✗ $acc"; }; }
  done
  echo "" >&2
  pass "   Passwords: $ok ok, $fail fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: RESTORE PREFERENCES (FIXED: Signature name + file approach)
# ─────────────────────────────────────────────────────────────────────────────
restore_preferences() {
  log "Step 3: Restoring preferences..."
  local dir="$BACKUP_ROOT/mailboxes/$BACKUP_DATE"
  [ ! -d "$dir" ] && { warn "   Not found"; return 1; }
  
  local ok=0 fail=0
  for pref_file in "$dir"/*-preferences.txt; do
    [ -f "$pref_file" ] || continue
    local fn=$(basename "$pref_file" -preferences.txt)
    local acc="${fn}@${DOMAIN}"
    
    account_exists "$acc" || { log "   Skipping $acc (not created)"; continue; }
    
    log "   Restoring preferences: $acc"
    
    local applied=0
    local failed_list=""
    
    # ───────────────────────────────────────────────────────────────────────
    # 1. Signature Name (ADDED BACK!)
    # ───────────────────────────────────────────────────────────────────────
    local sig_name
    sig_name=$(get_pref_value "$pref_file" "zimbraSignatureName")
    
    if [ -n "$sig_name" ] && [ "$sig_name" != "zimbraSignatureName" ]; then
      log "     Setting signature name: $sig_name"
      if set_zimbra_attr "$acc" "zimbraSignatureName" "$sig_name"; then
        log "     ✓ Set signature name"
        applied=$((applied+1))
      else
        log "     ✗ Failed to set signature name"
        failed_list="${failed_list}signature_name,"
      fi
    fi
    
    # ───────────────────────────────────────────────────────────────────────
    # 2. Signature HTML (BASE64 approach)
    # ───────────────────────────────────────────────────────────────────────
    local sig_html
    sig_html=$(get_pref_value_multiline "$pref_file" "zimbraPrefMailSignatureHTML" "zimbraPrefMailSignatureStyle" "false")
    
    if [ -n "$sig_html" ]; then
      log "     Setting signature HTML (${#sig_html} chars)"
      local temp_html="/tmp/sig_${fn}.html"
      
      # Write HTML to temp file
      printf '%s' "$sig_html" > "$temp_html"
      
      # Use base64 to avoid ALL escaping issues
      if set_zimbra_attr_base64 "$acc" "zimbraPrefMailSignatureHTML" "$temp_html"; then
        log "     ✓ Set signature HTML"
        applied=$((applied+1))
      else
        log "     ✗ Failed to set signature HTML"
        failed_list="${failed_list}signature,"
      fi
    fi
    
    # ───────────────────────────────────────────────────────────────────────
    # 3. Forwarding
    # ───────────────────────────────────────────────────────────────────────
    local fwd_addr=$(get_pref_value "$pref_file" "zimbraPrefMailForwardingAddress")
    if [ -n "$fwd_addr" ] && [ "$fwd_addr" != "zimbraPrefMailForwardingAddress" ]; then
      log "     Setting forwarding: $fwd_addr"
      set_zimbra_attr "$acc" "zimbraPrefMailForwardingAddress" "$fwd_addr" && { applied=$((applied+1)); log "     ✓ Applied forwarding"; } || { failed_list="${failed_list}forwarding,"; }
    fi
    
    # ───────────────────────────────────────────────────────────────────────
    # 4. Filters (FILE approach - V3.4 - ALREADY WORKING)
    # ───────────────────────────────────────────────────────────────────────
    local sieve_script
    sieve_script=$(get_pref_value_multiline "$pref_file" "zimbraMailSieveScript" "zimbraMailSieveScriptMaxSize" "true")
    
    if [ -n "$sieve_script" ] && [ "$sieve_script" != "zimbraMailSieveScript" ] && echo "$sieve_script" | grep -q "^require"; then
      log "     Restoring filters (${#sieve_script} chars)"
      local temp_sieve="/tmp/sieve_${fn}.sieve"
      
      printf '%s' "$sieve_script" > "$temp_sieve"
      
      if set_zimbra_attr_from_file "$acc" "zimbraMailSieveScript" "$temp_sieve"; then
        log "     ✓ Applied Sieve script"
        applied=$((applied+1))
      else
        log "     ✗ Failed to apply Sieve script"
        failed_list="${failed_list}filters,"
      fi
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
  
  local count=$(wc -l < "$dl_file")
  log "   Found $count DL(s)"
  
  local dl_ok=0 member_ok=0
  while IFS= read -r dl; do
    [ -z "$dl" ] && continue
    log "   Restoring DL: $dl"
    timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov cdl '$dl'" 2>/dev/null || true
    
    local dl_safe=$(echo "$dl" | tr '@' '_' | tr '.' '_')
    local member_file="$BACKUP_ROOT/distribution-lists/dl-members-${dl_safe}-${BACKUP_DATE}.txt"
    
    if [ -f "$member_file" ]; then
      local m_ok=0
      while IFS= read -r member; do
        [ -z "$member" ] && continue
        [[ "$member" =~ ^# ]] && continue
        [ "$member" = "members" ] && continue
        echo "$member" | grep -qE "^[^@]+@[^@]+\.[^@]+$" || continue
        
        account_exists "$member" && { timeout "$ZMPROV_TIMEOUT" su - "$ZIMBRA_USER" -c "zmprov adlm '$dl' '$member'" 2>/dev/null && m_ok=$((m_ok+1)); } || log "      ⚠ Member not found: $member"
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
  log "Step 5: Restoring mailboxes..."
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
    local acc="${fn}@${DOMAIN}"
    
    echo "$acc" | grep -q "@" || { warn "   Invalid: $acc"; continue; }
    account_exists "$acc" || { log "   Skipping $acc (not created)"; continue; }
    
    log "   Restoring mailbox: $acc"
    local restore_output=$(timeout 120 su - "$ZIMBRA_USER" -c "zmmailbox -z -m '$acc' postRestURL '/?fmt=tgz&resolve=skip' '$f'" 2>&1) || true
    echo "$restore_output" >> /tmp/zimbra-restore.log
    
    echo "$restore_output" | grep -qi "usage:\|error\|exception\|fail" && { fail=$((fail+1)); fail "      ✗ $acc"; } || { ok=$((ok+1)); pass "      ✓ $acc"; }
  done
  echo "" >&2
  pass "   Mailboxes: $ok ok, $fail fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
log "Starting restore: Accounts → Passwords → Preferences → DLs → Mailboxes"
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
echo -e "  su - zimbra -c 'zmprov ga user@$DOMAIN zimbraSignatureName'" >&2
echo -e "  su - zimbra -c 'zmprov ga user@$DOMAIN zimbraPrefMailSignatureHTML'" >&2
echo -e "  su - zimbra -c 'zmprov ga user@$DOMAIN zimbraMailSieveScript' | head -5" >&2
echo -e "${GREEN}========================================================${NC}" >&2
