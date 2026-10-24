#!/usr/bin/env python3
"""
Backward-compatible proxy to web-search.py.
Uses os.execv for a zero-cost process replacement (no subprocess overhead).
"""
import sys
import os

script_dir = os.path.dirname(os.path.abspath(__file__))
web_search = os.path.join(script_dir, "web-search.py")

# Replace this process with web-search.py — no fork, no Python startup overhead
os.execv(sys.executable, [sys.executable, web_search, "suggest"] + sys.argv[1:])
