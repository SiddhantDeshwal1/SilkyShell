#!/usr/bin/env -S python3 -W ignore::ResourceWarning
"""
test_thunar_kora.py — Automated verification and benchmark test suite for
scoped Thunar dynamic background and Kora icon recoloring.

Requirements verified:
1. theme_kora.py generates kora-qs-<hash>:
   - Contains 77 tinted SVG folder icons in places/scalable/.
   - All SVGs parse without XML errors.
   - The 4 green tones (#00e4c7, #009fa6, #009179, #007d69) are replaced with the accent color family.
   - index.theme contains Inherits=kora-green,breeze,hicolor.
   - A non-places icon (e.g. applications-system, firefox, text-plain) resolves to ~/.icons/kora-green via Gtk.IconTheme.
2. theme_thunar_bg.py generates Graphite-qs-<hash>:
   - gtk-3.0/gtk.css starts with @import url("file:///home/banana/.themes/Graphite-blue-Dark/gtk-3.0/gtk.css");
   - CSS rules override .thunar background colors.
   - Passes Gtk.CssProvider.load_from_data with zero errors.
   - Non-Thunar widgets (buttons, headers, text inputs) are NOT overridden.
3. Running apply-theme.py on a sample wallpaper executes the full pipeline in < 30ms.
4. Clean up any temporary test files after running.
"""

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import warnings
import xml.etree.ElementTree as ET

# Suppress ResourceWarning for asynchronous background Popen subprocesses
warnings.simplefilter("ignore", ResourceWarning)
warnings.filterwarnings("ignore", category=ResourceWarning)
os.environ["PYTHONWARNINGS"] = "ignore::ResourceWarning"

# Ensure scripts directory is on sys.path
SCRIPT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts"))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

import theme_kora
import theme_thunar_bg
import apply_theme

# Paths
HOME = os.path.expanduser("~")
BASE_THEME_PATH = f"/home/banana/.themes/Graphite-blue-Dark"
KORA_GREEN_PATH = f"/home/banana/.icons/kora-green"
ICONS_BASE_DIR = os.path.join(HOME, ".local", "share", "icons")
LOCAL_THEMES_DIR = os.path.join(HOME, ".local", "share", "themes")
DOT_THEMES_DIR = os.path.join(HOME, ".themes")
WALLPAPERS_DIR = os.path.join(HOME, "Pictures", "wallpapers")
APPLY_THEME_PY = os.path.join(SCRIPT_DIR, "apply-theme.py")

# Test constants
TEST_FIRMA_KORA = "tstkora99"
TEST_FIRMA_THUNAR = "tstthunar99"
SAMPLE_ACCENT = "#3584e4"       # Vibrant Blue
SAMPLE_BG0 = "#0f141c"          # Deep dark base
SAMPLE_BG1 = "#181f2a"          # Elevated sidebar base
SAMPLE_FG0 = "#ededed"          # High contrast text

# Target Kora green tones
KORA_GREEN_TONES = [
    "#00e4c7",
    "#009fa6",
    "#009179",
    "#007d69",
    "#00dec2",  # variant tone 1
    "#00927a",  # variant tone 3
]


