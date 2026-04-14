#!/bin/bash
# shared/metrics-autodiscovery.sh
# Automatic registration and discovery for centralized metrics collection
# Enables developer laptops to register with central Prometheus instance

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh" 2>/dev/null || {
  log_info() { echo "[INFO] $*"; }
  log_error() { echo "[ERROR] $*"; }
  log_warn() { echo "[WARN] $*"; }
  log_debug() { echo "[DEBUG] $*"; }
}

HOOK_NAME="metrics-autodiscovery"

# Configuration
METRICS_REGISTRY="${METRICS_REGISTRY:-.teya/metrics-registry.json}"
METRICS_AUTODISCOVERY_ENABLED="${METRICS_AUTODISCOVERY_ENABLED:-1}"
CENTRAL_PROMETHEUS_URL="${CENTRAL_PROMETHEUS_URL:-}"
CENTRAL_PROMETHEUS_API_TOKEN="${CENTRAL_PROMETHEUS_API_TOKEN:-}"
METRICS_EXPORT_PORT="${METRICS_EXPORT_PORT:-9090}"

# Get laptop identification
get_laptop_id() {
  # Try multiple methods to get a unique, stable ID

  # Method 1: Use hostname
  local hostname
  hostname=$(hostname -s 2>/dev/null)
  if [ -n "$hostname" ]; then
    echo "$hostname"
    return 0
  fi

  # Method 2: Use MAC address hash
  local mac_addr
  mac_addr=$(ifconfig 2>/dev/null | grep -i "hwaddr\|ether" | head -1 | awk '{print $NF}' | tr -d ':')
  if [ -n "$mac_addr" ]; then
    echo "dev-${mac_addr:0:8}"
    return 0
  fi

  # Method 3: Use UUID
  if [ -f "/sys/class/dmi/id/product_uuid" ]; then
    cat "/sys/class/dmi/id/product_uuid" 2>/dev/null | tr -d '-' | cut -c1-8
    return 0
  fi

  # Fallback
  echo "unknown-laptop-$RANDOM"
}

# Get local IP address reachable from VPN
get_local_ip() {
  local vpn_subnet="${1:-10.0.0.0/8}"

  # Try to get VPN IP (usually 10.x or 172.x)
  ip addr show 2>/dev/null | grep -E "inet\s+(10\.|172\.)" | head -1 | awk '{print $2}' | cut -d'/' -f1

  # Fallback: Use default interface IP
  if [ -z "$ip" ]; then
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

# Build laptop metadata for registration
build_laptop_metadata() {
  local laptop_id="$1"
  local metrics_endpoint="$2"

  local os_name
  os_name=$(uname -s)

  local os_version
  case "$os_name" in
    Darwin)
      os_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
      ;;
    Linux)
      os_version=$(uname -r)
      ;;
    *)
      os_version="unknown"
      ;;
  esac

  local arch
  arch=$(uname -m)

  local registered_at
  registered_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Output as JSON
  cat <<EOF
{
  "laptop_id": "$laptop_id",
  "hostname": "$(hostname -s 2>/dev/null)",
  "metrics_endpoint": "$metrics_endpoint",
  "metrics_port": $METRICS_EXPORT_PORT,
  "registered_at": "$registered_at",
  "last_heartbeat": "$registered_at",
  "environment": "developer",
  "organization": "teya",
  "os": {
    "type": "$os_name",
    "version": "$os_version",
    "arch": "$arch"
  },
  "metrics_enabled": true,
  "autodiscovery_version": "1.0"
}
EOF
}

# Register laptop with local registry
register_locally() {
  local laptop_id="$1"
  local metadata="$2"

  log_debug "[$HOOK_NAME] Registering laptop locally: $laptop_id"

  mkdir -p "$(dirname "$METRICS_REGISTRY")"

  # Create or update registry
  if [ ! -f "$METRICS_REGISTRY" ]; then
    echo "[]" > "$METRICS_REGISTRY"
  fi

  # Add/update entry in registry
  {
    echo "$metadata" | jq '.' > /tmp/laptop-metadata-$$.json

    # Use jq to add to array (with upsert)
    jq --arg id "$laptop_id" '.[] |= if .laptop_id == $id then . else empty end | if length == 0 then . + [input] else . end' \
      "$METRICS_REGISTRY" /tmp/laptop-metadata-$$.json > "$METRICS_REGISTRY.tmp" 2>/dev/null || {
      # Fallback if jq fails
      echo "[$metadata]" > "$METRICS_REGISTRY"
    }

    rm -f /tmp/laptop-metadata-$$.json
    [ -f "$METRICS_REGISTRY.tmp" ] && mv "$METRICS_REGISTRY.tmp" "$METRICS_REGISTRY"
  }

  log_debug "[$HOOK_NAME] Laptop registered locally"
  return 0
}

