#!/usr/bin/env python3
"""
Quickshell Audio Effects & DSP Controller Service (EasyEffects Backend)
High-performance, atomic, race-condition-free DSP preset manager.
"""

import sys
import os
import subprocess
import json
import time

PRESETS_DIR = os.path.expanduser("~/.local/share/easyeffects/output")
CONFIG_DB_DIR = os.path.expanduser("~/.config/easyeffects/db")
STATE_FILE = os.path.expanduser("~/.config/quickshell/scripts/audio-effects-state.json")

PRESET_METADATA = [
    {
        "id": "direct",
        "name": "Direct Bypass",
        "icon": "󰔊",
        "desc": "Raw uncolored sound (DSP bypassed)"
    },
    {
        "id": "vocal",
        "name": "Vocal Clarity",
        "icon": "󰍬",
        "desc": "Meetings & calls speech clarity"
    },
    {
        "id": "music",
        "name": "Music Hi-Fi",
        "icon": "󰎆",
        "desc": "Audiophile balanced soundstage"
    },
    {
        "id": "excited",
        "name": "Excited Bass",
        "icon": "󰝚",
        "desc": "Club punch & high energy"
    },
    {
        "id": "movie",
        "name": "Movie Cinema",
        "icon": "󰿎",
        "desc": "Dialogue leveler & spatial"
    },
    {
        "id": "auto",
        "name": "Auto Adapt",
        "icon": "󰓃",
        "desc": "EBU R128 adaptive loudness"
    },
    {
        "id": "latenight",
        "name": "Late Night Quiet",
        "icon": "󰤄",
        "desc": "No wall bass, quiet dialogue"
    },
    {
        "id": "gaming",
        "name": "Gaming Footsteps",
        "icon": "󰊴",
        "desc": "Footsteps & positional cues"
    }
]

def make_10band_eq(gains, input_gain=0.0, output_gain=0.0):
    freqs = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0]
    left = {}
    right = {}
    for i, (f, g) in enumerate(zip(freqs, gains)):
        b = {
            "frequency": f,
            "gain": float(g),
            "mode": "RLC (BT)",
            "mute": False,
            "q": 1.50476,
            "slope": "x1",
            "solo": False,
            "type": "Bell"
        }
        left[f"band{i}"] = b
        right[f"band{i}"] = dict(b)

    return {
        "input-gain": float(input_gain),
        "output-gain": float(output_gain),
        "mode": "IIR",
        "num-bands": 10,
        "split-channels": False,
        "left": left,
        "right": right
    }

