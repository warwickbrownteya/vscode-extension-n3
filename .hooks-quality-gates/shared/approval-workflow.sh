#!/bin/bash
# shared/approval-workflow.sh
# Approval workflow management: SLA enforcement, audit trails, renewal tracking

AUDIT_LOG="${AUDIT_LOG:-.teya/exceptions-audit.log}"
APPROVALS_DIR="${APPROVALS_DIR:-.teya/approvals}"

# Initialize approval infrastructure
init_approval_infrastructure() {
  mkdir -p "$APPROVALS_DIR"
  mkdir -p "$(dirname "$AUDIT_LOG")"

  # Ensure audit log exists
  if [ ! -f "$AUDIT_LOG" ]; then
    touch "$AUDIT_LOG"
  fi

  return 0
}

# Log exception event to audit trail
# event_type: created, approved, denied, renewed, expired, revoked
log_exception_event() {
  local event_type="$1"
  local exc_id="$2"
  local approver="$3"
  local notes="${4:-}"

  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local user=$(git config user.name || echo "unknown")

  # Format: timestamp | event_type | exc_id | approver | user | notes
  echo "$timestamp | $event_type | $exc_id | $approver | $user | $notes" >> "$AUDIT_LOG"

  return 0
}

# Get audit trail for specific exception
get_exception_audit_trail() {
  local exc_id="$1"

  if [ ! -f "$AUDIT_LOG" ]; then
    echo ""
    return 0
  fi

  grep "| $exc_id |" "$AUDIT_LOG" 2>/dev/null || true
}

# Check if exception requires approval
requires_approval() {
  local exc_type="$1"

  case "$exc_type" in
    finding-disabled|check-waived|hook-disabled|gate-waived)
      return 0  # Requires approval
      ;;
    *)
      return 1  # No approval needed
      ;;
  esac
}

# Get approval authority for exception type
get_approval_authority() {
  local exc_type="$1"

  case "$exc_type" in
    finding-disabled)
      echo "QA Lead, Security Officer"
      ;;
    check-waived)
      echo "Security Officer"
      ;;
    hook-disabled)
      echo "CISO"
      ;;
    gate-waived)
      echo "CISO, On-call Security Officer"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# Get SLA (in days) for approval
get_approval_sla() {
  local exc_type="$1"

  case "$exc_type" in
    finding-disabled)
      echo "5"  # 5 days
      ;;
    check-waived)
      echo "2"  # 2 days
      ;;
    hook-disabled)
      echo "1"  # 1 day
      ;;
    gate-waived)
      echo "0.041667"  # 1 hour = 1/24 day
      ;;
    *)
      echo "0"
      ;;
  esac
}

# Get auto-expiry duration (in days) for exception
get_auto_expiry_duration() {
  local exc_type="$1"

  case "$exc_type" in
    finding-disabled)
      echo "90"  # 90 days
      ;;
    check-waived)
      echo "30"  # 30 days
      ;;
    hook-disabled)
      echo "60"  # 60 days
      ;;
    gate-waived)
      echo "7"   # 7 days (can extend to 14 if needed)
      ;;
    *)
      echo "0"
      ;;
  esac
}

# Calculate expiry date for exception
calculate_expiry_date() {
  local exc_type="$1"
  local creation_date="${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

  local duration=$(get_auto_expiry_duration "$exc_type")

  # Use date math to add days (platform-independent)
  if command -v date &>/dev/null; then
    # Try GNU date first (Linux)
    date -u -d "+${duration} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
      # Fallback to BSD date (macOS)
      date -u -v +${duration}d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
      # Fallback: return creation_date as is (manual calculation needed)
      echo "$creation_date"
  fi
}

# Check if exception SLA is approaching (80% of duration)
approaching_sla_deadline() {
  local exc_id="$1"
  local exc_type="$2"
  local created_date="$3"

  local sla_days=$(get_approval_sla "$exc_type")
  local sla_seconds=$(echo "$sla_days * 86400" | bc)

  # Calculate 80% of SLA
  local warning_threshold=$(echo "$sla_seconds * 0.8" | bc)

  local now_timestamp=$(date +%s)
  local created_timestamp=$(date -f "%Y-%m-%dT%H:%M:%SZ" "+%s" "$created_date" 2>/dev/null || echo 0)

  local elapsed=$((now_timestamp - created_timestamp))

  if [ $elapsed -gt ${warning_threshold%.*} ]; then
    return 0  # SLA approaching
  fi
  return 1  # SLA not yet approaching
}

# Check if exception is overdue for renewal
is_renewal_overdue() {
  local exc_id="$1"
  local expires_date="$2"

  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # ISO 8601 string comparison (works because format is sortable)
  if [[ "$expires_date" < "$now" ]]; then
    return 0  # Overdue (expired)
  fi
  return 1  # Not yet expired
}

# Get renewal reminder threshold (in days before expiry)
get_renewal_reminder_days() {
  local exc_type="$1"

  case "$exc_type" in
    finding-disabled)
      echo "18"  # 20% of 90 days
      ;;
    check-waived)
      echo "6"   # 20% of 30 days
      ;;
    hook-disabled)
      echo "12"  # 20% of 60 days
      ;;
    gate-waived)
      echo "1"   # 14% of 7 days (1 day before)
      ;;
    *)
      echo "0"
      ;;
  esac
}

