#!/usr/bin/env python3
"""
screenshare-service.py — Zero-Churn Screen Share Border Supervisor for Quickshell
Tracks active screen sharing sessions (via xdg-desktop-portal-hyprland & PipeWire & wireless cast).
Dynamically tracks shared window position, size, and workspace visibility via Hyprland socket2.
Outputs atomic state to /tmp/qs_screenshare.json for zero-latency Quickshell overlay rendering.
"""

import sys
import os
import json
import time
import socket
import select
import signal
import threading
import subprocess
from pathlib import Path

STATE_FILE = "/tmp/qs_screenshare.json"
TARGET_FILE = "/tmp/qs_screenshare_target.json"
CAST_FILE = "/tmp/qs_screencast.json"
PID_FILE = "/tmp/qs_screenshare.pid"

def set_parent_death_signal():
    """Ensure kernel delivers SIGTERM to this process if parent terminates."""
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6")
        libc.prctl(1, signal.SIGTERM)  # 1 = PR_SET_PDEATHSIG
    except Exception:
        pass

def write_atomic_state(state):
    tmp = STATE_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(state, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, STATE_FILE)
    except Exception:
        pass

def get_current_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "isSharing": False,
        "type": "none",
        "monitor": "",
        "visible": False,
        "geometry": {"x": 0, "y": 0, "width": 0, "height": 0}
    }

def get_hypr_clients():
    try:
        res = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=1)
        return json.loads(res.stdout)
    except Exception:
        return []

def get_hypr_monitors():
    try:
        res = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True, timeout=1)
        return json.loads(res.stdout)
    except Exception:
        return []

def find_client(clients, target):
    if not target:
        return None
    t_str = str(target).strip().lower()
    for c in clients:
        addr = c.get("address", "").lower()
        if addr == t_str:
            return c
        try:
            if int(addr, 16) == int(t_str, 16):
                return c
        except Exception:
            pass
        try:
            if int(addr, 16) == int(t_str):
                return c
        except Exception:
            pass
        if t_str in c.get("class", "").lower() or t_str in c.get("title", "").lower():
            return c
    return None

def is_pipewire_or_portal_streaming():
    """
    Checks whether an active screencast session or video stream actually exists
    in PipeWire or DBus portal implementation.
    Returns True if an active stream is present, False otherwise.
    """
    # 1. Check PipeWire for active xdph stream node or active video stream input
    try:
        res = subprocess.run(["pw-cli", "ls", "Node"], capture_output=True, text=True, timeout=0.6)
        out = res.stdout
        if "xdph-streaming" in out:
            return True
        if 'media.class = "Stream/Input/Video"' in out:
            return True
    except Exception:
        pass

    # 2. Check DBus xdph portal for active session objects
    try:
        res = subprocess.run(["busctl", "--user", "tree", "org.freedesktop.impl.portal.desktop.hyprland"], capture_output=True, text=True, timeout=0.6)
        for line in res.stdout.splitlines():
            if "/session/" in line:
                return True
    except Exception:
        pass

    # 3. Check DBus main portal for active session objects
    try:
        res = subprocess.run(["busctl", "--user", "tree", "org.freedesktop.portal.Desktop"], capture_output=True, text=True, timeout=0.6)
        for line in res.stdout.splitlines():
            if "/session/" in line:
                return True
    except Exception:
        pass

    return False

