#!/usr/bin/env bash
# ==============================================================================
# SHOONYA — POST-INSTALL BOOTSTRAP
# Target : Arch Linux (fresh install)
# Mode   : Non-interactive, idempotent
# Usage  : bash bootstrap.sh
# ==============================================================================
#
# What this script does, in order:
#   1.  Preflight checks
#   2.  Full system upgrade (pacman -Syu)
#   3.  Install pacman packages from packages/pacman.txt
#   4.  Build yay from source + verify
#   5.  Install AUR packages from packages/aur.txt
#   6.  Install Flatpak + apps from packages/flatpak.txt
#   7.  Clone dotfiles repo
#   8.  Deploy configs (rsync repo/configs/ → ~/.config/)
#   9.  Create required directories
#   10. Change default shell to zsh
#   11. Enable system services
#   12. Enable user services
#   13. Enable SDDM
#   14. Seed wallpaper + generate matugen colour scheme
#   15. Sync Neovim plugins
#   16. Final summary
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION — edit these before running
# ------------------------------------------------------------------------------

DOTFILES_REPO="https://github.com/YOURUSERNAME/YOURREPO.git"   # ← replace
DOTFILES_DIR="$HOME/shoonya-dotfiles"                          # clone target

PKG_DIR="$DOTFILES_DIR/packages"
CONFIG_SRC="$DOTFILES_DIR/configs"      # repo/configs/ → ~/.config/

REAL_USER="${USER}"
REAL_HOME="${HOME}"
XDG_CONFIG="$REAL_HOME/.config"