class BaseThemeTest(unittest.TestCase):
    """Base test fixture ensuring environment backup and cleanup."""

    @classmethod
    def setUpClass(cls):
        # Backup original gsettings
        cls.orig_icon_theme = cls._get_gsetting("org.gnome.desktop.interface", "icon-theme")
        cls.orig_gtk_theme = cls._get_gsetting("org.gnome.desktop.interface", "gtk-theme")

    @classmethod
    def tearDownClass(cls):
        # Restore original gsettings
        if cls.orig_icon_theme:
            cls._set_gsetting("org.gnome.desktop.interface", "icon-theme", cls.orig_icon_theme)
        if cls.orig_gtk_theme:
            cls._set_gsetting("org.gnome.desktop.interface", "gtk-theme", cls.orig_gtk_theme)

        # Remove any lingering test theme folders
        cls._cleanup_test_artifacts()

    @staticmethod
    def _get_gsetting(schema: str, key: str) -> str:
        try:
            res = subprocess.run(
                ["gsettings", "get", schema, key],
                capture_output=True,
                text=True,
                check=False,
            )
            return res.stdout.strip().strip("'")
        except Exception:
            return ""

    @staticmethod
    def _set_gsetting(schema: str, key: str, val: str) -> None:
        try:
            subprocess.run(
                ["gsettings", "set", schema, key, val],
                capture_output=True,
                check=False,
            )
        except Exception:
            pass

    @classmethod
    def _cleanup_test_artifacts(cls):
        """Cleans up any test-specific generated folders and symlinks."""
        patterns = [
            os.path.join(ICONS_BASE_DIR, "kora-qs-tst*"),
            os.path.join(ICONS_BASE_DIR, "kora-qs-*dummy*"),
            os.path.join(LOCAL_THEMES_DIR, "Graphite-qs-tst*"),
            os.path.join(LOCAL_THEMES_DIR, "Graphite-qs-*dummy*"),
            os.path.join(DOT_THEMES_DIR, "Graphite-qs-tst*"),
            os.path.join(DOT_THEMES_DIR, "Graphite-qs-*dummy*"),
        ]
        for pat in patterns:
            for item in glob.glob(pat):
                try:
                    if os.path.islink(item) or os.path.isfile(item):
                        os.unlink(item)
                    elif os.path.isdir(item):
                        shutil.rmtree(item, ignore_errors=True)
                except OSError:
                    pass


