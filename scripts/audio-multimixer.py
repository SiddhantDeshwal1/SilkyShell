#!/usr/bin/env python3
"""
Quickshell Audio Multi-Mixer Backend Service (Persistent Hub Architecture)
Manages PipeWire latency-compensated multi-device playback.

Architecture:
- Creates a single persistent null-sink hub: 'qs_multi_mixer'.
- Audio from applications streams directly into 'qs_multi_mixer'.
- Independent 'module-loopback' instances route audio from 'qs_multi_mixer.monitor'
  to each active physical sink.
- Bluetooth streams play directly without artificial delay.
- Wired / ALSA streams receive buffer compensation (latency_msec) to match Bluetooth delay.
- Sinks can be dynamically added/removed or have their delay recalibrated WITHOUT
  destroying 'qs_multi_mixer', keeping media players (YouTube, Spotify, etc.)
  completely uninterrupted and continuous.
"""

import sys
import os
import subprocess
import json
import re
import time

SINK_NAME = "qs_multi_mixer"
SINK_DESC = "Multi-Mixer"
DELAY_SINK_NAME = "qs_delayed_speaker"  # Legacy cleanup
CONFIG_FILE = os.path.expanduser("~/.config/quickshell/scripts/multimixer-sync.json")
VOL_BACKUP_FILE = os.path.expanduser("~/.config/quickshell/scripts/multimixer-volumes.json")
DEFAULT_DELAY_MS = 180

def snapshot_sink_volumes():
    """Snapshots original physical sink volumes before Multi-Mixer modifications."""
    if os.path.exists(VOL_BACKUP_FILE):
        return  # Preserve initial pre-mixer volume snapshot
    avail = get_available_sinks()
    vols = {}
    for s in avail:
        out = run_cmd(["pactl", "get-sink-volume", s])
        match = re.search(r"/\s*(\d+)%", out)
        if match:
            vols[s] = int(match.group(1))
    if vols:
        try:
            os.makedirs(os.path.dirname(VOL_BACKUP_FILE), exist_ok=True)
            with open(VOL_BACKUP_FILE, "w") as f:
                json.dump(vols, f)
        except Exception:
            pass

