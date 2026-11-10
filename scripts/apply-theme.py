#!/usr/bin/env python3
"""
apply-theme.py
Core color extraction, palette generation, and theme synchronization module.

Extracts dominant hue and saturation from wallpaper in HLS space with high
performance (<10ms thumbnailing, caching <1ms) and derives:
  - bg0: Deep background (Lightness ~0.082, Saturation <= 0.35)
  - bg1: Elevated surface / sidebar (Lightness ~0.115)
  - bg_selection: Selection highlight (Lightness ~0.22, Saturation ~0.40)
  - fg0: Primary text (Lightness ~0.93, Saturation ~0.04, WCAG AAA > 10:1 vs bg0)
  - fg1: Dim/secondary text (Lightness ~0.62)
  - accent: Primary accent (Lightness ~0.60, Saturation >= 0.65)
  - 16 harmonized ANSI terminal colors (color0 through color15)

Syncs with ~/.cache/quickshell/theme.json for backward compatibility with Theme.qml
and caches in ~/.cache/quickshell/theme_cache.json.
"""

from __future__ import annotations

import argparse
import colorsys
import hashlib
import json
import math
import os
import subprocess
import sys
import threading
import time
from typing import Dict, Optional, Tuple, Any

try:
    from PIL import Image, JpegImagePlugin, PngImagePlugin
except ImportError:
    Image = None  # type: ignore

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

try:
    import theme_kitty
except ImportError:
    theme_kitty = None  # type: ignore

try:
    import theme_thunar_bg
except ImportError:
    theme_thunar_bg = None  # type: ignore

try:
    import theme_kora
except ImportError:
    theme_kora = None  # type: ignore

CACHE_DIR = os.path.expanduser("~/.cache/quickshell")
THEME_CACHE_JSON = os.path.join(CACHE_DIR, "theme_cache.json")
THEME_JSON = os.path.join(CACHE_DIR, "theme.json")


def rgb_to_hex(r: float, g: float, b: float) -> str:
    """Convert float RGB (0..1) to #rrggbb hex string."""
    ir = max(0, min(255, int(round(r * 255.0))))
    ig = max(0, min(255, int(round(g * 255.0))))
    ib = max(0, min(255, int(round(b * 255.0))))
    return f"#{ir:02x}{ig:02x}{ib:02x}"


def hex_to_rgb(hex_str: str) -> Tuple[float, float, float]:
    """Convert #rrggbb or rrggbb hex string to float RGB (0..1)."""
    s = hex_str.lstrip("#")
    if len(s) == 3:
        s = "".join(c * 2 for c in s)
    val = int(s, 16)
    r = ((val >> 16) & 0xFF) / 255.0
    g = ((val >> 8) & 0xFF) / 255.0
    b = (val & 0xFF) / 255.0
    return (r, g, b)


def relative_luminance(r: float, g: float, b: float) -> float:
    """Calculate relative luminance for WCAG contrast (sRGB)."""
    def linearize(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)


def wcag_contrast_ratio(rgb1: Tuple[float, float, float], rgb2: Tuple[float, float, float]) -> float:
    """Calculate WCAG contrast ratio between two RGB colors (1..21)."""
    l1 = relative_luminance(*rgb1)
    l2 = relative_luminance(*rgb2)
    bright = max(l1, l2)
    dark = min(l1, l2)
    return (bright + 0.05) / (dark + 0.05)


def calculate_temperature(h_val: float) -> float:
    """
    Calculate color temperature on the hue circle [-1.0, 1.0].
    +1.0: Warmest (around 30 deg / amber-orange)
    -1.0: Coolest (around 210 deg / cyan-azure)
    """
    return math.cos(2.0 * math.pi * (h_val - 30.0 / 360.0))


