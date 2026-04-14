#!/bin/bash
# shared/script-updater.sh
# Verify and update Quality Gates scripts from central repository

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"
source "$SHARED_DIR/retry-handler.sh"

HOOKS_REPO_URL="${HOOKS_REPO_URL:-https://github.com/warwickbrownteya/sdlc-quality-gates.git}"
HOOKS_CACHE_DIR="${HOOKS_CACHE_DIR:-.teya/quality-gates-cache}"
HOOKS_UPDATE_TTL_DAYS="${HOOKS_UPDATE_TTL_DAYS:-30}"  # Check for updates monthly
SCRIPTS_TEMP_DIR=$(mktemp -d)

trap 'rm -rf "$SCRIPTS_TEMP_DIR"' EXIT

# Download latest hooks from repository
download_hooks_repo() {
  local repo_url="$1"
  local branch="${2:-main}"

  log_debug "[script-updater] Downloading hooks from $repo_url (branch: $branch)"

  if retry_with_backoff 3 2 git clone --depth 1 --branch "$branch" "$repo_url" "$SCRIPTS_TEMP_DIR"; then
    log_debug "[script-updater] Hooks repository downloaded successfully"
    return 0
  else
    log_warn "[script-updater] Failed to download hooks repository"
    return 1
  fi
}

# Extract and verify scripts
extract_hooks_scripts() {
  local source_dir="$1"
  local cache_dir="$2"

  mkdir -p "$cache_dir"

  # Copy hook scripts
  if [ -d "$source_dir/hooks" ]; then
    cp -r "$source_dir/hooks" "$cache_dir/"
    log_debug "[script-updater] Cached hook scripts"
  else
    log_warn "[script-updater] No hooks directory in repository"
    return 1
  fi

  # Copy shared libraries
  if [ -d "$source_dir/shared" ]; then
    cp -r "$source_dir/shared" "$cache_dir/"
    log_debug "[script-updater] Cached shared libraries"
  else
    log_warn "[script-updater] No shared directory in repository"
    return 1
  fi

  # Copy config
  if [ -d "$source_dir/config" ]; then
    cp -r "$source_dir/config" "$cache_dir/"
    log_debug "[script-updater] Cached configuration"
  fi

  # Create version file
  if [ -f "$source_dir/.gitignore" ]; then
    git -C "$source_dir" rev-parse --short HEAD > "$cache_dir/VERSION"
    log_debug "[script-updater] Cached version info"
  fi

  return 0
}

# Check if scripts cache needs refresh
cache_needs_update() {
  local cache_dir="$1"
  local ttl_days="$2"

  if [ ! -d "$cache_dir" ]; then
    return 0  # Cache doesn't exist, needs update
  fi

  if [ ! -f "$cache_dir/VERSION" ]; then
    return 0  # VERSION missing, needs update
  fi

  # Check if cache is older than TTL
  local last_update
  last_update=$(stat -f %m "$cache_dir/VERSION" 2>/dev/null || stat -c %Y "$cache_dir/VERSION" 2>/dev/null)
  local now
  now=$(date +%s)
  local age_seconds=$((now - last_update))
  local ttl_seconds=$((ttl_days * 86400))

  [ $age_seconds -gt $ttl_seconds ]
}

