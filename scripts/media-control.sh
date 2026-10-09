#!/usr/bin/env bash
ACTION="$1"
PLAYER="$2"
VALUE="$3"

# Strip org.mpris.MediaPlayer2. prefix if present
PLAYER="${PLAYER#org.mpris.MediaPlayer2.}"

P_FLAG=()
if [ -n "$PLAYER" ]; then
    P_FLAG=("-p" "$PLAYER")
fi

case "$ACTION" in
    next)
        if [ -n "$PLAYER" ]; then
            playerctl "${P_FLAG[@]}" next 2>/dev/null || true
        else
            playerctl next 2>/dev/null || true
        fi
        ;;
    prev|previous)
        if [ -n "$PLAYER" ]; then
            playerctl "${P_FLAG[@]}" previous 2>/dev/null || true
        else
            playerctl previous 2>/dev/null || true
        fi
        ;;
    play-pause|toggle)
        if [ -n "$PLAYER" ]; then
            playerctl "${P_FLAG[@]}" play-pause 2>/dev/null || true
        else
            playerctl play-pause 2>/dev/null || true
        fi
        ;;
    play)
        if [ -n "$PLAYER" ]; then
            playerctl "${P_FLAG[@]}" play 2>/dev/null || true
        else
            playerctl play 2>/dev/null || true
        fi
        ;;
    pause)
        if [ -n "$PLAYER" ]; then
            playerctl "${P_FLAG[@]}" pause 2>/dev/null || true
        else
            playerctl pause 2>/dev/null || true
        fi
        ;;
    set-volume)
        if [ -n "$PLAYER" ]; then
            playerctl "${P_FLAG[@]}" volume "$VALUE" 2>/dev/null || true
        else
            playerctl volume "$VALUE" 2>/dev/null || true
        fi
        ;;
    set-position)
        if [ -n "$PLAYER" ]; then
            playerctl "${P_FLAG[@]}" position "$VALUE" 2>/dev/null || true
        else
            playerctl position "$VALUE" 2>/dev/null || true
        fi
        ;;
    get-info)
        STATUS=$(playerctl "${P_FLAG[@]}" status 2>/dev/null || true)
        STATUS="${STATUS:-Stopped}"
        
        # Query live position directly (in seconds)
        DIR_POS=$(playerctl "${P_FLAG[@]}" position 2>/dev/null || true)
        POS="0.00"
        if [ -n "$DIR_POS" ]; then
            POS=$(awk -v p="$DIR_POS" 'BEGIN { printf "%.2f", (p > 0 ? p : 0) }')
        fi

        # Query metadata for duration and volume
        RAW_META=$(playerctl "${P_FLAG[@]}" metadata --format '{{mpris:length}}|{{volume}}' 2>/dev/null || true)
        LEN="0.00"
        VOL="1.0"
        if [ -n "$RAW_META" ]; then
            IFS='|' read -r LEN_US VOL_RAW <<< "$RAW_META"
            if [ -n "$LEN_US" ]; then
                LEN=$(awk -v l="$LEN_US" 'BEGIN { printf "%.2f", (l > 0 ? l / 1000000 : 0) }')
            fi
            if [ -n "$VOL_RAW" ]; then
                VOL="$VOL_RAW"
            fi
        fi

        echo "$STATUS $POS $LEN $VOL"
        ;;
    get-metadata)
        RAW=$(playerctl "${P_FLAG[@]}" metadata --format '{{xesam:title}};;;{{xesam:artist}};;;{{mpris:artUrl}}' 2>/dev/null || true)
        if [ -z "$RAW" ] && [ -z "$PLAYER" ]; then
            RAW=$(playerctl metadata --format '{{xesam:title}};;;{{xesam:artist}};;;{{mpris:artUrl}}' 2>/dev/null || true)
        fi
        echo "$RAW"
        ;;
esac
