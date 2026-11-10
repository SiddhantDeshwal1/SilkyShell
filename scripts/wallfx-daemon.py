#!/usr/bin/env python3
"""
wallfx-daemon.py — Lightweight persistent BiRefNet / WallFx daemon for Quickshell.

Maintains the BiRefNet model pre-initialized in memory (max 2 threads) to eliminate
the ~4-5 second model load latency during wallpaper transitions.
Listens on a Unix domain socket (${XDG_RUNTIME_DIR:-/tmp}/wallfx-daemon.sock)
for line-delimited commands:
  - PREPARE <image_path>: Checks cache or runs perfil(image_path).
                          Returns 'perfil <campo> <linea>' or 'contagio <map> <liso>'.
  - PING: Returns 'PONG'.
  - STOP: Gracefully shuts down.
"""

import os
import sys

# ── 1. Ensure execution in wallfx virtual environment ────────────────────────
VENV_PY = os.path.expanduser("~/.local/share/wallfx/venv/bin/python")
if sys.executable != VENV_PY and os.path.exists(VENV_PY):
    try:
        os.execv(VENV_PY, [VENV_PY, os.path.abspath(__file__), *sys.argv[1:]])
    except OSError as err:
        sys.stderr.write(f"[wallfx-daemon] Failed to re-exec in venv: {err}\n")

import atexit
import fcntl
import importlib.machinery
import importlib.util
import json
import signal
import socket
import threading
import time

# ── 2. Environment & Paths ──────────────────────────────────────────────────
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
SOCKET_PATH = os.path.join(RUNTIME_DIR, "wallfx-daemon.sock")
LOCK_PATH = os.path.join(RUNTIME_DIR, "wallfx-daemon.lock")
WALLFX_BIN = os.path.expanduser("~/.local/bin/wallfx")

# Restrict threads across numerical and onnx libraries to 2
os.environ["OMP_NUM_THREADS"] = "2"
os.environ["MKL_NUM_THREADS"] = "2"
os.environ["OPENBLAS_NUM_THREADS"] = "2"
os.environ["VECLIB_MAXIMUM_THREADS"] = "2"
os.environ["NUMEXPR_NUM_THREADS"] = "2"

inference_lock = threading.Lock()
shutdown_event = threading.Event()
wallfx = None


def set_parent_death_signal():
    """Ensure kernel delivers SIGTERM to this process if parent process terminates."""
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6")
        PR_SET_PDEATHSIG = 1
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
    except Exception:
        pass


def ping_daemon(sock_path: str) -> bool:
    """Check if another daemon instance is already active and responsive."""
    if not os.path.exists(sock_path):
        return False
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.5)
        s.connect(sock_path)
        s.sendall(b"PING\n")
        resp = s.makefile("r", encoding="utf-8").readline().strip()
        s.close()
        return resp == "PONG"
    except Exception:
        return False


def load_wallfx_module():
    """Load the wallfx python script as an importable module."""
    global wallfx
    if wallfx is not None:
        return wallfx
    if not os.path.exists(WALLFX_BIN):
        raise FileNotFoundError(f"wallfx script not found at {WALLFX_BIN}")
    loader = importlib.machinery.SourceFileLoader("wallfx", WALLFX_BIN)
    spec = importlib.util.spec_from_loader("wallfx", loader)
    wallfx = importlib.util.module_from_spec(spec)
    loader.exec_module(wallfx)
    return wallfx


