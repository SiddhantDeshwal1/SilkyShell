#!/usr/bin/env python3
"""
brightness-control.py — High-speed, responsive brightness manager for Quickshell & Hyprland.

Features:
  - Immediate 10-point stepping on keypress (zero lag, instant hardware update).
  - True display power-off at level 0 via Hyprland DPMS + backlight unpowering.
  - Automatically suppresses mouse_move_enables_dpms when display is turned off so
    mouse jitter/touchpad drag does not immediately wake it up.
  - Clean restore of DPMS and mouse wake settings when brightness is increased.
"""

import os
import sys
import glob
import subprocess

STATE_FILE = "/tmp/quickshell_brightness_last.txt"
OFF_FILE = "/tmp/quickshell_display_is_off"

def get_backlight_device():
    devices = glob.glob("/sys/class/backlight/*")
    if not devices:
        return None
    for d in devices:
        if "amdgpu" in d or "intel" in d:
            return d
    return devices[0]

def is_display_off():
    return os.path.exists(OFF_FILE)

def get_brightness_info():
    if is_display_off():
        return 0, 100, 0

    bdir = get_backlight_device()
    if bdir:
        try:
            with open(os.path.join(bdir, "brightness"), "r") as f:
                curr = int(f.read().strip())
            with open(os.path.join(bdir, "max_brightness"), "r") as f:
                max_b = int(f.read().strip())
            pct = round((curr / max_b) * 100) if max_b > 0 else 0
            return curr, max_b, pct
        except Exception:
            pass

    try:
        out = subprocess.check_output(["brightnessctl", "-m"]).decode().strip()
        parts = out.split(",")
        if len(parts) >= 5:
            curr = int(parts[2])
            pct = int(parts[3].replace("%", "").strip())
            max_b = int(parts[4])
            return curr, max_b, pct
    except Exception:
        pass
    return 0, 100, 0

def save_last_on_brightness(pct):
    if pct > 0:
        try:
            with open(STATE_FILE, "w") as f:
                f.write(str(int(pct)))
        except Exception:
            pass

def get_last_on_brightness(default=50):
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                val = int(f.read().strip())
                if val > 0:
                    return val
        except Exception:
            pass
    return default

def turn_display_off():
    # 1. Mark state
    try:
        with open(OFF_FILE, "w") as f:
            f.write("1")
    except Exception:
        pass

    # 2. Disable mouse_move_enables_dpms in Hyprland so releasing mouse / moving won't cancel off
    subprocess.run(["hyprctl", "eval", "hl.config({ misc = { mouse_move_enables_dpms = false } })"], capture_output=True)

    # 3. Cut display power via DPMS (turns off all connected monitors: eDP-1, HDMI, etc.)
    subprocess.run(["hyprctl", "dispatch", 'hl.dsp.dpms("off")'], capture_output=True)

    # 4. Set backlight sysfs to 0
    subprocess.run(["brightnessctl", "-q", "s", "0%"])

def turn_display_on(target_pct=10):
    # 1. Clear off marker
    if os.path.exists(OFF_FILE):
        try:
            os.remove(OFF_FILE)
        except Exception:
            pass

    target_pct = max(10, min(100, int(round(target_pct))))

    # 2. Turn DPMS on (powers on panels)
    subprocess.run(["hyprctl", "dispatch", 'hl.dsp.dpms("on")'], capture_output=True)

    # 3. Restore normal mouse_move_enables_dpms
    subprocess.run(["hyprctl", "eval", "hl.config({ misc = { mouse_move_enables_dpms = true } })"], capture_output=True)

    # 4. Set target backlight level
    subprocess.run(["brightnessctl", "-q", "s", f"{target_pct}%"])
    save_last_on_brightness(target_pct)

def set_brightness(target_pct):
    target = int(round(float(target_pct)))
    if target <= 0:
        turn_display_off()
    else:
        if is_display_off():
            turn_display_on(target)
        else:
            subprocess.run(["brightnessctl", "-q", "s", f"{target}%"])
            save_last_on_brightness(target)

def step_down(step=10):
    if is_display_off():
        return

    _, _, cur_pct = get_brightness_info()
    if cur_pct <= step:
        # At or below minimum level (e.g. 10%): turn display completely off
        turn_display_off()
    else:
        # Immediately drop 10 points
        target = max(step, round((cur_pct - step) / step) * step)
        subprocess.run(["brightnessctl", "-q", "s", f"{target}%"])
        save_last_on_brightness(target)

def step_up(step=10):
    if is_display_off():
        # Turn display back on immediately to minimum level (10%)
        turn_display_on(step)
        return

    _, _, cur_pct = get_brightness_info()
    if cur_pct <= 0:
        turn_display_on(step)
        return

    # Immediately raise 10 points
    target = min(100, round((cur_pct + step) / step) * step)
    subprocess.run(["brightnessctl", "-q", "s", f"{target}%"])
    save_last_on_brightness(target)

def toggle_off():
    if is_display_off():
        target = get_last_on_brightness(default=50)
        turn_display_on(target)
    else:
        _, _, cur_pct = get_brightness_info()
        save_last_on_brightness(cur_pct)
        turn_display_off()

def main():
    if len(sys.argv) < 2 or sys.argv[1] == "get":
        _, _, pct = get_brightness_info()
        print(pct)
        return

    cmd = sys.argv[1]
    if cmd == "set":
        if len(sys.argv) >= 3:
            try:
                val = float(sys.argv[2])
                if 0.0 < val <= 1.0:
                    val = val * 100.0
                set_brightness(val)
            except ValueError:
                pass
    elif cmd == "step-down":
        step = int(sys.argv[2]) if len(sys.argv) >= 3 else 10
        step_down(step)
    elif cmd == "step-up":
        step = int(sys.argv[2]) if len(sys.argv) >= 3 else 10
        step_up(step)
    elif cmd == "toggle-off":
        toggle_off()
    else:
        print("Usage: brightness-control.py [get|set <pct>|step-down [amt]|step-up [amt]|toggle-off]")

if __name__ == "__main__":
    main()
