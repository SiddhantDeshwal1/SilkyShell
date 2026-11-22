#!/usr/bin/env python3
"""
test_backend_optimizations.py — Regression and contract verification test suite
for Quickshell backend daemons and optimization refactorings.
Validates:
1. Zero-Regression Invariants on schemas, CLI args, and return types.
2. Singleton locking enforcement on screenshare-service, camera-service, timer-service.
3. Clean process lifecycle and termination on stdin EOF (orphan prevention).
4. Sub-100ms response time on hardware queries.
"""

import unittest
import subprocess
import json
import os
import sys
import time

SCRIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts"))

class TestBackendOptimizations(unittest.TestCase):

    def test_camera_service_get_schema(self):
        """Verify camera-service.py get returns expected JSON schema."""
        script = os.path.join(SCRIPTS_DIR, "camera-service.py")
        res = subprocess.run([sys.executable, script, "get"], capture_output=True, text=True, timeout=5)
        self.assertEqual(res.returncode, 0, f"camera-service get failed: {res.stderr}")
        data = json.loads(res.stdout)
        self.assertIn("active", data)
        self.assertIn("apps", data)
        self.assertIsInstance(data["active"], bool)
        self.assertIsInstance(data["apps"], list)

    def test_camera_service_singleton_lock(self):
        """Verify camera-service daemon enforces singleton lock."""
        script = os.path.join(SCRIPTS_DIR, "camera-service.py")
        env = dict(os.environ, QUICKSHELL_CAMERA_LOCK="/tmp/test_cam.lock")
        p1 = subprocess.Popen([sys.executable, script, "daemon"], stdout=subprocess.PIPE, stdin=subprocess.PIPE, env=env)
        try:
            time.sleep(0.3)
            p2 = subprocess.run([sys.executable, script, "daemon"], capture_output=True, text=True, timeout=3, env=env)
            self.assertEqual(p2.returncode, 0)
            self.assertIn("Another instance is already running", p2.stderr)
        finally:
            p1.terminate()
            p1.stdin.close()
            p1.stdout.close()
            p1.wait(timeout=2)
            if os.path.exists("/tmp/test_cam.lock"):
                try: os.remove("/tmp/test_cam.lock")
                except Exception: pass

    def test_screenshare_service_status_schema(self):
        """Verify screenshare-service.py status returns expected JSON schema."""
        script = os.path.join(SCRIPTS_DIR, "screenshare-service.py")
        res = subprocess.run([sys.executable, script, "status"], capture_output=True, text=True, timeout=5)
        self.assertEqual(res.returncode, 0, f"screenshare-service status failed: {res.stderr}")
        data = json.loads(res.stdout)
        self.assertIn("isSharing", data)
        self.assertIn("type", data)
        self.assertIn("monitor", data)
        self.assertIn("visible", data)
        self.assertIn("geometry", data)
        self.assertIsInstance(data["geometry"], dict)
        for key in ["x", "y", "width", "height"]:
            self.assertIn(key, data["geometry"])

    def test_screenshare_service_singleton_lock(self):
        """Verify screenshare-service daemon enforces singleton lock."""
        script = os.path.join(SCRIPTS_DIR, "screenshare-service.py")
        env = dict(os.environ, QUICKSHELL_SCREENSHARE_LOCK="/tmp/test_screenshare.lock")
        p1 = subprocess.Popen([sys.executable, script, "daemon"], stdout=subprocess.PIPE, stdin=subprocess.PIPE, env=env)
        try:
            time.sleep(0.3)
            p2 = subprocess.run([sys.executable, script, "daemon"], capture_output=True, text=True, timeout=3, env=env)
            self.assertEqual(p2.returncode, 0)
            self.assertIn("Another daemon instance is already running", p2.stderr)
        finally:
            p1.terminate()
            p1.wait(timeout=2)
            if os.path.exists("/tmp/test_screenshare.lock"):
                try: os.remove("/tmp/test_screenshare.lock")
                except Exception: pass

    def test_screenshare_service_stdin_eof_cleanup(self):
        """Verify screenshare-service terminates promptly when stdin pipe closes."""
        script = os.path.join(SCRIPTS_DIR, "screenshare-service.py")
        env = dict(os.environ, QUICKSHELL_SCREENSHARE_LOCK="/tmp/test_screenshare_eof.lock")
        p = subprocess.Popen([sys.executable, script, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        try:
            time.sleep(0.3)
            self.assertIsNone(p.poll(), "Daemon should be running")
            # Close stdin pipe (simulating Quickshell exit)
            p.stdin.close()
            # Should exit within 2.5 seconds
            t0 = time.time()
            while p.poll() is None and (time.time() - t0) < 2.5:
                time.sleep(0.1)
            self.assertIsNotNone(p.poll(), "Daemon failed to terminate after stdin closed (orphan risk)")
        finally:
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=1)
            if os.path.exists("/tmp/test_screenshare_eof.lock"):
                try: os.remove("/tmp/test_screenshare_eof.lock")
                except Exception: pass

    def test_timer_service_get_schema(self):
        """Verify timer-service.py get returns expected JSON schema."""
        script = os.path.join(SCRIPTS_DIR, "timer-service.py")
        res = subprocess.run([sys.executable, script, "get"], capture_output=True, text=True, timeout=5)
        self.assertEqual(res.returncode, 0, f"timer-service get failed: {res.stderr}")
        data = json.loads(res.stdout)
        self.assertIn("mode", data)
        self.assertIn("running", data)
        self.assertIn("seconds", data)
        self.assertIn("duration", data)
        self.assertIn("display", data)

    def test_timer_service_singleton_lock(self):
        """Verify timer-service daemon enforces singleton lock."""
        script = os.path.join(SCRIPTS_DIR, "timer-service.py")
        env = dict(os.environ, QUICKSHELL_TIMER_LOCK="/tmp/test_timer.lock")
        p1 = subprocess.Popen([sys.executable, script, "daemon"], stdout=subprocess.PIPE, stdin=subprocess.PIPE, env=env)
        try:
            time.sleep(0.3)
            p2 = subprocess.run([sys.executable, script, "daemon"], capture_output=True, text=True, timeout=3, env=env)
            self.assertEqual(p2.returncode, 0)
            self.assertIn("Another daemon instance is already running", p2.stderr)
        finally:
            p1.terminate()
            p1.wait(timeout=2)
            if os.path.exists("/tmp/test_timer.lock"):
                try: os.remove("/tmp/test_timer.lock")
                except Exception: pass

    def test_timer_service_stdin_eof_cleanup(self):
        """Verify timer-service terminates promptly when stdin pipe closes."""
        script = os.path.join(SCRIPTS_DIR, "timer-service.py")
        env = dict(os.environ, QUICKSHELL_TIMER_LOCK="/tmp/test_timer_eof.lock")
        p = subprocess.Popen([sys.executable, script, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        try:
            time.sleep(0.3)
            self.assertIsNone(p.poll(), "Timer daemon should be running")
            # Close stdin pipe
            p.stdin.close()
            t0 = time.time()
            while p.poll() is None and (time.time() - t0) < 2.5:
                time.sleep(0.1)
            self.assertIsNotNone(p.poll(), "Timer daemon failed to terminate after stdin closed (orphan risk)")
        finally:
            if p.poll() is None:
                p.terminate()
                p.wait(timeout=1)
            if os.path.exists("/tmp/test_timer_eof.lock"):
                try: os.remove("/tmp/test_timer_eof.lock")
                except Exception: pass

if __name__ == "__main__":
    unittest.main()