def find_current_wallpaper() -> Optional[str]:
    """
    Auto-detect the currently active wallpaper from:
    1. awww query output
    2. ~/.cache/awww socket / cache files
    3. ~/.config/waypaper/config.ini
    """
    # 1. Inspect awww query
    try:
        out = subprocess.check_output(["awww", "query"], timeout=1.0).decode("utf-8")
        for line in out.splitlines():
            if "image:" in line:
                val = line.split("image:")[-1].strip()
                if os.path.isfile(val):
                    return os.path.abspath(val)
    except Exception:
        pass

    # 2. Inspect awww daemon cache (sort by mtime descending to get most recent monitor)
    awww_dir = os.path.expanduser("~/.cache/awww")
    if os.path.isdir(awww_dir):
        cache_files = []
        for root, _, files in os.walk(awww_dir):
            for f in files:
                p = os.path.join(root, f)
                try:
                    cache_files.append((os.path.getmtime(p), p))
                except Exception:
                    pass
        cache_files.sort(reverse=True)
        for _, p in cache_files:
            try:
                with open(p, "rb") as fh:
                    parts = fh.read().split(b"\x00")
                    for part in reversed(parts):
                        candidate = part.decode("utf-8", errors="ignore").strip()
                        if candidate and os.path.isfile(candidate):
                            return os.path.abspath(candidate)
            except Exception:
                pass

    # 3. Inspect waypaper config
    wp_cfg = os.path.expanduser("~/.config/waypaper/config.ini")
    if os.path.isfile(wp_cfg):
        try:
            with open(wp_cfg, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    if line.strip().startswith("wallpaper"):
                        val = line.split("=", 1)[1].strip()
                        val = os.path.expanduser(val)
                        if os.path.isfile(val):
                            return os.path.abspath(val)
        except Exception:
            pass

    return None


def extract_dominant_hue_saturation(img: Any) -> Tuple[float, float]:
    """
    Extracts the dominant hue and saturation from a 64x64 RGB PIL Image.
    Returns (dominant_hue, dominant_saturation) in range [0.0, 1.0].
    """
    raw = img.tobytes()
    num_bins = 36
    bins_weight = [0.0] * num_bins
    bins_pixels = [[] for _ in range(num_bins)]
    all_saturations = []

    for i in range(0, len(raw), 3):
        r, g, b = raw[i] / 255.0, raw[i + 1] / 255.0, raw[i + 2] / 255.0
        h, l, s = colorsys.rgb_to_hls(r, g, b)
        all_saturations.append(s)

        # Exclude extreme blacks and blown-out highlights for hue determination
        if 0.07 < l < 0.93 and s > 0.06:
            # Vibrancy weighting favoring rich saturation and comfortable mid-tones
            w = (s ** 1.25) * (1.0 - abs(l - 0.52) * 1.1)
            if w > 0:
                bin_idx = int(h * num_bins) % num_bins
                bins_weight[bin_idx] += w
                bins_pixels[bin_idx].append((w, h, l, s))

    max_w = max(bins_weight) if bins_weight else 0.0
    avg_s = sum(all_saturations) / len(all_saturations) if all_saturations else 0.0

    # If the image is virtually monochrome or desaturated
    if max_w < 0.05 or avg_s < 0.05:
        # Default to calm, modern slate-blue tone with low saturation
        return (215.0 / 360.0, max(0.0, min(avg_s, 0.15)))

    top_bin = max(range(num_bins), key=lambda idx: bins_weight[idx])

    # Cluster top peak and significant adjacent bins
    cluster = list(bins_pixels[top_bin])
    for offset in (-1, 1):
        neighbor = (top_bin + offset) % num_bins
        if bins_weight[neighbor] > bins_weight[top_bin] * 0.35:
            cluster.extend(bins_pixels[neighbor])

    cw_sum = sum(w for w, h, l, s in cluster)
    if cw_sum <= 0:
        return (215.0 / 360.0, 0.10)

    # Directional circular mean of cluster hues
    cx = sum(w * math.cos(h * 2.0 * math.pi) for w, h, l, s in cluster)
    cy = sum(w * math.sin(h * 2.0 * math.pi) for w, h, l, s in cluster)
    dom_h = (math.atan2(cy, cx) / (2.0 * math.pi)) % 1.0
    dom_s = sum(w * s for w, h, l, s in cluster) / cw_sum

    return (dom_h, min(1.0, max(0.0, dom_s)))


def harmonize_ansi_colors(dom_h: float, dom_s: float, temp: float, bg0_hex: str, fg0_hex: str) -> Dict[str, str]:
    """
    Derives full 16 ANSI colors harmonized to the wallpaper's temperature and dominant hue.
    Standard ANSI definitions:
      0: black, 1: red, 2: green, 3: yellow, 4: blue, 5: magenta, 6: cyan, 7: white
      8-15: bright variants
    """
    dom_deg = dom_h * 360.0

    # Base ANSI hues (degrees)
    base_hues = {
        "red": 0.0,
        "green": 125.0,
        "yellow": 48.0,
        "blue": 215.0,
        "magenta": 300.0,
        "cyan": 180.0,
    }

    # Temperature influence magnitude
    temp_factor = temp * min(dom_s, 1.0)

    harmonized_hues: Dict[str, float] = {}
    for name, base_deg in base_hues.items():
        diff = (dom_deg - base_deg + 180.0) % 360.0 - 180.0
        # If wallpaper hue is close to this ANSI hue (<35 deg), lock closely onto dominant hue
        if abs(diff) < 35.0:
            blend = (1.0 - abs(diff) / 35.0) * min(dom_s, 1.0) * 0.65
            h_deg = (base_deg + diff * blend) % 360.0
        else:
            # Temperature shift: warm nudges towards warm side, cool towards cool side
            h_deg = (base_deg - temp_factor * 7.0) % 360.0
        harmonized_hues[name] = h_deg / 360.0

    # Saturation and lightness tuning for legibility and vibrancy
    sat_norm = max(0.60, min(0.85, 0.68 + dom_s * 0.12))
    sat_bright = max(0.70, min(0.95, 0.78 + dom_s * 0.12))

    # Standard lightness levels (adjusted to ensure WCAG AA > 4.5:1 against bg0)
    lit_map = {
        "red": 0.62,
        "green": 0.58,
        "yellow": 0.58,
        "blue": 0.65,
        "magenta": 0.62,
        "cyan": 0.58,
    }
    lit_bright_map = {
        "red": 0.72,
        "green": 0.70,
        "yellow": 0.70,
        "blue": 0.75,
        "magenta": 0.73,
        "cyan": 0.70,
    }

    # Background and foreground subtle undertones
    bg_undertone_s = min(dom_s * 0.25, 0.18)
    fg_undertone_s = min(dom_s * 0.05, 0.03)

    color0 = bg0_hex
    color8 = rgb_to_hex(*colorsys.hls_to_rgb(dom_h, 0.30, bg_undertone_s))  # Bright black / muted comments
    color7 = rgb_to_hex(*colorsys.hls_to_rgb(dom_h, 0.78, fg_undertone_s))  # Muted white / light gray
    color15 = fg0_hex                                                       # Bright white (WCAG AAA)

    ansi = {
        "color0": color0,
        "color1": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["red"], lit_map["red"], sat_norm)),
        "color2": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["green"], lit_map["green"], sat_norm)),
        "color3": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["yellow"], lit_map["yellow"], sat_norm)),
        "color4": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["blue"], lit_map["blue"], sat_norm)),
        "color5": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["magenta"], lit_map["magenta"], sat_norm)),
        "color6": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["cyan"], lit_map["cyan"], sat_norm)),
        "color7": color7,
        "color8": color8,
        "color9": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["red"], lit_bright_map["red"], sat_bright)),
        "color10": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["green"], lit_bright_map["green"], sat_bright)),
        "color11": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["yellow"], lit_bright_map["yellow"], sat_bright)),
        "color12": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["blue"], lit_bright_map["blue"], sat_bright)),
        "color13": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["magenta"], lit_bright_map["magenta"], sat_bright)),
        "color14": rgb_to_hex(*colorsys.hls_to_rgb(harmonized_hues["cyan"], lit_bright_map["cyan"], sat_bright)),
        "color15": color15,
    }
    return ansi


