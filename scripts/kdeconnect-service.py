#!/usr/bin/env python3
"""
Quickshell Dynamic Island Unified Telephony & Notifications Backend Service
Integrates:
  1. ModemManager (Bluetooth AT commands for voice call monitoring, answering, and hangup)
  2. KDE Connect (Telephony packets, mobile notifications, alarms, and timers)
  3. WirePlumber / BlueZ (Hands-Free Profile hfp_hf routing)
Streams real-time JSON events over stdout for Quickshell SplitParser.
"""

import sys
import os
import json
import time
import signal
import threading
import subprocess
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

# Fix stdout buffering for instantaneous line streaming
sys.stdout.reconfigure(line_buffering=True)

class UnifiedTelephonyService:
    def __init__(self):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.session_bus = dbus.SessionBus()
        self.loop = GLib.MainLoop()
        self.active_devices = set()

        # ModemManager state
        self.sys_bus = None
        self.mm_active_call_path = None
        self.mm_active_call_id = None

        self.call_state = {
            "active": False,
            "state": "idle", # ringing | talking | idle
            "contact": "",
            "number": "",
            "start_time": 0
        }
        self.active_notifications = {}
        self.missed_calls = []
        self.phone_name = "Phone"
        self.phone_battery = 0
        self.phone_charging = False
        self.timer_state = None

        self._setup_kdeconnect_listeners()
        self._setup_modemmanager()
        self._discover_kdeconnect_devices()
        self._setup_command_listener()

        # Emit initial status and setup periodic 10s status sync
        self._emit_status()
        GLib.timeout_add_seconds(10, self._periodic_status)

    def log(self, *args):
        # Print debug to stderr so stdout is strictly clean JSON lines
        print("[TelephonyService]", *args, file=sys.stderr, flush=True)

    def emit(self, payload):
        """Emit JSON event to stdout for Quickshell SplitParser."""
        try:
            line = json.dumps(payload)
            print(line, flush=True)
        except Exception as e:
            self.log(f"Error emitting JSON: {e}")

    def _periodic_status(self):
        self._emit_status()
        return True # Keep GLib timeout repeating

    def _refresh_device_info(self):
        for dev_id in list(self.active_devices):
            try:
                # Name
                dev_obj = self.session_bus.get_object("org.kde.kdeconnect", f"/modules/kdeconnect/devices/{dev_id}")
                dev_props = dbus.Interface(dev_obj, "org.freedesktop.DBus.Properties")
                name = str(dev_props.Get("org.kde.kdeconnect.device", "name") or "")
                if name:
                    self.phone_name = name

                # Battery
                bat_obj = self.session_bus.get_object("org.kde.kdeconnect", f"/modules/kdeconnect/devices/{dev_id}/battery")
                bprops = dbus.Interface(bat_obj, "org.freedesktop.DBus.Properties")
                self.phone_battery = int(bprops.Get("org.kde.kdeconnect.device.battery", "charge"))
                self.phone_charging = bool(bprops.Get("org.kde.kdeconnect.device.battery", "isCharging"))

                # Active Notifications
                notif_obj = self.session_bus.get_object("org.kde.kdeconnect", f"/modules/kdeconnect/devices/{dev_id}/notifications")
                niface = dbus.Interface(notif_obj, "org.kde.kdeconnect.device.notifications")
                notifs = [str(n) for n in niface.activeNotifications()]
                # Prune notifications no longer active
                for nid in list(self.active_notifications.keys()):
                    if nid not in notifs and not nid.startswith("demo"):
                        del self.active_notifications[nid]
                for nid in notifs:
                    if nid not in self.active_notifications:
                        self.active_notifications[nid] = {"id": nid}
            except Exception as e:
                self.log(f"Error in _refresh_device_info for {dev_id}: {e}")

    def _emit_status(self):
        self._refresh_device_info()
        self.emit({
            "type": "status",
            "phoneName": self.phone_name,
            "battery": self.phone_battery,
            "charging": self.phone_charging,
            "notificationsCount": len(self.active_notifications),
            "missedCallsCount": len(self.missed_calls),
            "lastMissedCaller": self.missed_calls[-1]["caller"] if self.missed_calls else ""
        })

    # ═════════════════════════════════════════════════════════════════════════
    # 1. MODEMMANAGER VOICE INTEGRATION (Bluetooth AT Telephony)
    # ═════════════════════════════════════════════════════════════════════════
    def _setup_modemmanager(self):
        try:
            self.sys_bus = dbus.SystemBus()
            self.sys_bus.add_signal_receiver(
                self._on_mm_call_added,
                signal_name="CallAdded",
                dbus_interface="org.freedesktop.ModemManager1.Modem.Voice",
                path_keyword="modem_path"
            )
            self.sys_bus.add_signal_receiver(
                self._on_mm_call_deleted,
                signal_name="CallDeleted",
                dbus_interface="org.freedesktop.ModemManager1.Modem.Voice",
                path_keyword="modem_path"
            )
            self.log("ModemManager Voice signal listeners registered on SystemBus.")
            self._check_existing_mm_calls()
        except Exception as e:
            self.log(f"ModemManager setup notice (service may be inactive): {e}")

    def _check_existing_mm_calls(self):
        if not self.sys_bus:
            return
        try:
            mm_obj = self.sys_bus.get_object("org.freedesktop.ModemManager1", "/org/freedesktop/ModemManager1")
            mgr = dbus.Interface(mm_obj, "org.freedesktop.DBus.ObjectManager")
            objects = mgr.GetManagedObjects()
            for path, ifaces in objects.items():
                if "org.freedesktop.ModemManager1.Call" in ifaces:
                    props = ifaces["org.freedesktop.ModemManager1.Call"]
                    self._handle_mm_call(path, props)
        except Exception:
            pass

    def _on_mm_call_added(self, call_path, modem_path=None):
        call_path_str = str(call_path)
        self.log(f"ModemManager CallAdded: {call_path_str}")
        try:
            call_obj = self.sys_bus.get_object("org.freedesktop.ModemManager1", call_path_str)
            props_iface = dbus.Interface(call_obj, "org.freedesktop.DBus.Properties")
            props = props_iface.GetAll("org.freedesktop.ModemManager1.Call")
            self._handle_mm_call(call_path_str, props)

            # Listen to state changes on this specific call
            call_obj.connect_to_signal(
                "StateChanged",
                self._on_mm_call_state_changed,
                dbus_interface="org.freedesktop.ModemManager1.Call"
            )
        except Exception as e:
            self.log(f"Error inspecting ModemManager call {call_path_str}: {e}")

    def _on_mm_call_deleted(self, call_path, modem_path=None):
        call_path_str = str(call_path)
        self.log(f"ModemManager CallDeleted: {call_path_str}")
        if self.mm_active_call_path == call_path_str:
            self.mm_active_call_path = None
            self.call_state = {
                "active": False,
                "state": "idle",
                "contact": "",
                "number": "",
                "start_time": 0
            }
            self.emit({"type": "call", "state": "ended"})

    def _handle_mm_call(self, call_path, props):
        number = str(props.get("Number", "") or "")
        state = int(props.get("State", 0))
        self.mm_active_call_path = str(call_path)
        # Extract numeric call ID if available
        try:
            self.mm_active_call_id = str(call_path).rstrip("/").split("/")[-1]
        except Exception:
            self.mm_active_call_id = "1"

        self.log(f"ModemManager Call state={state}, number={number}")

        # State enum: 3 = MM_CALL_STATE_RINGING_IN, 4 = MM_CALL_STATE_ACTIVE
        if state == 3: # Ringing In
            contact = self._resolve_contact_name(number)
            self.call_state = {
                "active": True,
                "state": "ringing",
                "contact": contact,
                "number": number,
                "start_time": 0
            }
            self.emit({
                "type": "call",
                "state": "ringing",
                "contact": contact,
                "number": number
            })
        elif state == 4: # Active Talking
            start_t = time.time() if self.call_state["start_time"] == 0 else self.call_state["start_time"]
            contact = self.call_state.get("contact") or self._resolve_contact_name(number)
            self.call_state = {
                "active": True,
                "state": "talking",
                "contact": contact,
                "number": number,
                "start_time": start_t
            }
            self.emit({
                "type": "call",
                "state": "talking",
                "contact": contact,
                "number": number,
                "startTime": start_t
            })
        elif state in (6, 7): # Terminated
            self.mm_active_call_path = None
            self.call_state = {
                "active": False,
                "state": "idle",
                "contact": "",
                "number": "",
                "start_time": 0
            }
            self.emit({"type": "call", "state": "ended"})

    def _on_mm_call_state_changed(self, old_state, new_state, reason):
        new_state = int(new_state)
        self.log(f"ModemManager Call StateChanged: {old_state} -> {new_state} (reason: {reason})")
        if new_state == 4: # Talking
            start_t = time.time()
            self.call_state["active"] = True
            self.call_state["state"] = "talking"
            self.call_state["start_time"] = start_t
            self.emit({
                "type": "call",
                "state": "talking",
                "contact": self.call_state.get("contact", "Unknown Caller"),
                "number": self.call_state.get("number", ""),
                "startTime": start_t
            })
        elif new_state in (6, 7): # Terminated
            self.mm_active_call_path = None
            self.call_state = {
                "active": False,
                "state": "idle",
                "contact": "",
                "number": "",
                "start_time": 0
            }
            self.emit({"type": "call", "state": "ended"})

    def _resolve_contact_name(self, number):
        # Check if KDE Connect telephony cached a contact name for this number
        if self.call_state.get("contact") and self.call_state.get("contact") != "Unknown Caller":
            return self.call_state["contact"]
        return number or "Incoming Call"

    # ═════════════════════════════════════════════════════════════════════════
    # 2. KDE CONNECT INTEGRATION (Telephony, Notifications, Timers, Alarms)
    # ═════════════════════════════════════════════════════════════════════════
    def _setup_kdeconnect_listeners(self):
        try:
            self.session_bus.add_signal_receiver(
                self._on_device_added,
                signal_name="deviceAdded",
                dbus_interface="org.kde.kdeconnect.daemon",
                bus_name="org.kde.kdeconnect"
            )
            self.session_bus.add_signal_receiver(
                self._on_device_removed,
                signal_name="deviceRemoved",
                dbus_interface="org.kde.kdeconnect.daemon",
                bus_name="org.kde.kdeconnect"
            )
            self.session_bus.add_signal_receiver(
                self._on_device_visibility_changed,
                signal_name="deviceVisibilityChanged",
                dbus_interface="org.kde.kdeconnect.daemon",
                bus_name="org.kde.kdeconnect"
            )
            self.session_bus.add_signal_receiver(
                self._on_call_received,
                signal_name="callReceived",
                dbus_interface="org.kde.kdeconnect.device.telephony",
                path_keyword="device_path"
            )
            self.session_bus.add_signal_receiver(
                self._on_notification_posted,
                signal_name="notificationPosted",
                dbus_interface="org.kde.kdeconnect.device.notifications",
                path_keyword="device_path"
            )
            self.session_bus.add_signal_receiver(
                self._on_notification_removed,
                signal_name="notificationRemoved",
                dbus_interface="org.kde.kdeconnect.device.notifications",
                path_keyword="device_path"
            )
            self.session_bus.add_signal_receiver(
                self._on_all_notifications_removed,
                signal_name="allNotificationsRemoved",
                dbus_interface="org.kde.kdeconnect.device.notifications",
                path_keyword="device_path"
            )
            self.session_bus.add_signal_receiver(
                self._on_battery_refreshed,
                signal_name="refreshed",
                dbus_interface="org.kde.kdeconnect.device.battery",
                path_keyword="device_path"
            )
            self.log("KDE Connect signal listeners registered on SessionBus.")
        except Exception as e:
            self.log(f"KDE Connect signal receiver setup notice: {e}")

    def _on_battery_refreshed(self, is_charging, charge, device_path=None):
        self.phone_battery = int(charge)
        self.phone_charging = bool(is_charging)
        self._emit_status()

    def _discover_kdeconnect_devices(self):
        try:
            kdec = self.session_bus.get_object("org.kde.kdeconnect", "/modules/kdeconnect")
            iface = dbus.Interface(kdec, "org.kde.kdeconnect.daemon")
            dev_ids = iface.devices(True, True)
            for dev_id in dev_ids:
                dev_id_str = str(dev_id)
                self.active_devices.add(dev_id_str)
                self.log(f"Discovered paired KDE Connect device: {dev_id_str}")
                self._check_existing_kdeconnect_notifications(dev_id_str)
            self._emit_status()
        except Exception as e:
            self.log(f"KDE Connect device discovery error: {e}")

    def _on_device_added(self, dev_id):
        self.active_devices.add(str(dev_id))
        self.log(f"Device added: {dev_id}")
        self._emit_status()

    def _on_device_removed(self, dev_id):
        self.active_devices.discard(str(dev_id))
        self.log(f"Device removed: {dev_id}")
        self._emit_status()

    def _on_device_visibility_changed(self, dev_id, is_visible):
        if is_visible:
            self.active_devices.add(str(dev_id))
        else:
            self.active_devices.discard(str(dev_id))
        self.log(f"Device visibility changed: {dev_id} -> {is_visible}")
        self._emit_status()

    def _on_call_received(self, event, number, contact_name, device_path=None):
        event = str(event)
        number = str(number or "")
        contact = str(contact_name or number or "Unknown Caller")
        self.log(f"KDE Connect Call event: {event}, contact: {contact}, number: {number}")

        if event == "ringing":
            self.call_state = {
                "active": True,
                "state": "ringing",
                "contact": contact,
                "number": number,
                "start_time": 0
            }
            self.emit({
                "type": "call",
                "state": "ringing",
                "contact": contact,
                "number": number
            })
        elif event == "talking":
            start_t = time.time() if self.call_state["start_time"] == 0 else self.call_state["start_time"]
            self.call_state = {
                "active": True,
                "state": "talking",
                "contact": contact or self.call_state.get("contact", "Unknown Caller"),
                "number": number or self.call_state.get("number", ""),
                "start_time": start_t
            }
            self.emit({
                "type": "call",
                "state": "talking",
                "contact": self.call_state["contact"],
                "number": self.call_state["number"],
                "startTime": start_t
            })
        elif event == "missedCall":
            self.missed_calls.append({"caller": contact, "number": number, "time": time.time()})
            if len(self.missed_calls) > 50:
                self.missed_calls.pop(0)
            self.call_state = {
                "active": False,
                "state": "idle",
                "contact": "",
                "number": "",
                "start_time": 0
            }
            self.emit({
                "type": "missed_call",
                "caller": contact,
                "count": len(self.missed_calls)
            })
            self._emit_status()
        elif event in ("terminated", "ended"):
            self.call_state = {
                "active": False,
                "state": "idle",
                "contact": "",
                "number": "",
                "start_time": 0
            }
            self.emit({"type": "call", "state": "ended"})

    def _on_notification_posted(self, public_id, device_path=None):
        public_id_str = str(public_id)
        if not device_path:
            return
        notif_path = f"{device_path}/{public_id_str}"
        self._read_and_dispatch_notification(notif_path, public_id_str)

    def _read_and_dispatch_notification(self, notif_path, public_id):
        try:
            notif_obj = self.session_bus.get_object("org.kde.kdeconnect", notif_path)
            props_iface = dbus.Interface(notif_obj, "org.freedesktop.DBus.Properties")
            all_props = props_iface.GetAll("org.kde.kdeconnect.device.notifications.notification")

            app_name = str(all_props.get("appName", "") or "")
            title = str(all_props.get("title", "") or "")
            text = str(all_props.get("text", "") or "")
            ticker = str(all_props.get("ticker", "") or "")
            icon_path = str(all_props.get("iconPath", "") or "")
            dismissable = bool(all_props.get("dismissable", True))
            reply_id = str(all_props.get("replyId", "") or "")

            body = text or ticker
            self.active_notifications[public_id] = {
                "path": notif_path,
                "app": app_name,
                "title": title,
                "body": body
            }

            lower_app = app_name.lower()
            lower_title = title.lower()

            # Incoming call notification
            if ("call" in lower_app or "call" in lower_title or "phone" in lower_app) and ("incoming" in lower_title or "calling" in lower_title or "incoming" in body.lower()):
                self._on_call_received("ringing", "", title)
                return

            # Mobile timer
            if "timer" in lower_app or "timer" in lower_title or "countdown" in lower_title:
                self.emit({
                    "type": "timer",
                    "id": public_id,
                    "title": title or "Timer",
                    "body": body,
                    "active": True
                })
                return

            # Mobile alarm
            if "alarm" in lower_app or "alarm" in lower_title or "wake" in lower_title:
                self.emit({
                    "type": "alarm",
                    "id": public_id,
                    "title": title or "Alarm",
                    "body": body,
                    "active": True
                })
                return

            # Mobile app message / notification
            self.emit({
                "type": "notification",
                "id": public_id,
                "app": app_name or "Notification",
                "title": title,
                "body": body,
                "icon": icon_path,
                "dismissable": dismissable,
                "replyId": reply_id
            })
        except Exception as e:
            self.log(f"Error reading notification {notif_path}: {e}")

    def _on_notification_removed(self, public_id, device_path=None):
        public_id_str = str(public_id)
        self.active_notifications.pop(public_id_str, None)
        self.emit({"type": "notification_removed", "id": public_id_str})

    def _on_all_notifications_removed(self, device_path=None):
        self.active_notifications.clear()
        self.emit({"type": "all_notifications_removed"})

    def _check_existing_kdeconnect_notifications(self, dev_id):
        try:
            notif_mgr_path = f"/modules/kdeconnect/devices/{dev_id}/notifications"
            notif_mgr_obj = self.session_bus.get_object("org.kde.kdeconnect", notif_mgr_path)
            mgr_iface = dbus.Interface(notif_mgr_obj, "org.kde.kdeconnect.device.notifications")
            active_ids = mgr_iface.activeNotifications()
            for nid in active_ids:
                nid_str = str(nid)
                notif_path = f"{notif_mgr_path}/{nid_str}"
                self._read_and_dispatch_notification(notif_path, nid_str)
        except Exception:
            pass

    # ═════════════════════════════════════════════════════════════════════════
    # 3. CALL ACTIONS (Answer, Decline, Hangup)
    # ═════════════════════════════════════════════════════════════════════════
    def attend_call(self):
        """User answers/attends call on desktop."""
        self.log("Answering call...")

        # 1. Try ModemManager native AT command
        if self.mm_active_call_path and self.sys_bus:
            try:
                call_obj = self.sys_bus.get_object("org.freedesktop.ModemManager1", self.mm_active_call_path)
                call_iface = dbus.Interface(call_obj, "org.freedesktop.ModemManager1.Call")
                call_iface.Accept()
                self.log(f"Accepted call via ModemManager DBus: {self.mm_active_call_path}")
            except Exception as e:
                self.log(f"ModemManager Accept DBus error, trying mmcli fallback: {e}")
                cid = self.mm_active_call_id or "any"
                subprocess.run(["mmcli", "-m", "any", "-c", cid, "--accept"], capture_output=True)

        # 2. Try KDE Connect notification action
        for dev_id in self.active_devices:
            try:
                notif_mgr_path = f"/modules/kdeconnect/devices/{dev_id}/notifications"
                mgr_obj = self.session_bus.get_object("org.kde.kdeconnect", notif_mgr_path)
                mgr_iface = dbus.Interface(mgr_obj, "org.kde.kdeconnect.device.notifications")
                for nid, ninfo in list(self.active_notifications.items()):
                    if "call" in ninfo.get("app", "").lower() or "phone" in ninfo.get("app", "").lower():
                        mgr_iface.sendAction(nid, "Answer")
            except Exception:
                pass

        # Update local call state to talking
        contact = self.call_state.get("contact", "Unknown Caller")
        number = self.call_state.get("number", "")
        start_t = time.time()
        self.call_state = {
            "active": True,
            "state": "talking",
            "contact": contact,
            "number": number,
            "start_time": start_t
        }
        self.emit({
            "type": "call",
            "state": "talking",
            "contact": contact,
            "number": number,
            "startTime": start_t
        })

    def reject_call(self):
        """User declines or hangs up call."""
        self.log("Rejecting/Hanging up call...")

        # 1. Try ModemManager native AT command
        if self.mm_active_call_path and self.sys_bus:
            try:
                call_obj = self.sys_bus.get_object("org.freedesktop.ModemManager1", self.mm_active_call_path)
                call_iface = dbus.Interface(call_obj, "org.freedesktop.ModemManager1.Call")
                call_iface.Hangup()
                self.log(f"Hung up call via ModemManager DBus: {self.mm_active_call_path}")
            except Exception as e:
                self.log(f"ModemManager Hangup DBus error, trying mmcli fallback: {e}")
                cid = self.mm_active_call_id or "any"
                subprocess.run(["mmcli", "-m", "any", "-c", cid, "--hangup"], capture_output=True)

        self.mm_active_call_path = None

        # 2. Try KDE Connect decline action & dismissal
        for dev_id in self.active_devices:
            try:
                notif_mgr_path = f"/modules/kdeconnect/devices/{dev_id}/notifications"
                mgr_obj = self.session_bus.get_object("org.kde.kdeconnect", notif_mgr_path)
                mgr_iface = dbus.Interface(mgr_obj, "org.kde.kdeconnect.device.notifications")
                for nid, ninfo in list(self.active_notifications.items()):
                    if "call" in ninfo.get("app", "").lower() or "phone" in ninfo.get("app", "").lower():
                        try:
                            mgr_iface.sendAction(nid, "Decline")
                        except Exception:
                            pass
                        try:
                            notif_obj = self.session_bus.get_object("org.kde.kdeconnect", ninfo["path"])
                            notif_iface = dbus.Interface(notif_obj, "org.kde.kdeconnect.device.notifications.notification")
                            notif_iface.dismiss()
                        except Exception:
                            pass
            except Exception:
                pass

        self.call_state = {
            "active": False,
            "state": "idle",
            "contact": "",
            "number": "",
            "start_time": 0
        }
        self.emit({"type": "call", "state": "ended"})

    def dismiss_notification(self, notif_id):
        notif_id_str = str(notif_id).strip()
        self.log(f"Dismissing notification: {notif_id_str}")
        ninfo = self.active_notifications.pop(notif_id_str, None)
        dismissed = False

        # 1. Try cached DBus path
        if ninfo and "path" in ninfo:
            try:
                notif_obj = self.session_bus.get_object("org.kde.kdeconnect", ninfo["path"])
                notif_iface = dbus.Interface(notif_obj, "org.kde.kdeconnect.device.notifications.notification")
                notif_iface.dismiss()
                self.log(f"Dismissed via cached path: {ninfo['path']}")
                dismissed = True
            except Exception as e:
                self.log(f"Error dismissing via cached path: {e}")

        # 2. Fallback: Search all active devices directly via DBus
        if not dismissed:
            for dev_id in list(self.active_devices):
                notif_path = f"/modules/kdeconnect/devices/{dev_id}/notifications/{notif_id_str}"
                try:
                    notif_obj = self.session_bus.get_object("org.kde.kdeconnect", notif_path)
                    notif_iface = dbus.Interface(notif_obj, "org.kde.kdeconnect.device.notifications.notification")
                    notif_iface.dismiss()
                    self.log(f"Dismissed via device path: {notif_path}")
                    dismissed = True
                    break
                except Exception as e2:
                    self.log(f"Device path attempt {notif_path} error: {e2}")

        # 3. Always emit notification_removed so frontend island collapses immediately
        self.emit({"type": "notification_removed", "id": notif_id_str})

    # ═════════════════════════════════════════════════════════════════════════
    # 4. IPC COMMAND LISTENER (Quickshell stdin & file trigger)
    # ═════════════════════════════════════════════════════════════
    def _setup_command_listener(self):
        def handle_command(line):
            line = line.strip()
            if not line:
                return
            self.log(f"Handling command: {line}")
            try:
                if line in ("attend", "accept"):
                    self.attend_call()
                elif line in ("reject", "decline", "hangup", "end"):
                    self.reject_call()
                elif line == "toggle":
                    self.emit({"type": "toggle"})
                elif line.startswith("dismiss "):
                    nid = line.split(" ", 1)[1].strip()
                    self.dismiss_notification(nid)
                elif line.startswith("simulate "):
                    payload_str = line[len("simulate "):].strip()
                    data = json.loads(payload_str)
                    if data.get("type") == "call":
                        state = data.get("state", "ringing")
                        if state == "ringing":
                            self.call_state = {
                                "active": True,
                                "state": "ringing",
                                "contact": data.get("contact", "Saurabh"),
                                "number": data.get("number", "+91 98765 43210"),
                                "start_time": 0
                            }
                        elif state == "talking":
                            self.call_state = {
                                "active": True,
                                "state": "talking",
                                "contact": data.get("contact", "Saurabh"),
                                "number": data.get("number", "+91 98765 43210"),
                                "start_time": time.time()
                            }
                            data["startTime"] = self.call_state["start_time"]
                        elif state == "ended":
                            self.call_state = {
                                "active": False,
                                "state": "idle",
                                "contact": "",
                                "number": "",
                                "start_time": 0
                            }
                    elif data.get("type") == "missed_call":
                        self.missed_calls.append({"caller": data.get("caller", "Saurabh"), "number": "", "time": time.time()})
                    self.emit(data)
            except Exception as e:
                self.log(f"Error processing command '{line}': {e}")

        def stdin_worker():
            for line in sys.stdin:
                handle_command(line)

        def file_ipc_worker():
            cmd_file = "/tmp/quickshell-dynamic-island-cmd"
            while True:
                if os.path.exists(cmd_file):
                    try:
                        with open(cmd_file, "r") as f:
                            lines = f.readlines()
                        os.remove(cmd_file)
                        for l in lines:
                            handle_command(l)
                    except Exception:
                        pass
                    time.sleep(0.1)
                else:
                    time.sleep(1.0)

        t1 = threading.Thread(target=stdin_worker, daemon=True)
        t1.start()
        t2 = threading.Thread(target=file_ipc_worker, daemon=True)
        t2.start()

    def run(self):
        self.log("Unified Telephony Service daemon running...")
        try:
            signal.signal(signal.SIGINT, lambda *_: self.loop.quit())
            signal.signal(signal.SIGTERM, lambda *_: self.loop.quit())
        except Exception:
            pass
        try:
            self.loop.run()
        except (KeyboardInterrupt, SystemExit):
            self.log("Exiting daemon loop.")

