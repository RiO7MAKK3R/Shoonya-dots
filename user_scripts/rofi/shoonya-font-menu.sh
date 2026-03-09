#!/bin/bash

scripts="$HOME/user_scripts/rofi"

font=$(fc-list :spacing=100 -f "%{family[0]}\n" | sort -u | rofi -dmenu -i -p "Select Font")

if [ -n "$font" ]; then
    "$scripts/shoonya-font-set.sh" "$font"
fi