def extract_palette(wallpaper_path: str) -> Dict[str, Any]:
    """
    Core extraction function:
    Uses Pillow draft('RGB', (64, 64)) and thumbnail((64, 64)) for rapid extraction.
    Derives bg0, bg1, bg_selection, fg0, fg1, accent, and full 16 ANSI colors.
    """
    if not os.path.isfile(wallpaper_path):
        raise FileNotFoundError(f"Wallpaper not found: {wallpaper_path}")

    # Check for fast cached wallpaper thumbnail (< 3ms extraction)
    thumb_dir = os.path.expanduser("~/.cache/wallpaper-thumbs")
    wp_base = os.path.basename(wallpaper_path)
    candidates = [
        os.path.join(thumb_dir, f"{wp_base}.jpg"),
        os.path.join(thumb_dir, wp_base),
        os.path.join(thumb_dir, f"{wp_base}.png"),
    ]
    img_source = wallpaper_path
    for c in candidates:
        if os.path.isfile(c):
            img_source = c
            break

    # Low-resource, high-speed image downscaling (<10ms for typical images)
    with Image.open(img_source) as img:
        img.draft("RGB", (64, 64))
        img = img.convert("RGB")
        img.thumbnail((64, 64))
        dom_h, dom_s = extract_dominant_hue_saturation(img)

    temp = calculate_temperature(dom_h)

    # 1. bg0: Deep background (Lightness ~0.082, Saturation <= 0.35 preserving warmth/coolness)
    bg0_l = 0.082
    bg0_s = min(max(dom_s * 0.45, 0.06), 0.35) if dom_s > 0.04 else 0.0
    bg0_rgb = colorsys.hls_to_rgb(dom_h, bg0_l, bg0_s)
    bg0_hex = rgb_to_hex(*bg0_rgb)

    # 2. bg1: Elevated surface / sidebar (Lightness ~0.115)
    bg1_l = 0.115
    bg1_s = min(bg0_s * 1.15, 0.35)
    bg1_rgb = colorsys.hls_to_rgb(dom_h, bg1_l, bg1_s)
    bg1_hex = rgb_to_hex(*bg1_rgb)

    # 3. bg_selection: Selection highlight background (Lightness ~0.22, Saturation ~0.40)
    sel_l = 0.22
    sel_s = min(max(dom_s * 0.55, 0.25), 0.40) if dom_s > 0.04 else 0.0
    sel_rgb = colorsys.hls_to_rgb(dom_h, sel_l, sel_s)
    sel_hex = rgb_to_hex(*sel_rgb)

    # 4. fg0: Primary text (Lightness ~0.93, Saturation ~0.04, WCAG AAA contrast > 10:1 vs bg0)
    fg0_l = 0.93
    fg0_s = min(dom_s * 0.04, 0.03) if dom_s > 0.04 else 0.0
    fg0_rgb = colorsys.hls_to_rgb(dom_h, fg0_l, fg0_s)
    fg0_hex = rgb_to_hex(*fg0_rgb)

    # Verify WCAG contrast
    contrast = wcag_contrast_ratio(fg0_rgb, bg0_rgb)

    # 5. fg1: Dim/secondary text (Lightness ~0.62)
    fg1_l = 0.62
    fg1_s = min(dom_s * 0.10, 0.08) if dom_s > 0.04 else 0.0
    fg1_rgb = colorsys.hls_to_rgb(dom_h, fg1_l, fg1_s)
    fg1_hex = rgb_to_hex(*fg1_rgb)

    # 6. accent: Primary accent (Lightness ~0.60, Saturation >= 0.65)
    accent_l = 0.60
    accent_s = max(dom_s, 0.65)
    accent_rgb = colorsys.hls_to_rgb(dom_h, accent_l, accent_s)
    accent_hex = rgb_to_hex(*accent_rgb)

    # 7. 16 ANSI colors harmonized to temperature
    ansi = harmonize_ansi_colors(dom_h, dom_s, temp, bg0_hex, fg0_hex)

    palette: Dict[str, Any] = {
        "wallpaper": os.path.abspath(wallpaper_path),
        "dominant_hue": round(dom_h, 4),
        "dominant_hue_deg": round(dom_h * 360.0, 1),
        "dominant_sat": round(dom_s, 4),
        "temperature": round(temp, 3),
        "bg0": bg0_hex,
        "bg1": bg1_hex,
        "bg_selection": sel_hex,
        "fg0": fg0_hex,
        "fg1": fg1_hex,
        "accent": accent_hex,
        "wcag_contrast": round(contrast, 2),
        "ansi": ansi,
        # Flat convenience lookups for ANSI colors:
        "color0": ansi["color0"],
        "color1": ansi["color1"],
        "color2": ansi["color2"],
        "color3": ansi["color3"],
        "color4": ansi["color4"],
        "color5": ansi["color5"],
        "color6": ansi["color6"],
        "color7": ansi["color7"],
        "color8": ansi["color8"],
        "color9": ansi["color9"],
        "color10": ansi["color10"],
        "color11": ansi["color11"],
        "color12": ansi["color12"],
        "color13": ansi["color13"],
        "color14": ansi["color14"],
        "color15": ansi["color15"],
        # Semantic aliases:
        "background": bg0_hex,
        "foreground": fg0_hex,
        "selection_background": sel_hex,
        "selection_foreground": fg0_hex,
    }
    return palette


