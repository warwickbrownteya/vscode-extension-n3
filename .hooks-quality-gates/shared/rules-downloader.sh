#!/bin/bash
# shared/rules-downloader.sh
# Download and cache Semgrep rules from central repository

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"
source "$SHARED_DIR/retry-handler.sh"

RULES_REPO_URL="${RULES_REPO_URL:-https://github.com/warwickbrownteya/sdlc-semgrep-rules.git}"
RULES_CACHE_DIR="${RULES_CACHE_DIR:-.teya/semgrep-cache}"
RULES_CACHE_TTL_DAYS="${RULES_CACHE_TTL_DAYS:-7}"
RULES_TEMP_DIR=$(mktemp -d)

trap 'rm -rf "$RULES_TEMP_DIR"' EXIT

# Download rules from repository
download_rules() {
  local repo_url="$1"
  local branch="${2:-main}"

  log_debug "[rules-downloader] Downloading rules from $repo_url (branch: $branch)"

  # Try to clone the repo (with retry)
  if retry_with_backoff 3 2 git clone --depth 1 --branch "$branch" "$repo_url" "$RULES_TEMP_DIR"; then
    log_debug "[rules-downloader] Rules downloaded successfully"
    return 0
  else
    log_warn "[rules-downloader] Failed to download rules after retries"
    return 1
  fi
}

# Extract rules to cache
extract_rules() {
  local source_dir="$1"
  local cache_dir="$2"

  mkdir -p "$cache_dir"

  # Copy RULES.yaml (index)
  if [ -f "$source_dir/RULES.yaml" ]; then
    cp "$source_dir/RULES.yaml" "$cache_dir/RULES.yaml"
    log_debug "[rules-downloader] Cached RULES.yaml"
  fi

  # Copy VERSION
  if [ -f "$source_dir/VERSION" ]; then
    cp "$source_dir/VERSION" "$cache_dir/VERSION"
    log_debug "[rules-downloader] Cached VERSION"
  fi

  # Copy all rule files
  if [ -d "$source_dir/rules" ]; then
    cp -r "$source_dir/rules" "$cache_dir/"
    log_debug "[rules-downloader] Cached rule files"
  fi

  return 0
}

# Check if cache needs refresh
cache_needs_refresh() {
  local cache_dir="$1"
  local ttl_days="$2"

  if [ ! -d "$cache_dir" ]; then
    return 0  # Cache doesn't exist, needs refresh
  fi

  if [ ! -f "$cache_dir/VERSION" ]; then
    return 0  # VERSION missing, needs refresh
  fi

  # Check if cache is older than TTL
  local last_update=$(stat -f %m "$cache_dir/VERSION" 2>/dev/null || stat -c %Y "$cache_dir/VERSION" 2>/dev/null)
  local now=$(date +%s)
  local age_seconds=$((now - last_update))
  local ttl_seconds=$((ttl_days * 86400))

  [ $age_seconds -gt $ttl_seconds ]
}

# Main function: download and cache rules
download_and_cache_rules() {
  local repo_url="${1:-$RULES_REPO_URL}"
  local cache_dir="${2:-$RULES_CACHE_DIR}"
  local branch="${3:-main}"
  local ttl_days="${4:-$RULES_CACHE_TTL_DAYS}"

  log_info "[rules-downloader] Checking Semgrep rules cache"

  # Check if refresh needed
  if ! cache_needs_refresh "$cache_dir" "$ttl_days"; then
    log_debug "[rules-downloader] Cache is fresh, using cached rules"
    return 0
  fi

  log_info "[rules-downloader] Refreshing Semgrep rules cache"

  # Download rules
  if ! download_rules "$repo_url" "$branch"; then
    log_warn "[rules-downloader] Using existing cache (download failed)"
    [ -d "$cache_dir" ] && return 0 || return 1
  fi

  # Extract to cache
  if ! extract_rules "$RULES_TEMP_DIR" "$cache_dir"; then
    log_error "[rules-downloader] Failed to extract rules to cache"
    return 1
  fi

  log_info "[rules-downloader] Rules cache updated successfully"
  return 0
}

# Get local rules directory
get_rules_directory() {
  local cache_dir="${1:-.teya/semgrep-cache}"
  echo "$cache_dir/rules"
}

# Validate rules are present
validate_rules_present() {
  local cache_dir="${1:-.teya/semgrep-cache}"

  if [ ! -d "$cache_dir/rules" ]; then
    log_error "[rules-downloader] No rules found in cache"
    return 1
  fi

  local rule_count=$(find "$cache_dir/rules" -name "*.yaml" | wc -l)
  if [ "$rule_count" -eq 0 ]; then
    log_error "[rules-downloader] No rule files found in cache"
    return 1
  fi

  log_debug "[rules-downloader] Found $rule_count rules in cache"
  return 0
}

# Generate Semgrep config for cached rules
generate_semgrep_config() {
  local cache_dir="${1:-.teya/semgrep-cache}"
  local config_file="${2:-.teya/semgrep-config.yaml}"

  mkdir -p "$(dirname "$config_file")"

  cat > "$config_file" << 'EOF'
extends:
  - p: owasp-top-ten

paths:
  include:
    - ""
  exclude:
    - tests
    - docs
    - vendor

python:
  version: "3.9"
EOF

  log_debug "[rules-downloader] Generated Semgrep config"
  return 0
}

# Status report
report_cache_status() {
  local cache_dir="${1:-.teya/semgrep-cache}"

  if [ ! -f "$cache_dir/VERSION" ]; then
    echo "[rules-downloader] Cache status: NO CACHE"
    return 1
  fi

  local version=$(cat "$cache_dir/VERSION")
  local rule_count=$(find "$cache_dir/rules" -name "*.yaml" 2>/dev/null | wc -l)
  local cache_age=$(stat -f "%m" "$cache_dir/VERSION" 2>/dev/null || stat -c "%Y" "$cache_dir/VERSION" 2>/dev/null)

  echo "[rules-downloader] Cache status: VERSION=$version, RULES=$rule_count, AGE_HOURS=$(( ($(date +%s) - cache_age) / 3600 ))"
  return 0
}
