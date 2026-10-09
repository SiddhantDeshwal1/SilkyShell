#!/usr/bin/env bash
# waybar-music.sh — Simple music player display
#
# Features:
#   - Music info (artist - title)
#   - Simple music note icon
#   - Minimal overhead: ~2 calls per execution
#

# Check if playerctl is installed
if ! command -v playerctl &>/dev/null; then
    jq -n -c '{text: "", tooltip: "playerctl not installed", class: "music-unavailable"}'
    exit 0
fi

get_music_status() {
    # Get player status
    local status
    status=$(playerctl status 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        # No active player
        jq -n -c '{text: "", tooltip: "No player active", class: "music-stopped"}'
        return
    fi

    # Get metadata
    local title artist
    title=$(playerctl metadata --format '{{title}}' 2>/dev/null)
    artist=$(playerctl metadata --format '{{artist}}' 2>/dev/null)

    # Fallback for missing metadata
    [[ -z "$title" ]] && title="Unknown"
    [[ -z "$artist" ]] && artist="Unknown"

    # Build display string
    local display
    if [[ "$artist" != "Unknown" ]] && [[ "$title" != "Unknown" ]]; then
        display="${artist} - ${title}"
    else
        display="$title"
    fi

    # Truncate to 50 chars max
    if [[ ${#display} -gt 30 ]]; then
        display="${display:0:35}..."
    fi

    # Simple music note icon
    local icon="♪"

    # Determine CSS class based on status
    local class
    if [[ "$status" == "Playing" ]]; then
        class="music-playing"
    else
        class="music-paused"
    fi

    # Build tooltip with status
    local tooltip="${icon} ${status} | ${artist} - ${title}"

    # Format: icon + display
    local final_display=" | ${icon} ${display} | "

    # Output JSON for Waybar
    jq -n -c \
        --arg text "$final_display" \
        --arg tooltip "$tooltip" \
        --arg class "$class" \
        '{text: $text, tooltip: $tooltip, class: $class}'
}

toggle_playback() {
    playerctl play-pause 2>/dev/null
    sleep 0.1
    get_music_status
}

next_track() {
    playerctl next 2>/dev/null
    sleep 0.2
    get_music_status
}

previous_track() {
    playerctl previous 2>/dev/null
    sleep 0.2
    get_music_status
}

# Main routing
case "$1" in
toggle)
    toggle_playback
    ;;
next)
    next_track
    ;;
previous)
    previous_track
    ;;
*)
    get_music_status
    ;;
esac
