#!/bin/bash
# shared/sdlc-validator.sh
# Validate .sdlc.n3 metadata and report SDLC maturity level

set -e

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

# Load logger
if [ -f "$SHARED_DIR/logger.sh" ]; then
  source "$SHARED_DIR/logger.sh"
else
  log_info() { echo "[INFO] $*"; }
  log_warn() { echo "[WARN] $*"; }
  log_error() { echo "[ERROR] $*"; }
  log_debug() { echo "[DEBUG] $*"; }
fi

HOOK_NAME="sdlc-validator"
SDLC_FILE="${SDLC_FILE:-.sdlc.n3}"
REPO_ROOT="${REPO_ROOT:-.}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# ===== VALIDATION FUNCTIONS =====

# Check if file exists
validate_file_exists() {
  if [ ! -f "$SDLC_FILE" ]; then
    log_error "[$HOOK_NAME] SDLC metadata file not found: $SDLC_FILE"
    return 1
  fi
  return 0
}

# Validate N3 syntax (basic parsing)
validate_n3_syntax() {
  log_debug "[$HOOK_NAME] Validating N3 syntax..."

  # Check for common N3 patterns
  if ! grep -q "@prefix\|@base\|rdf:type\|rdfs:label" "$SDLC_FILE"; then
    log_warn "[$HOOK_NAME] .sdlc.n3 missing expected N3 patterns"
  fi

  # Check for unclosed square brackets
  local open_brackets
  open_brackets=$(grep -o "\[" "$SDLC_FILE" | wc -l)
  local close_brackets
  close_brackets=$(grep -o "\]" "$SDLC_FILE" | wc -l)

  if [ "$open_brackets" -ne "$close_brackets" ]; then
    log_error "[$HOOK_NAME] N3 syntax error: bracket mismatch (open: $open_brackets, close: $close_brackets)"
    return 1
  fi

  # Check for unclosed parentheses
  local open_parens
  open_parens=$(grep -o "(" "$SDLC_FILE" | wc -l)
  local close_parens
  close_parens=$(grep -o ")" "$SDLC_FILE" | wc -l)

  if [ "$open_parens" -ne "$close_parens" ]; then
    log_error "[$HOOK_NAME] N3 syntax error: parenthesis mismatch (open: $open_parens, close: $close_parens)"
    return 1
  fi

  log_debug "[$HOOK_NAME] N3 syntax validation passed"
  return 0
}

