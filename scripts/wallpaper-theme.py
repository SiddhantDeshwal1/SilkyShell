#!/usr/bin/env python3
"""
wallpaper-theme.py
Extracts a refined, hue-matching bar background color from the current wallpaper.
Runs once on Quickshell startup or refresh. Fast caching avoids re-processing
if the wallpaper has not changed.
"""

import sys, os, json, colorsys
from PIL import Image

CACHE_DIR = os.path.expanduser("~/.cache/quickshell")
THEME_JSON = os.path.join(CACHE_DIR, "theme.json")

def find_current_wallpaper():
    # 1. Inspect awww daemon cache
    awww_dir = os.path.expanduser("~/.cache/awww")
    if os.path.isdir(awww_dir):
        for root, _, files in os.walk(awww_dir):
            for f in files:
                p = os.path.join(root, f)
                try:
                    with open(p, "rb") as fh:
                        parts = fh.read().split(b"\x00")
                        for part in reversed(parts):
                            candidate = part.decode("utf-8", errors="ignore").strip()
                            if candidate and os.path.isfile(candidate):
                                return candidate
                except Exception:
                    pass

    # 2. Inspect waypaper config
    wp_cfg = os.path.expanduser("~/.config/waypaper/config.ini")
    if os.path.isfile(wp_cfg):
        try:
            with open(wp_cfg, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    if line.strip().startswith("wallpaper"):
                        val = line.split("=", 1)[1].strip()
                        val = os.path.expanduser(val)
                        if os.path.isfile(val):
                            return val
        except Exception:
            pass

    # 3. Fallback: inspect awww query
    try:
        import subprocess
        out = subprocess.check_output(["awww", "query"], timeout=1).decode("utf-8")
        for line in out.splitlines():
            if "image:" in line:
                val = line.split("image:")[-1].strip()
                if os.path.isfile(val):
                    return val
    except Exception:
        pass

    return None

def extract_colors(img_path):
    img = Image.open(img_path)
    img.draft("RGB", (128, 128))
    img = img.convert("RGB")
    img.thumbnail((64, 64))

    # Sample top ~18% (where the top bar rests)
    top_h = max(2, int(img.height * 0.18))
    top_slice = img.crop((0, 0, img.width, top_h))

    pixels = list(top_slice.getdata())
    if not pixels:
        return "#0b0e1d", "#f0f3fa", "#42a6f7"

    avg_r = sum(p[0] for p in pixels) / len(pixels)
    avg_g = sum(p[1] for p in pixels) / len(pixels)
    avg_b = sum(p[2] for p in pixels) / len(pixels)

    h, l, s = colorsys.rgb_to_hls(avg_r / 255.0, avg_g / 255.0, avg_b / 255.0)

    # Bar background: deep tone preserving wallpaper hue
    # Lightness 0.08-0.09, saturation clamped to 0.40 max for tasteful aesthetic
    dark_l = 0.085
    dark_s = min(s * 1.15, 0.40)
    dr, dg, db = colorsys.hls_to_rgb(h, dark_l, dark_s)
    bar_color = f"#{int(dr * 255):02x}{int(dg * 255):02x}{int(db * 255):02x}"

    # Accent color: vibrant tone matching the hue
    ar, ag, ab = colorsys.hls_to_rgb(h, 0.60, max(s, 0.65))
    accent = f"#{int(ar * 255):02x}{int(ag * 255):02x}{int(ab * 255):02x}"

    return bar_color, accent

def main():
    force = "--force" in sys.argv
    wp = find_current_wallpaper()

    # Load existing theme.json if present
    theme = {}
    if os.path.isfile(THEME_JSON):
        try:
            with open(THEME_JSON, "r", encoding="utf-8") as fh:
                theme = json.load(fh)
        except Exception:
            theme = {}

    if not wp:
        sys.exit(0)

    try:
        wp_mtime = os.path.getmtime(wp)
    except Exception:
        wp_mtime = 0

    # Fast caching check
    cached_wp = theme.get("wallpaper")
    cached_mtime = theme.get("wallpaperMtime")
    has_colors = "barBgColor" in theme

    if not force and cached_wp == wp and cached_mtime == wp_mtime and has_colors:
        # Cache is completely up to date; exit immediately!
        sys.exit(0)

    # Extract colors
    try:
        bar_color, accent = extract_colors(wp)
    except Exception as e:
        sys.exit(1)

    theme["wallpaper"] = wp
    theme["wallpaperMtime"] = wp_mtime
    theme["barBgColor"] = bar_color
    theme.pop("barBgColorLight", None)
    theme["wallpaperAccentColor"] = accent
    if "darkMode" not in theme:
        theme["darkMode"] = True

    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp_path = THEME_JSON + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        json.dump(theme, fh, indent=2)
    os.replace(tmp_path, THEME_JSON)

if __name__ == "__main__":
    main()
