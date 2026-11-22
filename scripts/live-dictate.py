#!/home/banana/.local/share/dictation/venv/bin/python3
"""
Live Dictation Service for QuickShell
Production-grade streaming speech-to-text with:
- AMD Radeon Vega GPU acceleration via Vulkan (whisper-server + ggml-small.en-q5_1, 244M params, ~3% WER).
- Seamless faster-whisper CPU fallback (distil-small.en INT8, ~6x faster than standard small with ~3% WER).
- Asynchronous producer-consumer pipeline (audio capture never blocks on inference).
- 5-Layer Safety Circuit Breaker: repetition firewall, bracketed sound effect stripper, 120-char burst cap.
- Direct keystroke injection into focused Wayland window via ydotool (-d 2 -H 2) with wtype fallback.
- Zero clipboard pollution, zero focus stealing, zero orphan/zombie process leaks.
"""

import sys
import os
import signal
import socket
import json
import time
import atexit
import ctypes
import subprocess
import threading
import queue
import re
import difflib
import io
import wave
import http.client
import urllib.request
from collections import Counter

VENV_PYTHON = "/home/banana/.local/share/dictation/venv/bin/python3"
DICTATION_DIR = os.path.expanduser("~/.local/share/dictation")
BIN_DIR = os.path.join(DICTATION_DIR, "bin")
MODELS_DIR = os.path.join(DICTATION_DIR, "models")
TURBO_GPU_MODEL = os.path.join(MODELS_DIR, "ggml-large-v3-turbo-q5_0.bin")
FALLBACK_GPU_MODEL = os.path.join(MODELS_DIR, "ggml-small.en.bin")


def resolve_gpu_model_path() -> str:
    """
    Resolve default GPU model path with fallback.
    Default: ggml-large-v3-turbo-q5_0.bin
    Fallback: ggml-small.en.bin (or ggml-small.en-q5_1.bin if present)
    Can be overridden via DICTATION_GPU_MODEL environment variable.
    """
    env_model = os.environ.get("DICTATION_GPU_MODEL")
    if env_model and os.path.exists(env_model):
        return env_model
    if os.path.exists(TURBO_GPU_MODEL):
        return TURBO_GPU_MODEL
    if os.path.exists(FALLBACK_GPU_MODEL):
        return FALLBACK_GPU_MODEL
    alt_q5 = os.path.join(MODELS_DIR, "ggml-small.en-q5_1.bin")
    if os.path.exists(alt_q5):
        return alt_q5
    return TURBO_GPU_MODEL


GPU_MODEL_PATH = resolve_gpu_model_path()
GPU_SERVER_BIN = os.path.join(BIN_DIR, "whisper-server")
GPU_SERVER_PORT = 8089

_gpu_http_conn = None
_gpu_http_lock = threading.Lock()


def get_gpu_http_connection() -> http.client.HTTPConnection:
    """Return or establish persistent HTTP connection to GPU whisper-server."""
    global _gpu_http_conn
    if _gpu_http_conn is None:
        _gpu_http_conn = http.client.HTTPConnection("127.0.0.1", GPU_SERVER_PORT, timeout=30.0)
    return _gpu_http_conn


def close_gpu_http_connection():
    """Cleanly close persistent HTTP connection."""
    global _gpu_http_conn
    with _gpu_http_lock:
        if _gpu_http_conn is not None:
            try:
                _gpu_http_conn.close()
            except Exception:
                pass
            _gpu_http_conn = None

CHUNK_SAMPLES = int(os.environ.get("DICTATION_CHUNK_SAMPLES", "1600"))  # 1600 samples = 0.1s = 100ms at 16kHz
CHUNK_BYTES = CHUNK_SAMPLES * 2  # 3200 bytes for 16-bit mono PCM (s16le)
SILENCE_RMS_THRESHOLD = float(os.environ.get("DICTATION_SILENCE_RMS", "250.0"))  # Silence threshold: RMS < 250
DEEP_SILENCE_RMS_THRESHOLD = float(os.environ.get("DICTATION_DEEP_SILENCE_RMS", "125.0"))  # True ambient noise floor
PAUSE_SILENCE_CHUNKS = 3  # Max pause chunks (300ms at 100ms/chunk)
PAUSE_SILENCE_CHUNKS_MIN = 2  # Fast pause chunks (200ms) for deep silence or sustained phrases
MAX_SPEECH_DURATION_S = 3.0  # Max speech buffer duration: 3.0 seconds
MAX_SPEECH_SAMPLES = int(16000 * MAX_SPEECH_DURATION_S)  # 48,000 samples
MAX_BURST_CHARS = 120  # Hard cap on characters injected per phrase burst

CPU_MODEL_NAME = os.environ.get("DICTATION_MODEL", "distil-small.en")
USE_GPU = os.environ.get("DICTATION_USE_GPU", "1") != "0"

INITIAL_PROMPT = (
    "The following is a technical software developer dictating code, "
    "system prompts, YAML, JSON, APIs, Python, TypeScript, and whisper.cpp."
)

