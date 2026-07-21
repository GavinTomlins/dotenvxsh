#!/usr/bin/env bash
#
# dotenvxsh — small TUI helper for adding secrets to dotenvx-encrypted .env files.
#
# Usage: ./dotenvxsh.sh [--no-echo] [env-file]
#   With no argument, a picker offers ./.env (local) or the global credentials
#   file — ~/.config/credentials/credentials.env by default, overridable via
#   the DOTENVXSH_CREDENTIALS_FILE environment variable.
#
# Secret display (issue #4 — keep secrets out of terminal scrollback):
#   DOTENVXSH_ECHO_SECRETS=always|masked|never   (default: masked)
#     always — print decrypted values inline, in plaintext
#     masked — round-trip checks print a masked value; Show reveals happen on
#              the terminal's alternate screen and never enter scrollback
#     never  — round-trip checks print only a verified/mismatch result;
#              Show reveals still use the alternate screen
#   --no-echo is shorthand for DOTENVXSH_ECHO_SECRETS=never.
#
# Flow per secret:
#   1. Check the key does not already exist in the file.
#   2. Ensure the file is fully encrypted (dotenvx encrypt).
#   3. Back up the encrypted state (git commit if in a repo, else a .bak copy).
#   4. Append KEY="value" to the end of the file.
#   5. Re-run dotenvx encrypt so the new value is encrypted.

set -euo pipefail

VERSION="0.1.0"

ENV_FILE=""
ECHO_SECRETS="${DOTENVXSH_ECHO_SECRETS:-masked}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)
      printf 'dotenvxsh %s\n' "$VERSION"
      exit 0
      ;;
    --no-echo)
      ECHO_SECRETS="never"
      shift
      ;;
    *)
      ENV_FILE="$1"
      shift
      ;;
  esac
done

case "$ECHO_SECRETS" in
  always|masked|never) ;;
  *)
    printf 'dotenvxsh: invalid DOTENVXSH_ECHO_SECRETS=%s (use always, masked, or never)\n' "$ECHO_SECRETS" >&2
    exit 1
    ;;
esac

CREDENTIALS_FILE="${DOTENVXSH_CREDENTIALS_FILE:-${HOME}/.config/credentials/credentials.env}"

BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
CYAN=$'\033[36m'
RESET=$'\033[0m'

KEY_ICON="🔑"
USER_ICON="👤"
VAULT_ICON="🔐"
EDIT_ICON="✏️ "
SHOW_ICON="🔍"
LOCK_ICON="🔒"
UNLOCK_ICON="🔓"

info()  { printf '%s\n' "${CYAN}==>${RESET} $*"; }
ok()    { printf '%s\n' "${GREEN} ✔${RESET} $*"; }
warn()  { printf '%s\n' "${YELLOW} !${RESET} $*" >&2; }
error() { printf '%s\n' "${RED} ✖${RESET} $*" >&2; }

require_dotenvx() {
  if ! command -v dotenvx >/dev/null 2>&1; then
    error "dotenvx not found on PATH. Install it first (brew install dotenvx/brew/dotenvx)."
    exit 1
  fi
}

# Uppercase and replace anything that isn't A-Z0-9_ with _
sanitize_name() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9_]/_/g; s/^_+//; s/_+$//'
}

key_exists() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] && grep -qE "^(export[[:space:]]+)?${key}=" "$ENV_FILE"
}

# Escape backslashes and double quotes so the value survives double-quoting
escape_value() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

encrypt_file() {
  dotenvx encrypt -f "$ENV_FILE" >/dev/null
}

# Mask a secret for display: first 4 and last 2 characters, or all-stars for
# short values.
mask_value() {
  local v="$1"
  if (( ${#v} <= 6 )); then
    printf '******'
  else
    printf '%s…%s' "${v:0:4}" "${v: -2}"
  fi
}

# Round-trip verification after a write: decrypt the key with `dotenvx get`
# and compare it to the value that was entered. How much of the value is
# echoed back depends on ECHO_SECRETS (issue #4 — scrollback hygiene).
verify_value() {
  local icon="$1" key="$2" expected="$3" actual
  if ! actual="$(dotenvx get "$key" -f "$ENV_FILE" 2>/dev/null)"; then
    warn "Could not decrypt ${key} for verification (is .env.keys present?)"
    return 0
  fi
  if [[ "$actual" != "$expected" ]]; then
    error "${key} decrypted value does NOT match what was entered!"
    return 0
  fi
  case "$ECHO_SECRETS" in
    always) printf '%s\n' "  ${icon} ${BOLD}${key}${RESET} = ${actual} ${GREEN}✔${RESET}" ;;
    masked) printf '%s\n' "  ${icon} ${BOLD}${key}${RESET} = $(mask_value "$actual") ${GREEN}✔ verified${RESET}" ;;
    never)  ok "${key} stored and verified (value not shown)" ;;
  esac
}

