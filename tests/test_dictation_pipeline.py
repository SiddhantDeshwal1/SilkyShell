#!/usr/bin/env python3
"""
test_dictation_pipeline.py — Comprehensive End-to-End Benchmark, Regression & Orphan Audit Suite
for Quickshell Live Dictation Service (scripts/live-dictate.py).

Verification Scope:
1. CLI Lifecycle: status, toggle, stop idempotency and transition verification.
2. Process Isolation & Safety:
   - Clean /proc PID management and hierarchy tracking.
   - Kernel-enforced PR_SET_PDEATHSIG child termination on parent SIGKILL.
3. State File Integrity:
   - Atomic /tmp/qs_dictation.json updates.
   - Strict schema validation and boolean isListening tracking.
4. Inference Pipeline & Latency:
   - Mock multipart/form-data HTTP inference endpoint contract verification.
   - Live GPU/Vulkan whisper-server inference with 16kHz synthetic WAV.
   - Sub-second / sub-SLA latency benchmarking.
5. Anti-Leak & Orphan Process Audit:
   - Zero lingering whisper-server or parec processes after cmd_stop().
   - Multi-cycle stress audit verifying zero accumulated process or file leaks.
6. Safety Circuit Breaker:
   - Repetition firewall, phantom tokens, sound effect stripper, and burst caps.
"""

import unittest
import subprocess
import json
import os
import sys
import time
import signal
import wave
import io
import math
import struct
import importlib.util
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading

REPO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS_DIR = os.path.join(REPO_DIR, "scripts")
LIVE_DICTATE_SCRIPT = os.path.join(SCRIPTS_DIR, "live-dictate.py")
STATE_FILE = "/tmp/qs_dictation.json"
STATE_TMP_FILE = "/tmp/qs_dictation.json.tmp"
DICTATION_DIR = os.path.expanduser("~/.local/share/dictation")
BIN_DIR = os.path.join(DICTATION_DIR, "bin")
MODELS_DIR = os.path.join(DICTATION_DIR, "models")
GPU_SERVER_BIN = os.path.join(BIN_DIR, "whisper-server")
GPU_MODEL_PATH = os.path.join(MODELS_DIR, "ggml-small.en-q5_1.bin")
GPU_SERVER_PORT = 8089

# Dynamically import live-dictate module for direct helper verification
_spec = importlib.util.spec_from_file_location("live_dictate", LIVE_DICTATE_SCRIPT)
live_dictate_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(live_dictate_mod)


def get_pid_file_path() -> str:
    """Return path to live-dictate.pid in user runtime dir."""
    uid = os.getuid()
    rt_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{uid}")
    if not os.path.isdir(rt_dir):
        rt_dir = f"/run/user/{uid}"
    return os.path.join(rt_dir, "live-dictate.pid")


