#!/usr/bin/env python3
"""
wallpaper-theme.py
Extracts a refined, hue-matching bar background color from the current wallpaper.
Delegates to the unified apply_theme module for Quickshell Theme.qml compatibility.
"""

import sys
import os

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from apply_theme import main

if __name__ == "__main__":
    sys.exit(main())
