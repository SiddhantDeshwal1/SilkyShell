#!/usr/bin/env python3
"""
Quickshell High-Precision Real-time Lyrics Daemon & MPRIS Sync Engine.

Provides:
  - Process safety: singleton file locking (/tmp/quickshell_lyrics_daemon.lock),
    PR_SET_PDEATHSIG parent termination, SIGINT/SIGTERM handling, stdin HUP detection.
  - MPRIS D-Bus integration: connects to SessionBus, auto-discovers active player
    (prioritizes Spotify, falls back to any org.mpris.MediaPlayer2.*), listens to
    PropertiesChanged (Metadata, PlaybackStatus) and Seeked signals.
  - Provider integration: queries Spotify official color-lyrics (via sp_dc cookie)
    with seamless fallback to LRCLIB synced lyrics and local caching.
  - Monotonic high-precision timeline synchronization without continuous D-Bus polling.
  - Instrumental section and intro detection (> 5.0 second gaps).
  - Adaptive GLib event scheduling with 1.5s safety re-sync heartbeat.
  - Formatted JSON output stream on stdout.
  - CLI modes: 'daemon', 'current', and 'get-lyrics'.
"""

import bisect
import fcntl
import json
import logging
import os
import signal
import sys
import time
from typing import Any, Dict, List, Optional

# Ensure scripts directory is on sys.path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

# Parent death signal safety
try:
    from qs_daemon_base import set_parent_death_signal
except ImportError:
    def set_parent_death_signal():
        try:
            import ctypes
            libc = ctypes.CDLL("libc.so.6")
            PR_SET_PDEATHSIG = 1
            libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
        except Exception:
            pass

# Import lyrics providers
try:
    import lyrics_provider_lrclib
except ImportError:
    lyrics_provider_lrclib = None

try:
    import lyrics_provider_spotify
except ImportError:
    lyrics_provider_spotify = None

# D-Bus & GLib imports
import dbus
import dbus.mainloop.glib
from gi.repository import GLib

# Configure logger
logging.basicConfig(level=logging.WARNING, format="[lyrics-service] %(levelname)s: %(message)s")
logger = logging.getLogger("lyrics-service")

LOCK_PATH = "/tmp/quickshell_lyrics_daemon.lock"
_lock_file: Optional[Any] = None


