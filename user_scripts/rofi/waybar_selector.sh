#!/usr/bin/env bash

CONFIG_ROOT="$HOME/.config/waybar"

themes=()
display=()

for dir in "$CONFIG_ROOT"/*/; do
    dir="${dir%/}"
    
    if [[ -f "$dir/config.jsonc" ]]; then
        name="${dir##*/}"
        themes+=("$name")
        
        # Replace underscores with spaces for display
        clean_name=$(echo "${name//_/ }" | sed 's/\b\(.\)/\u\1/g')
        display+=("$clean_name")
    fi
done

chosen=$(printf "%s\n" "${display[@]}" | rofi -dmenu -p "Waybar Theme")

[ -z "$chosen" ] && exit

# Convert display name back to original
for i in "${!display[@]}"; do
    if [[ "${display[$i]}" == "$chosen" ]]; then
        theme="${themes[$i]}"
        break
    fi
done

theme_path="$CONFIG_ROOT/$theme"

rm -f "$CONFIG_ROOT/config.jsonc" "$CONFIG_ROOT/style.css"

ln -snf "$theme_path/config.jsonc" "$CONFIG_ROOT/config.jsonc"

[[ -f "$theme_path/style.css" ]] && \
ln -snf "$theme_path/style.css" "$CONFIG_ROOT/style.css"

pkill waybar
uwsm-app -- waybar &
