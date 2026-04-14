#!/bin/bash
# shared/exception-loader.sh
# Load and match findings against exception registry

EXCEPTIONS_REGISTRY="${EXCEPTIONS_REGISTRY:-.teya/exceptions-registry.yaml}"
EXCEPTIONS_BACKUP="${EXCEPTIONS_REGISTRY}.backup"

# Determine shared library directory
if [ -n "$SHARED_DIR" ]; then
  : # SHARED_DIR already set by caller
elif [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SHARED_DIR="$SCRIPT_DIR"
fi

# Context variables for scope matching
CURRENT_REPO="${CURRENT_REPO:-}"
CURRENT_TEAM="${CURRENT_TEAM:-}"
CURRENT_ORG="${CURRENT_ORG:-teya}"

# Source logger if available
if [ -f "$SHARED_DIR/logger.sh" ]; then
  source "$SHARED_DIR/logger.sh"
else
  # Fallback logging functions
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_debug() { echo "[DEBUG] $*" >&2; }
fi

# Validate YAML syntax of exception registry
# Returns 0 if valid, 1 if invalid
validate_yaml_syntax() {
  local registry_file="$1"

  if [ ! -f "$registry_file" ]; then
    log_error "[exception-loader] Registry file not found: $registry_file"
    return 1
  fi

  # Check if yamllint is available
  if command -v yamllint &> /dev/null; then
    if yamllint "$registry_file" >/dev/null 2>&1; then
      log_debug "[exception-loader] YAML syntax valid (yamllint)"
      return 0
    else
      log_error "[exception-loader] YAML syntax invalid: $(yamllint "$registry_file" 2>&1 | head -1)"
      return 1
    fi
  fi

  # Fallback: basic YAML structure validation
  log_debug "[exception-loader] Using fallback YAML validation"

  # Check for common YAML errors
  # 1. Must start with 'version:' or 'exceptions:'
  if ! head -1 "$registry_file" | grep -q "^version:"; then
    log_error "[exception-loader] Registry must start with 'version:'"
    return 1
  fi

  # 2. Check for balanced quotes
  local quote_count=$(grep -o '"' "$registry_file" | wc -l)
  if [ $((quote_count % 2)) -ne 0 ]; then
    log_error "[exception-loader] Unbalanced quotes in registry"
    return 1
  fi

  # 3. Check for required fields in exceptions
  if grep -q "^exceptions:" "$registry_file"; then
    local has_id=0
    local has_type=0

    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*id: ]]; then
        ((has_id++))
      fi
      if [[ "$line" =~ ^[[:space:]]*type: ]]; then
        ((has_type++))
      fi
    done < "$registry_file"

    if [ $has_id -eq 0 ] || [ $has_type -eq 0 ]; then
      log_error "[exception-loader] Registry missing required 'id' or 'type' fields"
      return 1
    fi
  fi

  log_debug "[exception-loader] YAML structure valid (fallback validation)"
  return 0
}

# Create backup of current registry if valid
backup_registry() {
  local registry_file="$1"
  local backup_file="${2:-${registry_file}.backup}"

  if [ ! -f "$registry_file" ]; then
    log_debug "[exception-loader] No registry to backup (file doesn't exist)"
    return 0
  fi

  # Only backup if current version is valid
  if validate_yaml_syntax "$registry_file"; then
    cp "$registry_file" "$backup_file"
    log_debug "[exception-loader] Registry backed up to $backup_file"
    return 0
  else
    log_warn "[exception-loader] Registry invalid, skipping backup"
    return 1
  fi
}

# Restore registry from backup if current is corrupted
restore_from_backup() {
  local registry_file="$1"
  local backup_file="${2:-${registry_file}.backup}"

  if [ ! -f "$backup_file" ]; then
    log_error "[exception-loader] No backup available for recovery"
    return 1
  fi

  if ! validate_yaml_syntax "$backup_file"; then
    log_error "[exception-loader] Backup is also corrupted"
    return 1
  fi

  log_warn "[exception-loader] Restoring registry from backup"
  cp "$backup_file" "$registry_file"

  if [ -f "$SHARED_DIR/logger.sh" ]; then
    log_info "[exception-loader] Registry restored - please re-run your command"
  fi

  return 0
}

