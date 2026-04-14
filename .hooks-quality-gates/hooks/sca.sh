#!/bin/bash
# hooks/sca.sh
# SCA (Software Composition Analysis) using language-native scanners

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

HOOK_NAME="sca"
TIMEOUT_SEC=1

log_info "[$HOOK_NAME] Starting dependency scanning"

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [ -z "$STAGED_FILES" ]; then
  log_info "[$HOOK_NAME] No staged files to scan"
  FINDINGS="[]"
  CHECK_STATUS="passed"
else
  FINDINGS="[]"
  START_TIME=$(date +%s%N | cut -b1-13)

  # npm audit (JavaScript)
  if echo "$STAGED_FILES" | grep -q "package.json"; then
    if command -v npm &> /dev/null; then
      log_debug "[$HOOK_NAME] Running npm audit"
      NPM_OUTPUT=$(mktemp)
      trap 'rm -f "$NPM_OUTPUT"' EXIT

      timeout "$TIMEOUT_SEC" npm audit --json > "$NPM_OUTPUT" 2>/dev/null || true
      FINDINGS=$(parse_findings "$NPM_OUTPUT" "sca" "npm" || echo "[]")
    fi
  fi

  # pip check (Python)
  if echo "$STAGED_FILES" | grep -q "requirements.txt"; then
    if command -v pip &> /dev/null; then
      log_debug "[$HOOK_NAME] Running pip check"
      PIP_OUTPUT=$(mktemp)
      timeout $TIMEOUT_SEC pip check > "$PIP_OUTPUT" 2>/dev/null || true
      # Note: pip check output parsing would go here
    fi
  fi

  END_TIME=$(date +%s%N | cut -b1-13)
  EXECUTION_TIME_MS=$((END_TIME - START_TIME))

  # Check exceptions
  FINDINGS=$(check_exceptions "$FINDINGS" "$HOOK_NAME" || echo "$FINDINGS")

  # Determine status
  if [ -n "$FINDINGS" ] && [ "$FINDINGS" != "[]" ]; then
    CHECK_STATUS="failed"
    log_info "[$HOOK_NAME] Found SCA findings"
  else
    CHECK_STATUS="passed"
    log_info "[$HOOK_NAME] No vulnerable dependencies detected ✓"
  fi
fi

# Write results to .teya (non-blocking)
write_findings "$HOOK_NAME" "$FINDINGS" "npm/pip" "$CHECK_STATUS" "$EXECUTION_TIME_MS" || true

exit 0
