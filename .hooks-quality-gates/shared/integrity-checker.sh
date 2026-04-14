#!/bin/bash
# shared/integrity-checker.sh
# Verify and restore integrity of Quality Gates hooks and libraries

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"

HOOK_NAME="integrity-checker"
MANIFEST_FILE="${MANIFEST_FILE:-.teya/manifest.json}"

# Generate SHA256 hash manifest of hooks and shared libraries
generate_manifest() {
  local hooks_dir="$1"
  local output_file="$2"

  log_debug "[$HOOK_NAME] Generating integrity manifest"

  local temp_manifest
  temp_manifest=$(mktemp)
  trap 'rm -f "$temp_manifest"' RETURN

  local generated_at
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  {
    echo "{"
    echo "  \"generated_at\": \"$generated_at\","
    echo "  \"files\": {"
  } > "$temp_manifest"

  local first=true
  local file_count=0

  # Hash all hook scripts
  if [ -d "$hooks_dir/hooks" ]; then
    for hook in "$hooks_dir"/hooks/*.sh; do
      if [ -f "$hook" ]; then
        local hash
        hash=$(sha256sum "$hook" 2>/dev/null | cut -d' ' -f1)
        local basename
        basename=$(basename "$hook")

        if [ "$first" = true ]; then
          first=false
        else
          echo "," >> "$temp_manifest"
        fi

        printf '    "hooks/%s": "%s"' "$basename" "$hash" >> "$temp_manifest"
        ((file_count++))
      fi
    done
  fi

  # Hash all shared libraries
  if [ -d "$hooks_dir/shared" ]; then
    for lib in "$hooks_dir"/shared/*.sh; do
      if [ -f "$lib" ]; then
        local hash
        hash=$(sha256sum "$lib" 2>/dev/null | cut -d' ' -f1)
        local basename
        basename=$(basename "$lib")

        if [ "$first" = true ]; then
          first=false
        else
          echo "," >> "$temp_manifest"
        fi

        printf '    "shared/%s": "%s"' "$basename" "$hash" >> "$temp_manifest"
        ((file_count++))
      fi
    done
  fi

  # Hash all config files
  if [ -d "$hooks_dir/config" ]; then
    for config in "$hooks_dir"/config/*; do
      if [ -f "$config" ]; then
        local hash
        hash=$(sha256sum "$config" 2>/dev/null | cut -d' ' -f1)
        local basename
        basename=$(basename "$config")

        if [ "$first" = true ]; then
          first=false
        else
          echo "," >> "$temp_manifest"
        fi

        printf '    "config/%s": "%s"' "$basename" "$hash" >> "$temp_manifest"
        ((file_count++))
      fi
    done
  fi

  {
    echo ""
    echo "  }"
    echo "}"
  } >> "$temp_manifest"

  # Move to final location
  mkdir -p "$(dirname "$output_file")"
  mv "$temp_manifest" "$output_file"

  log_debug "[$HOOK_NAME] Generated manifest for $file_count files"
  return 0
}

# Verify integrity against manifest
verify_manifest() {
  local hooks_dir="$1"
  local manifest_file="$2"

  if [ ! -f "$manifest_file" ]; then
    log_warn "[$HOOK_NAME] Manifest not found, integrity check skipped"
    return 0  # Non-blocking - regenerate manifest
  fi

  log_debug "[$HOOK_NAME] Verifying file integrity"

  local integrity_ok=true

  # Verify all files listed in manifest
  local files_checked=0
  local files_modified=0

  # Check hook scripts
  if [ -d "$hooks_dir/hooks" ]; then
    for hook in "$hooks_dir"/hooks/*.sh; do
      if [ -f "$hook" ]; then
        local basename
        basename=$(basename "$hook")
        local expected_hash
        expected_hash=$(grep -o "\"hooks/$basename\": \"[^\"]*\"" "$manifest_file" 2>/dev/null | cut -d'"' -f4)

        if [ -z "$expected_hash" ]; then
          log_warn "[$HOOK_NAME] Missing manifest entry: hooks/$basename"
          integrity_ok=false
          ((files_modified++))
        else
          local actual_hash
          actual_hash=$(sha256sum "$hook" 2>/dev/null | cut -d' ' -f1)
          if [ "$actual_hash" != "$expected_hash" ]; then
            log_error "[$HOOK_NAME] Hash mismatch: hooks/$basename (modified externally)"
            integrity_ok=false
            ((files_modified++))
          fi
        fi
        ((files_checked++))
      fi
    done
  fi

  # Check shared libraries
  if [ -d "$hooks_dir/shared" ]; then
    for lib in "$hooks_dir"/shared/*.sh; do
      if [ -f "$lib" ]; then
        local basename
        basename=$(basename "$lib")
        local expected_hash
        expected_hash=$(grep -o "\"shared/$basename\": \"[^\"]*\"" "$manifest_file" 2>/dev/null | cut -d'"' -f4)

        if [ -z "$expected_hash" ]; then
          log_warn "[$HOOK_NAME] Missing manifest entry: shared/$basename"
          integrity_ok=false
          ((files_modified++))
        else
          local actual_hash
          actual_hash=$(sha256sum "$lib" 2>/dev/null | cut -d' ' -f1)
          if [ "$actual_hash" != "$expected_hash" ]; then
            log_error "[$HOOK_NAME] Hash mismatch: shared/$basename (modified externally)"
            integrity_ok=false
            ((files_modified++))
          fi
        fi
        ((files_checked++))
      fi
    done
  fi

  if [ "$integrity_ok" = true ]; then
    log_debug "[$HOOK_NAME] All $files_checked files verified successfully"
    return 0
  else
    log_error "[$HOOK_NAME] Integrity check failed: $files_modified files modified or missing"
    return 1
  fi
}

# Restore files from persistent hooks directory if integrity check fails
restore_from_persistent() {
  local hooks_dir="$1"
  local repo_root="$2"

  log_warn "[$HOOK_NAME] Restoring Quality Gates files from persistent copy"

  # Verify persistent directory exists
  if [ ! -d "$repo_root/.hooks-quality-gates" ]; then
    log_error "[$HOOK_NAME] Persistent hooks directory not found, cannot restore"
    return 1
  fi

  # Restore hooks
  if [ -d "$repo_root/.hooks-quality-gates/hooks" ]; then
    cp -r "$repo_root/.hooks-quality-gates/hooks"/* "$hooks_dir/hooks/" 2>/dev/null || true
    log_info "[$HOOK_NAME] Restored hook scripts"
  fi

  # Restore shared libraries
  if [ -d "$repo_root/.hooks-quality-gates/shared" ]; then
    cp -r "$repo_root/.hooks-quality-gates/shared"/* "$hooks_dir/shared/" 2>/dev/null || true
    log_info "[$HOOK_NAME] Restored shared libraries"
  fi

  # Restore configs
  if [ -d "$repo_root/.hooks-quality-gates/config" ]; then
    cp -r "$repo_root/.hooks-quality-gates/config"/* "$hooks_dir/config/" 2>/dev/null || true
    log_info "[$HOOK_NAME] Restored configuration files"
  fi

  # Re-generate manifest with restored files
  generate_manifest "$hooks_dir" "$repo_root/$MANIFEST_FILE" || true

  log_info "[$HOOK_NAME] Quality Gates files restored successfully"
  return 0
}

# Main function: check integrity and restore if needed
ensure_integrity() {
  local hooks_dir="${1:-.hooks-quality-gates}"
  local repo_root="${2:-.}"
  local manifest_file="$repo_root/$MANIFEST_FILE"

  log_debug "[$HOOK_NAME] Starting integrity verification"

  # Verify integrity
  if ! verify_manifest "$hooks_dir" "$manifest_file"; then
    log_warn "[$HOOK_NAME] Integrity verification failed, attempting restore"

    # Try to restore from persistent copy
    if ! restore_from_persistent "$hooks_dir" "$repo_root"; then
      log_error "[$HOOK_NAME] Failed to restore Quality Gates files"
      return 1
    fi

    log_info "[$HOOK_NAME] Quality Gates files restored and re-verified"
  fi

  log_debug "[$HOOK_NAME] Integrity check completed successfully"
  return 0
}
