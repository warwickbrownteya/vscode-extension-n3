#!/bin/bash
# hooks/iac.sh
# Infrastructure as Code (IaC) scanning using Checkov

set -e

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")/../shared"
fi

source "$SHARED_DIR/logger.sh"
source "$SHARED_DIR/exception-loader.sh"
source "$SHARED_DIR/findings-parser.sh"
source "$SHARED_DIR/results-writer.sh"

HOOK_NAME="iac"
TIMEOUT_SEC=3

log_info "[$HOOK_NAME] Starting IaC scanning"

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [ -z "$STAGED_FILES" ]; then
  log_info "[$HOOK_NAME] No staged files to scan"
  FINDINGS="[]"
  CHECK_STATUS="passed"
else
  # Filter for IaC files
  IaC_FILES=$(echo "$STAGED_FILES" | grep -E "\.(tf|yaml|yml|json|bicep)$" || true)

  if [ -z "$IaC_FILES" ]; then
    log_info "[$HOOK_NAME] No IaC files to scan"
    FINDINGS="[]"
    CHECK_STATUS="passed"
  else
    FINDINGS="[]"

    # Run Checkov if available
    if command -v checkov &> /dev/null; then
      log_debug "[$HOOK_NAME] Running Checkov"
      CHECKOV_OUTPUT=$(mktemp)
      trap 'rm -f "$CHECKOV_OUTPUT"' EXIT

      START_TIME=$(date +%s%N | cut -b1-13)
      timeout "$TIMEOUT_SEC" checkov --framework terraform,cloudformation,kubernetes,helm,bicep \
        --compact --quiet --output json "$IaC_FILES" \
        > "$CHECKOV_OUTPUT" 2>/dev/null || true
      END_TIME=$(date +%s%N | cut -b1-13)
      EXECUTION_TIME_MS=$((END_TIME - START_TIME))

      FINDINGS=$(parse_findings "$CHECKOV_OUTPUT" "iac" "checkov" || echo "[]")
    else
      log_warn "[$HOOK_NAME] Checkov not found"
      EXECUTION_TIME_MS=0
    fi

    # Check exceptions
    FINDINGS=$(check_exceptions "$FINDINGS" "$HOOK_NAME" || echo "$FINDINGS")

    # Determine status
    if [ -n "$FINDINGS" ] && [ "$FINDINGS" != "[]" ]; then
      CHECK_STATUS="failed"
      log_info "[$HOOK_NAME] Found IaC issues"
    else
      CHECK_STATUS="passed"
      log_info "[$HOOK_NAME] No IaC issues detected ✓"
    fi
  fi
fi

# Write results to .teya (non-blocking)
write_findings "$HOOK_NAME" "$FINDINGS" "checkov" "$CHECK_STATUS" "$EXECUTION_TIME_MS" || true

exit 0
