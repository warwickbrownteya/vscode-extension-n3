#!/bin/bash
# shared/linter-runner.sh
# Optional linting for popular languages and formats (can be disabled/configured)

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"

HOOK_NAME="linters"
LINTERS_ENABLED="${LINTERS_ENABLED:-true}"  # Set to false to disable all linters
LINTERS_TIMEOUT_SEC="${LINTERS_TIMEOUT_SEC:-5}"
LINTERS_FAIL_ON_ERROR="${LINTERS_FAIL_ON_ERROR:-false}"  # Warning only, don't block

# Get staged files
get_staged_files() {
  git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true
}

# Run ESLint for JavaScript/TypeScript
run_eslint() {
  local staged_files="$1"
  local js_files=$(echo "$staged_files" | grep -E "\.(js|jsx|ts|tsx)$" || true)

  if [ -z "$js_files" ]; then
    return 0
  fi

  if ! command -v eslint &> /dev/null; then
    log_debug "[$HOOK_NAME] ESLint not found, skipping JavaScript linting"
    return 0
  fi

  log_debug "[$HOOK_NAME] Running ESLint on JavaScript/TypeScript files"

  if timeout $LINTERS_TIMEOUT_SEC eslint $js_files 2>/dev/null; then
    log_debug "[$HOOK_NAME] ESLint: passed"
    return 0
  else
    log_warn "[$HOOK_NAME] ESLint found issues (non-blocking)"
    return 1
  fi
}

# Run Prettier for code formatting
run_prettier() {
  local staged_files="$1"
  local format_files=$(echo "$staged_files" | grep -E "\.(js|jsx|ts|tsx|css|scss|json|md|yaml|yml)$" || true)

  if [ -z "$format_files" ]; then
    return 0
  fi

  if ! command -v prettier &> /dev/null; then
    log_debug "[$HOOK_NAME] Prettier not found, skipping format linting"
    return 0
  fi

  log_debug "[$HOOK_NAME] Running Prettier on code files"

  # Check formatting (--check doesn't modify files)
  if timeout $LINTERS_TIMEOUT_SEC prettier --check $format_files 2>/dev/null; then
    log_debug "[$HOOK_NAME] Prettier: passed"
    return 0
  else
    log_warn "[$HOOK_NAME] Prettier formatting issues detected (non-blocking)"
    log_warn "[$HOOK_NAME] Run: prettier --write <files> to auto-fix"
    return 1
  fi
}

# Run Pylint for Python
run_pylint() {
  local staged_files="$1"
  local py_files=$(echo "$staged_files" | grep -E "\.py$" || true)

  if [ -z "$py_files" ]; then
    return 0
  fi

  if ! command -v pylint &> /dev/null; then
    log_debug "[$HOOK_NAME] Pylint not found, skipping Python linting"
    return 0
  fi

  log_debug "[$HOOK_NAME] Running Pylint on Python files"

  if timeout $LINTERS_TIMEOUT_SEC pylint $py_files 2>/dev/null; then
    log_debug "[$HOOK_NAME] Pylint: passed"
    return 0
  else
    log_warn "[$HOOK_NAME] Pylint found issues (non-blocking)"
    return 1
  fi
}

# Run ShellCheck for Bash/Shell scripts
run_shellcheck() {
  local staged_files="$1"
  local shell_files=$(echo "$staged_files" | grep -E "\.(sh|bash)$" || true)

  if [ -z "$shell_files" ]; then
    return 0
  fi

  if ! command -v shellcheck &> /dev/null; then
    log_debug "[$HOOK_NAME] ShellCheck not found, skipping shell linting"
    return 0
  fi

  log_debug "[$HOOK_NAME] Running ShellCheck on shell scripts"

  if timeout $LINTERS_TIMEOUT_SEC shellcheck $shell_files 2>/dev/null; then
    log_debug "[$HOOK_NAME] ShellCheck: passed"
    return 0
  else
    log_warn "[$HOOK_NAME] ShellCheck found issues (non-blocking)"
    return 1
  fi
}

# Run YAML linter
run_yamllint() {
  local staged_files="$1"
  local yaml_files=$(echo "$staged_files" | grep -E "\.(yaml|yml)$" || true)

  if [ -z "$yaml_files" ]; then
    return 0
  fi

  if ! command -v yamllint &> /dev/null; then
    log_debug "[$HOOK_NAME] yamllint not found, skipping YAML linting"
    return 0
  fi

  log_debug "[$HOOK_NAME] Running yamllint on YAML files"

  if timeout $LINTERS_TIMEOUT_SEC yamllint $yaml_files 2>/dev/null; then
    log_debug "[$HOOK_NAME] yamllint: passed"
    return 0
  else
    log_warn "[$HOOK_NAME] yamllint found issues (non-blocking)"
    return 1
  fi
}