# Register with central Prometheus API
register_with_central() {
  local laptop_id="$1"
  local metrics_endpoint="$2"

  if [ -z "$CENTRAL_PROMETHEUS_URL" ]; then
    log_debug "[$HOOK_NAME] Central Prometheus URL not configured, skipping central registration"
    return 0
  fi

  log_debug "[$HOOK_NAME] Registering with central Prometheus: $CENTRAL_PROMETHEUS_URL"

  local registration_url="$CENTRAL_PROMETHEUS_URL/api/v1/targets/register"

  local payload=$(cat <<EOF
{
  "laptop_id": "$laptop_id",
  "hostname": "$(hostname -s 2>/dev/null)",
  "metrics_endpoint": "$metrics_endpoint",
  "metrics_port": $METRICS_EXPORT_PORT,
  "registered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "environment": "developer"
}
EOF
)

  # Attempt registration with retry
  local attempt=1
  local max_attempts=3

  while [ $attempt -le $max_attempts ]; do
    local response
    response=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Content-Type: application/json" \
      ${CENTRAL_PROMETHEUS_API_TOKEN:+-H "Authorization: Bearer $CENTRAL_PROMETHEUS_API_TOKEN"} \
      -d "$payload" \
      "$registration_url" 2>/dev/null)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | head -n-1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
      log_info "[$HOOK_NAME] Successfully registered with central Prometheus"
      return 0
    else
      log_warn "[$HOOK_NAME] Central registration failed (HTTP $http_code, attempt $attempt/$max_attempts)"
      if [ $attempt -lt $max_attempts ]; then
        sleep $((2 ** attempt))  # Exponential backoff
      fi
    fi

    ((attempt++))
  done

  log_warn "[$HOOK_NAME] Could not register with central Prometheus (non-blocking)"
  return 1
}

# Send heartbeat to central Prometheus
send_heartbeat() {
  local laptop_id="$1"
  local metrics_endpoint="$2"

  if [ -z "$CENTRAL_PROMETHEUS_URL" ]; then
    return 0
  fi

  log_debug "[$HOOK_NAME] Sending heartbeat to central Prometheus"

  local heartbeat_url="$CENTRAL_PROMETHEUS_URL/api/v1/targets/$laptop_id/heartbeat"

  local payload=$(cat <<EOF
{
  "last_seen": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "metrics_reachable": true
}
EOF
)

  curl -s -X POST \
    -H "Content-Type: application/json" \
    ${CENTRAL_PROMETHEUS_API_TOKEN:+-H "Authorization: Bearer $CENTRAL_PROMETHEUS_API_TOKEN"} \
    -d "$payload" \
    "$heartbeat_url" > /dev/null 2>&1 || true
}

# Enable metrics autodiscovery
enable_autodiscovery() {
  if [ "$METRICS_AUTODISCOVERY_ENABLED" != "1" ]; then
    log_debug "[$HOOK_NAME] Metrics autodiscovery disabled"
    return 0
  fi

  log_debug "[$HOOK_NAME] Enabling metrics autodiscovery"

  local laptop_id
  laptop_id=$(get_laptop_id)

  local local_ip
  local_ip=$(get_local_ip)

  local metrics_endpoint="http://$local_ip:$METRICS_EXPORT_PORT/metrics"

  log_debug "[$HOOK_NAME] Laptop ID: $laptop_id, Metrics: $metrics_endpoint"

  # Build metadata
  local metadata
  metadata=$(build_laptop_metadata "$laptop_id" "$metrics_endpoint")

  # Register locally
  register_locally "$laptop_id" "$metadata"

  # Register with central Prometheus
  register_with_central "$laptop_id" "$metrics_endpoint"

  # Send periodic heartbeat (optional)
  send_heartbeat "$laptop_id" "$metrics_endpoint"

  return 0
}

# Disable metrics for this laptop
disable_autodiscovery() {
  local laptop_id
  laptop_id=$(get_laptop_id)

  log_info "[$HOOK_NAME] Disabling metrics autodiscovery for $laptop_id"

  # Remove from local registry
  if [ -f "$METRICS_REGISTRY" ]; then
    jq --arg id "$laptop_id" '.[] |= select(.laptop_id != $id)' "$METRICS_REGISTRY" > "$METRICS_REGISTRY.tmp"
    mv "$METRICS_REGISTRY.tmp" "$METRICS_REGISTRY"
  fi

  # Deregister from central
  if [ -n "$CENTRAL_PROMETHEUS_URL" ]; then
    local deregister_url="$CENTRAL_PROMETHEUS_URL/api/v1/targets/$laptop_id"
    curl -s -X DELETE \
      ${CENTRAL_PROMETHEUS_API_TOKEN:+-H "Authorization: Bearer $CENTRAL_PROMETHEUS_API_TOKEN"} \
      "$deregister_url" > /dev/null 2>&1 || true
  fi

  return 0
}

# Show autodiscovery status
show_status() {
  echo "Metrics Autodiscovery Status:"
  echo ""

  local laptop_id
  laptop_id=$(get_laptop_id)

  echo "  Laptop ID: $laptop_id"
  echo "  Enabled: $METRICS_AUTODISCOVERY_ENABLED"
  echo "  Export Port: $METRICS_EXPORT_PORT"
  echo ""

  if [ -f "$METRICS_REGISTRY" ]; then
    echo "  Local Registry: $METRICS_REGISTRY"
    jq ".[0]" "$METRICS_REGISTRY" 2>/dev/null || echo "    No entries"
  else
    echo "  Local Registry: Not found"
  fi

  if [ -n "$CENTRAL_PROMETHEUS_URL" ]; then
    echo ""
    echo "  Central Prometheus: $CENTRAL_PROMETHEUS_URL"
  else
    echo ""
    echo "  Central Prometheus: Not configured"
  fi
}

# Export functions
export METRICS_REGISTRY
export METRICS_AUTODISCOVERY_ENABLED
export CENTRAL_PROMETHEUS_URL
export METRICS_EXPORT_PORT
