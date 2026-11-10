#!/usr/bin/env bash
# set-wallpaper.sh — Wallpaper-only transition script using wallfx & awww
set -uo pipefail

IMG="${1:-}"
TARGET_SCREEN="${2:-}"

if [ -z "$IMG" ]; then
    echo "Usage: $(basename "$0") <image> [screen]" >&2
    exit 1
fi

if [ ! -f "$IMG" ]; then
    echo "Error: File not found: $IMG" >&2
    exit 1
fi

IMG="$(realpath -- "$IMG")" || exit 1

# If TARGET_SCREEN is not specified, auto-detect the focused monitor in Hyprland
if [ -z "$TARGET_SCREEN" ]; then
    TARGET_SCREEN="$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused).name' 2>/dev/null || true)"
fi

# Serialise runs with flock on runtime lock (3s timeout prevents concurrent spikes)
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/set-wallpaper.lock"
if exec 9>"$LOCK_FILE" 2>/dev/null; then
    flock -w 3 9 || {
        echo "[set-wallpaper] Another instance is running, skipping." >&2
        exit 0
    }
fi

# Query currently displaying wallpaper via awww for the target screen
if [ -n "$TARGET_SCREEN" ]; then
    OLD_IMG="$(awww query 2>/dev/null | grep -E "^: *${TARGET_SCREEN}:" | sed -n 's/.*currently displaying: image: //p' | head -n1)"
else
    OLD_IMG="$(awww query 2>/dev/null | sed -n 's/.*currently displaying: image: //p' | head -n1)"
fi

# If already displaying this exact image on this screen, nothing to do
if [ "$OLD_IMG" = "$IMG" ]; then
    exit 0
fi

# Query transition via wallfx daemon (fastest) or fallback to CLI wallfx
selection=""
DAEMON_SOCK="${XDG_RUNTIME_DIR:-/tmp}/wallfx-daemon.sock"

if [ -S "$DAEMON_SOCK" ]; then
    # Query wallfx daemon via socket with 8s timeout
    selection="$(python3 -c '
import socket, sys
try:
    sock_path = sys.argv[1]
    img_path = sys.argv[2]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(8.0)
    s.connect(sock_path)
    s.sendall(f"PREPARE {img_path}\n".encode("utf-8"))
    line = s.makefile("r", encoding="utf-8").readline().strip()
    s.close()
    if line and (line.startswith("perfil ") or line.startswith("contagio ")):
        print(line)
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
' "$DAEMON_SOCK" "$IMG" 2>/dev/null)" || selection=""
fi

# Fallback to CLI wallfx if daemon not responsive or not found
if [ -z "$selection" ] && [ -x "$HOME/.local/bin/wallfx" ]; then
    selection="$("$HOME/.local/bin/wallfx" elige "$IMG" 2>/dev/null 9>&-)"
fi

wallfx_ok=""
if [ -n "$OLD_IMG" ] && [ -f "$OLD_IMG" ] && [ -n "$selection" ]; then
    read -r wfx_kind wfx_map wfx_line <<<"$selection"
    if [ "$(qs ipc call wallfx play "$OLD_IMG" "$IMG" "$wfx_kind" "$wfx_map" "${wfx_line:-$wfx_map}" "$TARGET_SCREEN" 2>/dev/null)" = "ok" ]; then
        wallfx_ok=1
    fi
fi

# Fallback if Quickshell IPC fails or target not available
if [ -z "$wallfx_ok" ]; then
    outputs_flag=()
    if [ -n "$TARGET_SCREEN" ]; then
        outputs_flag=(--outputs "$TARGET_SCREEN")
    fi
    awww img "$IMG" "${outputs_flag[@]}" --resize crop --filter Lanczos3 --transition-type fade --transition-duration 0.5 >/dev/null 2>&1 \
        || awww img "$IMG" "${outputs_flag[@]}" --resize crop --filter Lanczos3 >/dev/null 2>&1 || true
fi

# Live dynamic theming for Kitty, GTK/Thunar, and Quickshell (backgrounded, fd 9 closed)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/apply-theme.py" ]; then
    nice -n 10 python3 "$SCRIPT_DIR/apply-theme.py" "$IMG" >/dev/null 2>&1 9>&- &
fi

# Background warm-up (lowest CPU & IO priority)
if [ -x "$HOME/.local/bin/wallfx" ]; then
    nice -n 19 ionice -c 3 "$HOME/.local/bin/wallfx" warm >/dev/null 2>&1 9>&- &
fi

exit 0