def get_cached_palette(wallpaper_path: str, cache_file: str = THEME_CACHE_JSON) -> Optional[Dict[str, Any]]:
    """
    Check cache file for existing valid palette.
    Returns cached palette dict if valid, or None if stale or missing.
    Executes in < 1ms.
    """
    if not os.path.isfile(cache_file):
        return None

    try:
        current_mtime = os.path.getmtime(wallpaper_path)
    except OSError:
        return None

    try:
        with open(cache_file, "r", encoding="utf-8") as f:
            data = json.load(f)

        cached_wp = data.get("wallpaper")
        cached_mtime = data.get("wallpaperMtime")
        if cached_wp == os.path.abspath(wallpaper_path) and cached_mtime == current_mtime:
            if "bg0" in data and "accent" in data:
                return data
            elif "palette" in data and "bg0" in data["palette"]:
                return data["palette"]
    except Exception:
        return None

    return None


def save_cache(wallpaper_path: str, mtime: float, palette: Dict[str, Any], cache_file: str = THEME_CACHE_JSON) -> None:
    """Save palette and wallpaper metadata to cache file atomically."""
    cache_dir = os.path.dirname(cache_file)
    os.makedirs(cache_dir, exist_ok=True)

    payload = {
        "wallpaper": os.path.abspath(wallpaper_path),
        "wallpaperMtime": mtime,
        **palette,
        "palette": palette,
    }

    tmp_path = f"{cache_file}.tmp.{os.getpid()}"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
        os.replace(tmp_path, cache_file)
    except Exception as e:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass
        raise e


