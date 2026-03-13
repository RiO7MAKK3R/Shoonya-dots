#!/bin/bash
# screenrecord.sh — Single-keybind screen recording toggle for Arch Linux + Hyprland
#
# Dependencies: wf-recorder, slurp, hyprctl, jq, ffmpeg, notify-send
# Optional:     hyprpicker (crosshair overlay during monitor selection)
#
# Usage (one keybind does everything):
#
#   screenrecord.sh
#     → If not recording: show monitor picker, click a screen, start recording
#     → If recording:     stop recording cleanly
#     → If picker open:   cancel selection and exit
#
# Output: ~/Videos/screenrecording-YYYY-MM-DD_HH-MM-SS.mp4

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

readonly OUTPUT_DIR="$HOME/Videos"
readonly RECORDING_FILE="/tmp/screenrecord-filename"   # stores active filepath during recording
readonly FPS=30
readonly ENCODER="libx264"
readonly ENCODER_PRESET="ultrafast"   # skip heavy motion-estimation; essential on Intel HD 3000
readonly ENCODER_CRF=18               # near-lossless quality; sharpens tutorial text cheaply

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_dependencies() {
    local missing=()
    for cmd in wf-recorder slurp hyprctl jq ffmpeg notify-send; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        notify-send "screenrecord.sh: missing dependencies" \
            "Please install: ${missing[*]}" -u critical -t 5000
        echo "Missing dependencies: ${missing[*]}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Output directory — created automatically if absent
# ---------------------------------------------------------------------------

ensure_output_dir() {
    mkdir -p "$OUTPUT_DIR" || {
        notify-send "screenrecord.sh: cannot create output directory" \
            "$OUTPUT_DIR" -u critical -t 4000
        echo "Failed to create output directory: $OUTPUT_DIR" >&2
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Toggle detection
# ---------------------------------------------------------------------------

# Returns 0 (true) if wf-recorder is currently running
recording_active() {
    pgrep -x wf-recorder &>/dev/null
}

# ---------------------------------------------------------------------------
# Waybar indicator (optional)
# ---------------------------------------------------------------------------
# Sends RTMIN+8 so a Waybar custom module can toggle a recording icon.
# Silently ignored when Waybar is not running.

signal_waybar() {
    pkill -RTMIN+8 waybar 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Monitor geometry
# ---------------------------------------------------------------------------

# jq snippet — handles portrait/rotated displays (transforms 1 and 3 swap W/H)
readonly JQ_MONITOR_GEO='
    def format_geo:
        .x as $x | .y as $y |
        (.width  / .scale | floor) as $w |
        (.height / .scale | floor) as $h |
        .transform as $t |
        if $t == 1 or $t == 3 then
            "\($x),\($y) \($h)x\($w)"
        else
            "\($x),\($y) \($w)x\($h)"
        end;
'

# Emit one "X,Y WxH" line per connected monitor
get_all_monitor_geos() {
    hyprctl monitors -j | jq -r "${JQ_MONITOR_GEO} .[] | format_geo"
}

# ---------------------------------------------------------------------------
# Monitor selection
# ---------------------------------------------------------------------------
# Pipes all monitor geometries into slurp -r (restricted/snap-only mode).
# The user clicks anywhere on a screen; slurp snaps the selection to that
# monitor's full geometry and returns "X,Y WxH".
#
# A bare click reliably returns a full monitor rectangle — not a near-zero
# region — because -r prevents slurp from accepting freehand selections.
#
# A crosshair overlay is shown via hyprpicker while the picker is open.
# If the keybind fires again while slurp is waiting, selection is cancelled.

select_monitor() {
    # Double-press to cancel: kill slurp if it is already waiting for input
    pgrep -x slurp >/dev/null && pkill -x slurp && exit 0

    # Show crosshair overlay while the user is picking (optional dependency)
    local picker_pid=""
    if command -v hyprpicker &>/dev/null; then
        hyprpicker -r -z >/dev/null 2>&1 &
        picker_pid=$!
        sleep 0.1   # let hyprpicker grab the cursor before slurp opens
    fi

    # Present monitor rectangles; user clicks one screen to select it
    local region
    region=$(get_all_monitor_geos | slurp -r 2>/dev/null)

    # Always clean up hyprpicker regardless of how slurp exited
    [[ -n $picker_pid ]] && kill "$picker_pid" 2>/dev/null

    echo "$region"
}

# ---------------------------------------------------------------------------
# Start recording
# ---------------------------------------------------------------------------

start_recording() {
    local region
    region=$(select_monitor)

    # Empty string means the user cancelled (Escape or double-press)
    if [[ -z $region ]]; then
        exit 0
    fi

    local filename="$OUTPUT_DIR/screenrecording-$(date +'%Y-%m-%d_%H-%M-%S').mp4"

    # Launch wf-recorder in the background.
    #   -g  capture geometry returned by slurp
    #   -r  framerate
    #   -c  video codec
    #   -p  preset=ultrafast  — minimises CPU usage on weak hardware
    #   -p  crf=18            — near-lossless; sharpens on-screen text for tutorials
    #   -f  output file
    wf-recorder \
        -g "$region" \
        -r "$FPS" \
        -c "$ENCODER" \
        -s 1920x1080 \
        -p "preset=$ENCODER_PRESET" \
        -p "crf=$ENCODER_CRF" \
        -p "pix_fmt=yuv444p" \
        -p "tune=zerolatency" \
        -f "$filename" &>/dev/null &
    local pid=$!

    # Give wf-recorder up to 0.5 s to initialise, then verify it is still alive
    sleep 0.5
    if ! kill -0 "$pid" 2>/dev/null; then
        notify-send "Screen recording failed to start" \
            "wf-recorder exited unexpectedly. Check the region or codec." \
            -u critical -t 5000
        exit 1
    fi

    echo "$filename" > "$RECORDING_FILE"
    signal_waybar
    notify-send "Screen recording started" \
        "Saving to: $(basename "$filename")" -t 3000
}

# ---------------------------------------------------------------------------
# Stop recording
# ---------------------------------------------------------------------------

stop_recording() {
    # SIGINT tells wf-recorder to flush all buffered frames and close the
    # MP4 container properly. SIGTERM or SIGKILL will produce a broken file.
    pkill -SIGINT wf-recorder

    # Wait up to 5 seconds for wf-recorder to exit on its own
    local count=0
    while recording_active && (( count < 50 )); do
        sleep 0.1
        count=$(( count + 1 ))
    done

    # Force-kill only as a last resort
    if recording_active; then
        pkill -9 wf-recorder
        notify-send "Screen recording error" \
            "Process had to be force-killed. Video may be corrupted." \
            -u critical -t 5000
        rm -f "$RECORDING_FILE"
        signal_waybar
        exit 1
    fi

    local filename
    filename=$(cat "$RECORDING_FILE" 2>/dev/null)
    rm -f "$RECORDING_FILE"

    signal_waybar

    if [[ -z $filename || ! -f $filename ]]; then
        notify-send "Screen recording error" \
            "Could not locate the recording file." -u critical -t 4000
        exit 1
    fi

    trim_first_frame   "$filename"
    generate_thumbnail "$filename"
    send_notification  "$filename"
}

# ---------------------------------------------------------------------------
# Post-processing helpers
# ---------------------------------------------------------------------------

# Trim ~0.1 s from the start to drop the black Wayland initialisation frame
# that wf-recorder produces before the first real frame arrives.
trim_first_frame() {
    local file="$1"
    local trimmed="${file%.mp4}-trimmed.mp4"

    if ffmpeg -y -ss 0.1 -i "$file" -c copy "$trimmed" -loglevel quiet 2>/dev/null; then
        mv "$trimmed" "$file"
    else
        rm -f "$trimmed"
        # Non-fatal: keep the original if trimming fails
    fi
}

# Extract one frame at ~0.1 s as a PNG for use as the notification icon.
# Sets the module-level THUMBNAIL variable; send_notification cleans it up.
generate_thumbnail() {
    local file="$1"
    THUMBNAIL="${file%.mp4}-preview.png"

    ffmpeg -y \
        -i "$file" \
        -ss 00:00:00.1 \
        -vframes 1 \
        -q:v 2 \
        "$THUMBNAIL" \
        -loglevel quiet 2>/dev/null || THUMBNAIL=""
}

# Notify the user; clicking the notification opens the video with xdg-open.
send_notification() {
    local file="$1"
    local icon="${THUMBNAIL:-$file}"

    (
        local action
        action=$(notify-send \
            "Screen recording saved" \
            "$(basename "$file")" \
            -i "$icon" \
            -t 10000 \
            -A "open=Open video")
        [[ $action == "open" ]] && xdg-open "$file"
        [[ -n $THUMBNAIL ]] && rm -f "$THUMBNAIL"
    ) &
}

# ---------------------------------------------------------------------------
# Main — single entry point, one keybind
# ---------------------------------------------------------------------------

main() {
    check_dependencies
    ensure_output_dir

    if recording_active; then
        stop_recording
    else
        start_recording
    fi
}

main "$@"