def init_birefnet_model():
    """Initialize BiRefNet ONCE in memory with SessionOptions intra_op_num_threads=2."""
    global wallfx
    load_wallfx_module()

    import onnxruntime as ort
    import rembg

    os.environ.setdefault("U2NET_HOME", os.path.join(wallfx.VENV, "models"))

    sess_opts = ort.SessionOptions()
    sess_opts.intra_op_num_threads = 2
    sess_opts.inter_op_num_threads = 2

    # Match execution provider selection from wallfx
    if wallfx._has_intel_gpu():
        try:
            providers = [
                ("OpenVINOExecutionProvider", {
                    "device_type": "GPU",
                    "cache_dir": os.path.join(wallfx.CACHE, "ov")
                }),
                "CPUExecutionProvider"
            ]
            session = rembg.new_session("birefnet-general-lite", sess_opts=sess_opts, providers=providers)
        except Exception as e:
            sys.stderr.write(f"[wallfx-daemon] OpenVINO GPU provider failed ({e}), falling back to CPU\n")
            session = rembg.new_session("birefnet-general-lite", sess_opts=sess_opts, providers=["CPUExecutionProvider"])
    else:
        session = rembg.new_session("birefnet-general-lite", sess_opts=sess_opts, providers=["CPUExecutionProvider"])

    # Store directly in wallfx._session so wallfx.perfil() reuses it
    wallfx._session = session
    return session


model_lock = threading.Lock()
idle_timer = None

def _reset_idle_timer():
    global idle_timer
    if idle_timer:
        idle_timer.cancel()
    # Unload model after 10 minutes (600s) of inactivity
    idle_timer = threading.Timer(600.0, _unload_model)
    idle_timer.daemon = True
    idle_timer.start()

def _unload_model():
    global wallfx
    with model_lock:
        if wallfx and hasattr(wallfx, "_session") and wallfx._session is not None:
            sys.stderr.write("[wallfx-daemon] 10 min idle reached: unloading BiRefNet model from memory\n")
            sys.stderr.flush()
            wallfx._session = None
            import gc
            gc.collect()

def ensure_model():
    """Ensure the BiRefNet model is loaded in memory when needed."""
    global wallfx
    with model_lock:
        load_wallfx_module()
        if not hasattr(wallfx, "_session") or wallfx._session is None:
            sys.stderr.write("[wallfx-daemon] Loading BiRefNet model on-demand...\n")
            sys.stderr.flush()
            t0 = time.time()
            init_birefnet_model()
            sys.stderr.write(f"[wallfx-daemon] Model ready ({time.time() - t0:.2f}s)\n")
            sys.stderr.flush()
        _reset_idle_timer()
        return wallfx._session


def daemon_contagio(img=None):
    """Retrieve contagion maps and renew the used pool slot asynchronously in a background thread."""
    global wallfx
    load_wallfx_module()
    path, liso = wallfx.spread()
    threading.Thread(target=wallfx.renew, args=(path,), daemon=True).start()
    return path, liso


def process_prepare(img_arg: str) -> str:
    """Handle PREPARE command: checks cache or runs perfil()."""
    global wallfx
    load_wallfx_module()

    path = os.path.expanduser(img_arg.strip().strip("'\""))
    path = os.path.realpath(path)

    if not os.path.isfile(path):
        return f"ERROR file not found: {path}"

    # 1. Check if configured as sin_perfil (always contagion)
    try:
        if os.path.basename(path) in wallfx.sin_perfil():
            c_map, c_liso = daemon_contagio(path)
            return f"contagio {c_map} {c_liso}"
    except Exception:
        pass

    # 2. Fast cache check
    base = os.path.join(wallfx.CACHE, "perfil", wallfx._key(path))
    meta_path = base + ".json"
    campo = base + "-campo.png"
    linea = base + "-linea.png"

    if os.path.exists(meta_path):
        try:
            with open(meta_path, "r", encoding="utf-8") as f:
                meta = json.load(f)
            if meta.get("ok"):
                if os.path.exists(campo) and os.path.exists(linea):
                    return f"perfil {campo} {linea}"
            else:
                # Wallpaper has no clear character (cached determination)
                c_map, c_liso = daemon_contagio(path)
                return f"contagio {c_map} {c_liso}"
        except Exception:
            pass

    # 3. Cache miss: Run perfil() with serialized inference
    with inference_lock:
        # Double check after acquiring lock
        if os.path.exists(meta_path):
            try:
                with open(meta_path, "r", encoding="utf-8") as f:
                    meta = json.load(f)
                if meta.get("ok"):
                    if os.path.exists(campo) and os.path.exists(linea):
                        return f"perfil {campo} {linea}"
                else:
                    c_map, c_liso = daemon_contagio(path)
                    return f"contagio {c_map} {c_liso}"
            except Exception:
                pass

        try:
            ensure_model()
            r = wallfx.perfil(path)
            if r and len(r) == 2 and os.path.exists(r[0]) and os.path.exists(r[1]):
                return f"perfil {r[0]} {r[1]}"
        except Exception as e:
            sys.stderr.write(f"[wallfx-daemon] Error in perfil for {path}: {e}\n")
            sys.stderr.flush()

    # Fallback to contagion if perfil returned None or failed
    try:
        c_map, c_liso = daemon_contagio(path)
        return f"contagio {c_map} {c_liso}"
    except Exception as e:
        return f"ERROR contagion failed: {e}"