def get_preset_definitions():
    """Generates calibrated DSP preset templates with makeup gain staging."""
    limiter_std = {
        "alr": False,
        "alr-attack": 5.0,
        "alr-knee": 0.0,
        "alr-release": 50.0,
        "attack": 5.0,
        "dithering": "None",
        "gain-boost": True,
        "input-gain": 0.0,
        "lookahead": 10.0,
        "mode": "Herm Thin",
        "output-gain": 0.0,
        "oversampling": "None",
        "release": 5.0,
        "sidechain-preamp": 0.0,
        "stereo-link": 100.0,
        "threshold": 0.0
    }

    presets = {}

    # 1. Vocal Clarity (input-gain: -2.0 for makeup leveling)
    presets["Vocal Clarity"] = {
        "output": {
            "blocklist": [],
            "equalizer": make_10band_eq([-12.0, -8.0, -3.0, -2.0, 1.0, 2.5, 4.0, 4.5, 1.0, -3.0], input_gain=-2.0),
            "exciter": {
                "amount": 3.0,
                "blend": 0.0,
                "ceil": 16000.0,
                "ceil-active": False,
                "harmonics": 4.0,
                "input-gain": 0.0,
                "output-gain": 0.0,
                "scope": 2500.0
            },
            "limiter": dict(limiter_std, threshold=-0.5),
            "plugins_order": ["equalizer", "exciter", "limiter"]
        }
    }

    # 2. Music Hi-Fi
    presets["Music Hi-Fi"] = {
        "output": {
            "blocklist": [],
            "equalizer": make_10band_eq([4.0, 2.5, 1.0, 0.0, -1.0, -1.5, 0.5, 2.0, 3.0, 3.5], input_gain=-1.0),
            "exciter": {
                "amount": 3.5,
                "blend": 0.0,
                "ceil": 16000.0,
                "ceil-active": False,
                "harmonics": 5.0,
                "input-gain": 0.0,
                "output-gain": 0.0,
                "scope": 5500.0
            },
            "limiter": dict(limiter_std, threshold=0.0),
            "plugins_order": ["equalizer", "exciter", "limiter"]
        }
    }

    # 3. Excited Bass (input-gain: -2.5 for heavy bass control)
    presets["Excited Bass"] = {
        "output": {
            "blocklist": [],
            "equalizer": make_10band_eq([7.0, 5.5, 2.5, -1.5, 0.0, 0.5, 1.5, 3.0, 4.5, 5.0], input_gain=-2.5),
            "exciter": {
                "amount": 6.0,
                "blend": 0.0,
                "ceil": 16000.0,
                "ceil-active": False,
                "harmonics": 8.5,
                "input-gain": -1.0,
                "output-gain": 0.0,
                "scope": 4000.0
            },
            "limiter": dict(limiter_std, threshold=-0.2),
            "plugins_order": ["equalizer", "exciter", "limiter"]
        }
    }

    # 4. Movie Cinema
    presets["Movie Cinema"] = {
        "output": {
            "blocklist": [],
            "equalizer": make_10band_eq([-3.0, -1.0, 0.0, -1.5, 1.5, 3.0, 4.0, 3.5, 2.0, 1.0], input_gain=-1.0),
            "exciter": {
                "amount": 4.0,
                "blend": 0.0,
                "ceil": 16000.0,
                "ceil-active": False,
                "harmonics": 4.5,
                "input-gain": 0.0,
                "output-gain": 0.0,
                "scope": 2200.0
            },
            "limiter": dict(limiter_std, threshold=-3.0, lookahead=12.0),
            "plugins_order": ["equalizer", "exciter", "limiter"]
        }
    }

    # 5. Auto Adapt (EBU R128 Loudness Normalizer)
    presets["Auto Adapt"] = {
        "output": {
            "autogain": {
                "target": -14.0
            },
            "blocklist": [],
            "equalizer": make_10band_eq([2.0, 1.0, 0.0, 0.0, 0.0, 0.5, 1.0, 1.5, 2.0, 2.0], input_gain=-0.5),
            "exciter": {
                "amount": 4.0,
                "blend": 0.0,
                "ceil": 16000.0,
                "ceil-active": False,
                "harmonics": 6.0,
                "input-gain": -1.0,
                "output-gain": 0.0,
                "scope": 5500.0
            },
            "limiter": dict(limiter_std, threshold=0.0),
            "plugins_order": ["equalizer", "exciter", "autogain", "limiter"]
        }
    }

    # 6. Late Night Quiet
    presets["Late Night Quiet"] = {
        "output": {
            "blocklist": [],
            "equalizer": make_10band_eq([-10.0, -6.0, -3.0, -1.0, 1.5, 3.0, 4.0, 3.5, 0.0, -4.0], input_gain=0.0),
            "limiter": dict(limiter_std, threshold=-6.0, release=15.0, lookahead=12.0),
            "plugins_order": ["equalizer", "limiter"]
        }
    }

    # 7. Gaming Footsteps (input-gain: -2.0)
    presets["Gaming Footsteps"] = {
        "output": {
            "blocklist": [],
            "equalizer": make_10band_eq([-8.0, -5.0, -2.0, -1.0, 0.5, 2.0, 4.5, 6.0, 3.5, 0.0], input_gain=-2.0),
            "exciter": {
                "amount": 5.5,
                "blend": 0.0,
                "ceil": 16000.0,
                "ceil-active": False,
                "harmonics": 7.0,
                "input-gain": 0.0,
                "output-gain": 0.0,
                "scope": 3000.0
            },
            "limiter": dict(limiter_std, threshold=-1.0),
            "plugins_order": ["equalizer", "exciter", "limiter"]
        }
    }

    return presets

def ensure_presets(force=False):
    """Writes calibrated preset files to disk only if missing (or forced)."""
    os.makedirs(PRESETS_DIR, exist_ok=True)
    presets = get_preset_definitions()
    for name, data in presets.items():
        filepath = os.path.join(PRESETS_DIR, f"{name}.json")
        if force or not os.path.exists(filepath):
            try:
                with open(filepath, "w") as f:
                    json.dump(data, f, indent=4)
            except Exception as e:
                sys.stderr.write(f"Failed to write preset {filepath}: {e}\n")

