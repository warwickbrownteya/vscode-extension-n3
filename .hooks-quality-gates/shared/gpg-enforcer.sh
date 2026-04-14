#!/bin/bash
# shared/gpg-enforcer.sh
# Enforce GPG commit signing as required by organization policy

# Determine shared library directory
if [ -n "$HOOKS_DIR" ]; then
  SHARED_DIR="$HOOKS_DIR/shared"
else
  SHARED_DIR="$(dirname "$0")"
fi

source "$SHARED_DIR/logger.sh"

HOOK_NAME="gpg-enforcer"
ENFORCE_GPG="${ENFORCE_GPG:-true}"  # Set to false to disable enforcement
GPG_KEY_PATTERN="${GPG_KEY_PATTERN:-.*}"  # Regex pattern for acceptable keys (optional)

# Check if GPG signing is configured for this repository
check_gpg_config() {
  local user_signingkey=$(git config user.signingkey || echo "")
  local commit_gpgsign=$(git config commit.gpgsign || echo "")

  if [ "$commit_gpgsign" != "true" ]; then
    log_warn "[$HOOK_NAME] GPG signing not configured (commit.gpgsign != true)"
    return 1
  fi

  if [ -z "$user_signingkey" ]; then
    log_warn "[$HOOK_NAME] No GPG signing key configured (user.signingkey)"
    return 1
  fi

  log_debug "[$HOOK_NAME] GPG signing configured: key=$user_signingkey"
  return 0
}

# Check if commit will be signed (dry run)
will_commit_be_signed() {
  # Check git config for GPG signing
  local gpgsign=$(git config commit.gpgsign)
  local signingkey=$(git config user.signingkey)

  if [ "$gpgsign" = "true" ] && [ -n "$signingkey" ]; then
    return 0  # Will be signed
  fi

  return 1  # Will not be signed
}

# Verify GPG key is available and valid
verify_gpg_key() {
  local signingkey=$(git config user.signingkey)

  if [ -z "$signingkey" ]; then
    log_error "[$HOOK_NAME] No GPG signing key configured"
    return 1
  fi

  # Check if key exists in GPG keyring
  if ! gpg --list-keys "$signingkey" &>/dev/null; then
    log_error "[$HOOK_NAME] GPG key not found in keyring: $signingkey"
    return 1
  fi

  log_debug "[$HOOK_NAME] GPG key verified: $signingkey"
  return 0
}

# Enforce GPG signing requirement
enforce_gpg_signing() {
  if [ "$ENFORCE_GPG" != "true" ]; then
    log_debug "[$HOOK_NAME] GPG enforcement disabled"
    return 0
  fi

  log_info "[$HOOK_NAME] Checking GPG signing configuration"

  # Check GPG is configured
  if ! check_gpg_config; then
    log_error "[$HOOK_NAME] GPG signing not properly configured"
    log_error "[$HOOK_NAME] Run: git config commit.gpgsign true"
    log_error "[$HOOK_NAME] Run: git config user.signingkey <GPG_KEY_ID>"
    return 1
  fi

  # Verify GPG key is available
  if ! verify_gpg_key; then
    log_error "[$HOOK_NAME] GPG key verification failed"
    log_error "[$HOOK_NAME] Ensure GPG key is available: gpg --list-keys"
    return 1
  fi

  # Check if this commit will be signed
  if ! will_commit_be_signed; then
    log_error "[$HOOK_NAME] Commit will not be GPG signed"
    log_error "[$HOOK_NAME] Ensure commit.gpgsign is true: git config commit.gpgsign"
    return 1
  fi

  log_info "[$HOOK_NAME] GPG signing requirement verified ✓"
  return 0
}

# Provide setup instructions
show_gpg_setup_instructions() {
  cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║          Quality Gates: GPG Signing Configuration              ║
╚════════════════════════════════════════════════════════════════╝

To enable GPG-signed commits, follow these steps:

STEP 1: Generate or import a GPG key
  # List existing keys
  gpg --list-keys

  # Generate new key (if needed)
  gpg --gen-key

STEP 2: Configure git to use your GPG key
  # Set globally (all repositories)
  git config --global user.signingkey <GPG_KEY_ID>
  git config --global commit.gpgsign true

  # Or set per repository
  cd /path/to/repository
  git config user.signingkey <GPG_KEY_ID>
  git config commit.gpgsign true

STEP 3: Configure GPG agent (optional, for automatic signing)
  # macOS
  brew install gpg-agent

  # Linux
  sudo apt-get install gnupg2 gpg-agent

  # Set pinentry mode in ~/.gnupg/gpg-agent.conf:
  pinentry-program /usr/bin/pinentry-curses

STEP 4: Test GPG signing
  git commit --allow-empty -m "test: gpg signing"
  git log --show-signature -1

TROUBLESHOOTING:
  • "error: gpg failed to sign the data"
    → Ensure GPG key is available: gpg --list-keys
    → Check GPG agent: gpg-agent --daemon

  • "No such file or directory"
    → Install GPG: brew install gnupg (macOS) or apt-get install gnupg (Linux)

  • Key not found
    → Verify key ID: gpg --list-keys | grep -i <email>
    → Use full key fingerprint if needed

For more information: https://docs.github.com/en/authentication/managing-commit-signature-verification

EOF
}

# Disable GPG enforcement for emergency bypass (temporary)
disable_gpg_enforcement() {
  log_warn "[$HOOK_NAME] GPG enforcement disabled (temporary)"
  export ENFORCE_GPG=false
}
