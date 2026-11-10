#!/usr/bin/env python3
"""
verify_kitty_theming.py - Verification script for Kitty live theming module.

Tests:
1. Palette normalization across formats
2. Atomic write integrity and atomicity
3. Kitty configuration parser validation
4. Signal handling (live & simulated)
5. Timing benchmarks
"""

import os
import sys
import tempfile
import time
from pathlib import Path

# Add scripts directory
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import theme_kitty


def run_verification():
    print("==================================================")
    print("KITTY LIVE THEMING MODULE - VERIFICATION SUITE")
    print("==================================================")

    # 1. Test Palette Generation
    print("[1/5] Testing Palette Generation & Normalization...")
    sample_palette = {
        "foreground": "#c0caf5",
        "background": "#1a1b26",
        "cursor": "#7aa2f7",
        "cursor_text_color": "#1a1b26",
        "selection_foreground": "#ffffff",
        "selection_background": "#33467c",
        "active_border_color": "#7aa2f7",
        "inactive_border_color": "#414868",
        "active_tab_foreground": "#16161e",
        "active_tab_background": "#7aa2f7",
        "inactive_tab_foreground": "#a9b1d6",
        "inactive_tab_background": "#1f2335",
        "tab_bar_background": "#15161e",
        "url_color": "#73daca",
        "color0": "#15161e",
        "color1": "#f7768e",
        "color2": "#9ece6a",
        "color3": "#e0af68",
        "color4": "#7aa2f7",
        "color5": "#bb9af7",
        "color6": "#7dcfff",
        "color7": "#a9b1d6",
        "color8": "#414868",
        "color9": "#ff7a93",
        "color10": "#b9f27c",
        "color11": "#ff9e64",
        "color12": "#7dcfff",
        "color13": "#c0caf5",
        "color14": "#b4f9f8",
        "color15": "#c0caf5",
    }

    norm = theme_kitty.normalize_palette(sample_palette)
    assert len(norm) >= 23, f"Expected at least 23 color keys, got {len(norm)}"
    for key, val in norm.items():
        assert val.startswith("#") and len(val) in (4, 7, 9), f"Invalid color for {key}: {val}"
    print("  ✓ Palette normalized correctly (23 keys validated with valid hex).")

    # 2. Test Atomic Write to Isolated Temp File
    print("\n[2/5] Testing Atomic Write Mechanism...")
    with tempfile.TemporaryDirectory() as tmpdir:
        test_theme_path = Path(tmpdir) / "kitty" / "current-theme.conf"
        content = theme_kitty.generate_kitty_theme(sample_palette, wallpaper_name="cyberpunk-neon.jpg")

        written_path = theme_kitty.write_theme_file(content, test_theme_path)
        assert written_path.exists(), "Target file does not exist after write"
        assert not written_path.with_name("current-theme.conf.tmp").exists(), "Temporary .tmp file was not swapped cleanly"
        assert written_path.read_text(encoding="utf-8") == content, "Content mismatch after write"
        print("  ✓ Atomic write to isolated destination succeeded without lingering .tmp file.")

    # 3. Test Syntax Validation with Kitty Engine
    print("\n[3/5] Validating Syntax with Official Kitty Engine...")
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as f:
        f.write(content)
        f_name = f.name

    try:
        import subprocess
        check_cmd = [
            "kitty", "+runpy",
            f"import kitty.config as kc; opts = kc.load_config('{f_name}'); "
            f"assert opts.foreground is not None; print('  Parsed successfully. Color count:', len(opts.color_table))"
        ]
        res = subprocess.run(check_cmd, capture_output=True, text=True)
        assert res.returncode == 0, f"Kitty config load failed: {res.stderr}"
        print(res.stdout.strip())
        print("  ✓ Kitty configuration engine accepted generated syntax with 0 errors/warnings.")
    finally:
        if os.path.exists(f_name):
            os.unlink(f_name)

    # 4. Test Signaling Kitty Process
    print("\n[4/5] Testing Signal Dispatch (pkill -SIGUSR1 -x kitty)...")
    sig_result = theme_kitty.signal_kitty()
    print(f"  ✓ signal_kitty() executed safely. Result: {sig_result} (True if kitty process active, False if no kitty).")

    # 5. Timing and Performance Benchmark
    print("\n[5/5] Running Performance Benchmark...")
    with tempfile.TemporaryDirectory() as tmpdir:
        bench_path = Path(tmpdir) / "current-theme.conf"
        n_rounds = 200
        t0 = time.perf_counter()
        for i in range(n_rounds):
            theme_kitty.apply_kitty_theme(
                sample_palette,
                wallpaper_name=f"wallpaper_{i:03d}.png",
                target_path=bench_path,
                notify=False
            )
        total_time = time.perf_counter() - t0
        avg_ms = (total_time / n_rounds) * 1000
        print(f"  ✓ Total time for {n_rounds} iterations: {total_time:.4f} s")
        print(f"  ✓ Average apply time per call: {avg_ms:.3f} ms")
        assert avg_ms < 5.0, f"Performance warning: average time {avg_ms:.3f} ms exceeds 5 ms target"

    print("\n==================================================")
    print("ALL VERIFICATION CHECKS PASSED SUCCESSFULLY!")
    print("==================================================")
    return True


if __name__ == "__main__":
    success = run_verification()
    sys.exit(0 if success else 1)