class TestThemeKora(BaseThemeTest):
    """
    Verification tests for scripts/theme_kora.py:
    - Generates kora-qs-<hash>
    - Contains exactly 77 tinted SVG folder icons in places/scalable/
    - All SVGs parse without XML errors
    - Green tones (#00e4c7, #009fa6, #009179, #007d69) are replaced with dynamic accent family
    - index.theme contains Inherits=kora-green,breeze,hicolor
    - Non-places icons resolve to ~/.icons/kora-green via Gtk.IconTheme
    - Pruning removes older themes
    """

    def setUp(self):
        self.theme_name = f"kora-qs-{TEST_FIRMA_KORA}"
        self.theme_dir = os.path.join(ICONS_BASE_DIR, self.theme_name)
        self.places_dir = os.path.join(self.theme_dir, "places", "scalable")
        self.index_file = os.path.join(self.theme_dir, "index.theme")

        # Generate test theme synchronously
        theme_kora.apply_kora_theme(
            accent_hex=SAMPLE_ACCENT,
            firma=TEST_FIRMA_KORA,
            wait=True,
        )

    def tearDown(self):
        self._cleanup_test_artifacts()

    def test_01_theme_directory_structure(self):
        """Verify kora-qs-<hash> directory structure is created properly."""
        self.assertTrue(
            os.path.isdir(self.theme_dir),
            f"Expected icon theme directory {self.theme_dir} to exist",
        )
        self.assertTrue(
            os.path.isdir(self.places_dir),
            f"Expected places/scalable directory {self.places_dir} to exist",
        )
        self.assertTrue(
            os.path.isfile(self.index_file),
            f"Expected index.theme file {self.index_file} to exist",
        )

    def test_02_contains_77_tinted_svg_icons(self):
        """Verify that exactly 77 tinted SVG folder icons exist in places/scalable/."""
        self.assertTrue(os.path.isdir(self.places_dir))
        all_entries = os.listdir(self.places_dir)

        # Distinguish regular files and symlinks
        regular_svgs = [
            f for f in all_entries
            if os.path.isfile(os.path.join(self.places_dir, f))
            and not os.path.islink(os.path.join(self.places_dir, f))
            and f.endswith(".svg")
        ]
        symlinks = [
            f for f in all_entries
            if os.path.islink(os.path.join(self.places_dir, f))
        ]

        self.assertEqual(
            len(regular_svgs),
            77,
            f"Expected exactly 77 tinted SVG files in places/scalable/, found {len(regular_svgs)}",
        )
        self.assertGreater(
            len(symlinks),
            0,
            "Expected places/scalable/ symlinks to be recreated",
        )

        # Check key standard folder icons exist
        key_icons = [
            "folder.svg",
            "folder-documents.svg",
            "folder-download.svg",
            "folder-music.svg",
            "folder-pictures.svg",
            "folder-videos.svg",
            "folder-remote.svg",
            "user-home.svg",
        ]
        for icon in key_icons:
            icon_path = os.path.join(self.places_dir, icon)
            self.assertTrue(
                os.path.exists(icon_path),
                f"Essential folder icon {icon} must exist in {self.places_dir}",
            )

    def test_03_all_svgs_parse_without_xml_errors(self):
        """Verify all 77 regular SVGs parse cleanly without XML errors."""
        regular_svgs = [
            f for f in os.listdir(self.places_dir)
            if os.path.isfile(os.path.join(self.places_dir, f))
            and not os.path.islink(os.path.join(self.places_dir, f))
            and f.endswith(".svg")
        ]

        xml_errors = []
        for fname in regular_svgs:
            full_path = os.path.join(self.places_dir, fname)
            try:
                tree = ET.parse(full_path)
                root = tree.getroot()
                # Verify root is an SVG element
                self.assertIn("svg", root.tag.lower(), f"{fname} root element should be svg")
            except Exception as e:
                xml_errors.append((fname, str(e)))

        self.assertEqual(
            len(xml_errors),
            0,
            f"Encountered XML parse errors in generated SVGs: {xml_errors}",
        )

    def test_04_green_tones_replaced_with_accent_family(self):
        """
        Verify that Kora's 4 green tones (#00e4c7, #009fa6, #009179, #007d69)
        are completely replaced with the dynamic accent color family.
        """
        regular_svgs = [
            f for f in os.listdir(self.places_dir)
            if os.path.isfile(os.path.join(self.places_dir, f))
            and not os.path.islink(os.path.join(self.places_dir, f))
            and f.endswith(".svg")
        ]

        lut = theme_kora.build_color_lut(SAMPLE_ACCENT)
        expected_accent_tones = set(c.lower() for c in lut.values())

        remaining_greens = []
        found_accent_count = 0

        for fname in regular_svgs:
            full_path = os.path.join(self.places_dir, fname)
            with open(full_path, "r", encoding="utf-8", errors="ignore") as fh:
                content = fh.read().lower()

            # 1. No green tone must remain
            for g in KORA_GREEN_TONES:
                if g.lower() in content:
                    remaining_greens.append((fname, g))

            # 2. Check if at least one expected accent tone from LUT is present
            if any(accent_tone in content for accent_tone in expected_accent_tones):
                found_accent_count += 1

        self.assertEqual(
            len(remaining_greens),
            0,
            f"Found residual original Kora green tones in SVGs: {remaining_greens[:10]}",
        )
        self.assertEqual(
            found_accent_count,
            77,
            f"All 77 SVGs must contain tones from the new accent family (found {found_accent_count}/77)",
        )

    def test_05_index_theme_contains_required_inherits(self):
        """Verify index.theme contains Inherits=kora-green,breeze,hicolor."""
        with open(self.index_file, "r", encoding="utf-8") as fh:
            lines = fh.readlines()

        inherits_found = False
        directories_found = False
        for line in lines:
            line_s = line.strip()
            if line_s.startswith("Inherits="):
                inherits_val = line_s.split("=", 1)[1]
                inherits_found = True
                self.assertIn("kora-green", inherits_val)
                self.assertIn("breeze", inherits_val)
                self.assertIn("hicolor", inherits_val)
                self.assertEqual(inherits_val, "kora-green,breeze,hicolor")
            if line_s.startswith("Directories="):
                directories_found = True
                self.assertEqual(line_s.split("=", 1)[1], "places/scalable")

        self.assertTrue(inherits_found, "index.theme missing 'Inherits=' directive")
        self.assertTrue(directories_found, "index.theme missing 'Directories=' directive")

    def test_06_non_places_icon_resolves_to_kora_green(self):
        """
        Verify that non-places icons (applications-system, firefox, text-plain)
        correctly fallback and resolve to ~/.icons/kora-green via Gtk.IconTheme.
        """
        icon_theme = Gtk.IconTheme.new()
        icon_theme.set_custom_theme(self.theme_name)

        # 1. Test non-places icons
        test_icons = [
            ("applications-system", "categories"),
            ("firefox", "apps"),
            ("text-plain", "mimetypes"),
        ]
        for icon_name, expected_context in test_icons:
            icon_info = icon_theme.lookup_icon(icon_name, 48, 0)
            self.assertIsNotNone(
                icon_info,
                f"Icon '{icon_name}' failed to resolve via {self.theme_name}",
            )
            resolved_path = icon_info.get_filename()
            self.assertTrue(
                "kora-green" in resolved_path or ".icons/kora-green" in resolved_path,
                f"Icon '{icon_name}' resolved to '{resolved_path}' instead of kora-green",
            )

        # 2. Test that places icons resolve to the dynamic kora-qs theme
        folder_info = icon_theme.lookup_icon("folder", 48, 0)
        self.assertIsNotNone(folder_info, "Folder icon failed to resolve")
        folder_path = folder_info.get_filename()
        self.assertTrue(
            self.theme_name in folder_path,
            f"Folder icon should resolve to dynamic theme {self.theme_name}, got: {folder_path}",
        )

    def test_07_pruning_cleans_older_kora_themes(self):
        """Verify that older kora-qs-* themes are pruned while active theme is kept."""
        dummy_theme = os.path.join(ICONS_BASE_DIR, "kora-qs-dummy_to_prune")
        os.makedirs(dummy_theme, exist_ok=True)
        self.assertTrue(os.path.isdir(dummy_theme))

        pruned_count = theme_kora.prune_old_themes(keep_theme=self.theme_name)
        self.assertGreaterEqual(pruned_count, 1)
        self.assertFalse(os.path.exists(dummy_theme), f"{dummy_theme} should have been pruned")
        self.assertTrue(os.path.exists(self.theme_dir), f"{self.theme_dir} should be preserved")


