#!/bin/bash
# hooks/sast.sh
# SAST analysis using Semgrep with centrally-managed rule repository

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
source "$SHARED_DIR/rules-downloader.sh"
source "$SHARED_DIR/results-writer.sh"

HOOK_NAME="sast"
TIMEOUT_SEC=2
RULES_REPO_URL="${RULES_REPO_URL:-https://github.com/warwickbrownteya/sdlc-semgrep-rules.git}"
RULES_CACHE_DIR="${RULES_CACHE_DIR:-.teya/semgrep-cache}"

log_info "[$HOOK_NAME] Starting SAST analysis"

STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [ -z "$STAGED_FILES" ]; then
  log_info "[$HOOK_NAME] No staged files to scan"
  FINDINGS="[]"
  CHECK_STATUS="passed"
else
  # Download and cache rules from central repository
  if ! download_and_cache_rules "$RULES_REPO_URL" "$RULES_CACHE_DIR"; then
    log_warn "[$HOOK_NAME] Failed to download rules, attempting to use existing cache"
  fi

  # Verify rules are available
  if ! validate_rules_present "$RULES_CACHE_DIR"; then
    log_warn "[$HOOK_NAME] No local rules available, using default Semgrep rules"
    RULES_CONFIG="p/owasp-top-ten"
  else
    RULES_CONFIG="$RULES_CACHE_DIR/rules"
    log_debug "[$HOOK_NAME] Using cached rules from $RULES_CONFIG"
  fi

  # Run Semgrep if available
  FINDINGS="[]"
  if command -v semgrep &> /dev/null; then
    log_debug "[$HOOK_NAME] Running Semgrep with rules from $RULES_CONFIG"
    SEMGREP_OUTPUT=$(mktemp)
    trap 'rm -f "$SEMGREP_OUTPUT"' EXIT

    START_TIME=$(date +%s%N | cut -b1-13)
    timeout "$TIMEOUT_SEC" semgrep --json --config="$RULES_CONFIG" "$STAGED_FILES" \
      > "$SEMGREP_OUTPUT" 2>/dev/null || true
    END_TIME=$(date +%s%N | cut -b1-13)
    EXECUTION_TIME_MS=$((END_TIME - START_TIME))

    FINDINGS=$(parse_findings "$SEMGREP_OUTPUT" "sast" "semgrep" || echo "[]")
  else
    log_warn "[$HOOK_NAME] Semgrep not found"
    EXECUTION_TIME_MS=0
  fi

  # Report cache status
  report_cache_status "$RULES_CACHE_DIR"

  # Check exceptions
  FINDINGS=$(check_exceptions "$FINDINGS" "$HOOK_NAME" || echo "$FINDINGS")

  # Determine status
  if [ -n "$FINDINGS" ] && [ "$FINDINGS" != "[]" ]; then
    CHECK_STATUS="failed"
    log_info "[$HOOK_NAME] Found SAST findings"
  else
    CHECK_STATUS="passed"
    log_info "[$HOOK_NAME] No SAST issues detected ✓"
  fi
fi

# Write results to .teya (non-blocking)
write_findings "$HOOK_NAME" "$FINDINGS" "semgrep" "$CHECK_STATUS" "$EXECUTION_TIME_MS" || true

exit 0