class ScreenShareDaemon:
    def __init__(self):
        self.running = True
        self.lock = threading.Lock()
        self.is_sharing = False
        self.share_type = "none"  # "window" | "screen" | "region"
        self.target_address = ""
        self.target_class = ""
        self.target_title = ""
        self.target_output = ""
        self.region_geom = {"x": 0, "y": 0, "width": 0, "height": 0}
        self.manual_test = False
        self.share_start_time = 0.0

    def stop(self):
        self.running = False

    def load_pending_target(self):
        if os.path.exists(TARGET_FILE):
            try:
                with open(TARGET_FILE, "r") as f:
                    data = json.load(f)
                ttype = data.get("type", "screen")
                self.share_type = ttype
                self.manual_test = data.get("test", False)
                if ttype == "window":
                    self.target_address = data.get("address", "")
                    self.target_class = data.get("class", "")
                    self.target_title = data.get("title", "")
                elif ttype == "region":
                    self.target_output = data.get("output", "")
                    self.region_geom = {
                        "x": data.get("x", 0),
                        "y": data.get("y", 0),
                        "width": data.get("width", 0),
                        "height": data.get("height", 0)
                    }
                elif ttype == "screen":
                    self.target_output = data.get("output", "")
                return True
            except Exception:
                pass
        return False

    def emit_state(self, st):
        write_atomic_state(st)
        try:
            sys.stdout.write(json.dumps(st) + "\n")
            sys.stdout.flush()
        except Exception:
            pass

    def update_geometry_and_emit(self):
        with self.lock:
            if not self.is_sharing:
                self.emit_state({
                    "isSharing": False,
                    "type": "none",
                    "monitor": "",
                    "visible": False,
                    "geometry": {"x": 0, "y": 0, "width": 0, "height": 0}
                })
                return

            monitors = get_hypr_monitors()
            primary_mon = monitors[0] if monitors else {"name": "eDP-1", "x": 0, "y": 0, "width": 1920, "height": 1080, "activeWorkspace": {"id": 1}}

            if self.share_type == "window":
                clients = get_hypr_clients()
                client = find_client(clients, self.target_address or self.target_class)
                if not client:
                    self.emit_state({
                        "isSharing": True,
                        "type": "window",
                        "target": self.target_class or "Unknown",
                        "windowAddress": self.target_address,
                        "visible": False,
                        "geometry": {"x": 0, "y": 0, "width": 0, "height": 0}
                    })
                    return

                win_mon_id = client.get("monitor", 0)
                win_mon = primary_mon
                for m in monitors:
                    if m.get("id") == win_mon_id or m.get("name") == str(win_mon_id):
                        win_mon = m
                        break

                active_ws_id = win_mon.get("activeWorkspace", {}).get("id", 1)
                win_ws_id = client.get("workspace", {}).get("id", 1)
                is_pinned = client.get("pinned", False)

                is_visible = (win_ws_id == active_ws_id) or is_pinned

                at = client.get("at", [0, 0])
                size = client.get("size", [0, 0])
                mon_x = win_mon.get("x", 0)
                mon_y = win_mon.get("y", 0)

                local_x = at[0] - mon_x
                local_y = at[1] - mon_y

                self.emit_state({
                    "isSharing": True,
                    "type": "window",
                    "monitor": win_mon.get("name", "eDP-1"),
                    "windowAddress": client.get("address", self.target_address),
                    "class": client.get("class", self.target_class),
                    "title": client.get("title", self.target_title),
                    "workspace": win_ws_id,
                    "activeWorkspace": active_ws_id,
                    "visible": is_visible,
                    "geometry": {
                        "x": local_x,
                        "y": local_y,
                        "width": size[0],
                        "height": size[1]
                    }
                })

            elif self.share_type == "region":
                out_name = self.region_geom.get("output") or self.target_output or primary_mon.get("name", "eDP-1")
                self.emit_state({
                    "isSharing": True,
                    "type": "region",
                    "monitor": out_name,
                    "visible": True,
                    "geometry": self.region_geom
                })

            elif self.share_type == "screen":
                out_name = self.target_output or primary_mon.get("name", "eDP-1")
                target_mon = primary_mon
                for m in monitors:
                    if m.get("name") == out_name:
                        target_mon = m
                        break

                self.emit_state({
                    "isSharing": True,
                    "type": "screen",
                    "monitor": target_mon.get("name", "eDP-1"),
                    "visible": True,
                    "geometry": {
                        "x": 0,
                        "y": 0,
                        "width": target_mon.get("width", 1920),
                        "height": target_mon.get("height", 1080)
                    }
                })

    def target_file_loop(self):
        """Watches /tmp/qs_screenshare_target.json for instant activation when picker finishes,
        and periodically verifies PipeWire/DBus stream health to immediately unmap when sharing stops."""
        last_mtime = 0
        last_check = 0.0
        while self.running:
            now = time.time()
            if os.path.exists(TARGET_FILE):
                try:
                    mtime = os.path.getmtime(TARGET_FILE)
                    if mtime != last_mtime:
                        last_mtime = mtime
                        with self.lock:
                            if self.load_pending_target():
                                self.is_sharing = (self.share_type != "none")
                                self.share_start_time = now
                                last_check = 0.0
                        self.update_geometry_and_emit()
                    elif self.is_sharing and not self.manual_test and self.share_type != "none":
                        # Check PipeWire & DBus stream health after a 3.0s initial startup grace period
                        if (now - self.share_start_time > 3.0) and (now - last_check >= 0.5):
                            last_check = now
                            if not is_pipewire_or_portal_streaming():
                                with self.lock:
                                    self.is_sharing = False
                                    self.share_type = "none"
                                try:
                                    if os.path.exists(TARGET_FILE):
                                        os.remove(TARGET_FILE)
                                except Exception:
                                    pass
                                self.update_geometry_and_emit()
                except Exception:
                    pass
            else:
                if self.is_sharing:
                    with self.lock:
                        self.is_sharing = False
                        self.share_type = "none"
                        self.manual_test = False
                    self.update_geometry_and_emit()
            time.sleep(0.15)

    def journal_loop(self):
        """Follows xdg-desktop-portal-hyprland logs for sharing start/stop events with unbuffered I/O."""
        cmd = ["stdbuf", "-oL", "-eL", "journalctl", "--user", "-u", "xdg-desktop-portal-hyprland", "-f", "-o", "cat", "-n", "0"]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            for line in proc.stdout:
                if not self.running:
                    break
                line = line.strip()

                if "Selection:" in line:
                    idx = line.find("Selection:")
                    sel = line[idx + len("Selection:"):].strip().lstrip("r").lstrip("/")
                    with self.lock:
                        self.load_pending_target()
                        if sel.startswith("screen:"):
                            self.share_type = "screen"
                            self.target_output = sel.split("screen:", 1)[1].strip()
                        elif sel.startswith("window:"):
                            self.share_type = "window"
                            w_id = sel.split("window:", 1)[1].strip()
                            if not self.target_address:
                                self.target_address = w_id
                        elif sel.startswith("region:"):
                            self.share_type = "region"
                        self.is_sharing = True
                        self.share_start_time = time.time()
                    self.update_geometry_and_emit()

                elif "Sharing initialized" in line:
                    with self.lock:
                        self.load_pending_target()
                        self.is_sharing = True
                        self.share_start_time = time.time()
                    self.update_geometry_and_emit()

                elif "Stream destroyed" in line or "Session destroyed" in line:
                    with self.lock:
                        if not self.manual_test:
                            self.is_sharing = False
                            self.share_type = "none"
                    try:
                        if os.path.exists(TARGET_FILE):
                            os.remove(TARGET_FILE)
                    except Exception:
                        pass
                    self.update_geometry_and_emit()
        except Exception:
            pass

    def cast_loop(self):
        """Polls or watches wireless screen casting status (/tmp/qs_screencast.json)."""
        last_mtime = 0
        while self.running:
            if os.path.exists(CAST_FILE):
                try:
                    mtime = os.path.getmtime(CAST_FILE)
                    if mtime != last_mtime:
                        last_mtime = mtime
                        with open(CAST_FILE, "r") as f:
                            cdata = json.load(f)
                        if cdata.get("connected") and not self.is_sharing:
                            with self.lock:
                                self.is_sharing = True
                                self.share_type = "screen"
                                self.target_output = ""
                            self.update_geometry_and_emit()
                        elif not cdata.get("connected") and self.is_sharing and self.share_type == "screen" and not self.manual_test:
                            with self.lock:
                                self.is_sharing = False
                                self.share_type = "none"
                            self.update_geometry_and_emit()
                except Exception:
                    pass
            time.sleep(1.0)

    def hypr_socket_loop(self):
        """Connects to Hyprland socket2 for real-time window tracking events."""
        sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
        sock_path = f"/run/user/{os.getuid()}/hypr/{sig}/.socket2.sock"

        while self.running:
            if not os.path.exists(sock_path):
                time.sleep(1.0)
                continue

            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(sock_path)
                s.setblocking(True)
                f = s.makefile("r", encoding="utf-8", errors="replace")

                for line in f:
                    if not self.running:
                        break
                    event = line.strip()
                    if not event:
                        continue

                    # Events that affect window position, size, or workspace
                    if any(event.startswith(k) for k in [
                        "movewindow", "resizewindow", "workspace", "focusedmon",
                        "closewindow", "fullscreen", "changefloatingmode"
                    ]):
                        if self.is_sharing and self.share_type == "window":
                            self.update_geometry_and_emit()

                s.close()
            except Exception:
                time.sleep(1.0)

    def run(self):
        with open(PID_FILE, "w") as f:
            f.write(str(os.getpid()))

        t_target = threading.Thread(target=self.target_file_loop, daemon=True)
        t_target.start()

        t_journal = threading.Thread(target=self.journal_loop, daemon=True)
        t_journal.start()

        t_cast = threading.Thread(target=self.cast_loop, daemon=True)
        t_cast.start()

        t_socket = threading.Thread(target=self.hypr_socket_loop, daemon=True)
        t_socket.start()

        # Emit initial state
        self.update_geometry_and_emit()

        # Keep alive
        try:
            while self.running:
                time.sleep(1.0)
        except (KeyboardInterrupt, SystemExit):
            pass
        finally:
            write_atomic_state({
                "isSharing": False,
                "type": "none",
                "monitor": "",
                "visible": False,
                "geometry": {"x": 0, "y": 0, "width": 0, "height": 0}
            })
            if os.path.exists(PID_FILE):
                try:
                    os.remove(PID_FILE)
                except Exception:
                    pass