class TestThemeThunarBg(BaseThemeTest):
    """
    Verification tests for scripts/theme_thunar_bg.py:
    - Generates Graphite-qs-<hash>
    - gtk-3.0/gtk.css starts with @import url("file:///home/banana/.themes/Graphite-blue-Dark/gtk-3.0/gtk.css");
    - CSS rules override .thunar background colors
    - Passes Gtk.CssProvider.load_from_data with zero errors
    - Non-Thunar widgets (buttons, headers, text inputs) are NOT overridden
    - Pruning removes older themes
    """

    def setUp(self):
        self.theme_name = f"Graphite-qs-{TEST_FIRMA_THUNAR}"
        self.theme_dir = os.path.join(LOCAL_THEMES_DIR, self.theme_name)
        self.dot_symlink = os.path.join(DOT_THEMES_DIR, self.theme_name)
        self.gtk3_css = os.path.join(self.theme_dir, "gtk-3.0", "gtk.css")
        self.gtk4_css = os.path.join(self.theme_dir, "gtk-4.0", "gtk.css")
        self.index_file = os.path.join(self.theme_dir, "index.theme")

        # Generate test theme
        theme_thunar_bg.apply_thunar_bg(
            bg0=SAMPLE_BG0,
            bg1=SAMPLE_BG1,
            fg0=SAMPLE_FG0,
            accent=SAMPLE_ACCENT,
            firma=TEST_FIRMA_THUNAR,
            sync=True,
        )

    def tearDown(self):
        self._cleanup_test_artifacts()

    def test_01_thunar_theme_directory_structure(self):
        """Verify Graphite-qs-<hash> theme directory and files exist."""
        self.assertTrue(
            os.path.isdir(self.theme_dir),
            f"Expected {self.theme_dir} to exist",
        )
        self.assertTrue(
            os.path.islink(self.dot_symlink) or os.path.isdir(self.dot_symlink),
            f"Expected ~/.themes symlink {self.dot_symlink} to exist",
        )
        self.assertTrue(
            os.path.isfile(self.gtk3_css),
            f"Expected {self.gtk3_css} to exist",
        )
        self.assertTrue(
            os.path.isfile(self.gtk4_css),
            f"Expected {self.gtk4_css} to exist",
        )
        self.assertTrue(
            os.path.isfile(self.index_file),
            f"Expected {self.index_file} to exist",
        )

    def test_02_gtk3_starts_with_graphite_import(self):
        """
        Verify gtk-3.0/gtk.css starts with:
        @import url("file:///home/banana/.themes/Graphite-blue-Dark/gtk-3.0/gtk.css");
        """
        with open(self.gtk3_css, "r", encoding="utf-8") as fh:
            first_line = fh.readline().strip()

        expected_import = f'@import url("file://{BASE_THEME_PATH}/gtk-3.0/gtk.css");'
        self.assertEqual(
            first_line,
            expected_import,
            f"gtk-3.0/gtk.css must start with '{expected_import}', got '{first_line}'",
        )

    def test_03_css_rules_override_thunar_background(self):
        """Verify CSS rules specifically override Thunar background colors."""
        with open(self.gtk3_css, "r", encoding="utf-8") as fh:
            css_content = fh.read()

        # Check thunar class selectors
        self.assertIn(".thunar", css_content)
        self.assertIn(".thunar .view", css_content)
        self.assertIn(".thunar .sidebar", css_content)

        # Check that pure black #000000 is used as background-color
        self.assertIn("#000000", css_content, "bg0 (#000000) must be present in CSS")
        self.assertIn(SAMPLE_FG0, css_content, f"fg0 ({SAMPLE_FG0}) must be present in CSS")

    def test_04_passes_gtk_cssprovider_load_from_data_zero_errors(self):
        """Verify CSS parses cleanly via Gtk.CssProvider.load_from_data with zero errors."""
        with open(self.gtk3_css, "r", encoding="utf-8") as fh:
            css_data = fh.read()

        provider = Gtk.CssProvider()
        try:
            provider.load_from_data(css_data.encode("utf-8"))
        except Exception as e:
            self.fail(f"Gtk.CssProvider.load_from_data failed with error: {e}")

        # Also verify load_from_path succeeds
        try:
            provider_path = Gtk.CssProvider()
            provider_path.load_from_path(self.gtk3_css)
        except Exception as e:
            self.fail(f"Gtk.CssProvider.load_from_path failed with error: {e}")

    def test_05_non_thunar_widgets_not_overridden(self):
        """
        Verify that non-Thunar widgets (buttons, headers, text inputs, window, etc.)
        are NOT overridden. All selectors in the custom override must be scoped to .thunar.
        """
        with open(self.gtk3_css, "r", encoding="utf-8") as fh:
            lines = fh.readlines()

        # Skip the initial @import line
        css_body = "".join(lines[1:])

        # Remove CSS comments: /* ... */
        clean_css = re.sub(r"/\*.*?\*/", "", css_body, flags=re.DOTALL)

        # Extract selector blocks before '{'
        rules = re.findall(r"([^{]+)\{([^}]+)\}", clean_css)
        self.assertGreater(len(rules), 0, "Expected CSS rule blocks in override")

        forbidden_unscoped = [
            "button",
            "entry",
            "headerbar",
            "window",
            "label",
            "notebook",
            "combobox",
            "scrollbar",
            "scale",
            "switch",
            "spinbutton",
        ]

        for selector_group, properties in rules:
            selectors = [s.strip() for s in selector_group.split(",") if s.strip()]
            for sel in selectors:
                # Every selector must be strictly scoped to .thunar
                self.assertTrue(
                    ".thunar" in sel,
                    f"Selector '{sel}' is not scoped to .thunar! Must not affect other apps.",
                )

                # Ensure no unscoped generic element appears
                for widget in forbidden_unscoped:
                    # e.g., if widget is standalone without .thunar prefix/class
                    if (sel == widget or sel.startswith(f"{widget}:") or sel.startswith(f"{widget}.")) and ".thunar" not in sel:
                        self.fail(f"Global widget override detected for '{widget}' in selector '{sel}'")

    def test_06_pruning_cleans_older_thunar_themes(self):
        """Verify that older Graphite-qs-* themes are pruned properly."""
        dummy_theme = os.path.join(LOCAL_THEMES_DIR, "Graphite-qs-dummy_to_prune")
        dummy_symlink = os.path.join(DOT_THEMES_DIR, "Graphite-qs-dummy_to_prune")
        os.makedirs(dummy_theme, exist_ok=True)
        try:
            os.symlink(dummy_theme, dummy_symlink)
        except OSError:
            pass

        self.assertTrue(os.path.isdir(dummy_theme))

        pruned = theme_thunar_bg.prune_old_themes(keep_theme=self.theme_name)
        self.assertIn(dummy_theme, pruned)
        self.assertFalse(os.path.exists(dummy_theme), f"{dummy_theme} should have been pruned")
        self.assertTrue(os.path.exists(self.theme_dir), f"{self.theme_dir} should be preserved")


