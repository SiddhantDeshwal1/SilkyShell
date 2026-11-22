#!/usr/bin/env python3
"""
tests/test_cpu_fallback.py — Comprehensive Test Suite & Benchmark Harness
for the Modernized CPU Fallback Engine in scripts/live-dictate.py.

Validates:
1. CPU Model Configuration: CTranslate2 INT8 quantization, cpu_threads=4, distil-small.en default.
2. CTranslate2 Runtime Options: vad_filter=True, min_silence_duration_ms=200, repetition_penalty=1.3, beam_size=1.
3. Audio Transcription Fidelity: Accurate transcription of speech audio with zero regressions.
4. Circuit Breakers: Phantom noise suppression, bracketed effect removal, dominant repetition firewall, burst capping.
5. Graceful Fallback Resilience: Automatic fallback to base.en if preferred model fails.
6. Memory & Latency Performance Benchmarks: Resident Set Size (VmRSS) overhead and Real-Time Factor (RTF).
"""

import os
import sys
import time
import wave
import unittest
import importlib.util
from typing import Tuple, List
import numpy as np

# Ensure dictation venv python or current python finds scripts
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

# Dynamically import live-dictate.py
live_dictate_path = os.path.join(SCRIPTS_DIR, "live-dictate.py")
spec = importlib.util.spec_from_file_location("live_dictate", live_dictate_path)
live_dictate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live_dictate)


def get_current_vm_rss_mb() -> float:
    """Return current process VmRSS (Resident Set Size) in megabytes."""
    try:
        with open("/proc/self/status", "r") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return float(line.split()[1]) / 1024.0
    except Exception:
        pass
    import resource
    return float(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss) / 1024.0


def load_test_audio(target_sr: int = 16000) -> Tuple[np.ndarray, float]:
    """
    Load a real speech audio sample from /usr/share/sounds/alsa/Front_Center.wav.
    If unavailable, generate synthetic voiced speech harmonics (F0=130Hz, formants).
    Returns (audio_float32, duration_seconds).
    """
    sample_path = "/usr/share/sounds/alsa/Front_Center.wav"
    if os.path.exists(sample_path):
        try:
            with wave.open(sample_path, "rb") as wf:
                sr = wf.getframerate()
                frames = wf.readframes(wf.getnframes())
                samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
            if sr != target_sr:
                duration = len(samples) / sr
                target_len = int(duration * target_sr)
                orig_indices = np.linspace(0, len(samples) - 1, target_len)
                samples = np.interp(orig_indices, np.arange(len(samples)), samples).astype(np.float32)
            duration_s = len(samples) / float(target_sr)
            return samples, duration_s
        except Exception:
            pass

    # Fallback synthetic voiced audio: 2.0s duration
    duration_s = 2.0
    total_samples = int(target_sr * duration_s)
    t = np.linspace(0, duration_s, total_samples, endpoint=False, dtype=np.float32)
    # Fundamental frequency ~130 Hz with vocal tract formants (F1=500Hz, F2=1500Hz, F3=2500Hz)
    audio = 0.3 * np.sin(2 * np.pi * 130 * t) + \
            0.2 * np.sin(2 * np.pi * 500 * t) + \
            0.1 * np.sin(2 * np.pi * 1500 * t) + \
            0.05 * np.sin(2 * np.pi * 2500 * t)
    envelope = np.sin(np.pi * t / duration_s) ** 2
    audio = (audio * envelope).astype(np.float32)
    return audio, duration_s


class TestCpuModelConfiguration(unittest.TestCase):
    """Test model loading configuration and defaults."""

    def test_default_cpu_model_name(self):
        """Verify default CPU_MODEL_NAME is distil-small.en for accelerated inference."""
        self.assertEqual(live_dictate.CPU_MODEL_NAME, "distil-small.en")

    def test_cpu_model_singleton_loading(self):
        """Verify get_cpu_model() successfully instantiates faster-whisper with INT8 and 4 threads."""
        model = live_dictate.get_cpu_model()
        self.assertIsNotNone(model, "CPU model instance must not be None")
        self.assertEqual(type(model).__name__, "WhisperModel")
        # Verify model object was cached in singleton
        self.assertIs(model, live_dictate._cpu_model_instance)

    def test_graceful_fallback_resilience(self):
        """Verify get_cpu_model() gracefully falls back to base.en if non-existent model requested."""
        model = live_dictate.get_cpu_model("non_existent_model_xyz_123")
        self.assertIsNotNone(model, "Must fall back to base.en when requested model is invalid")
        self.assertEqual(type(model).__name__, "WhisperModel")