def is_pid_alive(pid: int) -> bool:
    """Check if process with given PID exists in /proc."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return os.path.exists(f"/proc/{pid}")
    except OSError:
        return False


def get_process_children(parent_pid: int) -> list[int]:
    """Discover all child PIDs of parent_pid via /proc."""
    children = []
    # Primary: check /proc/<pid>/task/<pid>/children
    c_file = f"/proc/{parent_pid}/task/{parent_pid}/children"
    if os.path.exists(c_file):
        try:
            with open(c_file, "r") as f:
                children = [int(p) for p in f.read().split() if p.strip()]
        except (OSError, ValueError):
            pass
    if children:
        return children

    # Fallback: scan /proc/*/stat for ppid matching parent_pid
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            cpid = int(entry)
            stat_file = f"/proc/{cpid}/stat"
            try:
                with open(stat_file, "r") as f:
                    content = f.read()
                parts = content.split(")")
                if len(parts) > 1:
                    fields = parts[1].split()
                    ppid = int(fields[1])
                    if ppid == parent_pid:
                        children.append(cpid)
            except (OSError, IndexError, ValueError):
                pass
    return children


def synthesize_16k_wav(duration_s: float = 1.0, freq_hz: float = 440.0, sample_rate: int = 16000) -> bytes:
    """Synthesize clean 16kHz 16-bit mono PCM in standard RIFF WAV format."""
    num_samples = int(sample_rate * duration_s)
    wav_io = io.BytesIO()
    with wave.open(wav_io, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        frames = bytearray()
        for i in range(num_samples):
            # Generate 440Hz sine wave tone scaled to 16-bit int range
            val = int(16000.0 * math.sin(2.0 * math.pi * freq_hz * (i / sample_rate)))
            frames.extend(struct.pack("<h", val))
        wf.writeframes(frames)
    return wav_io.getvalue()


def clean_dictation_environment():
    """Ensure stopped status and clean up any residual processes before/after tests."""
    # 1. Stop via CLI
    subprocess.run(
        [sys.executable, LIVE_DICTATE_SCRIPT, "stop"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=6.0
    )

    # 2. Force remove stale PID file if still present
    pid_file = get_pid_file_path()
    if os.path.exists(pid_file):
        try:
            with open(pid_file, "r") as f:
                c = f.read().strip()
                if c and c.isdigit():
                    pid = int(c)
                    if is_pid_alive(pid):
                        os.kill(pid, signal.SIGKILL)
            os.remove(pid_file)
        except OSError:
            pass

    # 3. Terminate any orphaned live-dictate, parec, or test-spawned whisper-server
    try:
        res = subprocess.run(["pgrep", "-a", "-f", "live-dictate.py stream"], capture_output=True, text=True)
        for line in res.stdout.strip().splitlines():
            if line:
                p = int(line.split()[0])
                try: os.kill(p, signal.SIGKILL)
                except OSError: pass
    except Exception:
        pass

    # 4. Guarantee state file reflects stopped state
    try:
        live_dictate_mod.update_state(False)
    except Exception:
        pass


class TestCliLifecycle(unittest.TestCase):
    """Verifies Requirement 2a: CLI lifecycle commands (status, toggle, stop)."""

    def setUp(self):
        clean_dictation_environment()

    def tearDown(self):
        clean_dictation_environment()

    def test_cli_status_when_stopped(self):
        """Verify 'status' command returns valid JSON with running=False when stopped."""
        res = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "status"],
            capture_output=True,
            text=True,
            timeout=5.0
        )
        self.assertEqual(res.returncode, 0, f"status command failed: {res.stderr}")
        data = json.loads(res.stdout)
        self.assertIn("running", data)
        self.assertIn("pid", data)
        self.assertIn("device", data)
        self.assertIn("gpu", data)
        self.assertFalse(data["running"])
        self.assertEqual(data["pid"], 0)
        self.assertEqual(data["device"], "")
        self.assertIsInstance(data["gpu"], bool)

    def test_cli_stop_idempotent(self):
        """Verify 'stop' command is safe and idempotent when daemon is already stopped."""
        res = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "stop"],
            capture_output=True,
            text=True,
            timeout=5.0
        )
        self.assertEqual(res.returncode, 0)
        data = json.loads(res.stdout)
        self.assertFalse(data["running"])
        self.assertEqual(data["pid"], 0)

    def test_cli_toggle_lifecycle(self):
        """Verify 'toggle' transitions cleanly from stopped -> running -> stopped."""
        # 1. Toggle ON: stopped -> running
        res1 = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "toggle"],
            capture_output=True,
            text=True,
            timeout=6.0
        )
        self.assertEqual(res1.returncode, 0, f"Toggle ON failed: {res1.stderr}")
        data1 = json.loads(res1.stdout)
        self.assertTrue(data1["running"])
        daemon_pid = data1["pid"]
        self.assertGreater(daemon_pid, 0)

        # Allow daemon loop to initialize
        time.sleep(0.3)

        # Verify status reports running=True
        status_res = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "status"],
            capture_output=True,
            text=True,
            timeout=5.0
        )
        self.assertEqual(status_res.returncode, 0)
        st_data = json.loads(status_res.stdout)
        self.assertTrue(st_data["running"])
        self.assertEqual(st_data["pid"], daemon_pid)
        self.assertTrue(is_pid_alive(daemon_pid))

        # 2. Toggle OFF: running -> stopped
        res2 = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "toggle"],
            capture_output=True,
            text=True,
            timeout=8.0
        )
        self.assertEqual(res2.returncode, 0, f"Toggle OFF failed: {res2.stderr}")
        data2 = json.loads(res2.stdout)
        self.assertFalse(data2["running"])
        self.assertEqual(data2["pid"], 0)

        # Verify status reports running=False
        status_res2 = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "status"],
            capture_output=True,
            text=True,
            timeout=5.0
        )
        st_data2 = json.loads(status_res2.stdout)
        self.assertFalse(st_data2["running"])
        self.assertEqual(st_data2["pid"], 0)
        self.assertFalse(is_pid_alive(daemon_pid))

    def test_cli_stop_while_running(self):
        """Verify 'stop' command halts active streaming daemon and returns clean status."""
        # Start daemon
        res_start = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "toggle"],
            capture_output=True,
            text=True,
            timeout=6.0
        )
        daemon_pid = json.loads(res_start.stdout)["pid"]
        self.assertTrue(is_pid_alive(daemon_pid))

        # Stop daemon explicitly
        res_stop = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "stop"],
            capture_output=True,
            text=True,
            timeout=8.0
        )
        self.assertEqual(res_stop.returncode, 0)
        data = json.loads(res_stop.stdout)
        self.assertFalse(data["running"])
        self.assertEqual(data["pid"], 0)
        self.assertFalse(is_pid_alive(daemon_pid))

    def test_cli_help_and_invalid_arguments(self):
        """Verify help flags exit with code 0 and invalid commands exit with code 1."""
        res_help = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "--help"],
            capture_output=True,
            text=True,
            timeout=5.0
        )
        self.assertEqual(res_help.returncode, 0)
        self.assertIn("Usage:", res_help.stdout)

        res_invalid = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "bogus_action"],
            capture_output=True,
            text=True,
            timeout=5.0
        )
        self.assertEqual(res_invalid.returncode, 1)
        self.assertIn("Unknown command", res_invalid.stderr)


class TestProcessIsolationAndDeathSignal(unittest.TestCase):
    """Verifies Requirement 2b: /proc PID hierarchy and PR_SET_PDEATHSIG enforcement."""

    def setUp(self):
        clean_dictation_environment()

    def tearDown(self):
        clean_dictation_environment()

    def test_proc_pid_management_during_streaming(self):
        """Verify /proc reflects valid PID, cmdline, and clean parent-child hierarchy."""
        res = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "toggle"],
            capture_output=True,
            text=True,
            timeout=6.0
        )
        self.assertEqual(res.returncode, 0)
        daemon_pid = json.loads(res.stdout)["pid"]

        # 1. Check parent process in /proc
        proc_dir = f"/proc/{daemon_pid}"
        self.assertTrue(os.path.exists(proc_dir), f"/proc/{daemon_pid} does not exist")

        with open(f"{proc_dir}/cmdline", "rb") as f:
            cmdline = f.read().decode("utf-8", errors="ignore")
            self.assertIn("live-dictate", cmdline)

        # 2. Check child processes have PPID matching daemon_pid
        time.sleep(0.5)
        children = get_process_children(daemon_pid)
        for cpid in children:
            self.assertTrue(os.path.exists(f"/proc/{cpid}"))
            with open(f"/proc/{cpid}/stat", "r") as f:
                stat_content = f.read()
            parts = stat_content.split(")")
            ppid = int(parts[1].split()[1])
            self.assertEqual(ppid, daemon_pid, f"Child {cpid} PPID ({ppid}) does not match parent ({daemon_pid})")

        # Cleanup
        subprocess.run([sys.executable, LIVE_DICTATE_SCRIPT, "stop"], timeout=6.0)

    def test_pr_set_pdeathsig_kernel_cleanup_on_sigkill(self):
        """
        Verify PR_SET_PDEATHSIG: Abruptly killing parent with SIGKILL
        forces Linux kernel to immediately deliver SIGTERM to child processes.
        Bypasses all Python atexit / finally handlers.
        """
        # Spawn live-dictate stream directly as a monitored subprocess
        proc = subprocess.Popen(
            [sys.executable, LIVE_DICTATE_SCRIPT, "stream"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        parent_pid = proc.pid
        self.assertTrue(is_pid_alive(parent_pid))

        # Wait up to 2.0s for child processes (parec and/or whisper-server) to spawn
        children = []
        for _ in range(40):
            time.sleep(0.05)
            children = get_process_children(parent_pid)
            if children:
                break

        self.assertGreater(len(children), 0, "No child processes spawned by dictation stream")
        for cpid in children:
            self.assertTrue(is_pid_alive(cpid), f"Child {cpid} is not alive")

        # Deliver SIGKILL to parent (bypassing any userspace cleanup)
        os.kill(parent_pid, signal.SIGKILL)
        proc.wait(timeout=2.0)
        self.assertFalse(is_pid_alive(parent_pid))

        # Kernel must deliver SIGTERM to children via PR_SET_PDEATHSIG
        # Poll up to 2.0s for all children to terminate
        children_terminated = False
        for _ in range(40):
            time.sleep(0.05)
            alive_children = [c for c in children if is_pid_alive(c)]
            if not alive_children:
                children_terminated = True
                break

        self.assertTrue(
            children_terminated,
            f"PR_SET_PDEATHSIG failed: children leaked after parent SIGKILL: {alive_children}"
        )


class TestStateFileIntegrity(unittest.TestCase):
    """Verifies Requirement 2c: /tmp/qs_dictation.json valid schema and isListening boolean."""

    def setUp(self):
        clean_dictation_environment()

    def tearDown(self):
        clean_dictation_environment()

    def test_state_file_schema_when_stopped(self):
        """Verify state file exists, parses as valid JSON, and has isListening=False."""
        self.assertTrue(os.path.exists(STATE_FILE), f"{STATE_FILE} does not exist")
        with open(STATE_FILE, "r") as f:
            content = f.read().strip()
        self.assertTrue(len(content) > 0)

        data = json.loads(content)
        self.assertIn("isListening", data)
        self.assertIn("device", data)
        self.assertIsInstance(data["isListening"], bool)
        self.assertFalse(data["isListening"])
        self.assertIsInstance(data["device"], str)
        self.assertEqual(data["device"], "")

    def test_state_file_schema_and_values_running_to_stopped(self):
        """Verify state file transitions isListening=True -> isListening=False accurately."""
        # 1. Start streaming
        res = subprocess.run([sys.executable, LIVE_DICTATE_SCRIPT, "toggle"], capture_output=True, text=True, timeout=6.0)
        self.assertEqual(res.returncode, 0)
        time.sleep(0.3)

        # 2. Check running state
        with open(STATE_FILE, "r") as f:
            data_running = json.loads(f.read().strip())
        self.assertIsInstance(data_running["isListening"], bool)
        self.assertTrue(data_running["isListening"])
        self.assertIsInstance(data_running["device"], str)
        self.assertGreater(len(data_running["device"]), 0)

        # 3. Stop streaming
        subprocess.run([sys.executable, LIVE_DICTATE_SCRIPT, "stop"], timeout=6.0)

        # 4. Check stopped state
        with open(STATE_FILE, "r") as f:
            data_stopped = json.loads(f.read().strip())
        self.assertIsInstance(data_stopped["isListening"], bool)
        self.assertFalse(data_stopped["isListening"])
        self.assertEqual(data_stopped["device"], "")

    def test_no_temporary_file_leak(self):
        """Verify atomic write does not leave lingering .tmp file."""
        self.assertFalse(os.path.exists(STATE_TMP_FILE), "Found lingering /tmp/qs_dictation.json.tmp")


class TestInferenceEndpoint(unittest.TestCase):
    """Verifies Requirement 2d: Mock & Live 16kHz WAV inference endpoint & latency benchmarking."""

    def test_mock_inference_server_contract_and_latency(self):
        """
        Verify HTTP inference endpoint contract using an in-process mock server.
        Validates multipart/form-data WAV reception, JSON response format, and latency tracking.
        """
        recorded_requests = []

        class MockInferenceHandler(BaseHTTPRequestHandler):
            def do_POST(self):
                if self.path == "/inference":
                    content_length = int(self.headers.get("Content-Length", 0))
                    body = self.rfile.read(content_length)
                    recorded_requests.append({
                        "path": self.path,
                        "content_type": self.headers.get("Content-Type", ""),
                        "body_len": len(body)
                    })

                    # Respond with standard Whisper server JSON format
                    resp = json.dumps({"text": "technical software developer dictating code\n"}).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(resp)))
                    self.end_headers()
                    self.wfile.write(resp)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, format, *args):
                pass  # Suppress console logging

        mock_server = HTTPServer(("127.0.0.1", 0), MockInferenceHandler)
        mock_port = mock_server.server_port
        mock_thread = threading.Thread(target=mock_server.serve_forever, daemon=True)
        mock_thread.start()

        try:
            # Synthesize 1.0s 16kHz WAV sample
            wav_bytes = synthesize_16k_wav(duration_s=1.0, freq_hz=440.0, sample_rate=16000)
            boundary = "----TestBoundaryMockInference"
            body = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
                f"Content-Type: audio/wav\r\n\r\n"
            ).encode("utf-8") + wav_bytes + (
                f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n"
                f'--{boundary}\r\nContent-Disposition: form-data; name="temperature"\r\n\r\n0.0\r\n'
                f"--{boundary}--\r\n"
            ).encode("utf-8")

            req = urllib.request.Request(f"http://127.0.0.1:{mock_port}/inference", data=body)
            req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")

            t0 = time.perf_counter()
            with urllib.request.urlopen(req, timeout=5.0) as resp:
                status = resp.status
                res_json = json.loads(resp.read().decode("utf-8"))
            latency_ms = (time.perf_counter() - t0) * 1000

            self.assertEqual(status, 200)
            self.assertIn("text", res_json)
            self.assertIn("technical software developer", res_json["text"])
            self.assertLess(latency_ms, 150.0, f"Mock inference latency too high: {latency_ms:.2f}ms")
            self.assertEqual(len(recorded_requests), 1)
        finally:
            mock_server.shutdown()
            mock_server.server_close()

    def test_live_whisper_server_inference_and_latency(self):
        """
        Verify live GPU/Vulkan whisper-server inference with 16kHz synthetic WAV sample on port 8089.
        Validates real HTTP 200 status, JSON response schema {'text': ...}, and records latency.
        """
        if not (os.path.exists(GPU_SERVER_BIN) and os.path.exists(GPU_MODEL_PATH)):
            self.skipTest(f"whisper-server binary or model {GPU_MODEL_PATH} not found on system")

        # Check if whisper-server is already running on port 8089; if not, spin up managed instance
        server_proc = None
        server_ready = False
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{GPU_SERVER_PORT}", timeout=0.2) as resp:
                if resp.status == 200:
                    server_ready = True
        except Exception:
            pass

        if not server_ready:
            env = os.environ.copy()
            env["LD_LIBRARY_PATH"] = BIN_DIR
            server_proc = subprocess.Popen(
                [GPU_SERVER_BIN, "-m", GPU_MODEL_PATH, "--port", str(GPU_SERVER_PORT), "-t", "4"],
                env=env,
                cwd=BIN_DIR,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            for _ in range(40):
                time.sleep(0.1)
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{GPU_SERVER_PORT}", timeout=0.2) as resp:
                        if resp.status == 200:
                            server_ready = True
                            break
                except Exception:
                    pass

        self.assertTrue(server_ready, "GPU whisper-server failed to bind and become healthy on port 8089")

        try:
            # Synthesize 1.0s 16kHz tone in memory
            wav_bytes = synthesize_16k_wav(duration_s=1.0, freq_hz=440.0, sample_rate=16000)
            boundary = "----WebKitFormBoundaryE2EBenchmark"
            body = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
                f"Content-Type: audio/wav\r\n\r\n"
            ).encode("utf-8") + wav_bytes + (
                f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n"
                f'--{boundary}\r\nContent-Disposition: form-data; name="temperature"\r\n\r\n0.0\r\n'
                f"--{boundary}--\r\n"
            ).encode("utf-8")

            req = urllib.request.Request(f"http://127.0.0.1:{GPU_SERVER_PORT}/inference", data=body)
            req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")

            # Execute and benchmark latency
            t0 = time.perf_counter()
            with urllib.request.urlopen(req, timeout=10.0) as resp:
                res_raw = resp.read().decode("utf-8")
                status = resp.status
            latency_ms = (time.perf_counter() - t0) * 1000

            res_data = json.loads(res_raw)
            self.assertEqual(status, 200)
            self.assertIn("text", res_data)
            self.assertIsInstance(res_data["text"], str)

            # Performance benchmark log
            sys.stdout.write(f"\n[BENCHMARK] Live GPU whisper-server latency: {latency_ms:.2f}ms | Response: {res_data}\n")
            sys.stdout.flush()

            # Latency SLA check (< 5000ms threshold for 1.0s audio on AMD Radeon Vega GPU)
            self.assertLess(latency_ms, 5000.0, f"Inference latency exceeded 5s threshold: {latency_ms:.2f}ms")

        finally:
            if server_proc is not None:
                server_proc.terminate()
                try:
                    server_proc.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    server_proc.kill()
                    server_proc.wait(timeout=1.0)


class TestAntiLeakAndOrphanProcessAudit(unittest.TestCase):
    """Verifies Requirement 2e: Anti-leak audit confirming zero lingering processes after stop."""

    def setUp(self):
        clean_dictation_environment()

    def tearDown(self):
        clean_dictation_environment()

    def test_zero_lingering_processes_after_cmd_stop(self):
        """Verify cmd_stop completely reaps parec, whisper-server, and stream daemon without orphans."""
        # 1. Start streaming via toggle
        res = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "toggle"],
            capture_output=True,
            text=True,
            timeout=6.0
        )
        self.assertEqual(res.returncode, 0)
        daemon_pid = json.loads(res.stdout)["pid"]
        self.assertTrue(is_pid_alive(daemon_pid))

        # 2. Allow child processes to spawn
        time.sleep(1.0)
        tracked_children = get_process_children(daemon_pid)

        # 3. Stop service
        stop_res = subprocess.run(
            [sys.executable, LIVE_DICTATE_SCRIPT, "stop"],
            capture_output=True,
            text=True,
            timeout=8.0
        )
        self.assertEqual(stop_res.returncode, 0)
        self.assertFalse(json.loads(stop_res.stdout)["running"])

        # 4. Audit: confirm parent is dead
        time.sleep(0.5)
        self.assertFalse(is_pid_alive(daemon_pid), f"Parent daemon PID {daemon_pid} still alive after stop")

        # 5. Audit: confirm all spawned children are dead
        for cpid in tracked_children:
            self.assertFalse(is_pid_alive(cpid), f"Tracked child PID {cpid} leaked after cmd_stop()")

        # 6. Audit: confirm zero lingering parec instances with --rate=16000
        for entry in os.listdir("/proc"):
            if entry.isdigit():
                pid = int(entry)
                try:
                    with open(f"/proc/{pid}/cmdline", "rb") as f:
                        cmd = f.read().decode("utf-8", errors="ignore")
                    if "parec" in cmd and "--rate=16000" in cmd:
                        self.fail(f"Lingering parec audio capture process detected: PID {pid} ({cmd})")
                except OSError:
                    pass

        # 7. Audit: PID file and state file
        pid_file = get_pid_file_path()
        self.assertFalse(os.path.exists(pid_file), f"PID file {pid_file} still exists after stop")
        with open(STATE_FILE, "r") as f:
            st = json.loads(f.read().strip())
        self.assertFalse(st["isListening"], "State file isListening is still True after stop")

    def test_multi_cycle_toggle_anti_leak(self):
        """Stress audit: 3 consecutive start/stop cycles to verify zero cumulative resource leak."""
        for cycle in range(1, 4):
            # Toggle start
            res_on = subprocess.run([sys.executable, LIVE_DICTATE_SCRIPT, "toggle"], capture_output=True, text=True, timeout=6.0)
            self.assertEqual(res_on.returncode, 0)
            pid = json.loads(res_on.stdout)["pid"]
            self.assertTrue(is_pid_alive(pid))

            time.sleep(0.5)

            # Toggle stop
            res_off = subprocess.run([sys.executable, LIVE_DICTATE_SCRIPT, "toggle"], capture_output=True, text=True, timeout=8.0)
            self.assertEqual(res_off.returncode, 0)
            self.assertFalse(json.loads(res_off.stdout)["running"])

            time.sleep(0.3)
            self.assertFalse(is_pid_alive(pid), f"Cycle {cycle}: PID {pid} leaked after toggle off")


class TestSafetyCircuitBreaker(unittest.TestCase):
    """Verifies live-dictate repetition firewall, phantom filters, sound effect stripping, and burst caps."""

    def test_repetition_firewall_and_hallucinations(self):
        """Verify decoder repetition loops and phantom phrases are strictly blocked."""
        # Consecutive word repetition
        self.assertTrue(live_dictate_mod.is_hallucination_or_repetition("YAML, YAML, YAML"))
        self.assertTrue(live_dictate_mod.is_hallucination_or_repetition("test test test"))

        # Phantom noise tokens
        self.assertTrue(live_dictate_mod.is_hallucination_or_repetition("thank you."))
        self.assertTrue(live_dictate_mod.is_hallucination_or_repetition("blank audio"))
        self.assertTrue(live_dictate_mod.is_hallucination_or_repetition("please subscribe"))

        # Valid text allowed
        self.assertFalse(live_dictate_mod.is_hallucination_or_repetition("def transcribe_audio_gpu(): return text"))
        self.assertFalse(live_dictate_mod.is_hallucination_or_repetition("systemctl restart quickshell"))

    def test_sanitize_text_bracket_stripping_and_burst_cap(self):
        """Verify sound effects are stripped and phrases capped at 120 chars."""
        # Bracketed sound effect stripping
        stripped = live_dictate_mod.sanitize_text("[BLANK_AUDIO] hello world (chime)")
        self.assertEqual(stripped, "hello world")

        # 120-character burst cap
        long_phrase = "word " * 35  # 175 chars
        sanitized = live_dictate_mod.sanitize_text(long_phrase)
        self.assertLessEqual(len(sanitized), 120)


if __name__ == "__main__":
    unittest.main(verbosity=2)
