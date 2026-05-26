#!/usr/bin/env bash
#
# Dwarven-Smart-GIT-Sync
# Part of the DwarvenSuite -- https://github.com/gitdwarf
#
# Copyright (C) 2026 thedwarf / gitdwarf
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# smart-git-sync.sh
Version="0.2.5"
Released="2026-05-25"
#
# Changelog:
#   0.2.5 - Credential verification reworked to honour the brief
#           fn_verify_account_credentials: local sanity check only (no network)
#             checks key file exists on disk, token looks like a GitHub PAT
#             trust stored credentials until proven wrong by actual sync failure
#           fn_rotate_account_credentials: called on auth error during sync
#             re-prompts interactively, saves updated credentials, logs next step
#             non-interactive (cron): logs clear error with fix command, no hang
#           Auth failure detection in fn_sync_repo fetch and push paths
#
#   0.2.4 - Auto credential rotation, non-interactive tty guard - Auto credential rotation: fn_verify_account_credentials
#           Loaded credentials tested on every run; stale creds re-prompt automatically
#           Non-interactive guard: if stdin is not a tty, logs clear error and bails
#             rather than hanging forever (cron/automation safe)
#           fn_detect_mode: same non-interactive guard for missing credentials
#
#   0.2.3 - Two-way sync: fetch-then-decide (push/pull/diverged/in-sync) - Two-way sync: fn_sync_repo now fetch-then-decide
#           remote ahead -> pull (merge with ff-only if set)
#           local ahead  -> push
#           both moved   -> DIVERGED: skip with exact recovery commands
#           already sync -> no-op
#           PAT auth now uses token-in-URL for fetch and push (same fix as clone)
#           dry-run reports direction that would be taken per repo
#
#   0.2.2 - Fixed PAT clone auth: token-in-URL replaces GIT_ASKPASS - Fixed PAT clone auth: token-in-URL (https://<pat>@github.com/...)
#           replaces GIT_ASKPASS which doesn't work with fine-grained PATs
#           Fix applies to both fn_create_repo and fn_clone_missing_for_account
#           Verified live against real GitHub: create, clone, delete all pass
#
#   0.2.1 - Fixed clone-missing JSON parser (grep on indent vs broken bash regex) - Fixed fn_clone_missing_for_account JSON parser: bash regex fails on
#           multiline API responses; replaced with grep on 4-space indent (reliable)
#           fn_create_repo 403 error now names exact permission required:
#           fine-grained PAT needs Administration:write, classic PAT needs repo scope
#
#   0.2.0 - Branch awareness, auto_stash, --clone-missing, SSH passphrase detection - Branch awareness: detached HEAD and untracked branches skipped with clear message
#           Non-default branch (not main/master) warns loudly but still pulls
#           auto_stash: stash dirty changes, pull, pop; on pop failure leaves stash
#             and prints exact recovery command (repairable at 2am)
#           auto_stash added to XML config schema
#           --clone-missing: fetch GitHub repo list via API, clone absent repos
#             PAT required; SSH-only accounts get clear error; paginated (100/page)
#             dry-run aware; skips already-present repos
#           SSH passphrase detection in fn_test_ssh_key: warns with actionable options
#           dry-run log now shows branch name and auto_stash setting
#
#   0.1.9 - --help heredoc unquoted; version+date in usage output - --help heredoc now unquoted; version+date appear at top of usage output
#
#   0.1.8 - Version/Released are now executable var assignments in the script header
#           script_version and script_released reference them directly
#           Version bump is now two sed lines at the top of the file, nothing else
#
#   0.1.7 - --version / -V flag: prints version string and exits
#
#   0.1.6 - --reset with two safety gates, case-sensitive 'yes' confirmation
#           fn_email_log: pipes log file to mail after fn_print_summary
#           fn_init_logging: preflight check - disables email early if
#             'mail' not found or log_dir not set, with install hint
#           Subject line flags FAILURES when repos_failed > 0
#           Dry-run aware: logs intent without sending
#           No-op when email_logs=false, log_email_address empty, or log_file missing
#
#   0.0.9 - --dry-run functional for sync, --add-account, --remove-account
#
#   0.0.8 - CLI arg parsing, --create-repo, --dry-run (flag only), --help
#
#   0.0.7 - found counter now only increments for actual git repos
#           "No subdirectories" message corrected to "No git repos found"
#
#   0.0.6 - Repo processing implemented (replaces stubs)
#           fn_sync_repo: single-repo sync (dirty check, pull, counter update)
#           fn_process_repos_single_account: enumerate $github_root/*/
#           fn_process_repos_multi_account: enumerate $github_root/<account>/*/
#           Both call fn_sync_repo - no duplicated logic
#           Handles: missing root, not-a-repo dirs, dirty repos,
#                    already-up-to-date, actual updates, missing account dirs
#
#   0.0.5 - Style: whole script reindented to 2-space consistently
#
#   0.0.4 - XML config: parser and writer implemented (replaces stubs)
#           fn_xml_get_value: pure-bash single-tag extractor
#           fn_xml_get_accounts: pure-bash multi-value account list extractor
#           fn_load_external_config: loads all vars from .cfg, ignores invalid fields
#           fn_write_external_config: atomic write (tmp + mv), chmod 0600, header comment
#           Config is fully generated by the script - not intended for hand-editing
#           Repo processing: implemented in 0.0.6
#
#   0.0.3 - Initial versioned release
#           Hardware-fingerprint credential encryption
#           Multi-account support (associative arrays)
#           SSH key + PAT auto-detection and validation
#           Mode detection: first-run / single-account / multi-account
#           Path normaliser (absolute, $HOME-relative, ./-relative)
#           Logging: stdout + optional file
#           Repo processing and XML config: stubs (implemented in 0.0.6, 0.0.4)
#
# Safe, multi-repo, multi-account Git sync tool
# Designed for unattended automation *and* paranoid humans
#
# Philosophy:
# - No surprises
# - Explicit authority
# - Repairable by humans at 2am
#

set -euo pipefail

### User Variables START ###

cfg_path=""

# Path to external XML config (if set, overrides all internal vars below)
#
# Path handling:
#   - Absolute path (starts with /): used as-is
#     Example: "/etc/smart-git-sync" → /etc/smart-git-sync/smart-git-sync.cfg
#
#   - Relative path (no leading /): relative to $HOME
#     Example: ".config" → $HOME/.config/smart-git-sync.cfg
#
#   - Explicit $PWD relative: use ./
#     Example: "./configs" → $PWD/configs/smart-git-sync.cfg
#
#   - With or without trailing /: both work
#     Example: ".config" and ".config/" → same result
#
#   - Filename is always: smart-git-sync.cfg
#
#   - Empty = use internal vars below (no external config)

## User variables (ignored if cfg_path is set) ##

# Root directory containing repos or account directories
github_root="$HOME/GitHub"

# List of accounts (comma or space separated)
# If length == 1  → single-account mode
# If length > 1   → multi-account mode
accounts=""

# Safety controls
allow_dirty=false        # If true, skip dirty repo prompts
fast_forward_only=true   # Enforce --ff-only pulls
auto_stash=false         # If true, stash dirty changes, pull, pop (implies allow_dirty)

# Logging controls
#
# Hierarchy:
#   enable_logging=true  → ALWAYS logs to stdout
#                        → PLUS file (if log_dir set)
#                        → PLUS email (if email_logs=true AND log_email_address set)
#
#   enable_logging=false → silent (no output at all)
#
# log_dir path handling (same as cfg_path above):
#   - Absolute: /var/log/git-sync → /var/log/git-sync/smart-git-sync_TIMESTAMP.log
#   - Relative: .local/state → $HOME/.local/state/smart-git-sync_TIMESTAMP.log
#   - Explicit $PWD: ./logs → $PWD/logs/smart-git-sync_TIMESTAMP.log
#   - Empty = no file logging (stdout + email only)
#
# email_logs:
#   - Requires log_email_address to be set
#   - If log_email_address empty, email disabled regardless of this setting
#   - Requires MTA (mail transport agent) on system
enable_logging=true
log_dir="$HOME/.local/state/smart-git-sync"
email_logs=false
log_email_address=""

# Password storage (encrypted with hardware fingerprint)
#
# If empty or unset → ALWAYS prompt for credentials, never offer to store
# If set            → stores encrypted token at this path
password_store="$HOME/.config/smart-git-sync/.ghtoken"

### User Variables END ###


### Script starts here ###

## Internal state (do not edit) ##

script_name="$(basename "$0")"
script_version="$Version"
script_released="$Released"
run_timestamp="$(date +'%Y-%m-%d_%H-%M-%S')"
mode=""               # single-account | multi-account | first-run
use_external_cfg=false
dry_run=false
show_status=false
list_repos=false
reset_config=false
clone_missing=false

# --create-repo state
create_repo_name=""
create_repo_account=""
create_repo_description=""
create_repo_visibility=""  # public | private (set by prompt)

# --add-account / --remove-account state
manage_account_action=""   # add | remove
manage_account_name=""     # optional: name pre-supplied via --account

# Associative arrays for multi-account credential storage
declare -A account_auth_method
declare -A account_token
declare -A account_ssh_key

# Apply sensible defaults if user vars unchanged
[[ "$github_root" == "$HOME/GitHub" ]] && github_root="$PWD"
[[ "$password_store" == "$HOME/.config/smart-git-sync/.ghtoken" ]] && password_store="$HOME/.config/smart-git-sync/.ghtoken"

# Counters for summary
repos_total=0
repos_updated=0
repos_dirty=0
repos_skipped=0
repos_failed=0

# Log file path (set during init)
log_file=""

### Utility functions ###

fn_log_msg() {
  local msg="$1"
  local timestamp="$(date +'%Y-%m-%d %H:%M:%S')"

  # Always to stdout
  echo "[$timestamp] $msg"

  # To file if enabled
  if [[ -n "$log_file" && -f "$log_file" ]]; then
    echo "[$timestamp] $msg" >> "$log_file"
  fi
}

fn_fatal_error() {
  local msg="$1"
  fn_log_msg "FATAL: $msg"
  exit 1
}

