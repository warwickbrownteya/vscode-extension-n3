#!/bin/bash
# shared/github-client.sh
# GitHub API client with rate limiting and caching support

# Determine shared library directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load logger if available
if [ -f "$SCRIPT_DIR/logger.sh" ]; then
  source "$SCRIPT_DIR/logger.sh"
else
  log_info() { echo "[INFO] $*"; }
  log_warn() { echo "[WARN] $*"; }
  log_error() { echo "[ERROR] $*"; }
  log_debug() { echo "[DEBUG] $*"; }
fi

# GitHub API Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_API_BASE="https://api.github.com"
GITHUB_API_VERSION="2022-11-28"
GITHUB_CACHE_DIR="${GITHUB_CACHE_DIR:-.teya/github-cache}"
GITHUB_CACHE_TTL="${GITHUB_CACHE_TTL:-14}"  # days

# Rate limit tracking
GITHUB_RATE_LIMIT_REMAINING=0
GITHUB_RATE_LIMIT_RESET=0
GITHUB_RATE_LIMIT_FILE=".teya/.github-rate-limit"

# Initialize GitHub client
init_github_client() {
  mkdir -p "$GITHUB_CACHE_DIR"
  return 0
}

# Calculate cache file path from endpoint
get_cache_file() {
  local endpoint="$1"
  local cache_hash=$(echo -n "$endpoint" | md5sum 2>/dev/null | cut -d' ' -f1)
  echo "$GITHUB_CACHE_DIR/$cache_hash.json"
}

# Check if cache file is still valid
is_cache_valid() {
  local cache_file="$1"
  local ttl_seconds=$((GITHUB_CACHE_TTL * 86400))

  if [ ! -f "$cache_file" ]; then
    return 1
  fi

  # Check file age
  local file_age=$(( $(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || stat -c%Y "$cache_file" 2>/dev/null) ))

  if [ $file_age -lt $ttl_seconds ]; then
    return 0
  else
    return 1
  fi
}

# Load rate limit state from file
load_rate_limit_state() {
  if [ -f "$GITHUB_RATE_LIMIT_FILE" ]; then
    GITHUB_RATE_LIMIT_REMAINING=$(grep "remaining=" "$GITHUB_RATE_LIMIT_FILE" 2>/dev/null | cut -d'=' -f2)
    GITHUB_RATE_LIMIT_RESET=$(grep "reset=" "$GITHUB_RATE_LIMIT_FILE" 2>/dev/null | cut -d'=' -f2)
  fi
}

# Save rate limit state to file
save_rate_limit_state() {
  mkdir -p "$(dirname "$GITHUB_RATE_LIMIT_FILE")"
  cat > "$GITHUB_RATE_LIMIT_FILE" <<EOF
remaining=$GITHUB_RATE_LIMIT_REMAINING
reset=$GITHUB_RATE_LIMIT_RESET
EOF
}

# Check if we're approaching rate limit
is_rate_limited() {
  load_rate_limit_state

  if [ $GITHUB_RATE_LIMIT_REMAINING -lt 10 ]; then
    local now=$(date +%s)
    if [ $GITHUB_RATE_LIMIT_RESET -gt $now ]; then
      log_warn "[github] Rate limit approaching ($GITHUB_RATE_LIMIT_REMAINING remaining)"
      return 0
    fi
  fi

  return 1
}

# Make authenticated API call with rate limit tracking
github_api_call() {
  local endpoint="$1"
  local method="${2:-GET}"
  local data="${3:-}"

  init_github_client

  # Check cache first
  local cache_file=$(get_cache_file "$endpoint")
  if is_cache_valid "$cache_file"; then
    log_debug "[github] Using cached response for $endpoint"
    cat "$cache_file"
    return 0
  fi

  # Check if rate limited
  if is_rate_limited; then
    log_warn "[github] Rate limited, attempting to use cache"
    if [ -f "$cache_file" ]; then
      cat "$cache_file"
      return 0
    else
      log_error "[github] Rate limited and no cache available"
      return 1
    fi
  fi

  # Build curl command
  local curl_opts="-s -w \n%{http_code}"
  local headers="-H 'Accept: application/vnd.github.$GITHUB_API_VERSION+json'"

  # Add authentication if token provided
  if [ -n "$GITHUB_TOKEN" ]; then
    headers="$headers -H 'Authorization: token $GITHUB_TOKEN'"
    log_debug "[github] Using authenticated API call (token provided)"
  else
    log_debug "[github] Using unauthenticated API call (60 req/hr limit)"
  fi

  # Make the API call
  local response=$(eval "curl $curl_opts $headers -X $method '$GITHUB_API_BASE$endpoint' $data" 2>/dev/null)

  # Parse response and HTTP code
  local http_code=$(echo "$response" | tail -1)
  local body=$(echo "$response" | head -n-1)

  # Handle rate limit errors
  if [ "$http_code" = "403" ] || echo "$body" | grep -q "API rate limit exceeded"; then
    log_error "[github] Rate limit exceeded for endpoint: $endpoint"

    # Try to use cache as fallback
    if [ -f "$cache_file" ]; then
      log_warn "[github] Using stale cache as fallback"
      cat "$cache_file"
      return 0
    else
      log_error "[github] No cache available, request failed"
      return 1
    fi
  fi

  # Handle other errors
  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    log_error "[github] API call failed with HTTP $http_code"

    # Try cache fallback
    if [ -f "$cache_file" ]; then
      log_warn "[github] Using cache despite error"
      cat "$cache_file"
      return 0
    else
      return 1
    fi
  fi

  # Extract rate limit headers from response
  # Note: curl response doesn't include headers with -s flag, would need -i for full response
  # For now, we track what we can from body

  # Cache successful response
  mkdir -p "$GITHUB_CACHE_DIR"
  echo "$body" > "$cache_file"

  log_debug "[github] Cached response for $endpoint"

  echo "$body"
  return 0
}

# Convenience function for GET requests
github_get() {
  local endpoint="$1"
  github_api_call "$endpoint" "GET"
}

# Convenience function for POST requests
github_post() {
  local endpoint="$1"
  local data="$2"
  github_api_call "$endpoint" "POST" "$data"
}

# Get repository information
github_get_repo() {
  local org="$1"
  local repo="$2"

  github_get "/repos/$org/$repo"
}

# Get repository policies (for IaC validation)
github_get_iac_policies() {
  local org="$1"
  local repo="$2"

  github_get "/repos/$org/$repo/contents/.teya/iac-policies"
}

# Get branch protection rules
github_get_branch_protection() {
  local org="$1"
  local repo="$2"
  local branch="$3"

  github_get "/repos/$org/$repo/branches/$branch/protection"
}

# List repository secrets (metadata only, not actual values)
github_list_repo_secrets() {
  local org="$1"
  local repo="$2"

  github_get "/repos/$org/$repo/actions/secrets"
}

# Check rate limit status
github_get_rate_limit() {
  github_get "/rate_limit"
}

# Format rate limit info for display
github_display_rate_limit() {
  local rate_limit_json=$(github_get_rate_limit)

  if echo "$rate_limit_json" | grep -q "resources"; then
    echo "$rate_limit_json" | grep -o '"remaining": [0-9]*' | head -1
  else
    echo "Rate limit info unavailable"
  fi
}

# Export variables
export GITHUB_TOKEN
export GITHUB_API_BASE
export GITHUB_CACHE_DIR
