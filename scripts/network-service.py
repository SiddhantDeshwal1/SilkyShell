#!/usr/bin/env python3
"""
Quickshell Network & Wi-Fi Backend Service
Provides high-performance NetworkManager DBus interaction, active connection tracking,
live D-Bus event streaming with systemd-logind sleep/wake/lid integration, and scan management.
"""

import sys
import json
import subprocess
import os
import signal
import time
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

def get_dbus_system():
    try:
        return dbus.SystemBus()
    except Exception:
        return None

def get_wifi_state(bus=None):
    if bus is None:
        bus = get_dbus_system()
    
    wifi_enabled = True
    connected = False
    ssid = ""
    signal = 0

    if bus is not None:
        try:
            nm = bus.get_object("org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager")
            props = dbus.Interface(nm, "org.freedesktop.DBus.Properties")
            wifi_enabled = bool(props.Get("org.freedesktop.NetworkManager", "WirelessEnabled"))

            if wifi_enabled:
                act_paths = props.Get("org.freedesktop.NetworkManager", "ActiveConnections")
                for p in act_paths:
                    try:
                        ac_obj = bus.get_object("org.freedesktop.NetworkManager", p)
                        ac_props = dbus.Interface(ac_obj, "org.freedesktop.DBus.Properties")
                        ctype = str(ac_props.Get("org.freedesktop.NetworkManager.Connection.Active", "Type"))
                        cstate = int(ac_props.Get("org.freedesktop.NetworkManager.Connection.Active", "State"))
                        
                        # NM_ACTIVE_CONNECTION_STATE_ACTIVATED = 2
                        if "wireless" in ctype and cstate == 2:
                            connected = True
                            ssid = str(ac_props.Get("org.freedesktop.NetworkManager.Connection.Active", "Id"))
                            
                            # Get AP signal strength
                            devs = ac_props.Get("org.freedesktop.NetworkManager.Connection.Active", "Devices")
                            for dev_p in devs:
                                d_obj = bus.get_object("org.freedesktop.NetworkManager", dev_p)
                                d_props = dbus.Interface(d_obj, "org.freedesktop.DBus.Properties")
                                try:
                                    ap_p = d_props.Get("org.freedesktop.NetworkManager.Device.Wireless", "ActiveAccessPoint")
                                    if ap_p and ap_p != "/":
                                        ap_obj = bus.get_object("org.freedesktop.NetworkManager", ap_p)
                                        ap_props = dbus.Interface(ap_obj, "org.freedesktop.DBus.Properties")
                                        signal = int(ap_props.Get("org.freedesktop.NetworkManager.AccessPoint", "Strength"))
                                        break
                                except Exception:
                                    pass
                            break
                    except Exception:
                        pass
            return {
                "enabled": wifi_enabled,
                "connected": connected,
                "ssid": ssid,
                "signal": signal
            }
        except Exception:
            pass

    # Fallback to nmcli if DBus had an issue
    try:
        g_out = subprocess.run(["nmcli", "-t", "-f", "WIFI", "g"], capture_output=True, text=True, timeout=1).stdout.strip()
        wifi_enabled = (g_out == "enabled")
        if wifi_enabled:
            d_out = subprocess.run(["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "dev"], capture_output=True, text=True, timeout=1).stdout
            for line in d_out.splitlines():
                parts = line.strip().split(":")
                if len(parts) >= 4 and parts[1] == "wifi" and parts[2] == "connected":
                    connected = True
                    ssid = parts[3]
                    break
        return {
            "enabled": wifi_enabled,
            "connected": connected,
            "ssid": ssid,
            "signal": signal or (75 if connected else 0)
        }
    except Exception:
        pass

    return {
        "enabled": False,
        "connected": False,
        "ssid": "",
        "signal": 0
    }

def get_wifi_scan(rescan=False):
    bus = get_dbus_system()
    networks = []
    seen_ssids = set()
    active_ssid = ""

    if bus is not None:
        try:
            nm = bus.get_object("org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager")
            mgr = dbus.Interface(nm, "org.freedesktop.NetworkManager")
            for dev_p in mgr.GetDevices():
                d = bus.get_object("org.freedesktop.NetworkManager", dev_p)
                dp = dbus.Interface(d, "org.freedesktop.DBus.Properties")
                if dp.Get("org.freedesktop.NetworkManager.Device", "DeviceType") == 2: # NM_DEVICE_TYPE_WIFI
                    w_dev = dbus.Interface(d, "org.freedesktop.NetworkManager.Device.Wireless")
                    if rescan:
                        try:
                            w_dev.RequestScan({})
                            time.sleep(0.3)
                        except Exception:
                            pass
                    
                    active_ap = dp.Get("org.freedesktop.NetworkManager.Device.Wireless", "ActiveAccessPoint")
                    aps = w_dev.GetAllAccessPoints()
                    for ap_p in aps:
                        try:
                            ap_obj = bus.get_object("org.freedesktop.NetworkManager", ap_p)
                            app = dbus.Interface(ap_obj, "org.freedesktop.DBus.Properties")
                            raw_ssid = bytes(app.Get("org.freedesktop.NetworkManager.AccessPoint", "Ssid"))
                            ssid = raw_ssid.decode("utf-8", "replace").strip()
                            if not ssid:
                                continue
                            sig = int(app.Get("org.freedesktop.NetworkManager.AccessPoint", "Strength"))
                            wflags = int(app.Get("org.freedesktop.NetworkManager.AccessPoint", "WpaFlags"))
                            rsnflags = int(app.Get("org.freedesktop.NetworkManager.AccessPoint", "RsnFlags"))
                            secured = (wflags > 0 or rsnflags > 0)
                            is_active = (ap_p == active_ap)
                            if is_active:
                                active_ssid = ssid

                            # Keep best signal for each SSID
                            existing = next((n for n in networks if n["ssid"] == ssid), None)
                            if existing:
                                if sig > existing["signal"] or is_active:
                                    existing["signal"] = sig
                                    if is_active:
                                        existing["isActive"] = True
                            else:
                                networks.append({
                                    "ssid": ssid,
                                    "signal": sig,
                                    "isSecured": secured,
                                    "isActive": is_active
                                })
                        except Exception:
                            pass
        except Exception:
            pass

    if not networks:
        # Fallback to nmcli
        try:
            cmd = ["nmcli", "-t", "-f", "active,ssid,signal,security", "dev", "wifi", "list", "--rescan", "yes" if rescan else "no"]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=2.5)
            for line in res.stdout.splitlines():
                parts = line.strip().split(":")
                if len(parts) >= 4 and parts[1]:
                    is_active = parts[0] == "yes"
                    ssid = parts[1]
                    sig = int(parts[2]) if parts[2].isdigit() else 50
                    sec = parts[3]
                    secured = bool(sec and sec != "--")
                    existing = next((n for n in networks if n["ssid"] == ssid), None)
                    if existing:
                        if sig > existing["signal"] or is_active:
                            existing["signal"] = sig
                            if is_active:
                                existing["isActive"] = True
                    else:
                        networks.append({
                            "ssid": ssid,
                            "signal": sig,
                            "isSecured": secured,
                            "isActive": is_active
                        })
        except Exception:
            pass

    networks.sort(key=lambda n: (1 if n["isActive"] else 0, n["signal"]), reverse=True)
    return networks

def set_wifi_radio(enable: bool):
    bus = get_dbus_system()
    if bus is not None:
        try:
            nm = bus.get_object("org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager")
            props = dbus.Interface(nm, "org.freedesktop.DBus.Properties")
            props.Set("org.freedesktop.NetworkManager", "WirelessEnabled", dbus.Boolean(1 if enable else 0))
            return
        except Exception:
            pass
    subprocess.run(["nmcli", "radio", "wifi", "on" if enable else "off"], capture_output=True)

def disconnect_wifi():
    bus = get_dbus_system()
    if bus is not None:
        try:
            nm = bus.get_object("org.freedesktop.NetworkManager", "/org/freedesktop/NetworkManager")
            mgr = dbus.Interface(nm, "org.freedesktop.NetworkManager")
            for dev_p in mgr.GetDevices():
                d = bus.get_object("org.freedesktop.NetworkManager", dev_p)
                dp = dbus.Interface(d, "org.freedesktop.DBus.Properties")
                if dp.Get("org.freedesktop.NetworkManager.Device", "DeviceType") == 2:
                    dev_iface = dbus.Interface(d, "org.freedesktop.NetworkManager.Device")
                    dev_iface.Disconnect()
                    return
        except Exception:
            pass
    subprocess.run(["sh", "-c", "nmcli dev disconnect $(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | grep ':wifi$' | cut -d: -f1 | head -n 1)"], capture_output=True)

def run_stream_daemon():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    loop = GLib.MainLoop()

    last_state = [None]
    pending_emit = [False]

    def emit_state(force=False):
        pending_emit[0] = False
        try:
            st = get_wifi_state(bus)
            encoded = json.dumps(st)
            if force or encoded != last_state[0]:
                last_state[0] = encoded
                sys.stdout.write(encoded + "\n")
                sys.stdout.flush()
        except Exception:
            pass
        return False

    def schedule_emit():
        if not pending_emit[0]:
            pending_emit[0] = True
            GLib.timeout_add(100, emit_state)

    # Initial emit
    emit_state(force=True)

    # NetworkManager signal receivers
    bus.add_signal_receiver(
        lambda *args, **kwargs: schedule_emit(),
        signal_name="PropertiesChanged",
        dbus_interface="org.freedesktop.DBus.Properties",
        bus_name="org.freedesktop.NetworkManager"
    )
    bus.add_signal_receiver(
        lambda *args, **kwargs: schedule_emit(),
        signal_name="StateChanged",
        bus_name="org.freedesktop.NetworkManager"
    )
    bus.add_signal_receiver(
        lambda *args, **kwargs: schedule_emit(),
        signal_name="DeviceAdded",
        bus_name="org.freedesktop.NetworkManager"
    )
    bus.add_signal_receiver(
        lambda *args, **kwargs: schedule_emit(),
        signal_name="DeviceRemoved",
        bus_name="org.freedesktop.NetworkManager"
    )

    # systemd-logind Sleep/Wake & Lid integration
    def on_sleep_changed(sleeping):
        if sleeping:
            # Suspending / lid closed: emit disconnected immediately
            last_state[0] = json.dumps({"enabled": True, "connected": False, "ssid": "", "signal": 0})
            sys.stdout.write(last_state[0] + "\n")
            sys.stdout.flush()
        else:
            # Resumed / lid opened: immediate query + scheduled checks for reconnection
            emit_state(force=True)
            for delay in [500, 1200, 2500, 4500, 7000]:
                GLib.timeout_add(delay, lambda: (emit_state(force=False), False)[1])

    def on_login1_prop_changed(iface, changed, invalidated):
        if "LidClosed" in changed:
            lid_closed = bool(changed["LidClosed"])
            if not lid_closed:
                # Lid opened!
                emit_state(force=True)
                for delay in [500, 1200, 2500, 4500, 7000]:
                    GLib.timeout_add(delay, lambda: (emit_state(force=False), False)[1])
        if "PreparingForSleep" in changed:
            on_sleep_changed(bool(changed["PreparingForSleep"]))

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
    except Exception:
        pass

    # Periodic heartbeat (every 3 seconds) to ensure 100% sync
    GLib.timeout_add_seconds(3, lambda: (emit_state(force=False), True)[1])

    def sig_handler(*args):
        loop.quit()

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    try:
        loop.run()
    except (KeyboardInterrupt, SystemExit):
        sig_handler()

def main():
    if len(sys.argv) < 2 or sys.argv[1] == "get":
        st = get_wifi_state()
        print(json.dumps(st))
        sys.exit(0)

    cmd = sys.argv[1]

    if cmd in ["stream", "daemon"]:
        run_stream_daemon()
    elif cmd == "scan":
        nets = get_wifi_scan(rescan=False)
        print(json.dumps(nets))
    elif cmd == "rescan":
        nets = get_wifi_scan(rescan=True)
        print(json.dumps(nets))
    elif cmd in ["radio-on", "on"]:
        set_wifi_radio(True)
        print(json.dumps({"status": "radio_on"}))
    elif cmd in ["radio-off", "off"]:
        set_wifi_radio(False)
        print(json.dumps({"status": "radio_off"}))
    elif cmd in ["radio-toggle", "toggle"]:
        st = get_wifi_state()
        set_wifi_radio(not st["enabled"])
        print(json.dumps({"status": "radio_toggled"}))
    elif cmd == "disconnect":
        disconnect_wifi()
        print(json.dumps({"status": "disconnected"}))
    else:
        print(json.dumps({"error": "unknown_command"}))
        sys.exit(1)

if __name__ == "__main__":
    main()