# Validate required sections
validate_required_sections() {
  log_debug "[$HOOK_NAME] Validating required SDLC sections..."

  local required_sections=(
    "sdlc:planning"
    "sdlc:development"
    "sdlc:testing"
    "sdlc:security"
    "sdlc:deployment"
    "sdlc:operations"
  )

  local missing_sections=()

  for section in "${required_sections[@]}"; do
    if ! grep -q "$section" "$SDLC_FILE"; then
      log_warn "[$HOOK_NAME] Missing SDLC section: $section"
      missing_sections+=("$section")
    fi
  done

  if [ ${#missing_sections[@]} -gt 0 ]; then
    log_warn "[$HOOK_NAME] Missing ${#missing_sections[@]} SDLC sections"
    return 1  # Warning, not error
  fi

  log_debug "[$HOOK_NAME] All required sections present"
  return 0
}

# Validate file references
validate_file_references() {
  log_debug "[$HOOK_NAME] Validating file references..."

  local file_pattern='"[^"]*\.md|\.sh|\.json|\.yaml|\.n3"'
  local referenced_files=()
  local missing_files=()

  # Extract file paths from SDLC
  while IFS= read -r line; do
    # Extract quoted strings that look like file paths
    if [[ $line =~ \"([^\"]+\.(md|sh|json|yaml|n3|ttl))\" ]]; then
      local file="${BASH_REMATCH[1]}"
      referenced_files+=("$file")

      # Check if file exists
      if [ ! -f "$REPO_ROOT/$file" ]; then
        missing_files+=("$file")
      fi
    fi
  done < "$SDLC_FILE"

  if [ ${#missing_files[@]} -gt 0 ]; then
    log_warn "[$HOOK_NAME] ${#missing_files[@]} referenced files not found:"
    for f in "${missing_files[@]}"; do
      log_warn "  - $f"
    done
    return 1
  fi

  log_debug "[$HOOK_NAME] All ${#referenced_files[@]} referenced files validated"
  return 0
}

# Extract maturity level
extract_maturity_level() {
  # Look for sdlc:maturityLevel in the file
  local maturity
  maturity=$(grep -o "sdlc:maturityLevel[[:space:]]*sdlc:[A-Z_]*" "$SDLC_FILE" | cut -d':' -f3 | head -1)

  if [ -z "$maturity" ]; then
    maturity="UNKNOWN"
  fi

  echo "$maturity"
}

# Calculate maturity from completion percentages
calculate_maturity_score() {
  log_debug "[$HOOK_NAME] Calculating maturity score..."

  # Extract completion percentages for each stage (more robust extraction)
  local planning_pct
  planning_pct=$(grep "sdlc:PlanningStage" "$SDLC_FILE" -A 20 | grep "sdlc:completionPercentage" | grep -o "[0-9]\+" | head -1)
  planning_pct=${planning_pct:-0}

  local development_pct
  development_pct=$(grep "sdlc:DevelopmentStage" "$SDLC_FILE" -A 20 | grep "sdlc:completionPercentage" | grep -o "[0-9]\+" | head -1)
  development_pct=${development_pct:-0}

  local testing_pct
  testing_pct=$(grep "sdlc:TestingStage" "$SDLC_FILE" -A 20 | grep "sdlc:completionPercentage" | grep -o "[0-9]\+" | head -1)
  testing_pct=${testing_pct:-0}

  local security_pct
  security_pct=$(grep "sdlc:SecurityStage" "$SDLC_FILE" -A 20 | grep "sdlc:completionPercentage" | grep -o "[0-9]\+" | head -1)
  security_pct=${security_pct:-0}

  local deployment_pct
  deployment_pct=$(grep "sdlc:DeploymentStage" "$SDLC_FILE" -A 20 | grep "sdlc:completionPercentage" | grep -o "[0-9]\+" | head -1)
  deployment_pct=${deployment_pct:-0}

  local operations_pct
  operations_pct=$(grep "sdlc:OperationsStage" "$SDLC_FILE" -A 20 | grep "sdlc:completionPercentage" | grep -o "[0-9]\+" | head -1)
  operations_pct=${operations_pct:-0}

  # Calculate overall score (average of all stages)
  local total=$((planning_pct + development_pct + testing_pct + security_pct + deployment_pct + operations_pct))
  local overall_score=$((total / 6)) || overall_score=0

  log_debug "[$HOOK_NAME] Maturity scores: Planning=$planning_pct, Dev=$development_pct, Test=$testing_pct, Sec=$security_pct, Depl=$deployment_pct, Ops=$operations_pct"
  log_debug "[$HOOK_NAME] Overall score: $overall_score%"

  # Return scores (can be parsed by caller)
  echo "$overall_score|$planning_pct|$development_pct|$testing_pct|$security_pct|$deployment_pct|$operations_pct"
}

# Map score to maturity level
map_score_to_level() {
  local score="$1"

  if [ "$score" -lt 20 ]; then
    echo "AWAKENING"
  elif [ "$score" -lt 40 ]; then
    echo "ALIGNED"
  elif [ "$score" -lt 70 ]; then
    echo "INTEGRATED"
  elif [ "$score" -lt 90 ]; then
    echo "MEASURED"
  else
    echo "ADAPTIVE"
  fi
}

# Get maturity level description
get_maturity_description() {
  local level="$1"

  case "$level" in
    AWAKENING)
      echo "Ad hoc, chaotic processes; no formal methodology"
      ;;
    ALIGNED)
      echo "Process documented; team aware; basic tracking"
      ;;
    INTEGRATED)
      echo "Automated workflows; basic metrics; partial enforcement"
      ;;
    MEASURED)
      echo "Comprehensive metrics; SLI/SLO defined; data-driven decisions"
      ;;
    ADAPTIVE)
      echo "Continuous improvement; feedback loops; self-healing systems"
      ;;
    *)
      echo "Unknown maturity level: $level"
      ;;
  esac
}