# Run JSON linter
run_jsonlint() {
  local staged_files="$1"
  local json_files=$(echo "$staged_files" | grep -E "\.json$" || true)

  if [ -z "$json_files" ]; then
    return 0
  fi

  # Try jq for JSON validation (built-in on most systems)
  log_debug "[$HOOK_NAME] Validating JSON files"

  local has_errors=0
  for json_file in $json_files; do
    if ! jq empty "$json_file" 2>/dev/null; then
      log_warn "[$HOOK_NAME] Invalid JSON: $json_file (non-blocking)"
      has_errors=1
    fi
  done

  [ $has_errors -eq 0 ]
}

# Run Markdown linter
run_markdownlint() {
  local staged_files="$1"
  local md_files=$(echo "$staged_files" | grep -E "\.md$" || true)

  if [ -z "$md_files" ]; then
    return 0
  fi

  if ! command -v markdownlint &> /dev/null; then
    log_debug "[$HOOK_NAME] markdownlint not found, skipping Markdown linting"
    return 0
  fi

  log_debug "[$HOOK_NAME] Running markdownlint on Markdown files"

  if timeout $LINTERS_TIMEOUT_SEC markdownlint $md_files 2>/dev/null; then
    log_debug "[$HOOK_NAME] markdownlint: passed"
    return 0
  else
    log_warn "[$HOOK_NAME] markdownlint found issues (non-blocking)"
    return 1
  fi
}

# Main function: run all available linters
run_linters() {
  if [ "$LINTERS_ENABLED" != "true" ]; then
    log_debug "[$HOOK_NAME] Linting disabled"
    return 0
  fi

  log_info "[$HOOK_NAME] Running optional linters (non-blocking)"

  local staged_files=$(get_staged_files)

  if [ -z "$staged_files" ]; then
    log_debug "[$HOOK_NAME] No staged files to lint"
    return 0
  fi

  local linter_errors=0

  # Run each linter
  run_eslint "$staged_files" || ((linter_errors++))
  run_prettier "$staged_files" || ((linter_errors++))
  run_pylint "$staged_files" || ((linter_errors++))
  run_shellcheck "$staged_files" || ((linter_errors++))
  run_yamllint "$staged_files" || ((linter_errors++))
  run_jsonlint "$staged_files" || ((linter_errors++))
  run_markdownlint "$staged_files" || ((linter_errors++))

  if [ $linter_errors -gt 0 ]; then
    log_warn "[$HOOK_NAME] $linter_errors linter(s) found issues (non-blocking)"

    if [ "$LINTERS_FAIL_ON_ERROR" = "true" ]; then
      log_error "[$HOOK_NAME] Failing commit due to linter errors (LINTERS_FAIL_ON_ERROR=true)"
      return 1
    else
      log_info "[$HOOK_NAME] Linter issues ignored (warnings only)"
      return 0
    fi
  fi

  log_info "[$HOOK_NAME] All linters passed ✓"
  return 0
}

# Configure linters
show_linter_configuration() {
  cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║             Quality Gates: Linter Configuration                ║
╚════════════════════════════════════════════════════════════════╝

Optional linters run on every commit (non-blocking by default).

SUPPORTED LINTERS:
  • ESLint      - JavaScript/TypeScript
  • Prettier    - Code formatting
  • Pylint      - Python
  • ShellCheck  - Bash/Shell scripts
  • yamllint    - YAML files
  • jq          - JSON validation
  • markdownlint - Markdown files

DISABLE ALL LINTERS:
  # Globally
  git config --global hooks.linters false

  # Per repository
  git config hooks.linters false

  # Per commit
  LINTERS_ENABLED=false git commit -m "..."

FAIL ON LINTER ERRORS:
  # Fail commits with linter issues (instead of warning-only)
  git config hooks.lintersFail true
  # or: LINTERS_FAIL_ON_ERROR=true git commit -m "..."

ADJUST LINTER TIMEOUT:
  # Increase timeout for slow linters (seconds)
  LINTERS_TIMEOUT_SEC=10 git commit -m "..."

CONFIGURE LINTERS:
  # Create .eslintrc.json for ESLint
  # Create .prettierrc for Prettier
  # Create .yamllint for yamllint
  # Create .pylintrc for Pylint
  # Create .markdownlintrc for markdownlint

INSTALL LINTERS:
  # macOS
  brew install eslint prettier yamllint shellcheck

  # Linux
  sudo apt-get install yamllint shellcheck
  npm install -g eslint prettier markdownlint

  # Python
  pip install pylint yamllint

For more information:
  • ESLint: https://eslint.org/
  • Prettier: https://prettier.io/
  • Pylint: https://www.pylint.org/
  • ShellCheck: https://www.shellcheck.net/
  • yamllint: https://yamllint.readthedocs.io/

EOF
}

# Disable linters for this commit
disable_linters() {
  log_warn "[$HOOK_NAME] Linters disabled for this commit"
  export LINTERS_ENABLED=false
}