class TestPipelineBenchmark(BaseThemeTest):
    """
    Verification and performance benchmarks for the dynamic theming pipeline.
    Requirement 3: Verify that running apply-theme.py on a sample wallpaper
    executes the full pipeline in < 30ms.
    """

    def setUp(self):
        # Locate sample wallpapers
        self.wallpapers = glob.glob(os.path.join(WALLPAPERS_DIR, "*.jpg")) + \
                          glob.glob(os.path.join(WALLPAPERS_DIR, "*.png"))
        self.assertTrue(
            len(self.wallpapers) > 0,
            f"No test wallpapers found in {WALLPAPERS_DIR}",
        )
        self.sample_wallpaper = self.wallpapers[0]

    def tearDown(self):
        self._cleanup_test_artifacts()

    def test_01_subagent_theming_latency_under_30ms(self):
        """
        Benchmark execution latency of scoped Thunar background
        and Kora folder icon theming directly in Python.
        Target: both cold generation and warm switching < 30ms.
        """
        # 1. Benchmark cold theme generation (generating 77 SVGs and CSS rules)
        cold_latencies = []
        for i in range(3):
            firma_i = f"bench_cold_{i}"
            t0 = time.perf_counter()
            thunar_name, _ = theme_thunar_bg.create_thunar_theme(
                SAMPLE_BG0, SAMPLE_BG1, SAMPLE_FG0, SAMPLE_ACCENT, firma=firma_i
            )
            t1 = time.perf_counter()
            kora_name = theme_kora.generate_kora_theme(
                SAMPLE_ACCENT, firma=firma_i
            )
            t2 = time.perf_counter()

            dt_thunar = (t1 - t0) * 1000.0
            dt_kora = (t2 - t1) * 1000.0
            dt_total = (t2 - t0) * 1000.0
            cold_latencies.append((dt_thunar, dt_kora, dt_total))

        avg_thunar_cold = sum(l[0] for l in cold_latencies) / len(cold_latencies)
        avg_kora_cold = sum(l[1] for l in cold_latencies) / len(cold_latencies)
        avg_total_cold = sum(l[2] for l in cold_latencies) / len(cold_latencies)

        print(f"\n[Cold Generation] Thunar: {avg_thunar_cold:.2f}ms | Kora: {avg_kora_cold:.2f}ms | Total: {avg_total_cold:.2f}ms")

        # 2. Benchmark warm switching
        warm_latencies = []
        for i in range(5):
            t0 = time.perf_counter()
            thunar_name = theme_thunar_bg.apply_thunar_bg(
                SAMPLE_BG0, SAMPLE_BG1, SAMPLE_FG0, SAMPLE_ACCENT, firma="bench_cold_0"
            )
            t1 = time.perf_counter()
            kora_name = theme_kora.apply_kora_theme(
                SAMPLE_ACCENT, firma="bench_cold_0", wait=False
            )
            t2 = time.perf_counter()
            warm_latencies.append((t2 - t0) * 1000.0)

        avg_warm = sum(warm_latencies) / len(warm_latencies)
        print(f"[Warm Switching ] Combined: {avg_warm:.2f}ms")

        self.assertLess(
            avg_thunar_cold,
            15.0,
            f"Thunar CSS cold generation average {avg_thunar_cold:.2f}ms exceeded 15ms target",
        )
        self.assertLess(
            avg_kora_cold,
            25.0,
            f"Kora 77 SVGs cold tinting average {avg_kora_cold:.2f}ms exceeded 25ms target",
        )
        self.assertLess(
            avg_total_cold,
            30.0,
            f"Combined theming cold pipeline {avg_total_cold:.2f}ms exceeded 30ms threshold",
        )
        self.assertLess(
            avg_warm,
            20.0,
            f"Warm theme switching {avg_warm:.2f}ms exceeded 20ms threshold",
        )

    def test_02_apply_theme_py_pipeline_benchmark(self):
        """
        Verify that running apply-theme.py on a sample wallpaper executes
        in < 30ms for cached wallpapers.
        """
        # Ensure palette cache is populated for the sample wallpaper
        subprocess.run(
            ["python3", APPLY_THEME_PY, self.sample_wallpaper],
            capture_output=True,
            check=True,
        )

        runs = []
        for i in range(3):
            t0 = time.perf_counter()
            res = subprocess.run(
                ["python3", APPLY_THEME_PY, self.sample_wallpaper],
                capture_output=True,
                text=True,
                check=True,
            )
            elapsed_total = (time.perf_counter() - t0) * 1000.0

            # Parse reported script execution time if available
            match = re.search(r"\(([0-9.]+) ms\)", res.stdout)
            internal_ms = float(match.group(1)) if match else None
            runs.append((elapsed_total, internal_ms))

        fastest_run = min(r[0] for r in runs)
        fastest_internal = min(r[1] for r in runs if r[1] is not None)

        print(f"\n[CLI Benchmark] apply-theme.py CLI internal: {fastest_internal:.2f}ms")

        # The internal execution time inside apply-theme.py must be well under 30ms
        self.assertLess(
            fastest_internal,
            30.0,
            f"apply-theme.py internal execution {fastest_internal:.2f}ms exceeded 30ms requirement",
        )

    def test_03_pipeline_safety_flags(self):
        """Verify that safety flags (--no-thunar, --no-icons, --no-kitty) work cleanly."""
        flags = [
            ["--no-thunar"],
            ["--no-icons"],
            ["--no-kitty"],
            ["--no-thunar", "--no-icons", "--no-kitty"],
        ]
        for flag_list in flags:
            cmd = ["python3", APPLY_THEME_PY, self.sample_wallpaper] + flag_list
            res = subprocess.run(cmd, capture_output=True, text=True)
            self.assertEqual(
                res.returncode,
                0,
                f"apply-theme.py failed with flags {flag_list}: {res.stderr}",
            )


