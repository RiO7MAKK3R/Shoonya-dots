#!/bin/bash
# screenshot.sh — Click a monitor to screenshot it, then annotate in Satty
#
# Dependencies: hyprshot, satty
#
# Usage (single keybind):
#   screenshot.sh
#     → Move cursor to the monitor you want to capture and click
#     → The entire monitor is captured and opens immediately in Satty
#
# Inside Satty:
#   Ctrl+C   Copy annotated image to clipboard
#   Ctrl+S   Save annotated image to disk
#   Escape   Discard and close
#
# hyprshot -m output captures whichever monitor the cursor is on when clicked.
# --raw writes the PNG bytes to stdout instead of saving a file.
# satty reads from stdin (--filename -) and outputs to stdout (--output-filename -),
# keeping the entire flow in memory with no temporary files.

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_dependencies() {
    local missing=()
    for cmd in hyprshot satty; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        notify-send "screenshot.sh: missing dependencies" \
            "Please install: ${missing[*]}" -u critical -t 5000 2>/dev/null
        echo "Missing dependencies: ${missing[*]}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

check_dependencies

hyprshot -m output --raw | satty --filename - --output-filename -