fn_prompt_value() {
  local prompt="$1"
  local secret="${2:-false}"
  local value=""

  if [[ "$secret" == "true" ]]; then
    read -rsp "$prompt: " value
    echo >&2  # newline after secret input (stderr only - stdout is the return channel)
  else
    read -rp "$prompt: " value
  fi

  echo "$value"
}

# Multi-use path normaliser - used for cfg_path, log_dir, etc.
# $1 = path (absolute, relative to $HOME, or ./ relative to $PWD)
# $2 = filename to append (e.g. "smart-git-sync.cfg")
fn_normalize_path() {
  local path="$1"
  local filename="$2"

  # Empty = return empty
  if [[ -z "$path" ]]; then
    echo ""
    return
  fi

  # Expand tilde (~)
  path="${path/#\~/$HOME}"

  # If doesn't start with /, prepend $HOME (relative to home)
  if [[ "$path" != /* && "$path" != ./* ]]; then
    path="$HOME/$path"
  fi

  # If starts with ./, expand to $PWD
  if [[ "$path" == ./* ]]; then
    path="$PWD/${path#./}"
  fi

  # Remove trailing slash if present
  path="${path%/}"

  # Append filename
  echo "$path/$filename"
}

### Password storage (hardware fingerprint encryption, multi-account) ###

# Derive an encryption key from this machine's identity
# machine-id + root disk UUID + username → SHA-256 hash
# Stolen credential file is useless on a different machine or as a different user
fn_get_hardware_fingerprint() {
  local fingerprint=""

  # Machine ID (unique per system, persists across reboots)
  if [[ -f /etc/machine-id ]]; then
    fingerprint+=$(cat /etc/machine-id)
  fi

  # Root filesystem UUID (unique per installation)
  local root_uuid
  root_uuid=$(findmnt -n -o UUID / 2>/dev/null)
  if [[ -n "$root_uuid" ]]; then
    fingerprint+="$root_uuid"
  fi

  # Username (ties to specific user on this machine)
  fingerprint+="$USER"

  # Hash it all together → 256-bit key
  echo -n "$fingerprint" | sha256sum | cut -d' ' -f1
}

# Encrypt a single account's credentials into a base64 blob
# $1 = account name
# $2 = auth_method (ssh|token)
# $3 = credential (ssh_key path OR token)
fn_encrypt_account_credentials() {
  local account="$1"
  local auth_method="$2"
  local credential="$3"

  local key
  key=$(fn_get_hardware_fingerprint)

  # Build plaintext blob
  local plaintext
  if [[ "$auth_method" == "ssh" ]]; then
    plaintext="auth_method=ssh
ssh_key=$credential"
  else
    plaintext="auth_method=token
token=$credential"
  fi

  # Encrypt and base64 encode (single line, no wrapping)
  echo "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -pass pass:"$key" -base64 -A 2>/dev/null
}

# Decrypt a single account's credential blob
# $1 = base64 encrypted blob
# Returns: decrypted plaintext (auth_method=... and token=... OR ssh_key=...)
fn_decrypt_account_credentials() {
  local blob="$1"
  local key
  key=$(fn_get_hardware_fingerprint)

  # Decrypt base64 blob
  echo "$blob" | openssl enc -aes-256-cbc -pbkdf2 -d -pass pass:"$key" -base64 -A 2>/dev/null
}

# Parse decrypted credentials into auth_method and credential
# $1 = decrypted plaintext
# Returns: "auth_method|credential" (e.g. "ssh|/path/to/key" or "token|ghp_xyz")
fn_parse_account_credentials() {
  local decrypted="$1"

  local auth_method
  auth_method=$(echo "$decrypted" | grep '^auth_method=' | cut -d= -f2)

  if [[ "$auth_method" == "ssh" ]]; then
    local ssh_key
    ssh_key=$(echo "$decrypted" | grep '^ssh_key=' | cut -d= -f2)
    echo "ssh|$ssh_key"
  else
    local token
    token=$(echo "$decrypted" | grep '^token=' | cut -d= -f2)
    echo "token|$token"
  fi
}

# Load all credentials from password_store file into global arrays
fn_load_all_credentials() {
  # If password_store is empty/unset → return (will prompt per-account later)
  if [[ -z "$password_store" ]]; then
    return 0
  fi

  # If file doesn't exist or is empty (sentinel) → return
  if [[ ! -f "$password_store" || ! -s "$password_store" ]]; then
    return 0
  fi

  # Read file, skip comments and empty lines
  while IFS=': ' read -r account blob; do
    # Skip comments, empty lines, and malformed lines
    [[ -z "$account" || "$account" =~ ^# || -z "$blob" ]] && continue

    # Decrypt this account's blob
    local decrypted
    decrypted=$(fn_decrypt_account_credentials "$blob")

    if [[ -z "$decrypted" ]]; then
      fn_log_msg "WARNING: Failed to decrypt credentials for $account (wrong machine?)"
      continue
    fi

    # Parse credentials
    local parsed
    parsed=$(fn_parse_account_credentials "$decrypted")
    local auth_method
    auth_method=$(echo "$parsed" | cut -d'|' -f1)
    local credential
    credential=$(echo "$parsed" | cut -d'|' -f2)

    # Store in global arrays
    account_auth_method[$account]="$auth_method"
    if [[ "$auth_method" == "ssh" ]]; then
      account_ssh_key[$account]="$credential"
    else
      account_token[$account]="$credential"
    fi

  done < <(grep -v '^#' "$password_store" | grep -v '^$')

  fn_log_msg "Loaded credentials for ${#account_auth_method[@]} account(s)"
}

# Sanity-check loaded credentials without hitting the network
# Only checks that the credential exists and looks plausible
# Real validation happens on first actual sync failure (trust until proven wrong)
# $1 = account name
fn_verify_account_credentials() {
  local account="$1"
  local auth_method="${account_auth_method[$account]:-}"

  if [[ "$auth_method" == "ssh" ]]; then
    local key="${account_ssh_key[$account]:-}"
    if [[ -z "$key" ]]; then
      fn_log_msg "WARNING: No SSH key path stored for '$account'"
      return 1
    fi
    if [[ ! -f "$key" ]]; then
      fn_log_msg "WARNING: SSH key for '$account' not found at: $key"
      fn_log_msg "         Update credentials: smart-git-sync.sh --add-account"
      return 1
    fi
  elif [[ "$auth_method" == "token" ]]; then
    local token="${account_token[$account]:-}"
    if [[ -z "$token" ]]; then
      fn_log_msg "WARNING: No token stored for '$account'"
      return 1
    fi
    # Basic plausibility: GitHub PATs start with ghp_, github_pat_, or gho_
    if [[ ! "$token" =~ ^gh[pos]_|^github_pat_ ]]; then
      fn_log_msg "WARNING: Token for '$account' does not look like a GitHub PAT"
      fn_log_msg "         If sync fails with auth errors, run: smart-git-sync.sh --add-account"
    fi
  else
    fn_log_msg "WARNING: Unknown auth method '$auth_method' for '$account'"
    return 1
  fi

  return 0
}

# Re-prompt for credentials after an auth failure during sync
# Called from fn_sync_repo when a push/pull/fetch fails with auth error
# $1 = account name
fn_rotate_account_credentials() {
  local account="$1"

  fn_log_msg "Auth failure for '$account' - credentials may be expired"

  if [[ ! -t 0 ]]; then
    fn_log_msg "ERROR: stdin is not a terminal - cannot prompt for new credentials"
    fn_log_msg "       Run interactively to update: smart-git-sync.sh --add-account"
    return 1
  fi

  echo ""
  echo "Authentication failed for account '$account'."
  echo "Credentials may be expired or revoked."
  echo ""

  # Clear stale credential
  unset "account_auth_method[$account]"
  unset "account_token[$account]"
  unset "account_ssh_key[$account]"

  if fn_prompt_and_validate_credential "$account"; then
    account="$CREDENTIAL_ACCOUNT"
    fn_log_msg "New credentials accepted for '$account'"
    if [[ -n "$password_store" ]]; then
      fn_save_credentials
      fn_log_msg "Updated credentials saved to: $password_store"
    fi
    return 0
  else
    fn_log_msg "Credential update for '$account' cancelled"
    return 1
  fi
}

# Save all credentials from global arrays to password_store file
fn_save_credentials() {
  if [[ -z "$password_store" ]]; then
    fn_log_msg "No password_store configured - credentials not saved"
    return 1
  fi

  local tmp
  tmp=$(mktemp)

  # Write header
  cat > "$tmp" <<EOF
# smart-git-sync credentials
# Last updated: $(date '+%Y-%m-%d %H:%M:%S')

EOF

  # Write each account (sorted for consistent output)
  for account in $(echo "${!account_auth_method[@]}" | tr ' ' '\n' | sort); do
    local auth="${account_auth_method[$account]}"
    local blob

    if [[ "$auth" == "ssh" ]]; then
      blob=$(fn_encrypt_account_credentials "$account" "ssh" "${account_ssh_key[$account]}")
    else
      blob=$(fn_encrypt_account_credentials "$account" "token" "${account_token[$account]}")
    fi

    echo "$account: $blob" >> "$tmp"
    echo "" >> "$tmp"  # Double line space for readability
  done

  # Create directory if needed
  mkdir -p "$(dirname "$password_store")"

  # Move to final location
  mv "$tmp" "$password_store"
  chmod 0600 "$password_store"

  fn_log_msg "Credentials saved to $password_store"
}

# Test if a specific SSH key works for GitHub authentication
# $1 = SSH key path
# $2 = expected account name
# Returns: 0 if authenticated as expected account, 1 otherwise
fn_test_ssh_key() {
  local key_path="$1"
  local account="$2"

  # Verify key file exists and is readable
  if [[ ! -f "$key_path" ]]; then
    fn_log_msg "SSH key not found: $key_path"
    return 1
  fi

  # Passphrase detection: try to read the public key with an empty passphrase
  # If it fails, the key is passphrase-protected -- will hang unattended
  if ! ssh-keygen -y -P "" -f "$key_path" &>/dev/null; then
    fn_log_msg "WARNING: SSH key has a passphrase: $key_path"
    fn_log_msg "         This will block unattended use. Consider using ssh-agent,"
    fn_log_msg "         or a passphrase-free key dedicated to automation."
    echo ""
    echo "WARNING: SSH key '$key_path' is passphrase-protected."
    echo "         Unattended sync will hang waiting for the passphrase."
    echo "         Options:"
    echo "           1. Run ssh-agent and ssh-add before running this script"
    echo "           2. Use a separate passphrase-free key for automation"
    echo "           3. Use a PAT instead (--add-account, choose token auth)"
    echo ""
    # Don't fail -- user may have ssh-agent running; warn and continue
  fi

  # Test this specific key against GitHub
  local result
  result=$(ssh -T -i "$key_path" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null git@github.com 2>&1)

  # Check for success message
  if echo "$result" | grep -q "successfully authenticated"; then
    # Extract username from response
    local ssh_user
    ssh_user=$(echo "$result" | grep -o "Hi [^!]*" | cut -d' ' -f2)

    if [[ "$ssh_user" == "$account" ]]; then
      fn_log_msg "SSH key authenticated as $ssh_user ✓"
      return 0
    else
      fn_log_msg "SSH key authenticated as '$ssh_user' but expected '$account'"
      return 1
    fi
  else
    fn_log_msg "SSH authentication failed for key: $key_path"
    return 1
  fi
}

# Test if a Personal Access Token is valid for GitHub
# $1 = token string
# $2 = expected account name
# Returns: 0 if authenticated as expected account, 1 otherwise
fn_test_pat() {
  local token="$1"
  local account="$2"

  local api_result

  # Try curl first, then wget, then give up
  if command -v curl >/dev/null 2>&1; then
    api_result=$(curl -s -H "Authorization: token $token" https://api.github.com/user 2>/dev/null)
  elif command -v wget >/dev/null 2>&1; then
    api_result=$(wget -q --header="Authorization: token $token" -O- https://api.github.com/user 2>/dev/null)
  else
    # No curl/wget - can't validate, trust user input
    fn_log_msg "WARNING: curl/wget not found - cannot validate PAT (will test during git operations)"
    return 0  # Assume valid, will fail later if wrong
  fi

  # Check if we got a valid response with login field
  if echo "$api_result" | grep -q '"login"'; then
    local api_user
    api_user=$(echo "$api_result" | grep '"login"' | head -1 | sed 's/.*"login": *"\([^"]*\)".*/\1/')

    if [[ "$api_user" == "$account" ]]; then
      fn_log_msg "PAT authenticated as $api_user ✓"
      return 0
    else
      fn_log_msg "PAT authenticated as '$api_user' but expected '$account'"
      return 1
    fi
  else
    # Check for error messages
    if echo "$api_result" | grep -q "Bad credentials"; then
      fn_log_msg "PAT authentication failed: Bad credentials"
    else
      fn_log_msg "PAT authentication failed: Invalid or expired token"
    fi
    return 1
  fi
}

# Smart credential detection - accepts SSH key path OR PAT, figures out which
# $1 = user input (path to SSH key OR token string)
# $2 = account name
# Returns: "ssh|/path/to/key" or "token|ghp_xxx" on success, empty on failure
fn_detect_credential_type() {
  local input="$1"
  local account="$2"

  # Strategy 1: Does it look like a file path and exist?
  if [[ -f "$input" ]]; then
    fn_log_msg "Detected file path, testing as SSH key..."
    if fn_test_ssh_key "$input" "$account"; then
      echo "ssh|$input"
      return 0
    else
      return 1
    fi
  fi

  # Strategy 2: Does it match GitHub PAT format?
  # Classic: ghp_xxxxx (40 chars after prefix)
  # Fine-grained: github_pat_xxxxx
  if [[ "$input" =~ ^(ghp_|github_pat_) ]]; then
    fn_log_msg "Detected GitHub PAT format, testing..."
    if fn_test_pat "$input" "$account"; then
      echo "token|$input"
      return 0
    else
      return 1
    fi
  fi

  # Strategy 3: Not a file, doesn't match PAT format
  # Could be:
  #   - Old PAT format
  #   - User pasted without ghp_ prefix
  #   - Just random string
  # Try as PAT anyway
  fn_log_msg "Unknown format, attempting as PAT..."
  if fn_test_pat "$input" "$account"; then
    echo "token|$input"
    return 0
  fi

  # Nothing worked
  return 1
}

# Prompt for and validate a credential for a known account name
# Retry loop until valid credential or user cancels
# User can also correct the account name during retry
# Does NOT prompt to save - caller decides that
# $1 = account name (initial, may be changed by user during retry)
# Sets account_auth_method, account_token, account_ssh_key on success
# Also sets CREDENTIAL_ACCOUNT to the final (possibly corrected) account name
# Returns: 0 on success, 1 on cancel
fn_prompt_and_validate_credential() {
  local account="$1"

  while true; do
    echo ""
    echo "Account: $account"
    echo "Enter either:"
    echo "  • SSH key path (e.g. /home/user/.ssh/id_ed25519)"
    echo "  • Personal Access Token from https://github.com/settings/tokens"
    echo ""

    local credential
    credential=$(fn_prompt_value "SSH key path OR Personal Access Token for $account" true)

    # Detect and validate
    local detected
    if detected=$(fn_detect_credential_type "$credential" "$account"); then
      local auth_method
      auth_method=$(echo "$detected" | cut -d'|' -f1)
      local credential_value
      credential_value=$(echo "$detected" | cut -d'|' -f2-)

      # Store in arrays
      account_auth_method[$account]="$auth_method"
      if [[ "$auth_method" == "ssh" ]]; then
        account_ssh_key[$account]="$credential_value"
        fn_log_msg "✓ Credentials verified for $account (SSH key)"
      else
        account_token[$account]="$credential_value"
        fn_log_msg "✓ Credentials verified for $account (Personal Access Token)"
      fi

      # Export the final account name back to caller
      CREDENTIAL_ACCOUNT="$account"
      return 0  # Success
    else
      # Failed - could be invalid, expired, or wrong account name
      echo ""
      echo "❌ Authentication failed - credential invalid, expired, or account name mismatch"
      echo ""
      echo "   1) Try different credential (keep account: $account)"
      echo "   2) Change account name"
      echo "   3) Cancel"
      echo ""
      local retry_choice
      read -rp "   Choice [1/2/3]: " retry_choice
      case "$retry_choice" in
        2)
          # Let them correct the account name
          account=$(fn_prompt_value "GitHub account name")
          fn_log_msg "Account name changed to: $account"
          ;;
        3|[Cc]|[Nn])
          fn_log_msg "Credential setup cancelled"
          return 1
          ;;
        *)
          # Default (including just Enter or "1") = retry credential
          ;;
      esac
      # Loop back to credential prompt
    fi
  done
}

