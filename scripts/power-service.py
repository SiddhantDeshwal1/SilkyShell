#!/usr/bin/env python3
"""
Quickshell Power Mode Service & Daemon
Manages APU thermal limits, CPU governors, and sched-ext BPF schedulers.
Integrates with /usr/bin/pwr, persists active mode across laptop lid close/open,
and resets cleanly on system reboot.
"""

import os
import sys
import json
import time
import signal
import fcntl
import subprocess
from pathlib import Path
from qs_daemon_base import set_parent_death_signal

# Paths
RUN_DIR = Path(f"/run/user/{os.getuid()}") if hasattr(os, "getuid") else Path("/run/user/1000")
STATE_FILE = RUN_DIR / "quickshell_power_mode.json"
CACHE_DIR = Path.home() / ".cache" / "quickshell"
PERSIST_FILE = CACHE_DIR / "power_mode.json"
BOOT_ID_FILE = Path("/proc/sys/kernel/random/boot_id")
PWR_BIN = "/usr/bin/pwr"
CONFIG_TOML = Path("/etc/scx_loader/config.toml")
GOV_FILE = Path("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")

MODES = {
    "peak": {
        "mode": "peak",
        "name": "Peak",
        "shortName": "Peak",
        "tag": "Extreme Redline",
        "wattage": "35W",
        "temp": "100°C",
        "stapmLimit": 35000,
        "fastLimit": 35000,
        "slowLimit": 35000,
        "tempLimit": 100,
        "governor": "performance",
        "scheduler": "scx_bpfland",
        "color": "#f43f5e",
        "glowColor": "rgba(244, 63, 94, 0.45)",
        "gradientStart": "#fb7185",
        "gradientEnd": "#e11d48",
        "icon": "󰓅",
        "description": "Redlining the APU (35W / 100°C)",
        "levelIndex": 4
    },
    "performance": {
        "mode": "performance",
        "name": "Performance",
        "shortName": "Perf",
        "tag": "Max APU",
        "wattage": "30W",
        "temp": "100°C",
        "stapmLimit": 30000,
        "fastLimit": 30000,
        "slowLimit": 30000,
        "tempLimit": 100,
        "governor": "performance",
        "scheduler": "scx_bpfland",
        "color": "#f97316",
        "glowColor": "rgba(249, 115, 22, 0.45)",
        "gradientStart": "#fb923c",
        "gradientEnd": "#ea580c",
        "icon": "󰈸",
        "description": "Maxing out the APU (30W / 100°C)",
        "levelIndex": 3
    },
    "boost": {
        "mode": "boost",
        "name": "Boost",
        "shortName": "Boost",
        "tag": "High APU",
        "wattage": "25W",
        "temp": "100°C",
        "stapmLimit": 25000,
        "fastLimit": 25000,
        "slowLimit": 25000,
        "tempLimit": 100,
        "governor": "performance",
        "scheduler": "scx_bpfland",
        "color": "#a855f7",
        "glowColor": "rgba(168, 85, 247, 0.45)",
        "gradientStart": "#c084fc",
        "gradientEnd": "#9333ea",
        "icon": "󰌠",
        "description": "Boosting APU performance (25W / 100°C)",
        "levelIndex": 2
    },
    "balanced": {
        "mode": "balanced",
        "name": "Balanced",
        "shortName": "Bal",
        "tag": "Stock Limits",
        "wattage": "15W",
        "temp": "100°C",
        "stapmLimit": 15000,
        "fastLimit": 15000,
        "slowLimit": 15000,
        "tempLimit": 100,
        "governor": "schedutil",
        "scheduler": "scx_rusty",
        "color": "#0ea5e9",
        "glowColor": "rgba(14, 165, 233, 0.45)",
        "gradientStart": "#38bdf8",
        "gradientEnd": "#0284c7",
        "icon": "󰞬",
        "description": "Restoring stock APU limits (15W / 100°C)",
        "levelIndex": 1
    },
    "batterysaver": {
        "mode": "batterysaver",
        "name": "Battery Saver",
        "shortName": "Eco",
        "tag": "Longevity",
        "wattage": "10W",
        "temp": "100°C",
        "stapmLimit": 10000,
        "fastLimit": 10000,
        "slowLimit": 10000,
        "tempLimit": 100,
        "governor": "powersave",
        "scheduler": "scx_lavd",
        "color": "#10b981",
        "glowColor": "rgba(16, 185, 129, 0.45)",
        "gradientStart": "#34d399",
        "gradientEnd": "#059669",
        "icon": "󰌪",
        "description": "Underclocking for longevity (10W / 100°C)",
        "levelIndex": 0
    }
}

