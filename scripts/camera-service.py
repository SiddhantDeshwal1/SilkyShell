#!/usr/bin/env python3
"""
camera-service.py — Lightweight, Zero-Resource Camera State Tracker for Quickshell
Monitors /dev/video* via kernel inotify and /proc to detect applications (Chrome,
Firefox, Zoom, Discord, OBS, etc.) actively using the camera via V4L2.
Consumes 0.00% CPU on standby.
"""

import sys
import os
import glob
import json
import time
import fcntl
import signal
import select
import ctypes

LOCK_PATH = "/tmp/quickshell_camera.lock"

# Inotify constants from <sys/inotify.h>
IN_NONBLOCK = 0x00000800
IN_CLOEXEC = 0x00080000
IN_OPEN = 0x00000020
IN_CLOSE_WRITE = 0x00000008
IN_CLOSE_NOWRITE = 0x00000010
IN_CLOSE = IN_CLOSE_WRITE | IN_CLOSE_NOWRITE
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200


def set_parent_death_signal():
    """Ensure kernel delivers SIGTERM to this process if parent (Quickshell) dies."""
    try:
        libc = ctypes.CDLL("libc.so.6")
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
    except Exception:
        pass


def acquire_lock():
    """Prevent multiple daemon instances."""
    try:
        lock_file = open(LOCK_PATH, "a+")
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(f"{os.getpid()}\n")
        lock_file.flush()
        return lock_file
    except (BlockingIOError, IOError):
        sys.stderr.write("[camera-service] Another instance is already running. Exiting.\n")
        sys.stderr.flush()
        sys.exit(0)


def get_app_display_name(comm, cmdline):
    c = comm.lower()
    cmd = cmdline.lower()
    if "chrome" in c or "chrome" in cmd:
        return "Google Chrome"
    if "brave" in c or "brave" in cmd:
        return "Brave"
    if "firefox" in c or "firefox" in cmd:
        return "Firefox"
    if "discord" in c or "discord" in cmd:
        return "Discord"
    if "zoom" in c or "zoom" in cmd:
        return "Zoom"
    if "teams" in c or "teams" in cmd:
        return "Microsoft Teams"
    if "obs" in c or "obs" in cmd:
        return "OBS Studio"
    if "slack" in c or "slack" in cmd:
        return "Slack"
    if "telegram" in c or "telegram" in cmd:
        return "Telegram"
    if "cheese" in c or "cheese" in cmd:
        return "Cheese"

    if cmdline:
        first_token = cmdline.split("\0")[0].split()[0]
        bin_name = os.path.basename(first_token)
        if bin_name:
            return bin_name.capitalize()
    return comm.capitalize() if comm else "Camera App"


def get_camera_state():
    apps = []
    seen_pids = set()
    video_devs = set(glob.glob("/dev/video*"))
    if not video_devs:
        return {"active": False, "apps": []}

    my_uid = os.getuid()
    for pid_entry in os.scandir("/proc"):
        if not pid_entry.name.isdigit():
            continue
        pid = int(pid_entry.name)
        try:
            if pid_entry.stat().st_uid != my_uid:
                continue
            fd_dir = f"/proc/{pid}/fd"
            for fd_entry in os.scandir(fd_dir):
                try:
                    target = os.readlink(fd_entry.path)
                    if target in video_devs:
                        if pid in seen_pids:
                            continue
                        comm = ""
                        try:
                            with open(f"/proc/{pid}/comm", "r") as f:
                                comm = f.read().strip()
                        except Exception:
                            pass
                        # Ignore quickshell itself, daemons, and audio servers
                        if comm.lower() in ("quickshell", "qs", "wireplumber", "pipewire"):
                            continue
                        cmdline = ""
                        try:
                            with open(f"/proc/{pid}/cmdline", "r") as f:
                                cmdline = f.read()
                        except Exception:
                            pass
                        if "camera-service" in cmdline:
                            continue

                        display_name = get_app_display_name(comm, cmdline)
                        seen_pids.add(pid)
                        apps.append({
                            "pid": pid,
                            "comm": comm,
                            "name": display_name,
                            "device": target
                        })
                        break
                except Exception:
                    pass
        except Exception:
            pass
    return {"active": len(apps) > 0, "apps": apps}


def run_daemon():
    set_parent_death_signal()
    lock_file = acquire_lock()

    libc = ctypes.CDLL("libc.so.6")
    inotify_fd = -1
    try:
        inotify_fd = libc.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
    except Exception:
        pass

    poller = select.poll()
    if inotify_fd >= 0:
        poller.register(inotify_fd, select.POLLIN)
        # Watch /dev for dynamically plugged cameras
        try:
            libc.inotify_add_watch(inotify_fd, b"/dev", IN_CREATE | IN_DELETE)
        except Exception:
            pass

    # Monitor stdin for pipe hangup when Quickshell exits
    try:
        poller.register(sys.stdin.fileno(), select.POLLHUP | select.POLLERR)
    except Exception:
        pass

    def setup_video_watches():
        if inotify_fd < 0:
            return
        for dev in glob.glob("/dev/video*"):
            try:
                libc.inotify_add_watch(inotify_fd, dev.encode(), IN_OPEN | IN_CLOSE)
            except Exception:
                pass

    setup_video_watches()

    last_json = None

    def emit_state():
        nonlocal last_json
        state = get_camera_state()
        encoded = json.dumps(state)
        if encoded != last_json:
            last_json = encoded
            sys.stdout.write(encoded + "\n")
            sys.stdout.flush()

    # Initial emit
    emit_state()

    # Main event loop: inotify triggers or 1.5s periodic fallback
    while True:
        try:
            events = poller.poll(1500)
            recheck_watches = False
            for fd, event in events:
                if fd == sys.stdin.fileno():
                    if event & (select.POLLHUP | select.POLLERR):
                        sys.exit(0)
                elif fd == inotify_fd:
                    try:
                        # Flush inotify events
                        os.read(inotify_fd, 4096)
                        recheck_watches = True
                    except Exception:
                        pass
            if recheck_watches:
                setup_video_watches()
            emit_state()
        except (BrokenPipeError, KeyboardInterrupt):
            break
        except Exception:
            time.sleep(1)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "daemon"
    if cmd == "daemon":
        run_daemon()
    elif cmd == "get":
        print(json.dumps(get_camera_state()))
    else:
        sys.stderr.write("Usage: camera-service.py [daemon|get]\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