# Reveal secrets on the terminal's alternate screen buffer (the mechanism
# less/vim use). Content drawn there never enters the primary buffer's
# scrollback and disappears completely when the screen is restored.
# Args: pre-formatted display lines.
reveal_secrets() {
  local line
  if ! tput smcup 2>/dev/null; then
    # No alternate screen available (dumb terminal) — fall back to inline
    warn "Terminal has no alternate screen — values will appear in scrollback."
    for line in "$@"; do printf '%s\n' "$line"; done
    return 0
  fi
  clear
  printf '%s\n\n' "${VAULT_ICON} ${BOLD}dotenvxsh — secret reveal${RESET} ${DIM}(this screen is not kept in scrollback)${RESET}"
  for line in "$@"; do printf '%s\n' "$line"; done
  printf '\n%s' "${DIM}Press any key to hide…${RESET}"
  read -rsn1 </dev/tty || true
  tput rmcup
  ok "Revealed on the alternate screen — nothing retained in scrollback."
}

# Display one decrypted key, honouring ECHO_SECRETS. Used by the Show options;
# `always` prints inline like before, otherwise the reveal happens on the
# alternate screen via the caller batching lines with format_secret_line.
format_secret_line() {
  local icon="$1" key="$2" value
  if value="$(dotenvx get "$key" -f "$ENV_FILE" 2>/dev/null)"; then
    printf '%s' "  ${icon} ${BOLD}${key}${RESET} = ${value}"
  else
    printf '%s' "  ${icon} ${BOLD}${key}${RESET} = ${RED}<could not decrypt — is .env.keys present?>${RESET}"
  fi
}

backup_file() {
  # Run git relative to the env file's directory, not the CWD, so files like
  # ~/.config/credentials/credentials.env back up into their own repo.
  local env_dir env_base
  env_dir="$(cd "$(dirname "$ENV_FILE")" && pwd)"
  env_base="$(basename "$ENV_FILE")"
  if git -C "$env_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$env_dir" add -- "$env_dir/$env_base"
    if git -C "$env_dir" diff --cached --quiet -- "$env_dir/$env_base" \
       && git -C "$env_dir" ls-files --error-unmatch -- "$env_dir/$env_base" >/dev/null 2>&1; then
      ok "Backup: ${ENV_FILE} already committed and unchanged"
    else
      git -C "$env_dir" commit --quiet -o -m "chore: Backup ${env_base} before adding secrets

Automated pre-change snapshot taken by dotenvxsh with ${env_base} in a fully encrypted state.

Changelog: other" -- "$env_dir/$env_base"
      ok "Backup: committed encrypted ${ENV_FILE} ($(git -C "$env_dir" rev-parse --short HEAD))"
    fi
  else
    local bak
    bak="${ENV_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp "$ENV_FILE" "$bak"
    warn "Not a git repo — copied backup to ${bak}"
  fi
}

# Ensure file exists, is encrypted, and is backed up. Run once before appending.
prepare_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    warn "${ENV_FILE} does not exist — creating it"
    touch "$ENV_FILE"
  fi
  info "Ensuring ${ENV_FILE} is encrypted"
  encrypt_file
  backup_file
}

append_secret() {
  local key="$1" value="$2"
  # Make sure the file ends with a newline before appending
  if [[ -s "$ENV_FILE" ]] && [[ "$(tail -c 1 "$ENV_FILE")" != "" ]]; then
    printf '\n' >> "$ENV_FILE"
  fi
  printf '%s="%s"\n' "$key" "$(escape_value "$value")" >> "$ENV_FILE"
}

prompt_secret() {
  # prompt_secret <prompt text> -> echoes value, refuses empty
  local prompt="$1" value
  while true; do
    read -rs -p "${BOLD}${prompt}${RESET}: " value </dev/tty
    printf '\n' >&2
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return
    fi
    error "Value cannot be empty."
  done
}

prompt_name() {
  # prompt_name <prompt text> -> echoes sanitized name, refuses empty
  local prompt="$1" raw name
  while true; do
    read -r -p "${BOLD}${prompt}${RESET}: " raw </dev/tty
    name="$(sanitize_name "$raw")"
    if [[ -n "$name" ]]; then
      printf '%s' "$name"
      return
    fi
    error "Name cannot be empty (letters, numbers and underscores are kept)."
  done
}

