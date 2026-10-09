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
        RAW=$(playerctl "${P_FLAG[@]}" metadata --format '{{status}} {{position}} {{mpris:length}} {{volume}}' 2>/dev/null || true)
        if [ -z "$RAW" ] && [ -z "$PLAYER" ]; then
            RAW=$(playerctl metadata --format '{{status}} {{position}} {{mpris:length}} {{volume}}' 2>/dev/null || true)
        fi
        if [ -n "$RAW" ]; then
            read -r STATUS POS_US LEN_US VOL <<< "$RAW"
            POS=$(awk -v p="${POS_US:-0}" 'BEGIN { printf "%.2f", (p > 0 ? p / 1000000 : 0) }')
            LEN=$(awk -v l="${LEN_US:-0}" 'BEGIN { printf "%.2f", (l > 0 ? l / 1000000 : 0) }')
            
            # Fallback for direct position query if metadata template position was empty or 0
            if [ -z "$POS" ] || [ "$POS" = "0.00" ]; then
                DIR_POS=$(playerctl "${P_FLAG[@]}" position 2>/dev/null || true)
                if [ -n "$DIR_POS" ]; then
                    POS=$(awk -v p="$DIR_POS" 'BEGIN { printf "%.2f", (p > 0 ? p : 0) }')
                fi
            fi

            # Fallback for length if metadata template length was empty or 0
            if [ -z "$LEN" ] || [ "$LEN" = "0.00" ]; then
                DIR_LEN=$(playerctl "${P_FLAG[@]}" metadata mpris:length 2>/dev/null || true)
                if [ -n "$DIR_LEN" ]; then
                    LEN=$(awk -v l="$DIR_LEN" 'BEGIN { printf "%.2f", (l > 0 ? l / 1000000 : 0) }')
                fi
            fi

            VOL="${VOL:-1.0}"
            STATUS="${STATUS:-Playing}"
            echo "$STATUS $POS $LEN $VOL"
        else
            echo "Stopped 0.00 0.00 1.00"
        fi
        ;;
esac