def is_easyeffects_running():
    try:
        res = subprocess.run(["pgrep", "-x", "easyeffects"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        return res.returncode == 0
    except Exception:
        return False

def start_easyeffects_service():
    """Starts EasyEffects daemon in service mode detached."""
    if is_easyeffects_running():
        return True
    try:
        subprocess.Popen(
            ["easyeffects", "--service-mode"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True
        )
        for _ in range(20):
            time.sleep(0.05)
            if is_easyeffects_running():
                return True
        return False
    except Exception as e:
        sys.stderr.write(f"Failed to start easyeffects: {e}\n")
        return False

def read_state_cache():
    """Reads persistent state cache."""
    default_state = {
        "enabled": False,
        "active_preset": "Direct Bypass",
        "active_desc": "Raw uncolored sound (DSP bypassed)",
        "last_enabled_preset": "Music Hi-Fi"
    }
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    default_state.update(data)
                    return default_state
        except Exception:
            pass
    return default_state

def write_state_cache(state):
    """Writes persistent state cache atomically."""
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, indent=2)
        os.replace(tmp, STATE_FILE)
    except Exception as e:
        sys.stderr.write(f"Failed to write state cache: {e}\n")

def get_desc_for_preset(name):
    for p in PRESET_METADATA:
        if p["name"] == name:
            return p["desc"]
    return "Custom sound preset"

def set_preset(preset_name: str):
    """Atomically loads preset AND activates effects in ONE CLI call."""
    ensure_presets(force=False)
    state = read_state_cache()

    if preset_name == "Direct Bypass" or preset_name == "direct":
        start_easyeffects_service()
        try:
            subprocess.run(["easyeffects", "-b", "1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2.0)
        except Exception as e:
            sys.stderr.write(f"Bypass call error: {e}\n")
        state["enabled"] = False
        state["active_preset"] = "Direct Bypass"
        state["active_desc"] = "Raw uncolored sound (DSP bypassed)"
        write_state_cache(state)
        return

    start_easyeffects_service()

    # Match exact preset name
    matched_name = preset_name
    for p in PRESET_METADATA:
        if p["id"].lower() == preset_name.lower() or p["name"].lower() == preset_name.lower():
            matched_name = p["name"]
            break

    # ATOMIC EXECUTION: Load preset AND disable bypass (enable effects = 2) in single command
    try:
        subprocess.run(
            ["easyeffects", "-l", matched_name, "-b", "2"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2.5
        )
    except Exception as e:
        sys.stderr.write(f"Atomic load/bypass error for {matched_name}: {e}\n")

    state["enabled"] = True
    state["active_preset"] = matched_name
    state["active_desc"] = get_desc_for_preset(matched_name)
    state["last_enabled_preset"] = matched_name
    write_state_cache(state)

def set_bypass_state(enable_effects: bool):
    """Toggles bypass state."""
    state = read_state_cache()
    start_easyeffects_service()

    if enable_effects:
        target_preset = state.get("last_enabled_preset", "Music Hi-Fi")
        if target_preset == "Direct Bypass":
            target_preset = "Music Hi-Fi"
        # Atomically load last preset and enable
        try:
            subprocess.run(
                ["easyeffects", "-l", target_preset, "-b", "2"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2.5
            )
        except Exception:
            pass
        state["enabled"] = True
        state["active_preset"] = target_preset
        state["active_desc"] = get_desc_for_preset(target_preset)
        state["last_enabled_preset"] = target_preset
    else:
        try:
            subprocess.run(["easyeffects", "-b", "1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2.0)
        except Exception:
            pass
        state["enabled"] = False
        state["active_preset"] = "Direct Bypass"
        state["active_desc"] = "Raw uncolored sound (DSP bypassed)"

    write_state_cache(state)

def toggle_bypass():
    state = read_state_cache()
    current = state.get("enabled", False)
    set_bypass_state(not current)

def print_status():
    running = is_easyeffects_running()
    state = read_state_cache()

    # If easyeffects was killed externally, mark as disabled
    enabled = state.get("enabled", False) if running else False
    active = state.get("active_preset", "Direct Bypass") if enabled else "Direct Bypass"
    active_desc = get_desc_for_preset(active) if enabled else "Raw uncolored sound (DSP bypassed)"
    last_enabled = state.get("last_enabled_preset", "Music Hi-Fi")

    payload = {
        "service_running": running,
        "enabled": enabled,
        "active_preset": active,
        "active_desc": active_desc,
        "last_enabled_preset": last_enabled,
        "presets": PRESET_METADATA
    }
    print(json.dumps(payload))
    sys.stdout.flush()

def main():
    if len(sys.argv) < 2 or sys.argv[1] == "status":
        print_status()
        return

    cmd = sys.argv[1]
    if cmd == "ensure-presets":
        ensure_presets(force=True)
        print_status()
    elif cmd == "set-preset":
        if len(sys.argv) >= 3:
            set_preset(sys.argv[2])
        print_status()
    elif cmd == "set-bypass":
        if len(sys.argv) >= 3:
            val = sys.argv[2]
            enable = val not in ("0", "off", "false", "1_bypass")
            set_bypass_state(enable)
        print_status()
    elif cmd == "toggle-bypass":
        toggle_bypass()
        print_status()
    else:
        print_status()

if __name__ == "__main__":
    main()
