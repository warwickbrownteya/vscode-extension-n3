#!/bin/bash
# shared/sla-enforcer.sh
# SLA enforcement: Monitor exception approval SLAs and send reminders

EXCEPTIONS_REGISTRY="${EXCEPTIONS_REGISTRY:-.teya/exceptions-registry.yaml}"
AUDIT_LOG="${AUDIT_LOG:-.teya/exceptions-audit.log}"
REMINDERS_SENT="${REMINDERS_SENT:-.teya/reminder-tracker.log}"

# Initialize SLA enforcement
init_sla_enforcement() {
  mkdir -p "$(dirname "$REMINDERS_SENT")"
  touch "$REMINDERS_SENT"
  return 0
}

# Check SLA violations (exceptions pending approval beyond SLA)
check_sla_violations() {
  local exceptions_file="$EXCEPTIONS_REGISTRY"

  if [ ! -f "$exceptions_file" ]; then
    echo "{}"
    return 0
  fi

  local now=$(date -u +%s)
  local violations="[]"

  # For each exception in pending status, check if it's past SLA
  awk -F: '
    /^[[:space:]]*id:/ {
      match($0, /id:[[:space:]]*([^ ]+)/, arr)
      current_id = arr[1]
    }
    /^[[:space:]]*created_at:/ {
      match($0, /created_at:[[:space:]]*([^ ]+)/, arr)
      current_created = arr[1]
    }
    /^[[:space:]]*type:/ {
      match($0, /type:[[:space:]]*([^ ]+)/, arr)
      current_type = arr[1]
    }
    /^[[:space:]]*status:[[:space:]]*pending/ {
      if (current_id && current_created && current_type) {
        print current_id "|" current_created "|" current_type
      }
    }
  ' "$exceptions_file" 2>/dev/null | while IFS='|' read -r exc_id created_date exc_type; do
    _check_exception_sla_status "$exc_id" "$created_date" "$exc_type"
  done
}

# Check individual exception SLA status
_check_exception_sla_status() {
  local exc_id="$1"
  local created_date="$2"
  local exc_type="$3"

  # Map exception type to SLA (in hours)
  local sla_hours=0
  case "$exc_type" in
    finding-disabled)
      sla_hours=$((5 * 24))  # 5 days
      ;;
    check-waived)
      sla_hours=$((2 * 24))  # 2 days
      ;;
    hook-disabled)
      sla_hours=24           # 1 day
      ;;
    gate-waived)
      sla_hours=1            # 1 hour
      ;;
  esac

  local now=$(date -u +%s)
  local created_timestamp=$(date -f "%Y-%m-%dT%H:%M:%SZ" "+%s" "$created_date" 2>/dev/null || echo 0)
  local elapsed_hours=$(( (now - created_timestamp) / 3600 ))

  if [ $elapsed_hours -gt $sla_hours ]; then
    echo "{\"exception_id\": \"$exc_id\", \"type\": \"$exc_type\", \"elapsed_hours\": $elapsed_hours, \"sla_hours\": $sla_hours, \"status\": \"VIOLATED\"}"
  fi
}

# Check for reminders that need to be sent
check_renewal_reminders() {
  local exceptions_file="$EXCEPTIONS_REGISTRY"

  if [ ! -f "$exceptions_file" ]; then
    return 0
  fi

  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # For each active exception approaching expiry
  awk -F: '
    /^[[:space:]]*id:/ {
      match($0, /id:[[:space:]]*([^ ]+)/, arr)
      current_id = arr[1]
    }
    /^[[:space:]]*expires_at:/ {
      match($0, /expires_at:[[:space:]]*([^ ]+)/, arr)
      current_expires = arr[1]
    }
    /^[[:space:]]*type:/ {
      match($0, /type:[[:space:]]*([^ ]+)/, arr)
      current_type = arr[1]
    }
    /^[[:space:]]*status:[[:space:]]*active/ {
      if (current_id && current_expires && current_type) {
        print current_id "|" current_expires "|" current_type
      }
    }
  ' "$exceptions_file" 2>/dev/null | while IFS='|' read -r exc_id expires_date exc_type; do
    _check_renewal_reminder "$exc_id" "$expires_date" "$exc_type"
  done
}

# Check if renewal reminder should be sent
_check_renewal_reminder() {
  local exc_id="$1"
  local expires_date="$2"
  local exc_type="$3"

  # Get reminder threshold days (20% before expiry)
  local reminder_days=0
  case "$exc_type" in
    finding-disabled)
      reminder_days=18  # 20% of 90
      ;;
    check-waived)
      reminder_days=6   # 20% of 30
      ;;
    hook-disabled)
      reminder_days=12  # 20% of 60
      ;;
    gate-waived)
      reminder_days=1   # 14% of 7
      ;;
  esac

  local now=$(date -u +%s)
  local expires_timestamp=$(date -f "%Y-%m-%dT%H:%M:%SZ" "+%s" "$expires_date" 2>/dev/null || echo 0)
  local reminder_threshold=$((expires_timestamp - (reminder_days * 86400)))

  # Check if reminder already sent
  if grep -q "$exc_id" "$REMINDERS_SENT" 2>/dev/null; then
    return 0  # Reminder already sent
  fi

  if [ $now -gt $reminder_threshold ] && [ $now -lt $expires_timestamp ]; then
    # Send renewal reminder
    echo "$exc_id|$(date -u +%Y-%m-%dT%H:%M:%SZ)|$exc_type|$expires_date" >> "$REMINDERS_SENT"
    echo "{\"exception_id\": \"$exc_id\", \"type\": \"$exc_type\", \"expires\": \"$expires_date\", \"action\": \"SEND_REMINDER\"}"
  fi
}

