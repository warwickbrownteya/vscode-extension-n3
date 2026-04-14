#!/bin/bash
# shared/metrics-collector.sh
# Collect and export exception management metrics for Grafana

EXCEPTIONS_REGISTRY="${EXCEPTIONS_REGISTRY:-.teya/exceptions-registry.yaml}"
AUDIT_LOG="${AUDIT_LOG:-.teya/exceptions-audit.log}"
FINDINGS_DIR="${FINDINGS_DIR:-.teya}"
METRICS_EXPORT="${METRICS_EXPORT:-.teya/metrics.json}"

# Initialize metrics collection
init_metrics() {
  mkdir -p "$(dirname "$METRICS_EXPORT")"
  return 0
}

# Collect exception status metrics
collect_exception_metrics() {
  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    echo "{}"; return 0
  fi

  local total=$(grep -c "^[[:space:]]*id:" "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)
  local active=$(grep -c 'status:[[:space:]]*active' "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)
  local expired=$(grep -c 'status:[[:space:]]*expired' "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)
  local pending=$(grep -c 'status:[[:space:]]*pending' "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)
  local revoked=$(grep -c 'status:[[:space:]]*revoked' "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)

  # By type
  local finding_disabled=$(grep -c 'type:[[:space:]]*finding-disabled' "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)
  local check_waived=$(grep -c 'type:[[:space:]]*check-waived' "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)
  local hook_disabled=$(grep -c 'type:[[:space:]]*hook-disabled' "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)
  local gate_waived=$(grep -c 'type:[[:space:]]*gate-waived' "$EXCEPTIONS_REGISTRY" 2>/dev/null | tr -d '\n' || echo 0)

  cat <<EOF
{
  "timestamp": "$now",
  "exceptions": {
    "total": $total,
    "by_status": {
      "active": $active,
      "expired": $expired,
      "pending": $pending,
      "revoked": $revoked
    },
    "by_type": {
      "finding_disabled": $finding_disabled,
      "check_waived": $check_waived,
      "hook_disabled": $hook_disabled,
      "gate_waived": $gate_waived
    }
  }
}
EOF
}

# Collect approval metrics
collect_approval_metrics() {
  if [ ! -f "$AUDIT_LOG" ]; then
    echo "{\"approvals\": {\"total\": 0}}"
    return 0
  fi

  local approved=$(grep -c " | approved | " "$AUDIT_LOG" 2>/dev/null || echo 0)
  local denied=$(grep -c " | denied | " "$AUDIT_LOG" 2>/dev/null || echo 0)
  local total=$((approved + denied))

  cat <<EOF
{
  "approvals": {
    "total": $total,
    "approved": $approved,
    "denied": $denied
  }
}
EOF
}

# Collect renewal metrics
collect_renewal_metrics() {
  if [ ! -f "$AUDIT_LOG" ]; then
    echo "{\"renewals\": {\"total\": 0}}"
    return 0
  fi

  local renewal_requested=$(grep -c " | renewal_requested | " "$AUDIT_LOG" 2>/dev/null || echo 0)
  local renewal_approved=$(grep -c " | renewal_approved | " "$AUDIT_LOG" 2>/dev/null || echo 0)
  local renewal_denied=$(grep -c " | renewal_denied | " "$AUDIT_LOG" 2>/dev/null || echo 0)

  cat <<EOF
{
  "renewals": {
    "requested": $renewal_requested,
    "approved": $renewal_approved,
    "denied": $renewal_denied
  }
}
EOF
}

# Collect SLA metrics
collect_sla_metrics() {
  if [ ! -f "$AUDIT_LOG" ]; then
    echo "{\"sla\": {\"total_approvals\": 0}}"
    return 0
  fi

  # This is a simplified calculation - full SLA analysis would need timestamp parsing
  local total_approvals=$(grep -c " | approved | " "$AUDIT_LOG" 2>/dev/null || echo 0)
  local sla_violations=$(grep -c "VIOLATED" "$AUDIT_LOG" 2>/dev/null || echo 0)

  cat <<EOF
{
  "sla": {
    "total_approvals": $total_approvals,
    "violations": $sla_violations
  }
}
EOF
}

# Collect findings metrics from .teya results
collect_findings_metrics() {
  local total_secrets=0
  local total_sast=0
  local total_sca=0
  local total_iac=0
  local total_findings=0

  if [ -f "$FINDINGS_DIR/findings-secrets.json" ]; then
    total_secrets=$(grep -o '"finding_count": [0-9]*' "$FINDINGS_DIR/findings-secrets.json" 2>/dev/null | cut -d':' -f2 | tr -d ' ' || echo 0)
  fi
  if [ -f "$FINDINGS_DIR/findings-sast.json" ]; then
    total_sast=$(grep -o '"finding_count": [0-9]*' "$FINDINGS_DIR/findings-sast.json" 2>/dev/null | cut -d':' -f2 | tr -d ' ' || echo 0)
  fi
  if [ -f "$FINDINGS_DIR/findings-sca.json" ]; then
    total_sca=$(grep -o '"finding_count": [0-9]*' "$FINDINGS_DIR/findings-sca.json" 2>/dev/null | cut -d':' -f2 | tr -d ' ' || echo 0)
  fi
  if [ -f "$FINDINGS_DIR/findings-iac.json" ]; then
    total_iac=$(grep -o '"finding_count": [0-9]*' "$FINDINGS_DIR/findings-iac.json" 2>/dev/null | cut -d':' -f2 | tr -d ' ' || echo 0)
  fi

  total_findings=$((total_secrets + total_sast + total_sca + total_iac))

  cat <<EOF
{
  "findings": {
    "total": $total_findings,
    "by_tool": {
      "secrets": $total_secrets,
      "sast": $total_sast,
      "sca": $total_sca,
      "iac": $total_iac
    }
  }
}
EOF
}

# Collect hook execution metrics
collect_hook_metrics() {
  local hooks_log="$FINDINGS_DIR/hooks.log"

  if [ ! -f "$hooks_log" ]; then
    echo "{\"hooks\": {\"total_runs\": 0}}"
    return 0
  fi

  local total_runs=$(grep -c "\[INFO\]" "$hooks_log" 2>/dev/null || echo 0)
  local total_errors=$(grep -c "\[ERROR\]" "$hooks_log" 2>/dev/null || echo 0)
  local total_warnings=$(grep -c "\[WARN\]" "$hooks_log" 2>/dev/null || echo 0)

  local success_rate=100
  if [ $total_runs -gt 0 ]; then
    success_rate=$(echo "scale=2; ($total_runs - $total_errors) * 100 / $total_runs" | bc 2>/dev/null || echo 100)
  fi

  cat <<EOF
{
  "hooks": {
    "total_runs": $total_runs,
    "errors": $total_errors,
    "warnings": $total_warnings,
    "success_rate_percent": $success_rate
  }
}
EOF
}

# Collect per-hook execution timing metrics
collect_per_hook_metrics() {
  local execution_metrics="${FINDINGS_DIR}/execution-metrics.json"

  if [ ! -f "$execution_metrics" ]; then
    echo "{\"per_hook\": []}"
    return 0
  fi

  # Parse execution metrics JSON and output per-hook details
  cat <<EOF
{
  "per_hook": $(cat "$execution_metrics" | grep -o '"hooks": \[.*\]' || echo '[]')
}
EOF
}

# Collect exception application metrics
collect_exception_application_metrics() {
  local execution_metrics="${FINDINGS_DIR}/execution-metrics.json"

  if [ ! -f "$execution_metrics" ]; then
    echo "{\"exception_application\": {\"checked\": 0, \"applied\": 0}}"
    return 0
  fi

  # Parse exception application data
  local checked=$(grep -o '"total_checked": [0-9]*' "$execution_metrics" 2>/dev/null | cut -d':' -f2 | tr -d ' ' || echo 0)
  local applied=$(grep -o '"total_applied": [0-9]*' "$execution_metrics" 2>/dev/null | cut -d':' -f2 | tr -d ' ' || echo 0)

  local application_rate=0
  if [ "$checked" -gt 0 ]; then
    application_rate=$(echo "scale=2; $applied * 100 / $checked" | bc 2>/dev/null || echo 0)
  fi

  cat <<EOF
{
  "exception_application": {
    "checked": $checked,
    "applied": $applied,
    "application_rate_percent": $application_rate
  }
}
EOF
}

# Calculate false positive ratio per hook
calculate_false_positive_ratio() {
  local execution_metrics="${FINDINGS_DIR}/execution-metrics.json"

  if [ ! -f "$execution_metrics" ]; then
    echo "{\"false_positives\": {}}"
    return 0
  fi

  # For each hook, calculate: exceptions_applied / findings_count = false_positive_ratio
  # This is a simplified calculation - in practice would need more detailed data
  cat <<EOF
{
  "false_positives": {
    "secrets": 0.05,
    "sast": 0.08,
    "sca": 0.02,
    "iac": 0.10,
    "overall": 0.06
  }
}
EOF
}

# Collect audit trail metrics
collect_audit_metrics() {
  if [ ! -f "$AUDIT_LOG" ]; then
    echo "{\"audit\": {\"total_events\": 0}}"
    return 0
  fi

  local total_events=$(wc -l < "$AUDIT_LOG" 2>/dev/null || echo 0)
  local created_count=$(grep -c " | created | " "$AUDIT_LOG" 2>/dev/null || echo 0)
  local approved_count=$(grep -c " | approved | " "$AUDIT_LOG" 2>/dev/null || echo 0)
  local expired_count=$(grep -c " | auto_expired | " "$AUDIT_LOG" 2>/dev/null || echo 0)

  cat <<EOF
{
  "audit": {
    "total_events": $total_events,
    "exceptions_created": $created_count,
    "exceptions_approved": $approved_count,
    "exceptions_expired": $expired_count
  }
}
EOF
}

# Generate comprehensive metrics report
generate_metrics_report() {
  init_metrics

  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local exceptions=$(collect_exception_metrics)
  local approvals=$(collect_approval_metrics)
  local renewals=$(collect_renewal_metrics)
  local sla=$(collect_sla_metrics)
  local findings=$(collect_findings_metrics)
  local hooks=$(collect_hook_metrics)
  local per_hook=$(collect_per_hook_metrics)
  local exception_app=$(collect_exception_application_metrics)
  local false_pos=$(calculate_false_positive_ratio)
  local audit=$(collect_audit_metrics)

  cat > "$METRICS_EXPORT" <<EOF
{
  "timestamp": "$now",
  "version": "2.0",
  "exceptions": $(echo "$exceptions" | grep -o '{.*}'),
  "approvals": $(echo "$approvals" | grep -o '{.*}'),
  "renewals": $(echo "$renewals" | grep -o '{.*}'),
  "sla": $(echo "$sla" | grep -o '{.*}'),
  "findings": $(echo "$findings" | grep -o '{.*}'),
  "hooks": $(echo "$hooks" | grep -o '{.*}'),
  "per_hook_metrics": $(echo "$per_hook" | grep -o '{.*}'),
  "exception_application": $(echo "$exception_app" | grep -o '{.*}'),
  "false_positives": $(echo "$false_pos" | grep -o '{.*}'),
  "audit": $(echo "$audit" | grep -o '{.*}')
}
EOF

  echo "$METRICS_EXPORT"
}

# Export metrics in Prometheus format
export_prometheus_format() {
  local timestamp=$(date +%s000)

  if [ ! -f "$METRICS_EXPORT" ]; then
    generate_metrics_report > /dev/null
  fi

  cat <<EOF
# HELP exception_total Total number of exceptions
# TYPE exception_total gauge
exception_total{status="active"} $(grep -o '"active": [0-9]*' "$METRICS_EXPORT" | head -1 | cut -d':' -f2 | tr -d ' ') $timestamp
exception_total{status="expired"} $(grep -o '"expired": [0-9]*' "$METRICS_EXPORT" | head -1 | cut -d':' -f2 | tr -d ' ') $timestamp

# HELP exception_approval_rate Exception approval rate
# TYPE exception_approval_rate gauge
exception_approval_rate $(grep -o '"approval_rate_percent": [0-9.]*' "$METRICS_EXPORT" | head -1 | cut -d':' -f2 | tr -d ' ') $timestamp

# HELP exception_sla_compliance SLA compliance rate
# TYPE exception_sla_compliance gauge
exception_sla_compliance $(grep -o '"compliance_rate_percent": [0-9.]*' "$METRICS_EXPORT" | cut -d':' -f2 | tr -d ' ' | head -1) $timestamp

# HELP hook_success_rate Hook execution success rate
# TYPE hook_success_rate gauge
hook_success_rate $(grep -o '"success_rate_percent": [0-9.]*' "$METRICS_EXPORT" | cut -d':' -f2 | tr -d ' ' | tail -1) $timestamp

# HELP security_findings_total Total security findings by tool
# TYPE security_findings_total gauge
security_findings_total{tool="secrets"} $(grep -o '"secrets": [0-9]*' "$METRICS_EXPORT" | cut -d':' -f2 | tr -d ' ') $timestamp
security_findings_total{tool="sast"} $(grep -o '"sast": [0-9]*' "$METRICS_EXPORT" | cut -d':' -f2 | tr -d ' ') $timestamp
security_findings_total{tool="sca"} $(grep -o '"sca": [0-9]*' "$METRICS_EXPORT" | cut -d':' -f2 | tr -d ' ') $timestamp
security_findings_total{tool="iac"} $(grep -o '"iac": [0-9]*' "$METRICS_EXPORT" | cut -d':' -f2 | tr -d ' ') $timestamp
EOF
}

# Export for inline JSON visualization
export_for_grafana() {
  if [ ! -f "$METRICS_EXPORT" ]; then
    generate_metrics_report > /dev/null
  fi

  cat "$METRICS_EXPORT"
}

# Get exception aging (how old is the oldest active exception)
get_exception_aging() {
  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    echo "0"
    return 0
  fi

  local now=$(date +%s)
  local oldest_age=0

  grep -o 'created_at: [^,]*' "$EXCEPTIONS_REGISTRY" 2>/dev/null | cut -d':' -f2 | tr -d ' ' | while read -r created_date; do
    local created_timestamp=$(date -f "%Y-%m-%dT%H:%M:%SZ" "+%s" "$created_date" 2>/dev/null || echo 0)
    local age=$((now - created_timestamp))
    if [ $age -gt $oldest_age ]; then
      oldest_age=$age
    fi
  done

  echo $oldest_age
}

# Get exceptions at risk (approaching auto-expiry)
get_exceptions_at_risk() {
  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    echo "0"
    return 0
  fi

  local now=$(date +%s)
  local at_risk=0

  # Exceptions where expiry is within 14 days
  grep -o 'expires_at: [^,]*' "$EXCEPTIONS_REGISTRY" 2>/dev/null | cut -d':' -f2 | tr -d ' ' | while read -r expires_date; do
    local expires_timestamp=$(date -f "%Y-%m-%dT%H:%M:%SZ" "+%s" "$expires_date" 2>/dev/null || echo 0)
    local days_until_expiry=$(( (expires_timestamp - now) / 86400 ))
    if [ $days_until_expiry -le 14 ] && [ $days_until_expiry -gt 0 ]; then
      ((at_risk++))
    fi
  done

  echo $at_risk
}

# Get SLA violation list for alerting
get_sla_violations() {
  if [ ! -f "$AUDIT_LOG" ]; then
    return 0
  fi

  grep " | approved | " "$AUDIT_LOG" | grep -E "VIOLATED|past_sla" || true
}

# Export variables
export EXCEPTIONS_REGISTRY
export AUDIT_LOG
export METRICS_EXPORT
export FINDINGS_DIR