def acquire_daemon_lock() -> bool:
    """Acquires singleton file lock. Exits immediately if another daemon is running."""
    global _lock_file
    try:
        _lock_file = open(LOCK_PATH, "a+")
        fcntl.flock(_lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        _lock_file.seek(0)
        _lock_file.truncate()
        _lock_file.write(f"{os.getpid()}\n")
        _lock_file.flush()
        return True
    except (BlockingIOError, IOError):
        sys.stderr.write("[lyrics-service] Another instance is already running. Exiting.\n")
        sys.stderr.flush()
        sys.exit(0)


def release_daemon_lock():
    """Releases singleton lock file."""
    global _lock_file
    if _lock_file:
        try:
            fcntl.flock(_lock_file.fileno(), fcntl.LOCK_UN)
            _lock_file.close()
            _lock_file = None
        except Exception:
            pass


def find_active_player(bus: dbus.Bus) -> Optional[str]:
    """
    Discovers active player on the SessionBus.
    Prioritizes org.mpris.MediaPlayer2.spotify, then falls back to any
    active player with org.mpris.MediaPlayer2.*.
    """
    try:
        names = bus.list_names()
    except Exception as e:
        logger.debug(f"Failed to list D-Bus names: {e}")
        return None

    mpris_players = [str(n) for n in names if str(n).startswith("org.mpris.MediaPlayer2.")]
    if not mpris_players:
        return None

    # Priority 1: Spotify
    if "org.mpris.MediaPlayer2.spotify" in mpris_players:
        return "org.mpris.MediaPlayer2.spotify"

    # Priority 2: Any real player currently Playing (ignore playerctld proxy if real player exists)
    real_players = [p for p in mpris_players if p != "org.mpris.MediaPlayer2.playerctld"]
    candidates = real_players if real_players else mpris_players

    for p in candidates:
        try:
            obj = bus.get_object(p, "/org/mpris/MediaPlayer2")
            props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
            st = str(props.Get("org.mpris.MediaPlayer2.Player", "PlaybackStatus"))
            if st == "Playing":
                return p
        except Exception:
            continue

    return candidates[0]


def parse_mpris_metadata(metadata_dict: Dict[str, Any]) -> Dict[str, Any]:
    """Extracts title, artist, album, duration, track_id from MPRIS Metadata dict."""
    title = str(metadata_dict.get("xesam:title", "")).strip()

    artist_field = metadata_dict.get("xesam:artist", "")
    if isinstance(artist_field, (list, tuple, dbus.Array)):
        artist = ", ".join(str(a).strip() for a in artist_field if str(a).strip())
    else:
        artist = str(artist_field).strip()

    album_field = metadata_dict.get("xesam:album", "")
    album = str(album_field).strip()

    length_us = metadata_dict.get("mpris:length", 0)
    try:
        duration = float(length_us) / 1_000_000.0
    except (ValueError, TypeError):
        duration = 0.0

    track_id = str(metadata_dict.get("mpris:trackid", "")).strip()

    return {
        "title": title,
        "artist": artist,
        "album": album,
        "duration": duration,
        "track_id": track_id,
    }


def find_active_line_index(lines: List[Dict[str, Any]], position: float) -> int:
    """
    Finds the index of the active lyric line for the given position in seconds.
    Uses binary search O(log N).
    Returns:
        -1 if position is before the first lyric line or if lines list is empty.
        0 .. len(lines) - 1 for active lines.
    """
    if not lines:
        return -1
    times = [l["time"] for l in lines]
    idx = bisect.bisect_right(times, position) - 1
    return idx


def fetch_synced_lyrics(
    title: str,
    artist: str,
    album: Optional[str] = None,
    duration: Optional[float] = None,
    track_id: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """
    Fetches synced lyrics:
    1. Checks Spotify provider if cookie exists and track_id is available.
    2. Falls back to LRCLIB with local caching.
    Returns:
        Sorted list of dicts: [{"time": float, "text": "..."}]
    """
    lines: Optional[List[Dict[str, Any]]] = None

    # Check Spotify color-lyrics provider first if cookie is available
    if lyrics_provider_spotify and track_id:
        try:
            cookie = lyrics_provider_spotify.get_spotify_cookie()
            if cookie:
                lines = lyrics_provider_spotify.fetch_lyrics_spotify(track_id, cookie)
        except Exception as e:
            logger.debug(f"Spotify color-lyrics lookup error: {e}")
            lines = None

    # Fallback to LRCLIB
    if not lines and lyrics_provider_lrclib and title and artist:
        try:
            raw_lrc = lyrics_provider_lrclib.fetch_lyrics_lrclib(
                title=title, artist=artist, album=album, duration=duration
            )
            if raw_lrc:
                lines = lyrics_provider_lrclib.parse_lrc(raw_lrc)
        except Exception as e:
            logger.debug(f"LRCLIB lyrics lookup error: {e}")
            lines = None

    if lines and isinstance(lines, list):
        cleaned_lines: List[Dict[str, Any]] = []
        for line in lines:
            if isinstance(line, dict) and "time" in line and "text" in line:
                try:
                    t = float(line["time"])
                    txt = str(line["text"]).strip()
                    if txt:
                        cleaned_lines.append({"time": round(t, 3), "text": txt})
                except (ValueError, TypeError):
                    continue
        cleaned_lines.sort(key=lambda x: x["time"])
        return cleaned_lines

    return []


class LyricsSyncEngine:
    """
    High-Precision Timeline Synchronization and State Computation Engine.
    Maintains last position and monotonic clock sync time.
    Calculates active lines, instrumental gaps, and adaptive scheduling timeouts.
    """

    INSTRUMENTAL_GAP_THRESHOLD = 5.0  # seconds

    def __init__(self, lines: Optional[List[Dict[str, Any]]] = None):
        self.lines: List[Dict[str, Any]] = lines if lines is not None else []
        self.has_lyrics: bool = len(self.lines) > 0
        self.last_position: float = 0.0
        self.last_sync_time: float = time.monotonic()
        self.playback_status: str = "Stopped"
        self.player_name: str = "spotify"
        self.title: str = ""
        self.artist: str = ""
        self.album: str = ""
        self.duration: float = 0.0
        self.track_id: str = ""

    def get_current_position(self) -> float:
        """Calculates current track position using monotonic clock if playing."""
        if self.playback_status == "Playing":
            elapsed = time.monotonic() - self.last_sync_time
            pos = self.last_position + elapsed
            if self.duration > 0 and pos > self.duration:
                return self.duration
            return max(0.0, pos)
        return max(0.0, self.last_position)

    def find_active_line_index(self, position: Optional[float] = None) -> int:
        """Finds index of the currently active lyric line."""
        pos = position if position is not None else self.get_current_position()
        return find_active_line_index(self.lines, pos)

    def get_sync_state(self, position: Optional[float] = None) -> Dict[str, Any]:
        """
        Computes the complete synchronized state dictionary.
        Handles line events, instrumental sections, and no-lyrics fallback.
        """
        pos = position if position is not None else self.get_current_position()

        if not self.has_lyrics or not self.lines:
            return {
                "type": "no_lyrics",
                "status": self.playback_status,
                "player": self.player_name,
                "track": self.title,
                "artist": self.artist,
                "hasLyrics": False,
                "currentLine": "",
                "nextLine": "",
                "lineIndex": -1,
                "totalLines": 0,
                "isInstrumental": False,
                "position": round(pos, 2),
            }

        total_lines = len(self.lines)
        idx = find_active_line_index(self.lines, pos)

        # Case 1: Intro before the first line
        if idx < 0:
            first_line_time = self.lines[0]["time"]
            next_text = self.lines[0]["text"]
            gap_to_next = first_line_time - pos
            is_inst = gap_to_next > self.INSTRUMENTAL_GAP_THRESHOLD

            if is_inst:
                return {
                    "type": "instrumental",
                    "status": self.playback_status,
                    "player": self.player_name,
                    "track": self.title,
                    "artist": self.artist,
                    "hasLyrics": True,
                    "currentLine": "♪ Instrumental ♪",
                    "nextLine": next_text,
                    "lineIndex": 0,
                    "totalLines": total_lines,
                    "isInstrumental": True,
                    "gapDuration": round(first_line_time, 2),
                    "position": round(pos, 2),
                }
            else:
                return {
                    "type": "line",
                    "status": self.playback_status,
                    "player": self.player_name,
                    "track": self.title,
                    "artist": self.artist,
                    "hasLyrics": True,
                    "currentLine": "♪ Instrumental ♪",
                    "nextLine": next_text,
                    "lineIndex": 0,
                    "totalLines": total_lines,
                    "isInstrumental": False,
                    "position": round(pos, 2),
                }

        # Case 2: Active line with possible upcoming line or interlude
        cur_entry = self.lines[idx]
        cur_time = cur_entry["time"]
        cur_text = cur_entry["text"]

        if idx + 1 < total_lines:
            next_entry = self.lines[idx + 1]
            next_time = next_entry["time"]
            next_text = next_entry["text"]
            total_gap = next_time - cur_time
            time_to_next = next_time - pos

            # Keep vocal line visible for minimum duration before instrumental transition
            vocal_display_sec = min(4.0, max(1.0, total_gap - 4.0))

            if total_gap > self.INSTRUMENTAL_GAP_THRESHOLD and (pos - cur_time) >= vocal_display_sec and time_to_next > self.INSTRUMENTAL_GAP_THRESHOLD:
                return {
                    "type": "instrumental",
                    "status": self.playback_status,
                    "player": self.player_name,
                    "track": self.title,
                    "artist": self.artist,
                    "hasLyrics": True,
                    "currentLine": "♪ Instrumental ♪",
                    "nextLine": next_text,
                    "lineIndex": idx,
                    "totalLines": total_lines,
                    "isInstrumental": True,
                    "gapDuration": round(total_gap, 2),
                    "position": round(pos, 2),
                }
            else:
                return {
                    "type": "line",
                    "status": self.playback_status,
                    "player": self.player_name,
                    "track": self.title,
                    "artist": self.artist,
                    "hasLyrics": True,
                    "currentLine": cur_text,
                    "nextLine": next_text,
                    "lineIndex": idx,
                    "totalLines": total_lines,
                    "isInstrumental": False,
                    "position": round(pos, 2),
                }
        else:
            # Case 3: Last line of track
            return {
                "type": "line",
                "status": self.playback_status,
                "player": self.player_name,
                "track": self.title,
                "artist": self.artist,
                "hasLyrics": True,
                "currentLine": cur_text,
                "nextLine": "",
                "lineIndex": idx,
                "totalLines": total_lines,
                "isInstrumental": False,
                "position": round(pos, 2),
            }

    def calculate_next_event_delay_ms(self, pos: float) -> int:
        """
        Calculates millisecond delay until next event (line start or instrumental transition).
        Safety clamped between 50ms and 1500ms (safety re-sync timer).
        """
        if not self.has_lyrics or not self.lines or self.playback_status != "Playing":
            return 1500

        total_lines = len(self.lines)
        idx = find_active_line_index(self.lines, pos)

        # Before first line
        if idx < 0:
            t0 = self.lines[0]["time"]
            gap = t0 - pos
            if gap > self.INSTRUMENTAL_GAP_THRESHOLD:
                sec_to_event = gap - self.INSTRUMENTAL_GAP_THRESHOLD
            else:
                sec_to_event = gap
            delay_ms = int(max(0.05, sec_to_event) * 1000)
            return max(50, min(1500, delay_ms))

        # At line idx
        cur_time = self.lines[idx]["time"]
        if idx + 1 < total_lines:
            next_time = self.lines[idx + 1]["time"]
            total_gap = next_time - cur_time
            time_to_next = next_time - pos
            vocal_display_sec = min(4.0, max(1.0, total_gap - 4.0))

            if total_gap > self.INSTRUMENTAL_GAP_THRESHOLD:
                if (pos - cur_time) < vocal_display_sec:
                    sec_to_event = (cur_time + vocal_display_sec) - pos
                elif time_to_next > self.INSTRUMENTAL_GAP_THRESHOLD:
                    sec_to_event = time_to_next - self.INSTRUMENTAL_GAP_THRESHOLD
                else:
                    sec_to_event = time_to_next
            else:
                sec_to_event = time_to_next

            delay_ms = int(max(0.05, sec_to_event) * 1000)
            return max(50, min(1500, delay_ms))
        else:
            if self.duration > pos:
                sec_to_event = self.duration - pos
                delay_ms = int(max(0.05, sec_to_event) * 1000)
                return max(50, min(1500, delay_ms))
            return 1500


class LyricsDaemon(LyricsSyncEngine):
    """
    D-Bus and GLib event-driven daemon service.
    Subscribes to MPRIS PropertiesChanged and Seeked signals.
    Emits JSON line updates on stdout.
    """

    def __init__(self, bus: Optional[dbus.Bus] = None, loop: Optional[GLib.MainLoop] = None):
        super().__init__()
        self.bus = bus
        self.loop = loop
        self.player_bus_name: Optional[str] = None
        self._tick_source_id: Optional[int] = None
        self._last_line_idx: int = -2
        self._last_is_inst: Optional[bool] = None
        self._last_status: Optional[str] = None
        self._last_line_text: Optional[str] = None
        self.last_emitted_json: Optional[str] = None

    def get_mpris_position(self) -> float:
        """Directly queries current Position property from MPRIS player."""
        if not self.bus or not self.player_bus_name:
            return 0.0
        try:
            player_obj = self.bus.get_object(self.player_bus_name, "/org/mpris/MediaPlayer2")
            props_iface = dbus.Interface(player_obj, "org.freedesktop.DBus.Properties")
            pos_us = props_iface.Get("org.mpris.MediaPlayer2.Player", "Position")
            return float(pos_us) / 1_000_000.0
        except Exception:
            return 0.0

    def load_lyrics(self):
        """Fetches and parses lyrics for the currently loaded track."""
        self.lines = fetch_synced_lyrics(
            title=self.title,
            artist=self.artist,
            album=self.album,
            duration=self.duration,
            track_id=self.track_id,
        )
        self.has_lyrics = len(self.lines) > 0

    def switch_player(self, player_bus_name: Optional[str]):
        """Switches active player and queries current state."""
        self.player_bus_name = player_bus_name
        if not player_bus_name or not self.bus:
            self.player_name = ""
            self.playback_status = "Stopped"
            self.title = ""
            self.artist = ""
            self.album = ""
            self.duration = 0.0
            self.track_id = ""
            self.lines = []
            self.has_lyrics = False
            self.emit_state(force=True)
            return

        self.player_name = player_bus_name.replace("org.mpris.MediaPlayer2.", "")
        try:
            player_obj = self.bus.get_object(player_bus_name, "/org/mpris/MediaPlayer2")
            props = dbus.Interface(player_obj, "org.freedesktop.DBus.Properties")
            self.playback_status = str(props.Get("org.mpris.MediaPlayer2.Player", "PlaybackStatus"))
            meta = props.Get("org.mpris.MediaPlayer2.Player", "Metadata")
            parsed_meta = parse_mpris_metadata(meta)
            self.title = parsed_meta["title"]
            self.artist = parsed_meta["artist"]
            self.album = parsed_meta["album"]
            self.duration = parsed_meta["duration"]
            self.track_id = parsed_meta["track_id"]
            self.load_lyrics()
            self.last_position = self.get_mpris_position()
            self.last_sync_time = time.monotonic()
        except Exception as e:
            logger.debug(f"Error querying player {player_bus_name}: {e}")

    def emit_state(self, force: bool = False):
        """Emits structured JSON to stdout if state has changed or forced."""
        st = self.get_sync_state()
        cur_idx = st.get("lineIndex")
        is_inst = st.get("isInstrumental")
        status = st.get("status")
        line_text = st.get("currentLine")

        changed = (
            force
            or cur_idx != self._last_line_idx
            or is_inst != self._last_is_inst
            or status != self._last_status
            or line_text != self._last_line_text
        )

        if changed:
            self._last_line_idx = cur_idx
            self._last_is_inst = is_inst
            self._last_status = status
            self._last_line_text = line_text
            encoded = json.dumps(st, ensure_ascii=False)
            self.last_emitted_json = encoded
            try:
                sys.stdout.write(encoded + "\n")
                sys.stdout.flush()
            except BrokenPipeError:
                if self.loop:
                    self.loop.quit()

    def reschedule_tick(self):
        """Schedules the next high-precision tick."""
        if self._tick_source_id:
            try:
                GLib.source_remove(self._tick_source_id)
            except Exception:
                pass
            self._tick_source_id = None

        pos = self.get_current_position()
        delay_ms = self.calculate_next_event_delay_ms(pos)
        self._tick_source_id = GLib.timeout_add(delay_ms, self._on_tick_wrapper)

    def _on_tick_wrapper(self) -> bool:
        self._tick_source_id = None
        self.on_tick()
        return False  # GLib one-shot callback

    def on_tick(self):
        """Tick handler executed when an event delay expires or on safety interval."""
        if self.playback_status == "Playing" and self.bus and self.player_bus_name:
            mpris_pos = self.get_mpris_position()
            calc_pos = self.get_current_position()
            if abs(mpris_pos - calc_pos) > 0.4 and mpris_pos > 0.05:
                self.last_position = mpris_pos
                self.last_sync_time = time.monotonic()

        self.emit_state(force=False)
        self.reschedule_tick()

    def on_properties_changed(self, iface: str, changed_props: Dict[str, Any], invalidated_props: List[str]):
        """D-Bus signal handler for PropertiesChanged."""
        if iface != "org.mpris.MediaPlayer2.Player":
            return

        status_changed = "PlaybackStatus" in changed_props
        meta_changed = "Metadata" in changed_props

        if status_changed:
            new_status = str(changed_props["PlaybackStatus"])
            self.last_position = self.get_mpris_position()
            self.last_sync_time = time.monotonic()
            self.playback_status = new_status

        if meta_changed:
            new_meta = parse_mpris_metadata(changed_props["Metadata"])
            if (
                new_meta["title"] != self.title
                or new_meta["artist"] != self.artist
                or new_meta["track_id"] != self.track_id
            ):
                self.title = new_meta["title"]
                self.artist = new_meta["artist"]
                self.album = new_meta["album"]
                self.duration = new_meta["duration"]
                self.track_id = new_meta["track_id"]
                self.load_lyrics()
                self.last_position = self.get_mpris_position()
                self.last_sync_time = time.monotonic()

        if status_changed or meta_changed:
            self.emit_state(force=True)
            self.reschedule_tick()

    def on_seeked(self, position_us: int):
        """D-Bus signal handler for Seeked signal."""
        pos_sec = float(position_us) / 1_000_000.0
        self.last_position = pos_sec
        self.last_sync_time = time.monotonic()
        self.emit_state(force=True)
        self.reschedule_tick()

    def on_name_owner_changed(self, name: str, old_owner: str, new_owner: str):
        """D-Bus signal handler for MPRIS player additions and removals."""
        if name.startswith("org.mpris.MediaPlayer2."):
            new_player = find_active_player(self.bus)
            if new_player != self.player_bus_name:
                self.switch_player(new_player)
                self.reschedule_tick()


def cmd_current():
    """One-shot query: prints current lyric line JSON and exits."""
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    player = find_active_player(bus)
    daemon = LyricsDaemon(bus=bus)
    if player:
        daemon.switch_player(player)
    st = daemon.get_sync_state()
    print(json.dumps(st, ensure_ascii=False))


def cmd_get_lyrics():
    """One-shot query: prints all synced lyrics JSON list and exits."""
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    player = find_active_player(bus)
    daemon = LyricsDaemon(bus=bus)
    if player:
        daemon.switch_player(player)
    print(json.dumps(daemon.lines, ensure_ascii=False))


def cmd_daemon():
    """Runs the main daemon loop with singleton lock and live streaming."""
    set_parent_death_signal()
    acquire_daemon_lock()

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    loop = GLib.MainLoop()

    daemon = LyricsDaemon(bus=bus, loop=loop)

    def on_shutdown(*args):
        release_daemon_lock()
        loop.quit()

    signal.signal(signal.SIGINT, on_shutdown)
    signal.signal(signal.SIGTERM, on_shutdown)

    # Monitor stdin for HUP (Quickshell restart terminates pipe)
    try:
        def on_stdin_hup(source, condition):
            on_shutdown()
            return False

        GLib.io_add_watch(0, GLib.IOCondition.HUP | GLib.IOCondition.ERR, on_stdin_hup)
    except Exception:
        pass

    # Subscriptions
    bus.add_signal_receiver(
        daemon.on_properties_changed,
        signal_name="PropertiesChanged",
        dbus_interface="org.freedesktop.DBus.Properties",
        path="/org/mpris/MediaPlayer2",
    )
    bus.add_signal_receiver(
        daemon.on_seeked,
        signal_name="Seeked",
        dbus_interface="org.mpris.MediaPlayer2.Player",
        path="/org/mpris/MediaPlayer2",
    )
    bus.add_signal_receiver(
        daemon.on_name_owner_changed,
        signal_name="NameOwnerChanged",
        dbus_interface="org.freedesktop.DBus",
        bus_name="org.freedesktop.DBus",
    )

    # Connect to active player
    player = find_active_player(bus)
    daemon.switch_player(player)

    # Emit initial state
    daemon.emit_state(force=True)

    # Start adaptive scheduling
    daemon.reschedule_tick()

    try:
        loop.run()
    except (KeyboardInterrupt, SystemExit):
        on_shutdown()


def main():
    mode = "daemon"
    if len(sys.argv) > 1:
        mode = sys.argv[1].strip()

    if mode == "current":
        cmd_current()
    elif mode == "get-lyrics":
        cmd_get_lyrics()
    elif mode == "daemon":
        cmd_daemon()
    else:
        sys.stderr.write(f"Usage: lyrics-service.py [daemon|current|get-lyrics]\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