# Check for expired exceptions (mark for cleanup)
check_expired_exceptions() {
  local exceptions_file="$EXCEPTIONS_REGISTRY"

  if [ ! -f "$exceptions_file" ]; then
    return 0
  fi

  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  awk -F: -v now="$now" '
    /^[[:space:]]*id:/ {
      match($0, /id:[[:space:]]*([^ ]+)/, arr)
      current_id = arr[1]
    }
    /^[[:space:]]*expires_at:/ {
      match($0, /expires_at:[[:space:]]*([^ ]+)/, arr)
      current_expires = arr[1]
    }
    /^[[:space:]]*type:/ {
      match($0, /type:[[:space:]]*([^ ]+)/, arr)
      current_type = arr[1]
    }
    /^[[:space:]]*status:[[:space:]]*active/ {
      if (current_id && current_expires && current_expires < now) {
        print "{\"exception_id\": \"" current_id "\", \"type\": \"" current_type "\", \"expired\": \"" current_expires "\", \"action\": \"AUTO_EXPIRE\"}"
      }
    }
  ' "$exceptions_file" 2>/dev/null
}

# Mark exception as expired (auto-cleanup)
mark_exception_expired() {
  local exc_id="$1"
  local exceptions_file="$EXCEPTIONS_REGISTRY"

  if [ ! -f "$exceptions_file" ]; then
    return 1
  fi

  # Update exception status to expired
  # Note: This is a simple sed operation - proper YAML update in Phase 2
  sed -i.bak "/id:[[:space:]]*$exc_id/,/^[[:space:]]*-[[:space:]]/ s/status:[[:space:]]*active/status: expired/" "$exceptions_file"
  rm -f "${exceptions_file}.bak"

  # Log the expiry
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | auto_expired | $exc_id | system | auto-expire | Automatic expiry, no renewal requested" >> "$AUDIT_LOG"

  return 0
}

# Generate approval metrics
generate_approval_metrics() {
  init_sla_enforcement

  local exceptions_file="$EXCEPTIONS_REGISTRY"

  if [ ! -f "$exceptions_file" ]; then
    echo "{}"
    return 0
  fi

  local total=$(grep -c "^[[:space:]]*id:" "$exceptions_file" 2>/dev/null || echo 0)
  local active=$(grep -c 'status:[[:space:]]*active' "$exceptions_file" 2>/dev/null || echo 0)
  local expired=$(grep -c 'status:[[:space:]]*expired' "$exceptions_file" 2>/dev/null || echo 0)
  local pending=$(awk '/status:[[:space:]]*pending/ {print}' "$exceptions_file" 2>/dev/null | wc -l)

  local finding_disabled=$(grep -c 'type:[[:space:]]*finding-disabled' "$exceptions_file" 2>/dev/null || echo 0)
  local check_waived=$(grep -c 'type:[[:space:]]*check-waived' "$exceptions_file" 2>/dev/null || echo 0)
  local hook_disabled=$(grep -c 'type:[[:space:]]*hook-disabled' "$exceptions_file" 2>/dev/null || echo 0)
  local gate_waived=$(grep -c 'type:[[:space:]]*gate-waived' "$exceptions_file" 2>/dev/null || echo 0)

  cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_exceptions": $total,
  "by_status": {
    "active": $active,
    "expired": $expired,
    "pending": $pending
  },
  "by_type": {
    "finding-disabled": $finding_disabled,
    "check-waived": $check_waived,
    "hook-disabled": $hook_disabled,
    "gate-waived": $gate_waived
  },
  "metrics": {
    "approval_rate": "$(echo "scale=2; ($active + $expired) * 100 / $total" | bc)%",
    "expiry_rate": "$(echo "scale=2; $expired * 100 / $total" | bc)%",
    "renewal_pending": $pending
  }
}
EOF
}

# Generate SLA health report
generate_sla_health_report() {
  local report_file="${1:-.teya/sla-health-report.json}"

  init_sla_enforcement

  local violations=$(check_sla_violations | grep -c "VIOLATED" || echo 0)
  local reminders=$(check_renewal_reminders | grep -c "SEND_REMINDER" || echo 0)
  local expired=$(check_expired_exceptions | grep -c "AUTO_EXPIRE" || echo 0)

  cat > "$report_file" <<EOF
{
  "report_generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "health": {
    "sla_violations": $violations,
    "pending_reminders": $reminders,
    "auto_expiring": $expired
  },
  "actions_needed": {
    "approve_pending": "Review pending approval requests",
    "send_reminders": "Send renewal reminders to approvers",
    "cleanup_expired": "Mark expired exceptions, notify teams"
  },
  "audit_trail_entries": $(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)
}
EOF

  echo "SLA health report written to: $report_file"
  cat "$report_file"
}

# Export variables
export AUDIT_LOG
export REMINDERS_SENT
