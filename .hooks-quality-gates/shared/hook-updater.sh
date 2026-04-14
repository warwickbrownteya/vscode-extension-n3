#!/bin/bash
# shared/hook-updater.sh
# Verify and update the pre-commit hook itself from central repository

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"
source "$SHARED_DIR/retry-handler.sh"

HOOKS_REPO_URL="${HOOKS_REPO_URL:-https://github.com/warwickbrownteya/sdlc-quality-gates.git}"
HOOKS_UPDATE_TTL_DAYS="${HOOKS_UPDATE_TTL_DAYS:-30}"
HOOK_UPDATE_CACHE_FILE="${HOOK_UPDATE_CACHE_FILE:-.teya/hook-update-check}"

# Download latest install.sh from repository to extract hook content
download_latest_hook() {
  local repo_url="$1"
  local branch="${2:-main}"
  local temp_dir="$3"

  log_debug "[hook-updater] Downloading latest install.sh from $repo_url (branch: $branch)"

  if retry_with_backoff 3 2 git clone --depth 1 --branch "$branch" "$repo_url" "$temp_dir"; then
    if [ -f "$temp_dir/install.sh" ]; then
      log_debug "[hook-updater] Latest install.sh downloaded successfully"
      return 0
    else
      log_warn "[hook-updater] install.sh not found in repository"
      return 1
    fi
  else
    log_warn "[hook-updater] Failed to download repository"
    return 1
  fi
}

# Extract hook content from install.sh
extract_hook_from_install() {
  local install_file="$1"
  local output_file="$2"

  # Extract content between 'cat > "$HOOK_TEMP" << 'HOOK_EOF'' and 'HOOK_EOF'
  # Use awk to extract the block, then remove first and last lines with sed
  # (compatible with both GNU and BSD sed/awk)
  awk '/^cat > "\$HOOK_TEMP" << .HOOK_EOF.$/,/^HOOK_EOF$/ { print }' "$install_file" | \
    sed '1d;$d' > "$output_file"

  if [ -s "$output_file" ]; then
    log_debug "[hook-updater] Hook content extracted successfully"
    return 0
  else
    log_error "[hook-updater] Failed to extract hook content"
    return 1
  fi
}

# Compare current hook with latest version
hook_needs_update() {
  local current_hook="$1"
  local latest_hook="$2"

  if [ ! -f "$current_hook" ]; then
    return 0  # Hook doesn't exist, needs creation
  fi

  # Compare files (ignore comments to handle minor changes)
  if ! diff -q "$current_hook" "$latest_hook" > /dev/null 2>&1; then
    return 0  # Files differ, needs update
  else
    return 1  # Files are identical, no update needed
  fi
}

# Check if hook update is needed (based on TTL)
hook_update_check_needed() {
  local cache_file="$1"
  local ttl_days="$2"

  if [ ! -f "$cache_file" ]; then
    return 0  # Cache doesn't exist, check needed
  fi

  # Check if cache is older than TTL
  local last_check
  last_check=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)
  local now
  now=$(date +%s)
  local age_seconds=$((now - last_check))
  local ttl_seconds=$((ttl_days * 86400))

  [ $age_seconds -gt $ttl_seconds ]
}

# Update the pre-commit hook safely
update_hook() {
  local latest_hook="$1"
  local hook_path="$2"

  if [ ! -f "$latest_hook" ]; then
    log_error "[hook-updater] Latest hook file not found"
    return 1
  fi

  # Create temporary file for atomic update
  local hook_temp
  hook_temp=$(mktemp)
  trap 'rm -f "$hook_temp"' RETURN

  # Copy latest hook to temp file
  cp "$latest_hook" "$hook_temp"

  # Make executable
  chmod +x "$hook_temp"

  # Atomic move to replace current hook
  mv "$hook_temp" "$hook_path"

  if [ ! -x "$hook_path" ]; then
    log_error "[hook-updater] Hook not executable after update"
    return 1
  fi

  log_info "[hook-updater] Pre-commit hook updated successfully"
  return 0
}

# Main function: check and update hook if needed
ensure_hook_current() {
  local repo_url="${1:-$HOOKS_REPO_URL}"
  local hook_path="${2:-.git/hooks/pre-commit}"
  local branch="${3:-main}"
  local ttl_days="${4:-$HOOKS_UPDATE_TTL_DAYS}"

  # Get repo root
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$repo_root" ]; then
    log_debug "[hook-updater] Not in a git repository, skipping hook update"
    return 0
  fi

  local cache_file="$repo_root/$HOOK_UPDATE_CACHE_FILE"
  local absolute_hook_path="$repo_root/$hook_path"

  log_debug "[hook-updater] Checking pre-commit hook currency"

  # Check if update check is needed (use TTL to avoid frequent GitHub queries)
  if ! hook_update_check_needed "$cache_file" "$ttl_days"; then
    log_debug "[hook-updater] Hook update check done recently, skipping"
    return 0
  fi

  log_debug "[hook-updater] Checking for pre-commit hook updates"

  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  # Download latest repository
  if ! download_latest_hook "$repo_url" "$branch" "$temp_dir"; then
    log_debug "[hook-updater] Update check failed, using current hook"
    mkdir -p "$(dirname "$cache_file")"
    touch "$cache_file"  # Update cache timestamp even on failure
    return 0  # Non-blocking - continue with current hook
  fi

  local latest_hook="$temp_dir/install.sh.hook"
  if ! extract_hook_from_install "$temp_dir/install.sh" "$latest_hook"; then
    log_debug "[hook-updater] Could not extract hook content, using current"
    mkdir -p "$(dirname "$cache_file")"
    touch "$cache_file"
    return 0
  fi

  # Check if update is needed
  if hook_needs_update "$absolute_hook_path" "$latest_hook"; then
    log_info "[hook-updater] Updating pre-commit hook to latest version"
    if update_hook "$latest_hook" "$absolute_hook_path"; then
      mkdir -p "$(dirname "$cache_file")"
      touch "$cache_file"
      return 0
    else
      log_warn "[hook-updater] Hook update failed, using current version"
      mkdir -p "$(dirname "$cache_file")"
      touch "$cache_file"
      return 0  # Non-blocking
    fi
  else
    log_debug "[hook-updater] Pre-commit hook is already current"
    mkdir -p "$(dirname "$cache_file")"
    touch "$cache_file"
    return 0
  fi
}
