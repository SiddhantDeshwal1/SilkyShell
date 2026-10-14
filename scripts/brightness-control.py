#!/usr/bin/env python3
"""
brightness-control.py — Precision smooth brightness manager for Quickshell & Hyprland.

Supports:
  - Discrete stepped control with a dedicated 'Display Off' level (0%) below min (10%).
  - Smooth cinematic fading between off (0%) and on levels, without sleep/suspend.
  - Subcommands:
      get               Get current brightness percentage (0-100)
      set <pct>         Set target brightness percentage (smooth fade to/from 0%)
      step-down [amt]   Step down by amt (default 10). If at min (10%), steps to 0% (Display Off).
      step-up [amt]     Step up by amt (default 10). If at 0% (Display Off), steps to min (10%).
      toggle-off        Toggle between 0% (Display Off) and previous/default brightness.
"""

import os
import sys
import glob
import time
import signal
import subprocess

PID_FILE = "/tmp/quickshell_brightness_fade.pid"
STATE_FILE = "/tmp/quickshell_brightness_last.txt"

def get_backlight_device():
    devices = glob.glob("/sys/class/backlight/*")
    if not devices:
        return None
    for d in devices:
        if "amdgpu" in d or "intel" in d:
            return d
    return devices[0]

def get_brightness_info():
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

    # Fallback to brightnessctl
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

def kill_previous_transition():
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r") as f:
                old_pid = int(f.read().strip())
            if old_pid != os.getpid():
                os.kill(old_pid, signal.SIGTERM)
        except Exception:
            pass
        try:
            os.remove(PID_FILE)
        except Exception:
            pass

def register_transition():
    try:
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))
    except Exception:
        pass

def cleanup_transition():
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE, "r") as f:
                cur = int(f.read().strip())
            if cur == os.getpid():
                os.remove(PID_FILE)
        except Exception:
            pass

def save_last_on_brightness(pct):
    if pct > 0:
        try:
            with open(STATE_FILE, "w") as f:
                f.write(str(pct))
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

def set_raw_pct(pct):
    pct = max(0, min(100, int(round(pct))))
    subprocess.run(["brightnessctl", "-q", "s", f"{pct}%"])

def smooth_transition(start_pct, end_pct, duration=0.20, steps=10):
    """
    Executes a smooth cubic ease-in-out transition between start_pct and end_pct.
    """
    kill_previous_transition()
    register_transition()
    try:
        if start_pct == end_pct:
            set_raw_pct(end_pct)
            return

        interval = duration / max(1, steps)
        for i in range(1, steps + 1):
            t = i / steps
            # Cubic ease-in-out curve
            curve = t * t * (3 - 2 * t)
            val = start_pct + (end_pct - start_pct) * curve
            set_raw_pct(val)
            if i < steps:
                time.sleep(interval)
        set_raw_pct(end_pct)
    finally:
        cleanup_transition()

def set_brightness(target_pct, smooth=None):
    """
    Sets target brightness. Automatically chooses smooth transition when
    crossing the boundary between 0% (display off) and >0% (display on).
    """
    _, _, cur_pct = get_brightness_info()
    target_pct = max(0, min(100, int(round(target_pct))))

    if target_pct > 0:
        save_last_on_brightness(target_pct)

    # If transitioning to 0 (display off) or from 0 (display on), always fade smoothly
    is_power_boundary = (cur_pct == 0 and target_pct > 0) or (cur_pct > 0 and target_pct == 0)
    
    if smooth is True or (smooth is None and is_power_boundary):
        smooth_transition(cur_pct, target_pct, duration=0.22, steps=10)
    elif smooth is False:
        kill_previous_transition()
        set_raw_pct(target_pct)
    else:
        # Standard adjustment: if delta is large, short micro-fade, else direct
        delta = abs(target_pct - cur_pct)
        if delta > 15:
            smooth_transition(cur_pct, target_pct, duration=0.12, steps=6)
        else:
            kill_previous_transition()
            set_raw_pct(target_pct)

def step_down(step=10):
    _, _, cur_pct = get_brightness_info()
    if cur_pct <= 0:
        # Already at display off level
        return
    if cur_pct <= step:
        # At or below minimum on-level: step down to the new level below min (0% / Display Off)
        smooth_transition(cur_pct, 0, duration=0.22, steps=10)
    else:
        # Step down normally to next 10% interval
        target = max(step, round((cur_pct - step) / step) * step)
        smooth_transition(cur_pct, target, duration=0.14, steps=7)
        save_last_on_brightness(target)

def step_up(step=10):
    _, _, cur_pct = get_brightness_info()
    if cur_pct <= 0:
        # At display off level: turn back on smoothly to the minimum level (e.g. 10%)
        target = step
        smooth_transition(0, target, duration=0.22, steps=10)
        save_last_on_brightness(target)
    else:
        # Step up normally to next 10% interval
        target = min(100, round((cur_pct + step) / step) * step)
        smooth_transition(cur_pct, target, duration=0.14, steps=7)
        save_last_on_brightness(target)

def toggle_off():
    _, _, cur_pct = get_brightness_info()
    if cur_pct <= 0:
        # Turn back on
        target = get_last_on_brightness(default=50)
        smooth_transition(0, target, duration=0.22, steps=10)
    else:
        # Turn display off
        save_last_on_brightness(cur_pct)
        smooth_transition(cur_pct, 0, duration=0.22, steps=10)

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
                # If value is between 0 and 1, convert to 0-100
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
