#!/usr/bin/env python3
"""
Quickshell Audio Auto-Switch Backend Service
Implements a true MRU (Most Recently Used / Connected) Device Stack:
- When a device connects (Bluetooth, USB, Wired 3.5mm), it is pushed to the top of the stack and made active.
- When the active device disconnects, audio falls back to the second most recently connected available device, and so on.
- When an unplugged device is reconnected, it is promoted back to the top of the stack.
- When the user manually switches audio device in the UI, that device is promoted to the top of the stack.
- Automatically unmutes target sinks and moves live audio streams seamlessly.
- Automatically filters out virtual sinks (e.g. EasyEffects) to prevent shadow hijacking.
"""

import sys
import os
import json
import time
import signal
import fcntl
import array
import glob
import subprocess
from datetime import datetime
from pathlib import Path
from gi.repository import GLib

try:
    from qs_daemon_base import set_parent_death_signal
except ImportError:
    def set_parent_death_signal():
        try:
            import ctypes
            libc = ctypes.CDLL("libc.so.6")
            libc.prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
        except Exception:
            pass

CACHE_DIR = Path.home() / ".cache" / "quickshell"
CACHE_DIR.mkdir(parents=True, exist_ok=True)
STACK_FILE = CACHE_DIR / "audio_device_stack.json"
LOCK_FILE = Path("/tmp/quickshell_audio_autoswitch.lock")
LOG_FILE = CACHE_DIR / "audio_autoswitch.log"

MULTI_MIXER_SINK = "qs_multi_mixer"


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    line = f"[{ts}] {msg}\n"
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line)
    except Exception:
        pass
    if sys.stderr.isatty():
        sys.stderr.write(line)
        sys.stderr.flush()


def run_cmd(cmd, timeout=3.0):
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        return res.stdout.strip()
    except Exception:
        return ""


def load_stack():
    try:
        if STACK_FILE.exists():
            with open(STACK_FILE, "r") as f:
                data = json.load(f)
                if isinstance(data, list):
                    return data
    except Exception as e:
        log(f"Error loading stack: {e}")
    return []


def save_stack(stack):
    try:
        with open(STACK_FILE, "w") as f:
            json.dump(stack, f, indent=2)
    except Exception as e:
        log(f"Error saving stack: {e}")


def check_headphone_jack_hardware():
    """
    Checks the kernel input switch SW_HEADPHONE_INSERT (0x8008451b) directly.
    Works independently of whether PipeWire or ALSA has updated its port states yet.
    """
    EVIOCGNAME_256 = 0x82004506
    for path in glob.glob("/dev/input/event*"):
        try:
            with open(path, "rb") as f:
                name_buf = array.array("B", [0] * 256)
                fcntl.ioctl(f.fileno(), EVIOCGNAME_256, name_buf)
                dev_name = bytes(name_buf).split(b"\x00")[0].decode("utf-8", errors="ignore").lower()
                if "headphone" in dev_name:
                    sw_buf = array.array("B", [0] * 8)
                    fcntl.ioctl(f.fileno(), 0x8008451b, sw_buf)
                    return bool(sw_buf[0] & (1 << 2))
        except Exception:
            pass
    return False