DEFAULT_WALLPAPER="$REAL_HOME/Pictures/Wallpapers/default.png"

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
step()    { echo ""; echo -e "${BOLD}━━  $*${RESET}"; }
divider() { echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ------------------------------------------------------------------------------
# STEP 0 — Preflight
# ------------------------------------------------------------------------------

preflight() {
    divider
    echo -e "${BOLD}  SHOONYA — Post-Install Bootstrap${RESET}"
    echo -e "  User : ${CYAN}$REAL_USER${RESET}"
    echo -e "  Home : ${CYAN}$REAL_HOME${RESET}"
    echo -e "  Repo : ${CYAN}$DOTFILES_REPO${RESET}"
    divider
    echo ""

    [[ $EUID -eq 0 ]]          && die "Do NOT run as root. Run: bash bootstrap.sh"
    [[ -f /etc/arch-release ]] || die "This script targets Arch Linux only."
    command -v sudo &>/dev/null || die "sudo not found. Install sudo first."
    sudo -v                    || die "Cannot obtain sudo — check sudoers."
    command -v git &>/dev/null || die "git not found. Install git first."

    ok "Preflight passed"
}

# ------------------------------------------------------------------------------
# STEP 1 — Full system upgrade + pacman packages
# ------------------------------------------------------------------------------

install_pacman_packages() {
    step "Pacman — Full upgrade + package install"

    local pkg_file="$PKG_DIR/pacman.txt"
    [[ -f "$pkg_file" ]] || die "Missing package list: $pkg_file"

    info "Full system upgrade (pacman -Syu)..."
    sudo pacman -Syu --noconfirm

    # Ensure rsync is present before deploy_configs() needs it.
    # --needed makes this a no-op if already installed.
    info "Ensuring rsync and base-devel are present..."
    sudo pacman -S --needed --noconfirm rsync base-devel

    info "Installing pacman packages from pacman.txt..."
    sudo pacman -S --needed --noconfirm - < "$pkg_file"

    # Refresh bash command hash so all newly installed binaries are visible.
    hash -r

    ok "Pacman packages done"
}

# ------------------------------------------------------------------------------
# STEP 2 — AUR helper (yay, built from source)
# ------------------------------------------------------------------------------

# Global flag read by install_aur_packages().
YAY_OK=0

install_yay() {
    step "AUR Helper — yay (build from source)"

    # If yay is already present, verify it actually links against the current
    # libalpm. A binary built before a libalpm soname bump will be found by
    # command -v but will segfault or refuse to run.
    if command -v yay &>/dev/null; then
        if yay --version &>/dev/null; then
            ok "yay already installed and functional"
            YAY_OK=1
            return
        else
            warn "yay found but failed to run — libalpm soname mismatch likely."
            warn "Rebuilding yay from source..."
        fi
    else
        info "yay not found — building from source..."
    fi

    local tmp
    tmp="$(mktemp -d)"

    git clone --depth=1 https://aur.archlinux.org/yay.git "$tmp/yay" \
        || { warn "Failed to clone yay — AUR packages will be skipped."; rm -rf "$tmp"; return; }

    (
        cd "$tmp/yay"
        makepkg -si --noconfirm
    ) || { warn "makepkg failed for yay — AUR packages will be skipped."; rm -rf "$tmp"; return; }

    rm -rf "$tmp"

    # Refresh path cache so the freshly installed binary is found immediately.
    hash -r

    # Verify: must both exist on PATH and actually execute cleanly.
    if command -v yay &>/dev/null && yay --version &>/dev/null; then
        ok "yay built and verified"
        YAY_OK=1
    else
        warn "yay binary unresponsive after build — AUR packages will be skipped."
    fi
}

# ------------------------------------------------------------------------------
# STEP 3 — AUR packages
# ------------------------------------------------------------------------------

install_aur_packages() {
    step "AUR Packages"

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
    # || warn keeps set -e from aborting the entire bootstrap if one package
    # fails (e.g. a package is renamed or temporarily unavailable in the AUR).
    yay -S --needed --noconfirm - < "$pkg_file" \
        || warn "One or more AUR packages failed — continuing"

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

    # flatpak itself is in pacman.txt, but guard anyway.
    if ! command -v flatpak &>/dev/null; then
        info "Installing flatpak..."
        sudo pacman -S --needed --noconfirm flatpak
    fi

    info "Adding Flathub remote..."
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo

    info "Installing Flatpak apps from flatpak.txt..."
    mapfile -t apps < "$pkg_file"
    flatpak install -y flathub "${apps[@]}" \
        || warn "One or more Flatpak apps failed — continuing"

    ok "Flatpak apps done"
}

# ------------------------------------------------------------------------------
# STEP 5 — Clone dotfiles
# ------------------------------------------------------------------------------

clone_dotfiles() {
    step "Clone Dotfiles"

    if [[ -d "$DOTFILES_DIR/.git" ]]; then
        info "Repo already cloned — pulling latest..."
        git -C "$DOTFILES_DIR" pull --ff-only \
            || warn "git pull failed — local changes may exist, continuing with current state"
        ok "Dotfiles up to date"
        return
    fi

    info "Cloning $DOTFILES_REPO → $DOTFILES_DIR ..."
    git clone --depth=1 "$DOTFILES_REPO" "$DOTFILES_DIR" \
        || die "Failed to clone dotfiles repo. Check the URL and your network."

    ok "Dotfiles cloned"
}

# ------------------------------------------------------------------------------
# STEP 6 — Deploy configs
# ------------------------------------------------------------------------------

deploy_configs() {
    step "Deploy Configs (rsync)"

    [[ -d "$CONFIG_SRC" ]] || die "Config source not found: $CONFIG_SRC"

    mkdir -p "$XDG_CONFIG"

    info "Syncing $CONFIG_SRC/ → $XDG_CONFIG/ ..."
    # --backup preserves any file the rsync would overwrite, suffixed .bak.
    # This means re-runs are safe and nothing is silently destroyed.
    rsync -a --backup --suffix=".bak" "$CONFIG_SRC/" "$XDG_CONFIG/"

    ok "Configs deployed"
}

# ------------------------------------------------------------------------------
# STEP 7 — Required directories
# ------------------------------------------------------------------------------

create_directories() {
    step "Required Directories"

    local dirs=(
        "$REAL_HOME/Pictures/Wallpapers"
        "$REAL_HOME/Pictures/Screenshots"
        "$REAL_HOME/.local/bin"
        "$REAL_HOME/.local/share"
        "$REAL_HOME/.cache/shoonya"
        # Matugen expects these to exist before first run
        "$XDG_CONFIG/matugen"
        "$XDG_CONFIG/matugen/colors"
    )

    for d in "${dirs[@]}"; do
        mkdir -p "$d"
        info "Ready: $d"
    done

    ok "Directories ready"
}

# ------------------------------------------------------------------------------
# STEP 8 — Change default shell to zsh
# ------------------------------------------------------------------------------

set_default_shell() {
    step "Default Shell → zsh"

    local zsh_path
    zsh_path="$(command -v zsh 2>/dev/null || true)"

    if [[ -z "$zsh_path" ]]; then
        warn "zsh not found on PATH — shell change skipped"
        return
    fi

    if [[ "$SHELL" == "$zsh_path" ]]; then
        ok "zsh is already the default shell"
        return
    fi

    # Ensure zsh is listed in /etc/shells (required by chsh).
    if ! grep -qxF "$zsh_path" /etc/shells; then
        info "Adding $zsh_path to /etc/shells..."
        echo "$zsh_path" | sudo tee -a /etc/shells > /dev/null
    fi

    info "Changing shell to zsh for $REAL_USER..."
    chsh -s "$zsh_path" "$REAL_USER" \
        || warn "chsh failed — change shell manually with: chsh -s $zsh_path"

    ok "Default shell set to zsh (takes effect on next login)"
}

# ------------------------------------------------------------------------------
# STEP 9 — System services
# ------------------------------------------------------------------------------

enable_system_services() {
    step "System Services"

    # These match the services confirmed enabled on the live Shoonya system.
    # getty@.service is a template unit managed by systemd — skip it here.
    local services=(
        acpid.service
        auto-cpufreq.service
        bluetooth.service
        cups.service
        firewalld.service
        grub-btrfsd.service
        libvirtd.service
        NetworkManager.service
        NetworkManager-dispatcher.service
        NetworkManager-wait-online.service
        snapd.service
        sshd.service
        swayosd-libinput-backend.service
        systemd-resolved.service
        systemd-timesyncd.service
        thermald.service
        udisks2.service
        vsftpd.service
    )

    for svc in "${services[@]}"; do
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            info "Already enabled: $svc"
        else
            info "Enabling: $svc"
            sudo systemctl enable --now "$svc" \
                || warn "Failed to enable $svc — continuing"
        fi
    done

    ok "System services done"
}

# ------------------------------------------------------------------------------
# STEP 10 — User services
# ------------------------------------------------------------------------------

enable_user_services() {
    step "User Services"

    local services=(
        fumon.service
        gnome-keyring-daemon.service
        hyprpolkitagent.service
        network_meter.service
        wireplumber.service
        xdg-user-dirs.service
    )

    for svc in "${services[@]}"; do
        if systemctl --user is-enabled --quiet "$svc" 2>/dev/null; then
            info "Already enabled: $svc"
        else
            info "Enabling (user): $svc"
            systemctl --user enable --now "$svc" \
                || warn "Failed to enable user service $svc — continuing"
        fi
    done

    ok "User services done"
}

# ------------------------------------------------------------------------------
# STEP 11 — SDDM
# ------------------------------------------------------------------------------

enable_sddm() {
    step "SDDM Display Manager"

    if ! command -v sddm &>/dev/null; then
        warn "sddm binary not found — skipping (is sddm in pacman.txt?)"
        return
    fi

    if systemctl is-enabled --quiet sddm.service 2>/dev/null; then
        ok "sddm.service already enabled"
        return
    fi

    info "Enabling sddm.service..."
    sudo systemctl enable sddm.service \
        || warn "Failed to enable sddm.service"

    ok "SDDM enabled (active on next boot)"
}

# ------------------------------------------------------------------------------
# STEP 12 — Wallpaper seed + matugen colour scheme
# ------------------------------------------------------------------------------

seed_theme() {
    step "Wallpaper + Matugen Colour Scheme"

    # Copy the default wallpaper from the repo into the expected location.
    local repo_wallpaper="$CONFIG_SRC/wallpapers/default.png"
    if [[ ! -f "$repo_wallpaper" ]]; then
        warn "No default wallpaper at $repo_wallpaper — skipping theme seed"
        return
    fi

    cp -f "$repo_wallpaper" "$DEFAULT_WALLPAPER"
    info "Default wallpaper copied → $DEFAULT_WALLPAPER"

    # swww requires a running Wayland compositor. On a fresh TTY install this
    # will not be available, so we attempt it but never abort on failure.
    if command -v swww &>/dev/null; then
        if ! pgrep -x swww-daemon &>/dev/null; then
            info "Starting swww-daemon..."
            swww-daemon &
            sleep 1
        fi
        swww img "$DEFAULT_WALLPAPER" \
            || warn "swww img failed — no compositor running yet (normal on first install)"
    else
        warn "swww not found — wallpaper will be applied on first Hyprland launch"
    fi

    # Generate matugen colour files from the wallpaper.
    if command -v matugen &>/dev/null; then
        info "Generating matugen colour scheme..."
        matugen image "$DEFAULT_WALLPAPER" \
            || warn "matugen failed — run manually after first login"
    else
        warn "matugen not found — colour scheme generation skipped"
    fi

    ok "Theme seed done"
}

# ------------------------------------------------------------------------------
# STEP 13 — Neovim plugin sync
# ------------------------------------------------------------------------------

sync_neovim() {
    step "Neovim Plugin Sync"

    if ! command -v nvim &>/dev/null; then
        warn "nvim not found — skipping plugin sync"
        return
    fi

    info "Running Lazy sync (headless)..."
    # --headless runs nvim without a UI.
    # +qa closes nvim once the sync command completes.
    nvim --headless "+Lazy! sync" +qa 2>/dev/null \
        || warn "Neovim Lazy sync failed — run :Lazy sync manually on first launch"

    ok "Neovim plugins synced"
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
    echo -e "  ${BOLD}Dotfiles cloned to:${RESET}  $DOTFILES_DIR"
    echo -e "  ${BOLD}Configs deployed:${RESET}    $XDG_CONFIG"
    echo -e "  ${BOLD}Wallpaper:${RESET}           $DEFAULT_WALLPAPER"
    echo ""
    echo -e "  ${CYAN}${BOLD}Next steps:${RESET}"
    echo -e "   1. Reboot the system"
    echo -e "   2. SDDM will start — select Hyprland"
    echo -e "   3. Log in — matugen and swww will apply on first launch"
    echo -e "   4. If shell did not change: run ${BOLD}chsh -s \$(which zsh)${RESET}"
    echo ""
    divider
    echo ""
}

# ------------------------------------------------------------------------------
# MAIN
# ------------------------------------------------------------------------------

main() {
    preflight

    clone_dotfiles              #  5 — clone first so PKG_DIR and CONFIG_SRC exist
    install_pacman_packages     #  1
    install_yay                 #  2
    install_aur_packages        #  3
    install_flatpak_apps        #  4
    deploy_configs              #  6
    create_directories          #  7
    set_default_shell           #  8
    enable_system_services      #  9
    enable_user_services        # 10
    enable_sddm                 # 11
    seed_theme                  # 12
    sync_neovim                 # 13

    final_summary
}

main "$@"
