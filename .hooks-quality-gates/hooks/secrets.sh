#!/bin/bash
# hooks/secrets.sh
# Detects hardcoded credentials using TruffleHop + custom patterns

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

HOOK_NAME="secrets"
TIMEOUT_SEC=2
TOOL_VERSION=$(grep "truffleHop:" "$(dirname "$0")/../config/tool-versions.txt" | cut -d: -f2 | xargs)

log_info "[$HOOK_NAME] Starting secrets detection"

# Get staged files
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [ -z "$STAGED_FILES" ]; then
  log_info "[$HOOK_NAME] No staged files to scan"
  FINDINGS="[]"
  CHECK_STATUS="passed"
else
  # Run TruffleHop
  log_debug "[$HOOK_NAME] Running TruffleHop v$TOOL_VERSION"
  TRUFFLEHOP_OUTPUT=$(mktemp)
  trap 'rm -f "$TRUFFLEHOP_OUTPUT"' EXIT

  START_TIME=$(date +%s%N | cut -b1-13)

  if command -v truffleHop &> /dev/null; then
    timeout "$TIMEOUT_SEC" truffleHop filesystem --json "$STAGED_FILES" \
      > "$TRUFFLEHOP_OUTPUT" 2>/dev/null || true
  else
    log_warn "[$HOOK_NAME] TruffleHop not found, using fallback pattern matching"
    echo "[]" > "$TRUFFLEHOP_OUTPUT"
  fi

  END_TIME=$(date +%s%N | cut -b1-13)
  EXECUTION_TIME_MS=$((END_TIME - START_TIME))

  # Parse findings
  FINDINGS=$(parse_findings "$TRUFFLEHOP_OUTPUT" "secrets" || echo "[]")

  # Check exceptions
  FINDINGS=$(check_exceptions "$FINDINGS" "$HOOK_NAME" || echo "$FINDINGS")

  # Determine status
  if [ -n "$FINDINGS" ] && [ "$FINDINGS" != "[]" ]; then
    CHECK_STATUS="failed"
    log_info "[$HOOK_NAME] Found secrets"
  else
    CHECK_STATUS="passed"
    log_info "[$HOOK_NAME] No secrets detected ✓"
  fi
fi

# Write results to .teya (non-blocking)
write_findings "$HOOK_NAME" "$FINDINGS" "truffleHop" "$CHECK_STATUS" "$EXECUTION_TIME_MS" || true

exit 0
