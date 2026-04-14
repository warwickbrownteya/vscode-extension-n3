#!/bin/bash
# shared/logger.sh
# Centralized logging for all hooks

TEYA_HOOKS_LOG="${TEYA_HOOKS_LOG:-.teya/hooks.log}"
TEYA_LOG_LEVEL="${TEYA_LOG_LEVEL:-info}"

# Ensure log directory exists
mkdir -p "$(dirname "$TEYA_HOOKS_LOG")"

# Log levels: debug, info, warn, error, critical
log_debug() {
  if [ "$TEYA_LOG_LEVEL" = "debug" ]; then
    echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$TEYA_HOOKS_LOG" >&2
  fi
}

log_info() {
  echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$TEYA_HOOKS_LOG"
}

log_warn() {
  echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$TEYA_HOOKS_LOG" >&2
}

log_error() {
  echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$TEYA_HOOKS_LOG" >&2
}

log_critical() {
  echo "[CRITICAL] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$TEYA_HOOKS_LOG" >&2
}