# Check if renewal reminder should be sent
should_send_renewal_reminder() {
  local exc_id="$1"
  local exc_type="$2"
  local expires_date="$3"

  local reminder_days=$(get_renewal_reminder_days "$exc_type")
  local now=$(date -u +%s)
  local expires_timestamp=$(date -f "%Y-%m-%dT%H:%M:%SZ" "+%s" "$expires_date" 2>/dev/null || echo 0)
  local reminder_threshold=$((expires_timestamp - (reminder_days * 86400)))

  if [ $now -gt $reminder_threshold ] && [ $now -lt $expires_timestamp ]; then
    return 0  # Should send reminder
  fi
  return 1  # Reminder not needed yet
}

# Create approval record
create_approval_record() {
  local exc_id="$1"
  local approval_type="$2"  # approved, denied, expired
  local approver="$3"
  local notes="${4:-}"

  init_approval_infrastructure

  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local approval_file="$APPROVALS_DIR/${exc_id}.json"

  cat > "$approval_file" <<EOF
{
  "exception_id": "$exc_id",
  "approval_type": "$approval_type",
  "approver": "$approver",
  "timestamp": "$timestamp",
  "notes": "$notes",
  "approved_by_email": "$(git config user.email || echo 'unknown')",
  "approved_by_name": "$(git config user.name || echo 'unknown')"
}
EOF

  # Log to audit trail
  log_exception_event "$approval_type" "$exc_id" "$approver" "$notes"

  return 0
}

# Get approval record
get_approval_record() {
  local exc_id="$1"

  local approval_file="$APPROVALS_DIR/${exc_id}.json"

  if [ -f "$approval_file" ]; then
    cat "$approval_file"
  else
    echo "null"
  fi
}

# Request renewal for exception (extends expiry, requires re-justification)
request_renewal() {
  local exc_id="$1"
  local new_expiry_date="$2"
  local renewal_justification="$3"

  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local renewal_file="$APPROVALS_DIR/${exc_id}-renewal.json"

  cat > "$renewal_file" <<EOF
{
  "exception_id": "$exc_id",
  "renewal_request_date": "$timestamp",
  "new_expiry_date": "$new_expiry_date",
  "justification": "$renewal_justification",
  "requested_by": "$(git config user.name || echo 'unknown')",
  "requested_by_email": "$(git config user.email || echo 'unknown')",
  "status": "pending"
}
EOF

  log_exception_event "renewal_requested" "$exc_id" "pending" "Renewal requested, new expiry: $new_expiry_date"

  return 0
}

# Approve renewal
approve_renewal() {
  local exc_id="$1"
  local approver="$2"
  local notes="${3:-}"

  local renewal_file="$APPROVALS_DIR/${exc_id}-renewal.json"

  if [ ! -f "$renewal_file" ]; then
    return 1
  fi

  # Update renewal record
  local new_expiry=$(grep -o '"new_expiry_date": "[^"]*"' "$renewal_file" | cut -d'"' -f4)

  # Log approval
  log_exception_event "renewal_approved" "$exc_id" "$approver" "Approved until $new_expiry. $notes"

  # Mark renewal as approved
  sed -i.bak 's/"status": "pending"/"status": "approved"/' "$renewal_file"
  rm -f "${renewal_file}.bak"

  return 0
}

# Deny renewal (exception expires)
deny_renewal() {
  local exc_id="$1"
  local denier="$2"
  local reason="${3:-No justification provided}"

  local renewal_file="$APPROVALS_DIR/${exc_id}-renewal.json"

  if [ -f "$renewal_file" ]; then
    sed -i.bak 's/"status": "pending"/"status": "denied"/' "$renewal_file"
    rm -f "${renewal_file}.bak"
  fi

  log_exception_event "renewal_denied" "$exc_id" "$denier" "Renewal denied. Reason: $reason"

  return 0
}

# Get all pending approvals
get_pending_approvals() {
  init_approval_infrastructure

  if [ ! -d "$APPROVALS_DIR" ]; then
    return 0
  fi

  # Find all .json files that don't have approval records yet
  for renewal_file in "$APPROVALS_DIR"/*-renewal.json; do
    if [ -f "$renewal_file" ]; then
      if grep -q '"status": "pending"' "$renewal_file"; then
        cat "$renewal_file"
        echo "---"
      fi
    fi
  done
}

# Generate SLA report
generate_sla_report() {
  local exceptions_file="${1:-.teya/exceptions-registry.yaml}"

  if [ ! -f "$exceptions_file" ]; then
    echo "{}"
    return 0
  fi

  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  cat <<EOF
{
  "report_generated": "$now",
  "summary": {
    "total_exceptions": $(grep -c "^[[:space:]]*id:" "$exceptions_file" 2>/dev/null || echo 0),
    "active": $(grep -c 'status:[[:space:]]*active' "$exceptions_file" 2>/dev/null || echo 0),
    "expired": $(grep -c 'status:[[:space:]]*expired' "$exceptions_file" 2>/dev/null || echo 0),
    "pending_renewal": $(grep -c '"status": "pending"' "$APPROVALS_DIR"/*.json 2>/dev/null | grep -o '^[0-9]*' | awk '{s+=$1} END {print s}')
  },
  "audit_log_entries": $(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)
}
EOF
}

# Export approval infrastructure paths
export AUDIT_LOG
export APPROVALS_DIR
