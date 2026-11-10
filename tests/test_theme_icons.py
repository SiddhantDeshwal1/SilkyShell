#!/usr/bin/env python3
"""
test_theme_icons.py — Comprehensive test suite for scripts/theme_icons.py.
Tests icon source discovery, color tinting / shading preservation,
theme directory generation, pruning, gsettings application, resilience,
and latency benchmarking.
"""

import colorsys
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

# Ensure scripts directory is on sys.path
SCRIPT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts"))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import theme_icons


class TestThemeIcons(unittest.TestCase):
    def setUp(self):
        self.test_tmp_dir = tempfile.mkdtemp(prefix="test_qs_icons_")
        # Save original gsettings icon-theme to restore later
        self.orig_icon_theme = theme_icons.get_current_icon_theme()

    def tearDown(self):
        if os.path.isdir(self.test_tmp_dir):
            shutil.rmtree(self.test_tmp_dir, ignore_errors=True)
        # Restore original icon-theme if needed
        if self.orig_icon_theme:
            theme_icons.set_gsettings_icon_theme(self.orig_icon_theme)

    def test_find_icon_source(self):
        """Verify icon source detection finds Adwaita scalable places."""
        source_dir, base_theme = theme_icons.find_icon_source()
        self.assertIsNotNone(source_dir, "Icon source directory should be found")
        self.assertTrue(os.path.isdir(source_dir), f"{source_dir} must exist")
        self.assertEqual(base_theme, "Adwaita")
        # Check folder.svg exists in source
        self.assertTrue(os.path.isfile(os.path.join(source_dir, "folder.svg")))

    def test_parse_hex_color(self):
        """Test parsing hex color formats."""
        self.assertEqual(theme_icons.parse_hex_color("#ff0000"), (1.0, 0.0, 0.0))
        self.assertEqual(theme_icons.parse_hex_color("00ff00"), (0.0, 1.0, 0.0))
        self.assertEqual(theme_icons.parse_hex_color("#00f"), (0.0, 0.0, 1.0))
        self.assertIsNone(theme_icons.parse_hex_color(""))
        self.assertIsNone(theme_icons.parse_hex_color("invalid"))
        self.assertIsNone(theme_icons.parse_hex_color("#12345"))

    def test_color_shading_and_lightness_preservation(self):
        """
        Verify that original Adwaita blues have their lightness preserved intact,
        ensuring 3D depth, shading, and bevels are not lost.
        """
        accent = "#50e0e1"  # Cyan accent
        lut = theme_icons.build_color_lut(accent)
        self.assertTrue(len(lut) >= 5, "LUT should contain at least 5 standard blues")

        # Test each standard blue tone
        for b_hex in theme_icons.ADWAITA_BLUES:
            orig_rgb = theme_icons.parse_hex_color(b_hex)
            _, orig_l, orig_s = colorsys.rgb_to_hls(*orig_rgb)

            tinted_hex = lut.get("#" + b_hex)
            self.assertIsNotNone(tinted_hex, f"#{b_hex} must be mapped in LUT")

            tinted_rgb = theme_icons.parse_hex_color(tinted_hex)
            _, tinted_l, _ = colorsys.rgb_to_hls(*tinted_rgb)

            # Lightness should be preserved within rounding tolerance (< 0.015)
            self.assertAlmostEqual(
                orig_l, tinted_l, delta=0.015,
                msg=f"Lightness for #{b_hex} altered from {orig_l:.3f} to {tinted_l:.3f}"
            )

    def test_tint_svg_content_preserves_non_blues(self):
        """Verify that non-blue colors (e.g. grays in folder-remote.svg) are untouched."""
        test_svg = (
            '<svg><path fill="#438de6"/><path fill="#62a0ea"/>'
            '<path fill="#313133"/><path fill="#77767b"/></svg>'
        )
        accent = "#ff5555"
        lut = theme_icons.build_color_lut(accent)
        tinted_svg = theme_icons.tint_svg_content(test_svg, lut, accent)

        # Blues must be replaced
        self.assertNotIn("#438de6", tinted_svg)
        self.assertNotIn("#62a0ea", tinted_svg)
        # Grays must remain untouched
        self.assertIn("#313133", tinted_svg)
        self.assertIn("#77767b", tinted_svg)

    def test_grayscale_accent_handling(self):
        """Verify that a grayscale accent (#808080) produces pure grayscale shading without hue cast."""
        gray_accent = "#808080"
        lut = theme_icons.build_color_lut(gray_accent)
        for b_hex in theme_icons.ADWAITA_BLUES:
            tinted_hex = lut["#" + b_hex]
            r, g, b = theme_icons.parse_hex_color(tinted_hex)
            # For pure grayscale, r == g == b
            self.assertEqual(r, g)
            self.assertEqual(g, b)

    def test_generate_icon_theme(self):
        """Verify full theme directory generation in isolated path."""
        firma = "unittest1"
        theme_name = theme_icons.generate_icon_theme(
            "#42a6f7", firma=firma, icons_base=self.test_tmp_dir
        )
        self.assertEqual(theme_name, f"qs-folders-{firma}")

        theme_dir = os.path.join(self.test_tmp_dir, theme_name)
        self.assertTrue(os.path.isdir(theme_dir))

        # Check index.theme
        index_file = os.path.join(theme_dir, "index.theme")
        self.assertTrue(os.path.isfile(index_file))
        with open(index_file, "r", encoding="utf-8") as fh:
            content = fh.read()
        self.assertIn(f"Name={theme_name}", content)
        self.assertIn("Inherits=Adwaita", content)
        self.assertIn("Directories=scalable/places", content)

        # Check scalable/places folder SVGs
        places_dir = os.path.join(theme_dir, "scalable", "places")
        self.assertTrue(os.path.isdir(places_dir))
        expected_icons = [
            "folder.svg", "folder-documents.svg", "folder-download.svg",
            "folder-music.svg", "folder-pictures.svg", "folder-videos.svg",
            "user-home.svg", "user-desktop.svg", "user-bookmarks.svg"
        ]
        for icon in expected_icons:
            icon_path = os.path.join(places_dir, icon)
            self.assertTrue(os.path.isfile(icon_path), f"Missing {icon}")
            self.assertGreater(os.path.getsize(icon_path), 500)

    def test_prune_old_themes(self):
        """Verify old qs-folders-* directories are pruned while active one is preserved."""
        # Create mock old themes
        for name in ("qs-folders-old1", "qs-folders-old2", "qs-folders-active", "other-theme"):
            os.makedirs(os.path.join(self.test_tmp_dir, name), exist_ok=True)

        pruned = theme_icons.prune_old_themes(
            keep_theme="qs-folders-active", icons_base=self.test_tmp_dir
        )
        self.assertEqual(pruned, 2)
        remaining = os.listdir(self.test_tmp_dir)
        self.assertIn("qs-folders-active", remaining)
        self.assertIn("other-theme", remaining)
        self.assertNotIn("qs-folders-old1", remaining)
        self.assertNotIn("qs-folders-old2", remaining)

    def test_apply_icon_theme_end_to_end(self):
        """Test end-to-end apply_icon_theme function."""
        firma = "e2etest"
        accent = "#50e0e1"
        res = theme_icons.apply_icon_theme(accent, firma)
        self.assertEqual(res, f"qs-folders-{firma}")

        # Check if gsettings picked it up
        current = theme_icons.get_current_icon_theme()
        self.assertEqual(current, f"qs-folders-{firma}")

        # Check theme files in ~/.local/share/icons
        theme_dir = os.path.expanduser(f"~/.local/share/icons/qs-folders-{firma}")
        self.assertTrue(os.path.isdir(theme_dir))
        self.assertTrue(os.path.isfile(os.path.join(theme_dir, "index.theme")))
        self.assertTrue(os.path.isfile(os.path.join(theme_dir, "scalable", "places", "folder.svg")))

        # Clean up this e2e theme
        shutil.rmtree(theme_dir, ignore_errors=True)

    def test_resilience_missing_files_and_invalid_inputs(self):
        """Verify resilience against invalid hex, None, and empty inputs."""
        self.assertIsNone(theme_icons.apply_icon_theme(""))
        self.assertIsNone(theme_icons.apply_icon_theme("not_a_color"))
        self.assertIsNone(theme_icons.generate_icon_theme(None))

    def test_performance_benchmark(self):
        """Verify execution time is consistently < 30ms."""
        times = []
        for i in range(10):
            firma = f"bench{i}"
            t0 = time.perf_counter()
            name = theme_icons.apply_icon_theme("#42a6f7", firma=firma)
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            times.append(elapsed_ms)
            self.assertIsNotNone(name)

        # Cleanup bench themes
        theme_icons.prune_old_themes(keep_theme="none")

        avg_ms = sum(times) / len(times)
        min_ms = min(times)
        max_ms = max(times)
        print(f"\n[BENCHMARK] apply_icon_theme across 10 runs:")
        print(f"  Avg: {avg_ms:.2f}ms | Min: {min_ms:.2f}ms | Max: {max_ms:.2f}ms")
        self.assertLess(avg_ms, 30.0, f"Average latency {avg_ms:.2f}ms exceeds 30ms threshold")


if __name__ == "__main__":
    unittest.main()