# List keys in the env file matching <filter_regex> whose name contains <term>
# (case-insensitive). One key per line, deduplicated; empty when nothing matches.
find_matching_keys() {
  local term="$1" filter="$2"
  [[ -f "$ENV_FILE" ]] || return 0
  grep -oE '^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" \
    | sed -E 's/^export[[:space:]]+//; s/=$//' \
    | grep -E -- "$filter" | grep -i -- "$term" | awk '!seen[$0]++' || true
}

# Present matches as a numbered picker with a cancel option.
# Echoes the chosen key, or nothing on cancel. Menu output goes to stderr so it
# is visible even inside command substitution.
choose_match() {
  local matches=("$@") choice i key
  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s' "${matches[0]}"
    return
  fi
  {
    printf '\n%s\n' "${BOLD}Multiple matches found:${RESET}"
    i=1
    for key in "${matches[@]}"; do
      printf '%s\n' "  ${BOLD}${i}${RESET}) ${key}"
      i=$((i + 1))
    done
    printf '%s\n' "  ${BOLD}c${RESET}) Cancel"
  } >&2
  while true; do
    read -r -p "${BOLD}Choose [1-${#matches[@]}/c]${RESET}: " choice </dev/tty
    case "$choice" in
      c|C) return ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
          printf '%s' "${matches[$((choice - 1))]}"
          return
        fi
        error "Invalid choice: ${choice}"
        ;;
    esac
  done
}

# Prompt for a search term, find keys ending <suffix>, let the user pick one.
# Echoes the chosen key on stdout; returns 1 on cancel or no match.
# All UI goes to stderr so this works inside command substitution.
search_and_pick() {
  local icon="$1" suffix="$2" label="$3" verb="$4"
  local term matches_str key matches=()

  if [[ ! -f "$ENV_FILE" ]]; then
    error "${ENV_FILE} does not exist."
    return 1
  fi

  read -r -p "${BOLD}${icon} ${label} to ${verb} (search, empty to cancel)${RESET}: " term </dev/tty
  if [[ -z "$term" ]]; then
    warn "Cancelled."
    return 1
  fi

  matches_str="$(find_matching_keys "$term" "${suffix}\$")"
  if [[ -z "$matches_str" ]]; then
    error "No keys ending ${suffix} match '${term}' in ${ENV_FILE}."
    return 1
  fi
  while IFS= read -r key; do matches+=("$key"); done <<< "$matches_str"

  key="$(choose_match "${matches[@]}")"
  if [[ -z "$key" ]]; then
    warn "Cancelled."
    return 1
  fi
  printf '%s' "$key"
}

# Shared update flow: search for a key by suffix, pick a match, set a new value.
update_secret() {
  local icon="$1" suffix="$2" label="$3"
  local key value

  if ! key="$(search_and_pick "$icon" "$suffix" "$label" "update")"; then
    return 0
  fi
  info "Selected ${key}"

  read -rs -p "${BOLD}${icon} New value for ${key} (hidden, empty to cancel)${RESET}: " value </dev/tty
  printf '\n'
  if [[ -z "$value" ]]; then
    warn "Cancelled — nothing updated."
    return
  fi

  prepare_file
  dotenvx set "$key" "$value" -f "$ENV_FILE" >/dev/null
  ok "Updated ${key} in ${ENV_FILE} (encrypted)"
  info "Round-trip check:"
  verify_value "$icon" "$key" "$value"
}

show_api_key() {
  local key
  if ! key="$(search_and_pick "$SHOW_ICON" "_API_KEY" "API key" "show")"; then
    return 0
  fi
  if [[ "$ECHO_SECRETS" == "always" ]]; then
    info "Decrypted via dotenvx get:"
    printf '%s\n' "$(format_secret_line "$KEY_ICON" "$key")"
  else
    reveal_secrets "$(format_secret_line "$KEY_ICON" "$key")"
  fi
}

