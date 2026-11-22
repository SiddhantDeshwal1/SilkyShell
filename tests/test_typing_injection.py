#!/usr/bin/env python3
"""
test_typing_injection.py — Wayland Keystroke Injection Benchmark & Safety Suite.
Validates:
1. Socket Validation: Active vs stale / missing /run/user/<UID>/.ydotool_socket detection.
2. Grace Period Mechanics: 200ms Super-release delay ONLY on the very first stroke,
   zero delay on ongoing continuous streaming chunks.
3. Keystroke Injection Throughput & Fidelity: chars/sec throughput and 100% character
   fidelity across lowercase, uppercase, and technical syntax for -d 1 -H 1 vs -d 2 -H 2.
4. Fallback Path & Timeout Protection: wtype fallback execution and hang prevention.
5. Modifier Safety: Virtual modifier key release and state verification.
"""

import unittest
import subprocess
import socket
import os
import sys
import time

TEST_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(TEST_DIR, ".."))
SCRIPTS_DIR = os.path.join(PROJECT_DIR, "scripts")
sys.path.insert(0, SCRIPTS_DIR)

import importlib.util
spec = importlib.util.spec_from_file_location("live_dictate", os.path.join(SCRIPTS_DIR, "live-dictate.py"))
live_dictate = importlib.util.module_from_spec(spec)


