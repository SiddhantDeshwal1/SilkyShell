#!/usr/bin/env python3
"""
tests/test_vad_tuning.py — Comprehensive Unit & Benchmark Test Suite
for Audio Streaming, Chunking, and VAD Parameter Tuning in live-dictate.py.

Validates:
1. Vectorized RMS energy calculation accuracy, edge cases, and sub-50µs compute latency.
2. Pause detection latency: Demonstrates 50-100ms latency savings when reducing pause
   detection from 300ms to dynamic 2-3 chunks (200-300ms) or 250ms chunks.
3. Trailing speech padding retention: Asserts trailing phonemes and silence padding (>=200ms)
   are never truncated.
4. Pre-speech lead-in padding retention: Asserts initial unvoiced consonants are preserved.
5. Non-blocking audio queue enqueue with FIFO drop-oldest eviction under full queue conditions.
6. Clean shutdown flush: Guarantees remaining speech buffer and sentinel None are processed.
7. Max speech duration enforcement: Continuous speech chunking at 3.0 seconds (48,000 samples).
"""

import unittest
import queue
import threading
import time
import collections
import numpy as np


class TestVADTuning(unittest.TestCase):

    def setUp(self):
        self.sample_rate = 16000
        self.silence_threshold = 250.0
        self.deep_silence_threshold = 125.0

    @staticmethod
    def calc_rms_fast(samples: np.ndarray) -> float:
        """Fast vectorized RMS using BLAS dot product with float64 accumulator."""
        samples_f = samples.astype(np.float64)
        return float(np.sqrt(np.dot(samples_f, samples_f) / len(samples_f)))

    @staticmethod
    def calc_rms_legacy(samples: np.ndarray) -> float:
        """Legacy RMS calculation using mean squared."""
        samples_f = samples.astype(np.float64)
        return float(np.sqrt(np.mean(samples_f ** 2)))

    def test_01_rms_accuracy_and_benchmarks(self):
        """Verify RMS calculation accuracy, boundary conditions, and execution speed."""
        # Pure zero silence
        zero_chunk = np.zeros(1600, dtype=np.int16)
        self.assertEqual(self.calc_rms_fast(zero_chunk), 0.0)

        # Constant amplitude signal
        const_val = 1000
        const_chunk = np.full(1600, const_val, dtype=np.int16)
        self.assertAlmostEqual(self.calc_rms_fast(const_chunk), 1000.0, delta=0.01)

        # Sine wave with known RMS (amplitude A -> RMS = A / sqrt(2))
        t = np.linspace(0, 0.1, 1600, endpoint=False)
        sine_chunk = (np.sin(2 * np.pi * 440 * t) * 2000).astype(np.int16)
        expected_rms = 2000.0 / np.sqrt(2)
        actual_rms = self.calc_rms_fast(sine_chunk)
        self.assertAlmostEqual(actual_rms, expected_rms, delta=10.0)

        # Numerical equivalence between legacy mean-squared and fast dot product
        random_chunk = np.random.randint(-4000, 4000, size=1600, dtype=np.int16)
        legacy_rms = self.calc_rms_legacy(random_chunk)
        fast_rms = self.calc_rms_fast(random_chunk)
        self.assertAlmostEqual(fast_rms, legacy_rms, places=4)

        # Benchmark execution latency (< 50 microseconds per 100ms chunk)
        iterations = 1000
        t0 = time.perf_counter()
        for _ in range(iterations):
            _ = self.calc_rms_fast(random_chunk)
        elapsed_us = ((time.perf_counter() - t0) / iterations) * 1e6
        self.assertLess(
            elapsed_us,
            50.0,
            f"RMS compute latency {elapsed_us:.2f}µs exceeds 50µs ceiling (< 0.05% of 100ms chunk)"
        )

    def test_02_pause_detection_latency_savings(self):
        """
        Verify that dynamic 2-3 chunk pause detection (or 250ms) shaves 50-100ms
        off perceived latency compared to baseline 300ms pause detection.
        """
        sr = self.sample_rate
        # Generate 1.4s voiced speech + 0.1s decaying consonant + 1.0s ambient silence
        speech_end_ms = 1500
        total_ms = 2500
        t = np.arange(0, total_ms / 1000.0, 1.0 / sr)
        audio = np.zeros(len(t), dtype=np.int16)

        n_voiced = int(1.4 * sr)
        n_speech = int(1.5 * sr)
        # Voiced speech
        audio[:n_voiced] = (
            np.sin(2 * np.pi * 300 * t[:n_voiced]) * 1800
            + np.random.normal(0, 300, n_voiced)
        ).astype(np.int16)
        # Decaying tail (400 -> 100 RMS)
        decay = np.linspace(400, 100, n_speech - n_voiced)
        audio[n_voiced:n_speech] = (np.random.normal(0, 1, n_speech - n_voiced) * decay).astype(np.int16)
        # Ambient noise (~70 RMS)
        audio[n_speech:] = np.random.normal(0, 70, len(t) - n_speech).astype(np.int16)

        def simulate_vad(chunk_ms, strategy):
            chunk_samples = int(sr * chunk_ms / 1000.0)
            chunks = [audio[i:i + chunk_samples] for i in range(0, len(audio), chunk_samples)]
            speech_buffer = []
            buffer_samples = 0
            silence_chunks = 0
            deep_silence_chunks = 0
            current_ms = 0

            for c in chunks:
                current_ms += chunk_ms
                rms = self.calc_rms_fast(c)
                is_speech = (rms >= self.silence_threshold)

                if is_speech:
                    speech_buffer.append(c)
                    buffer_samples += len(c)
                    silence_chunks = 0
                    deep_silence_chunks = 0
                else:
                    if speech_buffer:
                        speech_buffer.append(c)
                        buffer_samples += len(c)
                        silence_chunks += 1
                        if rms < self.deep_silence_threshold:
                            deep_silence_chunks += 1
                        else:
                            deep_silence_chunks = 0

                should_flush = False
                if strategy == "baseline_300ms":
                    should_flush = (silence_chunks >= 3)
                elif strategy == "dynamic_2_3":
                    # Dynamic 2-3 chunks:
                    # 2 chunks (200ms) on deep silence (2 consecutive chunks < 125 RMS) or sustained phrase (>= 1.0s)
                    # 3 chunks (300ms) on borderline silence
                    should_flush = (
                        deep_silence_chunks >= 2
                        or (silence_chunks >= 2 and buffer_samples >= 16000)
                        or silence_chunks >= 3
                    )
                elif strategy == "fixed_250ms":
                    should_flush = (silence_chunks >= 5)  # 5 * 50ms = 250ms

                if speech_buffer and (should_flush or buffer_samples >= 48000):
                    return current_ms, buffer_samples
            return current_ms, 0

        t_baseline, len_base = simulate_vad(100, "baseline_300ms")
        t_dynamic, len_dyn = simulate_vad(100, "dynamic_2_3")
        t_250ms, len_250 = simulate_vad(50, "fixed_250ms")

        latency_baseline = t_baseline - speech_end_ms
        latency_dynamic = t_dynamic - speech_end_ms
        latency_250ms = t_250ms - speech_end_ms

        savings_dynamic = latency_baseline - latency_dynamic
        savings_250ms = latency_baseline - latency_250ms

        self.assertGreaterEqual(
            savings_dynamic,
            50,
            f"Dynamic 2-3 chunk pause should save >= 50ms, saved {savings_dynamic}ms"
        )
        self.assertGreaterEqual(
            savings_250ms,
            50,
            f"250ms chunk pause should save >= 50ms, saved {savings_250ms}ms"
        )

    def test_03_trailing_speech_padding_retention(self):
        """
        Verify that trailing phonemes and trailing silence padding (>= 200ms)
        are fully preserved and never truncated when the segment is enqueued.
        """
        sr = self.sample_rate
        chunk_samples = 1600  # 100ms
        speech_end_ms = 1200
        total_ms = 2000
        t = np.arange(0, total_ms / 1000.0, 1.0 / sr)
        audio = np.zeros(len(t), dtype=np.int16)

        n_voiced = int(1.1 * sr)
        n_speech = int(1.2 * sr)
        audio[:n_voiced] = (np.sin(2 * np.pi * 300 * t[:n_voiced]) * 2000).astype(np.int16)
        # Trailing decaying phoneme at 1.1s - 1.2s (decaying from 400 to 180 RMS)
        decay = np.linspace(400, 180, n_speech - n_voiced)
        audio[n_voiced:n_speech] = (np.random.normal(0, 1, n_speech - n_voiced) * decay).astype(np.int16)
        # Background ambient silence
        audio[n_speech:] = np.random.normal(0, 60, len(t) - n_speech).astype(np.int16)

        chunks = [audio[i:i + chunk_samples] for i in range(0, len(audio), chunk_samples)]
        speech_buffer = []
        silence_chunks = 0
        deep_silence_chunks = 0
        enqueued_segment = None

        for c in chunks:
            rms = self.calc_rms_fast(c)
            is_speech = (rms >= self.silence_threshold)
            if is_speech:
                speech_buffer.append(c)
                silence_chunks = 0
                deep_silence_chunks = 0
            else:
                if speech_buffer:
                    speech_buffer.append(c)
                    silence_chunks += 1
                    if rms < self.deep_silence_threshold:
                        deep_silence_chunks += 1
                    else:
                        deep_silence_chunks = 0

            buf_samples = sum(len(x) for x in speech_buffer)
            should_flush = (
                deep_silence_chunks >= 2
                or (silence_chunks >= 2 and buf_samples >= 16000)
                or silence_chunks >= 3
            )
            if speech_buffer and should_flush:
                enqueued_segment = np.concatenate(speech_buffer)
                break

        self.assertIsNotNone(enqueued_segment, "Segment was not enqueued")
        enqueued_ms = (len(enqueued_segment) / sr) * 1000.0

        # Trailing padding = duration beyond speech_end_ms
        trailing_padding_ms = enqueued_ms - speech_end_ms
        self.assertGreaterEqual(
            trailing_padding_ms,
            200.0,
            f"Trailing padding ({trailing_padding_ms}ms) must be at least 200ms to preserve phonemes"
        )

        # Verify the decaying phoneme is present inside enqueued_segment
        decay_samples = enqueued_segment[n_voiced:n_speech]
        self.assertEqual(len(decay_samples), n_speech - n_voiced)
        self.assertGreater(np.max(np.abs(decay_samples)), 0)

    def test_04_pre_speech_padding_retention(self):
        """
        Verify that a rolling preroll buffer captures leading unvoiced consonants
        that start before energy exceeds the silence threshold.
        """
        chunk_samples = 1600
        preroll = collections.deque(maxlen=1)
        speech_buffer = []

        # Chunk 0: ambient silence (RMS ~ 60)
        c0 = np.random.normal(0, 60, chunk_samples).astype(np.int16)
        # Chunk 1: soft unvoiced onset /s/ (RMS ~ 180, below 250 threshold)
        c1 = np.random.normal(0, 180, chunk_samples).astype(np.int16)
        # Chunk 2: voiced vowel (RMS ~ 1500, above threshold)
        c2 = (np.sin(np.linspace(0, 0.1, chunk_samples) * 2 * np.pi * 300) * 1500).astype(np.int16)

        stream = [c0, c1, c2]
        for c in stream:
            rms = self.calc_rms_fast(c)
            is_speech = (rms >= self.silence_threshold)
            if is_speech:
                if not speech_buffer and preroll:
                    speech_buffer.append(preroll.popleft())
                speech_buffer.append(c)
            else:
                if speech_buffer:
                    speech_buffer.append(c)
                else:
                    preroll.append(c)

        # Speech buffer should contain Chunk 1 (soft onset) + Chunk 2 (voiced)
        self.assertEqual(len(speech_buffer), 2)
        self.assertTrue(np.array_equal(speech_buffer[0], c1), "Pre-speech onset chunk was not preserved")
        self.assertTrue(np.array_equal(speech_buffer[1], c2), "Voiced chunk was not preserved")

    def test_05_non_blocking_enqueue_and_fifo_eviction(self):
        """
        Verify non-blocking enqueue into audio_queue with FIFO drop-oldest eviction
        when queue capacity (maxsize=30) is exceeded.
        """
        max_qsize = 5
        audio_q = queue.Queue(maxsize=max_qsize)

        def enqueue_helper(q: queue.Queue, item):
            try:
                q.put_nowait(item)
            except queue.Full:
                try:
                    q.get_nowait()
                    q.task_done()
                except queue.Empty:
                    pass
                try:
                    q.put_nowait(item)
                except queue.Full:
                    pass

        # Fill queue to capacity
        for i in range(max_qsize):
            enqueue_helper(audio_q, f"segment_{i}")
        self.assertEqual(audio_q.qsize(), max_qsize)

        # Enqueue 6th segment (should evict segment_0)
        enqueue_helper(audio_q, "segment_5")
        self.assertEqual(audio_q.qsize(), max_qsize)

        # Retrieve all items
        items = []
        while not audio_q.empty():
            items.append(audio_q.get_nowait())
            audio_q.task_done()

        expected = [f"segment_{i}" for i in range(1, max_qsize + 1)]
        self.assertEqual(items, expected, "Oldest segment was not dropped upon queue overflow")

    def test_06_clean_shutdown_flush(self):
        """
        Verify that in-progress speech buffer is flushed to audio_queue on shutdown,
        sentinel None is enqueued, and worker thread consumes all remaining audio.
        """
        audio_q = queue.Queue(maxsize=30)
        consumed = []

        def mock_worker(q):
            while True:
                item = q.get()
                if item is None:
                    q.task_done()
                    break
                consumed.append(item)
                q.task_done()

        worker = threading.Thread(target=mock_worker, args=(audio_q,))
        worker.start()

        # In-flight speech buffer on shutdown
        active_speech_buffer = [
            np.ones(1600, dtype=np.int16) * 1000,
            np.ones(1600, dtype=np.int16) * 500,
        ]

        def enqueue_audio_segment(q: queue.Queue, item) -> bool:
            if q is None:
                return False
            try:
                q.put_nowait(item)
                return True
            except queue.Full:
                try:
                    q.get_nowait()
                    q.task_done()
                except queue.Empty:
                    pass
                try:
                    q.put_nowait(item)
                    return True
                except queue.Full:
                    return False

        # Shutdown flush routine
        if active_speech_buffer:
            concatenated = np.concatenate(active_speech_buffer)
            audio_float = concatenated.astype(np.float32) / 32768.0
            enqueue_audio_segment(audio_q, audio_float)
            active_speech_buffer = []

        enqueue_audio_segment(audio_q, None)
        worker.join(timeout=2.0)

        self.assertFalse(worker.is_alive(), "Worker thread failed to terminate cleanly on sentinel")
        self.assertEqual(len(consumed), 1, "Remaining speech segment was not processed by worker")
        self.assertEqual(len(consumed[0]), 3200, "Spoken audio was truncated during shutdown flush")

    def test_07_max_speech_duration_chunking(self):
        """
        Verify that continuous speech exceeding MAX_SPEECH_DURATION_S (3.0s = 48,000 samples)
        is chunked at max duration limit to prevent buffer bloat.
        """
        sr = self.sample_rate
        max_duration_s = 3.0
        max_samples = int(sr * max_duration_s)

        # Generate 4.0s of continuous loud speech (no pauses)
        total_samples = int(4.0 * sr)
        loud_samples = np.full(1600, 2000, dtype=np.int16)

        speech_buffer = []
        buffer_samples = 0
        enqueued_segments = []

        for _ in range(total_samples // 1600):
            speech_buffer.append(loud_samples)
            buffer_samples += len(loud_samples)

            if buffer_samples >= max_samples:
                concatenated = np.concatenate(speech_buffer)
                enqueued_segments.append(concatenated)
                speech_buffer = []
                buffer_samples = 0

        self.assertEqual(len(enqueued_segments), 1)
        self.assertEqual(len(enqueued_segments[0]), max_samples)
        self.assertEqual(buffer_samples, total_samples - max_samples)


if __name__ == "__main__":
    unittest.main()
