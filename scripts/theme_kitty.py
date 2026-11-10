#!/usr/bin/env python3
"""
theme_kitty.py - Dynamic live theming module for Kitty terminal.

Generates valid Kitty terminal color configuration from a wallpaper palette,
performs an atomic write to ~/.config/kitty/current-theme.conf (.tmp file + os.replace),
and signals running Kitty instances (pkill -SIGUSR1 -x kitty) to reload live.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Union

logger = logging.getLogger("theme_kitty")

# Default target theme file location
DEFAULT_KITTY_THEME_PATH = Path.home() / ".config" / "kitty" / "current-theme.conf"

# Hex color regex validator (#RGB, #RRGGBB, #RRGGBBAA)
HEX_COLOR_PATTERN = re.compile(r"^#([A-Fa-f0-9]{3}|[A-Fa-f0-9]{6}|[A-Fa-f0-9]{8})$")

# Standard fallback ANSI colors (Tokyo Night neutral base)
DEFAULT_ANSI_COLORS = [
    "#15161e",  # 0: Black
    "#f7768e",  # 1: Red
    "#9ece6a",  # 2: Green
    "#e0af68",  # 3: Yellow
    "#7aa2f7",  # 4: Blue
    "#bb9af7",  # 5: Magenta
    "#7dcfff",  # 6: Cyan
    "#a9b1d6",  # 7: White
    "#414868",  # 8: Bright Black
    "#ff7a93",  # 9: Bright Red
    "#b9f27c",  # 10: Bright Green
    "#ff9e64",  # 11: Bright Yellow
    "#7dcfff",  # 12: Bright Blue
    "#c0caf5",  # 13: Bright Magenta
    "#b4f9f8",  # 14: Bright Cyan
    "#c0caf5",  # 15: Bright White
]

# Aliases for color names
ANSI_KEY_ALIASES: Dict[str, str] = {
    "black": "color0",
    "red": "color1",
    "green": "color2",
    "yellow": "color3",
    "blue": "color4",
    "magenta": "color5",
    "cyan": "color6",
    "white": "color7",
    "bright_black": "color8",
    "bright_red": "color9",
    "bright_green": "color10",
    "bright_yellow": "color11",
    "bright_blue": "color12",
    "bright_magenta": "color13",
    "bright_cyan": "color14",
    "bright_white": "color15",
}

UI_KEY_ALIASES: Dict[str, str] = {
    "fg": "foreground",
    "bg": "background",
    "cursor_color": "cursor",
    "cursor_text": "cursor_text_color",
    "selection_fg": "selection_foreground",
    "selection_bg": "selection_background",
    "active_border": "active_border_color",
    "inactive_border": "inactive_border_color",
    "active_tab_fg": "active_tab_foreground",
    "active_tab_bg": "active_tab_background",
    "inactive_tab_fg": "inactive_tab_foreground",
    "inactive_tab_bg": "inactive_tab_background",
    "tab_bar_bg": "tab_bar_background",
    "url": "url_color",
}


def _clean_color(val: Any, default: str = "#ffffff") -> str:
    """Sanitize and format a color value into a valid #RRGGBB hex string."""
    if not isinstance(val, str):
        return default
    val = val.strip()
    if not val:
        return default
    if not val.startswith("#"):
        val = "#" + val
    if HEX_COLOR_PATTERN.match(val):
        return val.lower()
    return default


