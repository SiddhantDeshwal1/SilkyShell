#!/usr/bin/env python3
"""
benchmark_theme.py — End-to-end performance benchmarking and validation test suite
for the dynamic theming pipeline (Kitty, GTK3/Thunar, Quickshell theme.json).

Usage:
    python3 tests/benchmark_theme.py [options] [wallpaper_path]

Options:
    -a, --all        Benchmark across all wallpapers found in ~/Pictures/wallpapers
    -v, --verbose    Print detailed validation logs
    -j, --json       Output benchmark results as JSON
    -h, --help       Show help message
"""

from __future__ import annotations

import argparse
import colorsys
import glob
import json
import os
import re
import resource
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# Base paths
PROJECT_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = PROJECT_ROOT / "scripts"
APPLY_THEME_SCRIPT = SCRIPTS_DIR / "apply-theme.py"

HOME = Path.home()
KITTY_THEME_CONF = HOME / ".config" / "kitty" / "current-theme.conf"
THEMES_DIR = HOME / ".local" / "share" / "themes"
ICONS_DIR = HOME / ".local" / "share" / "icons"
THEME_JSON = HOME / ".cache" / "quickshell" / "theme.json"
CACHE_JSON = HOME / ".cache" / "quickshell" / "theme_cache.json"
WALLPAPERS_DIR = HOME / "Pictures" / "wallpapers"

HEX_COLOR_RE = re.compile(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")


def hex_to_rgb(hex_str: str) -> Tuple[float, float, float]:
    s = hex_str.lstrip("#")
    if len(s) == 3:
        s = "".join(c * 2 for c in s)
    val = int(s, 16)
    return (((val >> 16) & 0xFF) / 255.0, ((val >> 8) & 0xFF) / 255.0, (val & 0xFF) / 255.0)


def relative_luminance(r: float, g: float, b: float) -> float:
    def lin(c: float) -> float:
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def contrast_ratio(rgb1: Tuple[float, float, float], rgb2: Tuple[float, float, float]) -> float:
    l1 = relative_luminance(*rgb1)
    l2 = relative_luminance(*rgb2)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)


class ValidationResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = True
        self.errors: List[str] = []
        self.warnings: List[str] = []
        self.details: Dict[str, Any] = {}

    def error(self, msg: str) -> None:
        self.passed = False
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)


def validate_kitty_theme(path: Path = KITTY_THEME_CONF) -> ValidationResult:
    res = ValidationResult("Kitty Theme (current-theme.conf)")
    if not path.is_file():
        res.error(f"File not found: {path}")
        return res

    size = path.stat().st_size
    res.details["file_size_bytes"] = size
    if size == 0:
        res.error(f"File is empty: {path}")
        return res

    try:
        content = path.read_text(encoding="utf-8")
    except Exception as e:
        res.error(f"Cannot read file: {e}")
        return res

    parsed_directives: Dict[str, str] = {}
    line_num = 0
    for line in content.splitlines():
        line_num += 1
        sline = line.strip()
        if not sline or sline.startswith("#"):
            continue

        parts = sline.split(None, 1)
        if len(parts) != 2:
            res.error(f"Syntax error at line {line_num}: invalid directive '{sline}'")
            continue

        key, val = parts[0].strip(), parts[1].strip()
        parsed_directives[key] = val

    # Verify all 16 ANSI colors exist
    missing_ansi = []
    for i in range(16):
        key = f"color{i}"
        if key not in parsed_directives:
            missing_ansi.append(key)
        else:
            cval = parsed_directives[key]
            if not HEX_COLOR_RE.match(cval):
                res.error(f"Invalid ANSI color value for {key}: '{cval}'")
    if missing_ansi:
        res.error(f"Missing ANSI color directives: {missing_ansi}")

    # Verify critical UI keys
    required_ui_keys = [
        "foreground", "background", "selection_foreground",
        "selection_background", "cursor", "cursor_text_color"
    ]
    missing_ui = [k for k in required_ui_keys if k not in parsed_directives]
    if missing_ui:
        res.error(f"Missing required UI directives: {missing_ui}")

    # Contrast check
    if "background" in parsed_directives and "foreground" in parsed_directives:
        try:
            bg_rgb = hex_to_rgb(parsed_directives["background"])
            fg_rgb = hex_to_rgb(parsed_directives["foreground"])
            cr = contrast_ratio(bg_rgb, fg_rgb)
            res.details["contrast_ratio"] = round(cr, 2)
            res.details["bg_color"] = parsed_directives["background"]
            res.details["fg_color"] = parsed_directives["foreground"]
            if cr < 7.0:
                res.warn(f"Contrast ratio ({cr:.2f}:1) is lower than recommended WCAG AAA (7:1)")
        except Exception as e:
            res.warn(f"Could not compute contrast ratio: {e}")

    res.details["directives_count"] = len(parsed_directives)
    return res


