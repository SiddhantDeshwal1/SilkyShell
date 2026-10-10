#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time

STATE_FILE = os.path.expanduser("~/.cache/quickshell/display_profile.json")
SHADERS_DIR = os.path.expanduser("~/.config/hypr/shaders")
COMPOSITE_SHADER = os.path.join(SHADERS_DIR, "active_composite.frag")

SATURATIONS = {
    "default": 1.0,
    "vivid": 1.30,
    "sports": 1.40,
    "cool": 1.0,
    "warm": 1.0,
    "cinema": 1.15,
    "greyscale": 0.0
}

SHADER_FUNCS = """
vec3 apply_vivid(vec3 rgb) {
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 sat = mix(vec3(luma), rgb, 1.25);
    vec3 contrast = sat * sat * (3.0 - 2.0 * sat);
    return clamp(mix(sat, contrast, 0.20), 0.0, 1.0);
}

vec3 apply_sports(vec3 rgb) {
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 sat = mix(vec3(luma), rgb, 1.30);
    sat.g = pow(sat.g, 0.95);
    sat.b = pow(sat.b, 0.96);
    return clamp((sat - 0.5) * 1.10 + 0.5, 0.0, 1.0);
}

vec3 apply_cool(vec3 rgb) {
    return clamp(rgb * vec3(0.92, 0.98, 1.08), 0.0, 1.0);
}

vec3 apply_warm(vec3 rgb) {
    return clamp(rgb * vec3(1.04, 0.94, 0.82), 0.0, 1.0);
}

vec3 apply_cinema(vec3 rgb) {
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 film = pow(rgb, vec3(1.08));
    film = mix(vec3(luma), film, 1.12);
    film *= vec3(1.02, 1.00, 0.96);
    return clamp(film, 0.0, 1.0);
}

vec3 apply_greyscale(vec3 rgb) {
    float g = dot(rgb, vec3(0.299, 0.587, 0.114));
    return vec3(g);
}
"""

def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        return res.stdout.strip()
    except Exception:
        return ""

DIR_MAP = {
    "left": "auto-left",
    "right": "auto-right",
    "top": "auto-up",
    "bottom": "auto-down"
}

def load_state():
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE, "r") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return {
                        "profiles": data.get("profiles", {}),
                        "arrangements": data.get("arrangements", {}),
                        "transforms": data.get("transforms", {})
                    }
    except Exception:
        pass
    return {"profiles": {}, "arrangements": {}, "transforms": {}}

def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f, indent=2)
    except Exception:
        pass

def load_profiles():
    return load_state()["profiles"]

def save_profiles(profiles):
    st = load_state()
    st["profiles"] = profiles
    save_state(st)

def update_composite_shader(profiles, monitors_raw):
    # Check if any profile requires shader
    active_branches = []
    for m in monitors_raw:
        name = m.get("name", "")
        prof = profiles.get(name, "default")
        if prof in ["vivid", "sports", "cool", "warm", "cinema", "greyscale"]:
            w = m.get("width", 0)
            h = m.get("height", 0)
            if w > 0 and h > 0:
                active_branches.append((w, h, prof))

    if not active_branches:
        # All default -> clear screen_shader
        run_cmd(["hyprctl", "eval", 'hl.config({ decoration = { screen_shader = "" } })'])
        return

    # Build GLSL
    branches_code = ""
    for i, (w, h, prof) in enumerate(active_branches):
        prefix = "if" if i == 0 else "    } else if"
        branches_code += f"""    {prefix} (sz.x == {w} && sz.y == {h}) {{
        rgb = apply_{prof}(rgb);
"""
    if active_branches:
        branches_code += "    }\n"

    shader_src = f"""#version 300 es
precision mediump float;

in vec2 v_texcoord;
uniform sampler2D tex;

layout(location = 0) out vec4 fragColor;

{SHADER_FUNCS}

void main() {{
    ivec2 sz = textureSize(tex, 0);
    vec4 c = texture(tex, v_texcoord);
    vec3 rgb = c.rgb;

{branches_code}
    fragColor = vec4(rgb, c.a);
}}
"""
    os.makedirs(SHADERS_DIR, exist_ok=True)
    with open(COMPOSITE_SHADER, "w") as f:
        f.write(shader_src)

    run_cmd(["hyprctl", "eval", f'hl.config({{ decoration = {{ screen_shader = "{COMPOSITE_SHADER}" }} }})'])