def get_current_boot_id():
    try:
        if BOOT_ID_FILE.exists():
            return BOOT_ID_FILE.read_text().strip()
    except Exception:
        pass
    return ""

def normalize_mode(mode_str):
    if not mode_str:
        return "balanced"
    m = mode_str.lower().strip()
    if m in ["peak", "extreme", "redline", "pwr", "max35", "35w", "35"]:
        return "peak"
    elif m in ["performance", "perf", "turbo", "max", "max30", "30w", "30"]:
        return "performance"
    elif m in ["boost", "gaming", "game", "high", "max25", "25w", "25"]:
        return "boost"
    elif m in ["balanced", "bal", "normal", "stock", "default", "15w", "15"]:
        return "balanced"
    elif m in ["batterysaver", "battery", "saver", "save", "eco", "powersave", "10w", "10"]:
        return "batterysaver"
    return "balanced"

def detect_system_mode():
    gov = ""
    sched = ""
    try:
        if GOV_FILE.exists():
            gov = GOV_FILE.read_text().strip()
    except Exception:
        pass

    try:
        if CONFIG_TOML.exists():
            import re
            match = re.search(r'default_sched\s*=\s*"([^"]+)"', CONFIG_TOML.read_text())
            if match:
                sched = match.group(1).strip()
    except Exception:
        pass

    if gov == "powersave" or sched == "scx_lavd":
        return "batterysaver"
    elif gov == "schedutil" or sched == "scx_rusty":
        return "balanced"
    elif gov == "performance" or sched == "scx_bpfland":
        # Default to performance if unable to distinguish between performance and peak
        return "performance"
    return "balanced"

def load_saved_mode():
    # 1. First check /run/user/1000/quickshell_power_mode.json (RAM tmpfs, wiped on reboot)
    try:
        if STATE_FILE.exists():
            data = json.loads(STATE_FILE.read_text())
            m = data.get("mode")
            if m in MODES:
                return m
    except Exception:
        pass

    # 2. Check cache file, but ONLY if boot_id matches current boot (session persistence)
    try:
        curr_boot = get_current_boot_id()
        if PERSIST_FILE.exists():
            data = json.loads(PERSIST_FILE.read_text())
            if data.get("boot_id") == curr_boot:
                m = data.get("mode")
                if m in MODES:
                    return m
    except Exception:
        pass

    # 3. If neither or rebooted, detect from system state
    return detect_system_mode()

def save_mode_state(mode_key):
    norm = normalize_mode(mode_key)
    mode_info = dict(MODES[norm])
    curr_boot = get_current_boot_id()
    mode_info["boot_id"] = curr_boot
    mode_info["updated_at"] = int(time.time())

    # Write in-place to STATE_FILE so inotify inode is preserved for QuickShell FileView
    try:
        RUN_DIR.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(json.dumps(mode_info, indent=2))
    except Exception as e:
        sys.stderr.write(f"Error saving to {STATE_FILE}: {e}\n")

    # Also save to CACHE_DIR with boot_id
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        PERSIST_FILE.write_text(json.dumps(mode_info, indent=2))
    except Exception:
        pass

    return mode_info

def execute_pwr_system(mode_key):
    norm = normalize_mode(mode_key)

    if os.geteuid() == 0:
        cmd = [PWR_BIN, norm]
    else:
        cmd = ["sudo", "-n", PWR_BIN, norm]

    try:
        # Run synchronously to ensure ryzenadj, cpupower, and scx_loader complete
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        if res.returncode != 0:
            sys.stderr.write(f"pwr failed ({res.returncode}): {res.stderr.decode()}\n")
            return False
        return True
    except Exception as e:
        sys.stderr.write(f"Failed to execute {cmd}: {e}\n")
        return False

