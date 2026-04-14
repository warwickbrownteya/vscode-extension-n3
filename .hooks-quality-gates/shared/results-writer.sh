#!/bin/bash
# shared/results-writer.sh
# Write security check results to .teya directory for analysis and Backstage integration

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"

HOOK_NAME="results-writer"
RESULTS_DIR="${RESULTS_DIR:-.teya}"

# Write findings result to JSON file (non-blocking)
write_findings() {
  local check_type="$1"      # "secrets", "sast", "sca", "iac", "gate-evaluator"
  local findings="$2"        # JSON findings object or array
  local tool_name="$3"       # "truffleHop", "semgrep", "npm", "checkov", etc.
  local check_status="$4"    # "passed" or "failed"
  local execution_time_ms="$5" # Execution time in milliseconds (optional)

  log_debug "[$HOOK_NAME] Writing results for $check_type check"

  local results_file="$RESULTS_DIR/findings-${check_type}.json"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Count findings
  local finding_count=0
  if [ -n "$findings" ] && [ "$findings" != "[]" ] && [ "$findings" != "{}" ]; then
    finding_count=$(echo "$findings" | grep -o '"severity"' 2>/dev/null | wc -l)
  fi

  # Build result JSON
  local temp_result
  temp_result=$(mktemp)
  trap 'rm -f "$temp_result"' RETURN

  {
    echo "{"
    echo "  \"check_type\": \"$check_type\","
    echo "  \"tool\": \"$tool_name\","
    echo "  \"status\": \"$check_status\","
    echo "  \"timestamp\": \"$timestamp\","
    echo "  \"finding_count\": $finding_count,"
    if [ -n "$execution_time_ms" ]; then
      echo "  \"execution_time_ms\": $execution_time_ms,"
    fi
    echo "  \"findings\": $findings"
    echo "}"
  } > "$temp_result"

  # Write to file (atomic operation)
  mkdir -p "$RESULTS_DIR"
  mv "$temp_result" "$results_file"

  log_debug "[$HOOK_NAME] Results written to $results_file"
  return 0
}

# Write overall gate evaluation result
write_gate_result() {
  local gate_status="$1"     # "passed" or "failed"
  local consensus_votes="$2" # Number of tools that agreed (e.g., "2/3")
  local blocking_findings="$3" # JSON array of blocking findings
  local details="$4"         # Additional details (optional)

  log_debug "[$HOOK_NAME] Writing gate evaluation result"

  local results_file="$RESULTS_DIR/findings-gate-evaluation.json"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local temp_result
  temp_result=$(mktemp)
  trap 'rm -f "$temp_result"' RETURN

  {
    echo "{"
    echo "  \"check_type\": \"gate-evaluator\","
    echo "  \"status\": \"$gate_status\","
    echo "  \"timestamp\": \"$timestamp\","
    echo "  \"consensus_votes\": \"$consensus_votes\","
    echo "  \"blocking_findings\": $blocking_findings"
    if [ -n "$details" ]; then
      echo ",  \"details\": \"$details\""
    fi
    echo "}"
  } > "$temp_result"

  mkdir -p "$RESULTS_DIR"
  mv "$temp_result" "$results_file"

  log_debug "[$HOOK_NAME] Gate result written to $results_file"
  return 0
}

# Write overall Quality Gates pass/fail result
write_overall_result() {
  local overall_status="$1"  # "passed" or "blocked"
  local check_details="$2"   # JSON object with all check statuses

  log_debug "[$HOOK_NAME] Writing overall Quality Gates result"

  local results_file="$RESULTS_DIR/quality-gates-result.json"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local temp_result
  temp_result=$(mktemp)
  trap 'rm -f "$temp_result"' RETURN

  {
    echo "{"
    echo "  \"overall_status\": \"$overall_status\","
    echo "  \"timestamp\": \"$timestamp\","
    echo "  \"checks\": $check_details"
    echo "}"
  } > "$temp_result"

  mkdir -p "$RESULTS_DIR"
  mv "$temp_result" "$results_file"

  log_debug "[$HOOK_NAME] Overall result written to $results_file"
  return 0
}

# Aggregate all findings from individual check results
aggregate_findings() {
  log_debug "[$HOOK_NAME] Aggregating all findings"

  local results_dir="${1:-.teya}"
  local temp_aggregate
  temp_aggregate=$(mktemp)
  trap 'rm -f "$temp_aggregate"' RETURN

  local total_findings=0
  local checks_passed=0
  local checks_failed=0

  {
    echo "{"
    echo "  \"aggregated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"checks\": ["
  } > "$temp_aggregate"

  local first=true

  # Read all findings-*.json files (excluding summary and gate-evaluation)
  for findings_file in "$results_dir"/findings-*.json; do
    if [ -f "$findings_file" ]; then
      local basename
      basename=$(basename "$findings_file")

        # Skip gate and summary files (handled separately)
        if [[ "$basename" == "findings-gate-evaluation.json" ]] || [[ "$basename" == "findings-summary.json" ]]; then
          continue
        fi

        if [ "$first" = true ]; then
          first=false
        else
          echo "," >> "$temp_aggregate"
        fi

        # Read and append findings file content
        cat "$findings_file" >> "$temp_aggregate"

        # Count findings and status
        local status
        status=$(grep -o '"status": "[^"]*"' "$findings_file" 2>/dev/null | head -1 | cut -d'"' -f4)
        local finding_count
        finding_count=$(grep -o '"finding_count": [0-9]*' "$findings_file" 2>/dev/null | cut -d':' -f2 | tr -d ' ')

        if [ -n "$finding_count" ]; then
          total_findings=$((total_findings + finding_count))
        fi

        if [ "$status" = "passed" ]; then
          ((checks_passed++))
        elif [ "$status" = "failed" ]; then
          ((checks_failed++))
        fi
      fi
    done

  {
    echo ""
    echo "  ],"
    echo "  \"summary\": {"
    echo "    \"total_findings\": $total_findings,"
    echo "    \"checks_passed\": $checks_passed,"
    echo "    \"checks_failed\": $checks_failed"
    echo "  }"
    echo "}"
  } >> "$temp_aggregate"

  mkdir -p "$results_dir"
  mv "$temp_aggregate" "$results_dir/findings-summary.json"

  log_debug "[$HOOK_NAME] Aggregate written to $results_dir/findings-summary.json"
  return 0
}

# Get findings summary for Backstage
get_findings_summary() {
  local results_dir="${1:-.teya}"

  if [ -f "$results_dir/findings-summary.json" ]; then
    cat "$results_dir/findings-summary.json"
  else
    echo "{}"
  fi
}

# Clean old results (optional - for testing)
cleanup_old_results() {
  local results_dir="${1:-.teya}"
  local retention_days="${2:-30}"

  log_debug "[$HOOK_NAME] Cleaning results older than $retention_days days"

  find "$results_dir" -name "findings-*.json" -type f -mtime "+$retention_days" -delete 2>/dev/null || true
  find "$results_dir" -name "quality-gates-result.json" -type f -mtime "+$retention_days" -delete 2>/dev/null || true

  log_debug "[$HOOK_NAME] Old results cleanup completed"
  return 0
}