def sync_theme_json(
    wallpaper_path: str,
    mtime: float,
    palette: Dict[str, Any],
    theme_json_path: str = THEME_JSON
) -> Dict[str, Any]:
    """
    Sync palette with ~/.cache/quickshell/theme.json preserving 100% backwards compatibility
    with Theme.qml (barBgColor, wallpaperAccentColor, wallpaper, wallpaperMtime, darkMode: true).
    """
    theme_dir = os.path.dirname(theme_json_path)
    os.makedirs(theme_dir, exist_ok=True)

    theme_data: Dict[str, Any] = {}
    if os.path.isfile(theme_json_path):
        try:
            with open(theme_json_path, "r", encoding="utf-8") as f:
                theme_data = json.load(f)
        except Exception:
            theme_data = {}

    # Required keys for Theme.qml
    theme_data["wallpaper"] = os.path.abspath(wallpaper_path)
    theme_data["wallpaperMtime"] = mtime
    theme_data["barBgColor"] = palette["bg0"]
    theme_data.pop("barBgColorLight", None)
    theme_data["wallpaperAccentColor"] = palette["accent"]
    if "darkMode" not in theme_data:
        theme_data["darkMode"] = True

    # Extended theme properties for modern components
    theme_data["bg0"] = palette["bg0"]
    theme_data["bg1"] = palette["bg1"]
    theme_data["bg_selection"] = palette["bg_selection"]
    theme_data["fg0"] = palette["fg0"]
    theme_data["fg1"] = palette["fg1"]
    theme_data["accent"] = palette["accent"]
    theme_data["colors"] = palette.get("ansi", {})

    tmp_path = f"{theme_json_path}.tmp.{os.getpid()}"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(theme_data, f, indent=2)
        os.replace(tmp_path, theme_json_path)
    except Exception as e:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass
        raise e

    return theme_data


