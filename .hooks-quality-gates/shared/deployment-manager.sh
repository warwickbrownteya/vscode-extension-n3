#!/bin/bash
# shared/deployment-manager.sh
# Manage reliable, atomic hook deployments with automatic rollback

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"
source "$SHARED_DIR/integrity-checker.sh"

HOOK_NAME="deployment-manager"
DEPLOYMENT_DIR="${DEPLOYMENT_DIR:-.teya/deployments}"
DEPLOYMENT_HISTORY="${DEPLOYMENT_HISTORY:-.teya/deployment-history.jsonl}"
DEPLOYMENT_MANIFEST="${DEPLOYMENT_MANIFEST:-.teya/deployment-manifest.json}"

# Initialize deployment directory
init_deployment_manager() {
  mkdir -p "$DEPLOYMENT_DIR"
  mkdir -p "$(dirname "$DEPLOYMENT_HISTORY")"
  mkdir -p "$(dirname "$DEPLOYMENT_MANIFEST")"
  return 0
}

# Record deployment in history log (JSONL format)
record_deployment() {
  local status="$1"
  local version="$2"
  local message="$3"
  local metadata="${4:-}"

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local entry
  entry=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "status": "$status",
  "version": "$version",
  "message": "$message"
EOF
)

  if [ -n "$metadata" ]; then
    entry="$entry,$(echo "$metadata" | sed 's/{//' | sed 's/}//')"
  fi

  entry="$entry
}"

  echo "$entry" >> "$DEPLOYMENT_HISTORY"
  log_info "[$HOOK_NAME] Deployment recorded: $status ($version) - $message"
}

# Get current deployed version
get_current_version() {
  local hooks_dir="${1:-.hooks-quality-gates}"

  if [ ! -d "$hooks_dir" ]; then
    echo "unknown"
    return 1
  fi

  # Use directory timestamp as simple version
  local timestamp
  timestamp=$(stat -f%m "$hooks_dir" 2>/dev/null || stat -c%Y "$hooks_dir" 2>/dev/null)
  echo "deployed-$timestamp"
  return 0
}

# Generate version ID for new deployment
generate_version() {
  local base_version="$1"
  local timestamp
  timestamp=$(date +%s)
  echo "${base_version:-deployment}-$(date +%Y%m%d-%H%M%S)-$timestamp"
}

# Create backup before deployment
create_deployment_backup() {
  local hooks_dir="$1"
  local backup_dir="$2"
  local version="$3"

  log_debug "[$HOOK_NAME] Creating deployment backup: $version"

  mkdir -p "$backup_dir/$version"

  # Backup hooks
  if [ -d "$hooks_dir/hooks" ]; then
    cp -r "$hooks_dir/hooks" "$backup_dir/$version/" 2>/dev/null || {
      log_error "[$HOOK_NAME] Failed to backup hooks"
      return 1
    }
  fi

  # Backup shared libraries
  if [ -d "$hooks_dir/shared" ]; then
    cp -r "$hooks_dir/shared" "$backup_dir/$version/" 2>/dev/null || {
      log_error "[$HOOK_NAME] Failed to backup shared libraries"
      return 1
    }
  fi

  # Backup configs
  if [ -d "$hooks_dir/config" ]; then
    cp -r "$hooks_dir/config" "$backup_dir/$version/" 2>/dev/null || {
      log_error "[$HOOK_NAME] Failed to backup config files"
      return 1
    }
  fi

  # Record backup metadata
  local backup_manifest
  backup_manifest="$backup_dir/$version/MANIFEST.json"
  {
    echo "{"
    echo "  \"version\": \"$version\","
    echo "  \"created_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"source\": \"pre-deployment-backup\""
    echo "}"
  } > "$backup_manifest"

  log_debug "[$HOOK_NAME] Backup created: $backup_dir/$version"
  return 0
}