# Search both halves of a credential pair (*_PASSWORD and USER_*), dedupe to
# logical names, then show whichever of NAME_PASSWORD / USER_NAME exists.
show_user_password() {
  local term matches_str key name names=()

  if [[ ! -f "$ENV_FILE" ]]; then
    error "${ENV_FILE} does not exist."
    return 0
  fi

  read -r -p "${BOLD}${SHOW_ICON} User/Password to show (search, empty to cancel)${RESET}: " term </dev/tty
  if [[ -z "$term" ]]; then
    warn "Cancelled."
    return 0
  fi

  matches_str="$(find_matching_keys "$term" "(_PASSWORD\$|^USER_)")"
  if [[ -z "$matches_str" ]]; then
    error "No *_PASSWORD or USER_* keys match '${term}' in ${ENV_FILE}."
    return 0
  fi

  # Collapse USER_FOO and FOO_PASSWORD into one logical name FOO
  while IFS= read -r key; do
    if [[ "$key" == USER_* ]]; then
      name="${key#USER_}"
    else
      name="${key%_PASSWORD}"
    fi
    case " ${names[*]-} " in
      *" ${name} "*) ;;
      *) names+=("$name") ;;
    esac
  done <<< "$matches_str"

  name="$(choose_match "${names[@]}")"
  if [[ -z "$name" ]]; then
    warn "Cancelled."
    return 0
  fi

  local lines=()
  if key_exists "${name}_PASSWORD"; then
    lines+=("$(format_secret_line "$KEY_ICON" "${name}_PASSWORD")")
  else
    warn "No ${name}_PASSWORD in ${ENV_FILE}."
  fi
  if key_exists "USER_${name}"; then
    lines+=("$(format_secret_line "$USER_ICON" "USER_${name}")")
  else
    warn "No USER_${name} in ${ENV_FILE}."
  fi
  if [[ ${#lines[@]} -eq 0 ]]; then
    return 0
  fi
  if [[ "$ECHO_SECRETS" == "always" ]]; then
    info "Decrypted via dotenvx get:"
    printf '%s\n' "${lines[@]}"
  else
    reveal_secrets "${lines[@]}"
  fi
}

add_api_key() {
  local name key value
  name="$(prompt_name "API key name (e.g. SOME_SYSTEM)")"
  key="${name}_API_KEY"

  if key_exists "$key"; then
    error "${key} already exists in ${ENV_FILE} — nothing added."
    return
  fi

  value="$(prompt_secret "${KEY_ICON} Value for ${key} (hidden)")"

  prepare_file
  append_secret "$key" "$value"
  info "Encrypting new value"
  encrypt_file
  ok "Added ${key} to ${ENV_FILE} (encrypted)"
  info "Round-trip check:"
  verify_value "$KEY_ICON" "$key" "$value"
}

add_user_password() {
  # One name covers the pair: NAME -> NAME_PASSWORD and USER_NAME
  local name user_key pass_key user_val pass_val skip_user=0 skip_pass=0
  name="$(prompt_name "PASSWORD NAME (e.g. AIHUB)")"
  pass_key="${name}_PASSWORD"
  user_key="USER_${name}"

  if key_exists "$pass_key"; then
    error "${pass_key} already exists in ${ENV_FILE} — it will be skipped."
    skip_pass=1
  fi
  if key_exists "$user_key"; then
    error "${user_key} already exists in ${ENV_FILE} — it will be skipped."
    skip_user=1
  fi
  if [[ $skip_user -eq 1 && $skip_pass -eq 1 ]]; then
    error "Both keys already exist — nothing added."
    return
  fi

  if [[ $skip_pass -eq 0 ]]; then
    pass_val="$(prompt_secret "${KEY_ICON} Value for ${pass_key} (hidden)")"
  fi
  if [[ $skip_user -eq 0 ]]; then
    user_val="$(prompt_secret "${USER_ICON} Value for ${user_key} (hidden)")"
  fi

  prepare_file
  if [[ $skip_pass -eq 0 ]]; then append_secret "$pass_key" "$pass_val"; fi
  if [[ $skip_user -eq 0 ]]; then append_secret "$user_key" "$user_val"; fi
  info "Encrypting new values"
  encrypt_file
  if [[ $skip_pass -eq 0 ]]; then ok "Added ${pass_key} to ${ENV_FILE} (encrypted)"; fi
  if [[ $skip_user -eq 0 ]]; then ok "Added ${user_key} to ${ENV_FILE} (encrypted)"; fi
  info "Round-trip check:"
  if [[ $skip_pass -eq 0 ]]; then verify_value "$KEY_ICON" "$pass_key" "$pass_val"; fi
  if [[ $skip_user -eq 0 ]]; then verify_value "$USER_ICON" "$user_key" "$user_val"; fi
}

choose_env_file() {
  # Skip the picker when a file was passed on the command line
  if [[ -n "$ENV_FILE" ]]; then
    return
  fi
  while true; do
    printf '\n%s\n' "${BOLD}Which env file?${RESET}"
    printf '%s\n' "  ${BOLD}1${RESET}) ./.env ${DIM}(current directory)${RESET}"
    printf '%s\n' "  ${BOLD}2${RESET}) ${CREDENTIALS_FILE/#"$HOME"/\~}"
    read -r -p "${BOLD}Choose [1/2]${RESET}: " choice </dev/tty
    case "$choice" in
      1) ENV_FILE=".env"; return ;;
      2)
        mkdir -p "$(dirname "$CREDENTIALS_FILE")"
        ENV_FILE="$CREDENTIALS_FILE"
        return
        ;;
      *) error "Invalid choice: ${choice}" ;;
    esac
  done
}