def set_profile(monitor_name, profile_name):
    monitor_name = monitor_name.strip()
    profile_name = profile_name.lower().strip()
    profiles = load_profiles()
    profiles[monitor_name] = profile_name
    save_profiles(profiles)

    # Set per-monitor saturation
    sat = SATURATIONS.get(profile_name, 1.0)
    lua_sat = f'hl.monitor({{ output = "{monitor_name}", sdrsaturation = {sat} }})'
    run_cmd(["hyprctl", "eval", lua_sat])

    # Update composite shader
    raw = run_cmd(["hyprctl", "monitors", "all", "-j"])
    try:
        monitors_raw = json.loads(raw)
    except Exception:
        monitors_raw = []
    update_composite_shader(profiles, monitors_raw)
    print(f"Set profile {profile_name} for {monitor_name}")

def get_brightness():
    try:
        out = run_cmd(["brightnessctl", "-m"])
        parts = out.split(",")
        if len(parts) >= 4:
            pct_str = parts[3].replace("%", "").strip()
            return int(pct_str) / 100.0
    except Exception:
        pass
    return 0.8

def get_monitors_data():
    raw = run_cmd(["hyprctl", "monitors", "all", "-j"])
    monitors_raw = []
    try:
        monitors_raw = json.loads(raw)
    except Exception:
        monitors_raw = []

    state = load_state()
    profiles = state.get("profiles", {})
    arrangements = state.get("arrangements", {})
    transforms = state.get("transforms", {})
    brightness = get_brightness()

    processed_monitors = []
    has_mirror = False

    primary_raw = next((x for x in monitors_raw if any(x.get("name", "").startswith(p) for p in ["eDP", "LVDS", "DSI"])), monitors_raw[0] if monitors_raw else {})

    for m in monitors_raw:
        name = m.get("name", "Unknown")
        is_builtin = any(name.startswith(p) for p in ["eDP", "LVDS", "DSI"])
        mirror_of = str(m.get("mirrorOf", "none"))
        if mirror_of != "none":
            has_mirror = True

        raw_modes = m.get("availableModes", [])
        clean_modes = []
        resolutions_seen = set()
        clean_resolutions = []

        for mode_str in raw_modes:
            clean_modes.append(mode_str)
            res = mode_str.split("@")[0].strip()
            if res and res not in resolutions_seen:
                resolutions_seen.add(res)
                clean_resolutions.append(res)

        active_res = f"{m.get('width', 0)}x{m.get('height', 0)}"
        refresh_rate = round(m.get("refreshRate", 60.0), 1)

        detected_arrangement = "right"
        if len(monitors_raw) > 1 and primary_raw and name != primary_raw.get("name"):
            px, py = primary_raw.get("x", 0), primary_raw.get("y", 0)
            mx, my = m.get("x", 0), m.get("y", 0)
            if mx < px:
                detected_arrangement = "left"
            elif my < py:
                detected_arrangement = "top"
            elif my > py:
                detected_arrangement = "bottom"
            else:
                detected_arrangement = "right"

        curr_arr = arrangements.get(name, detected_arrangement)
        curr_trans = m.get("transform", transforms.get(name, 0))

        processed_monitors.append({
            "id": m.get("id", 0),
            "name": name,
            "description": m.get("description", name),
            "make": m.get("make", ""),
            "model": m.get("model", ""),
            "isBuiltIn": is_builtin,
            "width": m.get("width", 1920),
            "height": m.get("height", 1080),
            "refreshRate": refresh_rate,
            "activeMode": f"{active_res}@{refresh_rate}Hz",
            "currentResolution": active_res,
            "dpmsStatus": bool(m.get("dpmsStatus", True)),
            "disabled": bool(m.get("disabled", False)),
            "mirrorOf": mirror_of,
            "isMirrored": mirror_of != "none",
            "scale": m.get("scale", 1),
            "x": m.get("x", 0),
            "y": m.get("y", 0),
            "availableModes": clean_modes,
            "resolutions": clean_resolutions,
            "activeProfile": profiles.get(name, "default"),
            "transform": curr_trans,
            "arrangement": curr_arr
        })

    sharing_mode = "single"
    if len(processed_monitors) > 1:
        sharing_mode = "mirrored" if has_mirror else "extended"

    return {
        "monitors": processed_monitors,
        "sharingMode": sharing_mode,
        "profiles": profiles,
        "arrangements": arrangements,
        "transforms": transforms,
        "brightness": brightness
    }