# Ensure registry is valid, restore from backup if needed
ensure_registry_valid() {
  local registry_file="$1"
  local backup_file="${2:-${registry_file}.backup}"

  # If registry doesn't exist, that's OK (no exceptions)
  if [ ! -f "$registry_file" ]; then
    log_debug "[exception-loader] No registry file - exceptions disabled"
    return 0
  fi

  # Validate current registry
  if validate_yaml_syntax "$registry_file"; then
    # Valid - ensure backup exists
    if [ ! -f "$backup_file" ]; then
      backup_registry "$registry_file" "$backup_file"
    fi
    return 0
  fi

  # Current is invalid - try to restore from backup
  log_error "[exception-loader] Registry corrupted - attempting recovery"

  if restore_from_backup "$registry_file" "$backup_file"; then
    log_info "[exception-loader] Recovery successful - registry restored"
    return 0
  else
    log_error "[exception-loader] Recovery failed - no valid backup available"
    log_error "[exception-loader] Contact: #hooks-support for manual recovery"
    return 1
  fi
}

# Primary function: Check findings against active exceptions
# Filters out findings that match active exceptions
# Returns JSON array of findings that are NOT covered by exceptions
check_exceptions() {
  local findings_json="$1"
  local hook_name="$2"
  local tool_name="${3:-$hook_name}"

  # Initialize scope context for exception filtering
  init_scope_context

  # Ensure registry is valid (recover from corruption if needed)
  if ! ensure_registry_valid "$EXCEPTIONS_REGISTRY" "$EXCEPTIONS_BACKUP"; then
    log_warn "[exception-loader] Registry validation failed - proceeding with findings"
    echo "$findings_json"
    return 0
  fi

  # Return input if no registry file
  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    echo "$findings_json"
    return 0
  fi

  # Return empty if no findings
  if [ -z "$findings_json" ] || [ "$findings_json" = "[]" ]; then
    echo "[]"
    return 0
  fi

  # Normalize tool name to lowercase for matching
  tool_name=$(echo "$tool_name" | tr '[:upper:]' '[:lower:]')

  # Check if entire hook is disabled (with scope filtering)
  while IFS= read -r exc_id; do
    if is_exception_applicable "$exc_id" "$EXCEPTIONS_REGISTRY"; then
      if grep -A 5 "^[[:space:]]*id:[[:space:]]*$exc_id" "$EXCEPTIONS_REGISTRY" 2>/dev/null | grep -q "status:[[:space:]]*active"; then
        log_info "[exception-loader] Hook $tool_name disabled by exception $exc_id (scope applied)"
        echo "[]"
        return 0
      fi
    else
      log_debug "[exception-loader] Exception $exc_id skipped (out of scope for hook-disabled)"
    fi
  done < <(grep -B 3 "type:[[:space:]]*hook-disabled" "$EXCEPTIONS_REGISTRY" 2>/dev/null | grep "^[[:space:]]*id:" | sed 's/.*id:[[:space:]]*//;s/[[:space:]]*$//')

  # Check if entire check is waived (with scope filtering)
  while IFS= read -r exc_id; do
    if is_exception_applicable "$exc_id" "$EXCEPTIONS_REGISTRY"; then
      if grep -A 5 "^[[:space:]]*id:[[:space:]]*$exc_id" "$EXCEPTIONS_REGISTRY" 2>/dev/null | grep -q "tool:[[:space:]]*$tool_name"; then
        if grep -A 8 "^[[:space:]]*id:[[:space:]]*$exc_id" "$EXCEPTIONS_REGISTRY" 2>/dev/null | grep -q "status:[[:space:]]*active"; then
          log_info "[exception-loader] Check $tool_name waived by exception $exc_id (scope applied)"
          echo "[]"
          return 0
        fi
      fi
    else
      log_debug "[exception-loader] Exception $exc_id skipped (out of scope for check-waived)"
    fi
  done < <(grep -B 3 "type:[[:space:]]*check-waived" "$EXCEPTIONS_REGISTRY" 2>/dev/null | grep "^[[:space:]]*id:" | sed 's/.*id:[[:space:]]*//;s/[[:space:]]*$//')

  # For finding-specific exceptions, return findings unchanged
  # (Full filtering logic will be implemented in Phase 2)
  echo "$findings_json"
}

# Load exceptions from YAML registry
# Returns exceptions as array of objects (basic extraction)
load_exceptions() {
  local tool_filter="$1"

  # Ensure registry is valid first
  if ! ensure_registry_valid "$EXCEPTIONS_REGISTRY" "$EXCEPTIONS_BACKUP"; then
    log_warn "[exception-loader] Registry validation failed - no exceptions available"
    echo "[]"
    return 0
  fi

  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    echo "[]"
    return 0
  fi

  # Simple approach: Return marker that exceptions exist
  # Full JSON conversion will be in Phase 2
  echo "true"
}

# Helper: Check if a specific exception is active
is_exception_active() {
  local exc_id="$1"

  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    return 1
  fi

  # Extract exception block and check status
  if grep -A 10 "id:[[:space:]]*$exc_id" "$EXCEPTIONS_REGISTRY" 2>/dev/null | grep -q "status:[[:space:]]*active"; then
    return 0
  fi
  return 1
}