# Verify scripts have correct permissions
verify_scripts_permissions() {
  local cache_dir="$1"

  local hook_count=0
  for hook in "$cache_dir"/hooks/*.sh; do
    if [ ! -x "$hook" ]; then
      chmod +x "$hook"
      log_debug "[script-updater] Fixed permissions: $hook"
    fi
    ((hook_count++))
  done

  if [ $hook_count -eq 0 ]; then
    log_error "[script-updater] No executable hooks found"
    return 1
  fi

  log_debug "[script-updater] Verified $hook_count hook scripts"
  return 0
}

# Main function: check and update scripts
ensure_scripts_current() {
  local repo_url="${1:-$HOOKS_REPO_URL}"
  local cache_dir="${2:-$HOOKS_CACHE_DIR}"
  local branch="${3:-main}"
  local ttl_days="${4:-$HOOKS_UPDATE_TTL_DAYS}"

  log_debug "[script-updater] Checking Quality Gates scripts currency"

  # Check if refresh needed
  if ! cache_needs_update "$cache_dir" "$ttl_days"; then
    log_debug "[script-updater] Scripts cache is current, no refresh needed"
    return 0
  fi

  log_info "[script-updater] Updating Quality Gates scripts cache"

  # Download latest repository
  if ! download_hooks_repo "$repo_url" "$branch"; then
    log_warn "[script-updater] Using existing scripts (update failed)"
    [ -d "$cache_dir" ] && return 0 || return 1
  fi

  # Extract scripts
  if ! extract_hooks_scripts "$SCRIPTS_TEMP_DIR" "$cache_dir"; then
    log_error "[script-updater] Failed to extract scripts"
    return 1
  fi

  # Verify permissions
  if ! verify_scripts_permissions "$cache_dir"; then
    log_error "[script-updater] Failed to verify script permissions"
    return 1
  fi

  log_info "[script-updater] Scripts cache updated successfully"
  return 0
}

# Get a script from cache
get_script_path() {
  local script_name="$1"
  local cache_dir="${2:-.teya/quality-gates-cache}"

  if [ -f "$cache_dir/hooks/$script_name" ]; then
    echo "$cache_dir/hooks/$script_name"
    return 0
  fi

  if [ -f "$cache_dir/shared/$script_name" ]; then
    echo "$cache_dir/shared/$script_name"
    return 0
  fi

  log_error "[script-updater] Script not found: $script_name"
  return 1
}

# Validate all required scripts are present
validate_scripts_present() {
  local cache_dir="${1:-.teya/quality-gates-cache}"

  local required_hooks=(
    "secrets.sh"
    "sast.sh"
    "sca.sh"
    "iac.sh"
    "gate-evaluator.sh"
  )

  local required_libs=(
    "logger.sh"
    "exception-loader.sh"
    "findings-parser.sh"
    "evidence-transformer.sh"
    "retry-handler.sh"
    "rules-downloader.sh"
    "hook-updater.sh"
    "prerequisites-checker.sh"
    "integrity-checker.sh"
    "results-writer.sh"
  )

  local missing=0

  for hook in "${required_hooks[@]}"; do
    if [ ! -f "$cache_dir/hooks/$hook" ]; then
      log_error "[script-updater] Missing hook: $hook"
      ((missing++))
    fi
  done

  for lib in "${required_libs[@]}"; do
    if [ ! -f "$cache_dir/shared/$lib" ]; then
      log_error "[script-updater] Missing library: $lib"
      ((missing++))
    fi
  done

  if [ $missing -gt 0 ]; then
    log_error "[script-updater] Found $missing missing scripts"
    return 1
  fi

  log_debug "[script-updater] All required scripts present"
  return 0
}

# Compare versions
get_script_version() {
  local cache_dir="${1:-.teya/quality-gates-cache}"

  if [ -f "$cache_dir/VERSION" ]; then
    cat "$cache_dir/VERSION"
  else
    echo "unknown"
  fi
}

# Status report
report_scripts_status() {
  local cache_dir="${1:-.teya/quality-gates-cache}"

  if [ ! -f "$cache_dir/VERSION" ]; then
    echo "[script-updater] Scripts status: NOT INSTALLED"
    return 1
  fi

  local version
  version=$(cat "$cache_dir/VERSION")
  local hook_count
  hook_count=$(find "$cache_dir/hooks" -name "*.sh" 2>/dev/null | wc -l)
  local lib_count
  lib_count=$(find "$cache_dir/shared" -name "*.sh" 2>/dev/null | wc -l)
  local cache_age
  cache_age=$(stat -f "%m" "$cache_dir/VERSION" 2>/dev/null || stat -c "%Y" "$cache_dir/VERSION" 2>/dev/null)
  local now
  now=$(date +%s)

  echo "[script-updater] Scripts status: VERSION=$version, HOOKS=$hook_count, LIBS=$lib_count, AGE_DAYS=$(( (now - cache_age) / 86400 ))"
  return 0
}