def main():
    if len(sys.argv) > 1:
        arg = sys.argv[1]
        cmd_file = "/tmp/quickshell-dynamic-island-cmd"
        if arg == "test-call":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "call", "state": "ringing", "contact": "Saurabh", "number": "+91 98765 43210"}\n')
            print("Dispatched test-call simulation")
            return
        elif arg == "test-talking":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "call", "state": "talking", "contact": "Saurabh", "number": "+91 98765 43210"}\n')
            print("Dispatched test-talking simulation")
            return
        elif arg == "test-end":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "call", "state": "ended"}\n')
            print("Dispatched test-end simulation")
            return
        elif arg == "test-notif":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "notification", "id": "demo1", "app": "WhatsApp", "title": "Saurabh", "body": "Hey! How is the dynamic island coming along?"}\n')
            print("Dispatched test-notif simulation")
            return
        elif arg == "test-notif-long":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "notification", "id": "demo_long", "app": "LinkedIn", "title": "SingleStore Hiring Alert: Software Engineer", "body": "SingleStore just posted a 92% match Software Engineer-Engine-New Grad role. Remote / 5+ referrals. Always be the first to apply! Be an early applicant APPLY NOW."}\n')
            print("Dispatched test-notif-long simulation")
            return
        elif arg == "test-timer":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "timer", "id": "t1", "title": "Cooking Timer", "seconds": 154, "active": true}\n')
            print("Dispatched test-timer simulation")
            return
        elif arg == "test-alarm":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "alarm", "id": "a1", "title": "Morning Alarm", "body": "7:00 AM Alarm ringing", "active": true}\n')
            print("Dispatched test-alarm simulation")
            return
        elif arg == "test-missed":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "missed_call", "caller": "Saurabh", "count": 1}\n')
            print("Dispatched test-missed simulation")
            return
        elif arg == "test-status":
            with open(cmd_file, "a") as f:
                f.write('simulate {"type": "status", "phoneName": "Galaxy A35 5G", "battery": 61, "charging": false, "notificationsCount": 17, "missedCallsCount": 0, "lastMissedCaller": ""}\n')
            print("Dispatched test-status simulation")
            return
        elif arg == "dismiss" and len(sys.argv) > 2:
            target_id = sys.argv[2]
            with open(cmd_file, "a") as f:
                f.write(f"dismiss {target_id}\n")
            try:
                bus = dbus.SessionBus()
                kdec = bus.get_object("org.kde.kdeconnect", "/modules/kdeconnect")
                dev_ids = dbus.Interface(kdec, "org.kde.kdeconnect.daemon").devices(True, True)
                for dev in dev_ids:
                    try:
                        n_obj = bus.get_object("org.kde.kdeconnect", f"/modules/kdeconnect/devices/{dev}/notifications/{target_id}")
                        dbus.Interface(n_obj, "org.kde.kdeconnect.device.notifications.notification").dismiss()
                        break
                    except Exception:
                        pass
            except Exception:
                pass
            return
        elif arg in ("attend", "accept"):
            with open(cmd_file, "a") as f:
                f.write("attend\n")
            return
        elif arg in ("reject", "decline", "hangup", "end"):
            with open(cmd_file, "a") as f:
                f.write("reject\n")
            return
        elif arg == "send":
            with open(cmd_file, "a") as f:
                f.write(" ".join(sys.argv[2:]) + "\n")
            return

    service = UnifiedTelephonyService()
    service.run()

if __name__ == "__main__":
    main()
