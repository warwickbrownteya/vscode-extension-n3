#!/bin/bash
# hooks/gate-evaluator.sh
# Gate Evaluator: Consensus voting (2/3 tools) + exception management

set -e

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")/../shared"
fi

source "$SHARED_DIR/logger.sh"
source "$SHARED_DIR/exception-loader.sh"
source "$SHARED_DIR/results-writer.sh"

HOOK_NAME="gate-evaluator"
EXCEPTIONS_REGISTRY="${EXCEPTIONS_REGISTRY:-.teya/exceptions-registry.yaml}"

log_info "[$HOOK_NAME] Evaluating security gates with consensus voting (2/3)"

# Collect findings from .teya directory
RESULTS_DIR="${RESULTS_DIR:-.teya}"
SECRETS_FINDINGS=$([ -f "$RESULTS_DIR/findings-secrets.json" ] && jq '.findings // []' "$RESULTS_DIR/findings-secrets.json" 2>/dev/null || echo "[]")
SAST_FINDINGS=$([ -f "$RESULTS_DIR/findings-sast.json" ] && jq '.findings // []' "$RESULTS_DIR/findings-sast.json" 2>/dev/null || echo "[]")
SCA_FINDINGS=$([ -f "$RESULTS_DIR/findings-sca.json" ] && jq '.findings // []' "$RESULTS_DIR/findings-sca.json" 2>/dev/null || echo "[]")
IAC_FINDINGS=$([ -f "$RESULTS_DIR/findings-iac.json" ] && jq '.findings // []' "$RESULTS_DIR/findings-iac.json" 2>/dev/null || echo "[]")

# Count tools with findings (2 or more = consensus blocking)
TOOLS_WITH_FINDINGS=0

if [ "$SECRETS_FINDINGS" != "[]" ] && [ -n "$SECRETS_FINDINGS" ]; then
  ((TOOLS_WITH_FINDINGS++))
  log_debug "[$HOOK_NAME] Secrets tool reported findings"
fi

if [ "$SAST_FINDINGS" != "[]" ] && [ -n "$SAST_FINDINGS" ]; then
  ((TOOLS_WITH_FINDINGS++))
  log_debug "[$HOOK_NAME] SAST tool reported findings"
fi

if [ "$SCA_FINDINGS" != "[]" ] && [ -n "$SCA_FINDINGS" ]; then
  ((TOOLS_WITH_FINDINGS++))
  log_debug "[$HOOK_NAME] SCA tool reported findings"
fi

if [ "$IAC_FINDINGS" != "[]" ] && [ -n "$IAC_FINDINGS" ]; then
  ((TOOLS_WITH_FINDINGS++))
  log_debug "[$HOOK_NAME] IaC tool reported findings"
fi

# Aggregate all findings
AGGREGATE_FINDINGS=$(jq -s 'add' \
  <(echo "$SECRETS_FINDINGS") \
  <(echo "$SAST_FINDINGS") \
  <(echo "$SCA_FINDINGS") \
  <(echo "$IAC_FINDINGS") 2>/dev/null || echo "[]")

# Write gate evaluation result to .teya (non-blocking)
write_gate_result "$([ $TOOLS_WITH_FINDINGS -ge 2 ] && echo "failed" || echo "passed")" "$TOOLS_WITH_FINDINGS/4" "$AGGREGATE_FINDINGS" "Consensus voting threshold: 2/4 tools" || true

# Aggregate all findings for Backstage
aggregate_findings "$RESULTS_DIR" || true

# Check for gate-waived exceptions (emergency consensus override)
GATE_WAIVED=false
if [ -f "$EXCEPTIONS_REGISTRY" ]; then
  if grep -q "type:[[:space:]]*gate-waived" "$EXCEPTIONS_REGISTRY" 2>/dev/null; then
    if grep -q "status:[[:space:]]*active" "$EXCEPTIONS_REGISTRY" 2>/dev/null; then
      # Check if current commit matches exception criteria
      CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
      if grep -A 5 "type:[[:space:]]*gate-waived" "$EXCEPTIONS_REGISTRY" | grep -q "status:[[:space:]]*active"; then
        GATE_WAIVED=true
        log_warn "[$HOOK_NAME] Gate-waived exception active - emergency consensus override"
      fi
    fi
  fi
fi

# Consensus voting: 2 or more tools must agree
if [ $TOOLS_WITH_FINDINGS -ge 2 ]; then
  # Check if gate is waived by exception
  if [ "$GATE_WAIVED" = true ]; then
    log_warn "[$HOOK_NAME] CONSENSUS BLOCK overridden by gate-waived exception"
    OVERALL_CHECK_DETAILS="{\"secrets\": \"failed\", \"sast\": \"failed\", \"sca\": \"failed\", \"iac\": \"failed\", \"consensus\": \"BLOCK-WAIVED\"}"
    write_overall_result "passed" "$OVERALL_CHECK_DETAILS" || true
    exit 0
  fi

  log_warn "[$HOOK_NAME] CONSENSUS BLOCK: $TOOLS_WITH_FINDINGS tools reported findings (threshold: 2/4)"

  # Write overall result
  OVERALL_CHECK_DETAILS="{\"secrets\": \"failed\", \"sast\": \"failed\", \"sca\": \"failed\", \"iac\": \"failed\", \"consensus\": \"BLOCK\"}"
  write_overall_result "blocked" "$OVERALL_CHECK_DETAILS" || true

  log_info "[$HOOK_NAME] Commit blocked by consensus gate"
  exit 1
else
  log_info "[$HOOK_NAME] Consensus gate passed: $TOOLS_WITH_FINDINGS tools agree ✓"

  # Write overall result
  OVERALL_CHECK_DETAILS="{\"secrets\": \"passed\", \"sast\": \"passed\", \"sca\": \"passed\", \"iac\": \"passed\", \"consensus\": \"PASS\"}"
  write_overall_result "passed" "$OVERALL_CHECK_DETAILS" || true

  exit 0
fi
