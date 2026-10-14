#!/usr/bin/env bash
# File opener and terminal spawner for Quickshell Spotlight.
# Safely detaches from parent process using setsid.

ACTION="$1" # "open" or "terminal"
TARGET="$2" # file or folder path

if [ -z "$TARGET" ]; then
    exit 0
fi

if [ "$ACTION" = "terminal" ]; then
    if [ -d "$TARGET" ]; then
        DIR="$TARGET"
    else
        DIR=$(dirname "$TARGET")
    fi

    if [ ! -d "$DIR" ]; then
        DIR="$HOME"
    fi

    if command -v kitty >/dev/null 2>&1; then
        setsid -f kitty --directory "$DIR" >/dev/null 2>&1
    elif command -v alacritty >/dev/null 2>&1; then
        setsid -f alacritty --working-directory "$DIR" >/dev/null 2>&1
    elif command -v foot >/dev/null 2>&1; then
        setsid -f foot -D "$DIR" >/dev/null 2>&1
    else
        setsid -f xdg-terminal-exec >/dev/null 2>&1
    fi
else
    # Default: Open file with default desktop handler via xdg-open
    setsid -f xdg-open "$TARGET" >/dev/null 2>&1
fi
