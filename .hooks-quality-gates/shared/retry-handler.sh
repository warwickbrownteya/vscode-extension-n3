#!/bin/bash
# shared/retry-handler.sh
# Retry logic with exponential backoff and circuit breaker

# Retry command with exponential backoff
# Usage: retry_with_backoff <max_attempts> <initial_delay> <command>
retry_with_backoff() {
  local max_attempts=${1:-3}
  local initial_delay=${2:-1}
  shift 2
  local command=("$@")
  local attempt=1
  local delay=$initial_delay

  while [ $attempt -le $max_attempts ]; do
    if "${command[@]}"; then
      return 0
    fi

    if [ $attempt -lt $max_attempts ]; then
      echo "Attempt $attempt failed, retrying in ${delay}s..." >&2
      sleep "$delay"
      # Exponential backoff: delay * 2, max 30s
      delay=$((delay * 2))
      if [ $delay -gt 30 ]; then
        delay=30
      fi
    fi

    ((attempt++))
  done

  echo "Command failed after $max_attempts attempts" >&2
  return 1
}

# Circuit breaker pattern: track failures and disable after threshold
CIRCUIT_BREAKER_STATE="${CIRCUIT_BREAKER_STATE:-.teya/circuit-breaker.json}"

# Initialize circuit breaker
init_circuit_breaker() {
  local service="$1"
  mkdir -p "$(dirname "$CIRCUIT_BREAKER_STATE")"

  if [ ! -f "$CIRCUIT_BREAKER_STATE" ]; then
    echo '{}' > "$CIRCUIT_BREAKER_STATE"
  fi
}

# Record a failure in the circuit breaker
record_failure() {
  local service="$1"
  local max_failures=${2:-5}

  init_circuit_breaker "$service"

  local failures=$(jq --arg svc "$service" '.[$svc] // 0' "$CIRCUIT_BREAKER_STATE")
  ((failures++))

  jq --arg svc "$service" --arg f "$failures" '.[$svc] = ($f | tonumber)' "$CIRCUIT_BREAKER_STATE" > "$CIRCUIT_BREAKER_STATE.tmp"
  mv "$CIRCUIT_BREAKER_STATE.tmp" "$CIRCUIT_BREAKER_STATE"

  if [ "$failures" -ge "$max_failures" ]; then
    return 1  # Circuit breaker open
  fi
  return 0  # Circuit breaker closed
}

# Reset circuit breaker for a service
reset_circuit_breaker() {
  local service="$1"

  init_circuit_breaker "$service"
  jq --arg svc "$service" 'del(.[$svc])' "$CIRCUIT_BREAKER_STATE" > "$CIRCUIT_BREAKER_STATE.tmp"
  mv "$CIRCUIT_BREAKER_STATE.tmp" "$CIRCUIT_BREAKER_STATE"
}

# Check circuit breaker state
is_circuit_open() {
  local service="$1"
  local max_failures=${2:-5}

  init_circuit_breaker "$service"

  local failures=$(jq --arg svc "$service" '.[$svc] // 0' "$CIRCUIT_BREAKER_STATE")
  [ "$failures" -ge "$max_failures" ]
}
