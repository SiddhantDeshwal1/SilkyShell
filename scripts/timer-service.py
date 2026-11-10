#!/usr/bin/env python3
import os
import sys
import time
import json
import signal
import fcntl
import select

def set_parent_death_signal():
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6")
        libc.prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except Exception:
        pass

STATE_DIR = os.path.expanduser(os.environ.get("XDG_CACHE_HOME", "~/.cache")) + "/waybar-timer"

def ensure_dir():
    os.makedirs(STATE_DIR, exist_ok=True)

def read_file(name, default=""):
    path = os.path.join(STATE_DIR, name)
    if not os.path.exists(path):
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return default

def write_file(name, val):
    ensure_dir()
    path = os.path.join(STATE_DIR, name)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write(str(val) + "\n")
    except Exception:
        pass

def remove_file(name):
    path = os.path.join(STATE_DIR, name)
    if os.path.exists(path):
        try:
            os.remove(path)
        except Exception:
            pass

def read_int(name, default=0):
    val = read_file(name)
    try:
        return int(val)
    except (ValueError, TypeError):
        return default

def read_mode():
    val = read_file("mode", "timer")
    return val if val in ("timer", "stopwatch") else "timer"

def fmt_time(seconds):
    seconds = max(0, int(seconds))
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    if h > 0:
        return f"{h:02d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"

def get_state():
    mode = read_mode()
    running = (read_int("run") == 1)
    reset_flag = (read_int("reset_flag") == 1)
    now_s = int(time.time())
    now_ms = int(time.time() * 1000)

    duration = read_int("duration")
    
    if mode == "timer":
        if running:
            start_s = read_int("start")
            val = duration - (now_s - start_s)
        else:
            val = read_int("remaining")
        
        is_set = not reset_flag and (duration > 0 or val > 0)
        
        if is_set and val <= 0:
            overtime_sec = abs(val)
            is_overtime = True
            display = "+" + fmt_time(overtime_sec)
        else:
            overtime_sec = 0
            is_overtime = False
            display = fmt_time(max(0, val)) if is_set else "Timer"
            
        return {
            "mode": "timer",
            "running": running,
            "seconds": max(0, val) if not is_overtime else 0,
            "duration": duration,
            "overtime": overtime_sec,
            "is_overtime": is_overtime,
            "is_set": is_set,
            "display": display
        }
    else:  # stopwatch
        if running:
            start_ms = read_int("start")
            elapsed_ms = max(0, now_ms - start_ms)
        else:
            elapsed_ms = max(0, read_int("elapsed"))
        
        elapsed_s = elapsed_ms // 1000
        is_set = not reset_flag and (elapsed_s > 0 or running)
        display = fmt_time(elapsed_s) if is_set else "Timer"

        return {
            "mode": "stopwatch",
            "running": running,
            "seconds": elapsed_s,
            "duration": 0,
            "overtime": 0,
            "is_overtime": False,
            "is_set": is_set,
            "display": display
        }

def cmd_toggle():
    ensure_dir()
    mode = read_mode()
    running = (read_int("run") == 1)
    reset_flag = (read_int("reset_flag") == 1)
    now_s = int(time.time())
    now_ms = int(time.time() * 1000)

    if running:
        # Pause
        if mode == "timer":
            dur = read_int("duration")
            start_s = read_int("start")
            rem = dur - (now_s - start_s)
            write_file("remaining", rem)
        else:
            start_ms = read_int("start")
            elapsed_ms = max(0, now_ms - start_ms)
            write_file("elapsed", elapsed_ms)
        write_file("run", "0")
        write_file("start", "0")
    else:
        # Start / Resume
        remove_file("reset_flag")
        if mode == "timer":
            rem = read_int("remaining")
            dur = read_int("duration")
            # If no timer set yet or reset, switch to stopwatch as user requested
            if (rem <= 0 and dur <= 0) or reset_flag:
                write_file("mode", "stopwatch")
                write_file("start", now_ms)
                remove_file("elapsed")
                write_file("run", "1")
                return
            
            write_file("duration", rem if rem > 0 else dur)
            write_file("start", now_s)
            remove_file("remaining")
            write_file("run", "1")
        else:
            elapsed_ms = read_int("elapsed")
            if elapsed_ms <= 0:
                write_file("start", now_ms)
            else:
                write_file("start", now_ms - elapsed_ms)
            remove_file("elapsed")
            write_file("run", "1")

def cmd_set_timer(sec):
    ensure_dir()
    remove_file("notif_sent")
    write_file("mode", "timer")
    write_file("run", "0")
    write_file("start", "0")
    write_file("duration", sec)
    write_file("remaining", sec)
    write_file("elapsed", "0")
    write_file("reset_flag", "0")

def cmd_start_timer(sec):
    cmd_set_timer(sec)
    now_s = int(time.time())
    write_file("start", now_s)
    remove_file("remaining")
    write_file("run", "1")

def cmd_set_stopwatch():
    ensure_dir()
    remove_file("notif_sent")
    write_file("mode", "stopwatch")
    write_file("run", "0")
    write_file("start", "0")
    write_file("duration", "0")
    write_file("remaining", "0")
    write_file("elapsed", "0")
    write_file("reset_flag", "0")

def cmd_start_stopwatch():
    cmd_set_stopwatch()
    now_ms = int(time.time() * 1000)
    write_file("start", now_ms)
    write_file("run", "1")

def cmd_reset():
    ensure_dir()
    remove_file("notif_sent")
    write_file("mode", "timer")
    write_file("run", "0")
    write_file("start", "0")
    write_file("duration", "0")
    write_file("remaining", "0")
    write_file("elapsed", "0")
    write_file("reset_flag", "1")

def cmd_daemon():
    set_parent_death_signal()
    ensure_dir()
    try:
        lock_file = open("/tmp/quickshell_timer.lock", "a+")
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(f"{os.getpid()}\n")
        lock_file.flush()
    except (BlockingIOError, IOError):
        sys.stderr.write("[TimerService] Another daemon instance is already running. Exiting.\n")
        sys.exit(0)

    while True:
        try:
            if not sys.stdin.isatty():
                r, _, _ = select.select([sys.stdin], [], [], 0)
                if r:
                    chunk = sys.stdin.read(1)
                    if chunk == "":
                        break
            state = get_state()
            sys.stdout.write(json.dumps(state) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            break
        except Exception:
            pass
        time.sleep(0.5)

def main():
    if len(sys.argv) < 2:
        print(json.dumps(get_state()))
        return

    cmd = sys.argv[1]
    if cmd == "get":
        print(json.dumps(get_state()))
    elif cmd == "daemon":
        cmd_daemon()
    elif cmd == "toggle":
        cmd_toggle()
        print(json.dumps(get_state()))
    elif cmd == "set-timer":
        sec = int(sys.argv[2]) if len(sys.argv) > 2 else 600
        cmd_set_timer(sec)
        print(json.dumps(get_state()))
    elif cmd == "start-timer":
        sec = int(sys.argv[2]) if len(sys.argv) > 2 else 600
        cmd_start_timer(sec)
        print(json.dumps(get_state()))
    elif cmd == "set-stopwatch":
        cmd_set_stopwatch()
        print(json.dumps(get_state()))
    elif cmd == "start-stopwatch":
        cmd_start_stopwatch()
        print(json.dumps(get_state()))
    elif cmd == "reset":
        cmd_reset()
        print(json.dumps(get_state()))
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
