#!/usr/bin/env bash
# status-check.sh
# Usage: status-check.sh {mic|camera|screenshare}
# Exit 0 -> waybar shows the module. Exit 1 -> waybar hides it.
#
# Used as the "exec-if" for three separate waybar custom modules, each
# calling this same script with a different argument.

MODE="$1"

# PipeWire node.name filter used to detect the portal's screencast stream.
# Adjust if needed — check with:
#   pw-dump | jq -r '.[] | select(.info.props."media.class"=="Video/Source") | .info.props."node.name"'
# while actively sharing your screen.
SHARE_FILTER='xdph|portal|hyprland'

check_mic() {
    # Filter out known non-user source outputs:
    #   cava       — audio visualizer reads the sink monitor as a source output
    #   pipewire   — internal PipeWire nodes
    #   quickshell — the shell itself
    # We look for any source-output block whose application.name or node.name
    # does NOT match those patterns.
    local block app node
    while IFS= read -r line; do
        if [[ "$line" =~ ^Source\ Output ]]; then
            block=""
        fi
        block+="$line"$'\n'
        if [[ "$line" =~ application\.name\ =\ \"([^\"]+)\" ]]; then
            app="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ node\.name\ =\ \"([^\"]+)\" ]]; then
            node="${BASH_REMATCH[1]}"
        fi
        # End of a block — decide
        if [[ "$line" == "" ]] && [[ -n "$block" ]]; then
            local combined="${app}${node}"
            if [[ -n "$combined" ]] && ! echo "$combined" | grep -qiE 'cava|pipewire|quickshell|qs'; then
                return 0
            fi
            app=""; node=""; block=""
        fi
    done < <(pactl list source-outputs 2>/dev/null; echo "")
    return 1
}

check_camera() {
    shopt -s nullglob
    local devices=(/dev/video*)
    for dev in "${devices[@]}"; do
        local pids
        pids=$(fuser "$dev" 2>/dev/null)
        for pid in $pids; do
            local name
            name=$(cat /proc/"$pid"/comm 2>/dev/null)
            # Exclude quickshell and qs from triggering the indicator
            if [[ -n "$name" ]] && ! echo "$name" | grep -qiE 'quickshell|^qs$'; then
                return 0
            fi
        done
    done
    return 1
}


check_screenshare() {
    local active
    active=$(pw-dump 2>/dev/null | jq -e --arg re "$SHARE_FILTER" '
        [.[] | select(.info.props."media.class" == "Video/Source")
             | select((.info.props."node.name" // "") | test($re; "i"))
             | select(.info.state == "running")] | length > 0
    ' 2>/dev/null)
    [ "$active" = "true" ] && return 0
    return 1
}

case "$MODE" in
mic) check_mic ;;
camera) check_camera ;;
screenshare) check_screenshare ;;
*)
    echo "Usage: $0 {mic|camera|screenshare}" >&2
    exit 2
    ;;
esac