def apply_theme(
    wallpaper_path: Optional[str] = None,
    force: bool = False,
    sync_qs: bool = True,
    apply_kitty: bool = True,
    apply_thunar: bool = True,
    apply_icons: bool = True,
    firma: Optional[str] = None,
    **kwargs: Any,
) -> Dict[str, Any]:
    """
    High-level orchestration function:
    1. Resolves wallpaper path (or detects current).
    2. Checks cache (returns in <1ms if unchanged and not force).
    3. Extracts palette using Pillow draft & thumbnail.
    4. Saves cache to ~/.cache/quickshell/theme_cache.json.
    5. Syncs ~/.cache/quickshell/theme.json for Quickshell Theme.qml compatibility.
    6. Triggers Kitty live reloading (current-theme.conf + SIGUSR1).
    7. Generates and activates scoped Thunar background theme (Graphite-qs-<hash>).
    8. Generates and activates tinted Kora folder icons (kora-qs-<hash>).
    9. Returns generated palette.
    """
    # Backward compatibility with legacy caller arguments
    if "apply_gtk" in kwargs and kwargs["apply_gtk"] is not None:
        apply_thunar = bool(kwargs["apply_gtk"])

    if not wallpaper_path:
        wallpaper_path = find_current_wallpaper()

    if not wallpaper_path or not os.path.isfile(wallpaper_path):
        raise FileNotFoundError(f"Wallpaper file not found: {wallpaper_path}")

    wallpaper_path = os.path.abspath(wallpaper_path)
    try:
        mtime = os.path.getmtime(wallpaper_path)
    except OSError:
        mtime = 0.0

    if not force:
        cached = get_cached_palette(wallpaper_path)
        if cached is not None:
            return cached

    palette = extract_palette(wallpaper_path)
    save_cache(wallpaper_path, mtime, palette)

    # Derive unique firma if not provided
    if not firma:
        firma = palette.get("firma")
    if not firma:
        base_sig = f"{wallpaper_path}_{mtime}_{palette.get('accent', '')}"
        firma = hashlib.md5(base_sig.encode("utf-8")).hexdigest()[:8]
    palette["firma"] = firma

    if sync_qs:
        try:
            sync_theme_json(wallpaper_path, mtime, palette)
        except Exception as e:
            print(f"Warning: Quickshell theme.json sync failed: {e}", file=sys.stderr)

    if apply_kitty:
        try:
            th_kitty = theme_kitty or __import__("theme_kitty")
            # Execute in non-daemon thread to avoid blocking on pkill process table traversal
            threading.Thread(
                target=th_kitty.apply_kitty_theme,
                args=(palette,),
                kwargs={"wallpaper_name": os.path.basename(wallpaper_path)},
                daemon=False,
            ).start()
        except Exception as e:
            print(f"Warning: Kitty theming failed: {e}", file=sys.stderr)

    if apply_thunar:
        try:
            th_thunar = theme_thunar_bg or __import__("theme_thunar_bg")
            th_thunar.apply_thunar_bg(
                palette["bg0"],
                palette["bg1"],
                palette["fg0"],
                palette["accent"],
                firma,
            )
        except Exception as e:
            print(f"Warning: Thunar dynamic background theming failed: {e}", file=sys.stderr)

    if apply_icons:
        try:
            th_kora = theme_kora or __import__("theme_kora")
            accent_hex = palette.get("accent") or palette.get("wallpaperAccentColor")
            if accent_hex:
                th_kora.apply_kora_theme(accent_hex, firma)
        except Exception as e:
            print(f"Warning: Kora icon theming failed: {e}", file=sys.stderr)

    return palette


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract wallpaper palette and apply dynamic theme.")
    parser.add_argument("wallpaper", nargs="?", default=None, help="Path to wallpaper image file")
    parser.add_argument("-f", "--force", action="store_true", help="Force re-extraction ignoring cache")
    parser.add_argument("-j", "--json", action="store_true", help="Output full palette as formatted JSON")
    parser.add_argument("--no-sync", action="store_true", help="Do not sync ~/.cache/quickshell/theme.json")
    parser.add_argument("--no-kitty", action="store_true", help="Do not apply Kitty terminal theme")
    parser.add_argument("--no-thunar", action="store_true", help="Do not apply Thunar dynamic background theme")
    parser.add_argument("--no-icons", action="store_true", help="Do not apply Kora icon tinting")
    parser.add_argument("--firma", default=None, help="Custom signature hash for generated theme names")
    # Legacy flags for compatibility
    parser.add_argument("--gtk", action="store_true", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--no-gtk", action="store_true", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--icons", action="store_true", default=None, help=argparse.SUPPRESS)

    args = parser.parse_args()

    apply_thunar = not args.no_thunar
    if args.no_gtk:
        apply_thunar = False

    t0 = time.perf_counter()
    try:
        palette = apply_theme(
            wallpaper_path=args.wallpaper,
            force=args.force,
            sync_qs=not args.no_sync,
            apply_kitty=not args.no_kitty,
            apply_thunar=apply_thunar,
            apply_icons=not args.no_icons,
            firma=args.firma,
        )
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    t1 = time.perf_counter()

    elapsed_ms = (t1 - t0) * 1000.0

    if args.json:
        out = dict(palette)
        out["_elapsed_ms"] = round(elapsed_ms, 3)
        print(json.dumps(out, indent=2))
    else:
        print(f"Applied theme for: {palette['wallpaper']} ({elapsed_ms:.2f} ms)")
        print(f"  Dominant Hue: {palette['dominant_hue_deg']}° | Saturation: {palette['dominant_sat']} | Temp: {palette['temperature']}")
        print(f"  bg0 (barBgColor)    : {palette['bg0']}")
        print(f"  bg1 (surface/side)  : {palette['bg1']}")
        print(f"  bg_selection        : {palette['bg_selection']}")
        print(f"  fg0 (text, CR {palette['wcag_contrast']}:1): {palette['fg0']}")
        print(f"  fg1 (dim text)      : {palette['fg1']}")
        print(f"  accent              : {palette['accent']}")
        print("  ANSI:")
        for idx in range(8):
            print(f"    color{idx:2d}: {palette[f'color{idx}']}   |   color{idx+8:2d}: {palette[f'color{idx+8}']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