def restore_sink_volumes():
    """Restores physical sink volumes to their pre-mixer states."""
    if not os.path.exists(VOL_BACKUP_FILE):
        return
    try:
        with open(VOL_BACKUP_FILE, "r") as f:
            vols = json.load(f)
        avail = get_available_sinks()
        for s, pct in vols.items():
            if s in avail:
                subprocess.run(["pactl", "set-sink-volume", s, f"{pct}%"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.remove(VOL_BACKUP_FILE)
    except Exception:
        pass

def get_saved_delay():
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, "r") as f:
                data = json.load(f)
                return int(data.get("delay_ms", DEFAULT_DELAY_MS))
    except Exception:
        pass
    return DEFAULT_DELAY_MS

def save_delay(ms):
    try:
        os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            json.dump({"delay_ms": int(ms)}, f)
    except Exception:
        pass

def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
        return res.stdout.strip()
    except Exception:
        return ""

def get_available_sinks():
    try:
        out = run_cmd(["pactl", "list", "short", "sinks"])
        sinks = []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                name = parts[1]
                if name != SINK_NAME and name != DELAY_SINK_NAME and not name.startswith("qs_"):
                    sinks.append(name)
        return sinks
    except Exception:
        return []

def get_default_sink():
    info = run_cmd(["pactl", "info"])
    for line in info.splitlines():
        if "Default Sink:" in line:
            return line.split(":", 1)[1].strip()
    return ""

def is_bluetooth_sink(name):
    return "bluez" in (name or "").lower()

def get_hub_module_id():
    out = run_cmd(["pactl", "list", "short", "modules"])
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "module-null-sink":
            args = " ".join(parts[2:])
            if f"sink_name={SINK_NAME}" in args:
                return parts[0]
    return None

def get_active_loopbacks():
    """
    Returns a dict of active loopbacks routing from qs_multi_mixer.monitor:
    { sink_name: {"id": module_id, "latency_msec": int} }
    """
    out = run_cmd(["pactl", "list", "short", "modules"])
    loopbacks = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "module-loopback":
            mod_id = parts[0]
            args = " ".join(parts[2:])
            if f"{SINK_NAME}.monitor" in args:
                sink_match = re.search(r"sink=([^\s]+)", args)
                if sink_match:
                    sink_name = sink_match.group(1)
                    lat_match = re.search(r"latency_msec=([0-9]+)", args)
                    lat = int(lat_match.group(1)) if lat_match else 0
                    loopbacks[sink_name] = {"id": mod_id, "latency_msec": lat}
    return loopbacks

def cleanup_legacy_modules():
    """Removes any obsolete combine-sink or delayed-speaker modules from previous versions."""
    out = run_cmd(["pactl", "list", "short", "modules"])
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            mod_id = parts[0]
            mod_name = parts[1]
            args = " ".join(parts[2:])
            if mod_name == "module-combine-sink" and SINK_NAME in args:
                subprocess.run(["pactl", "unload-module", mod_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elif DELAY_SINK_NAME in args:
                subprocess.run(["pactl", "unload-module", mod_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def migrate_client_streams(target_sink):
    """
    Safely moves application playback streams to target_sink.
    Ignores internal loopbacks (where client index is '-').
    """
    if not target_sink:
        return
    try:
        out = run_cmd(["pactl", "list", "short", "sink-inputs"])
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[2] != "-":
                inp_id = parts[0]
                subprocess.run(["pactl", "move-sink-input", inp_id, target_sink], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

def get_status():
    hub_id = get_hub_module_id()
    active_lbs = get_active_loopbacks()
    avail = get_available_sinks()
    current_delay = get_saved_delay()

    if hub_id:
        slaves = [s for s in active_lbs.keys() if s in avail]
        bt_sinks = [s for s in slaves if is_bluetooth_sink(s)]
        wired_sinks = [s for s in slaves if not is_bluetooth_sink(s)]
        is_mixed = bool(bt_sinks and wired_sinks)

        return {
            "enabled": True,
            "module_id": hub_id,
            "slaves": slaves,
            "default_sink": get_default_sink(),
            "sync_delay_ms": current_delay,
            "is_mixed": is_mixed
        }

    return {
        "enabled": False,
        "module_id": None,
        "slaves": [],
        "default_sink": get_default_sink(),
        "sync_delay_ms": current_delay,
        "is_mixed": False
    }

def set_slaves(slaves, fallback=None, custom_delay=None):
    cleanup_legacy_modules()

    avail = get_available_sinks()
    clean_slaves = []
    for s in slaves:
        s_clean = s.strip()
        if s_clean and s_clean in avail and s_clean != SINK_NAME and s_clean not in clean_slaves:
            clean_slaves.append(s_clean)

    delay_ms = custom_delay if custom_delay is not None else get_saved_delay()
    if custom_delay is not None:
        save_delay(custom_delay)

    # If no devices selected, disable Multi-Mixer
    if not clean_slaves:
        if not fallback:
            current_lbs = get_active_loopbacks()
            if current_lbs:
                fallback = list(current_lbs.keys())[0]
        return disable(fallback)

    # 1. Ensure Persistent Hub exists
    hub_id = get_hub_module_id()
    if not hub_id:
        snapshot_sink_volumes()
        hub_id = run_cmd([
            "pactl", "load-module", "module-null-sink",
            f"sink_name={SINK_NAME}",
            f"sink_properties=device.description={SINK_DESC}"
        ])
        subprocess.run(["pactl", "set-default-sink", SINK_NAME], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        migrate_client_streams(SINK_NAME)
    else:
        if get_default_sink() != SINK_NAME:
            subprocess.run(["pactl", "set-default-sink", SINK_NAME], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            migrate_client_streams(SINK_NAME)

    # 2. Determine Mixed Sync Mode (Bluetooth + Wired)
    bt_sinks = [s for s in clean_slaves if is_bluetooth_sink(s)]
    wired_sinks = [s for s in clean_slaves if not is_bluetooth_sink(s)]
    is_mixed = bool(bt_sinks and wired_sinks)

    # 3. Reconcile Loopbacks Non-Disruptively
    current_lbs = get_active_loopbacks()

    # Unload loopbacks for sinks no longer desired
    for sink_name, info in list(current_lbs.items()):
        if sink_name not in clean_slaves:
            subprocess.run(["pactl", "unload-module", info["id"]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            del current_lbs[sink_name]

    # Add or update loopbacks for desired sinks
    for sink in clean_slaves:
        desired_latency = delay_ms if (is_mixed and sink in wired_sinks) else 0

        if sink in current_lbs:
            cur_lat = current_lbs[sink]["latency_msec"]
            if cur_lat != desired_latency:
                # Latency adjustment needed (e.g. state transitioned to/from mixed)
                subprocess.run(["pactl", "unload-module", current_lbs[sink]["id"]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                cmd = [
                    "pactl", "load-module", "module-loopback",
                    f"source={SINK_NAME}.monitor",
                    f"sink={sink}",
                    "sink_dont_move=true",
                    "source_dont_move=true"
                ]
                if desired_latency > 0:
                    cmd.append(f"latency_msec={desired_latency}")
                new_id = run_cmd(cmd)
                current_lbs[sink] = {"id": new_id, "latency_msec": desired_latency}
            else:
                # Loopback already running with desired latency! Keep untouched!
                pass
        else:
            # New device: load loopback without touching hub or other loopbacks
            cmd = [
                "pactl", "load-module", "module-loopback",
                f"source={SINK_NAME}.monitor",
                f"sink={sink}",
                "sink_dont_move=true",
                "source_dont_move=true"
            ]
            if desired_latency > 0:
                cmd.append(f"latency_msec={desired_latency}")
            new_id = run_cmd(cmd)
            current_lbs[sink] = {"id": new_id, "latency_msec": desired_latency}

    return {
        "enabled": True,
        "module_id": hub_id,
        "slaves": clean_slaves,
        "default_sink": SINK_NAME,
        "sync_delay_ms": delay_ms,
        "is_mixed": is_mixed
    }

def set_delay(ms_val):
    try:
        ms = max(0, min(800, int(ms_val)))
    except Exception:
        ms = DEFAULT_DELAY_MS
    save_delay(ms)

    st = get_status()
    if not st["enabled"]:
        return st

    # Only adjust wired loopbacks when mixed with Bluetooth
    if st["is_mixed"]:
        current_lbs = get_active_loopbacks()
        for sink_name, info in current_lbs.items():
            if not is_bluetooth_sink(sink_name):
                # Unload and re-create only the wired loopback with updated latency
                # Hub and Bluetooth loopback stay 100% active and uninterrupted!
                subprocess.run(["pactl", "unload-module", info["id"]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                cmd = [
                    "pactl", "load-module", "module-loopback",
                    f"source={SINK_NAME}.monitor",
                    f"sink={sink_name}",
                    f"latency_msec={ms}",
                    "sink_dont_move=true",
                    "source_dont_move=true"
                ]
                run_cmd(cmd)

    st["sync_delay_ms"] = ms
    return st

def disable(fallback=None):
    cleanup_legacy_modules()

    avail = get_available_sinks()
    target_sink = None
    if fallback and fallback in avail and fallback != SINK_NAME:
        target_sink = fallback
    elif avail:
        bt_avail = [s for s in avail if is_bluetooth_sink(s)]
        target_sink = bt_avail[0] if bt_avail else avail[0]

    # 1. Switch default sink and migrate streams back to physical hardware first
    if target_sink:
        subprocess.run(["pactl", "set-default-sink", target_sink], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        migrate_client_streams(target_sink)
        time.sleep(0.05)

    # 2. Unload loopbacks
    current_lbs = get_active_loopbacks()
    for info in current_lbs.values():
        subprocess.run(["pactl", "unload-module", info["id"]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # 3. Unload persistent hub
    hub_id = get_hub_module_id()
    if hub_id:
        subprocess.run(["pactl", "unload-module", hub_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # 4. Restore original physical sink volumes (revert all settings)
    restore_sink_volumes()

    return {
        "enabled": False,
        "module_id": None,
        "slaves": [],
        "default_sink": get_default_sink(),
        "sync_delay_ms": get_saved_delay(),
        "is_mixed": False
    }

def toggle_device(device_name):
    if not device_name or device_name == SINK_NAME:
        return get_status()

    st = get_status()
    current_slaves = list(st["slaves"])

    if not st["enabled"]:
        def_sink = st.get("default_sink", "")
        initial_slaves = []
        avail = get_available_sinks()
        if def_sink and def_sink in avail and def_sink != SINK_NAME:
            initial_slaves.append(def_sink)
        if device_name in avail and device_name not in initial_slaves:
            initial_slaves.append(device_name)
        return set_slaves(initial_slaves)
    else:
        if device_name in current_slaves:
            current_slaves.remove(device_name)
        else:
            current_slaves.append(device_name)
        return set_slaves(current_slaves)

def main():
    if len(sys.argv) < 2:
        print(json.dumps(get_status()))
        return

    cmd = sys.argv[1].lower()

    if cmd == "status":
        print(json.dumps(get_status()))
    elif cmd == "enable":
        slaves = sys.argv[2:]
        if not slaves:
            def_sink = get_default_sink()
            avail = get_available_sinks()
            if def_sink and def_sink in avail and def_sink != SINK_NAME:
                slaves = [def_sink]
            elif avail:
                slaves = [avail[0]]
        print(json.dumps(set_slaves(slaves)))
    elif cmd == "disable":
        fallback = sys.argv[2] if len(sys.argv) > 2 else None
        print(json.dumps(disable(fallback)))
    elif cmd == "set-slaves":
        slaves = sys.argv[2:]
        print(json.dumps(set_slaves(slaves)))
    elif cmd == "set-delay":
        ms = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DELAY_MS
        print(json.dumps(set_delay(ms)))
    elif cmd == "toggle-device":
        device = sys.argv[2] if len(sys.argv) > 2 else ""
        print(json.dumps(toggle_device(device)))
    elif cmd == "set-device-volume":
        device = sys.argv[2] if len(sys.argv) > 2 else ""
        vol_pct = sys.argv[3] if len(sys.argv) > 3 else "100"
        if device:
            subprocess.run(["pactl", "set-sink-volume", device, f"{vol_pct}%"])
        print(json.dumps({"status": "ok", "device": device, "volume": vol_pct}))
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))

if __name__ == "__main__":
    main()