# Setup credentials for a single account (first-run or --add-account)
# Prompts for account name, then credential
# Only prompts to save AFTER successful authentication
# On save, overwrites existing entry for this account
fn_setup_account_credentials() {
  local account

  # Prompt for account name
  account=$(fn_prompt_value "GitHub account name")

  # Validate credential (retry loop - user may also correct account name)
  if ! fn_prompt_and_validate_credential "$account"; then
    return 1  # User cancelled
  fi

  # Pick up the final account name (may have been corrected during retry)
  account="$CREDENTIAL_ACCOUNT"

  # Only offer to save after success
  if [[ -n "$password_store" ]]; then
    local save_choice
    read -rp "Store logon credentials for $account? [Y/n]: " save_choice
    case "$save_choice" in
      [Nn]*)
        fn_log_msg "Credentials for $account not stored"
        ;;
      *)
        fn_save_credentials
        ;;
    esac
  fi
}

### Config handling ###

# Extract the text content of a single XML tag (first occurrence)
# Pure bash - no xmllint dependency
# $1 = tag name (e.g. "github_root")
# $2 = XML string to search
# Returns: trimmed text content, or empty string if tag absent/empty
fn_xml_get_value() {
  local tag="$1"
  local xml="$2"
  local value=""

  # Match <tag>content</tag> (content may span whitespace)
  if [[ "$xml" =~ \<${tag}\>([^'<']*)\</${tag}\> ]]; then
    value="${BASH_REMATCH[1]}"
    # Trim leading/trailing whitespace
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  fi

  echo "$value"
}