def reapply_active_mode():
    curr = load_saved_mode()
    sys.stderr.write(f"[PowerService] Re-applying active mode '{curr}' on resume/lid event\n")
    sys.stderr.flush()
    execute_pwr_system(curr)
    state = save_mode_state(curr)
    try:
        sys.stdout.write(json.dumps(state) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        sys.exit(0)

def run_daemon():
    set_parent_death_signal()
    # Acquire singleton lock
    try:
        lock_file = open("/tmp/quickshell_power.lock", "a+")
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(f"{os.getpid()}\n")
        lock_file.flush()
    except (BlockingIOError, IOError):
        sys.stderr.write("[PowerService] Another daemon instance is already running. Exiting.\n")
        sys.exit(0)

    # Ensure initial state is written
    initial_mode = load_saved_mode()
    state = save_mode_state(initial_mode)
    try:
        sys.stdout.write(json.dumps(state) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        sys.exit(0)

    try:
        import dbus
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib

        DBusGMainLoop(set_as_default=True)
        bus = dbus.SystemBus()
        loop = GLib.MainLoop()

        # Exit instantly when Quickshell exits or pipe closes
        GLib.io_add_watch(0, GLib.IOCondition.HUP | GLib.IOCondition.ERR, lambda *a: (loop.quit(), False)[1])
        signal.signal(signal.SIGINT, lambda *a: loop.quit())
        signal.signal(signal.SIGTERM, lambda *a: loop.quit())

        # Debounce flag: prevents quadruple-fire when both PrepareForSleep
        # and LidClosed signals fire simultaneously on lid open / resume.
        _reapply_pending = [False]

        def _schedule_reapply():
            if not _reapply_pending[0]:
                _reapply_pending[0] = True
                def _do_reapply():
                    _reapply_pending[0] = False
                    reapply_active_mode()
                    return False
                GLib.timeout_add(900, _do_reapply)
                # Second reapply at 2.5s for slow power management settling
                GLib.timeout_add(2500, lambda: (reapply_active_mode(), False)[1])

        def on_sleep_changed(sleeping):
            if not sleeping:
                # Resumed from sleep / suspend!
                _schedule_reapply()

        def on_login1_prop_changed(iface, changed, invalidated):
            if "LidClosed" in changed:
                lid_closed = bool(changed["LidClosed"])
                if not lid_closed:
                    # Laptop lid was opened!
                    _schedule_reapply()

        try:
            bus.add_signal_receiver(
                on_sleep_changed,
                signal_name="PrepareForSleep",
                dbus_interface="org.freedesktop.login1.Manager",
                bus_name="org.freedesktop.login1"
            )
            bus.add_signal_receiver(
                on_login1_prop_changed,
                signal_name="PropertiesChanged",
                dbus_interface="org.freedesktop.DBus.Properties",
                bus_name="org.freedesktop.login1"
            )
            sys.stderr.write("[PowerService] Connected to login1 sleep/lid monitoring\n")
            sys.stderr.flush()
        except Exception as e:
            sys.stderr.write(f"[PowerService] DBus login1 listener error: {e}\n")

        loop = GLib.MainLoop()
        loop.run()
    except Exception as e:
        sys.stderr.write(f"[PowerService] Falling back to polling loop: {e}\n")
        while True:
            time.sleep(10)

if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "get"

    if action == "daemon":
        run_daemon()
    elif action == "get":
        curr = load_saved_mode()
        state = save_mode_state(curr)
        sys.stdout.write(json.dumps(state) + "\n")
        sys.stdout.flush()
    elif action in ["set", "apply"]:
        target = sys.argv[2] if len(sys.argv) > 2 else "balanced"
        norm = normalize_mode(target)
        state = save_mode_state(norm)
        execute_pwr_system(norm)
        sys.stdout.write(json.dumps(state) + "\n")
        sys.stdout.flush()
    elif action == "save":
        # Saves state only without re-running system pwr (used by shell wrapper)
        target = sys.argv[2] if len(sys.argv) > 2 else "balanced"
        norm = normalize_mode(target)
        state = save_mode_state(norm)
        sys.stdout.write(json.dumps(state) + "\n")
        sys.stdout.flush()
        try:
            subprocess.Popen(["quickshell", "ipc", "call", "controlcenter", "refreshPowerMode"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
    else:
        print("Usage: power-service.py {daemon|get|set <mode>|save <mode>}")
