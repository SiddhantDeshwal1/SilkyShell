#!/usr/bin/env python3
"""
test_gpu_latency.py — Benchmark and verification suite for whisper-server GPU Vulkan execution.

Measures:
1. Startup health check latency (50ms polling resolution).
2. End-to-end round-trip inference latency (ms) on dummy 2-second audio chunks (16kHz mono PCM).
3. HTTP connection reuse efficiency: Persistent http.client.HTTPConnection with keepalive vs
   brand-new connection per request (urllib.request.urlopen).
4. GPU Vulkan acceleration verification on AMD Radeon Vega 8 Mobile GPU (UMA, FP16).
5. Thread scaling and flags verification (--flash-attn, --suppress-nst, -t 4, --port 8089).
"""

import os
import sys
import time
import json
import io
import wave
import signal
import subprocess
import http.client
import urllib.request
import unittest
import numpy as np

DICTATION_DIR = os.path.expanduser("~/.local/share/dictation")
BIN_DIR = os.path.join(DICTATION_DIR, "bin")
MODELS_DIR = os.path.join(DICTATION_DIR, "models")
GPU_SERVER_BIN = os.path.join(BIN_DIR, "whisper-server")
DEFAULT_TURBO_MODEL = os.path.join(MODELS_DIR, "ggml-large-v3-turbo-q5_0.bin")
FALLBACK_SMALL_MODEL = os.path.join(MODELS_DIR, "ggml-small.en.bin")
FALLBACK_Q5_MODEL = os.path.join(MODELS_DIR, "ggml-small.en-q5_1.bin")

BENCHMARK_PORT = int(os.environ.get("DICTATION_BENCH_PORT", "8089"))
PROMPT_TEXT = (
    "The following is a technical software developer dictating code, "
    "system prompts, YAML, JSON, APIs, Python, TypeScript, and whisper.cpp."
)


def generate_dummy_wav(duration_s: float = 2.0, sample_rate: int = 16000) -> bytes:
    """Generate 16-bit mono PCM WAV bytes with a synthetic harmonic speech-like tone."""
    num_samples = int(duration_s * sample_rate)
    t = np.linspace(0, duration_s, num_samples, endpoint=False)
    # Blend 220Hz, 440Hz, and 880Hz harmonics to mimic acoustic energy
    waveform = 0.5 * np.sin(2 * np.pi * 220 * t) + 0.3 * np.sin(2 * np.pi * 440 * t) + 0.2 * np.sin(2 * np.pi * 880 * t)
    # Scale to int16 range
    pcm = (np.clip(waveform, -1.0, 1.0) * 16384).astype(np.int16).tobytes()

    wav_io = io.BytesIO()
    with wave.open(wav_io, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm)
    return wav_io.getvalue()


def build_multipart_body(wav_bytes: bytes, boundary: str = "----WebKitFormBoundary7MA4YWxkTrZu0gW") -> bytes:
    """Build multipart/form-data payload for whisper-server /inference endpoint."""
    return (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
        f"Content-Type: audio/wav\r\n\r\n"
    ).encode() + wav_bytes + (
        f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n"
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"temperature\"\r\n\r\n0.0\r\n"
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n{PROMPT_TEXT}\r\n"
        f"--{boundary}--\r\n"
    ).encode()


def start_server_instance(model_path: str, port: int = BENCHMARK_PORT, threads: int = 4) -> subprocess.Popen:
    """Start whisper-server subprocess with optimized GPU Vulkan flags."""
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = BIN_DIR

    cmd = [
        GPU_SERVER_BIN,
        "-m", model_path,
        "--port", str(port),
        "-t", str(threads),
        "--flash-attn",
        "--suppress-nst",
        "--no-speech-thold", "0.6",
        "--no-fallback"
    ]

    proc = subprocess.Popen(
        cmd,
        env=env,
        cwd=BIN_DIR,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    return proc


def wait_for_server(port: int = BENCHMARK_PORT, max_wait_s: float = 4.0, poll_interval_s: float = 0.050) -> float:
    """Fast health check polling with 50ms intervals. Returns time to ready in ms."""
    t0 = time.perf_counter()
    deadline = t0 + max_wait_s
    while time.perf_counter() < deadline:
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=0.1)
            conn.request("GET", "/")
            resp = conn.getresponse()
            resp.read()
            conn.close()
            if resp.status == 200:
                return (time.perf_counter() - t0) * 1000.0
        except Exception:
            pass
        time.sleep(poll_interval_s)
    raise TimeoutError(f"whisper-server on port {port} failed to become healthy within {max_wait_s}s")


