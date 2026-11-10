#!/usr/bin/env python3
"""
theme_thunar_bg.py — Scoped dynamic background and selection theming for Thunar.

Creates and activates a lightweight GTK metatheme (Graphite-qs-<hash>) that
imports the user's base Graphite-blue-Dark theme and overrides ONLY Thunar-specific
background, sidebar, and selection colors, leaving window decorations, headers,
buttons, and all non-Thunar GTK applications 100% untouched.

Benchmark target: < 10ms execution time.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

# Base constants
BASE_THEME_NAME = "Graphite-blue-Dark"
DEFAULT_BASE_THEME_PATH = f"/home/banana/.themes/{BASE_THEME_NAME}"
LOCAL_THEMES_DIR = os.path.expanduser("~/.local/share/themes")
DOT_THEMES_DIR = os.path.expanduser("~/.themes")
GTK3_SETTINGS_PATH = os.path.expanduser("~/.config/gtk-3.0/settings.ini")
GTK4_SETTINGS_PATH = os.path.expanduser("~/.config/gtk-4.0/settings.ini")
GTK2_RC_PATH = os.path.expanduser("~/.gtkrc-2.0")
THEME_JSON_PATH = os.path.expanduser("~/.cache/quickshell/theme.json")


def normalize_hex(color_str: str) -> str:
    """Ensures hex color starts with '#' and trims 8-digit alpha if present."""
    if not color_str:
        return "#000000"
    c = color_str.strip()
    if not c.startswith("#"):
        c = "#" + c
    # If 8-digit hex (#rrggbbaa), strip the alpha channel for CSS color compatibility
    if len(c) == 9:
        c = c[:7]
    return c


def find_base_theme(theme_name: str = BASE_THEME_NAME) -> str:
    """Resolves the base theme directory, prioritizing ~/.themes."""
    candidates = [
        f"/home/banana/.themes/{theme_name}",
        os.path.expanduser(f"~/.themes/{theme_name}"),
        os.path.expanduser(f"~/.local/share/themes/{theme_name}"),
        f"/usr/share/themes/{theme_name}",
    ]
    for p in candidates:
        if os.path.isdir(p):
            return p
    return DEFAULT_BASE_THEME_PATH


def sanitize_firma(
    firma: str | None,
    bg0: str,
    bg1: str,
    fg0: str,
    accent: str,
) -> str:
    """
    Returns a clean signature/hash for the theme name.
    If firma is supplied, cleans it; otherwise computes an 8-character MD5 hash of colors.
    """
    clean = ""
    if firma:
        clean = re.sub(r"[^a-zA-Z0-9_-]", "", str(firma))
        clean = clean.removeprefix("Graphite-qs-")

    if not clean:
        raw_key = f"{bg0}:{bg1}:{fg0}:{accent}"
        clean = hashlib.md5(raw_key.encode("utf-8")).hexdigest()[:8]

    return clean


def generate_index_theme(theme_name: str, base_name: str = BASE_THEME_NAME) -> str:
    """Generates the index.theme metatheme file content."""
    return (
        "[Desktop Entry]\n"
        "Type=X-GNOME-Metatheme\n"
        f"Name={theme_name}\n"
        f"Comment={base_name} with dynamic wallpaper background for Thunar\n"
        "Encoding=UTF-8\n"
        "\n"
        "[X-GNOME-Metatheme]\n"
        f"GtkTheme={theme_name}\n"
        f"MetacityTheme={base_name}\n"
        "IconTheme=Tela-circle-dark\n"
        "CursorTheme=Graphite-cursors\n"
    )


def generate_gtk3_css(
    bg0: str,
    bg1: str,
    fg0: str,
    accent: str,
    base_theme_path: str = DEFAULT_BASE_THEME_PATH,
    force_pure_black: bool = True,
) -> str:
    """
    Generates gtk-3.0/gtk.css importing Graphite-blue-Dark and adding
    strictly-scoped overrides for Thunar background, sidebar, and selection.
    Headers, buttons, and other applications remain completely untouched.
    Thunar background is always pure black (#000000).
    """
    norm_bg0 = "#000000" if force_pure_black else normalize_hex(bg0)
    norm_bg1 = "#000000" if force_pure_black else normalize_hex(bg1)
    norm_fg0 = normalize_hex(fg0)
    norm_accent = normalize_hex(accent)

    return f"""@import url("file://{base_theme_path}/gtk-3.0/gtk.css");

/* Scoped background for Thunar ONLY - Pure Black */
.thunar,
.thunar window,
.thunar .view,
.thunar iconview,
.thunar treeview.view,
.thunar .standard-view,
.thunar .standard-view.frame,
window.background.csd.thunar,
window.background.thunar {{
    background-color: {norm_bg0};
    color: {norm_fg0};
}}

/* Sidebar and shortcuts pane */
.thunar .sidebar,
.thunar .sidebar .view,
.thunar .shortcuts-pane,
.thunar > grid.horizontal > paned.horizontal > scrolledwindow.frame.sidebar.shortcuts-pane,
window.background.csd.thunar > grid.horizontal > paned.horizontal > scrolledwindow.frame.sidebar.shortcuts-pane {{
    background-color: {norm_bg1};
    color: {norm_fg0};
}}

/* Location toolbar and statusbar */
.thunar #location-toolbar,
.thunar statusbar {{
    background-color: {norm_bg0};
}}

/* Thunar selection highlight */
.thunar .view:selected,
.thunar iconview:selected,
.thunar treeview.view:selected {{
    background-color: alpha({norm_accent}, 0.28);
    color: {norm_fg0};
}}
"""


def generate_gtk4_css(base_theme_path: str = DEFAULT_BASE_THEME_PATH) -> str:
    """Generates gtk-4.0/gtk.css importing the base theme."""
    return f'@import url("file://{base_theme_path}/gtk-4.0/gtk.css");\n'


def update_gtk_settings(theme_name: str, paths: Optional[List[str]] = None) -> None:
    """
    Atomically updates gtk-theme-name={theme_name} under [Settings] in GTK settings files.
    """
    if paths is None:
        paths = [GTK3_SETTINGS_PATH, GTK4_SETTINGS_PATH]

    for ini_path in paths:
        try:
            os.makedirs(os.path.dirname(ini_path), exist_ok=True)
            if not os.path.exists(ini_path):
                with open(ini_path, "w", encoding="utf-8") as fh:
                    fh.write(f"[Settings]\ngtk-theme-name={theme_name}\n")
                continue

            with open(ini_path, "r", encoding="utf-8", errors="ignore") as fh:
                lines = fh.readlines()

            found = False
            in_settings = False
            new_lines: List[str] = []

            for line in lines:
                trimmed = line.strip()
                if trimmed.startswith("[Settings]"):
                    in_settings = True
                    new_lines.append(line)
                elif in_settings and trimmed.startswith("gtk-theme-name"):
                    new_lines.append(f"gtk-theme-name={theme_name}\n")
                    found = True
                elif in_settings and trimmed.startswith("["):
                    if not found:
                        new_lines.append(f"gtk-theme-name={theme_name}\n")
                        found = True
                    in_settings = False
                    new_lines.append(line)
                else:
                    new_lines.append(line)

            if not found:
                idx = -1
                for i, l in enumerate(new_lines):
                    if l.strip() == "[Settings]":
                        idx = i + 1
                        break
                if idx >= 0:
                    new_lines.insert(idx, f"gtk-theme-name={theme_name}\n")
                else:
                    new_lines.append("\n[Settings]\n")
                    new_lines.append(f"gtk-theme-name={theme_name}\n")

            tmp_path = ini_path + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as fh:
                fh.writelines(new_lines)
            os.replace(tmp_path, ini_path)
        except OSError:
            pass

    # Optional legacy ~/.gtkrc-2.0
    if os.path.isfile(GTK2_RC_PATH):
        try:
            with open(GTK2_RC_PATH, "r", encoding="utf-8", errors="ignore") as fh:
                content = fh.read()
            if "gtk-theme-name=" in content:
                new_content = re.sub(
                    r'gtk-theme-name\s*=\s*"?[^"\n]*"?',
                    f'gtk-theme-name="{theme_name}"',
                    content,
                )
            else:
                new_content = content.rstrip() + f'\ngtk-theme-name="{theme_name}"\n'

            tmp = GTK2_RC_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(new_content)
            os.replace(tmp, GTK2_RC_PATH)
        except OSError:
            pass


def prune_old_themes(
    keep_theme: Optional[str] = None,
    base_dirs: Optional[List[str]] = None,
) -> List[str]:
    """
    Deletes previous Graphite-qs-* theme directories and symlinks from ~/.local/share/themes
    and ~/.themes. Skips keep_theme if given.
    """
    if base_dirs is None:
        base_dirs = [LOCAL_THEMES_DIR, DOT_THEMES_DIR]

    pruned: List[str] = []
    for parent in base_dirs:
        if not os.path.isdir(parent):
            continue
        try:
            for entry in os.listdir(parent):
                if entry.startswith("Graphite-qs-") and (keep_theme is None or entry != keep_theme):
                    full_path = os.path.join(parent, entry)
                    try:
                        if os.path.islink(full_path) or os.path.isfile(full_path):
                            os.unlink(full_path)
                            pruned.append(full_path)
                        elif os.path.isdir(full_path):
                            shutil.rmtree(full_path, ignore_errors=True)
                            pruned.append(full_path)
                    except OSError:
                        pass
        except OSError:
            pass

    return pruned


def create_thunar_theme(
    bg0: str,
    bg1: str,
    fg0: str,
    accent: str,
    firma: str = "",
    base_theme_dir: Optional[str] = None,
    output_base: Optional[str] = None,
    symlink_base: Optional[str] = None,
) -> Tuple[str, str]:
    """
    Creates the theme directory structure and files on disk.

    Returns:
        (theme_name, theme_dir_path)
    """
    base_dir = base_theme_dir or find_base_theme()
    theme_hash = sanitize_firma(firma, bg0, bg1, fg0, accent)
    theme_name = f"Graphite-qs-{theme_hash}"

    local_base = output_base or LOCAL_THEMES_DIR
    dot_base = symlink_base or DOT_THEMES_DIR

    theme_dir = os.path.join(local_base, theme_name)
    gtk3_dir = os.path.join(theme_dir, "gtk-3.0")
    gtk4_dir = os.path.join(theme_dir, "gtk-4.0")

    os.makedirs(gtk3_dir, exist_ok=True)
    os.makedirs(gtk4_dir, exist_ok=True)

    # 1. index.theme
    index_content = generate_index_theme(theme_name, os.path.basename(base_dir))
    with open(os.path.join(theme_dir, "index.theme"), "w", encoding="utf-8") as fh:
        fh.write(index_content)

    # 2. gtk-3.0/gtk.css
    gtk3_content = generate_gtk3_css(bg0, bg1, fg0, accent, base_dir)
    with open(os.path.join(gtk3_dir, "gtk.css"), "w", encoding="utf-8") as fh:
        fh.write(gtk3_content)

    # 3. gtk-4.0/gtk.css
    gtk4_content = generate_gtk4_css(base_dir)
    with open(os.path.join(gtk4_dir, "gtk.css"), "w", encoding="utf-8") as fh:
        fh.write(gtk4_content)

    # 4. Symlinks in gtk-3.0 and gtk-4.0
    for d, sub in [(gtk3_dir, "gtk-3.0"), (gtk4_dir, "gtk-4.0")]:
        dark_link = os.path.join(d, "gtk-dark.css")
        if not os.path.exists(dark_link) and not os.path.islink(dark_link):
            try:
                os.symlink("gtk.css", dark_link)
            except OSError:
                pass

        base_assets = os.path.join(base_dir, sub, "assets")
        if os.path.isdir(base_assets):
            assets_link = os.path.join(d, "assets")
            if not os.path.exists(assets_link) and not os.path.islink(assets_link):
                try:
                    os.symlink(base_assets, assets_link)
                except OSError:
                    pass

    # 5. Base metatheme symlinks (metacity-1, xfwm4, gtk-2.0)
    for extra in ["metacity-1", "xfwm4", "gtk-2.0"]:
        extra_src = os.path.join(base_dir, extra)
        if os.path.isdir(extra_src):
            extra_dst = os.path.join(theme_dir, extra)
            if not os.path.exists(extra_dst) and not os.path.islink(extra_dst):
                try:
                    os.symlink(extra_src, extra_dst)
                except OSError:
                    pass

    # 6. Backward-compatible symlink in ~/.themes
    os.makedirs(dot_base, exist_ok=True)
    legacy_symlink = os.path.join(dot_base, theme_name)
    try:
        if os.path.islink(legacy_symlink) or os.path.exists(legacy_symlink):
            os.unlink(legacy_symlink)
        os.symlink(theme_dir, legacy_symlink)
    except OSError:
        pass

    return theme_name, theme_dir


def apply_thunar_bg(
    bg0: str,
    bg1: str,
    fg0: str,
    accent: str,
    firma: str = "",
    sync: bool = False,
    base_theme: Optional[str] = None,
) -> str:
    """
    Dynamically adjusts Thunar background while preserving 100% of Graphite-blue-Dark.

    1. Creates ~/.local/share/themes/Graphite-qs-<hash> and ~/.themes/Graphite-qs-<hash>
    2. Writes index.theme and scoped gtk-3.0/gtk.css + gtk-4.0/gtk.css
    3. Runs `gsettings set org.gnome.desktop.interface gtk-theme "Graphite-qs-<hash>"`
    4. Updates gtk-theme-name in GTK 3 & 4 settings.ini
    5. Prunes older Graphite-qs-* theme directories

    Args:
        bg0: Primary background color (hex, e.g. '#181512')
        bg1: Secondary/sidebar background color (hex, e.g. '#221e19')
        fg0: Primary foreground text color (hex, e.g. '#ededed')
        accent: Accent color (hex, e.g. '#dba157')
        firma: Optional unique signature or identifier
        sync: If True, waits for gsettings process; if False, runs asynchronously (< 2ms)
        base_theme: Optional path to base Graphite-blue-Dark theme

    Returns:
        The generated theme name (e.g. 'Graphite-qs-a1b2c3d4').
    """
    # 1. Create theme files on disk
    theme_name, _ = create_thunar_theme(
        bg0=bg0,
        bg1=bg1,
        fg0=fg0,
        accent=accent,
        firma=firma,
        base_theme_dir=base_theme,
    )

    # 2. Trigger live reload via gsettings
    gsettings_bin = shutil.which("gsettings")
    if gsettings_bin:
        try:
            if sync:
                subprocess.run(
                    [gsettings_bin, "set", "org.gnome.desktop.interface", "gtk-theme", theme_name],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=2.0,
                )
            else:
                try:
                    os.posix_spawn(
                        gsettings_bin,
                        [gsettings_bin, "set", "org.gnome.desktop.interface", "gtk-theme", theme_name],
                        os.environ,
                    )
                except (AttributeError, OSError):
                    subprocess.Popen(
                        [gsettings_bin, "set", "org.gnome.desktop.interface", "gtk-theme", theme_name],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
        except OSError:
            pass

    # 3. Update persistent GTK settings.ini files
    update_gtk_settings(theme_name)

    # 4. Prune older Graphite-qs-* theme files
    prune_old_themes(keep_theme=theme_name)

    return theme_name


def get_current_gtk_theme() -> Optional[str]:
    """Queries current gtk-theme from gsettings."""
    gsettings_bin = shutil.which("gsettings")
    if gsettings_bin:
        try:
            res = subprocess.run(
                [gsettings_bin, "get", "org.gnome.desktop.interface", "gtk-theme"],
                capture_output=True,
                text=True,
                timeout=2.0,
            )
            if res.returncode == 0:
                return res.stdout.strip().strip("'\"")
        except (subprocess.SubprocessError, OSError):
            pass
    return None


def _load_colors_from_theme_json() -> Dict[str, str]:
    """Helper to extract colors from ~/.cache/quickshell/theme.json."""
    defaults = {
        "bg0": "#181512",
        "bg1": "#221e19",
        "fg0": "#ededed",
        "accent": "#dba157",
        "firma": "",
    }
    if os.path.isfile(THEME_JSON_PATH):
        try:
            with open(THEME_JSON_PATH, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            bg0 = data.get("bg0") or (data.get("colors", {}).get("color0"))
            bg1 = data.get("bg1") or data.get("barBgColor")
            fg0 = data.get("fg0") or (data.get("colors", {}).get("color15"))
            accent = data.get("accent") or data.get("wallpaperAccentColor")
            wall = data.get("wallpaper", "")

            if bg0:
                defaults["bg0"] = bg0
            if bg1:
                defaults["bg1"] = bg1
            if fg0:
                defaults["fg0"] = fg0
            if accent:
                defaults["accent"] = accent
            if wall:
                defaults["firma"] = hashlib.md5(wall.encode("utf-8")).hexdigest()[:8]
        except Exception:
            pass
    return defaults


def benchmark(iterations: int = 10) -> None:
    """Runs a latency benchmark of apply_thunar_bg."""
    print(f"=== Benchmarking apply_thunar_bg ({iterations} iterations) ===")
    colors = _load_colors_from_theme_json()

    durations: List[float] = []
    created_themes: List[str] = []

    for i in range(iterations):
        firma = f"bench{i:02d}"
        t0 = time.perf_counter()
        name = apply_thunar_bg(
            bg0=colors["bg0"],
            bg1=colors["bg1"],
            fg0=colors["fg0"],
            accent=colors["accent"],
            firma=firma,
            sync=False,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        durations.append(elapsed_ms)
        created_themes.append(name)

    # Cleanup benchmark themes
    prune_old_themes(keep_theme="none")

    avg_ms = sum(durations) / len(durations)
    min_ms = min(durations)
    max_ms = max(durations)

    print(f"Iterations: {iterations}")
    print(f"Min latency: {min_ms:.3f} ms")
    print(f"Avg latency: {avg_ms:.3f} ms")
    print(f"Max latency: {max_ms:.3f} ms")
    print(f"All runs < 10ms: {all(d < 10.0 for d in durations)}")
    print(f"Target (< 10ms): {'PASS' if avg_ms < 10.0 else 'FAIL'}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scoped dynamic background theming for Thunar.")
    parser.add_argument("bg0", nargs="?", default=None, help="Background hex color (e.g. #181512)")
    parser.add_argument("bg1", nargs="?", default=None, help="Sidebar background hex color (e.g. #221e19)")
    parser.add_argument("fg0", nargs="?", default=None, help="Foreground text hex color (e.g. #ededed)")
    parser.add_argument("accent", nargs="?", default=None, help="Accent highlight hex color (e.g. #dba157)")
    parser.add_argument("firma", nargs="?", default=None, help="Optional unique signature/hash")
    parser.add_argument("--sync", action="store_true", help="Synchronously wait for gsettings execution")
    parser.add_argument("--status", action="store_true", help="Show current GTK theme status")
    parser.add_argument("--prune", action="store_true", help="Prune all Graphite-qs-* themes")
    parser.add_argument("--benchmark", action="store_true", help="Run performance latency benchmark")

    args = parser.parse_args()

    if args.status:
        current = get_current_gtk_theme()
        print(f"Current GTK theme: {current}")
        return 0

    if args.prune:
        pruned = prune_old_themes(keep_theme=None)
        print(f"Pruned {len(pruned)} entries: {pruned}")
        return 0

    if args.benchmark:
        benchmark(iterations=10)
        return 0

    # Resolve colors: command-line args or fallback to ~/.cache/quickshell/theme.json
    colors = _load_colors_from_theme_json()
    bg0 = args.bg0 or colors["bg0"]
    bg1 = args.bg1 or colors["bg1"]
    fg0 = args.fg0 or colors["fg0"]
    accent = args.accent or colors["accent"]
    firma = args.firma or colors["firma"]

    t0 = time.perf_counter()
    applied = apply_thunar_bg(
        bg0=bg0,
        bg1=bg1,
        fg0=fg0,
        accent=accent,
        firma=firma,
        sync=args.sync,
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    print(f"Applied Thunar background theme: {applied} in {elapsed_ms:.2f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