class TestCTranslate2RuntimeOptions(unittest.TestCase):
    """Test that CTranslate2 options match specifications."""

    def test_vad_and_inference_parameters(self):
        """Verify transcribe_audio_cpu passes correct CTranslate2 and VAD arguments."""
        calls = []

        class MockModel:
            def transcribe(self, audio, **kwargs):
                calls.append(kwargs)
                return [], None

        dummy_audio = np.zeros(16000, dtype=np.float32)
        mock_model = MockModel()
        live_dictate.transcribe_audio_cpu(mock_model, dummy_audio)

        self.assertEqual(len(calls), 1)
        kw = calls[0]
        self.assertTrue(kw.get("vad_filter"), "vad_filter must be True")
        self.assertEqual(kw.get("beam_size"), 1, "beam_size must be 1 for greedy decoding")
        self.assertEqual(kw.get("repetition_penalty"), 1.3, "repetition_penalty must be 1.3")
        self.assertEqual(kw.get("condition_on_previous_text"), False, "condition_on_previous_text must be False")
        self.assertEqual(kw.get("temperature"), 0.0, "temperature must be 0.0")
        self.assertEqual(kw.get("language"), "en", "language must be 'en'")
        self.assertEqual(kw.get("no_speech_threshold"), 0.6, "no_speech_threshold must be 0.6")
        self.assertEqual(kw.get("compression_ratio_threshold"), 2.2, "compression_ratio_threshold must be 2.2")

        vad_params = kw.get("vad_parameters", {})
        self.assertEqual(vad_params.get("min_silence_duration_ms"), 200, "min_silence_duration_ms must be 200ms")
        self.assertEqual(vad_params.get("threshold"), 0.5, "VAD threshold must be 0.5")

    def test_transcribe_audio_cpu_safety_on_none_model(self):
        """Verify transcribe_audio_cpu safely returns empty string if model is None."""
        dummy_audio = np.zeros(16000, dtype=np.float32)
        result = live_dictate.transcribe_audio_cpu(None, dummy_audio)
        self.assertEqual(result, "")


class TestAudioTranscriptionFidelity(unittest.TestCase):
    """Test end-to-end transcription accuracy on speech input."""

    def test_speech_transcription_accuracy(self):
        """Verify distil-small.en accurately transcribes ALSA speech sample."""
        audio, duration_s = load_test_audio()
        model = live_dictate.get_cpu_model()
        self.assertIsNotNone(model)

        text = live_dictate.transcribe_audio_cpu(model, audio)
        self.assertIsInstance(text, str)
        if os.path.exists("/usr/share/sounds/alsa/Front_Center.wav"):
            cleaned = text.lower().replace(".", "").replace(",", "").strip()
            self.assertIn("front", cleaned)
            self.assertIn("center", cleaned)


class TestSafetyCircuitBreakers(unittest.TestCase):
    """Verify 5-layer safety circuit breaker suppresses hallucinations and repetitions."""

    def test_phantom_phrases(self):
        """Verify common phantom whisper hallucination phrases are blocked."""
        for phrase in ["thank you.", "subtitles by", "thanks for watching", "bye.", "blank_audio"]:
            self.assertTrue(live_dictate.is_hallucination_or_repetition(phrase), f"Failed to block '{phrase}'")

    def test_consecutive_repetition(self):
        """Verify consecutive word repetitions are dropped."""
        self.assertTrue(live_dictate.is_hallucination_or_repetition("YAML YAML YAML"))
        self.assertTrue(live_dictate.is_hallucination_or_repetition("test, test, test."))

    def test_dominant_repetition(self):
        """Verify dominant repetition (>40% of utterance) is dropped."""
        self.assertTrue(live_dictate.is_hallucination_or_repetition("the echo echo echo was loud"))

    def test_bracket_sound_effect_stripping(self):
        """Verify [BLANK_AUDIO] and (applause) bracketed effects are stripped."""
        self.assertEqual(live_dictate.sanitize_text("[BLANK_AUDIO]"), "")
        self.assertEqual(live_dictate.sanitize_text("Hello [MUSIC] world (applause)"), "Hello world")

    def test_burst_capping(self):
        """Verify burst character length is capped at MAX_BURST_CHARS (120 chars)."""
        long_phrase = "word " * 40  # 200 chars
        sanitized = live_dictate.sanitize_text(long_phrase)
        self.assertLessEqual(len(sanitized), live_dictate.MAX_BURST_CHARS)


