#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: auto-spicetify.sh
# Description: Automated Spicetify setup/recovery for Dusky Dotfiles.
#              Handles package installation, marketplace injection, and 
#              Comfy theme setup while respecting UWSM/Matugen environments.
# Author: Dusky Dotfiles Automation
# License: MIT
# -----------------------------------------------------------------------------

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly REQUIRED_BASH_VERSION=5
declare -a TEMP_FILES=()

if [[ -t 1 ]]; then
    readonly COLOR_RESET=$'\033[0m'
    readonly COLOR_INFO=$'\033[1;34m'
    readonly COLOR_SUCCESS=$'\033[1;32m'
    readonly COLOR_WARN=$'\033[1;33m'
    readonly COLOR_ERR=$'\033[1;31m'
    readonly COLOR_BOLD=$'\033[1m'
else
    readonly COLOR_RESET=''
    readonly COLOR_INFO=''
    readonly COLOR_SUCCESS=''
    readonly COLOR_WARN=''
    readonly COLOR_ERR=''
    readonly COLOR_BOLD=''
fi

log_info()    { printf '%s[INFO]%s %s\n' "${COLOR_INFO}" "${COLOR_RESET}" "$*"; }
log_success() { printf '%s[OK]%s %s\n' "${COLOR_SUCCESS}" "${COLOR_RESET}" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n' "${COLOR_WARN}" "${COLOR_RESET}" "$*" >&2; }
log_err()     { printf '%s[ERROR]%s %s\n' "${COLOR_ERR}" "${COLOR_RESET}" "$*" >&2; }
die()         { log_err "$*"; exit 1; }

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM

    for file in "${TEMP_FILES[@]}"; do
        [[ -f "$file" ]] && rm -f "$file"
    done

    if [[ $exit_code -ne 0 ]]; then
        log_err "Script failed with exit code $exit_code"
    fi
    exit "$exit_code"
}
trap cleanup EXIT INT TERM

detect_pm() {
    if command -v pacman &>/dev/null && pacman -Si spicetify-cli &>/dev/null; then
        echo "pacman"
        return 0
    fi

    if command -v paru &>/dev/null; then
        echo "paru"
        return 0
    fi

    if command -v yay &>/dev/null; then
        echo "yay"
        return 0
    fi

    die "No suitable package manager found. Please install paru or yay."
}

install_package() {
    local pkg="$1"
    local pm
    pm=$(detect_pm)

    log_info "Installing $pkg using $pm..."
    
    case "$pm" in
        pacman)
            sudo pacman -S --needed --noconfirm "$pkg"
            ;;
        paru|yay)
            "$pm" -S --needed --noconfirm "$pkg"
            ;;
    esac
}

check_requirements() {
    if ((BASH_VERSINFO[0] < REQUIRED_BASH_VERSION)); then
        die "Bash 5.0+ required. Current: $BASH_VERSION"
    fi

    if command -v spotify &>/dev/null; then
        log_success "Spotify binary detected."
    elif command -v spotify-launcher &>/dev/null; then
        log_success "Spotify-launcher detected."
    else
        die "Spotify is not installed! Install 'spotify' or 'spotify-launcher' first."
    fi
}

prompt_user_confirmation() {
    if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
        log_info "Auto-confirm enabled."
        return 0
    fi

    log_warn "--- USER ATTENTION REQUIRED ---"
    printf "%s" "To ensure Spicetify works, please confirm:
  1. Spotify is installed and you are logged in.
  2. You have kept Spotify open for ~60 seconds (to generate config files).
"
    
    while true; do
        printf "${COLOR_BOLD}Ready to proceed? [y/n]: ${COLOR_RESET}"
        read -r -p "" confirm || confirm="n"
        case "${confirm,,}" in
            y|yes) break ;;
            n|no)  die "Setup aborted by user." ;;
            *)     log_warn "Please answer 'y' or 'n'." ;;
        esac
    done
}

setup_spicetify() {
    if ! command -v spicetify &>/dev/null; then
        install_package "spicetify-cli"
    else
        log_info "Spicetify CLI is already installed."
    fi

    log_info "Generating Spicetify config..."
    spicetify > /dev/null 2>&1 || true

    log_info "Applying backup and enabling devtools..."
    if ! spicetify backup apply enable-devtools 2>/dev/null; then
        log_warn "Backup/Apply returned non-zero. Assuming Spotify is already patched or backup exists."
        log_info "Proceeding with update..."
    else
        log_success "Backup and injection successful."
    fi

    log_info "Updating internal extensions..."
    spicetify update
}

install_marketplace() {
    log_info "Installing Spicetify Marketplace..."
    
    local mk_script
    mk_script=$(mktemp)
    TEMP_FILES+=("$mk_script")

    if ! curl -fsSL "https://raw.githubusercontent.com/spicetify/spicetify-marketplace/main/resources/install.sh" -o "$mk_script"; then
        die "Failed to download Marketplace installer."
    fi

    if ! bash "$mk_script"; then
        log_warn "Marketplace install script returned error. It might already be installed."
    else
        log_success "Marketplace installed."
    fi
}

setup_theme() {
    local config_dir
    config_dir="$(dirname "$(spicetify -c)")"
    
    local themes_dir="$config_dir/Themes"
    local comfy_dir="$themes_dir/Comfy"

    log_info "Setting up Comfy Theme..."
    mkdir -p "$themes_dir"

    if [[ -d "$comfy_dir" ]]; then
        if [[ -L "$comfy_dir/color.ini" ]]; then
            log_success "Matugen configuration detected (color.ini is a symlink)."
            log_info "Skipping Git pull to protect generated colors."
        else
            log_info "Updating Comfy theme..."
            if ! git -C "$comfy_dir" pull --ff-only; then
                log_warn "Git pull failed (likely local changes). Skipping update."
            fi
        fi
    else
        log_info "Cloning Comfy theme..."
        git clone https://github.com/Comfy-Themes/Spicetify "$comfy_dir"
    fi
    log_info "Configuring Spicetify for Matugen-only setup..."

    spicetify config current_theme ""
    spicetify config color_scheme ""
    spicetify config inject_css 1
    spicetify config replace_colors 1

    log_info "Applying changes..."
    spicetify apply
}

main() {
    check_requirements
    prompt_user_confirmation "${1:-}"
    setup_spicetify
    install_marketplace
    setup_theme

    echo ""
    log_success "Spicetify setup complete!"
    log_info "If colors are missing, run 'matugen' to generate them."
}

main "$@"