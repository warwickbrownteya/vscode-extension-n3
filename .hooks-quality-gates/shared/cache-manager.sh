#!/bin/bash
# shared/cache-manager.sh
# Manage cache cleanup with per-tool TTL to prevent directory bloat

# Determine shared library directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Load logger if available
if [ -f "$SCRIPT_DIR/logger.sh" ]; then
  source "$SCRIPT_DIR/logger.sh"
else
  log_info() { echo "[INFO] $*"; }
  log_warn() { echo "[WARN] $*"; }
  log_error() { echo "[ERROR] $*"; }
  log_debug() { echo "[DEBUG] $*"; }
fi

# Default cache configuration
CACHE_DIR="${CACHE_DIR:-.teya}"
CACHE_CONFIG="${CACHE_DIR}/cache-config.yaml"
CACHE_LOG="${CACHE_DIR}/cache-cleanup.log"

# Default TTL values (days)
CACHE_TTL_SEMGREP="${CACHE_TTL_SEMGREP:-30}"
CACHE_TTL_DEPENDENCIES="${CACHE_TTL_DEPENDENCIES:-7}"
CACHE_TTL_GITHUB="${CACHE_TTL_GITHUB:-14}"
CACHE_TTL_IAC="${CACHE_TTL_IAC:-7}"
CACHE_TTL_LINTER="${CACHE_TTL_LINTER:-7}"

# Initialize cache directory
init_cache_manager() {
  mkdir -p "$CACHE_DIR"
  return 0
}

# Load configuration from YAML if present
load_cache_config() {
  if [ -f "$CACHE_CONFIG" ]; then
    # Extract TTL values from YAML
    CACHE_TTL_SEMGREP=$(grep -A5 "semgrep:" "$CACHE_CONFIG" 2>/dev/null | grep "ttl_days:" | cut -d':' -f2 | tr -d ' ' || echo "$CACHE_TTL_SEMGREP")
    CACHE_TTL_DEPENDENCIES=$(grep -A5 "dependencies:" "$CACHE_CONFIG" 2>/dev/null | grep "ttl_days:" | cut -d':' -f2 | tr -d ' ' || echo "$CACHE_TTL_DEPENDENCIES")
    CACHE_TTL_GITHUB=$(grep -A5 "github:" "$CACHE_CONFIG" 2>/dev/null | grep "ttl_days:" | cut -d':' -f2 | tr -d ' ' || echo "$CACHE_TTL_GITHUB")
    CACHE_TTL_IAC=$(grep -A5 "iac:" "$CACHE_CONFIG" 2>/dev/null | grep "ttl_days:" | cut -d':' -f2 | tr -d ' ' || echo "$CACHE_TTL_IAC")
    CACHE_TTL_LINTER=$(grep -A5 "linter:" "$CACHE_CONFIG" 2>/dev/null | grep "ttl_days:" | cut -d':' -f2 | tr -d ' ' || echo "$CACHE_TTL_LINTER")
  fi
}

# Clean cache directory by TTL
cleanup_cache() {
  local cache_dir="$1"
  local ttl_days="$2"
  local cache_name="$3"

  if [ ! -d "$cache_dir" ]; then
    log_debug "[cache] Cache directory not found: $cache_dir"
    return 0
  fi

  log_info "[cache] Cleaning $cache_name (TTL: ${ttl_days} days)"

  local files_deleted=0
  local bytes_freed=0

  # Find and delete files older than TTL
  while IFS= read -r file; do
    if [ -f "$file" ]; then
      local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
      rm -f "$file"
      ((files_deleted++))
      ((bytes_freed += size))
    fi
  done < <(find "$cache_dir" -type f -mtime +$ttl_days 2>/dev/null)

  # Remove empty directories
  find "$cache_dir" -type d -empty -delete 2>/dev/null || true

  # Log results
  if [ $files_deleted -gt 0 ]; then
    local bytes_freed_mb=$((bytes_freed / 1024 / 1024))
    log_info "[cache] Deleted $files_deleted files, freed ${bytes_freed_mb}MB from $cache_name"
    record_cleanup_stats "$cache_name" "$files_deleted" "$bytes_freed"
  else
    log_debug "[cache] No old files to clean in $cache_name"
  fi

  return 0
}

