#!/bin/bash

font_name="$1"

if [[ -z "$font_name" ]]; then
    echo "Usage: shoonya-font-set <font-name>"
    exit 1
fi

if ! fc-list | grep -iq "$font_name"; then
    echo "Font '$font_name' not found."
    exit 1
fi

# Kitty
if [[ -f ~/.config/kitty/kitty.conf ]]; then
    sed -i "s/^font_family.*/font_family $font_name/g" ~/.config/kitty/kitty.conf
    pkill -USR1 kitty
fi

# Waybar
if [[ -f ~/.config/waybar/style.css ]]; then
    sed -i "s/font-family:.*/font-family: '$font_name';/g" ~/.config/waybar/style.css
fi

# SwayNC
if [[ -f ~/.config/swaync/style.css ]]; then
    sed -i "s/font-family:.*/font-family: '$font_name';/g" ~/.config/swaync/style.css
fi

# Hyprlock
if [[ -f ~/.config/hypr/hyprlock.conf ]]; then
    sed -i "s/font_family = .*/font_family = $font_name/g" ~/.config/hypr/hyprlock.conf
fi

# Fontconfig (global monospace override)
mkdir -p ~/.config/fontconfig

cat > ~/.config/fontconfig/fonts.conf <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
 <match target="pattern">
  <test name="family"><string>monospace</string></test>
  <edit name="family" mode="assign" binding="strong">
   <string>$font_name</string>
  </edit>
 </match>
</fontconfig>
EOF

fc-cache -fv

# Reload UI
pkill waybar
sleep 1
uwsm-app -- waybar

pkill swaync
swaync &

notify-send "Shoonya Font" "Font changed to $font_name"