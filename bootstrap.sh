#!/usr/bin/env bash
# ==============================================================================
# SHOONYA OS — PRODUCTION BOOTSTRAP
# Target: Arch Linux (Fresh Install)
# Mode: Non-interactive, Idempotent
# ==============================================================================

set -euo pipefail

# -------------------------------
# 0. Elevation
# -------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[INFO] Elevating to root..."
    exec sudo "$0" "$@"
fi

# -------------------------------
# 1. Detect Real User
# -------------------------------
REAL_USER="${SUDO_USER:-$(logname)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

echo "[INFO] Real user detected: $REAL_USER"
echo "[INFO] Home directory: $REAL_HOME"

# -------------------------------
# 2. Install Pacman Packages
# -------------------------------
echo "[INFO] Installing pacman packages..."
pacman -Syu --noconfirm --needed - < packages/pacman.txt

# -------------------------------
# 3. Install Paru (if missing)
# -------------------------------
if ! command -v paru &>/dev/null; then
    echo "[INFO] Installing paru..."
    pacman -S --needed --noconfirm base-devel git
    sudo -u "$REAL_USER" git clone https://aur.archlinux.org/paru.git /tmp/paru
    cd /tmp/paru
    sudo -u "$REAL_USER" makepkg -si --noconfirm
    cd /
    rm -rf /tmp/paru
fi

# -------------------------------
# 4. Install AUR Packages
# -------------------------------
echo "[INFO] Installing AUR packages..."
sudo -u "$REAL_USER" paru -S --noconfirm --needed - < packages/aur.txt

# -------------------------------
# 5. Install Flatpaks
# -------------------------------
if [[ -s packages/flatpak.txt ]]; then
    echo "[INFO] Installing Flatpaks..."
    sudo -u "$REAL_USER" flatpak install -y flathub $(cat packages/flatpak.txt)
fi

# -------------------------------
# 6. Copy Configurations
# -------------------------------
echo "[INFO] Copying configs..."
rsync -a configs/ "$REAL_HOME/.config/"
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config"

# -------------------------------
# 7. Enable System Services
# -------------------------------
echo "[INFO] Enabling system services..."
bash user_scripts/install/050_system_services.sh

# -------------------------------
# 8. Enable User Services
# -------------------------------
echo "[INFO] Enabling user services..."
sudo -u "$REAL_USER" bash user_scripts/install/006_enabling_user_services.sh

# -------------------------------
# 9. Qt Theme Enforcement
# -------------------------------
sudo -u "$REAL_USER" bash user_scripts/install/025_qtct_config.sh

# -------------------------------
# 10. Matugen Directories
# -------------------------------
sudo -u "$REAL_USER" bash user_scripts/install/021_matugen_directories.sh

# -------------------------------
# 11. Neovim Lazy Sync
# -------------------------------
sudo -u "$REAL_USER" bash user_scripts/install/047_neovim_lazy_sync.sh

# -------------------------------
# 12. Git Config Setup
# -------------------------------
sudo -u "$REAL_USER" bash user_scripts/install/052_git_config.sh

# -------------------------------
# 13. SDDM Setup (Auto Mode)
# -------------------------------
echo "[INFO] Configuring SDDM..."
bash user_scripts/install/091_sddm_setup.sh --auto

# -------------------------------
# 14. Done
# -------------------------------
echo "================================================="
echo " Shoonya Bootstrap Complete."
echo " Reboot your system now."
echo "================================================="