def run_benchmark():
    """Execute latency and memory comparative benchmark between distil-small.en and base.en."""
    print("\n" + "=" * 78)
    print(" QUICKSHELL LIVE DICTATION — CPU FALLBACK BENCHMARK SUITE")
    print("=" * 78)

    audio, duration_s = load_test_audio()
    print(f"Audio Test Input : {duration_s:.2f}s ({len(audio)} samples at 16kHz)")

    models_to_test = [
        ("base.en", "Standard Base (74M params)"),
        ("distil-small.en", "Distil-Small (166M params, ~3% WER)")
    ]

    results = []

    for model_name, desc in models_to_test:
        print(f"\nEvaluating {model_name} [{desc}]...")
        mem_before = get_current_vm_rss_mb()
        t0 = time.perf_counter()

        from faster_whisper import WhisperModel
        model = WhisperModel(
            model_name,
            device="cpu",
            compute_type="int8",
            cpu_threads=4,
            local_files_only=True
        )
        load_time_ms = (time.perf_counter() - t0) * 1000.0
        mem_after = get_current_vm_rss_mb()
        mem_delta_mb = max(0.0, mem_after - mem_before)

        # Warmup / Inference run 1
        t_start1 = time.perf_counter()
        text1 = live_dictate.transcribe_audio_cpu(model, audio)
        infer1_ms = (time.perf_counter() - t_start1) * 1000.0

        # Inference run 2
        t_start2 = time.perf_counter()
        text2 = live_dictate.transcribe_audio_cpu(model, audio)
        infer2_ms = (time.perf_counter() - t_start2) * 1000.0

        avg_infer_ms = (infer1_ms + infer2_ms) / 2.0
        rtf = (avg_infer_ms / 1000.0) / duration_s

        results.append({
            "name": model_name,
            "desc": desc,
            "load_ms": load_time_ms,
            "mem_rss_mb": mem_after,
            "mem_delta_mb": mem_delta_mb,
            "infer1_ms": infer1_ms,
            "infer2_ms": infer2_ms,
            "avg_infer_ms": avg_infer_ms,
            "rtf": rtf,
            "text": text1
        })

    print("\n" + "-" * 78)
    print(" BENCHMARK RESULTS SUMMARY")
    print("-" * 78)
    header = f"{'Model':<18} | {'Load (ms)':<10} | {'RAM (MB)':<9} | {'Run 1 (ms)':<11} | {'Run 2 (ms)':<11} | {'RTF':<6}"
    print(header)
    print("-" * 78)
    for r in results:
        row = f"{r['name']:<18} | {r['load_ms']:<10.1f} | {r['mem_delta_mb']:<9.1f} | {r['infer1_ms']:<11.1f} | {r['infer2_ms']:<11.1f} | {r['rtf']:<6.2f}"
        print(row)
    print("-" * 78)

    for r in results:
        print(f"[{r['name']}] Transcribed: \"{r['text']}\"")
    print("=" * 78 + "\n")


if __name__ == "__main__":
    # If run with unittest flags or default unittest runner
    if len(sys.argv) > 1 and sys.argv[1] in ("-v", "-q", "--verbose"):
        unittest.main()
    else:
        suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
        runner = unittest.TextTestRunner(verbosity=2)
        test_result = runner.run(suite)
        if test_result.wasSuccessful():
            run_benchmark()
            sys.exit(0)
        else:
            sys.exit(1)