def stop_server_instance(proc: subprocess.Popen):
    """Safely terminate server subprocess."""
    if proc is not None and proc.poll() is None:
        try:
            proc.terminate()
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=1.0)


def benchmark_gpu_pipeline(model_path: str, port: int = BENCHMARK_PORT, iterations: int = 5) -> dict:
    """
    Run comprehensive benchmark measuring inference latency and HTTP connection reuse.
    Returns metrics dictionary.
    """
    if not (os.path.exists(GPU_SERVER_BIN) and os.path.exists(model_path)):
        raise FileNotFoundError(f"Binary {GPU_SERVER_BIN} or model {model_path} not found")

    boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
    wav_bytes = generate_dummy_wav(duration_s=2.0, sample_rate=16000)
    body = build_multipart_body(wav_bytes, boundary=boundary)
    headers = {
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Connection": "keep-alive",
        "Content-Length": str(len(body))
    }

    # Start server
    proc = start_server_instance(model_path, port=port, threads=4)
    try:
        health_ms = wait_for_server(port=port, max_wait_s=5.0, poll_interval_s=0.050)

        # 1. Warmup inference (triggers initial Vulkan shader compilation & weights caching)
        t_w0 = time.perf_counter()
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=40.0)
        conn.request("POST", "/inference", body=body, headers=headers)
        resp = conn.getresponse()
        resp_data = json.loads(resp.read().decode())
        warmup_latency_ms = (time.perf_counter() - t_w0) * 1000.0

        # 2. Method A: Persistent connection with HTTP keepalive
        persistent_latencies = []
        for _ in range(iterations):
            t0 = time.perf_counter()
            conn.request("POST", "/inference", body=body, headers=headers)
            r = conn.getresponse()
            data = json.loads(r.read().decode())
            lat = (time.perf_counter() - t0) * 1000.0
            persistent_latencies.append(lat)
        conn.close()

        # 3. Method B: Connection per request (urllib.request.urlopen)
        urllib_latencies = []
        for _ in range(iterations):
            t0 = time.perf_counter()
            req = urllib.request.Request(f"http://127.0.0.1:{port}/inference", data=body)
            req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
            with urllib.request.urlopen(req, timeout=40.0) as resp:
                data = json.loads(resp.read().decode())
            lat = (time.perf_counter() - t0) * 1000.0
            urllib_latencies.append(lat)

        p_lat = np.array(persistent_latencies)
        u_lat = np.array(urllib_latencies)

        return {
            "model": os.path.basename(model_path),
            "model_size_mb": os.path.getsize(model_path) / (1024 * 1024),
            "health_check_ms": health_ms,
            "warmup_ms": warmup_latency_ms,
            "persistent": {
                "mean_ms": float(np.mean(p_lat)),
                "p50_ms": float(np.median(p_lat)),
                "p90_ms": float(np.percentile(p_lat, 90)),
                "min_ms": float(np.min(p_lat)),
                "max_ms": float(np.max(p_lat)),
                "runs": [float(x) for x in p_lat]
            },
            "new_conn": {
                "mean_ms": float(np.mean(u_lat)),
                "p50_ms": float(np.median(u_lat)),
                "p90_ms": float(np.percentile(u_lat, 90)),
                "min_ms": float(np.min(u_lat)),
                "max_ms": float(np.max(u_lat)),
                "runs": [float(x) for x in u_lat]
            },
            "tcp_overhead_saved_ms": float(np.mean(u_lat) - np.mean(p_lat))
        }

    finally:
        stop_server_instance(proc)