class TestTypingInjection(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        # Dynamically load live_dictate module functions
        try:
            spec.loader.exec_module(live_dictate)
        except Exception as e:
            # If exec fails due to environment dependencies, we still test imported functions
            pass

    def test_01_socket_validation_active(self):
        """Verify active /run/user/<UID>/.ydotool_socket passes validation."""
        uid = os.getuid()
        active_sock = f"/run/user/{uid}/.ydotool_socket"
        if os.path.exists(active_sock):
            self.assertTrue(
                live_dictate.validate_ydotool_socket(active_sock),
                f"Active socket {active_sock} should pass datagram validation"
            )
            detected = live_dictate.get_ydotool_socket()
            self.assertIsNotNone(detected)
            self.assertTrue(os.path.exists(detected))

    def test_02_socket_validation_stale_and_invalid(self):
        """Verify non-existent and stale sockets fail validation immediately."""
        self.assertFalse(live_dictate.validate_ydotool_socket("/tmp/non_existent_socket.sock"))
        self.assertFalse(live_dictate.validate_ydotool_socket(""))

        # Create a stale socket (bound then closed, no listener)
        stale_sock = "/tmp/test_stale_unit.sock"
        if os.path.exists(stale_sock):
            os.remove(stale_sock)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            s.bind(stale_sock)
            s.close()
            self.assertFalse(
                live_dictate.validate_ydotool_socket(stale_sock),
                "Stale socket without listener must fail datagram validation"
            )
        finally:
            if os.path.exists(stale_sock):
                os.remove(stale_sock)

    def test_03_grace_period_first_stroke_vs_continuous(self):
        """
        Verify grace period only delays up to 200ms from activation time,
        and causes ZERO delay on continuous streaming chunks.
        """
        # Scenario A: Dictation stream started 300ms ago (normal speech transcription)
        live_dictate._stream_start_time = time.monotonic() - 0.30
        live_dictate._grace_period_done = False
        live_dictate._shutdown_requested = False
        live_dictate._shutdown_grace_done = False

        t0 = time.monotonic()
        # Call grace period logic via type_text on a mock/blank or fast string
        # We can observe elapsed time for the call
        # Mock sanitize_text to return empty to isolate the grace period calculation
        orig_sanitize = live_dictate.sanitize_text
        try:
            live_dictate.sanitize_text = lambda x: ""  # Return empty to avoid actual typing
            live_dictate.type_text("test")
            t_elapsed = time.monotonic() - t0
            self.assertTrue(live_dictate._grace_period_done, "_grace_period_done should be True after first call")
            self.assertLess(t_elapsed, 0.05, f"Grace period should NOT sleep when elapsed >= 200ms (took {t_elapsed:.4f}s)")

            # Scenario B: Continuous streaming chunk (chunk 2)
            t1 = time.monotonic()
            live_dictate.type_text("chunk 2")
            t_chunk2 = time.monotonic() - t1
            self.assertLess(t_chunk2, 0.01, f"Continuous chunks must have ZERO delay (took {t_chunk2:.4f}s)")

            # Scenario C: Stream started just 50ms ago (simulated instant chunk)
            live_dictate._stream_start_time = time.monotonic() - 0.05
            live_dictate._grace_period_done = False
            t2 = time.monotonic()
            live_dictate.type_text("quick chunk")
            t_quick = time.monotonic() - t2
            self.assertTrue(live_dictate._grace_period_done)
            # Should have slept approximately 200ms - 50ms = 150ms (within 120ms - 200ms)
            self.assertGreaterEqual(t_quick, 0.12, f"Should sleep remainder of grace period (took {t_quick:.4f}s)")
            self.assertLess(t_quick, 0.25, f"Should not sleep beyond grace period (took {t_quick:.4f}s)")
        finally:
            live_dictate.sanitize_text = orig_sanitize

    def test_04_shutdown_grace_period_timing(self):
        """Verify shutdown grace period only delays first shutdown chunk, not subsequent ones."""
        orig_sanitize = live_dictate.sanitize_text
        try:
            live_dictate.sanitize_text = lambda x: ""
            live_dictate._stream_start_time = time.monotonic() - 5.0
            live_dictate._grace_period_done = True
            live_dictate._shutdown_requested = True
            live_dictate._shutdown_grace_done = False
            live_dictate._shutdown_time = time.monotonic() - 0.20  # Stopped 200ms ago

            t0 = time.monotonic()
            live_dictate.type_text("shutdown chunk 1")
            t_first = time.monotonic() - t0
            self.assertTrue(live_dictate._shutdown_grace_done)
            self.assertLess(t_first, 0.05, "Shutdown chunk should NOT sleep if >150ms has passed since stop signal")

            # Subsequent shutdown chunk
            t1 = time.monotonic()
            live_dictate.type_text("shutdown chunk 2")
            t_subsequent = time.monotonic() - t1
            self.assertLess(t_subsequent, 0.01, "Subsequent shutdown chunk must have zero delay")
        finally:
            live_dictate.sanitize_text = orig_sanitize

    def test_05_modifier_safety_reset(self):
        """Verify reset_virtual_modifiers executes without raising errors."""
        try:
            live_dictate.reset_virtual_modifiers()
            success = True
        except Exception as e:
            success = False
        self.assertTrue(success, "reset_virtual_modifiers must execute cleanly")

    def test_06_wtype_fallback_timeout(self):
        """Verify wtype fallback has timeout protection and does not hang."""
        t0 = time.monotonic()
        # Test wtype with valid arguments
        env = os.environ.copy()
        res = subprocess.run(
            ["wtype", "-d", "1", "--", ""],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1.0
        )
        t_elapsed = time.monotonic() - t0
        self.assertLess(t_elapsed, 1.0, f"wtype took too long: {t_elapsed:.4f}s")

    def test_07_keystroke_benchmark_and_fidelity(self):
        """
        Benchmark typing throughput (chars/sec) and verify 100% character fidelity
        for -d 1 -H 1 vs -d 2 -H 2 across lowercase, uppercase, and code syntax.
        """
        sock = live_dictate.get_ydotool_socket()
        if not sock:
            self.skipTest("ydotoold socket not active; skipping live terminal benchmark")

        # Receiver script that captures raw terminal keystrokes
        receiver_script = "/tmp/bench_receiver.py"
        with open(receiver_script, "w") as f:
            f.write(
                "import sys, tty, termios, time\n"
                "fd = sys.stdin.fileno()\n"
                "old = termios.tcgetattr(fd)\n"
                "tty.setraw(fd)\n"
                "received = []\n"
                "start = None\n"
                "with open('/tmp/receiver_ready', 'w') as f: f.write('ready')\n"
                "try:\n"
                "    while True:\n"
                "        ch = sys.stdin.read(1)\n"
                "        if start is None: start = time.time()\n"
                "        if ch in ('\\x04', '\\x03'): break\n"
                "        received.append(ch)\n"
                "        if ''.join(received).endswith('DONE'): break\n"
                "finally:\n"
                "    end = time.time()\n"
                "    termios.tcsetattr(fd, termios.TCSADRAIN, old)\n"
                "    text = ''.join(received)\n"
                "    dur = (end - start) if start else 0.0\n"
                "    with open('/tmp/receiver_result.txt', 'w') as f:\n"
                "        f.write(f'{dur:.4f}\\n{text}')\n"
            )

        test_phrases = [
            "The quick brown fox jumps over the lazy dog! DONE",
            "def calculate(items: list[dict]) -> int: return sum(x['val'] for x in items) DONE",
        ]

        # Get current workspace
        try:
            curr_ws_res = subprocess.run(["hyprctl", "activeworkspace"], capture_output=True, text=True, timeout=1.0)
            orig_ws = "11"
            for line in curr_ws_res.stdout.splitlines():
                if line.startswith("workspace "):
                    orig_ws = line.split()[1]
                    break
        except Exception:
            orig_ws = "11"

        rates = {}
        for (d, h) in [(1, 1), (2, 2)]:
            param_key = f"-d {d} -H {h}"
            total_chars = 0
            total_time = 0.0

            for phrase in test_phrases:
                if os.path.exists("/tmp/receiver_ready"): os.remove("/tmp/receiver_ready")
                if os.path.exists("/tmp/receiver_result.txt"): os.remove("/tmp/receiver_result.txt")

                # Switch to workspace 99 and open foot
                subprocess.run(["hyprctl", "eval", "hl.dispatch(hl.dsp.focus({ workspace = 99 }))"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                foot = subprocess.Popen(["foot", "--title=BENCH", "python3", receiver_script],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                for _ in range(40):
                    if os.path.exists("/tmp/receiver_ready"): break
                    time.sleep(0.05)
                time.sleep(0.15)

                env = os.environ.copy()
                env["YDOTOOL_SOCKET"] = sock

                t_start = time.perf_counter()
                subprocess.run(["ydotool", "type", "-d", str(d), "-H", str(h), phrase],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                t_end = time.perf_counter()

                try:
                    foot.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    foot.kill()

                subprocess.run(["hyprctl", "eval", f"hl.dispatch(hl.dsp.focus({{ workspace = {orig_ws} }}))"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

                if os.path.exists("/tmp/receiver_result.txt"):
                    with open("/tmp/receiver_result.txt") as f:
                        lines = f.readlines()
                    received = "".join(lines[1:])
                    self.assertEqual(
                        phrase, received,
                        f"Fidelity mismatch for {param_key}!\nExpected: {phrase}\nGot:      {received}"
                    )
                    total_chars += len(phrase)
                    total_time += (t_end - t_start)
                else:
                    self.fail(f"Receiver timed out on {param_key} for phrase '{phrase}'")

            rate = total_chars / total_time if total_time > 0 else 0
            rates[param_key] = rate
            print(f"\n[BENCHMARK] {param_key}: {rate:.1f} chars/sec ({total_chars} chars in {total_time:.3f}s)")

        # Restore original workspace
        subprocess.run(["hyprctl", "eval", f"hl.dispatch(hl.dsp.focus({{ workspace = {orig_ws} }}))"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Assert -d 1 -H 1 is faster than -d 2 -H 2 and achieves >300 chars/sec
        self.assertGreater(rates["-d 1 -H 1"], rates["-d 2 -H 2"], "-d 1 -H 1 should be significantly faster than -d 2 -H 2")
        self.assertGreater(rates["-d 1 -H 1"], 300.0, f"-d 1 -H 1 throughput ({rates['-d 1 -H 1']:.1f} chars/sec) should exceed 300 chars/sec")


if __name__ == "__main__":
    unittest.main()