# Helper: Check if exception is expired
is_exception_expired() {
  local exc_id="$1"
  local now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    return 1
  fi

  local expires_at=$(grep -A 10 "id:[[:space:]]*$exc_id" "$EXCEPTIONS_REGISTRY" 2>/dev/null | grep "expires_at:" | sed 's/.*expires_at:[[:space:]]*//;s/[[:space:]]*$//' | head -1)

  if [ -z "$expires_at" ]; then
    return 1
  fi

  # ISO 8601 comparison (string comparison works for this format)
  if [[ "$expires_at" < "$now" ]]; then
    return 0  # Expired
  fi
  return 1  # Not expired
}

# Helper: Get exception type
get_exception_type() {
  local exc_id="$1"

  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    return 1
  fi

  grep -A 3 "id:[[:space:]]*$exc_id" "$EXCEPTIONS_REGISTRY" 2>/dev/null | grep "type:" | sed 's/.*type:[[:space:]]*//;s/[[:space:]]*$//' | head -1
}

# Helper: Get exception statistics
get_exception_stats() {
  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    echo "{\"total\": 0, \"active\": 0, \"expired\": 0}"
    return 0
  fi

  local total=$(grep -c "^[[:space:]]*id:" "$EXCEPTIONS_REGISTRY" 2>/dev/null || echo 0)
  local active=$(grep -c "status:[[:space:]]*active" "$EXCEPTIONS_REGISTRY" 2>/dev/null || echo 0)
  local by_finding=$(grep -c "type:[[:space:]]*finding-disabled" "$EXCEPTIONS_REGISTRY" 2>/dev/null || echo 0)
  local by_check=$(grep -c "type:[[:space:]]*check-waived" "$EXCEPTIONS_REGISTRY" 2>/dev/null || echo 0)
  local by_hook=$(grep -c "type:[[:space:]]*hook-disabled" "$EXCEPTIONS_REGISTRY" 2>/dev/null || echo 0)
  local by_gate=$(grep -c "type:[[:space:]]*gate-waived" "$EXCEPTIONS_REGISTRY" 2>/dev/null || echo 0)

  cat <<EOF
{
  "total": $total,
  "active": $active,
  "by_type": {
    "finding-disabled": $by_finding,
    "check-waived": $by_check,
    "hook-disabled": $by_hook,
    "gate-waived": $by_gate
  }
}
EOF
}

# Placeholder for advanced filtering (Phase 2)
filter_findings_by_exceptions() {
  local findings_json="$1"
  local hook_name="$2"
  local tool_name="${3:-$hook_name}"

  # Phase 1: Just call check_exceptions
  check_exceptions "$findings_json" "$hook_name" "$tool_name"
}

# Helper: List all active exceptions for a tool
list_exceptions_for_tool() {
  local tool_name="$1"

  if [ ! -f "$EXCEPTIONS_REGISTRY" ]; then
    return 0
  fi

  # Extract exception IDs for this tool
  awk -v tool="$tool_name" '
    /^[[:space:]]*id:/ {
      match($0, /id:[[:space:]]*([^ ]+)/, arr)
      current_id = arr[1]
      found_tool = 0
    }
    /^[[:space:]]*tool:/ && match($0, tool) {
      found_tool = 1
    }
    /^[[:space:]]*status:[[:space:]]*active/ && found_tool && current_id {
      print current_id
      current_id = ""
      found_tool = 0
    }
  ' "$EXCEPTIONS_REGISTRY" 2>/dev/null
}

# Safely write to exception registry with automatic backup
# Creates backup before modifying, validates new content
safe_write_registry() {
  local new_content="$1"
  local temp_file=$(mktemp)

  # Write new content to temp file
  echo "$new_content" > "$temp_file"

  # Validate new content before committing
  if ! validate_yaml_syntax "$temp_file"; then
    log_error "[exception-loader] New registry content is invalid YAML - write aborted"
    rm -f "$temp_file"
    return 1
  fi

  # Create backup of current valid version
  if [ -f "$EXCEPTIONS_REGISTRY" ]; then
    if ! backup_registry "$EXCEPTIONS_REGISTRY" "$EXCEPTIONS_BACKUP"; then
      log_warn "[exception-loader] Could not backup current registry - proceeding"
    fi
  fi

  # Move new content to registry location
  mv "$temp_file" "$EXCEPTIONS_REGISTRY"
  chmod 644 "$EXCEPTIONS_REGISTRY"

  log_info "[exception-loader] Registry updated and backed up"
  return 0
}