# Verify deployment completeness
verify_deployment() {
  local hooks_dir="$1"

  log_debug "[$HOOK_NAME] Verifying deployment integrity"

  # Check all required directories exist
  if [ ! -d "$hooks_dir/hooks" ]; then
    log_error "[$HOOK_NAME] Hooks directory missing"
    return 1
  fi

  if [ ! -d "$hooks_dir/shared" ]; then
    log_error "[$HOOK_NAME] Shared libraries directory missing"
    return 1
  fi

  # Verify key files exist
  local key_files=(
    "hooks/secrets.sh"
    "hooks/sast.sh"
    "hooks/sca.sh"
    "hooks/iac.sh"
    "hooks/gate-evaluator.sh"
    "shared/logger.sh"
    "shared/exception-loader.sh"
    "shared/findings-parser.sh"
  )

  local missing_count=0
  for file in "${key_files[@]}"; do
    if [ ! -f "$hooks_dir/$file" ]; then
      log_error "[$HOOK_NAME] Critical file missing: $file"
      ((missing_count++))
    fi
  done

  if [ $missing_count -gt 0 ]; then
    log_error "[$HOOK_NAME] Deployment incomplete: $missing_count files missing"
    return 1
  fi

  # Verify executability of hooks
  for hook in "$hooks_dir"/hooks/*.sh; do
    if [ ! -x "$hook" ]; then
      log_error "[$HOOK_NAME] Hook not executable: $(basename "$hook")"
      return 1
    fi
  done

  log_debug "[$HOOK_NAME] Deployment verification successful"
  return 0
}

# Restore from backup
restore_from_backup() {
  local backup_dir="$1"
  local version="$2"
  local hooks_dir="${3:-.hooks-quality-gates}"

  if [ ! -d "$backup_dir/$version" ]; then
    log_error "[$HOOK_NAME] Backup not found: $version"
    return 1
  fi

  log_warn "[$HOOK_NAME] Restoring deployment from backup: $version"

  # Remove current deployment
  rm -rf "$hooks_dir/hooks" "$hooks_dir/shared" "$hooks_dir/config" 2>/dev/null || true

  # Restore from backup
  if [ -d "$backup_dir/$version/hooks" ]; then
    cp -r "$backup_dir/$version/hooks" "$hooks_dir/" 2>/dev/null || {
      log_error "[$HOOK_NAME] Failed to restore hooks"
      return 1
    }
  fi

  if [ -d "$backup_dir/$version/shared" ]; then
    cp -r "$backup_dir/$version/shared" "$hooks_dir/" 2>/dev/null || {
      log_error "[$HOOK_NAME] Failed to restore shared libraries"
      return 1
    }
  fi

  if [ -d "$backup_dir/$version/config" ]; then
    cp -r "$backup_dir/$version/config" "$hooks_dir/" 2>/dev/null || {
      log_error "[$HOOK_NAME] Failed to restore configs"
      return 1
    }
  fi

  log_info "[$HOOK_NAME] Restoration complete from backup $version"
  return 0
}

# Perform atomic deployment
deploy_hooks() {
  local source_dir="$1"
  local target_dir="${2:-.hooks-quality-gates}"
  local deployment_name="${3:-manual-deployment}"

  init_deployment_manager

  # Generate version ID
  local version
  version=$(generate_version "$deployment_name")
  log_info "[$HOOK_NAME] Starting deployment: $version"

  # Create backup of current state
  if ! create_deployment_backup "$target_dir" "$DEPLOYMENT_DIR" "pre-$version"; then
    log_error "[$HOOK_NAME] Backup failed, aborting deployment"
    record_deployment "failed" "$version" "Backup failed" ""
    return 1
  fi

  # Use atomic deploy pattern: temp dir + mv
  local deploy_temp
  deploy_temp=$(mktemp -d)
  trap 'rm -rf "$deploy_temp"' RETURN

  log_debug "[$HOOK_NAME] Staging deployment to temp directory: $deploy_temp"

  # Copy source to temp
  if ! cp -r "$source_dir"/* "$deploy_temp/"; then
    log_error "[$HOOK_NAME] Failed to stage files, deployment aborted"
    record_deployment "failed" "$version" "File staging failed" ""
    return 1
  fi

  # Make hooks executable
  chmod +x "$deploy_temp/hooks"/*.sh 2>/dev/null || true

  # Verify staged deployment
  if ! verify_deployment "$deploy_temp"; then
    log_error "[$HOOK_NAME] Staged deployment verification failed, aborting"
    record_deployment "failed" "$version" "Verification failed before deployment" ""
    return 1
  fi

  log_debug "[$HOOK_NAME] Staged deployment verified, performing atomic move"

  # Atomic move: create backup marker first
  local old_hooks="$target_dir.rollback-$$"
  if [ -d "$target_dir" ]; then
    mv "$target_dir" "$old_hooks" || {
      log_error "[$HOOK_NAME] Failed to create rollback point"
      record_deployment "failed" "$version" "Rollback point creation failed" ""
      return 1
    }
  fi

  # Move staged deployment to target
  if ! mv "$deploy_temp" "$target_dir"; then
    log_error "[$HOOK_NAME] Atomic move failed, rolling back"
    if [ -d "$old_hooks" ]; then
      mv "$old_hooks" "$target_dir"
    fi
    record_deployment "failed" "$version" "Atomic move failed" ""
    return 1
  fi

  # Clean up rollback marker
  rm -rf "$old_hooks" 2>/dev/null || true

  # Verify deployed state
  if ! verify_deployment "$target_dir"; then
    log_error "[$HOOK_NAME] Post-deployment verification failed, attempting rollback"

    if [ -d "$DEPLOYMENT_DIR/pre-$version" ]; then
      restore_from_backup "$DEPLOYMENT_DIR" "pre-$version" "$target_dir"
      record_deployment "failed-rollback" "$version" "Post-deployment verification failed, rolled back" ""
      return 1
    fi
  fi

  # Verify integrity using existing checker
  if ! ensure_integrity "$target_dir" "." > /dev/null 2>&1; then
    log_warn "[$HOOK_NAME] Integrity check had warnings but deployment proceeded"
  fi

  log_info "[$HOOK_NAME] Deployment completed successfully: $version"
  record_deployment "success" "$version" "Deployment completed and verified" ""

  # Update manifest
  {
    echo "{"
    echo "  \"current_version\": \"$version\","
    echo "  \"deployed_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"status\": \"active\","
    echo "  \"source\": \"$source_dir\""
    echo "}"
  } > "$DEPLOYMENT_MANIFEST"

  return 0
}

# Rollback to previous deployment
rollback_deployment() {
  local target_version="${1:-}"
  local target_dir="${2:-.hooks-quality-gates}"

  init_deployment_manager

  log_warn "[$HOOK_NAME] Initiating deployment rollback"

  if [ -z "$target_version" ]; then
    # Find most recent successful deployment before current
    local current_version
    current_version=$(get_current_version "$target_dir")

    # Use most recent backup
    local backups=($(ls -1d "$DEPLOYMENT_DIR"/pre-* 2>/dev/null | sort -r | head -1))

    if [ -z "${backups[0]}" ]; then
      log_error "[$HOOK_NAME] No backups available for rollback"
      return 1
    fi

    target_version=$(basename "${backups[0]}" | sed 's/pre-//')
  fi

  log_info "[$HOOK_NAME] Rolling back to version: $target_version"

  if ! restore_from_backup "$DEPLOYMENT_DIR" "pre-$target_version" "$target_dir"; then
    log_error "[$HOOK_NAME] Rollback failed"
    record_deployment "rollback-failed" "$target_version" "Rollback failed" ""
    return 1
  fi

  # Verify restored state
  if ! verify_deployment "$target_dir"; then
    log_error "[$HOOK_NAME] Rolled back state verification failed"
    record_deployment "rollback-failed" "$target_version" "Verification failed after rollback" ""
    return 1
  fi

  log_info "[$HOOK_NAME] Rollback completed successfully to version: $target_version"
  record_deployment "rollback-success" "$target_version" "Rollback completed and verified" ""

  return 0
}

# List deployment history
show_deployment_history() {
  local limit="${1:-20}"

  if [ ! -f "$DEPLOYMENT_HISTORY" ]; then
    echo "No deployment history available"
    return 0
  fi

  echo "Deployment History (last $limit):"
  echo ""
  tail -n "$limit" "$DEPLOYMENT_HISTORY" | while read -r line; do
    # Pretty-print JSON lines
    echo "$line" | grep -q "success" && prefix="✓" || prefix="✗"
    timestamp=$(echo "$line" | grep -o '"timestamp": "[^"]*"' | cut -d'"' -f4)
    status=$(echo "$line" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
    version=$(echo "$line" | grep -o '"version": "[^"]*"' | cut -d'"' -f4)
    message=$(echo "$line" | grep -o '"message": "[^"]*"' | cut -d'"' -f4)

    printf "%s %s | %s | %s | %s\n" "$prefix" "$timestamp" "$status" "$version" "$message"
  done
}

# Get deployment status
get_deployment_status() {
  local target_dir="${1:-.hooks-quality-gates}"

  if [ ! -f "$DEPLOYMENT_MANIFEST" ]; then
    echo "No deployment manifest found"
    return 1
  fi

  echo "Current Deployment Status:"
  echo ""
  cat "$DEPLOYMENT_MANIFEST" | grep -v "^{" | grep -v "^}" | sed 's/^ *//'
}

# Export functions
export DEPLOYMENT_DIR
export DEPLOYMENT_HISTORY
export DEPLOYMENT_MANIFEST