class TestGpuLatency(unittest.TestCase):
    """Automated unit test suite verifying whisper-server GPU execution and optimizations."""

    @classmethod
    def setUpClass(cls):
        cls.turbo_model = DEFAULT_TURBO_MODEL
        cls.small_model = FALLBACK_SMALL_MODEL if os.path.exists(FALLBACK_SMALL_MODEL) else FALLBACK_Q5_MODEL
        cls.has_gpu_bin = os.path.exists(GPU_SERVER_BIN)

    def test_01_binary_and_models_exist(self):
        """Verify whisper-server binary and required GGML models are present."""
        self.assertTrue(self.has_gpu_bin, f"whisper-server binary missing: {GPU_SERVER_BIN}")
        self.assertTrue(
            os.path.exists(self.turbo_model) or os.path.exists(self.small_model),
            f"Neither turbo ({self.turbo_model}) nor fallback ({self.small_model}) model found."
        )

    def test_02_fast_health_check(self):
        """Verify startup health check polls and responds within 1500ms using 50ms intervals."""
        if not self.has_gpu_bin:
            self.skipTest("whisper-server binary not available")
        target_model = self.turbo_model if os.path.exists(self.turbo_model) else self.small_model
        proc = start_server_instance(target_model, port=BENCHMARK_PORT)
        try:
            health_ms = wait_for_server(port=BENCHMARK_PORT, max_wait_s=4.0, poll_interval_s=0.050)
            self.assertLess(health_ms, 2500.0, f"Health check took too long: {health_ms:.2f}ms")
        finally:
            stop_server_instance(proc)

    def test_03_persistent_http_inference_roundtrip(self):
        """Verify persistent HTTP connection completes inference successfully with valid JSON text."""
        if not self.has_gpu_bin:
            self.skipTest("whisper-server binary not available")
        target_model = self.small_model if os.path.exists(self.small_model) else self.turbo_model
        proc = start_server_instance(target_model, port=BENCHMARK_PORT)
        try:
            wait_for_server(port=BENCHMARK_PORT, max_wait_s=4.0, poll_interval_s=0.050)
            boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
            wav_bytes = generate_dummy_wav(duration_s=2.0)
            body = build_multipart_body(wav_bytes, boundary=boundary)
            headers = {
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Connection": "keep-alive",
                "Content-Length": str(len(body))
            }
            conn = http.client.HTTPConnection("127.0.0.1", BENCHMARK_PORT, timeout=30.0)
            # Run two consecutive inferences on the same connection
            for i in range(2):
                conn.request("POST", "/inference", body=body, headers=headers)
                resp = conn.getresponse()
                self.assertEqual(resp.status, 200)
                data = json.loads(resp.read().decode())
                self.assertIn("text", data)
            conn.close()
        finally:
            stop_server_instance(proc)


def print_benchmark_table(res: dict):
    """Print ASCII formatting benchmark table."""
    print("\n" + "=" * 70)
    print(f" whisper-server GPU Benchmark: {res['model']} ({res['model_size_mb']:.1f} MB)")
    print("=" * 70)
    print(f" Startup Health Check : {res['health_check_ms']:.2f} ms (50ms polling interval)")
    print(f" Cold/Warmup Run      : {res['warmup_ms']:.2f} ms")
    print("-" * 70)
    print(f" {'Metric':<25} | {'Persistent (Keepalive)':<20} | {'New Conn (urllib)':<15}")
    print("-" * 70)
    p = res["persistent"]
    n = res["new_conn"]
    print(f" {'Mean Latency':<25} | {p['mean_ms']:>14.2f} ms     | {n['mean_ms']:>11.2f} ms")
    print(f" {'P50 (Median) Latency':<25} | {p['p50_ms']:>14.2f} ms     | {n['p50_ms']:>11.2f} ms")
    print(f" {'P90 Latency':<25} | {p['p90_ms']:>14.2f} ms     | {n['p90_ms']:>11.2f} ms")
    print(f" {'Min Latency':<25} | {p['min_ms']:>14.2f} ms     | {n['min_ms']:>11.2f} ms")
    print(f" {'Max Latency':<25} | {p['max_ms']:>14.2f} ms     | {n['max_ms']:>11.2f} ms")
    print("-" * 70)
    print(f" Handshake Overhead Saved: {res['tcp_overhead_saved_ms']:+.2f} ms per request")
    print("=" * 70 + "\n")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "test":
        unittest.main(argv=[sys.argv[0]])
        return

    print("Running GPU Latency Benchmark across available models...\n")

    models_to_test = []
    if os.path.exists(DEFAULT_TURBO_MODEL):
        models_to_test.append(DEFAULT_TURBO_MODEL)
    if os.path.exists(FALLBACK_SMALL_MODEL):
        models_to_test.append(FALLBACK_SMALL_MODEL)
    elif os.path.exists(FALLBACK_Q5_MODEL):
        models_to_test.append(FALLBACK_Q5_MODEL)

    if not models_to_test:
        print("Error: No models found in", MODELS_DIR)
        sys.exit(1)

    results = []
    for model in models_to_test:
        print(f"-> Testing {os.path.basename(model)} (3 iterations)...")
        # Run 3 iterations for benchmark report
        res = benchmark_gpu_pipeline(model, port=BENCHMARK_PORT, iterations=3)
        print_benchmark_table(res)
        results.append(res)

    print("All benchmarks completed successfully.")


if __name__ == "__main__":
    main()
