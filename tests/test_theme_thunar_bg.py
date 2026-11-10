#!/usr/bin/env python3
"""
test_theme_thunar_bg.py — Test suite for scripts/theme_thunar_bg.py.
Validates scoped Thunar background & selection theming, file hierarchy,
CSS parser validity (Gtk 3 & 4), settings.ini updates, pruning, and <10ms benchmark.
"""

import os
import shutil
import sys
import tempfile
import time
import unittest

# Ensure scripts directory is on sys.path
SCRIPT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts"))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import theme_thunar_bg


class TestThemeThunarBg(unittest.TestCase):
    def setUp(self):
        self.orig_theme = theme_thunar_bg.get_current_gtk_theme() or "Graphite-blue-Dark"
        self.test_tmp_dir = tempfile.mkdtemp(prefix="test_thunar_bg_")

    def tearDown(self):
        if os.path.isdir(self.test_tmp_dir):
            shutil.rmtree(self.test_tmp_dir, ignore_errors=True)
        # Restore original GTK theme
        if self.orig_theme:
            theme_thunar_bg.apply_thunar_bg(
                bg0="#181512",
                bg1="#221e19",
                fg0="#ededed",
                accent="#dba157",
                firma="restore",
                sync=False,
            )
            # Revert to original user theme if it was Graphite-blue-Dark
            theme_thunar_bg.prune_old_themes(keep_theme="none")
            theme_thunar_bg.update_gtk_settings(self.orig_theme)
            gsettings_bin = shutil.which("gsettings")
            if gsettings_bin:
                import subprocess
                subprocess.run(
                    [gsettings_bin, "set", "org.gnome.desktop.interface", "gtk-theme", self.orig_theme],
                    check=False,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )

    def test_normalize_hex(self):
        """Verify hex color parsing and alpha stripping."""
        self.assertEqual(theme_thunar_bg.normalize_hex("#1a1b26"), "#1a1b26")
        self.assertEqual(theme_thunar_bg.normalize_hex("1a1b26"), "#1a1b26")
        self.assertEqual(theme_thunar_bg.normalize_hex("#1a1b26ff"), "#1a1b26")
        self.assertEqual(theme_thunar_bg.normalize_hex(""), "#000000")

    def test_find_base_theme(self):
        """Verify base theme resolution finds Graphite-blue-Dark."""
        base_path = theme_thunar_bg.find_base_theme()
        self.assertTrue(os.path.isdir(base_path), f"Base theme path {base_path} must exist")
        self.assertTrue(os.path.isfile(os.path.join(base_path, "index.theme")))
        self.assertTrue(os.path.isfile(os.path.join(base_path, "gtk-3.0", "gtk.css")))
        self.assertTrue(os.path.isfile(os.path.join(base_path, "gtk-4.0", "gtk.css")))

    def test_sanitize_firma(self):
        """Verify signature generation and deterministic hashing."""
        f1 = theme_thunar_bg.sanitize_firma("my-test_01", "#111", "#222", "#333", "#444")
        self.assertEqual(f1, "my-test_01")

        # Prefix stripping
        f2 = theme_thunar_bg.sanitize_firma("Graphite-qs-abc123", "#111", "#222", "#333", "#444")
        self.assertEqual(f2, "abc123")

        # Fallback to MD5
        f3 = theme_thunar_bg.sanitize_firma(None, "#111", "#222", "#333", "#444")
        self.assertEqual(len(f3), 8)

        # Deterministic
        f4 = theme_thunar_bg.sanitize_firma("", "#111", "#222", "#333", "#444")
        self.assertEqual(f3, f4)

    def test_generate_index_theme(self):
        """Verify index.theme content."""
        content = theme_thunar_bg.generate_index_theme("Graphite-qs-12345678")
        self.assertIn("[Desktop Entry]", content)
        self.assertIn("Type=X-GNOME-Metatheme", content)
        self.assertIn("Name=Graphite-qs-12345678", content)
        self.assertIn("Comment=Graphite-blue-Dark with dynamic wallpaper background for Thunar", content)
        self.assertIn("[X-GNOME-Metatheme]", content)
        self.assertIn("GtkTheme=Graphite-qs-12345678", content)
        self.assertIn("MetacityTheme=Graphite-blue-Dark", content)

    def test_generate_gtk3_css_and_parser_validation(self):
        """Verify gtk-3.0/gtk.css contains all required scoped rules and parses without error."""
        css = theme_thunar_bg.generate_gtk3_css(
            bg0="#111213",
            bg1="#212223",
            fg0="#ffffff",
            accent="#3388ee",
            base_theme_path="/home/banana/.themes/Graphite-blue-Dark",
        )

        # Base import
        self.assertIn('@import url("file:///home/banana/.themes/Graphite-blue-Dark/gtk-3.0/gtk.css");', css)

        # Scoped background
        self.assertIn(".thunar,", css)
        self.assertIn(".thunar window,", css)
        self.assertIn(".thunar .view,", css)
        self.assertIn(".thunar iconview,", css)
        self.assertIn(".thunar treeview.view,", css)
        self.assertIn(".thunar .standard-view,", css)
        self.assertIn(".thunar .standard-view.frame", css)
        self.assertIn("background-color: #000000;", css)
        self.assertIn("color: #ffffff;", css)

        # Scoped sidebar
        self.assertIn(".thunar .sidebar,", css)
        self.assertIn(".thunar .sidebar .view,", css)
        self.assertIn(".thunar .shortcuts-pane,", css)
        self.assertIn("scrolledwindow.frame.sidebar.shortcuts-pane", css)
        self.assertIn("background-color: #000000;", css)

        # Scoped selection
        self.assertIn(".thunar .view:selected,", css)
        self.assertIn(".thunar iconview:selected,", css)
        self.assertIn(".thunar treeview.view:selected", css)
        self.assertIn("background-color: alpha(#3388ee, 0.28);", css)

        # Ensure NO unscoped global overrides are present
        lines = [line.strip() for line in css.splitlines() if line.strip() and not line.startswith("/*") and not line.startswith("@import")]
        # Every rule block selector must begin with .thunar
        selectors = []
        for line in lines:
            if "{" in line:
                selectors.append(line.split("{")[0].strip())
            elif line.endswith(","):
                selectors.append(line.rstrip(","))
        for sel in selectors:
            self.assertTrue(".thunar" in sel, f"Selector '{sel}' must be scoped to Thunar")

        # Parse with Gtk 3 CssProvider
        try:
            import gi
            gi.require_version("Gtk", "3.0")
            from gi.repository import Gtk
            provider = Gtk.CssProvider()
            provider.load_from_data(css.encode("utf-8"))
        except ImportError:
            pass

    def test_generate_gtk4_css(self):
        """Verify gtk-4.0/gtk.css imports base theme without alterations."""
        css = theme_thunar_bg.generate_gtk4_css("/home/banana/.themes/Graphite-blue-Dark")
        self.assertEqual(css.strip(), '@import url("file:///home/banana/.themes/Graphite-blue-Dark/gtk-4.0/gtk.css");')

    def test_create_thunar_theme_structure(self):
        """Verify on-disk file layout, symlinks, and legacy links."""
        local_dir = os.path.join(self.test_tmp_dir, "local_themes")
        dot_dir = os.path.join(self.test_tmp_dir, "dot_themes")

        theme_name, theme_dir = theme_thunar_bg.create_thunar_theme(
            bg0="#111111",
            bg1="#222222",
            fg0="#eeeeee",
            accent="#4488ff",
            firma="teststruct",
            output_base=local_dir,
            symlink_base=dot_dir,
        )

        self.assertEqual(theme_name, "Graphite-qs-teststruct")
        self.assertTrue(os.path.isdir(theme_dir))

        # Check index.theme
        index_file = os.path.join(theme_dir, "index.theme")
        self.assertTrue(os.path.isfile(index_file))

        # Check gtk-3.0
        gtk3_css = os.path.join(theme_dir, "gtk-3.0", "gtk.css")
        gtk3_dark = os.path.join(theme_dir, "gtk-3.0", "gtk-dark.css")
        gtk3_assets = os.path.join(theme_dir, "gtk-3.0", "assets")
        self.assertTrue(os.path.isfile(gtk3_css))
        self.assertTrue(os.path.exists(gtk3_dark))
        self.assertTrue(os.path.exists(gtk3_assets))

        # Check gtk-4.0
        gtk4_css = os.path.join(theme_dir, "gtk-4.0", "gtk.css")
        gtk4_dark = os.path.join(theme_dir, "gtk-4.0", "gtk-dark.css")
        gtk4_assets = os.path.join(theme_dir, "gtk-4.0", "assets")
        self.assertTrue(os.path.isfile(gtk4_css))
        self.assertTrue(os.path.exists(gtk4_dark))
        self.assertTrue(os.path.exists(gtk4_assets))

        # Check legacy symlink
        legacy_symlink = os.path.join(dot_dir, theme_name)
        self.assertTrue(os.path.islink(legacy_symlink))
        self.assertEqual(os.path.realpath(legacy_symlink), os.path.realpath(theme_dir))

    def test_update_gtk_settings(self):
        """Verify safe and atomic settings.ini updates."""
        test_ini = os.path.join(self.test_tmp_dir, "settings.ini")
        with open(test_ini, "w", encoding="utf-8") as f:
            f.write("[Settings]\ngtk-icon-theme-name=kora-green\ngtk-theme-name=Graphite-blue-Dark\n")

        theme_thunar_bg.update_gtk_settings("Graphite-qs-newhash", paths=[test_ini])

        with open(test_ini, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertIn("gtk-theme-name=Graphite-qs-newhash", content)
        self.assertIn("gtk-icon-theme-name=kora-green", content)

    def test_prune_old_themes(self):
        """Verify pruning removes only older Graphite-qs-* directories and symlinks."""
        local_dir = os.path.join(self.test_tmp_dir, "local_themes")
        dot_dir = os.path.join(self.test_tmp_dir, "dot_themes")
        os.makedirs(local_dir, exist_ok=True)
        os.makedirs(dot_dir, exist_ok=True)

        # Create dummy old themes
        for name in ["Graphite-qs-old1", "Graphite-qs-old2", "Graphite-qs-keep", "Adwaita"]:
            os.makedirs(os.path.join(local_dir, name), exist_ok=True)
            os.symlink(os.path.join(local_dir, name), os.path.join(dot_dir, name))

        pruned = theme_thunar_bg.prune_old_themes(keep_theme="Graphite-qs-keep", base_dirs=[local_dir, dot_dir])

        self.assertFalse(os.path.exists(os.path.join(local_dir, "Graphite-qs-old1")))
        self.assertFalse(os.path.exists(os.path.join(local_dir, "Graphite-qs-old2")))
        self.assertTrue(os.path.exists(os.path.join(local_dir, "Graphite-qs-keep")))
        self.assertTrue(os.path.exists(os.path.join(local_dir, "Adwaita")))
        self.assertTrue(os.path.exists(os.path.join(dot_dir, "Graphite-qs-keep")))
        self.assertTrue(os.path.exists(os.path.join(dot_dir, "Adwaita")))

    def test_apply_thunar_bg_e2e(self):
        """Verify full end-to-end execution of apply_thunar_bg."""
        theme_name = theme_thunar_bg.apply_thunar_bg(
            bg0="#151618",
            bg1="#1f2023",
            fg0="#f0f1f2",
            accent="#5294e2",
            firma="e2etest",
            sync=True,
        )
        self.assertEqual(theme_name, "Graphite-qs-e2etest")

        # Verify theme directory and symlink
        theme_dir = os.path.expanduser("~/.local/share/themes/Graphite-qs-e2etest")
        symlink_dir = os.path.expanduser("~/.themes/Graphite-qs-e2etest")
        self.assertTrue(os.path.isdir(theme_dir))
        self.assertTrue(os.path.islink(symlink_dir))

        # Verify gsettings
        current = theme_thunar_bg.get_current_gtk_theme()
        self.assertEqual(current, "Graphite-qs-e2etest")

    def test_latency_benchmark(self):
        """Verify that apply_thunar_bg executes well below 10ms (<10ms requirement)."""
        durations = []
        for i in range(10):
            firma = f"benchtest{i}"
            t0 = time.perf_counter()
            name = theme_thunar_bg.apply_thunar_bg(
                bg0="#181512",
                bg1="#221e19",
                fg0="#ededed",
                accent="#dba157",
                firma=firma,
                sync=False,
            )
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            durations.append(elapsed_ms)

        avg_ms = sum(durations) / len(durations)
        max_ms = max(durations)

        self.assertLess(avg_ms, 10.0, f"Average execution latency {avg_ms:.2f}ms exceeds 10ms threshold")
        self.assertLess(max_ms, 10.0, f"Max execution latency {max_ms:.2f}ms exceeds 10ms threshold")


if __name__ == "__main__":
    unittest.main()
