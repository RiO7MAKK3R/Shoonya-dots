#!/usr/bin/env bash
# ==============================================================================
# SHOONYA — POST-INSTALL BOOTSTRAP
# Target : Arch Linux (fresh install)
# Mode   : Non-interactive, idempotent
# Usage  : bash bootstrap.sh
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # repo root
CONFIG_SRC="$DOTFILES_DIR/configs"
SCRIPTS_DIR="$DOTFILES_DIR/user_scripts/install"
PKG_DIR="$DOTFILES_DIR/packages"

REAL_USER="${USER}"
REAL_HOME="${HOME}"
XDG_CONFIG="$REAL_HOME/.config"

DEFAULT_WALLPAPER="$CONFIG_SRC/wallpapers/default.png"

# ------------------------------------------------------------------------------
# OUTPUT HELPERS
# ------------------------------------------------------------------------------

RESET="\033[0m"; BOLD="\033[1m"
CYAN="\033[0;36m"; GREEN="\033[0;32m"
YELLOW="\033[0;33m"; RED="\033[0;31m"

info()    { echo -e "${CYAN}${BOLD}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}${BOLD}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}${BOLD}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}${BOLD}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo ""; echo -e "${BOLD}── $* ${RESET}"; }
divider() { echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

run_script() {
    local script="$SCRIPTS_DIR/$1"
    shift
    if [[ -x "$script" ]]; then
        bash "$script" "$@"
    else
        warn "Script not found or not executable, skipping: $script"
    fi
}

# ------------------------------------------------------------------------------
# PREFLIGHT
# ------------------------------------------------------------------------------

preflight() {
    divider
    echo -e "${BOLD}  SHOONYA — Post-Install Bootstrap${RESET}"
    echo -e "  User: ${CYAN}$REAL_USER${RESET}  |  Home: ${CYAN}$REAL_HOME${RESET}"
    divider
    echo ""

    [[ $EUID -eq 0 ]]          && die "Do NOT run as root. Run: bash bootstrap.sh"
    [[ -f /etc/arch-release ]] || die "This script targets Arch Linux only."
    command -v sudo &>/dev/null || die "sudo not found."
    sudo -v                    || die "Cannot obtain sudo — check sudoers."

    ok "Preflight passed"
}

# ------------------------------------------------------------------------------
# STEP 1 — Pacman Packages
# ------------------------------------------------------------------------------

install_pacman_packages() {
    step "Pacman Packages"

    local pkg_file="$PKG_DIR/pacman.txt"
    [[ -f "$pkg_file" ]] || die "Missing package list: $pkg_file"

    # Full system upgrade first — this ensures libalpm is at its final version
    # before we attempt to build anything against it (e.g. yay from source).
    # Running -Syu before -S also prevents partial-upgrade breakage.
    info "Full system upgrade (pacman -Syu)..."
    sudo pacman -Syu --noconfirm

    info "Installing pacman packages from pacman.txt..."
    sudo pacman -S --noconfirm --needed - < "$pkg_file"

    # Ensure rsync is present — deploy_configs() depends on it and it is not
    # guaranteed to be in every pacman.txt.
    info "Ensuring rsync is installed..."
    sudo pacman -S --needed --noconfirm rsync

    # Refresh bash's command hash table so any upgraded/newly installed
    # binaries (pacman, makepkg, etc.) are resolved from their current paths.
    hash -r

    ok "Pacman packages done"
}

# ------------------------------------------------------------------------------
# STEP 2 — AUR Helper (yay)
# ------------------------------------------------------------------------------

# Global flag — install_aur_packages() reads this to decide whether to proceed.
YAY_OK=0

install_yay() {
    step "AUR Helper (yay)"

    # base-devel and git are required to compile any AUR package.
    # Install them unconditionally — pacman --needed makes this a no-op
    # if they are already present.
    info "Ensuring base-devel and git are installed..."
    sudo pacman -S --needed --noconfirm base-devel git

    # If yay is already present, verify it actually links correctly against
    # the current libalpm before trusting it.  A binary built against an older
    # libalpm soname will be found by `command -v` but will fail to run.
    if command -v yay &>/dev/null; then
        if yay --version &>/dev/null; then
            ok "yay already installed and functional"
            YAY_OK=1
            return
        else
            warn "yay is installed but failed to run (likely libalpm soname mismatch)."
            warn "Rebuilding yay from source to match the current libalpm..."
        fi
    else
        info "yay not found — building from source..."
    fi

    # Build yay from source so makepkg compiles it against the libalpm version
    # that is currently installed, regardless of any recent soname bump.
    local tmp
    tmp="$(mktemp -d)"

    git clone --depth=1 https://aur.archlinux.org/yay.git "$tmp/yay" \
        || { warn "Failed to clone yay from AUR — AUR packages will be skipped."; rm -rf "$tmp"; return; }

    (
        cd "$tmp/yay"
        makepkg -si --noconfirm
    ) || { warn "makepkg failed building yay — AUR packages will be skipped."; rm -rf "$tmp"; return; }

    rm -rf "$tmp"

    # Refresh path cache so the newly built binary is immediately visible.
    hash -r

    # Final verification — confirm the binary is on PATH and actually executes.
    # Both checks are required: command -v confirms PATH visibility, yay --version
    # confirms the binary loads and links correctly against the current libalpm.
    if command -v yay &>/dev/null && yay --version &>/dev/null; then
        ok "yay built and verified"
        YAY_OK=1
    else
        warn "yay was built but could not run — AUR packages will be skipped."
    fi
}

# ------------------------------------------------------------------------------
# STEP 3 — AUR Packages
# ------------------------------------------------------------------------------

install_aur_packages() {
    step "AUR Packages"

    # Respect the flag set by install_yay().
    # If yay could not be built or verified, skip AUR entirely rather than
    # letting `yay -S` crash the whole bootstrap.
    if [[ "$YAY_OK" -ne 1 ]]; then
        warn "Skipping AUR packages — yay is not available."
        return
    fi

    local pkg_file="$PKG_DIR/aur.txt"
    if [[ ! -s "$pkg_file" ]]; then
        info "No AUR packages listed — skipping"
        return
    fi

    info "Installing AUR packages from aur.txt..."
    yay -S --needed --noconfirm - < "$pkg_file" \
        || warn "One or more AUR packages failed to install"

    ok "AUR packages done"
}

# ------------------------------------------------------------------------------
# STEP 4 — Flatpak
# ------------------------------------------------------------------------------

install_flatpak_apps() {
    step "Flatpak Apps"

    local pkg_file="$PKG_DIR/flatpak.txt"
    if [[ ! -s "$pkg_file" ]]; then
        info "No Flatpak apps listed — skipping"
        return
    fi

    if ! command -v flatpak &>/dev/null; then
        info "Installing flatpak..."
        sudo pacman -S --noconfirm --needed flatpak
    fi

    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo

    info "Installing Flatpak apps from flatpak.txt..."
    mapfile -t apps < "$pkg_file"
    flatpak install -y flathub "${apps[@]}"

    ok "Flatpak apps done"
}

# ------------------------------------------------------------------------------
# STEP 5 — Deploy Configs (rsync, non-destructive)
# ------------------------------------------------------------------------------

deploy_configs() {
    step "Deploy Configs"

    [[ -d "$CONFIG_SRC" ]] || die "Config source not found: $CONFIG_SRC"

    mkdir -p "$XDG_CONFIG"
    info "Syncing configs/ → ~/.config/ ..."
    rsync -a --backup --suffix=".bak" "$CONFIG_SRC/" "$XDG_CONFIG/"

    if [[ -d "$DOTFILES_DIR/scripts" ]]; then
        mkdir -p "$REAL_HOME/.local/bin"
        rsync -a "$DOTFILES_DIR/scripts/" "$REAL_HOME/.local/bin/"
        chmod +x "$REAL_HOME/.local/bin/"* 2>/dev/null || true
        info "Scripts deployed → ~/.local/bin"
    fi

    ok "Configs deployed"
}

# ------------------------------------------------------------------------------
# STEP 6 — Required Directories
# ------------------------------------------------------------------------------

create_directories() {
    step "Required Directories"

    local dirs=(
        "$REAL_HOME/Pictures/Wallpapers"
        "$REAL_HOME/Pictures/Screenshots"
        "$REAL_HOME/.local/bin"
        "$REAL_HOME/.local/share"
        "$REAL_HOME/.cache/shoonya"
    )

    for d in "${dirs[@]}"; do
        mkdir -p "$d" && info "Ready: $d"
    done

    # Matugen-specific directories (if script exists)
    run_script "021_matugen_directories.sh"

    ok "Directories ready"
}

# ------------------------------------------------------------------------------
# STEP 7 — Qt Theme
# ------------------------------------------------------------------------------

apply_qt_config() {
    step "Qt Theme Config"
    run_script "025_qtct_config.sh"
    ok "Qt config applied"
}

# ------------------------------------------------------------------------------
# STEP 8 — Wallpaper Seed + Matugen Color Scheme (CRITICAL)
# ------------------------------------------------------------------------------

seed_theme() {
    step "Wallpaper + Initial Color Scheme"

    if [[ ! -f "$DEFAULT_WALLPAPER" ]]; then
        warn "No default wallpaper found at $DEFAULT_WALLPAPER — skipping seed"
        return
    fi

    cp -f "$DEFAULT_WALLPAPER" "$REAL_HOME/Pictures/Wallpapers/default.png"
    info "Default wallpaper copied"

    # Start swww daemon if not running
    if ! pgrep -x swww-daemon &>/dev/null; then
        info "Starting swww-daemon..."
        swww-daemon &
        sleep 1
    fi

    swww img "$REAL_HOME/Pictures/Wallpapers/default.png" \
        || warn "swww img failed — continuing anyway"

    run_script "086_generate_colorfiles_for_current_wallpaper.sh"

    ok "Initial theme seeded"
}

# ------------------------------------------------------------------------------
# STEP 9 — System Services
# ------------------------------------------------------------------------------

enable_system_services() {
    step "System Services"
    run_script "050_system_services.sh"
    ok "System services configured"
}

# ------------------------------------------------------------------------------
# STEP 10 — User Services
# ------------------------------------------------------------------------------

enable_user_services() {
    step "User Services"
    run_script "006_enabling_user_services.sh"
    ok "User services configured"
}

# ------------------------------------------------------------------------------
# STEP 11 — Neovim Plugin Sync
# ------------------------------------------------------------------------------

sync_neovim() {
    step "Neovim Plugin Sync"

    if ! command -v nvim &>/dev/null; then
        warn "nvim not found — skipping plugin sync"
        return
    fi

    run_script "047_neovim_lazy_sync.sh"
    ok "Neovim plugins synced"
}

# ------------------------------------------------------------------------------
# STEP 12 — Git Configuration
# ------------------------------------------------------------------------------

configure_git() {
    step "Git Configuration"
    run_script "052_git_config.sh"
    ok "Git configured"
}

# ------------------------------------------------------------------------------
# STEP 13 — SDDM Setup
# ------------------------------------------------------------------------------

configure_sddm() {
    step "SDDM Display Manager"

    if ! command -v sddm &>/dev/null; then
        warn "sddm not installed — skipping"
        return
    fi

    run_script "091_sddm_setup.sh" --auto
    ok "SDDM configured"
}

# ------------------------------------------------------------------------------
# SUMMARY
# ------------------------------------------------------------------------------

final_summary() {
    echo ""
    divider
    echo -e "${GREEN}${BOLD}"
    echo "   ███████╗██╗  ██╗ ██████╗  ██████╗ ███╗  ██╗██╗   ██╗ █████╗ "
    echo "   ██╔════╝██║  ██║██╔═══██╗██╔═══██╗████╗ ██║╚██╗ ██╔╝██╔══██╗"
    echo "   ███████╗███████║██║   ██║██║   ██║██╔██╗██║ ╚████╔╝ ███████║"
    echo "   ╚════██║██╔══██║██║   ██║██║   ██║██║╚████║  ╚██╔╝  ██╔══██║"
    echo "   ███████║██║  ██║╚██████╔╝╚██████╔╝██║ ╚███║   ██║   ██║  ██║"
    echo "   ╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚══╝   ╚═╝   ╚═╝  ╚═╝"
    echo -e "${RESET}"
    divider
    echo ""
    echo -e "  ${GREEN}${BOLD}Bootstrap complete.${RESET}"
    echo ""
    echo -e "  ${BOLD}Config deployed to:${RESET}  ~/.config"
    echo -e "  ${BOLD}Scripts at:${RESET}         ~/.local/bin"
    echo -e "  ${BOLD}Wallpapers at:${RESET}      ~/Pictures/Wallpapers"
    echo ""
    echo -e "  ${CYAN}Next:${RESET}  Reboot → select Hyprland at SDDM"
    echo -e "         Or from TTY: ${BOLD}Hyprland${RESET}"
    echo ""
    divider
    echo ""
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main() {
    preflight

    install_pacman_packages   # 1
    install_yay               # 2
    install_aur_packages      # 3
    install_flatpak_apps      # 4
    deploy_configs            # 5
    create_directories        # 6
    apply_qt_config           # 7
    seed_theme                # 8  ← matugen color seed (critical)
    enable_system_services    # 9
    enable_user_services      # 10
    sync_neovim               # 11
    configure_git             # 12
    configure_sddm            # 13

    final_summary
}

main "$@"