def trigger_shutdown():
    """Signal daemon to shut down and unblock listener."""
    shutdown_event.set()


def handle_client(conn: socket.socket):
    """Handle connection from a client socket."""
    try:
        conn.settimeout(60.0)
        with conn:
            # Using raw bytes reading and writing to prevent Python text stream flush exceptions on disconnect
            reader = conn.makefile("rb")
            for raw_line in reader:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line:
                    continue

                if line == "PING":
                    try:
                        conn.sendall(b"PONG\n")
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        break
                elif line == "STOP":
                    trigger_shutdown()
                    try:
                        conn.sendall(b"OK\n")
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        pass
                    break
                elif line.startswith("PREPARE"):
                    img_arg = line[7:].strip()
                    resp = process_prepare(img_arg)
                    try:
                        conn.sendall((resp + "\n").encode("utf-8", errors="replace"))
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        break
                else:
                    try:
                        conn.sendall(f"ERROR unknown command: {line}\n".encode("utf-8"))
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        break
    except (BrokenPipeError, ConnectionResetError):
        pass
    except Exception as e:
        sys.stderr.write(f"[wallfx-daemon] Client error: {e}\n")
        sys.stderr.flush()


def main():
    set_parent_death_signal()
    # Prevent zombie processes when wallfx.contagio forks background renewers
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)

    # 1. Acquire singleton lock
    lock_file = open(LOCK_PATH, "a+")
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (BlockingIOError, IOError):
        if ping_daemon(SOCKET_PATH):
            sys.stderr.write("[wallfx-daemon] Another active daemon is already running. Exiting.\n")
            sys.exit(42)
        sys.stderr.write("[wallfx-daemon] Lock held by another process. Exiting.\n")
        sys.exit(42)

    lock_file.seek(0)
    lock_file.truncate()
    lock_file.write(f"{os.getpid()}\n")
    lock_file.flush()

    # 2. Cleanup stale socket if present
    if os.path.exists(SOCKET_PATH):
        try:
            os.unlink(SOCKET_PATH)
        except OSError:
            pass

    # 3. Create Unix domain socket with 0600 permissions
    server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old_umask = os.umask(0o077)
    try:
        server_sock.bind(SOCKET_PATH)
    finally:
        os.umask(old_umask)

    server_sock.listen(16)
    server_sock.settimeout(1.0)

    def cleanup():
        try:
            server_sock.close()
        except Exception:
            pass
        try:
            if os.path.exists(SOCKET_PATH):
                os.unlink(SOCKET_PATH)
        except OSError:
            pass
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
            lock_file.close()
        except Exception:
            pass

    atexit.register(cleanup)

    def sig_handler(sig, frame):
        shutdown_event.set()

    signal.signal(signal.SIGTERM, sig_handler)
    signal.signal(signal.SIGINT, sig_handler)

    # 4. BiRefNet model will be loaded lazily on first uncached request
    sys.stderr.write(f"[wallfx-daemon] Ready (lazy model loading enabled). Listening on {SOCKET_PATH}\n")
    sys.stderr.flush()

    # 5. Socket accept loop
    while not shutdown_event.is_set():
        try:
            conn, _ = server_sock.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        client_thread = threading.Thread(target=handle_client, args=(conn,), daemon=True)
        client_thread.start()

    sys.stderr.write("[wallfx-daemon] Shutting down...\n")
    sys.stderr.flush()
    cleanup()


if __name__ == "__main__":
    main()