PROMPT_CLAUSES = [
    "The following is a technical software developer dictating code",
    "system prompts, YAML, JSON, APIs, Python, TypeScript, and whisper.cpp",
    "The following is a technical software developer dictating code, system prompts, and whisper.",
    "The following is a software developer dictating code",
    "This is a technical software developer dictating code",
    "This is a software developer dictating code",
    "system prompts, and whisper",
    "system prompts and whisper.cpp",
    "system prompt, and whisper",
]

def _normalize_tokens(s: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", s.lower()))

PROMPT_CLAUSES_NORM = [_normalize_tokens(c) for c in PROMPT_CLAUSES]

PROMPT_STRIP_REGEXES = [
    # Full or partial opening clause echo: 'The following / this is a [technical] software developer dictating code...'
    re.compile(
        r"(?i)\b(?:the following|this)\s+(?:is\s+)?(?:a\s+)?(?:technical\s+)?software\s+developer\s+dictating\s+code\b"
        r"(?:[,\s]*(?:system\s+prompts?|whisper(?:\.cpp)?|yaml|json|apis?|python|typescript|and\s+whisper(?:\.cpp)?|and))*"
        r"[\.\?!]?",
        re.IGNORECASE
    ),
    # Tail / system prompt clause echoes: 'system prompts, YAML, JSON, APIs...' or 'system prompts, and whisper'
    re.compile(
        r"(?i)\bsystem\s+prompts?,?(?:[,\s]*(?:yaml|json|apis?|python|typescript|whisper(?:\.cpp)?|and\s+whisper(?:\.cpp)?|and))*[\.\?!]?",
        re.IGNORECASE
    ),
    # Repetition loops of prompt keywords
    re.compile(
        r"(?i)\b(?:(?:YAML|system prompt|JSON),\s*){2,}(?:YAML|system prompt|JSON)?[\.\?!;:]?",
        re.IGNORECASE
    ),
]

SOUND_EFFECT_REGEXES = [
    re.compile(r"\[[A-Z_\s]{3,}\]|\[(?i:blank_audio|blank audio|music|applause|laughter|silence|noise|sound|cheering|cough|coughing|sigh)\]"),
    re.compile(r"(?i)\*(?:cough|coughing|snicker|laughter|giggle|sigh|gasp|throat clearing|clears throat)\*"),
    re.compile(r"(?i)\((?:music|chime|applause|laughter|bell|cough|coughing|clears throat|throat clearing|sigh|gasp|snicker|giggle|whistle|groan|static|beep|silence|sonic logo)\)"),
]

PHANTOM_PHRASES = {
    "thank you.", "thank you", "thank you very much.", "thank you very much",
    "thanks for watching", "thanks for watching.", "please subscribe", "like and subscribe",
    "subtitles by", "subtitles by the amara.org community", "amara.org",
    "bye.", "bye", "bye bye", "bye-bye",
    "...", "you", "so", "the end",
    "blank_audio", "blank audio", "[blank_audio]", "[blank audio]",
    "whisper", "whisper.", "whisper.cpp", "whisper cpp",
    "system prompts", "system prompt", "system prompts.", "system prompt.",
    "silence", "[silence]", "(silence)",
}

LOG_FILE = "/tmp/live-dictate.log"
STATE_FILE = "/tmp/qs_dictation.json"

# Ensure Wayland environment is available
runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
if "WAYLAND_DISPLAY" not in os.environ:
    for w in ["wayland-1", "wayland-0"]:
        if os.path.exists(os.path.join(runtime_dir, w)):
            os.environ["WAYLAND_DISPLAY"] = w
            break

# Keystroke injection parameters
KEY_DELAY_MS = os.environ.get("DICTATION_KEY_DELAY", "1")
KEY_HOLD_MS = os.environ.get("DICTATION_KEY_HOLD", "1")

pw_proc = None
gpu_server_proc = None
_shutdown_requested = False
_stream_start_time = time.monotonic()
_grace_period_done = False
_shutdown_time = 0.0
_shutdown_grace_done = False
_validated_ydotool_socket = None
audio_queue = None
worker_thread = None


def validate_ydotool_socket(sock_path: str) -> bool:
    """
    Validate that sock_path exists, has read/write permissions,
    and ydotoold is actively listening by probing with a 0-byte UNIX datagram.
    """
    if not sock_path or not os.path.exists(sock_path):
        return False
    try:
        if not (os.access(sock_path, os.R_OK) and os.access(sock_path, os.W_OK)):
            return False
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        try:
            s.settimeout(0.05)
            s.connect(sock_path)
            s.send(b'')
            return True
        finally:
            s.close()
    except OSError:
        return False


def get_ydotool_socket() -> str | None:
    """Return verified ydotoold socket path, checking candidates in priority order."""
    global _validated_ydotool_socket
    if _validated_ydotool_socket and validate_ydotool_socket(_validated_ydotool_socket):
        return _validated_ydotool_socket

    candidates = []
    if "YDOTOOL_SOCKET" in os.environ:
        candidates.append(os.environ["YDOTOOL_SOCKET"])

    uid = os.getuid()
    rt_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{uid}")
    candidates.append(os.path.join(rt_dir, ".ydotool_socket"))
    candidates.append("/tmp/.ydotool_socket")

    for path in candidates:
        if path and validate_ydotool_socket(path):
            _validated_ydotool_socket = path
            os.environ["YDOTOOL_SOCKET"] = path
            return path

    # Attempt to auto-start ydotool.service if managed by systemd user
    try:
        res = subprocess.run(
            ["systemctl", "--user", "is-active", "ydotool"],
            capture_output=True,
            text=True,
            timeout=0.2
        )
        if res.returncode != 0:
            subprocess.run(
                ["systemctl", "--user", "start", "ydotool"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=0.5
            )
            std_path = os.path.join(rt_dir, ".ydotool_socket")
            for _ in range(5):
                time.sleep(0.04)
                if validate_ydotool_socket(std_path):
                    _validated_ydotool_socket = std_path
                    os.environ["YDOTOOL_SOCKET"] = std_path
                    return std_path
    except Exception:
        pass

    _validated_ydotool_socket = None
    return None


def reset_virtual_modifiers():
    """Ensure any virtual modifier keys (Super, Ctrl, Alt, Shift) are released."""
    sock = get_ydotool_socket()
    if sock:
        env = os.environ.copy()
        env["YDOTOOL_SOCKET"] = sock
        try:
            # 125/126: Left/Right Meta, 29/97: Left/Right Ctrl, 56/100: Left/Right Alt, 42/54: Left/Right Shift
            subprocess.run(
                ["ydotool", "key", "125:0", "126:0", "29:0", "97:0", "56:0", "100:0", "42:0", "54:0"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=0.3
            )
        except Exception:
            pass


def ensure_venv():
    """Ensure running inside the dictation virtual environment if needed."""
    if sys.executable != VENV_PYTHON and os.path.exists(VENV_PYTHON):
        try:
            import numpy
        except ImportError:
            os.execv(VENV_PYTHON, [VENV_PYTHON] + sys.argv)


def log_debug(msg: str):
    """Write timestamped entry to debug log."""
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def get_current_mic_name() -> str:
    """Return friendly name and source device of currently active recording device."""
    try:
        res = subprocess.run(["pactl", "get-default-source"], capture_output=True, text=True, timeout=1.0)
        source = res.stdout.strip()
        if "bluez" in source:
            return f"Bluetooth Headset ({source})"
        elif "analog-stereo" in source:
            return f"Laptop Microphone ({source})"
        return source or "Default Microphone"
    except Exception:
        return "Default Microphone"


def update_state(is_listening: bool, mic_name: str = ""):
    """Write state file for Quickshell FileView atomically and notify IPC."""
    try:
        data = {
            "isListening": bool(is_listening),
            "device": mic_name or (get_current_mic_name() if is_listening else "")
        }
        tmp_path = f"{STATE_FILE}.tmp"
        with open(tmp_path, "w") as f:
            f.write(json.dumps(data) + "\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, STATE_FILE)
    except Exception:
        pass

    try:
        subprocess.run(
            ["quickshell", "ipc", "call", "dictation", "start" if is_listening else "stop"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=0.3
        )
    except Exception:
        pass


def set_parent_death_signal(sig=signal.SIGTERM):
    """Ensure kernel delivers SIGTERM to child process if parent dies."""
    try:
        libc = ctypes.CDLL("libc.so.6")
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, sig)
    except Exception:
        pass


def get_pid_file() -> str:
    """Return path to /run/user/<UID>/live-dictate.pid."""
    uid = os.getuid()
    rt_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{uid}")
    if not os.path.isdir(rt_dir):
        rt_dir = f"/run/user/{uid}"
    return os.path.join(rt_dir, "live-dictate.pid")


def is_pid_running(pid: int) -> bool:
    """Check if process with PID is alive and is live-dictate."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmdline = f.read().decode("utf-8", errors="ignore")
            return "live-dictate" in cmdline
    except Exception:
        return True


def get_status() -> dict:
    """Return current status: {'running': bool, 'pid': int}."""
    pid_file = get_pid_file()
    if not os.path.exists(pid_file):
        return {"running": False, "pid": 0}
    try:
        with open(pid_file, "r") as f:
            content = f.read().strip()
            pid = int(content) if content else 0
    except (ValueError, OSError):
        return {"running": False, "pid": 0}

    if is_pid_running(pid):
        return {"running": True, "pid": pid}
    else:
        try:
            os.remove(pid_file)
        except OSError:
            pass
        return {"running": False, "pid": 0}


def start_gpu_server() -> bool:
    """Start whisper-server on AMD Radeon Vega GPU via Vulkan."""
    global gpu_server_proc
    if not USE_GPU:
        log_debug("GPU acceleration disabled via environment")
        return False

    model_path = resolve_gpu_model_path()
    if not (os.path.exists(GPU_SERVER_BIN) and os.path.exists(model_path)):
        log_debug(f"GPU server binary or model not found ({model_path}); using CPU fallback")
        return False

    # Check if whisper-server is already running
    try:
        conn = http.client.HTTPConnection("127.0.0.1", GPU_SERVER_PORT, timeout=0.2)
        conn.request("GET", "/")
        resp = conn.getresponse()
        resp.read()
        conn.close()
        log_debug(f"GPU whisper-server is already running on port {GPU_SERVER_PORT}")
        return True
    except Exception:
        pass

    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = BIN_DIR

    log_debug(f"Starting GPU whisper-server on Vulkan (model: {os.path.basename(model_path)})...")
    try:
        gpu_server_proc = subprocess.Popen(
            [
                GPU_SERVER_BIN,
                "-m", model_path,
                "--port", str(GPU_SERVER_PORT),
                "-t", "4",
                "--flash-attn",
                "--suppress-nst",
                "--no-speech-thold", "0.6",
                "--no-fallback"
            ],
            env=env,
            cwd=BIN_DIR,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            preexec_fn=set_parent_death_signal
        )
    except Exception as e:
        log_debug(f"Failed to spawn GPU whisper-server: {e}")
        return False

    # Poll until server is ready (50ms intervals instead of 80ms)
    for _ in range(70):
        time.sleep(0.05)
        try:
            conn = http.client.HTTPConnection("127.0.0.1", GPU_SERVER_PORT, timeout=0.1)
            conn.request("GET", "/")
            resp = conn.getresponse()
            resp.read()
            conn.close()
            log_debug("GPU whisper-server is healthy and ready on AMD Radeon Vega GPU!")
            return True
        except Exception:
            pass

    log_debug("GPU whisper-server startup timed out; using CPU fallback")
    return False


def stop_gpu_server():
    """Terminate managed whisper-server to free GPU VRAM immediately."""
    global gpu_server_proc
    close_gpu_http_connection()
    if gpu_server_proc is not None:
        try:
            if gpu_server_proc.poll() is None:
                gpu_server_proc.terminate()
                try:
                    gpu_server_proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    gpu_server_proc.kill()
                    gpu_server_proc.wait(timeout=0.5)
        except Exception:
            pass
        gpu_server_proc = None
        log_debug("GPU whisper-server stopped; VRAM released")


def cleanup():
    """Clean up child processes, state file, and PID file."""
    global pw_proc
    if pw_proc is not None:
        try:
            if pw_proc.poll() is None:
                pw_proc.terminate()
                try:
                    pw_proc.wait(timeout=0.3)
                except subprocess.TimeoutExpired:
                    pw_proc.kill()
                    pw_proc.wait(timeout=0.3)
        except Exception:
            pass
        pw_proc = None

    stop_gpu_server()
    reset_virtual_modifiers()

    pid_file = get_pid_file()
    try:
        if os.path.exists(pid_file):
            with open(pid_file, "r") as f:
                content = f.read().strip()
                if content and int(content) == os.getpid():
                    os.remove(pid_file)
    except Exception:
        pass
    update_state(False)


def handle_signal(signum, frame):
    """Handle termination signals cleanly and unblock read loop immediately."""
    global _shutdown_requested, _shutdown_time, pw_proc
    _shutdown_requested = True
    _shutdown_time = time.monotonic()
    if pw_proc is not None:
        try:
            pw_proc.terminate()
        except OSError:
            pass
        if pw_proc.stdout:
            try:
                pw_proc.stdout.close()
            except Exception:
                pass


def is_clause_prompt_echo(clause: str) -> bool:
    """Check if a decoded clause or sentence closely matches reference prompt clauses."""
    norm = _normalize_tokens(clause)
    if not norm or len(norm.split()) < 2:
        return False
    for ref in PROMPT_CLAUSES_NORM:
        ratio = difflib.SequenceMatcher(None, ref, norm).ratio()
        if ratio >= 0.70:
            return True
        if norm in ref and len(norm.split()) >= 4:
            return True
        if ref in norm and len(ref.split()) >= 4:
            return True
    return False


def strip_prompt_reflections(text: str) -> str:
    """
    Prompt Reflection Stripper:
    Whenever Whisper decodes text, if the output contains or closely matches sentences
    from INITIAL_PROMPT, strip that portion immediately before any typing occurs.
    """
    if not text:
        return ""
    cleaned = text
    for pat in PROMPT_STRIP_REGEXES:
        cleaned = pat.sub(" ", cleaned)

    # Split into sentences and drop any clause closely matching prompt
    sentences = re.split(r"(\n+|(?<=[.!?])\s+)", cleaned)
    retained = []
    for s in sentences:
        if not s.strip():
            continue
        if not is_clause_prompt_echo(s):
            retained.append(s.strip())

    res = " ".join(retained)
    return re.sub(r"\s+", " ", res).strip()


def is_phantom_token(text: str) -> bool:
    """Check if utterance matches or is fuzzily close to known phantom noise/hallucination tokens."""
    norm = text.lower().strip(" .,?!;:'\"-_()[]{}")
    if not norm:
        return True
    if norm in PHANTOM_PHRASES:
        return True
    words = norm.split()
    if len(words) <= 4 and len(norm) <= 35:
        for phrase in PHANTOM_PHRASES:
            phrase_norm = phrase.lower().strip(" .,?!;:'\"-_()[]{}")
            phrase_words = phrase_norm.split()
            if abs(len(words) - len(phrase_words)) <= 1:
                ratio = difflib.SequenceMatcher(None, norm, phrase_norm).ratio()
                if ratio >= 0.82:
                    return True
    return False


def is_hallucination_or_repetition(text: str) -> bool:
    """
    Safety Circuit Breaker:
    Detect autoregressive decoder repetition loops, phantom noise tokens, sound effects, and spam.
    Returns True if the text should be discarded.
    """
    if not text:
        return True

    cleaned = text.strip()
    if not cleaned or cleaned in (".", ",", "...", "-", "?", "!", ":", ";"):
        return True

    if is_phantom_token(cleaned):
        log_debug(f"SAFETY: Blocked phantom noise token '{cleaned}'")
        return True

    words = [w.strip(".,?!\"':;()[]{}").lower() for w in cleaned.split()]
    words = [w for w in words if w]
    if not words:
        return True

    # 1. Consecutive word repetition (e.g. "YAML, YAML, YAML")
    for i in range(len(words) - 2):
        if words[i] == words[i + 1] == words[i + 2]:
            log_debug(f"SAFETY: Blocked consecutive repetition of '{words[i]}' in '{cleaned}'")
            return True

    # 2. Word dominance check (e.g. >40% of words in sentence are identical)
    if len(words) >= 4:
        counts = Counter(words)
        most_common_word, count = counts.most_common(1)[0]
        if (count / len(words)) > 0.4:
            log_debug(f"SAFETY: Blocked dominant repetition '{most_common_word}' ({count}/{len(words)}) in '{cleaned}'")
            return True

    return False


def sanitize_text(text: str) -> str:
    """Apply safety firewall, bracket stripper, prompt reflection defense, and character burst cap before emission."""
    if not text:
        return ""

    # Strip bracketed / parenthesized non-speech sound effects without mangling code syntax
    cleaned = text
    for pat in SOUND_EFFECT_REGEXES:
        cleaned = pat.sub("", cleaned)
    cleaned = cleaned.strip()

    # Strip prompt reflections before hallucination and burst checks
    cleaned = strip_prompt_reflections(cleaned)

    if is_hallucination_or_repetition(cleaned):
        return ""

    if len(cleaned) > MAX_BURST_CHARS:
        log_debug(f"SAFETY: Capped burst length from {len(cleaned)} to {MAX_BURST_CHARS} chars")
        truncated = cleaned[:MAX_BURST_CHARS].rsplit(' ', 1)[0]
        cleaned = truncated if truncated else cleaned[:MAX_BURST_CHARS]

    return cleaned.strip()


def type_text(text: str):
    """
    Type text directly into focused window using fast ydotool (-d 1 -H 1)
    with reliable timeout-protected fallback to wtype.
    """
    global _grace_period_done, _shutdown_grace_done

    # 1. Grace period for initial activation (Super + V physical key release)
    # Only delays the very first keystroke after activation up to 200ms from activation time.
    # If 200ms has already passed during inference/capture, remaining delay is 0ms.
    if not _grace_period_done:
        _grace_period_done = True
        elapsed = time.monotonic() - _stream_start_time
        remaining = 0.20 - elapsed
        if remaining > 0:
            time.sleep(remaining)
    # 2. Grace period for shutdown key release (if stopped via Super + V)
    # Only applies to the first keystroke after shutdown signal.
    elif _shutdown_requested and not _shutdown_grace_done:
        _shutdown_grace_done = True
        elapsed = time.monotonic() - _shutdown_time
        remaining = 0.15 - elapsed
        if remaining > 0:
            time.sleep(remaining)

    sanitized = sanitize_text(text)
    if not sanitized:
        return

    formatted = f"{sanitized} "
    log_debug(f"TYPING: '{formatted}'")

    # Primary: Fast ydotool (-d 1 -H 1 by default, >400 chars/sec)
    sock = get_ydotool_socket()
    if sock:
        env = os.environ.copy()
        env["YDOTOOL_SOCKET"] = sock
        ydo_timeout = max(0.8, len(formatted) * 0.015 + 0.5)
        try:
            res = subprocess.run(
                ["ydotool", "type", "-d", KEY_DELAY_MS, "-H", KEY_HOLD_MS, formatted],
                env=env,
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=ydo_timeout
            )
            if res.returncode == 0:
                return
            log_debug(f"ydotool exited with non-zero status: {res.returncode}")
        except subprocess.TimeoutExpired:
            log_debug("ydotool timed out; aborted to prevent worker thread hang")
            reset_virtual_modifiers()
        except Exception as e:
            log_debug(f"ydotool error: {e}")

    # Fallback: wtype via Wayland virtual-keyboard protocol (-d 1, timeout-protected)
    wtype_timeout = max(1.0, len(formatted) * 0.02 + 0.5)
    try:
        subprocess.run(
            ["wtype", "-d", "1", "--", formatted],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=wtype_timeout
        )
    except subprocess.TimeoutExpired:
        log_debug("wtype timed out; aborted to prevent worker thread hang")
    except Exception as e:
        log_debug(f"wtype error: {e}")


def transcribe_audio_gpu(audio_samples) -> str:
    """Send audio to GPU whisper-server via persistent HTTP connection and return transcribed text."""
    import numpy as np

    if audio_samples.dtype != np.int16:
        pcm_data = (np.clip(audio_samples, -1.0, 1.0) * 32767.0).astype(np.int16).tobytes()
    else:
        pcm_data = audio_samples.tobytes()

    wav_io = io.BytesIO()
    with wave.open(wav_io, 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16000)
        wf.writeframes(pcm_data)
    wav_bytes = wav_io.getvalue()

    boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
    body = (
        f'--{boundary}\r\n'
        f'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
        f'Content-Type: audio/wav\r\n\r\n'
    ).encode() + wav_bytes + (
        f'\r\n--{boundary}\r\nContent-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'
        f'--{boundary}\r\nContent-Disposition: form-data; name="temperature"\r\n\r\n0.0\r\n'
        f'--{boundary}\r\nContent-Disposition: form-data; name="temperature_inc"\r\n\r\n0.0\r\n'
        f'--{boundary}\r\nContent-Disposition: form-data; name="prompt"\r\n\r\n{INITIAL_PROMPT}\r\n'
        f'--{boundary}--\r\n'
    ).encode()

    headers = {
        'Content-Type': f'multipart/form-data; boundary={boundary}',
        'Connection': 'keep-alive',
        'Content-Length': str(len(body))
    }

    with _gpu_http_lock:
        conn = get_gpu_http_connection()
        try:
            conn.request("POST", "/inference", body=body, headers=headers)
            resp = conn.getresponse()
            raw_data = resp.read().decode('utf-8', errors='replace')
            res_data = json.loads(raw_data)
            return res_data.get("text", "").strip()
        except (http.client.RemoteDisconnected, http.client.CannotSendRequest, BrokenPipeError, ConnectionResetError, OSError) as e:
            log_debug(f"Persistent HTTP connection dropped ({e}), retrying once with fresh socket...")
            close_gpu_http_connection()
            conn = get_gpu_http_connection()
            conn.request("POST", "/inference", body=body, headers=headers)
            resp = conn.getresponse()
            raw_data = resp.read().decode('utf-8', errors='replace')
            res_data = json.loads(raw_data)
            return res_data.get("text", "").strip()
        except Exception:
            close_gpu_http_connection()
            raise


_cpu_model_instance = None


def get_cpu_model(model_name: str = None):
    """
    Load or return cached faster-whisper CPU model singleton.
    Defaults to CPU_MODEL_NAME (distil-small.en INT8 with 4 threads).
    Gracefully falls back to base.en if preferred model is unavailable.
    """
    global _cpu_model_instance
    if _cpu_model_instance is not None:
        return _cpu_model_instance

    target_model = model_name or CPU_MODEL_NAME
    log_debug(f"Loading faster-whisper CPU model: {target_model} (INT8, cpu_threads=4)...")
    try:
        from faster_whisper import WhisperModel
        _cpu_model_instance = WhisperModel(
            target_model,
            device="cpu",
            compute_type="int8",
            cpu_threads=4
        )
        log_debug(f"WhisperModel ({target_model} INT8) loaded successfully on CPU")
        return _cpu_model_instance
    except Exception as e:
        log_debug(f"Failed to load preferred CPU model '{target_model}': {e}")
        if target_model != "base.en":
            try:
                log_debug("Attempting fallback to base.en on CPU...")
                from faster_whisper import WhisperModel
                _cpu_model_instance = WhisperModel(
                    "base.en",
                    device="cpu",
                    compute_type="int8",
                    cpu_threads=4
                )
                log_debug("Fallback WhisperModel (base.en INT8) loaded on CPU")
                return _cpu_model_instance
            except Exception as e2:
                log_debug(f"Failed to load fallback CPU model base.en: {e2}")
        return None


def transcribe_audio_cpu(model, audio_float) -> str:
    """CPU fallback inference using faster-whisper with CTranslate2 INT8."""
    if model is None:
        return ""
    segments, _ = model.transcribe(
        audio_float,
        vad_filter=True,
        vad_parameters=dict(min_silence_duration_ms=200, threshold=0.5),
        condition_on_previous_text=False,
        initial_prompt=INITIAL_PROMPT,
        language="en",
        beam_size=1,
        repetition_penalty=1.3,
        no_speech_threshold=0.6,
        compression_ratio_threshold=2.2,
        temperature=0.0
    )
    return " ".join(seg.text.strip() for seg in segments).strip()


def enqueue_audio_segment(q: queue.Queue, item) -> bool:
    """Non-blocking enqueue into audio queue with FIFO drop-oldest eviction."""
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
            log_debug("Audio queue full; evicted oldest segment and enqueued new item")
            return True
        except queue.Full:
            log_debug("Audio queue full; failed to enqueue item")
            return False


def transcription_worker(cpu_model, audio_q: queue.Queue, use_gpu: bool):
    """
    Dedicated worker thread consuming audio segments asynchronously.
    Processes inference on GPU with seamless CPU fallback.
    """
    log_debug(f"Transcription worker thread started (GPU acceleration: {use_gpu})")
    while True:
        try:
            item = audio_q.get(timeout=0.2)
        except queue.Empty:
            if _shutdown_requested:
                break
            continue

        if item is None:
            audio_q.task_done()
            break

        audio_segment = item
        try:
            text = ""
            if use_gpu:
                try:
                    text = transcribe_audio_gpu(audio_segment)
                except Exception as e:
                    log_debug(f"GPU inference error, falling back to CPU: {e}")
                    active_cpu_model = cpu_model or get_cpu_model()
                    if active_cpu_model is not None:
                        text = transcribe_audio_cpu(active_cpu_model, audio_segment)
            else:
                active_cpu_model = cpu_model or get_cpu_model()
                if active_cpu_model is not None:
                    text = transcribe_audio_cpu(active_cpu_model, audio_segment)

            if text:
                type_text(text)
        except Exception as e:
            log_debug(f"Inference error in worker: {e}")
        finally:
            audio_q.task_done()

    log_debug("Transcription worker thread finished")


def cmd_stream() -> int:
    """Start live streaming speech-to-text with GPU acceleration and async pipeline."""
    ensure_venv()

    import numpy as np

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGHUP, handle_signal)
    atexit.register(cleanup)

    pid_file = get_pid_file()
    if os.path.exists(pid_file):
        try:
            with open(pid_file, "r") as f:
                c = f.read().strip()
                old_pid = int(c) if c else 0
            if is_pid_running(old_pid):
                sys.stderr.write(f"live-dictate is already running (PID {old_pid})\n")
                sys.stderr.flush()
                return 1
            else:
                try:
                    os.remove(pid_file)
                except OSError:
                    pass
        except (ValueError, OSError):
            pass

    os.makedirs(os.path.dirname(pid_file), exist_ok=True)
    my_pid = os.getpid()
    with open(pid_file, "w") as f:
        f.write(f"{my_pid}\n")
        f.flush()

    mic_info = get_current_mic_name()
    update_state(True, mic_info)
    log_debug(f"Initializing dictation stream on mic: {mic_info} (PID {my_pid})")

    global pw_proc, audio_queue, worker_thread, _stream_start_time, _grace_period_done, _shutdown_grace_done, _shutdown_time
    _stream_start_time = time.monotonic()
    _grace_period_done = False
    _shutdown_grace_done = False
    _shutdown_time = 0.0

    # 1. Initialize GPU acceleration on AMD Radeon Vega GPU
    gpu_ready = start_gpu_server()
    cpu_model = None

    if not gpu_ready:
        cpu_model = get_cpu_model()
        if cpu_model is None:
            log_debug("Failed to initialize CPU fallback model")
            cleanup()
            return 1

    # 2. Start PipeWire parec audio capture
    try:
        pw_proc = subprocess.Popen(
            ["parec", "--rate=16000", "--channels=1", "--format=s16le"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            preexec_fn=set_parent_death_signal
        )
    except Exception as e:
        sys.stderr.write(f"Failed to start parec: {e}\n")
        sys.stderr.flush()
        cleanup()
        return 1

    # 3. Start async worker thread
    audio_queue = queue.Queue(maxsize=30)
    worker_thread = threading.Thread(
        target=transcription_worker,
        args=(cpu_model, audio_queue, gpu_ready),
        daemon=True
    )
    worker_thread.start()

    import collections
    preroll_chunks = collections.deque(maxlen=1)
    speech_buffer = []
    buffer_samples = 0
    silence_chunks = 0
    deep_silence_chunks = 0

    chunk_ms = (CHUNK_SAMPLES / 16000.0) * 1000.0
    pause_chunks_max = max(1, int(round(300.0 / chunk_ms)))
    pause_chunks_min = max(1, int(round(200.0 / chunk_ms)))

    try:
        while not _shutdown_requested:
            try:
                chunk_bytes = pw_proc.stdout.read(CHUNK_BYTES)
            except (ValueError, OSError):
                break
            if not chunk_bytes:
                break

            if len(chunk_bytes) < CHUNK_BYTES:
                if len(chunk_bytes) >= 2:
                    num_samples = len(chunk_bytes) // 2
                    samples = np.frombuffer(chunk_bytes[:num_samples * 2], dtype=np.int16)
                else:
                    break
            else:
                samples = np.frombuffer(chunk_bytes, dtype=np.int16)

            # Fast vectorized RMS energy calculation via dot product
            samples_f = samples.astype(np.float64)
            rms = float(np.sqrt(np.dot(samples_f, samples_f) / len(samples_f)))
            is_speech = (rms >= SILENCE_RMS_THRESHOLD)

            if is_speech:
                if not speech_buffer and preroll_chunks:
                    pre = preroll_chunks.popleft()
                    speech_buffer.append(pre)
                    buffer_samples += len(pre)
                speech_buffer.append(samples)
                buffer_samples += len(samples)
                silence_chunks = 0
                deep_silence_chunks = 0
            else:
                if speech_buffer:
                    speech_buffer.append(samples)
                    buffer_samples += len(samples)
                    silence_chunks += 1
                    if rms < DEEP_SILENCE_RMS_THRESHOLD:
                        deep_silence_chunks += 1
                    else:
                        deep_silence_chunks = 0
                else:
                    preroll_chunks.append(samples)

            # Dynamic pause detection:
            # - Trigger at 2 chunks (200ms) on deep silence (>=2 chunks < 125 RMS) or sustained phrase (>= 1.0s)
            # - Trigger at 3 chunks (300ms) on borderline silence/hesitation
            # - Trailing speech padding is preserved because silence chunks remain in speech_buffer
            should_enqueue = (
                deep_silence_chunks >= pause_chunks_min
                or (silence_chunks >= pause_chunks_min and buffer_samples >= 16000)
                or silence_chunks >= pause_chunks_max
            )

            if speech_buffer and (should_enqueue or buffer_samples >= MAX_SPEECH_SAMPLES):
                concatenated = np.concatenate(speech_buffer)
                audio_float = concatenated.astype(np.float32) / 32768.0
                enqueue_audio_segment(audio_queue, audio_float)
                speech_buffer = []
                buffer_samples = 0
                silence_chunks = 0
                deep_silence_chunks = 0

        # On stop / shutdown: enqueue any remaining in-flight audio buffer
        if speech_buffer:
            concatenated = np.concatenate(speech_buffer)
            audio_float = concatenated.astype(np.float32) / 32768.0
            enqueue_audio_segment(audio_queue, audio_float)
            speech_buffer = []
            buffer_samples = 0

        # Send sentinel to worker thread and wait for completion
        if audio_queue is not None:
            enqueue_audio_segment(audio_queue, None)

        if worker_thread is not None and worker_thread.is_alive():
            worker_thread.join(timeout=3.0)

    except Exception as e:
        log_debug(f"Stream error: {e}")
        sys.stderr.write(f"Stream error: {e}\n")
        sys.stderr.flush()
    finally:
        cleanup()

    return 0


def cmd_stop() -> int:
    """Stop running live-dictate instance."""
    pid_file = get_pid_file()
    if not os.path.exists(pid_file):
        update_state(False)
        print(json.dumps({"running": False, "pid": 0}))
        return 0

    try:
        with open(pid_file, "r") as f:
            content = f.read().strip()
            pid = int(content) if content else 0
    except (ValueError, OSError):
        pid = 0

    if pid > 0 and is_pid_running(pid):
        try:
            os.kill(pid, signal.SIGTERM)
            for _ in range(60):  # Wait up to 3.0 seconds for worker flush and typing
                time.sleep(0.05)
                if not is_pid_running(pid):
                    break
            if is_pid_running(pid):
                os.kill(pid, signal.SIGKILL)
                for _ in range(10):
                    time.sleep(0.05)
                    if not is_pid_running(pid):
                        break
        except OSError:
            pass

    try:
        if os.path.exists(pid_file):
            os.remove(pid_file)
    except OSError:
        pass

    update_state(False)
    print(json.dumps({"running": False, "pid": 0}))
    return 0


def cmd_status() -> int:
    """Output JSON status."""
    st = get_status()
    st["device"] = get_current_mic_name() if st["running"] else ""
    st["gpu"] = os.path.exists(GPU_SERVER_BIN) and os.path.exists(resolve_gpu_model_path())
    print(json.dumps(st))
    return 0


def cmd_toggle() -> int:
    """Toggle between stream and stop cleanly (non-blocking)."""
    st = get_status()
    if st["running"]:
        return cmd_stop()
    else:
        python_bin = VENV_PYTHON if os.path.exists(VENV_PYTHON) else sys.executable
        proc = subprocess.Popen(
            [python_bin, os.path.abspath(__file__), "stream"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True
        )
        for _ in range(25):
            time.sleep(0.02)
            if get_status()["running"]:
                break
        print(json.dumps({"running": True, "pid": proc.pid}))
        return 0


def main():
    if len(sys.argv) < 2:
        cmd = "status"
    else:
        cmd = sys.argv[1].lower()

    if cmd == "stream":
        sys.exit(cmd_stream())
    elif cmd == "stop":
        sys.exit(cmd_stop())
    elif cmd == "toggle":
        sys.exit(cmd_toggle())
    elif cmd == "status":
        sys.exit(cmd_status())
    elif cmd in ("-h", "--help", "help"):
        print(f"Usage: {sys.argv[0]} [stream|stop|toggle|status]")
        sys.exit(0)
    else:
        sys.stderr.write(f"Unknown command: {cmd}\nUsage: {sys.argv[0]} [stream|stop|toggle|status]\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