# Clean all caches based on configuration
cleanup_all_caches() {
  init_cache_manager
  load_cache_config

  log_info "[cache] Starting cache cleanup cycle"

  local total_deleted=0
  local total_freed=0

  # Cleanup Semgrep cache
  if [ -d "$CACHE_DIR/semgrep-cache" ]; then
    cleanup_cache "$CACHE_DIR/semgrep-cache" "$CACHE_TTL_SEMGREP" "semgrep" || true
  fi

  # Cleanup dependencies cache
  if [ -d "$CACHE_DIR/dependencies-cache" ]; then
    cleanup_cache "$CACHE_DIR/dependencies-cache" "$CACHE_TTL_DEPENDENCIES" "dependencies" || true
  fi

  # Cleanup GitHub cache
  if [ -d "$CACHE_DIR/github-cache" ]; then
    cleanup_cache "$CACHE_DIR/github-cache" "$CACHE_TTL_GITHUB" "github" || true
  fi

  # Cleanup IaC cache
  if [ -d "$CACHE_DIR/iac-cache" ]; then
    cleanup_cache "$CACHE_DIR/iac-cache" "$CACHE_TTL_IAC" "iac" || true
  fi

  # Cleanup linter cache
  if [ -d "$CACHE_DIR/linter-cache" ]; then
    cleanup_cache "$CACHE_DIR/linter-cache" "$CACHE_TTL_LINTER" "linter" || true
  fi

  log_info "[cache] Cache cleanup cycle completed"
  return 0
}

# Record cleanup statistics
record_cleanup_stats() {
  local cache_name="$1"
  local files_deleted="$2"
  local bytes_freed="$3"

  mkdir -p "$(dirname "$CACHE_LOG")"

  # Append to cleanup log (JSON format for easy parsing)
  cat >> "$CACHE_LOG" <<EOF
$(date -u +%Y-%m-%dT%H:%M:%SZ) | $cache_name | files=$files_deleted | bytes=$bytes_freed
EOF
}

# Get cache sizes for metrics
get_cache_sizes() {
  local sizes_json="{}"

  if [ -d "$CACHE_DIR/semgrep-cache" ]; then
    local size=$(du -s "$CACHE_DIR/semgrep-cache" 2>/dev/null | cut -f1)
    sizes_json=$(echo "$sizes_json" | sed "s/}/,\"semgrep\": $size}/" 2>/dev/null || echo "$sizes_json")
  fi

  if [ -d "$CACHE_DIR/dependencies-cache" ]; then
    local size=$(du -s "$CACHE_DIR/dependencies-cache" 2>/dev/null | cut -f1)
    sizes_json=$(echo "$sizes_json" | sed "s/}/,\"dependencies\": $size}/" 2>/dev/null || echo "$sizes_json")
  fi

  if [ -d "$CACHE_DIR/github-cache" ]; then
    local size=$(du -s "$CACHE_DIR/github-cache" 2>/dev/null | cut -f1)
    sizes_json=$(echo "$sizes_json" | sed "s/}/,\"github\": $size}/" 2>/dev/null || echo "$sizes_json")
  fi

  if [ -d "$CACHE_DIR/iac-cache" ]; then
    local size=$(du -s "$CACHE_DIR/iac-cache" 2>/dev/null | cut -f1)
    sizes_json=$(echo "$sizes_json" | sed "s/}/,\"iac\": $size}/" 2>/dev/null || echo "$sizes_json")
  fi

  if [ -d "$CACHE_DIR/linter-cache" ]; then
    local size=$(du -s "$CACHE_DIR/linter-cache" 2>/dev/null | cut -f1)
    sizes_json=$(echo "$sizes_json" | sed "s/}/,\"linter\": $size}/" 2>/dev/null || echo "$sizes_json")
  fi

  echo "$sizes_json"
}

# Get total cache directory size
get_total_cache_size() {
  local total_size=0

  if [ -d "$CACHE_DIR" ]; then
    total_size=$(du -s "$CACHE_DIR" 2>/dev/null | cut -f1 || echo 0)
  fi

  echo $total_size
}

# Generate cache metrics report
generate_cache_metrics() {
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local total_size=$(get_total_cache_size)
  local total_size_mb=$((total_size / 1024))

  cat <<EOF
{
  "timestamp": "$timestamp",
  "cache": {
    "total_size_kb": $total_size,
    "total_size_mb": $total_size_mb,
    "by_tool": $(get_cache_sizes)
  }
}
EOF
}

# Validate cache configuration
validate_cache_config() {
  if [ ! -f "$CACHE_CONFIG" ]; then
    log_warn "[cache] No cache configuration found, using defaults"
    return 0
  fi

  # Basic validation - check if file is valid YAML
  if ! grep -q "cache:" "$CACHE_CONFIG" 2>/dev/null; then
    log_warn "[cache] Cache config exists but may not be valid YAML"
    return 1
  fi

  log_info "[cache] Cache configuration validated"
  return 0
}

# Export variables for sourcing
export CACHE_DIR
export CACHE_LOG
export CACHE_TTL_SEMGREP
export CACHE_TTL_DEPENDENCIES
export CACHE_TTL_GITHUB
export CACHE_TTL_IAC
export CACHE_TTL_LINTER
