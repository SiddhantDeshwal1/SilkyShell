#!/usr/bin/env python3
"""
test_hallucination_defense.py — Unit and regression test suite for
Prompt Reflection Stripping, Phantom Noise Token Defense, and Server Flags
in live-dictate.py.

Verifies:
1. Exact and mutated prompt echoes are completely stripped.
2. Mixed outputs (prompt echo + code) have the prompt echo stripped, leaving code intact.
3. Phantom noise tokens (e.g. 'whisper', 'whisper.cpp', 'system prompts', 'blank audio', 'thank you') are blocked.
4. Repetitive autoregressive loops (e.g. 'YAML, YAML, YAML') are blocked.
5. Non-speech sound effects (*cough*, [BLANK_AUDIO], (music)) are stripped without mangling code syntax like express() or (3000).
6. Legitimate developer dictations pass through cleanly with zero distortion.
"""

import unittest
import sys
import os

# Add scripts directory to path
SCRIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts"))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

# Import defense functions from live-dictate.py
import importlib.util
spec = importlib.util.spec_from_file_location("live_dictate", os.path.join(SCRIPTS_DIR, "live-dictate.py"))
live_dictate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live_dictate)


class TestHallucinationDefense(unittest.TestCase):

    def test_pure_prompt_echo_stripped(self):
        """Verify that pure prompt regurgitations from Whisper are stripped to empty."""
        echoes = [
            # Exact echo observed in /tmp/live-dictate.log:
            "The following is a technical software developer dictating code, system prompts, and whisper. ",
            # Mutated echo observed in /tmp/live-dictate.log:
            "This is a software developer dictating code. ",
            # Full initial prompt:
            "The following is a technical software developer dictating code, system prompts, YAML, JSON, APIs, Python, TypeScript, and whisper.cpp.",
            # Tail clauses:
            "System prompts, YAML, JSON, APIs, Python, TypeScript, and whisper.cpp.",
            "System prompt, and whisper.",
            "The following is a software developer dictating code.",
            "This is a technical software developer dictating code.",
        ]
        for echo in echoes:
            with self.subTest(echo=echo):
                result = live_dictate.sanitize_text(echo)
                self.assertEqual(result, "", f"Failed to strip prompt echo: {echo!r} -> {result!r}")

    def test_mixed_prompt_echo_and_code(self):
        """Verify that when a prompt echo is prepended or appended to code, only the echo is stripped."""
        cases = [
            (
                "The following is a technical software developer dictating code, system prompts, and whisper. const app = express();",
                "const app = express();"
            ),
            (
                "The following is a technical software developer dictating code, system prompts, and whisper const app = express();",
                "const app = express();"
            ),
            (
                "const app = express(); The following is a technical software developer dictating code, system prompts, and whisper.",
                "const app = express();"
            ),
            (
                "This is a software developer dictating code. git checkout -b feature/audio-defense",
                "git checkout -b feature/audio-defense"
            ),
            (
                "docker run -it alpine The following is a software developer dictating code.",
                "docker run -it alpine"
            ),
            (
                "System prompt, and whisper. def test_handler():",
                "def test_handler():"
            ),
        ]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                result = live_dictate.sanitize_text(raw)
                self.assertEqual(result, expected, f"Failed mixed stripping on: {raw!r}")

    def test_phantom_tokens_blocked(self):
        """Verify that isolated phantom noise tokens and hallucination artifacts are blocked."""
        phantoms = [
            "whisper",
            "whisper.",
            "whisper.cpp",
            "whisper cpp",
            "system prompts",
            "system prompt",
            "System prompt.",
            "blank audio",
            "blank_audio",
            "[BLANK_AUDIO]",
            "[blank_audio]",
            "thank you",
            "Thank you.",
            "thank you very much",
            "thanks for watching",
            "thanks for watching!",
            "please subscribe",
            "like and subscribe",
            "subtitles by the amara.org community",
            "amara.org",
            "bye.",
            "bye bye",
            "silence",
            "[silence]",
            "(silence)",
        ]
        for p in phantoms:
            with self.subTest(phantom=p):
                result = live_dictate.sanitize_text(p)
                self.assertEqual(result, "", f"Phantom token leaked through: {p!r} -> {result!r}")

    def test_repetition_loops_blocked(self):
        """Verify that autoregressive repetition loops (e.g. repeated words) are blocked."""
        repetitions = [
            "System prompt, YAML, YAML, YAML, YAML, YAML, YAML, YAML, YAML, ",
            "code code code code code",
            "the the the the",
            "test test test test test",
        ]
        for rep in repetitions:
            with self.subTest(rep=rep):
                result = live_dictate.sanitize_text(rep)
                self.assertEqual(result, "", f"Repetition loop leaked through: {rep!r} -> {result!r}")

    def test_sound_effects_stripped_without_mangling_code(self):
        """Verify non-speech audio cues (*cough*, [MUSIC]) are stripped while preserving code parens like express()."""
        cases = [
            ("Some changes in the... *cough*", "Some changes in the..."),
            ("Hello world [MUSIC]", "Hello world"),
            ("Test function (laughter)", "Test function"),
            ("const app = express();", "const app = express();"),
            ("app.listen(3000);", "app.listen(3000);"),
            ("def run(timeout=5):", "def run(timeout=5):"),
        ]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                result = live_dictate.sanitize_text(raw)
                self.assertEqual(result, expected, f"Sound effect stripping mangled text: {raw!r}")

    def test_legitimate_developer_dictations_pass_cleanly(self):
        """Verify standard programming and CLI dictations pass through completely intact."""
        legitimate = [
            "const app = express();",
            "docker run -it alpine",
            "git commit -m 'fix: anti-hallucination defense'",
            "curl -X POST http://localhost:8089/inference",
            "def get_user_profile(user_id: int):",
            "npm run build",
            "cargo test --release",
            "git clone https://github.com/ggerganov/whisper.cpp",
            "parse yaml and json in python",
            "export PATH=\"$PATH:/usr/local/bin\"",
            "if [ $? -eq 0 ]; then",
            "kubectl get pods -n kube-system",
            "SELECT id, name FROM users WHERE active = 1;",
        ]
        for dictation in legitimate:
            with self.subTest(dictation=dictation):
                result = live_dictate.sanitize_text(dictation)
                self.assertEqual(result, dictation, f"Legitimate dictation was altered: {dictation!r} -> {result!r}")


if __name__ == "__main__":
    unittest.main()