class AudioAutoSwitcher:
    def __init__(self):
        self.stack = load_stack()
        self.prev_available_keys = set()
        self.prev_active_key = None
        self.lock_fp = None
        self.pactl_proc = None
        self.pactl_buf = ""
        self.jack_fd = None
        self.debounce_timer_id = 0
        self.debounce_ms = 80

    def acquire_lock(self, wait=False):
        try:
            self.lock_fp = open(LOCK_FILE, "a+")
            flags = fcntl.LOCK_EX if wait else (fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(self.lock_fp.fileno(), flags)
            self.lock_fp.seek(0)
            self.lock_fp.truncate()
            self.lock_fp.write(f"{os.getpid()}\n")
            self.lock_fp.flush()
            return True
        except (BlockingIOError, IOError):
            return False

    def get_pactl_json(self, target):
        out = run_cmd(["pactl", "-f", "json", "list", target])
        if not out:
            return []
        try:
            return json.loads(out)
        except Exception:
            return []

    def get_default_sink_name(self):
        info = run_cmd(["pactl", "info"])
        for line in info.splitlines():
            if line.startswith("Default Sink:"):
                return line.split(":", 1)[1].strip()
        return ""

    def scan_endpoints(self):
        sinks = self.get_pactl_json("sinks")
        cards = self.get_pactl_json("cards")
        default_sink = self.get_default_sink_name()

        # Build card port availability map
        card_ports = {}
        for card in cards:
            c_name = card.get("name", "")
            for p_name, p_info in card.get("ports", {}).items():
                card_ports[(c_name, p_name)] = p_info.get("availability", "")

        endpoints = []
        is_multi_mixer_default = (default_sink == MULTI_MIXER_SINK)

        # Query hardware jack status for Realtek ALC3204
        hw_jack_plugged = check_headphone_jack_hardware()

        for s in sinks:
            s_name = s.get("name", "")
            props = s.get("properties", {})
            media_class = props.get("media.class", "")
            factory_name = props.get("factory.name", "")
            device_api = props.get("device.api", "")

            # Filter out virtual/filter sinks: Multi-Mixer, QuickShell monitor, EasyEffects, null sinks
            if (s_name.startswith("qs_") or
                s_name == MULTI_MIXER_SINK or
                "easyeffects" in s_name.lower() or
                "auto_null" in s_name.lower() or
                media_class == "Audio/Sink/Virtual" or
                "null-audio-sink" in factory_name.lower() or
                device_api == "null"):
                continue

            bus = props.get("device.bus", "")
            card_name = props.get("device.name", "")
            obj_id = props.get("object.id", str(s.get("index", "")))
            desc = s.get("description", s_name)
            active_port = s.get("active_port")
            ports = s.get("ports", [])

            # 1. Bluetooth device
            if bus == "bluetooth" or s_name.startswith("bluez_output.") or "bluez" in device_api:
                is_active = (s_name == default_sink)
                endpoints.append({
                    "key": f"bluetooth:{s_name}",
                    "type": "bluetooth",
                    "sink_name": s_name,
                    "sink_id": obj_id,
                    "port_name": None,
                    "desc": desc,
                    "icon": "audio-headphones-bluetooth",
                    "is_external": True,
                    "available": True,
                    "is_active": is_active
                })
            # 2. USB Audio DAC / Headset
            elif bus == "usb" or s_name.startswith("alsa_output.usb-"):
                is_active = (s_name == default_sink)
                endpoints.append({
                    "key": f"usb:{s_name}",
                    "type": "usb",
                    "sink_name": s_name,
                    "sink_id": obj_id,
                    "port_name": active_port,
                    "desc": desc,
                    "icon": "audio-card-usb",
                    "is_external": True,
                    "available": True,
                    "is_active": is_active
                })
            # 3. Built-in ALSA (Speaker & 3.5mm Headphone Jack)
            else:
                has_headphones = False
                has_speaker = False

                for p in ports:
                    p_name = p.get("name", "")
                    p_type = p.get("type", "")
                    p_desc = p.get("description", p_name)

                    avail = p.get("availability") or card_ports.get((card_name, p_name), "")

                    if "headphone" in p_name.lower() or p_type in ["Headphones", "Headset"]:
                        is_plugged = (avail in ["available", "yes"]) or hw_jack_plugged
                        is_active = (s_name == default_sink and active_port == p_name)
                        endpoints.append({
                            "key": f"wired:{s_name}:{p_name}",
                            "type": "wired_headphones",
                            "sink_name": s_name,
                            "sink_id": obj_id,
                            "port_name": p_name,
                            "desc": f"Wired Headphones ({p_desc})",
                            "icon": "audio-headphones",
                            "is_external": True,
                            "available": is_plugged,
                            "is_active": is_active
                        })
                        has_headphones = True

                    elif "speaker" in p_name.lower() or p_type == "Speaker":
                        is_active = (s_name == default_sink and active_port == p_name)
                        endpoints.append({
                            "key": f"speaker:{s_name}:{p_name}",
                            "type": "speaker",
                            "sink_name": s_name,
                            "sink_id": obj_id,
                            "port_name": p_name,
                            "desc": desc or "Built-in Speakers",
                            "icon": "audio-speakers",
                            "is_external": False,
                            "available": True,
                            "is_active": is_active
                        })
                        has_speaker = True

                # Fallback if no specific speaker port was enumerated
                if not has_speaker and not has_headphones:
                    is_active = (s_name == default_sink)
                    endpoints.append({
                        "key": f"speaker:{s_name}:default",
                        "type": "speaker",
                        "sink_name": s_name,
                        "sink_id": obj_id,
                        "port_name": None,
                        "desc": desc or "Built-in Speakers",
                        "icon": "audio-speakers",
                        "is_external": False,
                        "available": True,
                        "is_active": is_active
                    })

        return endpoints, default_sink, is_multi_mixer_default

    def switch_to_endpoint(self, endpoint, reason="auto"):
        sink_name = endpoint["sink_name"]
        sink_id = endpoint["sink_id"]
        port_name = endpoint.get("port_name")
        desc = endpoint["desc"]

        log(f"Executing switch_to_endpoint: {desc} ({sink_name}), port: {port_name}, reason: {reason}")

        # 1. Switch port if applicable (e.g. wired headphones / speaker)
        if port_name:
            run_cmd(["pactl", "set-sink-port", sink_name, port_name])

        # 2. Set default sink in PulseAudio, WirePlumber, and PipeWire metadata
        run_cmd(["pactl", "set-default-sink", sink_name])
        if sink_id:
            run_cmd(["wpctl", "set-default", str(sink_id)])
            # Explicitly unmute target sink
            run_cmd(["wpctl", "set-mute", str(sink_id), "0"])
        run_cmd(["pactl", "set-sink-mute", sink_name, "0"])

        run_cmd(["pw-metadata", "-n", "default", "0", "default.audio.sink", json.dumps({"name": sink_name})])
        run_cmd(["pw-metadata", "-n", "default", "0", "default.configured.audio.sink", json.dumps({"name": sink_name})])

        # 3. Hardware mixer adjustments for Realtek ALC3204 ALSA
        if "pci-0000_04_00.6" in sink_name or "analog-stereo" in sink_name:
            if endpoint["type"] == "wired_headphones":
                run_cmd(["amixer", "-c", "1", "sset", "Headphone", "unmute"])
                run_cmd(["amixer", "-c", "1", "sset", "Headphone", "80%"])
                run_cmd(["amixer", "-c", "1", "sset", "Speaker", "mute"])
            elif endpoint["type"] == "speaker":
                run_cmd(["amixer", "-c", "1", "sset", "Speaker", "unmute"])
                run_cmd(["amixer", "-c", "1", "sset", "Speaker", "80%"])
                run_cmd(["amixer", "-c", "1", "sset", "Headphone", "mute"])

        # 4. Move all currently playing audio streams to the target sink
        sink_inputs_raw = run_cmd(["pactl", "list", "short", "sink-inputs"])
        for line in sink_inputs_raw.splitlines():
            parts = line.split()
            if parts:
                input_id = parts[0]
                run_cmd(["pactl", "move-sink-input", input_id, sink_name])

        # 5. Handle microphone matching
        if endpoint["type"] == "wired_headphones":
            sources = self.get_pactl_json("sources")
            for src in sources:
                src_name = src.get("name", "")
                if "analog-stereo" in src_name:
                    for sp in src.get("ports", []):
                        sp_name = sp.get("name", "")
                        sp_avail = sp.get("availability", "")
                        if "headset" in sp_name or "headphone" in sp_name:
                            if sp_avail in ["available", "yes"]:
                                run_cmd(["pactl", "set-source-port", src_name, sp_name])
                                break
        elif endpoint["type"] == "speaker":
            sources = self.get_pactl_json("sources")
            for src in sources:
                src_name = src.get("name", "")
                if "analog-stereo" in src_name:
                    run_cmd(["pactl", "set-source-port", src_name, "analog-input-internal-mic"])

    def evaluate_and_route(self, reason_hint=""):
        endpoints, default_sink, is_multi_mixer = self.scan_endpoints()

        if is_multi_mixer:
            return {"status": "multi_mixer_active", "endpoints": endpoints}

        available_map = {ep["key"]: ep for ep in endpoints if ep["available"]}
        current_available_keys = set(available_map.keys())

        # Find currently active endpoint
        active_ep = None
        for ep in endpoints:
            if ep["is_active"]:
                active_ep = ep
                break
        active_key = active_ep["key"] if active_ep else None

        # 1. Detect newly connected/appeared endpoints
        newly_connected = current_available_keys - self.prev_available_keys

        # 2. Detect manual user selection in UI:
        # If active_key changed without any newly connected devices
        user_manual_switch = None
        if active_key and self.prev_active_key and active_key != self.prev_active_key and not newly_connected:
            user_manual_switch = active_key
            log(f"Manual UI switch detected to: {user_manual_switch}")

        # 3. Update MRU Stack
        if user_manual_switch and user_manual_switch in self.stack:
            self.stack.remove(user_manual_switch)
            self.stack.insert(0, user_manual_switch)

        # Newly connected devices are pushed to the top of the stack (most recent)
        for key in sorted(newly_connected):
            if key in self.stack:
                self.stack.remove(key)
            self.stack.insert(0, key)
            log(f"Newly connected device pushed to top of stack: {key}")

        # Ensure all currently available devices exist in stack
        for key in current_available_keys:
            if key not in self.stack:
                if available_map[key].get("is_external"):
                    self.stack.insert(0, key)
                else:
                    self.stack.append(key)

        save_stack(self.stack)

        # 4. Target endpoint is the top of the stack that is currently available
        available_stack = [k for k in self.stack if k in current_available_keys]
        if available_stack:
            target_key = available_stack[0]
        elif current_available_keys:
            target_key = list(current_available_keys)[0]
        else:
            target_key = None

        target_ep = available_map.get(target_key)
        switch_reason = None

        if newly_connected and target_key in newly_connected:
            switch_reason = "device_connected"
        elif self.prev_active_key and self.prev_active_key not in current_available_keys:
            switch_reason = "fallback_remaining_device"
        elif not active_ep:
            switch_reason = "no_active_endpoint"
        elif active_ep and target_ep and active_ep["key"] != target_ep["key"]:
            switch_reason = "mru_stack_sync"

        # Apply switch if needed
        if target_ep and (switch_reason or not active_ep or active_ep["key"] != target_ep["key"]):
            log(f"Switch triggered -> Target: {target_ep['key']} (reason: {switch_reason}). Available Stack: {available_stack}")
            self.switch_to_endpoint(target_ep, reason=switch_reason)
            active_ep = target_ep
            active_ep["is_active"] = True

        self.prev_available_keys = set(current_available_keys)
        self.prev_active_key = active_ep["key"] if active_ep else None

        result = {
            "active": active_ep,
            "endpoints": endpoints,
            "stack": available_stack,
            "reason": switch_reason or reason_hint or "synced"
        }
        return result

    def emit_state(self, reason_hint=""):
        state = self.evaluate_and_route(reason_hint=reason_hint)
        try:
            line = json.dumps(state) + "\n"
            sys.stdout.write(line)
            sys.stdout.flush()
        except BrokenPipeError:
            sys.exit(0)
        except Exception:
            pass

    def schedule_debounce(self, ms=None):
        delay = ms if ms is not None else self.debounce_ms
        if self.debounce_timer_id:
            GLib.source_remove(self.debounce_timer_id)
        self.debounce_timer_id = GLib.timeout_add(delay, self._on_debounce_trigger)

    def _on_debounce_trigger(self):
        self.debounce_timer_id = 0
        self.emit_state()
        return False

    def on_pactl_line(self, source, condition):
        if condition & GLib.IOCondition.IN:
            if not self.pactl_proc or not self.pactl_proc.stdout:
                return False
            fd = self.pactl_proc.stdout.fileno()
            should_trigger = False
            card_event = False

            while True:
                try:
                    chunk = os.read(fd, 4096)
                    if not chunk:
                        GLib.timeout_add(1000, self.start_pactl_listener)
                        return False
                    self.pactl_buf += chunk.decode("utf-8", errors="replace")
                except BlockingIOError:
                    break
                except Exception:
                    break

            if "\n" in self.pactl_buf:
                lines = self.pactl_buf.split("\n")
                self.pactl_buf = lines[-1]
                for line in lines[:-1]:
                    if any(k in line for k in ("'sink'", "'card'", "'source'")):
                        should_trigger = True
                        if "'card'" in line:
                            card_event = True
                        break

            if should_trigger:
                self.schedule_debounce()
                # If a card event occurred, also schedule follow-up retries
                # to catch delayed Bluetooth A2DP or USB audio sink registrations
                if card_event:
                    GLib.timeout_add(350, lambda: (self.emit_state("card_retry_350ms"), False)[1])
                    GLib.timeout_add(750, lambda: (self.emit_state("card_retry_750ms"), False)[1])

            return True

        if condition & (GLib.IOCondition.HUP | GLib.IOCondition.ERR):
            GLib.timeout_add(1000, self.start_pactl_listener)
            return False

        return True

    def on_jack_event(self, source, condition):
        if condition & GLib.IOCondition.IN:
            if self.jack_fd is None:
                return False
            try:
                while True:
                    data = os.read(self.jack_fd, 24)
                    if len(data) < 24:
                        break
                    # Immediate debounce on headphone jack insert/remove
                    self.schedule_debounce(40)
            except BlockingIOError:
                pass
            except Exception:
                pass
        return True

    def start_pactl_listener(self):
        try:
            if self.pactl_proc:
                self.pactl_proc.terminate()
                try:
                    self.pactl_proc.wait(timeout=0.5)
                except Exception:
                    self.pactl_proc.kill()
                    self.pactl_proc.wait(timeout=0.2)
        except Exception:
            pass

        try:
            self.pactl_buf = ""
            self.pactl_proc = subprocess.Popen(
                ["pactl", "subscribe"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL
            )
            fd = self.pactl_proc.stdout.fileno()
            fl = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)

            GLib.io_add_watch(
                fd,
                GLib.IOCondition.IN | GLib.IOCondition.HUP | GLib.IOCondition.ERR,
                self.on_pactl_line
            )
            log("pactl subscribe listener started")
        except Exception as e:
            log(f"Error starting pactl listener: {e}")
            GLib.timeout_add(2000, self.start_pactl_listener)
        return False

    def start_jack_listener(self):
        try:
            jack_path = None
            EVIOCGNAME_256 = 0x82004506
            for path in glob.glob("/dev/input/event*"):
                try:
                    with open(path, "rb") as f:
                        name_buf = array.array("B", [0] * 256)
                        fcntl.ioctl(f.fileno(), EVIOCGNAME_256, name_buf)
                        dev_name = bytes(name_buf).split(b"\x00")[0].decode("utf-8", errors="ignore").lower()
                        if "headphone" in dev_name:
                            jack_path = path
                            break
                except Exception:
                    pass

            if jack_path:
                self.jack_fd = os.open(jack_path, os.O_RDONLY | os.O_NONBLOCK)
                GLib.io_add_watch(self.jack_fd, GLib.IOCondition.IN, self.on_jack_event)
                log(f"Hardware headphone jack monitor attached to {jack_path}")
        except Exception as e:
            log(f"Note: Jack monitor not active: {e}")

    def run_daemon(self):
        set_parent_death_signal()
        log("Starting audio-autoswitch daemon...")
        if not self.acquire_lock(wait=False):
            log("Daemon already running. Blocking wait...")
            self.acquire_lock(wait=True)

        loop = GLib.MainLoop()

        def sig_handler(sig, frame):
            log("Daemon shutting down via signal")
            loop.quit()

        signal.signal(signal.SIGINT, sig_handler)
        signal.signal(signal.SIGTERM, sig_handler)

        def on_stdin_hup(source, condition):
            loop.quit()
            return False

        try:
            if not sys.stdin.isatty():
                GLib.io_add_watch(0, GLib.IOCondition.HUP | GLib.IOCondition.ERR, on_stdin_hup)
        except Exception:
            pass

        # Initial MRU state evaluation & routing
        self.emit_state("initial_startup")

        # Start listeners
        self.start_pactl_listener()
        self.start_jack_listener()

        # Periodic health check every 30 seconds
        GLib.timeout_add_seconds(30, lambda: (self.emit_state("periodic_sync"), True)[1])

        loop.run()

        if self.pactl_proc:
            try:
                self.pactl_proc.terminate()
                try:
                    self.pactl_proc.wait(timeout=0.5)
                except Exception:
                    self.pactl_proc.kill()
            except Exception:
                pass

        if self.jack_fd is not None:
            try:
                os.close(self.jack_fd)
            except Exception:
                pass
        log("Daemon terminated cleanly.")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    switcher = AudioAutoSwitcher()

    if action == "daemon":
        switcher.run_daemon()
    elif action in ["get", "status"]:
        state = switcher.evaluate_and_route("status_query")
        print(json.dumps(state, indent=2))
    elif action in ["switch-recent", "switch"]:
        state = switcher.evaluate_and_route("cli_switch")
        active = state.get("active")
        if active:
            print(f"Switched to: {active.get('desc')} ({active.get('sink_name')})")
        else:
            print("No active endpoint found.")
    else:
        print("Usage: audio-autoswitch.py {daemon|status|switch-recent}")


if __name__ == "__main__":
    main()
