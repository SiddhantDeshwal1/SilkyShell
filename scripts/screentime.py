#!/usr/bin/env python3
import json
import os
import sys
import time
import socket
import subprocess
from pathlib import Path
from datetime import datetime

CACHE_DIR = Path("/home/banana/.cache/quickshell")
DATA_FILE = CACHE_DIR / "screentime.json"

APP_NAMES = {
    "google-chrome": "Google Chrome",
    "chrome": "Google Chrome",
    "chromium": "Chromium",
    "firefox": "Firefox",
    "antigravity": "Antigravity",
    "code": "VS Code",
    "code-oss": "VS Code",
    "vscodium": "VSCodium",
    "kitty": "Kitty Terminal",
    "foot": "Foot Terminal",
    "alacritty": "Alacritty",
    "wezterm": "WezTerm",
    "spotify": "Spotify",
    "discord": "Discord",
    "slack": "Slack",
    "telegram-desktop": "Telegram",
    "org.kde.dolphin": "Dolphin",
    "nautilus": "Files",
    "thunar": "Thunar",
    "vlc": "VLC Media Player",
    "mpv": "MPV Player",
    "steam": "Steam",
    "obs": "OBS Studio"
}

PALETTE = [
    "#3b82f6",  # iOS Blue
    "#06b6d4",  # Cyan
    "#10b981",  # Emerald Green
    "#8b5cf6",  # Purple
    "#f59e0b",  # Amber
    "#ec4899",  # Pink
    "#64748b",  # Slate Grey
]

def format_duration(seconds):
    if seconds <= 0:
        return "0m"
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    if hours > 0:
        return f"{hours}h {minutes:02d}m" if minutes > 0 else f"{hours}h"
    return f"{minutes}m"

def load_data():
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    today = datetime.now().strftime("%Y-%m-%d")
    if DATA_FILE.exists():
        try:
            with open(DATA_FILE, "r") as f:
                data = json.load(f)
                if data.get("date") == today:
                    apps_raw = data.get("apps", {})
                    apps_dict = {}
                    if isinstance(apps_raw, dict):
                        apps_dict = apps_raw
                    elif isinstance(apps_raw, list):
                        for item in apps_raw:
                            if isinstance(item, dict) and "id" in item and "seconds" in item:
                                apps_dict[item["id"]] = item["seconds"]
                    return {
                        "date": today,
                        "totalSeconds": data.get("totalSeconds", 0),
                        "apps": apps_dict
                    }
        except Exception:
            pass
    return {
        "date": today,
        "totalSeconds": 0,
        "apps": {}
    }

def format_payload(raw_data):
    today = datetime.now().strftime("%Y-%m-%d")
    if raw_data.get("date") != today:
        raw_data = {"date": today, "totalSeconds": 0, "apps": {}}

    total_sec = raw_data.get("totalSeconds", 0)
    hours = total_sec // 3600
    minutes = (total_sec % 3600) // 60

    apps_dict = raw_data.get("apps", {})
    sorted_apps = sorted(apps_dict.items(), key=lambda x: x[1], reverse=True)

    formatted_apps = []
    for idx, (app_id, secs) in enumerate(sorted_apps):
        color = PALETTE[idx % len(PALETTE)]
        name = APP_NAMES.get(app_id.lower(), app_id.capitalize())
        percent = round((secs / total_sec * 100)) if total_sec > 0 else 0
        formatted_apps.append({
            "id": app_id,
            "name": name,
            "seconds": secs,
            "formatted": format_duration(secs),
            "percent": percent,
            "color": color,
            "icon": app_id
        })

    return {
        "date": today,
        "totalSeconds": total_sec,
        "hours": hours,
        "minutes": minutes,
        "hoursStr": str(hours),
        "minutesStr": f"{minutes:02d}" if hours > 0 else str(minutes),
        "totalFormatted": f"{hours}h {minutes:02d}m" if hours > 0 else f"{minutes}m",
        "apps": formatted_apps
    }

def save_data(raw_data):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = format_payload(raw_data)
    tmp_file = DATA_FILE.with_suffix(".tmp")
    with open(tmp_file, "w") as f:
        json.dump(payload, f, indent=2)
    os.replace(tmp_file, DATA_FILE)
    return payload

def is_screen_locked():
    """Scan /proc/<pid>/comm directly — no subprocess spawn needed."""
    try:
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open(f"/proc/{pid}/comm") as f:
                    if f.read().strip() == "hyprlock":
                        return True
            except OSError:
                continue
    except Exception:
        pass
    return False

def get_active_window_class():
    """Query Hyprland via its IPC Unix socket — no subprocess spawn needed."""
    try:
        sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        if not sig:
            # Fallback: scan /tmp/hypr/ for the signature directory
            hypr_dir = Path("/tmp/hypr")
            if hypr_dir.exists():
                sigs = [d.name for d in hypr_dir.iterdir() if d.is_dir()]
                if sigs:
                    sig = sigs[0]
        if not sig:
            return ""
        # Try XDG_RUNTIME_DIR path first, then /tmp/hypr fallback
        uid = os.getuid()
        for sock_path in [
            f"/run/user/{uid}/hypr/{sig}/.socket.sock",
            f"/tmp/hypr/{sig}/.socket.sock",
        ]:
            if not os.path.exists(sock_path):
                continue
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(0.5)
                s.connect(sock_path)
                s.send(b"j/activewindow")
                chunks = []
                while True:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    chunks.append(chunk)
            data = b"".join(chunks)
            if data:
                info = json.loads(data.decode())
                cls = info.get("class") or info.get("initialClass") or ""
                return cls.strip()
    except Exception:
        pass
    return ""

def run_daemon():
    raw_data = load_data()
    # Save once on start so JSON is populated
    save_data(raw_data)

    tick_interval = 5.0
    flush_counter = 0

    while True:
        try:
            today = datetime.now().strftime("%Y-%m-%d")
            if raw_data.get("date") != today:
                raw_data = {"date": today, "totalSeconds": 0, "apps": {}}

            if not is_screen_locked():
                app_class = get_active_window_class()
                if app_class and app_class != "null":
                    raw_data["totalSeconds"] = raw_data.get("totalSeconds", 0) + int(tick_interval)
                    apps = raw_data.setdefault("apps", {})
                    apps[app_class] = apps.get(app_class, 0) + int(tick_interval)

            flush_counter += 1
            # Save to disk every 3 ticks (every 15 seconds)
            if flush_counter >= 3:
                save_data(raw_data)
                flush_counter = 0

        except Exception as e:
            pass

        time.sleep(tick_interval)

def main():
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "daemon":
            run_daemon()
            return
        elif cmd == "reset":
            raw_data = {"date": datetime.now().strftime("%Y-%m-%d"), "totalSeconds": 0, "apps": {}}
            out = save_data(raw_data)
            print(json.dumps(out, indent=2))
            return
        elif cmd == "get":
            if DATA_FILE.exists():
                try:
                    with open(DATA_FILE, "r") as f:
                        print(f.read().strip())
                        return
                except Exception:
                    pass
            raw_data = load_data()
            out = format_payload(raw_data)
            print(json.dumps(out))
            return
    # Default to get
    if DATA_FILE.exists():
        try:
            with open(DATA_FILE, "r") as f:
                print(f.read().strip())
                return
        except Exception:
            pass
    raw_data = load_data()
    out = format_payload(raw_data)
    print(json.dumps(out))

if __name__ == "__main__":
    main()
