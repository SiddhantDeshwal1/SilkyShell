#!/usr/bin/env python3
"""
Quickshell Bluetooth Backend Service
Provides high-performance BlueZ DBus interaction, active discovery daemon with
pairing Agent support (PINs/Passkeys/SSP), and PipeWire/PulseAudio codec management.
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

AGENT_PATH = "/org/bluez/quickshell_agent"
CAPABILITY = "NoInputNoOutput"

class BluezAgent(dbus.service.Object):
    def __init__(self, bus, path):
        super().__init__(bus, path)

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        return

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        return "0000"

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        return dbus.UInt32(0)

    @dbus.service.method("org.bluez.Agent1", in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        pass

    @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        return

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        return

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Cancel(self):
        pass


def get_dbus_system():
    try:
        return dbus.SystemBus()
    except Exception:
        return None

def get_adapter(bus=None):
    if bus is None:
        bus = get_dbus_system()
    if bus is None:
        return None, None
    try:
        bluez = bus.get_object("org.bluez", "/")
        mgr = dbus.Interface(bluez, "org.freedesktop.DBus.ObjectManager")
        objects = mgr.GetManagedObjects()
        for path, ifaces in objects.items():
            if "org.bluez.Adapter1" in ifaces:
                adapter_obj = bus.get_object("org.bluez", path)
                return adapter_obj, path
    except Exception:
        pass
    return None, None

def classify_device(name, icon_prop, dev_class):
    n = (name or "").lower()
    icon = (icon_prop or "").lower()

    if "mouse" in icon or "mouse" in n or "m650" in n or "mx " in n or "trackball" in n:
        return "mouse"
    if "keyboard" in icon or "keyboard" in n or "keychron" in n or "k380" in n or "k850" in n:
        return "keyboard"
    if "head" in icon or "audio" in icon or "headphone" in n or "headset" in n or "wf-" in n or "wh-" in n or "earbuds" in n or "buds" in n or "airpod" in n or "c710n" in n or "soundcore" in n or "speaker" in n:
        return "headphones"
    if "watch" in icon or "watch" in n or "band" in n or "fit" in n:
        return "watch"
    if "phone" in icon or "phone" in n or "iphone" in n or "pixel" in n or "galaxy" in n or "android" in n:
        return "phone"
    if "computer" in icon or "laptop" in n or "desktop" in n:
        return "laptop"
    
    if dev_class:
        try:
            cls_val = int(dev_class)
            major = (cls_val >> 8) & 0x1F
            if major == 4:
                return "headphones"
            elif major == 5:
                minor = (cls_val >> 2) & 0x3F
                if minor & 0x10:
                    return "keyboard"
                elif minor & 0x20:
                    return "mouse"
            elif major == 2:
                return "phone"
        except Exception:
            pass

    return "bluetooth"

def format_profile_name(profile_id, desc=""):
    pid = profile_id.lower()
    if "ldac" in pid: return "LDAC"
    if "aac" in pid: return "AAC"
    if "sbc_xq" in pid or "sbc-xq" in pid: return "SBC-XQ"
    if "sbc" in pid: return "SBC"
    if "aptx_hd" in pid or "aptx-hd" in pid: return "aptX HD"
    if "aptx" in pid: return "aptX"
    if "opus" in pid: return "Opus"
    if "lc3" in pid: return "LC3"
    if "a2dp" in pid: return "A2DP High-Res"
    if "headset" in pid or "hfp" in pid or "hsp" in pid or "msbc" in pid or "cvsd" in pid: return "Headset Mic"
    if "off" in pid: return "Off"
    
    clean = profile_id.replace("a2dp-sink-", "").replace("a2dp-sink", "A2DP").replace("headset-head-unit-", "HFP ")
    return clean.upper() if len(clean) <= 6 else clean.title()

def get_audio_card_info():
    try:
        res = subprocess.run(["pactl", "-f", "json", "list", "cards"], capture_output=True, text=True, timeout=1.5)
        if res.returncode != 0 or not res.stdout.strip():
            return None
        cards = json.loads(res.stdout)
        for card in cards:
            cname = card.get("name", "")
            if "bluez" in cname:
                active_profile = card.get("active_profile", "")
                raw_profiles = card.get("profiles", {})
                profile_list = []
                for pid, pdata in raw_profiles.items():
                    if pid == "off" or pid == "pro-audio":
                        continue
                    desc = pdata.get("description", "")
                    avail = pdata.get("available", True)
                    profile_list.append({
                        "id": pid,
                        "name": format_profile_name(pid, desc),
                        "description": desc,
                        "available": avail
                    })
                
                def prof_sort_key(p):
                    pid = p["id"].lower()
                    if "ldac" in pid: return 1
                    if "aptx_hd" in pid: return 2
                    if "aptx" in pid: return 3
                    if "aac" in pid: return 4
                    if "sbc_xq" in pid: return 5
                    if "sbc" in pid: return 6
                    if "a2dp" in pid: return 7
                    if "headset" in pid: return 8
                    return 9
                profile_list.sort(key=prof_sort_key)

                return {
                    "card_name": cname,
                    "active_profile": active_profile,
                    "profiles": profile_list
                }
    except Exception:
        pass
    return None

def get_full_state(bus=None):
    if bus is None:
        bus = get_dbus_system()
    powered = False
    discovering = False
    devices_list = []
    
    if bus is not None:
        try:
            bluez = bus.get_object("org.bluez", "/")
            mgr = dbus.Interface(bluez, "org.freedesktop.DBus.ObjectManager")
            objects = mgr.GetManagedObjects()

            for path, ifaces in objects.items():
                if "org.bluez.Adapter1" in ifaces:
                    props = ifaces["org.bluez.Adapter1"]
                    powered = bool(props.get("Powered", 0))
                    discovering = bool(props.get("Discovering", 0))

                elif "org.bluez.Device1" in ifaces:
                    props = ifaces["org.bluez.Device1"]
                    mac = str(props.get("Address", ""))
                    name = str(props.get("Alias", props.get("Name", mac)))
                    icon_prop = str(props.get("Icon", ""))
                    dev_class = props.get("Class", None)
                    paired = bool(props.get("Paired", 0))
                    connected = bool(props.get("Connected", 0))
                    rssi = int(props.get("RSSI", -999)) if "RSSI" in props else None
                    
                    bat = ""
                    if "org.bluez.Battery1" in ifaces:
                        bat_val = ifaces["org.bluez.Battery1"].get("Percentage", None)
                        if bat_val is not None:
                            bat = str(bat_val)
                    
                    icon_type = classify_device(name, icon_prop, dev_class)

                    state = "available"
                    if connected:
                        state = "connected"
                    elif paired:
                        state = "paired"

                    devices_list.append({
                        "mac": mac,
                        "name": name,
                        "iconType": icon_type,
                        "state": state,
                        "isConnected": connected,
                        "isPaired": paired,
                        "battery": bat,
                        "rssi": rssi
                    })
        except Exception:
            pass

    def dev_sort_key(d):
        rank = 0
        if d["isConnected"]:
            rank = 3
        elif d["isPaired"]:
            rank = 2
        else:
            rank = 1
        
        has_real_name = (d["name"] != d["mac"] and not d["name"].replace("-", ":").lower() == d["mac"].lower())
        name_bonus = 1 if has_real_name else 0
        rssi_val = d["rssi"] if d["rssi"] is not None else -100
        return (rank, name_bonus, rssi_val)

    devices_list.sort(key=dev_sort_key, reverse=True)
    connected_dev = next((d["name"] for d in devices_list if d["isConnected"]), "")
    audio_card = get_audio_card_info()

    return {
        "powered": powered,
        "discovering": discovering,
        "connectedDevice": connected_dev,
        "devices": devices_list,
        "audioCard": audio_card
    }

def set_power(power_on: bool):
    bus = get_dbus_system()
    adapter, _ = get_adapter(bus)
    if power_on:
        subprocess.run(["rfkill", "unblock", "bluetooth"], capture_output=True)
    if adapter:
        try:
            props = dbus.Interface(adapter, "org.freedesktop.DBus.Properties")
            props.Set("org.bluez.Adapter1", "Powered", dbus.Boolean(1 if power_on else 0))
        except Exception:
            subprocess.run(["bluetoothctl", "power", "on" if power_on else "off"], capture_output=True)
    else:
        subprocess.run(["bluetoothctl", "power", "on" if power_on else "off"], capture_output=True)

    if not power_on:
        subprocess.run(["rfkill", "block", "bluetooth"], capture_output=True)

def connect_device(mac, timeout=10):
    try:
        res = subprocess.run(["bluetoothctl", "connect", mac], capture_output=True, text=True, timeout=timeout)
        success = res.returncode == 0 and "Connection successful" in res.stdout
        print(json.dumps({"status": "connected" if success else "failed", "mac": mac, "output": res.stdout.strip()}))
    except subprocess.TimeoutExpired:
        print(json.dumps({"status": "timeout", "mac": mac}))
    except Exception as e:
        print(json.dumps({"status": "error", "mac": mac, "error": str(e)}))

def disconnect_device(mac, timeout=6):
    try:
        res = subprocess.run(["bluetoothctl", "disconnect", mac], capture_output=True, text=True, timeout=timeout)
        print(json.dumps({"status": "disconnected", "mac": mac}))
    except Exception as e:
        print(json.dumps({"status": "error", "mac": mac, "error": str(e)}))

def pair_device(mac, timeout=15):
    try:
        cmd = f"bluetoothctl pair {mac} && sleep 0.2 && bluetoothctl trust {mac} && sleep 0.2 && bluetoothctl connect {mac}"
        res = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, timeout=timeout)
        success = "Connection successful" in res.stdout or "Pairing successful" in res.stdout
        print(json.dumps({"status": "paired" if success else "failed", "mac": mac, "output": res.stdout.strip()}))
    except subprocess.TimeoutExpired:
        print(json.dumps({"status": "timeout", "mac": mac}))
    except Exception as e:
        print(json.dumps({"status": "error", "mac": mac, "error": str(e)}))

def remove_device(mac):
    try:
        subprocess.run(["bluetoothctl", "remove", mac], capture_output=True, text=True, timeout=5)
        print(json.dumps({"status": "removed", "mac": mac}))
    except Exception as e:
        print(json.dumps({"status": "error", "mac": mac, "error": str(e)}))

def set_audio_profile(card, profile):
    try:
        subprocess.run(["pactl", "set-card-profile", card, profile], capture_output=True, text=True, timeout=2)
        print(json.dumps({"status": "profile_set", "card": card, "profile": profile}))
    except Exception as e:
        print(json.dumps({"status": "error", "card": card, "error": str(e)}))

def run_stream_daemon():
    """
    Runs a persistent D-Bus listener with a registered BlueZ Pairing Agent,
    keeping active Discovery alive and streaming state events in real time.
    """
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    
    # Register Agent
    try:
        agent = BluezAgent(bus, AGENT_PATH)
        obj = bus.get_object("org.bluez", "/org/bluez")
        agent_mgr = dbus.Interface(obj, "org.bluez.AgentManager1")
        agent_mgr.RegisterAgent(AGENT_PATH, CAPABILITY)
        agent_mgr.RequestDefaultAgent(AGENT_PATH)
    except Exception:
        pass

    # Start Discovery
    adapter_obj, _ = get_adapter(bus)
    if adapter_obj:
        try:
            iface = dbus.Interface(adapter_obj, "org.bluez.Adapter1")
            iface.StartDiscovery()
        except dbus.DBusException as e:
            pass

    loop = GLib.MainLoop()
    pending_emit = [False]

    def emit_state():
        pending_emit[0] = False
        try:
            st = get_full_state(bus)
            sys.stdout.write(json.dumps(st) + "\n")
            sys.stdout.flush()
        except Exception:
            pass
        return False

    def schedule_emit():
        if not pending_emit[0]:
            pending_emit[0] = True
            GLib.timeout_add(120, emit_state)

    # Initial emit
    emit_state()

    # D-Bus Signal Listeners
    bus.add_signal_receiver(
        lambda *args, **kwargs: schedule_emit(),
        signal_name="InterfacesAdded",
        dbus_interface="org.freedesktop.DBus.ObjectManager",
        bus_name="org.bluez"
    )
    bus.add_signal_receiver(
        lambda *args, **kwargs: schedule_emit(),
        signal_name="InterfacesRemoved",
        dbus_interface="org.freedesktop.DBus.ObjectManager",
        bus_name="org.bluez"
    )
    bus.add_signal_receiver(
        lambda *args, **kwargs: schedule_emit(),
        signal_name="PropertiesChanged",
        dbus_interface="org.freedesktop.DBus.Properties",
        bus_name="org.bluez"
    )

    # Periodic heartbeat to catch pactl card or battery changes
    GLib.timeout_add_seconds(3, lambda: (emit_state(), True)[1])

    def sig_handler(*args):
        if adapter_obj:
            try:
                iface = dbus.Interface(adapter_obj, "org.bluez.Adapter1")
                iface.StopDiscovery()
            except Exception:
                pass
        loop.quit()

    signal.signal(signal.SIGINT, sig_handler)
    signal.signal(signal.SIGTERM, sig_handler)

    try:
        loop.run()
    except (KeyboardInterrupt, SystemExit):
        sig_handler()

def main():
    if len(sys.argv) < 2 or sys.argv[1] == "get":
        state = get_full_state()
        print(json.dumps(state))
        sys.exit(0)

    cmd = sys.argv[1]

    if cmd in ["stream", "daemon", "scan"]:
        run_stream_daemon()
    elif cmd == "power-on":
        set_power(True)
        print(json.dumps({"status": "powered_on"}))
    elif cmd == "power-off":
        set_power(False)
        print(json.dumps({"status": "powered_off"}))
    elif cmd == "power-toggle":
        st = get_full_state()
        set_power(not st["powered"])
        print(json.dumps({"status": "power_toggled"}))
    elif cmd == "connect" and len(sys.argv) > 2:
        connect_device(sys.argv[2])
    elif cmd == "disconnect" and len(sys.argv) > 2:
        disconnect_device(sys.argv[2])
    elif cmd == "pair" and len(sys.argv) > 2:
        pair_device(sys.argv[2])
    elif cmd == "remove" and len(sys.argv) > 2:
        remove_device(sys.argv[2])
    elif cmd == "set-profile" and len(sys.argv) > 3:
        set_audio_profile(sys.argv[2], sys.argv[3])
    else:
        print(json.dumps({"error": "unknown_command"}))
        sys.exit(1)

if __name__ == "__main__":
    main()
