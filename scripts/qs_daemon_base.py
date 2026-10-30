#!/usr/bin/env python3
"""
Shared base class for QuickShell D-Bus daemon services.
Provides:
  - Singleton file locking (prevents duplicate instances)
  - Stdin hangup detection (immediate exit when Quickshell exits or restarts)
  - Linux PR_SET_PDEATHSIG (kernel-delivered SIGTERM on parent death)
  - Explicit BrokenPipeError termination
  - Debounced emit_state, sleep/lid monitoring, SIGTERM cleanup, heartbeat
Subclasses implement get_state(bus) and optionally setup_extra_signals(bus, schedule_emit).
"""
import sys
import os
import json
import signal
import fcntl
import dbus
import dbus.mainloop.glib
from gi.repository import GLib

def set_parent_death_signal():
    """Ensure kernel delivers SIGTERM to this process if parent dies."""
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6")
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
    except Exception:
        pass

class QSDaemonBase:
    """Inherit from this and implement get_state(bus) -> dict."""

    service_name = "daemon"
    DEBOUNCE_MS = 100
    HEARTBEAT_S = 30

    def __init__(self, service_name=None):
        if service_name:
            self.service_name = service_name
        self.lock_file = None

    def acquire_lock(self):
        """Acquire singleton file lock. Exits immediately if another daemon is running."""
        try:
            lock_dir = "/tmp"
            lock_path = os.path.join(lock_dir, f"quickshell_{self.service_name}.lock")
            self.lock_file = open(lock_path, "a+")
            fcntl.flock(self.lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.lock_file.seek(0)
            self.lock_file.truncate()
            self.lock_file.write(f"{os.getpid()}\n")
            self.lock_file.flush()
            return True
        except (BlockingIOError, IOError):
            sys.stderr.write(f"[{self.service_name}] Another instance is already running. Exiting.\n")
            sys.stderr.flush()
            sys.exit(0)

    def get_state(self, bus) -> dict:
        raise NotImplementedError

    def setup_extra_signals(self, bus, schedule_emit):
        """Override to add subsystem-specific D-Bus signal receivers."""
        pass

    def run(self):
        set_parent_death_signal()
        self.acquire_lock()

        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        bus = dbus.SystemBus()
        loop = GLib.MainLoop()

        last_state = [None]
        pending_emit = [False]

        def emit_state(force=False):
            pending_emit[0] = False
            try:
                st = self.get_state(bus)
                encoded = json.dumps(st)
                if force or encoded != last_state[0]:
                    last_state[0] = encoded
                    sys.stdout.write(encoded + '\n')
                    sys.stdout.flush()
            except BrokenPipeError:
                # Quickshell closed the reading end of stdout
                loop.quit()
                return False
            except Exception:
                pass
            return False

        def schedule_emit():
            if not pending_emit[0]:
                pending_emit[0] = True
                GLib.timeout_add(self.DEBOUNCE_MS, emit_state)

        # Monitor stdin for HUP (Quickshell exit/restart terminates the pipe immediately)
        try:
            def on_stdin_hup(source, condition):
                self.on_shutdown(bus)
                loop.quit()
                return False

            GLib.io_add_watch(0, GLib.IOCondition.HUP | GLib.IOCondition.ERR, on_stdin_hup)
        except Exception:
            pass

        # Subsystem-specific signals
        self.setup_extra_signals(bus, schedule_emit)

        # systemd-logind: sleep/resume + lid open/close
        def on_sleep_changed(sleeping):
            if sleeping:
                self.on_suspend(last_state, bus)
            else:
                emit_state(force=True)
                for delay in [500, 1500, 3000, 5500]:
                    GLib.timeout_add(delay, lambda: (emit_state(force=False), False)[1])

        def on_login1_prop_changed(iface, changed, invalidated):
            if 'LidClosed' in changed:
                if not bool(changed['LidClosed']):
                    emit_state(force=True)
                    for delay in [500, 1500, 3000, 5500]:
                        GLib.timeout_add(delay, lambda: (emit_state(force=False), False)[1])
            if 'PreparingForSleep' in changed:
                on_sleep_changed(bool(changed['PreparingForSleep']))

        try:
            bus.add_signal_receiver(
                on_sleep_changed,
                signal_name='PrepareForSleep',
                dbus_interface='org.freedesktop.login1.Manager',
                bus_name='org.freedesktop.login1'
            )
            bus.add_signal_receiver(
                on_login1_prop_changed,
                signal_name='PropertiesChanged',
                dbus_interface='org.freedesktop.DBus.Properties',
                bus_name='org.freedesktop.login1'
            )
        except Exception:
            pass

        # Heartbeat — guard for missed signals
        GLib.timeout_add_seconds(self.HEARTBEAT_S, lambda: (emit_state(force=False), True)[1])

        # Emit initial state
        emit_state(force=True)

        def sig_handler(*args):
            self.on_shutdown(bus)
            loop.quit()

        signal.signal(signal.SIGINT, sig_handler)
        signal.signal(signal.SIGTERM, sig_handler)

        try:
            loop.run()
        except (KeyboardInterrupt, SystemExit):
            sig_handler()

    def on_suspend(self, last_state, bus):
        """Called when system is going to sleep. Override to customize pre-sleep state."""
        pass

    def on_shutdown(self, bus):
        """Called on SIGTERM/SIGINT/HUP. Override for cleanup."""
        if self.lock_file:
            try:
                fcntl.flock(self.lock_file.fileno(), fcntl.LOCK_UN)
                self.lock_file.close()
                self.lock_file = None
            except Exception:
                pass