def validate_gtk_theme(themes_dir: Path = THEMES_DIR) -> ValidationResult:
    res = ValidationResult("GTK3 / Thunar Theme (gtk-3.0/gtk.css)")
    if not themes_dir.is_dir():
        res.error(f"Themes directory not found: {themes_dir}")
        return res

    # Find Graphite-qs-* theme directory
    matches = sorted(themes_dir.glob("Graphite-qs-*"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not matches:
        res.error(f"No Graphite-qs-* directory found in {themes_dir}")
        return res

    theme_dir = matches[0]
    res.details["theme_name"] = theme_dir.name

    gtk3_css = theme_dir / "gtk-3.0" / "gtk.css"
    if not gtk3_css.is_file():
        res.error(f"gtk-3.0/gtk.css not found in {theme_dir}")
        return res

    content = gtk3_css.read_text(encoding="utf-8")
    res.details["gtk3_size_bytes"] = len(content)

    # Syntax balance checks
    open_braces = content.count("{")
    close_braces = content.count("}")
    if open_braces != close_braces:
        res.error(f"Unbalanced braces in gtk.css: {open_braces} '{{' vs {close_braces} '}}'")

    open_comments = content.count("/*")
    close_comments = content.count("*/")
    if open_comments != close_comments:
        res.error(f"Unbalanced comments in gtk.css: {open_comments} '/*' vs {close_comments} '*/'")

    # Import statement check
    if 'Graphite-blue-Dark/gtk-3.0/gtk.css' not in content:
        res.warn("Base Graphite-blue-Dark @import statement not found in gtk-3.0/gtk.css")

    # Pure black check for Thunar bg
    if "background-color: #000000;" not in content:
        res.error("Thunar pure black background (#000000) not found in gtk-3.0/gtk.css")

    # Check Thunar rules
    if ".thunar" not in content and "treeview" not in content:
        res.warn("No Thunar specific CSS selectors detected in gtk-3.0/gtk.css")

    # Check GTK4 CSS and index.theme
    gtk4_css = theme_dir / "gtk-4.0" / "gtk.css"
    index_theme = theme_dir / "index.theme"
    res.details["has_gtk4"] = gtk4_css.is_file()
    res.details["has_index_theme"] = index_theme.is_file()

    return res


def validate_theme_json(path: Path = THEME_JSON, expected_wp: Optional[str] = None) -> ValidationResult:
    res = ValidationResult("Quickshell Theme Config (~/.cache/quickshell/theme.json)")
    if not path.is_file():
        res.error(f"theme.json not found at {path}")
        return res

    try:
        content = path.read_text(encoding="utf-8")
        data = json.loads(content)
    except Exception as e:
        res.error(f"Failed to parse JSON: {e}")
        return res

    # Check required backward-compatible keys
    req_keys = ["darkMode", "barBgColor", "wallpaperAccentColor", "wallpaper", "wallpaperMtime"]
    missing = [k for k in req_keys if k not in data]
    if missing:
        res.error(f"Missing required keys in theme.json: {missing}")

    # Check color hex syntax
    for c_key in ["barBgColor", "wallpaperAccentColor", "bg0", "fg0", "accent"]:
        if c_key in data:
            cval = str(data[c_key])
            if not HEX_COLOR_RE.match(cval):
                res.error(f"Invalid hex color format for '{c_key}': '{cval}'")

    if expected_wp and "wallpaper" in data:
        exp_abs = os.path.abspath(expected_wp)
        got_abs = os.path.abspath(data["wallpaper"])
        if exp_abs != got_abs:
            res.warn(f"Wallpaper mismatch in theme.json: expected '{exp_abs}', got '{got_abs}'")

    res.details["barBgColor"] = data.get("barBgColor")
    res.details["wallpaperAccentColor"] = data.get("wallpaperAccentColor")
    res.details["darkMode"] = data.get("darkMode")
    return res


def run_benchmark_for_wallpaper(wallpaper_path: str, verbose: bool = False) -> Dict[str, Any]:
    wallpaper_path = os.path.abspath(wallpaper_path)
    if not os.path.isfile(wallpaper_path):
        raise FileNotFoundError(f"Wallpaper not found: {wallpaper_path}")

    bench: Dict[str, Any] = {
        "wallpaper": wallpaper_path,
        "wallpaper_name": os.path.basename(wallpaper_path),
        "file_size_kb": round(os.path.getsize(wallpaper_path) / 1024, 1),
    }

    # 1. Cold Run Benchmark (with --force to bypass any cache)
    cmd_cold = [sys.executable, str(APPLY_THEME_SCRIPT), "--force", wallpaper_path]
    ru_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.perf_counter()
    proc_cold = subprocess.run(cmd_cold, capture_output=True, text=True)
    t1 = time.perf_counter()
    ru_after = resource.getrusage(resource.RUSAGE_CHILDREN)

    cold_time_ms = (t1 - t0) * 1000.0
    rss_kb = ru_after.ru_maxrss  # on Linux, ru_maxrss is in KiB

    bench["cold_run_ms"] = round(cold_time_ms, 2)
    bench["cold_exit_code"] = proc_cold.returncode
    bench["peak_rss_kb"] = rss_kb
    bench["peak_rss_mb"] = round(rss_kb / 1024.0, 2)

    # Parse internal timing from output if available
    cold_internal = None
    if proc_cold.stdout:
        m = re.search(r"\(([0-9.]+)\s*ms\)", proc_cold.stdout)
        if m:
            cold_internal = float(m.group(1))
    bench["cold_internal_ms"] = cold_internal

    if proc_cold.returncode != 0:
        bench["cold_error"] = proc_cold.stderr.strip()
        return bench

    # 2. Warm Run Benchmark (cache hit)
    cmd_warm = [sys.executable, str(APPLY_THEME_SCRIPT), wallpaper_path]
    t2 = time.perf_counter()
    proc_warm = subprocess.run(cmd_warm, capture_output=True, text=True)
    t3 = time.perf_counter()

    warm_time_ms = (t3 - t2) * 1000.0
    bench["warm_run_ms"] = round(warm_time_ms, 2)
    bench["warm_exit_code"] = proc_warm.returncode

    warm_internal = None
    if proc_warm.stdout:
        m = re.search(r"\(([0-9.]+)\s*ms\)", proc_warm.stdout)
        if m:
            warm_internal = float(m.group(1))
    bench["warm_internal_ms"] = warm_internal

    # 3. Validations
    v_kitty = validate_kitty_theme(KITTY_THEME_CONF)
    v_gtk = validate_gtk_theme(THEMES_DIR)
    v_qs = validate_theme_json(THEME_JSON, expected_wp=wallpaper_path)

    bench["validations"] = {
        "kitty": {
            "passed": v_kitty.passed,
            "errors": v_kitty.errors,
            "warnings": v_kitty.warnings,
            "details": v_kitty.details,
        },
        "gtk": {
            "passed": v_gtk.passed,
            "errors": v_gtk.errors,
            "warnings": v_gtk.warnings,
            "details": v_gtk.details,
        },
        "quickshell": {
            "passed": v_qs.passed,
            "errors": v_qs.errors,
            "warnings": v_qs.warnings,
            "details": v_qs.details,
        },
    }

    bench["all_passed"] = (
        proc_cold.returncode == 0
        and proc_warm.returncode == 0
        and v_kitty.passed
        and v_gtk.passed
        and v_qs.passed
    )

    return bench


def print_report_table(results: List[Dict[str, Any]], verbose: bool = False) -> None:
    print("\n" + "=" * 90)
    print(" DYNAMIC THEMING END-TO-END BENCHMARK & VALIDATION REPORT ".center(90, "="))
    print("=" * 90)

    header = f"{'Wallpaper':<34} | {'Cold (ms)':<10} | {'Warm (ms)':<10} | {'RSS (MB)':<9} | {'Kitty':<6} | {'GTK':<6} | {'QS':<6}"
    print(header)
    print("-" * len(header))

    for r in results:
        wp_name = r["wallpaper_name"]
        if len(wp_name) > 32:
            wp_name = wp_name[:29] + "..."

        cold_str = f"{r.get('cold_run_ms', 0):.2f}"
        warm_str = f"{r.get('warm_run_ms', 0):.2f}"
        rss_str = f"{r.get('peak_rss_mb', 0):.2f}"

        val = r.get("validations", {})
        k_pass = "✓ PASS" if val.get("kitty", {}).get("passed") else "✗ FAIL"
        g_pass = "✓ PASS" if val.get("gtk", {}).get("passed") else "✗ FAIL"
        q_pass = "✓ PASS" if val.get("quickshell", {}).get("passed") else "✗ FAIL"

        row = f"{wp_name:<34} | {cold_str:<10} | {warm_str:<10} | {rss_str:<9} | {k_pass:<6} | {g_pass:<6} | {q_pass:<6}"
        print(row)

    print("=" * 90)

    # Details & Errors section
    has_errors = False
    for r in results:
        val = r.get("validations", {})
        all_errs = []
        for mod, mdata in val.items():
            if mdata.get("errors"):
                all_errs.extend([f"[{mod.upper()}] {e}" for e in mdata["errors"]])

        if all_errs:
            has_errors = True
            print(f"\n❌ Validation errors for {r['wallpaper_name']}:")
            for e in all_errs:
                print(f"   • {e}")

        if verbose:
            print(f"\nℹ️ Details for {r['wallpaper_name']}:")
            print(f"   • Process Cold:  {r['cold_run_ms']:.2f} ms (spawn + run)")
            print(f"   • Process Warm:  {r['warm_run_ms']:.2f} ms (spawn + cache check)")
            if r.get('cold_internal_ms') is not None and r.get('warm_internal_ms') is not None:
                print(f"   • Pure Pipeline: {r['cold_internal_ms']:.2f} ms cold | {r['warm_internal_ms']:.2f} ms warm cache hit (Internal Speedup: {r['cold_internal_ms'] / max(r['warm_internal_ms'], 0.001):.1f}x)")
            print(f"   • Peak Memory:   {r['peak_rss_mb']:.2f} MB ({r['peak_rss_kb']} KB)")
            for mod, mdata in val.items():
                print(f"   • {mod.capitalize()} Theme: {mdata.get('details')}")

    if not has_errors:
        print("\n✨ ALL TESTS & INTEGRATION BENCHMARKS PASSED SUCCESSFULLY! ✨\n")
    else:
        print("\n⚠️ SOME VALIDATION CHECKS FAILED. See details above.\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Dynamic Theming Benchmark and Verification Test Suite")
    parser.add_argument("wallpaper", nargs="?", default=None, help="Path to wallpaper file to test")
    parser.add_argument("-a", "--all", action="store_true", help="Run benchmark across all wallpapers in ~/Pictures/wallpapers")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose logging of details")
    parser.add_argument("-j", "--json", action="store_true", help="Output JSON only")

    args = parser.parse_args()

    wallpapers: List[str] = []
    if args.wallpaper:
        wallpapers.append(args.wallpaper)
    elif args.all:
        pattern = str(WALLPAPERS_DIR / "*")
        found = [f for f in glob.glob(pattern) if os.path.isfile(f) and f.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))]
        wallpapers = sorted(found)
    else:
        # Default: pick up to 3 wallpapers from ~/Pictures/wallpapers for representative testing
        pattern = str(WALLPAPERS_DIR / "*")
        found = [f for f in glob.glob(pattern) if os.path.isfile(f) and f.lower().endswith((".jpg", ".jpeg", ".png", ".webp"))]
        if found:
            wallpapers = sorted(found)[:3]

    if not wallpapers:
        print(f"Error: No wallpaper files found in {WALLPAPERS_DIR}", file=sys.stderr)
        return 1

    results: List[Dict[str, Any]] = []
    all_ok = True

    for wp in wallpapers:
        try:
            res = run_benchmark_for_wallpaper(wp, verbose=args.verbose)
            results.append(res)
            if not res.get("all_passed", False):
                all_ok = False
        except Exception as e:
            print(f"Failed benchmark for {wp}: {e}", file=sys.stderr)
            all_ok = False

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print_report_table(results, verbose=args.verbose)

    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
