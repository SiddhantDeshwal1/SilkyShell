#!/usr/bin/env python3
"""
Unit tests and verification suite for Kitty live theming module (theme_kitty.py).
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

# Add scripts directory to sys.path so theme_kitty can be imported
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from theme_kitty import (
    DEFAULT_ANSI_COLORS,
    _clean_color,
    apply_kitty_theme,
    generate_kitty_theme,
    normalize_palette,
    signal_kitty,
    write_theme_file,
)


class TestThemeKitty(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="kitty_theme_test_")
        self.target_file = Path(self.test_dir) / "current-theme.conf"

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_clean_color(self):
        """Test color hex string sanitization and normalization."""
        self.assertEqual(_clean_color("#1a1b26"), "#1a1b26")
        self.assertEqual(_clean_color("1A1B26"), "#1a1b26")
        self.assertEqual(_clean_color("#FFF"), "#fff")
        self.assertEqual(_clean_color("fff"), "#fff")
        # Invalid values should return the default fallback
        self.assertEqual(_clean_color("invalid_hex", "#000000"), "#000000")
        self.assertEqual(_clean_color("", "#123456"), "#123456")
        self.assertEqual(_clean_color(None, "#abcdef"), "#abcdef")
        self.assertEqual(_clean_color(12345, "#112233"), "#112233")

    def test_normalize_palette_complete(self):
        """Test normalizer with full, explicitly specified palette."""
        raw = {
            "foreground": "#d0d7de",
            "background": "#0d1117",
            "selection_foreground": "#ffffff",
            "selection_background": "#1f6feb",
            "cursor": "#58a6ff",
            "cursor_text_color": "#0d1117",
            "active_border_color": "#58a6ff",
            "inactive_border_color": "#30363d",
            "active_tab_foreground": "#0d1117",
            "active_tab_background": "#58a6ff",
            "inactive_tab_foreground": "#8b949e",
            "inactive_tab_background": "#161b22",
            "tab_bar_background": "#0d1117",
            "url_color": "#2f81f7",
        }
        for i in range(16):
            raw[f"color{i}"] = f"#{i:02x}{i:02x}{i:02x}"

        norm = normalize_palette(raw)

        self.assertEqual(norm["foreground"], "#d0d7de")
        self.assertEqual(norm["background"], "#0d1117")
        self.assertEqual(norm["cursor"], "#58a6ff")
        self.assertEqual(norm["active_border_color"], "#58a6ff")
        for i in range(16):
            self.assertEqual(norm[f"color{i}"], f"#{i:02x}{i:02x}{i:02x}")

    def test_normalize_palette_pywal_format(self):
        """Test compatibility with Pywal style nested dictionaries."""
        pywal_data = {
            "special": {
                "background": "#1e1e2e",
                "foreground": "#cdd6f4",
                "cursor": "#f5e0dc",
            },
            "colors": {
                f"color{i}": f"#11{i:02x}22" for i in range(16)
            },
        }
        norm = normalize_palette(pywal_data)
        self.assertEqual(norm["background"], "#1e1e2e")
        self.assertEqual(norm["foreground"], "#cdd6f4")
        self.assertEqual(norm["cursor"], "#f5e0dc")
        self.assertEqual(norm["color0"], "#110022")
        self.assertEqual(norm["color15"], "#110f22")
        # Derivations
        self.assertTrue(norm["selection_background"].startswith("#"))
        self.assertTrue(norm["active_border_color"].startswith("#"))

    def test_normalize_palette_colors_list(self):
        """Test palette where colors is provided as a 16-element list."""
        colors_list = [f"#{i*15:02x}0000" for i in range(16)]
        raw = {
            "foreground": "#ffffff",
            "background": "#000000",
            "colors": colors_list,
        }
        norm = normalize_palette(raw)
        self.assertEqual(norm["color0"], "#000000")
        self.assertEqual(norm["color1"], "#0f0000")
        self.assertEqual(norm["color15"], "#e10000")

    def test_normalize_palette_theme_json_and_fallbacks(self):
        """Test quickshell theme.json keys (barBgColor, wallpaperAccentColor) and fallbacks."""
        qs_theme = {
            "barBgColor": "#101820",
            "wallpaperAccentColor": "#fee715",
        }
        norm = normalize_palette(qs_theme)
        self.assertEqual(norm["background"], "#101820")
        self.assertEqual(norm["active_border_color"], "#fee715")
        # Ensure all 16 colors fall back cleanly
        for i in range(16):
            self.assertEqual(norm[f"color{i}"], DEFAULT_ANSI_COLORS[i])

    def test_normalize_palette_aliases(self):
        """Test user-friendly aliases such as fg, bg, red, blue, etc."""
        raw = {
            "fg": "#e0e0e0",
            "bg": "#121212",
            "red": "#ff5555",
            "blue": "#5555ff",
            "selection_fg": "#000000",
            "selection_bg": "#ffff00",
            "active_border": "#00ffcc",
        }
        norm = normalize_palette(raw)
        self.assertEqual(norm["foreground"], "#e0e0e0")
        self.assertEqual(norm["background"], "#121212")
        self.assertEqual(norm["color1"], "#ff5555")
        self.assertEqual(norm["color4"], "#5555ff")
        self.assertEqual(norm["selection_foreground"], "#000000")
        self.assertEqual(norm["selection_background"], "#ffff00")
        self.assertEqual(norm["active_border_color"], "#00ffcc")

    def test_generate_kitty_theme_syntax(self):
        """Test formatting of the theme content."""
        palette = {
            "foreground": "#c0caf5",
            "background": "#1a1b26",
            "color0": "#15161e",
            "color1": "#f7768e",
        }
        content = generate_kitty_theme(palette, wallpaper_name="cyberpunk-city.png")

        # Modeline & headers
        self.assertIn("# vim:ft=kitty", content)
        self.assertIn("cyberpunk-city.png", content)

        # UI Color lines
        self.assertIn("foreground              #c0caf5", content)
        self.assertIn("background              #1a1b26", content)
        self.assertIn("cursor                  #c0caf5", content)
        self.assertIn("cursor_text_color       #1a1b26", content)
        self.assertIn("selection_foreground    #ffffff", content)
        self.assertIn("active_border_color     #7aa2f7", content)
        self.assertIn("inactive_border_color   #414868", content)
        self.assertIn("active_tab_foreground   #1a1b26", content)
        self.assertIn("active_tab_background   #7aa2f7", content)

        # ANSI Colors
        self.assertIn("color0                  #15161e", content)
        self.assertIn("color1                  #f7768e", content)
        self.assertIn("color15                 #c0caf5", content)

    def test_generate_kitty_theme_kitty_parser_validation(self):
        """Validate generated theme against Kitty's internal configuration parser."""
        palette = {
            "foreground": "#e0def4",
            "background": "#191724",
            "cursor": "#eb6f92",
            "cursor_text_color": "#191724",
            "active_border_color": "#ebbcba",
            "inactive_border_color": "#6e6a86",
            "active_tab_foreground": "#191724",
            "active_tab_background": "#ebbcba",
            "inactive_tab_foreground": "#908caa",
            "inactive_tab_background": "#26233a",
        }
        content = generate_kitty_theme(palette, wallpaper_name="rose_pine.jpg")
        test_file = Path(self.test_dir) / "rose_pine.conf"
        test_file.write_text(content, encoding="utf-8")

        # Run kitty parser check
        cmd = [
            "kitty",
            "+runpy",
            (
                "import kitty.config as kc, sys; "
                f"opts = kc.load_config('{test_file}'); "
                "sys.exit(0 if opts.foreground and opts.background else 1)"
            ),
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"Kitty parser failed on generated theme: {res.stderr}")

    def test_write_theme_file_atomic(self):
        """Test atomic file creation, temporary file swap, and persistence."""
        content = "# Test theme content\nforeground #ffffff\n"
        out_path = write_theme_file(content, self.target_file)

        # Verify output exists and matches content
        self.assertEqual(out_path, self.target_file)
        self.assertTrue(self.target_file.exists())
        self.assertEqual(self.target_file.read_text(encoding="utf-8"), content)

        # Verify temporary file is removed
        tmp_file = self.target_file.with_name(f"{self.target_file.name}.tmp")
        self.assertFalse(tmp_file.exists(), ".tmp file should not exist after atomic swap")

    def test_write_theme_file_error_handling(self):
        """Test error handling when destination is invalid."""
        with self.assertRaises(IOError):
            write_theme_file("test", "/root/forbidden_dir_test/theme.conf")

    @patch("subprocess.run")
    def test_signal_kitty_success(self, mock_run):
        """Test signal_kitty when Kitty is running (returncode 0)."""
        mock_run.return_value = MagicMock(returncode=0)
        res = signal_kitty()
        self.assertTrue(res)
        mock_run.assert_called_once_with(
            ["pkill", "-SIGUSR1", "-x", "kitty"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )

    @patch("subprocess.run")
    def test_signal_kitty_not_running(self, mock_run):
        """Test signal_kitty when no Kitty process exists (returncode 1)."""
        mock_run.return_value = MagicMock(returncode=1)
        res = signal_kitty()
        # Should gracefully return False without raising
        self.assertFalse(res)

    @patch("subprocess.run", side_effect=FileNotFoundError("pkill not found"))
    def test_signal_kitty_pkill_missing(self, mock_run):
        """Test signal_kitty when pkill is not installed."""
        res = signal_kitty()
        self.assertFalse(res)

    def test_apply_kitty_theme_integration(self):
        """Test end-to-end apply_kitty_theme function."""
        test_palette = {
            "foreground": "#a6adc8",
            "background": "#11111b",
            "cursor": "#f5e0dc",
        }
        success = apply_kitty_theme(
            test_palette,
            wallpaper_name="catppuccin.png",
            target_path=self.target_file,
            notify=False,
        )
        self.assertTrue(success)
        self.assertTrue(self.target_file.exists())

        saved_text = self.target_file.read_text(encoding="utf-8")
        self.assertIn("catppuccin.png", saved_text)
        self.assertIn("foreground              #a6adc8", saved_text)
        self.assertIn("background              #11111b", saved_text)
        self.assertIn("cursor                  #f5e0dc", saved_text)

    def test_performance_timing(self):
        """Benchmark theme generation and atomic write speed (< 10ms target)."""
        palette = {
            "foreground": "#ffffff",
            "background": "#000000",
            "colors": DEFAULT_ANSI_COLORS,
        }

        iterations = 50
        t0 = time.perf_counter()
        for i in range(iterations):
            apply_kitty_theme(
                palette,
                wallpaper_name=f"wallpaper_{i}.png",
                target_path=self.target_file,
                notify=False,
            )
        elapsed_total = time.perf_counter() - t0
        avg_ms = (elapsed_total / iterations) * 1000

        print(f"\n[Performance Benchmark] Average apply_kitty_theme execution: {avg_ms:.3f} ms (50 iterations)")
        # Must execute cleanly within reasonable timing (typically ~0.2ms - 2ms)
        self.assertLess(avg_ms, 20.0, "Execution took longer than expected threshold")


if __name__ == "__main__":
    unittest.main()
