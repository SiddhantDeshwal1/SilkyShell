#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
# quickshell screenshot helper — Ultra-Low Latency Pipeline
# ─────────────────────────────────────────────────────────────────────────────

# Clean up temporary screenshot files older than 60 minutes
find /tmp -maxdepth 1 -name 'qs_screenshot_*.png' -mmin +60 -delete 2>/dev/null || true

timestamp=$(date +'%Y-%m-%d_%H-%M-%S')
mode="${1:---area}"
geom=""
X=0
Y=0
W=1920
H=1080
autoSaved="false"

run_slurp() {
    if [ -t 0 ]; then
        slurp "$@"
    else
        script -q -c "slurp $(printf '%q ' "$@")" /dev/null 2>/dev/null | tr -d '\r' | head -n 1
    fi
}

case "$mode" in
    --now|--full)
        # Fullscreen capture — auto-saved to ~/Pictures/Screenshots
        save_dir="${HOME}/Pictures/Screenshots"
        mkdir -p "$save_dir"
        filename="${save_dir}/Screenshot_${timestamp}.png"
        autoSaved="true"

        mon_name=""
        if command -v hyprctl &>/dev/null; then
            if command -v jq &>/dev/null; then
                IFS=$'\t' read -r mon_name X Y W H < <(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | "\(.name)\t\(.x)\t\(.y)\t\(.width)\t\(.height)"' 2>/dev/null)
            fi
            if [ -z "$mon_name" ]; then
                mon_info=$(hyprctl monitors -j 2>/dev/null | grep -E '"(width|height)"' | head -n 2 | awk -F': ' '{print $2}' | tr -d ',')
                if [ -n "$mon_info" ]; then
                    W=$(echo "$mon_info" | head -n 1)
                    H=$(echo "$mon_info" | tail -n 1)
                fi
            fi
        fi

        if [ -n "$mon_name" ]; then
            grim -o "$mon_name" "$filename" || grim "$filename" || exit 1
        else
            grim "$filename" || exit 1
        fi
        ;;
    --win|--window)
        # Active window capture — cached to /tmp
        filename="/tmp/qs_screenshot_${timestamp}.png"
        autoSaved="false"

        if command -v hyprctl &>/dev/null; then
            if command -v jq &>/dev/null; then
                IFS=$'\t' read -r X Y W H < <(hyprctl activewindow -j 2>/dev/null | jq -r '"\(.at[0])\t\(.at[1])\t\(.size[0])\t\(.size[1])"' 2>/dev/null)
                if [ -n "$X" ] && [ -n "$W" ] && [ "$W" -gt 0 ]; then
                    geom="${X},${Y} ${W}x${H}"
                    grim -g "$geom" "$filename"
                fi
            else
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
        fi
        if [ ! -f "$filename" ]; then
            geom=$(run_slurp)
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
        geom=$(run_slurp)
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