# Extract all <account> children from an <accounts> block
# $1 = XML string
# Prints one account per line
fn_xml_get_accounts() {
  local xml="$1"
  local accounts_block=""

  # Pull out everything between <accounts> and </accounts>
  if [[ "$xml" =~ \<accounts\>(.*)\</accounts\> ]]; then
  accounts_block="${BASH_REMATCH[1]}"
  else
  return 0
  fi

  # Extract each <account>value</account>
  local remainder="$accounts_block"
  while [[ "$remainder" =~ \<account\>([^'<']+)\</account\>(.*) ]]; do
  local acct="${BASH_REMATCH[1]}"
  remainder="${BASH_REMATCH[2]}"
  # Trim whitespace
  acct="${acct#"${acct%%[![:space:]]*}"}"
  acct="${acct%"${acct##*[![:space:]]}"}"
  [[ -n "$acct" ]] && echo "$acct"
  done
}

# Load all settings from the XML config file into runtime vars
# Validates required fields; ignores invalid/missing fields (script regenerates on write)
# Aborts with fn_fatal_error only if the file exists but is unreadable/corrupt
fn_load_external_config() {
  local cfg_file="$cfg_path"

  if [[ ! -f "$cfg_file" ]]; then
  fn_log_msg "Config file not found: $cfg_file - will create on first run"
  return 0
  fi

  if [[ ! -r "$cfg_file" ]]; then
  fn_fatal_error "Config file exists but is not readable: $cfg_file"
  fi

  fn_log_msg "Loading config from: $cfg_file"

  # Read entire file into a single string (strip newlines for regex matching)
  local xml
  xml=$(tr '\n' ' ' < "$cfg_file")

  # --- github_root ---
  local val
  val=$(fn_xml_get_value "github_root" "$xml")
  if [[ -n "$val" ]]; then
  github_root="$val"
  fn_log_msg "Config: github_root = $github_root"
  else
  fn_log_msg "Config: github_root missing or empty - keeping default ($github_root)"
  fi

  # --- accounts ---
  local loaded_accounts
  loaded_accounts=$(fn_xml_get_accounts "$xml")
  if [[ -n "$loaded_accounts" ]]; then
  # Convert newline-separated list back to space-separated string (matches existing var format)
  accounts=$(echo "$loaded_accounts" | tr '\n' ' ' | sed 's/ $//')
  fn_log_msg "Config: accounts = $accounts"
  else
  fn_log_msg "Config: no accounts found in config"
  fi

  # --- safety ---
  val=$(fn_xml_get_value "allow_dirty" "$xml")
  if [[ "$val" == "true" || "$val" == "false" ]]; then
  allow_dirty="$val"
  fn_log_msg "Config: allow_dirty = $allow_dirty"
  fi

  val=$(fn_xml_get_value "fast_forward_only" "$xml")
  if [[ "$val" == "true" || "$val" == "false" ]]; then
  fast_forward_only="$val"
  fn_log_msg "Config: fast_forward_only = $fast_forward_only"
  fi

  val=$(fn_xml_get_value "auto_stash" "$xml")
  if [[ "$val" == "true" || "$val" == "false" ]]; then
  auto_stash="$val"
  fn_log_msg "Config: auto_stash = $auto_stash"
  fi

  # --- logging ---
  val=$(fn_xml_get_value "enabled" "$xml")
  if [[ "$val" == "true" || "$val" == "false" ]]; then
  enable_logging="$val"
  fn_log_msg "Config: enable_logging = $enable_logging"
  fi

  val=$(fn_xml_get_value "log_dir" "$xml")
  if [[ -n "$val" ]]; then
  log_dir="$val"
  fn_log_msg "Config: log_dir = $log_dir"
  fi

  val=$(fn_xml_get_value "email_logs" "$xml")
  if [[ "$val" == "true" || "$val" == "false" ]]; then
  email_logs="$val"
  fn_log_msg "Config: email_logs = $email_logs"
  fi

  val=$(fn_xml_get_value "log_email_address" "$xml")
  if [[ -n "$val" ]]; then
  log_email_address="$val"
  fn_log_msg "Config: log_email_address = $log_email_address"
  fi

  # --- password_store ---
  val=$(fn_xml_get_value "password_store" "$xml")
  # Explicit empty tag = sentinel mode (never store creds)
  # Tag absent = keep default
  if [[ "$xml" =~ \<password_store\> ]]; then
  password_store="$val"
  if [[ -n "$val" ]]; then
      fn_log_msg "Config: password_store = $password_store"
  else
      fn_log_msg "Config: password_store empty - sentinel mode (will always prompt)"
  fi
  fi

  fn_log_msg "Config loaded successfully"
}

# Write current runtime vars to the XML config file
# Generates the file from scratch - invalid or hand-edited content is replaced
# Safe: writes to tmp then moves atomically
fn_write_external_config() {
  local cfg_file="$cfg_path"

  if [[ -z "$cfg_file" ]]; then
  fn_log_msg "No cfg_path set - cannot write config"
  return 1
  fi

  # Ensure directory exists
  mkdir -p "$(dirname "$cfg_file")"

  local tmp
  tmp=$(mktemp)

  # Build accounts block
  local accounts_xml=""
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"
  for acct in "${account_array[@]}"; do
  [[ -z "$acct" ]] && continue
  accounts_xml+="        <account>${acct}</account>"$'\n'
  done

    cat > "$tmp" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!--
    smart-git-sync configuration
    Generated: $(date '+%Y-%m-%d %H:%M:%S')
    Version:   ${script_version}

    This file is managed by smart-git-sync.
    Invalid or unrecognised values are ignored and will be overwritten on next save.
    Do not add credentials here - those are stored separately in password_store.
-->
<smart-git-sync>

    <!-- Root directory containing repos (single-account) or account subdirs (multi-account) -->
    <github_root>${github_root}</github_root>

    <!-- GitHub account names. Add one <account> per line. -->
    <accounts>
${accounts_xml}    </accounts>

    <safety>
        <!-- If true, dirty repos are synced without prompting. Default: false -->
        <allow_dirty>${allow_dirty}</allow_dirty>
        <!-- If true, only fast-forward merges are permitted. Default: true -->
        <fast_forward_only>${fast_forward_only}</fast_forward_only>
        <!-- If true, stash dirty changes before pull and pop after. Default: false -->
        <auto_stash>${auto_stash}</auto_stash>
    </safety>

    <logging>
        <!-- Master on/off switch -->
        <enabled>${enable_logging}</enabled>
        <!-- Directory for log files. Empty = stdout only -->
        <log_dir>${log_dir}</log_dir>
        <!-- Send log by email after each run. Requires MTA. -->
        <email_logs>${email_logs}</email_logs>
        <!-- Destination address for emailed logs. Empty = email disabled -->
        <log_email_address>${log_email_address}</log_email_address>
    </logging>

    <!-- Path to encrypted credential store. Empty = always prompt, never store -->
    <password_store>${password_store}</password_store>

</smart-git-sync>
EOF

  mv "$tmp" "$cfg_file"
  chmod 0600 "$cfg_file"
  fn_log_msg "Config written to: $cfg_file"
}

### Initialization ###

fn_detect_mode() {
  # Parse accounts (handle comma or space separation)
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"

  # Load existing credentials from file
  fn_load_all_credentials

  # Empty accounts = first-run, prompt for first account
  if [[ ${#account_array[@]} -eq 0 ]]; then
    mode="first-run"
    fn_log_msg "No accounts configured - first run setup"

    # If password_store is configured and no file yet, prompt for first account
    if [[ -n "$password_store" && ! -f "$password_store" ]]; then
      fn_setup_account_credentials
    fi

    return 0
  fi

  # Accounts configured - check credentials for each one
  for account in "${account_array[@]}"; do
    if [[ -z "${account_auth_method[$account]:-}" ]]; then
      # No stored credentials for this account
      fn_log_msg "No stored credentials for account: $account"

      if [[ ! -t 0 ]]; then
        fn_log_msg "ERROR: No credentials for '$account' and stdin is not a terminal"
        fn_log_msg "       Run interactively to set up: smart-git-sync.sh --add-account"
        continue
      fi

      if fn_prompt_and_validate_credential "$account"; then
        account="$CREDENTIAL_ACCOUNT"
        if [[ -n "$password_store" ]] && ! [[ -f "$password_store" && ! -s "$password_store" ]]; then
          local save_choice
          read -rp "Store logon credentials for $account? [Y/n]: " save_choice
          case "$save_choice" in
            [Nn]*) fn_log_msg "Credentials for $account not stored" ;;
            *)     fn_save_credentials ;;
          esac
        fi
      else
        fn_log_msg "Credential setup for $account cancelled - skipping"
      fi
    else
      # Credentials loaded -- verify they still work, re-prompt if not
      fn_verify_account_credentials "$account"
    fi
  done

  # Determine mode
  if [[ ${#account_array[@]} -eq 1 ]]; then
    mode="single-account"
    fn_log_msg "Mode: single-account (${account_array[0]})"
  else
    mode="multi-account"
    fn_log_msg "Mode: multi-account (${#account_array[@]} accounts)"
  fi
}

### First-run setup ###

fn_first_run_setup() {
  [[ -t 1 ]] && tput clear
  echo ""
  echo "========================================"
  echo "  smart-git-sync v${script_version}"
  echo "  First-run setup"
  echo "========================================"
  echo ""
  echo "No accounts configured. Let's get you set up."
  echo "You can re-run this at any time with --add-account."
  echo ""

  # --- github_root ---
  local default_root="$HOME/GitHub"
  local input_root
  read -rp "GitHub repos root directory [$default_root]: " input_root
  if [[ -z "$input_root" ]]; then
    github_root="$default_root"
  else
    github_root=$(fn_normalize_path "$input_root" "GitHub")
  fi
  echo "  -> github_root: $github_root"
  mkdir -p "$github_root"
  echo ""

  # --- Config file ---
  local default_cfg="$HOME/.config/smart-git-sync/config.cfg"
  local input_cfg
  echo "Save configuration to a file? (recommended - lets you drop in templates for teams)"
  read -rp "Config file path [$default_cfg] (Enter to use, 'no' to skip): " input_cfg
  if [[ "$input_cfg" == "no" || "$input_cfg" == "n" ]]; then
    cfg_path=""
    use_external_cfg=false
    echo "  -> No config file. Settings will use script defaults only."
  else
    if [[ -z "$input_cfg" ]]; then
      cfg_path="$default_cfg"
    else
      cfg_path=$(fn_normalize_path "$input_cfg" "config.cfg")
    fi
    use_external_cfg=true
    echo "  -> Config file: $cfg_path"
  fi
  echo ""

  # --- Password store ---
  if [[ "$use_external_cfg" == "true" ]]; then
    local default_store
    default_store="$(dirname "$cfg_path")/.credentials"
    local input_store
    echo "Store credentials in an encrypted file? (recommended for unattended use)"
    read -rp "Credential store path [$default_store] (Enter to use, 'no' for always-prompt): " input_store
    if [[ "$input_store" == "no" || "$input_store" == "n" ]]; then
      password_store=""
      echo "  -> Sentinel mode: credentials will be prompted every run."
    else
      if [[ -z "$input_store" ]]; then
        password_store="$default_store"
      else
        password_store=$(fn_normalize_path "$input_store" ".credentials")
      fi
      echo "  -> Credential store: $password_store"
    fi
    echo ""
  fi

  # --- First account ---
  echo "Now let's add your first GitHub account."
  echo ""
  if ! fn_setup_account_credentials; then
    echo ""
    echo "Account setup cancelled. Run again when ready."
    exit 1
  fi
  local first_account="$CREDENTIAL_ACCOUNT"
  accounts="$first_account"

  # Save credentials if store is configured
  if [[ -n "$password_store" ]]; then
    fn_save_credentials
  fi

  # --- Additional accounts ---
  echo ""
  while true; do
    local more
    read -rp "Add another GitHub account? [y/N]: " more
    [[ "$more" =~ ^[Yy]$ ]] || break
    echo ""
    if fn_setup_account_credentials; then
      local new_account="$CREDENTIAL_ACCOUNT"
      # Avoid duplicates
      if [[ " $accounts " != *" $new_account "* ]]; then
        accounts="$accounts $new_account"
        fn_log_msg "Account '$new_account' added"
        [[ -n "$password_store" ]] && fn_save_credentials
      else
        echo "  Account '$new_account' already in list - skipping."
      fi
    else
      echo "  Account setup cancelled."
    fi
    echo ""
  done

  # --- Determine mode ---
  local account_array
  IFS=' ' read -ra account_array <<< "$accounts"
  if [[ ${#account_array[@]} -eq 1 ]]; then
    mode="single-account"
  else
    mode="multi-account"
  fi

  # --- Write config ---
  if [[ "$use_external_cfg" == "true" ]]; then
    mkdir -p "$(dirname "$cfg_path")"
    fn_write_external_config
    echo ""
    echo "Configuration saved to: $cfg_path"
  fi

  # --- Summary ---
  echo ""
  echo "========================================"
  echo "  Setup complete!"
  echo "========================================"
  echo ""
  echo "  github_root: $github_root"
  echo "  Mode:        $mode"
  echo "  Accounts:    $accounts"
  [[ -n "$cfg_path" ]] && echo "  Config:      $cfg_path"
  [[ -n "$password_store" ]] && echo "  Credentials: $password_store"
  echo ""
  echo "Next steps:"
  echo "  - Clone your repos into $github_root"
  [[ "$mode" == "multi-account" ]] && echo "    (one subdirectory per account: $github_root/<account>/<repo>)"
  echo "  - Run:  smart-git-sync.sh --list-repos   to verify layout"
  echo "  - Run:  smart-git-sync.sh                to sync"
  echo ""
}



# Sync a single repo directory
# $1 = account name (used for credential lookup; empty = single-account mode)
# $2 = full path to repo directory
# Increments global counters directly
fn_sync_repo() {
  local account="$1"
  local repo_path="$2"
  local repo_name
  repo_name="$(basename "$repo_path")"

  # Must be a git repo
  if [[ ! -d "$repo_path/.git" ]]; then
    fn_log_msg "  SKIP $repo_name: not a git repo"
    (( repos_skipped++ )) || true
    return 0
  fi

  (( repos_total++ )) || true
  fn_log_msg "  --> $repo_name"

  # --- Branch awareness ---
  local current_branch
  current_branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null) || {
    fn_log_msg "  SKIP $repo_name: detached HEAD - not on any branch"
    (( repos_skipped++ )) || true
    return 0
  }

  # Check this branch has a remote tracking ref
  local tracking
  tracking=$(git -C "$repo_path" rev-parse --abbrev-ref "${current_branch}@{upstream}" 2>/dev/null) || {
    fn_log_msg "  SKIP $repo_name: branch '$current_branch' has no remote tracking ref"
    (( repos_skipped++ )) || true
    return 0
  }

  # Warn if not on default branch (main/master)
  if [[ "$current_branch" != "main" && "$current_branch" != "master" ]]; then
    fn_log_msg "  WARN $repo_name: on non-default branch '$current_branch' (tracking: $tracking)"
  fi

  # --- Dirty check ---
  local git_status
  git_status=$(git -C "$repo_path" status --porcelain 2>&1)

  if [[ -n "$git_status" ]]; then
    (( repos_dirty++ )) || true

    if [[ "$auto_stash" == "true" ]]; then
      fn_log_msg "  STSH $repo_name: stashing dirty changes before pull"
      if ! git -C "$repo_path" stash push --include-untracked -m "smart-git-sync auto-stash ${run_timestamp}" &>/dev/null; then
        fn_log_msg "  FAIL $repo_name: stash failed - skipping"
        (( repos_failed++ )) || true
        return 0
      fi
    elif [[ "$allow_dirty" == "true" ]]; then
      fn_log_msg "  WARN $repo_name: dirty (proceeding - allow_dirty=true)"
    else
      fn_log_msg "  SKIP $repo_name: dirty working tree (set allow_dirty=true or auto_stash=true to override)"
      (( repos_skipped++ )) || true
      return 0
    fi
  fi

  # --- Build remote URL with embedded auth (for token accounts) ---
  # SSH accounts use GIT_SSH_COMMAND; token accounts embed PAT in URL
  local git_env=()
  local remote_url=""
  if [[ -n "$account" ]]; then
    local auth_method="${account_auth_method[$account]:-}"
    if [[ "$auth_method" == "ssh" ]]; then
      local ssh_key="${account_ssh_key[$account]:-}"
      [[ -n "$ssh_key" ]] && git_env+=( "GIT_SSH_COMMAND=ssh -i $ssh_key -o IdentitiesOnly=yes" )
    elif [[ "$auth_method" == "token" ]]; then
      local token="${account_token[$account]:-}"
      if [[ -n "$token" ]]; then
        # Get the current remote URL and inject the PAT
        local base_url
        base_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null)
        if [[ "$base_url" =~ ^https://github.com/(.+) ]]; then
          remote_url="https://${token}@github.com/${BASH_REMATCH[1]}"
        fi
      fi
    fi
  fi

  # --- Fetch (no merge) -- establishes ground truth before deciding direction ---
  local fetch_output fetch_exit=0
  if [[ -n "$remote_url" ]]; then
    fetch_output=$(git -C "$repo_path" fetch origin --quiet 2>&1) || fetch_exit=$?
    # Re-run with auth URL if plain fetch fails
    if [[ $fetch_exit -ne 0 ]]; then
      fetch_output=$(git -C "$repo_path" fetch "$remote_url" --quiet 2>&1) || fetch_exit=$?
    fi
  elif [[ ${#git_env[@]} -gt 0 ]]; then
    fetch_output=$(env "${git_env[@]}" git -C "$repo_path" fetch origin --quiet 2>&1) || fetch_exit=$?
  else
    fetch_output=$(git -C "$repo_path" fetch origin --quiet 2>&1) || fetch_exit=$?
  fi

  if [[ $fetch_exit -ne 0 ]]; then
    fn_log_msg "  FAIL $repo_name: fetch failed: $fetch_output"
    # Check for auth failure -- offer credential rotation
    if echo "$fetch_output" | grep -qiE "authentication failed|could not read|403|401|invalid credentials|bad credentials"; then
      fn_rotate_account_credentials "$account" && \
        fn_log_msg "  INFO $repo_name: credentials updated - re-run to sync"
    fi
    (( repos_failed++ )) || true
    return 0
  fi

  # --- Determine sync direction ---
  local local_sha remote_sha merge_base
  local_sha=$(git  -C "$repo_path" rev-parse HEAD 2>/dev/null)
  remote_sha=$(git -C "$repo_path" rev-parse "${tracking}" 2>/dev/null)
  merge_base=$(git -C "$repo_path" merge-base HEAD "${tracking}" 2>/dev/null)

  local local_ahead=false remote_ahead=false
  [[ "$local_sha"  != "$merge_base" ]] && local_ahead=true
  [[ "$remote_sha" != "$merge_base" ]] && remote_ahead=true

  # --- Dry-run ---
  if [[ "$dry_run" == "true" ]]; then
    if [[ "$local_ahead" == "true" && "$remote_ahead" == "true" ]]; then
      fn_log_msg "  DRY  $repo_name: DIVERGED - would skip (manual resolve required)"
    elif [[ "$local_ahead" == "true" ]]; then
      fn_log_msg "  DRY  $repo_name: would PUSH branch '$current_branch'"
    elif [[ "$remote_ahead" == "true" ]]; then
      fn_log_msg "  DRY  $repo_name: would PULL branch '$current_branch' (ff-only=$fast_forward_only)"
    else
      fn_log_msg "  DRY  $repo_name: already in sync"
    fi
    return 0
  fi

  # --- Diverged: human must resolve ---
  if [[ "$local_ahead" == "true" && "$remote_ahead" == "true" ]]; then
    fn_log_msg "  SKIP $repo_name: DIVERGED - local and remote have both moved"
    fn_log_msg "       Resolve manually:"
    fn_log_msg "         cd $repo_path"
    fn_log_msg "         git log --oneline HEAD..${tracking}   # remote commits"
    fn_log_msg "         git log --oneline ${tracking}..HEAD   # your commits"
    fn_log_msg "         git rebase ${tracking}                # or: git merge ${tracking}"
    (( repos_skipped++ )) || true
    return 0
  fi

  # --- Already in sync ---
  if [[ "$local_ahead" == "false" && "$remote_ahead" == "false" ]]; then
    fn_log_msg "  OK   $repo_name: already in sync"
    return 0
  fi

  # --- Push: local is ahead ---
  if [[ "$local_ahead" == "true" ]]; then
    fn_log_msg "  PUSH $repo_name: branch '$current_branch'"
    local push_output push_exit=0
    if [[ -n "$remote_url" ]]; then
      push_output=$(git -C "$repo_path" push "$remote_url" "${current_branch}" 2>&1) || push_exit=$?
    elif [[ ${#git_env[@]} -gt 0 ]]; then
      push_output=$(env "${git_env[@]}" git -C "$repo_path" push origin "${current_branch}" 2>&1) || push_exit=$?
    else
      push_output=$(git -C "$repo_path" push origin "${current_branch}" 2>&1) || push_exit=$?
    fi
    if [[ $push_exit -ne 0 ]]; then
      fn_log_msg "  FAIL $repo_name: push failed: $push_output"
      if echo "$push_output" | grep -qiE "authentication failed|could not read|403|401|invalid credentials|bad credentials"; then
        fn_rotate_account_credentials "$account" && \
          fn_log_msg "  INFO $repo_name: credentials updated - re-run to sync"
      fi
      (( repos_failed++ )) || true
    else
      fn_log_msg "  OK   $repo_name: pushed"
      (( repos_updated++ )) || true
    fi
    return 0
  fi

  # --- Pull: remote is ahead ---
  fn_log_msg "  PULL $repo_name: branch '$current_branch'"
  local pull_flags=()
  [[ "$fast_forward_only" == "true" ]] && pull_flags+=( "--ff-only" )

  local pull_output pull_exit=0
  if [[ -n "$remote_url" ]]; then
    pull_output=$(git -C "$repo_path" merge "${pull_flags[@]}" "${tracking}" 2>&1) || pull_exit=$?
  elif [[ ${#git_env[@]} -gt 0 ]]; then
    pull_output=$(env "${git_env[@]}" git -C "$repo_path" merge "${pull_flags[@]}" "${tracking}" 2>&1) || pull_exit=$?
  else
    pull_output=$(git -C "$repo_path" merge "${pull_flags[@]}" "${tracking}" 2>&1) || pull_exit=$?
  fi

  if [[ $pull_exit -ne 0 ]]; then
    fn_log_msg "  FAIL $repo_name: merge failed: $pull_output"
    (( repos_failed++ )) || true
    if [[ "$auto_stash" == "true" && -n "$git_status" ]]; then
      fn_log_msg "  NOTE $repo_name: stash preserved - recover with: git -C $repo_path stash pop"
    fi
    return 0
  fi

  fn_log_msg "  OK   $repo_name: pulled"
  (( repos_updated++ )) || true

  # Pop stash if we pushed one earlier
  if [[ "$auto_stash" == "true" && -n "$git_status" ]]; then
    local pop_output pop_exit=0
    pop_output=$(git -C "$repo_path" stash pop 2>&1) || pop_exit=$?
    if [[ $pop_exit -ne 0 ]]; then
      fn_log_msg "  WARN $repo_name: stash pop failed (conflict?) - stash preserved"
      fn_log_msg "       Resolve manually: git -C $repo_path stash pop"
    else
      fn_log_msg "  OK   $repo_name: stash restored"
    fi
  fi
}

# Enumerate and sync repos for a single account
# Layout: $github_root/<repo>/
fn_process_repos_single_account() {
  fn_log_msg "Processing repos in: $github_root"

  if [[ ! -d "$github_root" ]]; then
    fn_log_msg "ERROR: github_root does not exist: $github_root"
    return 1
  fi

  local account=""
  # Single-account: pick up the one account name if set
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"
  [[ ${#account_array[@]} -eq 1 ]] && account="${account_array[0]}"

  local found=0
  for repo_path in "$github_root"/*/; do
    [[ -d "$repo_path" ]] || continue
    [[ -d "$repo_path/.git" ]] && (( found++ )) || true
    fn_sync_repo "$account" "$repo_path"
  done

  [[ $found -eq 0 ]] && fn_log_msg "No git repos found in $github_root"
}

# Enumerate and sync repos for multiple accounts
# Layout: $github_root/<account>/<repo>/
fn_process_repos_multi_account() {
  fn_log_msg "Processing repos in: $github_root (multi-account)"

  if [[ ! -d "$github_root" ]]; then
    fn_log_msg "ERROR: github_root does not exist: $github_root"
    return 1
  fi

  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"

  for account in "${account_array[@]}"; do
    local account_dir="$github_root/$account"
    fn_log_msg "Account: $account ($account_dir)"

    if [[ ! -d "$account_dir" ]]; then
      fn_log_msg "  SKIP: directory not found for account $account"
      continue
    fi

    local found=0
    for repo_path in "$account_dir"/*/; do
      [[ -d "$repo_path" ]] || continue
      [[ -d "$repo_path/.git" ]] && (( found++ )) || true
      fn_sync_repo "$account" "$repo_path"
    done

    [[ $found -eq 0 ]] && fn_log_msg "  No git repos found for account $account"
  done
}

fn_init_logging() {
  # Determine if we're logging to file
  if [[ "$enable_logging" == "true" && -n "$log_dir" ]]; then
    mkdir -p "$log_dir"
    log_file="$log_dir/smart-git-sync_${run_timestamp}.log"
    fn_log_msg "=== smart-git-sync v${script_version} started ==="
  elif [[ "$enable_logging" == "true" ]]; then
    fn_log_msg "Logging to stdout only (no file or email configured)"
  fi

  # Email preflight: warn early if email is wanted but can't be delivered
  if [[ "$email_logs" == "true" && -n "$log_email_address" ]]; then
    if ! command -v mail &>/dev/null; then
      fn_log_msg "WARNING: email_logs=true but 'mail' command not found - email will be skipped"
      fn_log_msg "         Install mailutils (Debian/Ubuntu) or mailx (RHEL/Fedora) to enable"
      email_logs="false"  # Disable to avoid silent failure at end of run
    elif [[ -z "$log_file" ]]; then
      fn_log_msg "WARNING: email_logs=true but log_dir is empty - no log file to send"
      fn_log_msg "         Set log_dir to enable email log delivery"
      email_logs="false"
    fi
  fi
}

fn_print_summary() {
  fn_log_msg "=== Summary ==="
  fn_log_msg "Total repos: $repos_total"
  fn_log_msg "Updated: $repos_updated"
  fn_log_msg "Dirty: $repos_dirty"
  fn_log_msg "Skipped: $repos_skipped"
  fn_log_msg "Failed: $repos_failed"
}

# Email the log file via system MTA (mail command)
# Called after fn_print_summary so the summary is included in the email
# No-op if email_logs != true, log_email_address empty, or log_file missing
fn_email_log() {
  [[ "$email_logs" != "true" ]] && return 0
  [[ -z "$log_email_address" ]] && return 0
  [[ -z "$log_file" || ! -f "$log_file" ]] && return 0
  [[ "$dry_run" == "true" ]] && { fn_log_msg "DRY RUN: would email log to $log_email_address"; return 0; }

  local subject="smart-git-sync: $run_timestamp"
  [[ $repos_failed -gt 0 ]] && subject="smart-git-sync FAILURES: $run_timestamp"

  if mail -s "$subject" "$log_email_address" < "$log_file"; then
    fn_log_msg "Log emailed to $log_email_address"
  else
    fn_log_msg "WARNING: Failed to email log to $log_email_address (mail exit code $?)"
  fi
}

fn_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --create-repo)
        [[ -z "${2:-}" ]] && { echo "ERROR: --create-repo requires a name"; exit 1; }
        create_repo_name="$2"
        shift 2
        ;;
      --add-account)
        manage_account_action="add"
        shift
        ;;
      --remove-account)
        manage_account_action="remove"
        shift
        ;;
      --account)
        [[ -z "${2:-}" ]] && { echo "ERROR: --account requires a value"; exit 1; }
        create_repo_account="$2"
        manage_account_name="$2"
        shift 2
        ;;
      --description)
        [[ -z "${2:-}" ]] && { echo "ERROR: --description requires a value"; exit 1; }
        create_repo_description="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --status)
        show_status=true
        shift
        ;;
      --list-repos)
        list_repos=true
        shift
        ;;
      --reset)
        reset_config=true
        shift
        ;;
      --clone-missing)
        clone_missing=true
        shift
        ;;
      --version|-V)
        echo "smart-git-sync v${script_version} (${script_released})"
        exit 0
        ;;
      --help|-h)
        fn_print_usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown argument: $1"
        fn_print_usage
        exit 1
        ;;
    esac
  done
}

fn_print_usage() {
  cat << USAGE
smart-git-sync v${script_version} (${script_released})

Usage: smart-git-sync.sh [OPTIONS]

Options:
  (no args)                     Sync all configured repos
  --create-repo <name>          Create a new GitHub repo and clone it locally
  --add-account                 Add a new GitHub account and credentials
  --remove-account              Remove a GitHub account and its credentials
  --account <name>              Account name (for --create-repo or --remove-account)
  --description <text>          Repo description for --create-repo
  --dry-run                     Show what would happen, make no changes
  --status                      Show current configuration and repo counts
  --list-repos                  List repos that would be synced, no git operations
  --clone-missing               Clone repos on GitHub not yet present locally (requires PAT)
  --reset                       Remove config and credential files (accounts must be removed first)
  --version, -V                 Print version and exit
  --help                        Show this message
USAGE
}

### Clone missing ###

# Fetch list of repos from GitHub API for one account, clone any not present locally
# $1 = account name
# $2 = local directory to clone into (github_root or github_root/account)
fn_clone_missing_for_account() {
  local account="$1"
  local local_dir="$2"

  # Requires PAT -- API is not available over SSH
  local auth_method="${account_auth_method[$account]:-}"
  if [[ "$auth_method" != "token" ]]; then
    fn_log_msg "  SKIP $account: --clone-missing requires a PAT (account uses SSH)"
    echo "       Add a PAT for '$account' via --add-account to use --clone-missing"
    return 0
  fi

  local pat="${account_token[$account]:-}"
  if [[ -z "$pat" ]]; then
    fn_log_msg "  SKIP $account: no PAT found"
    return 0
  fi

  fn_log_msg "Fetching repo list for $account from GitHub API..."

  # Paginate: GitHub returns max 100 per page
  local page=1
  local remote_repos=()
  while true; do
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: token $pat" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/user/repos?per_page=100&page=${page}&affiliation=owner") || {
        fn_log_msg "  FAIL $account: curl error fetching repo list"
        return 1
      }
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n -1)

    if [[ "$http_code" != "200" ]]; then
      local msg
      msg=$(echo "$body" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
      fn_log_msg "  FAIL $account: GitHub API returned HTTP $http_code: ${msg:-unknown}"
      return 1
    fi

    # Extract repo names at top-level array depth
    # GitHub formats each repo's "name" field at 4-space indent -- reliable anchor
    local page_repos=()
    while IFS= read -r repo_name; do
      [[ -n "$repo_name" ]] && page_repos+=( "$repo_name" )
    done < <(echo "$body" | grep -E '^    "name":' | cut -d'"' -f4)

    [[ ${#page_repos[@]} -eq 0 ]] && break
    remote_repos+=( "${page_repos[@]}" )
    [[ ${#page_repos[@]} -lt 100 ]] && break
    (( page++ )) || true
  done

  fn_log_msg "  Found ${#remote_repos[@]} repo(s) on GitHub for $account"

  # Compare against local
  local cloned=0 already=0 failed=0
  mkdir -p "$local_dir"

  for repo_name in "${remote_repos[@]}"; do
    local repo_path="$local_dir/$repo_name"
    if [[ -d "$repo_path/.git" ]]; then
      (( already++ )) || true
      continue
    fi

    fn_log_msg "  CLONE $repo_name -> $repo_path"
    if [[ "$dry_run" == "true" ]]; then
      fn_log_msg "  DRY   would clone $account/$repo_name"
      continue
    fi

    local clone_url="https://${pat}@github.com/$account/$repo_name.git"
    local clone_out clone_exit=0
    clone_out=$(git clone "$clone_url" "$repo_path" 2>&1) || clone_exit=$?

    if [[ $clone_exit -ne 0 ]]; then
      fn_log_msg "  FAIL $repo_name: $clone_out"
      (( failed++ )) || true
    else
      fn_log_msg "  OK   $repo_name: cloned"
      (( cloned++ )) || true
    fi
  done

  fn_log_msg "  $account: $cloned cloned, $already already present, $failed failed"
}

# Entry point for --clone-missing: dispatches per account
fn_clone_missing() {
  fn_log_msg "=== Clone missing repos ==="
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"

  if [[ "$mode" == "single-account" ]]; then
    fn_clone_missing_for_account "${account_array[0]}" "$github_root"
  elif [[ "$mode" == "multi-account" ]]; then
    for account in "${account_array[@]}"; do
      fn_clone_missing_for_account "$account" "$github_root/$account"
    done
  else
    echo "No accounts configured. Run setup first."
    return 1
  fi
}

### Status ###

# Remove config file and credential store
# Refuses if accounts are still configured or credential store is non-empty
fn_reset_config() {
  echo ""
  echo "=== smart-git-sync reset ==="
  echo ""

  # --- Safety gate 1: accounts still configured ---
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"
  if [[ ${#account_array[@]} -gt 0 ]]; then
    echo "ERROR: Cannot reset while accounts are still configured."
    echo ""
    echo "Remove all accounts first:"
    for a in "${account_array[@]}"; do
      echo "  smart-git-sync.sh --remove-account --account $a"
    done
    echo ""
    echo "Or edit the accounts= line in the script / config file directly,"
    echo "then remove the credential store manually:"
    [[ -n "$password_store" ]] && echo "  rm $password_store"
    echo ""
    return 1
  fi

  # --- Safety gate 2: credential store still has content ---
  if [[ -n "$password_store" && -f "$password_store" && -s "$password_store" ]]; then
    echo "ERROR: Credential store still exists and is non-empty: $password_store"
    echo ""
    echo "Remove all accounts first to clear it:"
    echo "  smart-git-sync.sh --remove-account --account <name>"
    echo ""
    echo "Or remove it manually:"
    echo "  rm $password_store"
    echo ""
    return 1
  fi

  # --- Nothing to remove? ---
  local has_cfg=false
  local has_store=false
  [[ -n "$cfg_path" && -f "$cfg_path" ]] && has_cfg=true
  [[ -n "$password_store" && -f "$password_store" ]] && has_store=true

  if [[ "$has_cfg" == "false" && "$has_store" == "false" ]]; then
    echo "Nothing to reset."
    echo "  Config file:      ${cfg_path:-not set}"
    echo "  Credential store: ${password_store:-not set}"
    echo ""
    return 0
  fi

  # --- Show what will be removed ---
  echo "The following files will be permanently deleted:"
  echo ""
  [[ "$has_cfg" == "true" ]]   && echo "  Config file:      $cfg_path"
  [[ "$has_store" == "true" ]] && echo "  Credential store: $password_store"
  echo ""
  echo "Your repos in ${github_root:-github_root} are NOT affected."
  echo ""

  local confirm
  read -rp "Type 'yes' to confirm reset: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    return 1
  fi

  # --- Remove ---
  local removed=0
  if [[ "$has_cfg" == "true" ]]; then
    rm -f "$cfg_path"
    fn_log_msg "Removed config file: $cfg_path"
    (( removed++ )) || true
  fi
  if [[ "$has_store" == "true" ]]; then
    rm -f "$password_store"
    fn_log_msg "Removed credential store: $password_store"
    (( removed++ )) || true
  fi

  echo ""
  echo "Reset complete. $removed file(s) removed."
  echo "Run smart-git-sync.sh with no arguments to start the setup wizard."
  echo ""
}

# List repos that would be synced -- pure filesystem scan, no git operations
# Single-account: $github_root/*/  Multi-account: $github_root/<account>/*/
fn_list_repos() {
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"
  local total=0

  echo ""
  echo "Repos that would be synced:"
  echo ""

  if [[ "$mode" == "single-account" ]]; then
    local account="${account_array[0]:-}"
    if [[ ! -d "$github_root" ]]; then
      echo "  ERROR: github_root not found: $github_root"
      return 1
    fi
    for repo_path in "$github_root"/*/; do
      [[ -d "$repo_path" ]] || continue
      local repo_name
      repo_name="$(basename "$repo_path")"
      if [[ -d "$repo_path/.git" ]]; then
        # Show current branch if we can get it cheaply (just reads .git/HEAD, no network)
        local branch=""
        local head_file="$repo_path/.git/HEAD"
        if [[ -f "$head_file" ]]; then
          local head_content
          head_content=$(cat "$head_file")
          if [[ "$head_content" =~ ref:\ refs/heads/(.+) ]]; then
            branch="${BASH_REMATCH[1]}"
          else
            branch="(detached HEAD)"
          fi
        fi
        printf "  %-40s  [%s]\n" "$repo_name" "$branch"
        (( total++ )) || true
      else
        printf "  %-40s  (not a git repo - would be skipped)\n" "$repo_name"
      fi
    done

  elif [[ "$mode" == "multi-account" ]]; then
    for account in "${account_array[@]}"; do
      local account_dir="$github_root/$account"
      echo "  $account/"
      if [[ ! -d "$account_dir" ]]; then
        echo "    (directory not found - account would be skipped)"
        continue
      fi
      local found=false
      for repo_path in "$account_dir"/*/; do
        [[ -d "$repo_path" ]] || continue
        local repo_name
        repo_name="$(basename "$repo_path")"
        if [[ -d "$repo_path/.git" ]]; then
          local branch=""
          local head_file="$repo_path/.git/HEAD"
          if [[ -f "$head_file" ]]; then
            local head_content
            head_content=$(cat "$head_file")
            if [[ "$head_content" =~ ref:\ refs/heads/(.+) ]]; then
              branch="${BASH_REMATCH[1]}"
            else
              branch="(detached HEAD)"
            fi
          fi
          printf "    %-38s  [%s]\n" "$repo_name" "$branch"
          (( total++ )) || true
          found=true
        else
          printf "    %-38s  (not a git repo - would be skipped)\n" "$repo_name"
          found=true
        fi
      done
      [[ "$found" == "false" ]] && echo "    (no subdirectories found)"
      echo ""
    done

  else
    echo "  No accounts configured."
    return 0
  fi

  echo ""
  echo "Total: $total repo(s) would be synced"
  echo ""
}

fn_print_status() {
  echo ""
  echo "smart-git-sync v${script_version} -- status"
  echo "----------------------------------------"
  echo "Mode:         $mode"
  echo "github_root:  $github_root"
  echo "Config file:  ${cfg_path:-not set (using script defaults)}"
  echo "Password store: ${password_store:-not set (always prompt)}"
  echo "Log dir:      ${log_dir:-stdout only}"
  echo "Email logs:   $email_logs${log_email_address:+ -> $log_email_address}"
  echo "allow_dirty:  $allow_dirty"
  echo "ff_only:      $fast_forward_only"
  echo "dry_run:      $dry_run"
  echo ""

  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"

  if [[ ${#account_array[@]} -eq 0 ]]; then
    echo "Accounts:     none configured"
  else
    echo "Accounts:"
    for account in "${account_array[@]}"; do
      local auth="${account_auth_method[$account]:-unknown}"
      local cred_detail=""
      if [[ "$auth" == "ssh" ]]; then
        cred_detail="key: ${account_ssh_key[$account]:-not set}"
      elif [[ "$auth" == "token" ]]; then
        local tok="${account_token[$account]:-}"
        if [[ -n "$tok" ]]; then
          cred_detail="token: ${tok:0:8}..."
        else
          cred_detail="token: not set"
        fi
      fi

      # Count repos
      local repo_count=0
      local repo_dir
      if [[ "$mode" == "single-account" ]]; then
        repo_dir="$github_root"
      else
        repo_dir="$github_root/$account"
      fi
      if [[ -d "$repo_dir" ]]; then
        for d in "$repo_dir"/*/; do
          [[ -d "$d/.git" ]] && (( repo_count++ )) || true
        done
      fi

      printf "  %-20s  %-8s  %-30s  %d repo(s)\n" \
        "$account" "$auth" "$cred_detail" "$repo_count"
    done
  fi
  echo ""
}

### Account management ###

# Add a new account: prompt for credentials, validate, save, update accounts list
fn_add_account() {
  echo ""
  echo "=== Add GitHub Account ==="

  # fn_setup_account_credentials prompts for name + credential, validates, offers to save
  if ! fn_setup_account_credentials; then
    echo "Add account cancelled."
    return 1
  fi

  # CREDENTIAL_ACCOUNT is set by fn_prompt_and_validate_credential (via fn_setup_account_credentials)
  local new_account="$CREDENTIAL_ACCOUNT"

  # Add to accounts list if not already present
  local already=false
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"
  for a in "${account_array[@]}"; do
    [[ "$a" == "$new_account" ]] && already=true && break
  done

  if [[ "$already" == "false" ]]; then
    if [[ -z "$accounts" ]]; then
      accounts="$new_account"
    else
      accounts="$accounts $new_account"
    fi
    fn_log_msg "Account '$new_account' added to accounts list"
  else
    fn_log_msg "Account '$new_account' already in accounts list (credentials updated)"
  fi

  # Persist updated accounts list to config if using external config
  if [[ "$use_external_cfg" == "true" ]]; then
    fn_write_external_config
    fn_log_msg "Config updated: $cfg_path"
  else
    echo ""
    echo "NOTE: accounts list updated in memory only."
    echo "      Set cfg_path and run again to persist to config file,"
    echo "      or add '$new_account' to the accounts= var in the script."
  fi

  echo ""
  echo "Account '$new_account' added."
}

# Remove an account: confirm, unset from arrays, remove from accounts list, save
fn_remove_account() {
  local target="$1"

  # Load existing accounts
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"

  if [[ ${#account_array[@]} -eq 0 ]]; then
    echo "No accounts configured."
    return 1
  fi

  # If no account name supplied, prompt
  if [[ -z "$target" ]]; then
    echo ""
    echo "=== Remove GitHub Account ==="
    echo "Configured accounts:"
    local i=1
    for a in "${account_array[@]}"; do
      echo "  $i) $a"
      (( i++ )) || true
    done
    echo ""
    local choice
    read -rp "Account number or name to remove: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#account_array[@]} )); then
      target="${account_array[$((choice-1))]}"
    else
      target="$choice"
    fi
  fi

  # Validate target is in the list
  local found=false
  for a in "${account_array[@]}"; do
    [[ "$a" == "$target" ]] && found=true && break
  done
  if [[ "$found" == "false" ]]; then
    echo "ERROR: Account '$target' not found in configured accounts"
    return 1
  fi

  # Confirmation
  echo ""
  echo "  About to remove account: $target"
  echo "  This will delete stored credentials for this account."
  echo ""
  local confirm
  read -rp "Confirm? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }

  # Unset from credential arrays
  unset "account_auth_method[$target]"
  unset "account_token[$target]"
  unset "account_ssh_key[$target]"

  # Remove from accounts list
  local new_accounts=()
  for a in "${account_array[@]}"; do
    [[ "$a" != "$target" ]] && new_accounts+=( "$a" )
  done
  accounts="${new_accounts[*]}"

  # Save updated credentials file
  if [[ -n "$password_store" ]]; then
    fn_save_credentials
  fi

  # Persist updated accounts list to config if using external config
  if [[ "$use_external_cfg" == "true" ]]; then
    fn_write_external_config
    fn_log_msg "Config updated: $cfg_path"
  else
    echo ""
    echo "NOTE: accounts list updated in memory only."
    echo "      Set cfg_path and run again to persist to config file,"
    echo "      or remove '$target' from the accounts= var in the script."
  fi

  echo ""
  echo "Account '$target' removed."
}

### Repo creation ###

# Create a new repo on GitHub via REST API, then clone it locally
# Requires a PAT with repo scope (SSH-only accounts cannot create repos)
fn_create_repo() {
  local repo_name="$1"
  local account="$2"
  local description="$3"

  # --- Resolve account ---
  local account_array
  IFS=', ' read -ra account_array <<< "$accounts"

  if [[ "$mode" == "single-account" ]]; then
    # Ignore --account in single-account mode
    account="${account_array[0]}"
    fn_log_msg "Single-account mode: using account $account"
  elif [[ "$mode" == "multi-account" ]]; then
    if [[ -z "$account" ]]; then
      echo ""
      echo "Multiple accounts configured. Which account should own this repo?"
      local i=1
      for a in "${account_array[@]}"; do
        echo "  $i) $a"
        (( i++ )) || true
      done
      echo ""
      local choice
      read -rp "Account number or name: " choice
      # Accept number or name
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#account_array[@]} )); then
        account="${account_array[$((choice-1))]}"
      else
        account="$choice"
      fi
    fi
  else
    echo "ERROR: No accounts configured. Run without --create-repo first to set up."
    return 1
  fi

  # Validate account is in the configured list
  local valid=false
  for a in "${account_array[@]}"; do
    [[ "$a" == "$account" ]] && valid=true && break
  done
  if [[ "$valid" == "false" ]]; then
    echo "ERROR: Account '$account' not in configured accounts list"
    return 1
  fi

  # --- PAT check: repo creation requires token auth ---
  local auth_method="${account_auth_method[$account]:-}"
  if [[ "$auth_method" != "token" ]]; then
    echo ""
    echo "ERROR: Repo creation requires a Personal Access Token with 'repo' scope."
    echo "       Account '$account' is configured with SSH key authentication."
    echo "       Add a PAT for this account to use --create-repo."
    return 1
  fi
  local pat="${account_token[$account]:-}"
  if [[ -z "$pat" ]]; then
    echo "ERROR: No PAT found for account '$account'"
    return 1
  fi

  # Fine-grained PATs need Administration: write to create repos
  # Classic PATs need repo scope
  # We can't check this upfront -- the API will 403 with a clear message if missing

  # --- Prompt for description if not supplied ---
  if [[ -z "$description" ]]; then
    read -rp "Repo description (Enter to skip): " description
  fi

  # --- Prompt for visibility ---
  echo ""
  local visibility_choice
  while true; do
    read -rp "Visibility [public/private]: " visibility_choice
    case "$visibility_choice" in
      public|private) break ;;
      *) echo "  Please enter 'public' or 'private'" ;;
    esac
  done
  create_repo_visibility="$visibility_choice"
  local is_private="false"
  [[ "$create_repo_visibility" == "private" ]] && is_private="true"

  # --- Determine clone destination ---
  local clone_dest
  if [[ "$mode" == "single-account" ]]; then
    clone_dest="$github_root/$repo_name"
  else
    clone_dest="$github_root/$account/$repo_name"
  fi

  # --- Confirmation ---
  echo ""
  echo "  About to create:"
  echo "    Repo:        $account/$repo_name"
  echo "    Visibility:  $create_repo_visibility"
  [[ -n "$description" ]] && echo "    Description: $description"
  echo "    Clone to:    $clone_dest"
  echo ""
  if [[ "$dry_run" == "true" ]]; then
    fn_log_msg "DRY RUN: would create $account/$repo_name ($create_repo_visibility) and clone to $clone_dest"
    return 0
  fi
  local confirm
  read -rp "Confirm? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; return 1; }

  # --- API call: create repo ---
  fn_log_msg "Creating repo $account/$repo_name on GitHub..."

  local payload
  payload=$(printf '{"name":"%s","description":"%s","private":%s,"auto_init":false}' \
    "$repo_name" "$description" "$is_private")

  local api_response
  local api_http_code
  api_response=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Authorization: token $pat" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.github.com/user/repos") || {
      echo "ERROR: curl failed - check network connectivity"
      return 1
    }

  api_http_code=$(echo "$api_response" | tail -n1)
  local api_body
  api_body=$(echo "$api_response" | head -n -1)

  if [[ "$api_http_code" != "201" ]]; then
    local api_message
    api_message=$(echo "$api_body" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
    echo "ERROR: GitHub API returned HTTP $api_http_code: ${api_message:-unknown error}"
    if [[ "$api_http_code" == "403" || "$api_http_code" == "422" ]]; then
      echo ""
      echo "For fine-grained PATs: requires 'Administration: write' permission"
      echo "For classic PATs: requires 'repo' scope"
      echo "Update your PAT at: https://github.com/settings/tokens"
    fi
    fn_log_msg "Repo creation failed: HTTP $api_http_code ${api_message:-}"
    return 1
  fi

  fn_log_msg "Repo created: $account/$repo_name ($create_repo_visibility)"

  # --- Clone ---
  # Embed PAT in URL -- works for both classic and fine-grained PATs
  local clone_url="https://${pat}@github.com/$account/$repo_name.git"
  fn_log_msg "Cloning $account/$repo_name -> $clone_dest"

  mkdir -p "$(dirname "$clone_dest")"

  local clone_output
  local clone_exit=0
  clone_output=$(git clone "$clone_url" "$clone_dest" 2>&1) || clone_exit=$?

  if [[ $clone_exit -ne 0 ]]; then
    echo "ERROR: Clone failed: $clone_output"
    fn_log_msg "Clone failed for $repo_name: $clone_output"
    return 1
  fi

  fn_log_msg "Cloned to: $clone_dest"
  echo ""
  echo "Done. $account/$repo_name created and cloned to $clone_dest"
}

### Entry point ###

# Parse CLI args
fn_parse_args "$@"

# Initialize
fn_init_logging

[[ "$dry_run" == "true" ]] && fn_log_msg "=== DRY RUN - no changes will be made ==="

# Load external config if specified
if [[ -n "$cfg_path" ]]; then
  use_external_cfg=true
  cfg_path=$(fn_normalize_path "$cfg_path" "smart-git-sync.cfg")
  fn_log_msg "Using external config: $cfg_path"
  fn_load_external_config
fi

# Detect mode (loads credentials for each account)
fn_detect_mode

# --clone-missing: fetch GitHub repo list and clone anything not local
if [[ "$clone_missing" == "true" ]]; then
  fn_clone_missing
  exit $?
fi

# --reset: must run after config load but before anything that touches credentials
if [[ "$reset_config" == "true" ]]; then
  fn_reset_config
  exit $?
fi

# --status: show config and exit
if [[ "$show_status" == "true" ]]; then
  fn_print_status
  exit 0
fi

# --list-repos: filesystem scan only, no git operations
if [[ "$list_repos" == "true" ]]; then
  fn_list_repos
  exit 0
fi

# --add-account / --remove-account: branch off, skip normal sync
if [[ "$manage_account_action" == "add" ]]; then
  fn_add_account
  exit $?
fi

if [[ "$manage_account_action" == "remove" ]]; then
  fn_remove_account "$manage_account_name"
  exit $?
fi

# --create-repo: branch off, skip normal sync
if [[ -n "$create_repo_name" ]]; then
  fn_create_repo "$create_repo_name" "$create_repo_account" "$create_repo_description"
  exit $?
fi

# Normal sync
if [[ "$mode" == "single-account" ]]; then
  fn_process_repos_single_account
elif [[ "$mode" == "multi-account" ]]; then
  fn_process_repos_multi_account
elif [[ "$mode" == "first-run" ]]; then
  fn_first_run_setup
  exit 0
fi

# Print summary
fn_print_summary

# Email log if configured
fn_email_log

### smart-git-sync.sh ends ###
