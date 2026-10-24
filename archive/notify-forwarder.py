#!/usr/bin/env python3
"""Forward D-Bus notifications to quickshell via a shared state file."""

import dbus
import dbus.mainloop.glib
import json
import os
import time
import sys

from gi.repository import GLib

NOTIFICATIONS_BUS_NAME = "org.freedesktop.Notifications"
NOTIFICATIONS_OBJECT_PATH = "/org/freedesktop/Notifications"
STATE_FILE = "/tmp/quickshell-notify-state.json"

# The QML NotificationWidget expects these properties:
# - title: string
# - body: string  
# - timeout: int (milliseconds, default 5000)


def write_notification_state(title, body, timeout=5000, app_name="", icon=""):
    """Write notification state to file that quickshell QML monitors."""
    state = {
        "title": title,
        "body": body,
        "timeout": timeout,
        "app_name": app_name,
        "icon": icon,
        "timestamp": time.time()
    }
    with open(STATE_FILE, "w") as f:
        json.dump(state, f)


def notify_changed_callback(*args):
    """This is a GLib callback - we use the main loop instead."""
    pass


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()

    # Add a message filter to catch Notification.Notify calls
    def message_filter(message):
        if message.get_member() != "Notify":
            return True

        try:
            args = message.get_args()
            if len(args) < 7:
                return True

            summary = args[0] if len(args) > 0 else ""
            replaces_id = args[1] if len(args) > 1 else 0
            body = args[2] if len(args) > 2 else ""
            app_name = args[3] if len(args) > 3 else ""
            icon_value = args[4] if len(args) > 4 else ""
            actions = args[5] if len(args) > 5 else []
            hints = args[6] if len(args) > 6 else {}
            expire_timeout = args[7] if len(args) > 7 else 5000

            # Write state file for quickshell to read
            write_notification_state(
                title=summary,
                body=body,
                timeout=expire_timeout * 1000,  # convert to ms
                app_name=app_name,
                icon=str(icon_value)
            )

            # Also print for debugging
            print(f"Forwarded notification: {summary} - {body}", flush=True)
        except Exception as e:
            print(f"Error parsing notification: {e}", flush=True)

        return True

    bus.add_match_string(
        "type='method_call',member='Notify',"
        "destination='org.freedesktop.Notifications'"
    )
    bus.add_message_filter(message_filter)

    # Keep running
    loop = GLib.MainLoop()
    loop.run()


if __name__ == "__main__":
    main()