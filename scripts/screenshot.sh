#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# quickshell screenshot helper — Ultra-Low Latency Pipeline
# ─────────────────────────────────────────────────────────────────────────────

timestamp=$(date +'%Y-%m-%d_%H-%M-%S')
mode="${1:---area}"
geom=""
X=0
Y=0
W=1920
H=1080
autoSaved="false"

case "$mode" in
    --now|--full)
        # Fullscreen capture — auto-saved to ~/Pictures/Screenshots
        save_dir="${HOME}/Pictures/Screenshots"
        mkdir -p "$save_dir"
        filename="${save_dir}/Screenshot_${timestamp}.png"
        autoSaved="true"

        grim "$filename" || exit 1
        if command -v hyprctl &>/dev/null; then
            mon_info=$(hyprctl monitors -j 2>/dev/null | grep -E '"(width|height)"' | head -n 2 | awk -F': ' '{print $2}' | tr -d ',')
            if [ -n "$mon_info" ]; then
                W=$(echo "$mon_info" | head -n 1)
                H=$(echo "$mon_info" | tail -n 1)
            fi
        fi
        ;;
    --win|--window)
        # Active window capture — cached to /tmp
        filename="/tmp/qs_screenshot_${timestamp}.png"
        autoSaved="false"

        if command -v hyprctl &>/dev/null; then
            active_win=$(hyprctl activewindow -j 2>/dev/null)
            if [ -n "$active_win" ]; then
                at=$(echo "$active_win" | grep -o '"at": \[[^]]*\]' | tr -d '[]"at: ')
                size=$(echo "$active_win" | grep -o '"size": \[[^]]*\]' | tr -d '[]"size: ')
                X=$(echo "$at" | cut -d',' -f1)
                Y=$(echo "$at" | cut -d',' -f2)
                W=$(echo "$size" | cut -d',' -f1)
                H=$(echo "$size" | cut -d',' -f2)
                geom="${X},${Y} ${W}x${H}"
                grim -g "$geom" "$filename"
            fi
        fi
        if [ ! -f "$filename" ]; then
            geom=$(slurp)
            [ -z "$geom" ] && exit 0
            if [[ "$geom" =~ ([0-9]+),([0-9]+)[[:space:]]+([0-9]+)x([0-9]+) ]]; then
                X="${BASH_REMATCH[1]}"
                Y="${BASH_REMATCH[2]}"
                W="${BASH_REMATCH[3]}"
                H="${BASH_REMATCH[4]}"
            fi
            grim -g "$geom" "$filename" || exit 1
        fi
        ;;
    *)
        # Default: Region selection with slurp — cached to /tmp
        geom=$(slurp)
        [ -z "$geom" ] && exit 0

        filename="/tmp/qs_screenshot_${timestamp}.png"
        autoSaved="false"

        if [[ "$geom" =~ ([0-9]+),([0-9]+)[[:space:]]+([0-9]+)x([0-9]+) ]]; then
            X="${BASH_REMATCH[1]}"
            Y="${BASH_REMATCH[2]}"
            W="${BASH_REMATCH[3]}"
            H="${BASH_REMATCH[4]}"
        fi

        grim -g "$geom" "$filename" || exit 1
        ;;
esac

# Ensure image exists
[ ! -f "$filename" ] && exit 1

# 1. Zero-latency clipboard copy
wl-copy < "$filename" &

# 2. Shutter sound
if [ -f "${HOME}/.config/hypr/scripts/Sounds.sh" ]; then
    "${HOME}/.config/hypr/scripts/Sounds.sh" --screenshot &
fi

# 3. Notify Quickshell IPC
quickshell ipc call screenshot trigger "{\"path\":\"${filename}\",\"x\":${X:-0},\"y\":${Y:-0},\"w\":${W:-1920},\"h\":${H:-1080},\"autoSaved\":${autoSaved}}" 2>/dev/null &
