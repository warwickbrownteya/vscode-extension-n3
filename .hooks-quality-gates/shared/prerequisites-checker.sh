#!/bin/bash
# shared/prerequisites-checker.sh
# Check if required prerequisites are installed
# Warns developer if missing and offers installation

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"

HOOK_NAME="prerequisites-checker"

# Minimum required tools for Quality Gates to function
REQUIRED_TOOLS=("git" "jq")

# Optional but recommended tools
OPTIONAL_TOOLS=("semgrep" "checkov" "eslint" "shellcheck")

# Check prerequisites
check_prerequisites() {
  local missing_required=()
  local missing_optional=()
  
  log_debug "[$HOOK_NAME] Checking for required tools"
  
  # Check required tools
  for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      missing_required+=("$tool")
    fi
  done
  
  # Check optional tools
  for tool in "${OPTIONAL_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      missing_optional+=("$tool")
    fi
  done
  
  # Report missing required tools
  if [ ${#missing_required[@]} -gt 0 ]; then
    log_error "[$HOOK_NAME] Missing required tools: ${missing_required[*]}"
    log_error "[$HOOK_NAME] Quality Gates cannot function without: ${missing_required[*]}"
    
    echo ""
    echo "❌ MISSING REQUIRED PREREQUISITES"
    echo "=================================================="
    echo ""
    echo "Quality Gates requires the following tools:"
    for tool in "${missing_required[@]}"; do
      echo "  • $tool (REQUIRED)"
    done
    echo ""
    echo "Install prerequisites with:"
    echo ""
    echo "  curl -fsSL https://github.com/warwickbrownteya/sdlc-quality-gates/raw/main/install-prerequisites.sh | sh -"
    echo ""
    echo "=================================================="
    echo ""
    return 1
  fi
  
  # Report missing optional tools (warning only)
  if [ ${#missing_optional[@]} -gt 0 ]; then
    log_warn "[$HOOK_NAME] Missing optional tools: ${missing_optional[*]}"
    
    echo ""
    echo "⚠️  MISSING OPTIONAL SECURITY TOOLS"
    echo "=================================================="
    echo ""
    echo "Quality Gates works with core tools only, but these optional"
    echo "security scanners are recommended for better coverage:"
    echo ""
    for tool in "${missing_optional[@]}"; do
      echo "  • $tool"
    done
    echo ""
    echo "Install all tools (including optional) with:"
    echo ""
    echo "  curl -fsSL https://github.com/warwickbrownteya/sdlc-quality-gates/raw/main/install-prerequisites.sh | sh -"
    echo ""
    echo "Continue anyway? (Press Ctrl+C to cancel, or Enter to continue)"
    read -r
    echo "=================================================="
    echo ""
  fi
  
  return 0
}

# Main function
prerequisites_ok() {
  check_prerequisites
}
