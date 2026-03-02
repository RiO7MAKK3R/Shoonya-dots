#!/usr/bin/env bash
# ==============================================================================
# SHOONYA OS — PRODUCTION BOOTSTRAP
# Target: Arch Linux (Fresh Install)
# Mode: Non-interactive, Idempotent
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 0. Safety Check
# ------------------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "[ERROR] Do NOT run bootstrap as root."
    echo "Run: bash bootstrap.sh"
    exit 1
fi

REAL_USER="$USER"
REAL_HOME="$HOME"

echo "[INFO] Running bootstrap as: $REAL_USER"
echo

# ------------------------------------------------------------------------------
# 1. Install Pacman Packages
# ------------------------------------------------------------------------------

echo "[STEP 1] Installing pacman packages..."
sudo pacman -Syu --noconfirm --needed - < packages/pacman.txt
echo "[OK] Pacman packages complete."
echo

# ------------------------------------------------------------------------------
# 2. Install Paru (if missing)
# ------------------------------------------------------------------------------

if ! command -v paru &>/dev/null; then
    echo "[STEP 2] Installing paru (AUR helper)..."
    sudo pacman -S --needed --noconfirm base-devel git

    git clone https://aur.archlinux.org/paru.git /tmp/paru
    cd /tmp/paru
    makepkg -si --noconfirm
    cd /
    rm -rf /tmp/paru

    echo "[OK] Paru installed."
    echo
else
    echo "[STEP 2] Paru already installed. Skipping."
    echo
fi

# ------------------------------------------------------------------------------
# 3. Install AUR Packages
# ------------------------------------------------------------------------------

if [[ -s packages/aur.txt ]]; then
    echo "[STEP 3] Installing AUR packages..."
    paru -S --noconfirm --needed - < packages/aur.txt
    echo "[OK] AUR packages complete."
    echo
fi

# ------------------------------------------------------------------------------
# 4. Install Flatpaks
# ------------------------------------------------------------------------------

if [[ -s packages/flatpak.txt ]]; then
    echo "[STEP 4] Installing Flatpaks..."
    flatpak install -y flathub $(cat packages/flatpak.txt)
    echo "[OK] Flatpaks complete."
    echo
fi

# ------------------------------------------------------------------------------
# 5. Copy Configurations
# ------------------------------------------------------------------------------

echo "[STEP 5] Copying configuration files..."
mkdir -p "$REAL_HOME/.config"
rsync -a configs/ "$REAL_HOME/.config/"
echo "[OK] Configs copied."
echo

# ------------------------------------------------------------------------------
# 6. Create Required Directories (Matugen etc.)
# ------------------------------------------------------------------------------

echo "[STEP 6] Creating required directories..."
bash user_scripts/install/021_matugen_directories.sh
echo "[OK] Directories ready."
echo

# ------------------------------------------------------------------------------
# 7. Enforce Qt Theme Config
# ------------------------------------------------------------------------------

echo "[STEP 7] Applying Qt configuration..."
bash user_scripts/install/025_qtct_config.sh
echo "[OK] Qt config applied."
echo

# ------------------------------------------------------------------------------
# 8. Initial Wallpaper + Matugen Seed (CRITICAL)
# ------------------------------------------------------------------------------

echo "[STEP 8] Seeding wallpaper and generating initial color scheme..."

mkdir -p "$REAL_HOME/Pictures/Wallpapers"
cp -f configs/wallpapers/default.png "$REAL_HOME/Pictures/Wallpapers/default.png"

# Start swww daemon temporarily if not running
if ! pgrep -x swww-daemon >/dev/null; then
    swww-daemon &
    sleep 1
fi

# Apply wallpaper
swww img "$REAL_HOME/Pictures/Wallpapers/default.png"

# Generate color files
bash user_scripts/install/086_generate_colorfiles_for_current_wallpaer.sh

echo "[OK] Initial theme generation complete."
echo

# ------------------------------------------------------------------------------
# 9. Enable System Services
# ------------------------------------------------------------------------------

echo "[STEP 9] Enabling system services..."
bash user_scripts/install/050_system_services.sh
echo "[OK] System services configured."
echo

# ------------------------------------------------------------------------------
# 10. Enable User Services
# ------------------------------------------------------------------------------

echo "[STEP 10] Enabling user services..."
bash user_scripts/install/006_enabling_user_services.sh
echo "[OK] User services configured."
echo

# ------------------------------------------------------------------------------
# 11. Neovim Plugin Sync
# ------------------------------------------------------------------------------

echo "[STEP 11] Syncing Neovim plugins..."
bash user_scripts/install/047_neovim_lazy_sync.sh
echo "[OK] Neovim ready."
echo

# ------------------------------------------------------------------------------
# 12. Git Configuration
# ------------------------------------------------------------------------------

echo "[STEP 12] Applying Git configuration..."
bash user_scripts/install/052_git_config.sh
echo "[OK] Git configured."
echo

# ------------------------------------------------------------------------------
# 13. SDDM Setup (Auto Mode)
# ------------------------------------------------------------------------------

echo "[STEP 13] Configuring SDDM..."
bash user_scripts/install/091_sddm_setup.sh --auto
echo "[OK] SDDM configured."
echo

# ------------------------------------------------------------------------------
# DONE
# ------------------------------------------------------------------------------

echo "================================================="
echo " Shoonya Bootstrap Complete."
echo " Reboot your system now."
echo "================================================="