def normalize_palette(palette: Mapping[str, Any]) -> Dict[str, str]:
    """
    Normalizes various palette input structures (flat dict, pywal format,
    nested colors list/dict, quickshell theme.json) into a standardized dictionary
    containing all 16 ANSI colors and UI colors.
    """
    raw: Dict[str, Any] = dict(palette)
    normalized: Dict[str, str] = {}

    # Extract nested Pywal structures if present
    special = raw.get("special")
    if isinstance(special, dict):
        for k, v in special.items():
            if k not in raw:
                raw[k] = v

    nested_colors = raw.get("colors")
    if isinstance(nested_colors, dict):
        for k, v in nested_colors.items():
            if k not in raw:
                raw[k] = v
    elif isinstance(nested_colors, (list, tuple)):
        for idx, col in enumerate(nested_colors[:16]):
            k = f"color{idx}"
            if k not in raw:
                raw[k] = col

    # Support quickshell theme.json keys
    if "barBgColor" in raw and "background" not in raw:
        raw["background"] = raw["barBgColor"]
    if "wallpaperAccentColor" in raw and "active_border_color" not in raw:
        raw["active_border_color"] = raw["wallpaperAccentColor"]

    # Normalize ANSI aliases (e.g. 'black' -> 'color0')
    for alias, standard in ANSI_KEY_ALIASES.items():
        if alias in raw and standard not in raw:
            raw[standard] = raw[alias]

    # Normalize numeric keys (e.g. 0 -> 'color0', '0' -> 'color0')
    for i in range(16):
        key = f"color{i}"
        if i in raw and key not in raw:
            raw[key] = raw[i]
        if str(i) in raw and key not in raw:
            raw[key] = raw[str(i)]

    # Normalize UI aliases
    for alias, standard in UI_KEY_ALIASES.items():
        if alias in raw and standard not in raw:
            raw[standard] = raw[alias]

    # Resolve 16 ANSI colors with fallbacks
    for i in range(16):
        key = f"color{i}"
        default_val = DEFAULT_ANSI_COLORS[i]
        val = raw.get(key)
        normalized[key] = _clean_color(val, default_val) if val else default_val

    # Resolve core UI colors
    # Background
    bg = _clean_color(raw.get("background"), normalized["color0"])
    normalized["background"] = bg

    # Foreground
    fg = _clean_color(raw.get("foreground"), normalized["color15"])
    normalized["foreground"] = fg

    # Cursor
    cursor = _clean_color(raw.get("cursor"), fg)
    normalized["cursor"] = cursor

    # Cursor text color
    cursor_text = _clean_color(raw.get("cursor_text_color"), bg)
    normalized["cursor_text_color"] = cursor_text

    # Selection
    sel_bg = _clean_color(raw.get("selection_background"), normalized["color4"])
    sel_fg = _clean_color(raw.get("selection_foreground"), "#ffffff")
    normalized["selection_background"] = sel_bg
    normalized["selection_foreground"] = sel_fg

    # Window borders
    active_border = _clean_color(
        raw.get("active_border_color"),
        raw.get("accent") or normalized["color4"]
    )
    inactive_border = _clean_color(raw.get("inactive_border_color"), normalized["color8"])
    normalized["active_border_color"] = active_border
    normalized["inactive_border_color"] = inactive_border

    # Tab bar colors
    normalized["active_tab_foreground"] = _clean_color(raw.get("active_tab_foreground"), bg)
    normalized["active_tab_background"] = _clean_color(raw.get("active_tab_background"), active_border)
    normalized["inactive_tab_foreground"] = _clean_color(raw.get("inactive_tab_foreground"), normalized["color7"])
    normalized["inactive_tab_background"] = _clean_color(raw.get("inactive_tab_background"), normalized["color0"])
    normalized["tab_bar_background"] = _clean_color(raw.get("tab_bar_background"), bg)

    # URL underline / hover color
    normalized["url_color"] = _clean_color(
        raw.get("url_color"),
        raw.get("accent") or normalized["color6"]
    )

    return normalized


def generate_kitty_theme(palette: Mapping[str, Any], wallpaper_name: str = "") -> str:
    """
    Formats the palette into valid Kitty theme configuration syntax.
    Includes ANSI 0-15 and all UI colors (foreground, background, cursor,
    selection, window borders, tabs).
    """
    p = normalize_palette(palette)
    wp_clean = Path(wallpaper_name).name if wallpaper_name else "Dynamic Wallpaper"

    lines = [
        "# vim:ft=kitty",
        f"## name: Dynamic Theme ({wp_clean})",
        f"## Generated dynamically from wallpaper: {wp_clean}",
        f"## Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        "",
        "# Basic terminal UI colors",
        f"foreground              {p['foreground']}",
        f"background              {p['background']}",
        f"selection_foreground    {p['selection_foreground']}",
        f"selection_background    {p['selection_background']}",
        "",
        "# Cursor colors",
        f"cursor                  {p['cursor']}",
        f"cursor_text_color       {p['cursor_text_color']}",
        "",
        "# URL underline color on mouse hover",
        f"url_color               {p['url_color']}",
        "",
        "# Kitty window borders",
        f"active_border_color     {p['active_border_color']}",
        f"inactive_border_color   {p['inactive_border_color']}",
        "",
        "# Tab bar colors",
        f"active_tab_foreground   {p['active_tab_foreground']}",
        f"active_tab_background   {p['active_tab_background']}",
        f"inactive_tab_foreground {p['inactive_tab_foreground']}",
        f"inactive_tab_background {p['inactive_tab_background']}",
        f"tab_bar_background      {p['tab_bar_background']}",
        "",
        "# 16 Terminal Colors (ANSI)",
        "# Black",
        f"color0                  {p['color0']}",
        f"color8                  {p['color8']}",
        "",
        "# Red",
        f"color1                  {p['color1']}",
        f"color9                  {p['color9']}",
        "",
        "# Green",
        f"color2                  {p['color2']}",
        f"color10                 {p['color10']}",
        "",
        "# Yellow",
        f"color3                  {p['color3']}",
        f"color11                 {p['color11']}",
        "",
        "# Blue",
        f"color4                  {p['color4']}",
        f"color12                 {p['color12']}",
        "",
        "# Magenta",
        f"color5                  {p['color5']}",
        f"color13                 {p['color13']}",
        "",
        "# Cyan",
        f"color6                  {p['color6']}",
        f"color14                 {p['color14']}",
        "",
        "# White",
        f"color7                  {p['color7']}",
        f"color15                 {p['color15']}",
        "",
    ]
    return "\n".join(lines)