# Encrypt the whole selected file (idempotent — plaintext values are
# encrypted, already-encrypted values are left alone).
encrypt_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    error "${ENV_FILE} does not exist — nothing to encrypt."
    return 0
  fi
  info "Encrypting ${ENV_FILE}"
  encrypt_file
  ok "${ENV_FILE} is encrypted ${LOCK_ICON}"
}

# Decrypt the whole selected file to plaintext on disk, after a backup of the
# encrypted state and an explicit confirmation.
decrypt_env_file() {
  local confirm
  if [[ ! -f "$ENV_FILE" ]]; then
    error "${ENV_FILE} does not exist — nothing to decrypt."
    return 0
  fi
  warn "This will write DECRYPTED PLAINTEXT values to ${ENV_FILE}."
  read -r -p "${BOLD}${UNLOCK_ICON} Decrypt ${ENV_FILE}? [y/N]${RESET}: " confirm </dev/tty
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) warn "Cancelled — file left encrypted."; return 0 ;;
  esac
  info "Backing up encrypted state first"
  prepare_file
  dotenvx decrypt -f "$ENV_FILE" >/dev/null
  ok "${ENV_FILE} is now plaintext ${UNLOCK_ICON} — re-encrypt with option 7 when done."
}

main_menu() {
  while true; do
    printf '\n%s\n' "${BOLD}dotenvxsh${RESET} ${DIM}— target file: ${ENV_FILE}${RESET}"
    printf '%s\n' "  ${BOLD}1${RESET}) ${KEY_ICON} API_KEY          ${DIM}(adds <NAME>_API_KEY)${RESET}"
    printf '%s\n' "  ${BOLD}2${RESET}) ${USER_ICON} USER & PASSWORD  ${DIM}(adds <NAME>_PASSWORD and USER_<NAME>)${RESET}"
    printf '%s\n' "  ${BOLD}3${RESET}) ${EDIT_ICON}Update API_KEY   ${DIM}(search & update a *_API_KEY)${RESET}"
    printf '%s\n' "  ${BOLD}4${RESET}) ${EDIT_ICON}Update PASSWORD  ${DIM}(search & update a *_PASSWORD)${RESET}"
    printf '%s\n' "  ${BOLD}5${RESET}) ${SHOW_ICON} Show API_KEY     ${DIM}(search & display a *_API_KEY)${RESET}"
    printf '%s\n' "  ${BOLD}6${RESET}) ${SHOW_ICON} Show USER & PASSWORD ${DIM}(search & display *_PASSWORD + USER_*)${RESET}"
    printf '%s\n' "  ${BOLD}7${RESET}) ${LOCK_ICON} Encrypt file     ${DIM}(dotenvx encrypt the whole file)${RESET}"
    printf '%s\n' "  ${BOLD}8${RESET}) ${UNLOCK_ICON} Decrypt file     ${DIM}(dotenvx decrypt to plaintext, backup first)${RESET}"
    printf '%s\n' "  ${BOLD}q${RESET}) Quit"
    read -r -p "${BOLD}Choose [1-8/q]${RESET}: " choice </dev/tty
    case "$choice" in
      1) add_api_key ;;
      2) add_user_password ;;
      3) update_secret "$KEY_ICON" "_API_KEY" "API key" ;;
      4) update_secret "$KEY_ICON" "_PASSWORD" "Password" ;;
      5) show_api_key ;;
      6) show_user_password ;;
      7) encrypt_env_file ;;
      8) decrypt_env_file ;;
      q|Q) printf '%s\n' "${DIM}Bye.${RESET}"; exit 0 ;;
      *) error "Invalid choice: ${choice}" ;;
    esac
  done
}

require_dotenvx
printf '\n%s\n' "${VAULT_ICON} ${BOLD}dotenvx helper${RESET} ${DIM}v${VERSION}${RESET}"
choose_env_file
main_menu