def set_resolution(monitor_name, mode_str):
    data = get_monitors_data()
    mon = next((m for m in data["monitors"] if m["name"] == monitor_name), None)
    
    pos = f"{mon['x']}x{mon['y']}" if mon else "auto"
    scale = mon["scale"] if mon else 1
    trans = mon["transform"] if mon else 0

    clean_mode = mode_str.replace("Hz", "").strip()
    if "@" not in clean_mode and mon:
        clean_mode = f"{clean_mode}@{int(mon['refreshRate'])}"

    if mon and mon["isMirrored"]:
        mirror_target = mon["mirrorOf"]
        if mirror_target.isdigit():
            idx = int(mirror_target)
            if idx < len(data["monitors"]):
                mirror_target = data["monitors"][idx]["name"]
        lua = f'hl.monitor({{ output = "{monitor_name}", mode = "{clean_mode}", transform = {trans}, mirror = "{mirror_target}" }})'
        run_cmd(["hyprctl", "eval", lua])
        run_cmd(["hyprctl", "keyword", "monitor", f"{monitor_name},{clean_mode},0x0,{scale},mirror,{mirror_target},transform,{trans}"])
    else:
        lua = f'hl.monitor({{ output = "{monitor_name}", mode = "{clean_mode}", position = "{pos}", scale = {scale}, transform = {trans}, mirror = "" }})'
        run_cmd(["hyprctl", "eval", lua])
        run_cmd(["hyprctl", "keyword", "monitor", f"{monitor_name},{clean_mode},{pos},{scale},transform,{trans}"])
    
    print(f"Applied resolution {clean_mode} to {monitor_name}")

def set_sharing(monitor_name, mode, target_monitor=""):
    data = get_monitors_data()
    state = load_state()

    if mode == "mirror":
        if not target_monitor:
            other = next((m["name"] for m in data["monitors"] if m["name"] != monitor_name), "")
            target_monitor = other
        if target_monitor:
            mon = next((m for m in data["monitors"] if m["name"] == monitor_name), None)
            m_res = f"{mon['currentResolution']}@{int(mon['refreshRate'])}" if mon else "preferred"
            m_trans = mon["transform"] if mon else 0
            lua = f'hl.monitor({{ output = "{monitor_name}", mode = "{m_res}", position = "0x0", transform = {m_trans}, mirror = "{target_monitor}" }})'
            run_cmd(["hyprctl", "eval", lua])
            run_cmd(["hyprctl", "keyword", "monitor", f"{monitor_name},{m_res},0x0,1,mirror,{target_monitor},transform,{m_trans}"])
            print(f"Mirrored {monitor_name} to {target_monitor}")

    elif mode == "extend":
        primary = next((m for m in data["monitors"] if m["isBuiltIn"]), data["monitors"][0] if data["monitors"] else None)
        for m in data["monitors"]:
            m_name = m["name"]
            m_res = f"{m['currentResolution']}@{int(m['refreshRate'])}"
            m_trans = m.get("transform", state["transforms"].get(m_name, 0))
            if primary and m_name == primary["name"]:
                pos = "0x0"
            else:
                arr = m.get("arrangement", state["arrangements"].get(m_name, "right"))
                pos = DIR_MAP.get(arr, "auto-right")

            lua = f'hl.monitor({{ output = "{m_name}", mode = "{m_res}", position = "{pos}", scale = {m["scale"]}, transform = {m_trans}, mirror = "" }})'
            run_cmd(["hyprctl", "eval", lua])
            run_cmd(["hyprctl", "keyword", "monitor", f"{m_name},{m_res},{pos},{m['scale']},transform,{m_trans}"])
        print(f"Extended displays cleanly")

def set_arrangement(monitor_name, arrangement):
    arrangement = arrangement.lower().strip()
    if arrangement not in ["left", "right", "top", "bottom"]:
        arrangement = "right"

    state = load_state()
    state["arrangements"][monitor_name] = arrangement
    save_state(state)

    data = get_monitors_data()
    monitors = data["monitors"]
    if len(monitors) <= 1:
        print(f"Only 1 display connected, arrangement saved for {monitor_name}")
        return

    primary = next((m for m in monitors if m["isBuiltIn"]), monitors[0])
    target = next((m for m in monitors if m["name"] == monitor_name), None)
    if not target:
        target = next((m for m in monitors if m["name"] != primary["name"]), None)
    if not target or target["isBuiltIn"]:
        print(f"Cannot rearrange anchor display {monitor_name}")
        return

    ref = primary

    auto_pos = DIR_MAP.get(arrangement, "auto-right")
    
    t_name = target["name"]
    t_res = f"{target['currentResolution']}@{int(target['refreshRate'])}"
    t_scale = target["scale"]
    t_trans = target["transform"]

    r_name = ref["name"]
    r_res = f"{ref['currentResolution']}@{int(ref['refreshRate'])}"
    r_scale = ref["scale"]
    r_trans = ref["transform"]

    # Anchor reference monitor at 0x0
    lua_ref = f'hl.monitor({{ output = "{r_name}", mode = "{r_res}", position = "0x0", scale = {r_scale}, transform = {r_trans}, mirror = "" }})'
    run_cmd(["hyprctl", "eval", lua_ref])
    run_cmd(["hyprctl", "keyword", "monitor", f"{r_name},{r_res},0x0,{r_scale},transform,{r_trans}"])

    # Position target relative to reference
    lua_target = f'hl.monitor({{ output = "{t_name}", mode = "{t_res}", position = "{auto_pos}", scale = {t_scale}, transform = {t_trans}, mirror = "" }})'
    run_cmd(["hyprctl", "eval", lua_target])
    run_cmd(["hyprctl", "keyword", "monitor", f"{t_name},{t_res},{auto_pos},{t_scale},transform,{t_trans}"])

    print(f"Arranged {t_name} to {arrangement} ({auto_pos}) relative to {r_name}")