# Extract gaps from SDLC file
extract_gaps() {
  log_debug "[$HOOK_NAME] Extracting maturity gaps..."

  local gaps=()

  # Look for sdlc:gap entries
  while IFS= read -r line; do
    if [[ $line =~ sdlc:gap[[:space:]]+\"([^\"]+)\" ]]; then
      gaps+=("${BASH_REMATCH[1]}")
    fi
  done < "$SDLC_FILE"

  for gap in "${gaps[@]}"; do
    echo "$gap"
  done
}

# Report maturity status
report_maturity() {
  local level="$1"
  local score="$2"
  local planning="$3"
  local development="$4"
  local testing="$5"
  local security="$6"
  local deployment="$7"
  local operations="$8"

  echo ""
  echo "========================================="
  echo "🎯 SDLC MATURITY ASSESSMENT"
  echo "========================================="
  echo ""

  # Color code the level
  case "$level" in
    AWAKENING) level_color="$RED" ;;
    ALIGNED) level_color="$YELLOW" ;;
    INTEGRATED) level_color="$BLUE" ;;
    MEASURED) level_color="$PURPLE" ;;
    ADAPTIVE) level_color="$GREEN" ;;
    *) level_color="$NC" ;;
  esac

  echo -e "Current Level: ${level_color}${level}${NC}"
  echo "Description: $(get_maturity_description "$level")"
  echo "Overall Score: ${score}%"
  echo ""

  echo "Stage Completion:"
  printf "  %-15s %3d%%\n" "Planning:" "${planning:-0}"
  printf "  %-15s %3d%%\n" "Development:" "${development:-0}"
  printf "  %-15s %3d%%\n" "Testing:" "${testing:-0}"
  printf "  %-15s %3d%%\n" "Security:" "${security:-0}"
  printf "  %-15s %3d%%\n" "Deployment:" "${deployment:-0}"
  printf "  %-15s %3d%%\n" "Operations:" "${operations:-0}"
  echo ""

  # Show gaps
  local gaps=()
  while IFS= read -r gap; do
    [ -n "$gap" ] && gaps+=("$gap")
  done < <(extract_gaps)

  if [ ${#gaps[@]} -gt 0 ]; then
    echo "⚠️  Maturity Gaps:"
    for gap in "${gaps[@]}"; do
      echo "  - $gap"
    done
    echo ""
  fi

  # Show next level guidance
  case "$level" in
    AWAKENING)
      echo "🚀 Next Level: ALIGNED"
      echo "   To reach ALIGNED, ensure:"
      echo "   - [ ] All lifecycle stages documented"
      echo "   - [ ] Team aware of SDLC process"
      echo "   - [ ] Basic change tracking (git commits)"
      ;;
    ALIGNED)
      echo "🚀 Next Level: INTEGRATED"
      echo "   To reach INTEGRATED, ensure:"
      echo "   - [ ] Pre-commit hooks automated"
      echo "   - [ ] Test coverage >= 70%"
      echo "   - [ ] Security scanning enabled"
      echo "   - [ ] Staging environment deployed"
      ;;
    INTEGRATED)
      echo "🚀 Next Level: MEASURED"
      echo "   To reach MEASURED, ensure:"
      echo "   - [ ] SLI/SLO defined for key metrics"
      echo "   - [ ] Prometheus + Grafana monitoring"
      echo "   - [ ] Alerting rules configured"
      echo "   - [ ] Dashboard with team metrics"
      ;;
    MEASURED)
      echo "🚀 Next Level: ADAPTIVE"
      echo "   To reach ADAPTIVE, ensure:"
      echo "   - [ ] Feedback loops operational"
      echo "   - [ ] Auto-remediation enabled"
      echo "   - [ ] Predictive analytics in place"
      echo "   - [ ] Continuous improvement culture"
      ;;
    ADAPTIVE)
      echo "✨ ADAPTIVE LEVEL ACHIEVED"
      echo "   Maintain through:"
      echo "   - Quarterly maturity reviews"
      echo "   - Cross-org knowledge sharing"
      echo "   - Industry leadership & innovation"
      ;;
  esac

  echo ""
  echo "========================================="
}

# Main validation function
validate_sdlc() {
  log_info "[$HOOK_NAME] Validating SDLC metadata (.sdlc.n3)"

  # Run all validations
  local validation_failed=0

  validate_file_exists || validation_failed=1
  validate_n3_syntax || validation_failed=1
  validate_required_sections || true  # Warning, not error
  validate_file_references || true     # Warning, not error

  if [ $validation_failed -eq 1 ]; then
    log_error "[$HOOK_NAME] SDLC validation failed"
    return 1
  fi

  # Continue with maturity report even if some files referenced don't exist yet
  # (they're aspirational goals)

  # Calculate and report maturity
  local maturity_data
  maturity_data=$(calculate_maturity_score)

  local overall_score
  overall_score=$(echo "$maturity_data" | cut -d'|' -f1)

  local planning_pct
  planning_pct=$(echo "$maturity_data" | cut -d'|' -f2)

  local development_pct
  development_pct=$(echo "$maturity_data" | cut -d'|' -f3)

  local testing_pct
  testing_pct=$(echo "$maturity_data" | cut -d'|' -f4)

  local security_pct
  security_pct=$(echo "$maturity_data" | cut -d'|' -f5)

  local deployment_pct
  deployment_pct=$(echo "$maturity_data" | cut -d'|' -f6)

  local operations_pct
  operations_pct=$(echo "$maturity_data" | cut -d'|' -f7)

  # Extract declared level or calculate from score
  local declared_level
  declared_level=$(extract_maturity_level)

  local calculated_level
  calculated_level=$(map_score_to_level "$overall_score")

  # Use declared level if present, otherwise use calculated
  local final_level
  if [ "$declared_level" = "UNKNOWN" ]; then
    final_level="$calculated_level"
  else
    final_level="$declared_level"
  fi

  # Report maturity
  report_maturity "$final_level" "$overall_score" "$planning_pct" "$development_pct" "$testing_pct" "$security_pct" "$deployment_pct" "$operations_pct"

  log_info "[$HOOK_NAME] SDLC validation completed successfully (Level: $final_level)"
  return 0
}

# Allow direct invocation with optional arguments
case "${1:-validate}" in
  validate)
    validate_sdlc
    ;;
  score)
    calculate_maturity_score
    ;;
  gaps)
    extract_gaps
    ;;
  level)
    extract_maturity_level
    ;;
  *)
    log_error "Unknown command: $1"
    echo "Usage: $0 [validate|score|gaps|level]"
    exit 1
    ;;
esac

export SDLC_FILE
export HOOK_NAME