def main():
    set_parent_death_signal()

    if len(sys.argv) < 2:
        cmd = "status"
    else:
        cmd = sys.argv[1].lower()

    if cmd == "status":
        print(json.dumps(get_current_state(), indent=2))

    elif cmd == "daemon":
        daemon = ScreenShareDaemon()
        def sig_handler(sig, frame):
            daemon.stop()
            sys.exit(0)
        signal.signal(signal.SIGTERM, sig_handler)
        signal.signal(signal.SIGINT, sig_handler)
        daemon.run()

    elif cmd == "test-window":
        target = sys.argv[2] if len(sys.argv) > 2 else "chrome"
        clients = get_hypr_clients()
        client = find_client(clients, target)
        if not client:
            print(json.dumps({"error": f"Client '{target}' not found"}))
            sys.exit(1)

        monitors = get_hypr_monitors()
        primary_mon = monitors[0] if monitors else {"name": "eDP-1", "x": 0, "y": 0, "activeWorkspace": {"id": 1}}
        win_mon_id = client.get("monitor", 0)
        win_mon = primary_mon
        for m in monitors:
            if m.get("id") == win_mon_id or m.get("name") == str(win_mon_id):
                win_mon = m
                break

        at = client.get("at", [0, 0])
        size = client.get("size", [0, 0])
        local_x = at[0] - win_mon.get("x", 0)
        local_y = at[1] - win_mon.get("y", 0)

        active_ws_id = win_mon.get("activeWorkspace", {}).get("id", 1)
        win_ws_id = client.get("workspace", {}).get("id", 1)

        st = {
            "isSharing": True,
            "type": "window",
            "monitor": win_mon.get("name", "eDP-1"),
            "windowAddress": client.get("address"),
            "class": client.get("class"),
            "title": client.get("title"),
            "workspace": win_ws_id,
            "activeWorkspace": active_ws_id,
            "visible": (win_ws_id == active_ws_id),
            "geometry": {
                "x": local_x,
                "y": local_y,
                "width": size[0],
                "height": size[1]
            }
        }
        tgt = {
            "type": "window",
            "address": client.get("address"),
            "class": client.get("class"),
            "title": client.get("title"),
            "test": True
        }
        try:
            with open(TARGET_FILE, "w") as f:
                json.dump(tgt, f)
        except Exception:
            pass
        write_atomic_state(st)
        print(json.dumps(st, indent=2))

    elif cmd == "test-region":
        geom_str = sys.argv[2] if len(sys.argv) > 2 else "100,100 800x600"
        x, y, w, h = 100, 100, 800, 600
        try:
            if " " in geom_str:
                xy, wh = geom_str.split(" ")
                x, y = map(int, xy.split(","))
                w, h = map(int, wh.split("x"))
            elif "," in geom_str:
                parts = list(map(int, geom_str.split(",")))
                if len(parts) >= 4:
                    x, y, w, h = parts[0], parts[1], parts[2], parts[3]
        except Exception:
            pass

        tgt = {
            "type": "region",
            "output": "eDP-1",
            "x": x, "y": y, "width": w, "height": h,
            "test": True
        }
        try:
            with open(TARGET_FILE, "w") as f:
                json.dump(tgt, f)
        except Exception:
            pass

        st = {
            "isSharing": True,
            "type": "region",
            "monitor": "eDP-1",
            "visible": True,
            "geometry": {"x": x, "y": y, "width": w, "height": h}
        }
        write_atomic_state(st)
        print(json.dumps(st, indent=2))

    elif cmd == "test-screen":
        mon_name = sys.argv[2] if len(sys.argv) > 2 else "eDP-1"
        monitors = get_hypr_monitors()
        target_mon = monitors[0] if monitors else {"width": 1920, "height": 1080}
        for m in monitors:
            if m.get("name") == mon_name:
                target_mon = m
                break

        tgt = {
            "type": "screen",
            "output": target_mon.get("name", "eDP-1"),
            "test": True
        }
        try:
            with open(TARGET_FILE, "w") as f:
                json.dump(tgt, f)
        except Exception:
            pass

        st = {
            "isSharing": True,
            "type": "screen",
            "monitor": target_mon.get("name", "eDP-1"),
            "visible": True,
            "geometry": {
                "x": 0,
                "y": 0,
                "width": target_mon.get("width", 1920),
                "height": target_mon.get("height", 1080)
            }
        }
        write_atomic_state(st)
        print(json.dumps(st, indent=2))

    elif cmd == "stop":
        st = {
            "isSharing": False,
            "type": "none",
            "monitor": "",
            "visible": False,
            "geometry": {"x": 0, "y": 0, "width": 0, "height": 0}
        }
        write_atomic_state(st)
        try:
            if os.path.exists(TARGET_FILE):
                os.remove(TARGET_FILE)
        except Exception:
            pass
        print(json.dumps(st, indent=2))

    else:
        print(json.dumps({"error": f"Unknown command '{cmd}'"}))

if __name__ == "__main__":
    main()