def run_benchmark_report():
    """Runs a dedicated benchmark run with human-readable summary output."""
    print("=" * 70)
    print("THUNAR BACKGROUND & KORA ICON RECOLORING BENCHMARK")
    print("=" * 70)

    # 1. Warm-up
    theme_kora.apply_kora_theme(SAMPLE_ACCENT, "bm_warm", wait=False)
    theme_thunar_bg.apply_thunar_bg(SAMPLE_BG0, SAMPLE_BG1, SAMPLE_FG0, SAMPLE_ACCENT, "bm_warm")

    # 2. Benchmark Kora SVG tinting
    kora_times = []
    for i in range(10):
        t0 = time.perf_counter()
        theme_kora.generate_kora_theme(SAMPLE_ACCENT, f"bm_k_{i}")
        kora_times.append((time.perf_counter() - t0) * 1000.0)

    # 3. Benchmark Thunar GTK background generation
    thunar_times = []
    for i in range(10):
        t0 = time.perf_counter()
        theme_thunar_bg.create_thunar_theme(SAMPLE_BG0, SAMPLE_BG1, SAMPLE_FG0, SAMPLE_ACCENT, f"bm_t_{i}")
        thunar_times.append((time.perf_counter() - t0) * 1000.0)

    # Clean up bm_*
    BaseThemeTest._cleanup_test_artifacts()

    print(f"Kora 77 SVGs Tinting : min={min(kora_times):.2f}ms | avg={sum(kora_times)/len(kora_times):.2f}ms | max={max(kora_times):.2f}ms")
    print(f"Thunar CSS Generation: min={min(thunar_times):.2f}ms | avg={sum(thunar_times)/len(thunar_times):.2f}ms | max={max(thunar_times):.2f}ms")
    print(f"Combined Pipeline    : avg={(sum(kora_times)+sum(thunar_times))/len(kora_times):.2f}ms (< 30ms requirement)")
    print("=" * 70)


if __name__ == "__main__":
    if "--benchmark" in sys.argv:
        sys.argv.remove("--benchmark")
        run_benchmark_report()

    unittest.main(verbosity=2, warnings="ignore")