def write_theme_file(content: str, target_path: Union[str, Path] = DEFAULT_KITTY_THEME_PATH) -> Path:
    """
    Performs an ATOMIC write to target_path:
    1. Writes to target_path.tmp
    2. Flushes and fsyncs to ensure data durability
    3. Atomically replaces target_path via os.replace
    """
    target = Path(target_path).expanduser().resolve()
    target.parent.mkdir(parents=True, exist_ok=True)

    tmp_path = target.with_name(f"{target.name}.tmp")
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, target)
        return target
    except Exception as e:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        raise IOError(f"Failed atomic write to {target}: {e}") from e


def signal_kitty() -> bool:
    """
    Signals running Kitty processes via `pkill -SIGUSR1 -x kitty` to live reload.
    Gracefully handles return codes:
    - 0: Successfully signaled running Kitty instance(s).
    - 1: No Kitty process found (normal when Kitty is closed).
    Returns True if signal was delivered, False otherwise. Does not crash.
    """
    cmd = ["pkill", "-SIGUSR1", "-x", "kitty"]
    try:
        res = subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if res.returncode == 0:
            logger.debug("Successfully signaled Kitty (SIGUSR1).")
            return True
        elif res.returncode == 1:
            logger.debug("Kitty is not currently running (returncode 1).")
            return False
        else:
            logger.warning("pkill returned unexpected code: %d", res.returncode)
            return False
    except FileNotFoundError:
        logger.warning("pkill utility not found; cannot signal Kitty.")
        return False
    except Exception as e:
        logger.warning("Error signaling Kitty: %s", e)
        return False


def apply_kitty_theme(
    palette: Mapping[str, Any],
    wallpaper_name: str = "",
    target_path: Optional[Union[str, Path]] = None,
    notify: bool = True,
) -> bool:
    """
    Main dynamic theming function for Kitty:
    1. Converts palette into valid Kitty theme configuration syntax.
    2. Atomically writes ~/.config/kitty/current-theme.conf.
    3. Dispatches pkill -SIGUSR1 -x kitty.

    Args:
        palette: Dictionary containing 16 ANSI colors and/or UI colors.
        wallpaper_name: Optional wallpaper name/path for configuration header.
        target_path: Optional custom output path (defaults to ~/.config/kitty/current-theme.conf).
        notify: Whether to dispatch SIGUSR1 to Kitty processes.

    Returns:
        True if the theme was formatted and written atomically, False on error.
    """
    try:
        content = generate_kitty_theme(palette, wallpaper_name)
        dest = target_path or DEFAULT_KITTY_THEME_PATH
        write_theme_file(content, dest)

        if notify:
            signal_kitty()

        return True
    except Exception as e:
        logger.error("Failed to apply Kitty theme: %s", e)
        return False


# CLI demo / verification support
if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    sample_palette = {
        "foreground": "#c0caf5",
        "background": "#1a1b26",
        "selection_foreground": "#ffffff",
        "selection_background": "#33467c",
        "cursor": "#c0caf5",
        "cursor_text_color": "#1a1b26",
        "active_border_color": "#7aa2f7",
        "inactive_border_color": "#414868",
        "active_tab_foreground": "#16161e",
        "active_tab_background": "#7aa2f7",
        "inactive_tab_foreground": "#a9b1d6",
        "inactive_tab_background": "#1f2335",
        "tab_bar_background": "#15161e",
        "url_color": "#73daca",
        "colors": DEFAULT_ANSI_COLORS,
    }

    if "--help" in sys.argv:
        print("Usage: python3 theme_kitty.py [--test | <theme.json>] [--wallpaper <name>]")
        sys.exit(0)

    if "--test" in sys.argv or len(sys.argv) == 1:
        print("Applying test theme to Kitty...")
        t0 = time.perf_counter()
        ok = apply_kitty_theme(sample_palette, wallpaper_name="test_pattern.jpg")
        dt = (time.perf_counter() - t0) * 1000
        print(f"Result: {ok} (completed in {dt:.2f} ms)")
        sys.exit(0 if ok else 1)

    json_path = sys.argv[1]
    wp = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--wallpaper" else ""
    try:
        with open(json_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        ok = apply_kitty_theme(data, wallpaper_name=wp)
        sys.exit(0 if ok else 1)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