def set_orientation(monitor_name, transform):
    try:
        transform = int(transform)
    except Exception:
        transform = 0

    state = load_state()
    state["transforms"][monitor_name] = transform
    save_state(state)

    data = get_monitors_data()
    mon = next((m for m in data["monitors"] if m["name"] == monitor_name), None)
    if not mon:
        return

    m_res = f"{mon['currentResolution']}@{int(mon['refreshRate'])}"
    scale = mon["scale"]

    if mon["isMirrored"]:
        mirror_target = mon["mirrorOf"]
        if mirror_target.isdigit():
            idx = int(mirror_target)
            if idx < len(data["monitors"]):
                mirror_target = data["monitors"][idx]["name"]
        lua = f'hl.monitor({{ output = "{monitor_name}", mode = "{m_res}", transform = {transform}, mirror = "{mirror_target}" }})'
        run_cmd(["hyprctl", "eval", lua])
        run_cmd(["hyprctl", "keyword", "monitor", f"{monitor_name},{m_res},0x0,{scale},mirror,{mirror_target},transform,{transform}"])
    else:
        arrangement = mon.get("arrangement", state["arrangements"].get(monitor_name, "right"))
        auto_pos = DIR_MAP.get(arrangement, "auto-right")
        pos = "0x0" if (mon["isBuiltIn"] and len(data["monitors"]) > 1 and arrangement not in ["left", "top"]) else (f"{mon['x']}x{mon['y']}" if len(data["monitors"]) == 1 else auto_pos)

        lua = f'hl.monitor({{ output = "{monitor_name}", mode = "{m_res}", position = "{pos}", scale = {scale}, transform = {transform}, mirror = "" }})'
        run_cmd(["hyprctl", "eval", lua])
        run_cmd(["hyprctl", "keyword", "monitor", f"{monitor_name},{m_res},{pos},{scale},transform,{transform}"])

    # Update composite shader in case buffer dimensions changed
    profiles = state["profiles"]
    raw = run_cmd(["hyprctl", "monitors", "all", "-j"])
    try:
        monitors_raw = json.loads(raw)
    except Exception:
        monitors_raw = []
    update_composite_shader(profiles, monitors_raw)

    print(f"Applied orientation transform {transform} to {monitor_name}")

def set_dpms(monitor_name, state):
    lua = f'hl.dsp.dpms("{state}", "{monitor_name}")'
    run_cmd(["hyprctl", "dispatch", lua])
    print(f"DPMS {state} applied to {monitor_name}")

def main():
    if len(sys.argv) < 2 or sys.argv[1] == "get":
        print(json.dumps(get_monitors_data()))
    elif sys.argv[1] == "set-profile":
        if len(sys.argv) >= 4:
            set_profile(sys.argv[2], sys.argv[3])
        elif len(sys.argv) == 3:
            data = get_monitors_data()
            first = data["monitors"][0]["name"] if data["monitors"] else "eDP-1"
            set_profile(first, sys.argv[2])
    elif sys.argv[1] == "set-resolution" and len(sys.argv) >= 4:
        set_resolution(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "set-sharing" and len(sys.argv) >= 4:
        target = sys.argv[4] if len(sys.argv) >= 5 else ""
        set_sharing(sys.argv[2], sys.argv[3], target)
    elif sys.argv[1] == "set-arrangement" and len(sys.argv) >= 4:
        set_arrangement(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "set-orientation" and len(sys.argv) >= 4:
        set_orientation(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "set-dpms" and len(sys.argv) >= 4:
        set_dpms(sys.argv[2], sys.argv[3])
    else:
        print("Usage: display-manager.py [get|set-profile <mon> <prof>|set-resolution <mon> <res>|set-sharing <mon> <mode>|set-arrangement <mon> <pos>|set-orientation <mon> <trans>|set-dpms <mon> <state>]")

if __name__ == "__main__":
    main()