# Determine current repository name from git remote
determine_current_repo() {
  if [ -n "$CURRENT_REPO" ]; then
    return 0  # Already set
  fi

  # Try to get from git remote
  CURRENT_REPO=$(git config --get remote.origin.url 2>/dev/null | sed 's/.*\///;s/\.git$//' || echo "")

  if [ -z "$CURRENT_REPO" ]; then
    # Fallback to directory name
    CURRENT_REPO=$(basename "$(pwd)")
  fi

  log_debug "[exception-loader] Determined repo: $CURRENT_REPO"
}

# Determine current team from .teya/team.yaml or environment
determine_current_team() {
  if [ -n "$CURRENT_TEAM" ]; then
    return 0  # Already set
  fi

  # Try to read from .teya/team.yaml
  if [ -f ".teya/team.yaml" ]; then
    CURRENT_TEAM=$(grep "^team:" ".teya/team.yaml" 2>/dev/null | cut -d: -f2 | xargs || echo "")
  fi

  # Fallback to environment variable
  if [ -z "$CURRENT_TEAM" ]; then
    CURRENT_TEAM="${TEAM:-}"
  fi

  log_debug "[exception-loader] Determined team: $CURRENT_TEAM"
}

# Check if an exception applies to current context based on scope
# Returns 0 (applies) or 1 (does not apply)
is_exception_applicable() {
  local exc_id="$1"
  local registry_file="${2:-$EXCEPTIONS_REGISTRY}"

  if [ ! -f "$registry_file" ]; then
    return 0  # No registry, accept all
  fi

  # Extract scope for this exception
  local scope=$(grep -A 15 "^[[:space:]]*id:[[:space:]]*$exc_id" "$registry_file" 2>/dev/null | \
                grep "^[[:space:]]*scope:" | head -1 | sed 's/.*scope:[[:space:]]*//;s/[[:space:]]*$//')

  # If no scope specified, default to global (backward compatibility)
  if [ -z "$scope" ]; then
    scope="global"
  fi

  # Extract applies_to section
  local applies_to=$(grep -A 25 "^[[:space:]]*id:[[:space:]]*$exc_id" "$registry_file" 2>/dev/null | \
                    sed -n '/^[[:space:]]*applies_to:/,/^[[:space:]]*[a-z]/p' | \
                    sed '$ d')

  # Match based on scope
  case "$scope" in
    "global")
      # Global scope always applies
      log_debug "[exception-loader] Exception $exc_id is global (applies)"
      return 0
      ;;
    "org")
      # Check if current org is in applies_to
      if echo "$applies_to" | grep -q "org:[[:space:]]*\"*$CURRENT_ORG\"*"; then
        log_debug "[exception-loader] Exception $exc_id matches org scope ($CURRENT_ORG)"
        return 0
      else
        log_debug "[exception-loader] Exception $exc_id doesn't match org scope (org: $CURRENT_ORG not in applies_to)"
        return 1
      fi
      ;;
    "team")
      # Check if current team is in applies_to
      if [ -z "$CURRENT_TEAM" ]; then
        log_debug "[exception-loader] Exception $exc_id requires team scope but CURRENT_TEAM not set"
        return 1
      fi
      if echo "$applies_to" | grep -q "team:[[:space:]]*\"*$CURRENT_TEAM\"*"; then
        log_debug "[exception-loader] Exception $exc_id matches team scope ($CURRENT_TEAM)"
        return 0
      else
        log_debug "[exception-loader] Exception $exc_id doesn't match team scope (team: $CURRENT_TEAM not in applies_to)"
        return 1
      fi
      ;;
    "repo")
      # Check if current repo is in applies_to
      if [ -z "$CURRENT_REPO" ]; then
        log_debug "[exception-loader] Exception $exc_id requires repo scope but CURRENT_REPO not set"
        return 1
      fi
      if echo "$applies_to" | grep -q "repository:[[:space:]]*\"*$CURRENT_REPO\"*"; then
        log_debug "[exception-loader] Exception $exc_id matches repo scope ($CURRENT_REPO)"
        return 0
      else
        log_debug "[exception-loader] Exception $exc_id doesn't match repo scope (repo: $CURRENT_REPO not in applies_to)"
        return 1
      fi
      ;;
    *)
      log_warn "[exception-loader] Unknown scope: $scope for exception $exc_id"
      return 1
      ;;
  esac
}

# Initialize scope context (must be called before checking exceptions)
init_scope_context() {
  determine_current_repo
  determine_current_team
  log_debug "[exception-loader] Scope context: repo=$CURRENT_REPO team=$CURRENT_TEAM org=$CURRENT_ORG"
}
