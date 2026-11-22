#!/usr/bin/env python3
"""
Unit tests and verification suite for Quickshell Lyrics Service & LRCLIB Provider.

Covers:
1. Title and artist name sanitization in lyrics_provider_lrclib:
   - Parenthetical / bracketed features: "Song Name (feat. Artist)" -> "Song Name"
   - Remastered tags: "Song Name - Remastered 2021" -> "Song Name"
   - Live recording markers: "Song Name (Live at Wembley)" -> "Song Name"
   - Special devotional / subtitle queries: "Hey Ram Hey Ram Shree Ram Dhun" -> "Hey Ram Hey Ram"
   - Multi-artist delimiter handling: commas, slashes, semicolons, feat clauses
2. LRC timestamp parsing:
   - Standard centisecond format: [01:23.45] -> 83.45s
   - Millisecond format: [01:23.456] -> 83.456s
   - Multi-timestamp single-line expansion: [00:10.00][00:20.00] repeated chorus -> 2 distinct entries
   - Metadata headers ignored: [ti:...], [ar:...], [length:...], etc.
   - Out-of-order timestamp sorting
   - Blank lines and whitespace filtering
3. Timeline binary search & active line matching:
   - Target positions: t=5.0 (before first line), t=10.0 (line 0), t=18.5 (line 0),
     t=20.0 (line 1), t=55.0 (line 3 / last line)
   - Edge cases: t=0.0, exact line boundaries, empty line lists
4. Instrumental section detection:
   - Interlude gap detection between lines (e.g. gap between 22.0 and 35.0 = 13.0s > 5.0s)
   - Intro instrumental detection before first line (> 5.0s)
   - Normal small gaps (<= 5.0s) retaining vocal line state
   - Transition state properties (type == 'instrumental', isInstrumental == True)
5. Disk cache operations:
   - Temporary cache directory isolation
   - Saving and loading raw .lrc files
   - Safe slug generation across unicode and special characters
   - Cache hit via cleaned title fallback
6. MPRIS metadata extraction & Monotonic clock sync:
   - Parsing title, artist array, album, length (us -> s), track ID
   - Monotonic position advancement during playback
"""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch

# Ensure quickshell scripts directory is in sys.path
SCRIPTS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "scripts"))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

# Import lyrics_provider_lrclib
import lyrics_provider_lrclib as lrclib

# Dynamically import lyrics-service.py (contains hyphen in filename)
SERVICE_PATH = os.path.join(SCRIPTS_DIR, "lyrics-service.py")
_spec = importlib.util.spec_from_file_location("lyrics_service", SERVICE_PATH)
lyrics_service = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lyrics_service)


class TestTitleCleaning(unittest.TestCase):
    """
    Verification of title and artist cleaning logic in lyrics_provider_lrclib.
    Ensures noisy streaming metadata is cleaned for optimal LRCLIB search accuracy.
    """

    def test_feat_artist_parentheses(self):
        """'Song Name (feat. Artist)' -> 'Song Name'"""
        raw = "Song Name (feat. Artist)"
        self.assertEqual(lrclib.clean_track_title(raw), "Song Name")

    def test_feat_artist_bracket(self):
        """'Song Name [feat. Artist]' -> 'Song Name'"""
        raw = "Song Name [feat. Artist]"
        self.assertEqual(lrclib.clean_track_title(raw), "Song Name")

    def test_remastered_dash_format(self):
        """'Song Name - Remastered 2021' -> 'Song Name'"""
        raw = "Song Name - Remastered 2021"
        self.assertEqual(lrclib.clean_track_title(raw), "Song Name")

    def test_remastered_bracket_format(self):
        """'Song Name [2011 Remaster]' -> 'Song Name'"""
        raw = "Song Name [2011 Remaster]"
        self.assertEqual(lrclib.clean_track_title(raw), "Song Name")

    def test_live_recording_parentheses(self):
        """'Song Name (Live at Wembley)' -> 'Song Name'"""
        raw = "Song Name (Live at Wembley)"
        self.assertEqual(lrclib.clean_track_title(raw), "Song Name")

    def test_live_recording_dash(self):
        """'Song Name - Live at Tokyo Dome' -> 'Song Name'"""
        raw = "Song Name - Live at Tokyo Dome"
        self.assertEqual(lrclib.clean_track_title(raw), "Song Name")

    def test_hey_ram_dhun_cleaning(self):
        """'Hey Ram Hey Ram Shree Ram Dhun' -> 'Hey Ram Hey Ram'"""
        raw = "Hey Ram Hey Ram Shree Ram Dhun"
        self.assertEqual(lrclib.clean_track_title(raw), "Hey Ram Hey Ram")

    def test_hey_ram_dhun_with_dash(self):
        """'Hey Ram Hey Ram - Shree Ram Dhun' -> 'Hey Ram Hey Ram'"""
        raw = "Hey Ram Hey Ram - Shree Ram Dhun"
        self.assertEqual(lrclib.clean_track_title(raw), "Hey Ram Hey Ram")

    def test_hey_ram_dhun_with_brackets(self):
        """'Hey Ram Hey Ram (Shree Ram Dhun)' -> 'Hey Ram Hey Ram'"""
        raw = "Hey Ram Hey Ram (Shree Ram Dhun)"
        self.assertEqual(lrclib.clean_track_title(raw), "Hey Ram Hey Ram")

    def test_multi_artist_comma_separated(self):
        """Multi-artist strings with commas: primary artist extracted."""
        raw = "Jagjit Singh, Chitra Singh"
        self.assertEqual(lrclib.clean_artist_name(raw), "Jagjit Singh")

    def test_multi_artist_slash_separated(self):
        """Multi-artist strings with slashes: primary artist extracted."""
        raw = "Queen / David Bowie"
        self.assertEqual(lrclib.clean_artist_name(raw), "Queen")

    def test_multi_artist_semicolon_separated(self):
        """Multi-artist strings with semicolons: primary artist extracted."""
        raw = "Daft Punk; Pharrell Williams"
        self.assertEqual(lrclib.clean_artist_name(raw), "Daft Punk")

    def test_multi_artist_feat_clause(self):
        """'Artist A feat. Artist B' in artist field: primary artist extracted."""
        raw = "Major Lazer feat. Justin Bieber"
        self.assertEqual(lrclib.clean_artist_name(raw), "Major Lazer")

    def test_unparenthesized_trailing_feat(self):
        """'Song Name feat. Guest' -> 'Song Name'"""
        raw = "Song Name feat. Guest"
        self.assertEqual(lrclib.clean_track_title(raw), "Song Name")

    def test_bonus_track_suffix(self):
        """'Song Name - Bonus Track' -> 'Song Name'"""
        raw = "Song Name - Bonus Track"
        self.assertEqual(lrclib.clean_track_title(raw), "Song Name")

    def test_already_clean_title(self):
        """Clean titles without noise remain untouched."""
        self.assertEqual(lrclib.clean_track_title("Bohemian Rhapsody"), "Bohemian Rhapsody")
        self.assertEqual(lrclib.clean_artist_name("Queen"), "Queen")

    def test_empty_and_whitespace_inputs(self):
        """Empty or None values handled gracefully."""
        self.assertEqual(lrclib.clean_track_title(""), "")
        self.assertEqual(lrclib.clean_track_title("   "), "")
        self.assertEqual(lrclib.clean_track_title(None), "")
        self.assertEqual(lrclib.clean_artist_name(""), "")
        self.assertEqual(lrclib.clean_artist_name(None), "")


class TestLrcTimestampParser(unittest.TestCase):
    """
    Verification of the .lrc timestamp parser in lyrics_provider_lrclib.
    Validates various timestamp formats, multi-timestamps, metadata filtering,
    out-of-order sorting, and whitespace robustness.
    """

    def test_standard_timestamp_format(self):
        """Standard format [01:23.45] lyric text -> 83.45 seconds."""
        lrc = "[01:23.45] lyric text"
        lines = lrclib.parse_lrc(lrc)
        self.assertEqual(len(lines), 1)
        self.assertAlmostEqual(lines[0]["time"], 83.45, places=2)
        self.assertEqual(lines[0]["text"], "lyric text")

    def test_millisecond_timestamp_format(self):
        """Millisecond format [01:23.456] lyric text -> 83.456 seconds."""
        lrc = "[01:23.456] lyric text"
        lines = lrclib.parse_lrc(lrc)
        self.assertEqual(len(lines), 1)
        self.assertAlmostEqual(lines[0]["time"], 83.456, places=3)
        self.assertEqual(lines[0]["text"], "lyric text")

    def test_multiple_timestamps_single_line(self):
        """
        Multiple timestamps on one line:
        '[00:10.00][00:20.00] repeated chorus' -> two distinct timestamped entries.
        """
        lrc = "[00:10.00][00:20.00] repeated chorus"
        lines = lrclib.parse_lrc(lrc)
        self.assertEqual(len(lines), 2)
        self.assertAlmostEqual(lines[0]["time"], 10.0, places=2)
        self.assertEqual(lines[0]["text"], "repeated chorus")
        self.assertAlmostEqual(lines[1]["time"], 20.0, places=2)
        self.assertEqual(lines[1]["text"], "repeated chorus")

    def test_three_timestamps_single_line(self):
        """Three timestamps on one line produce three separate entries."""
        lrc = "[00:05.00][00:15.50][00:25.00] triple hook"
        lines = lrclib.parse_lrc(lrc)
        self.assertEqual(len(lines), 3)
        self.assertEqual([l["time"] for l in lines], [5.0, 15.5, 25.0])
        self.assertTrue(all(l["text"] == "triple hook" for l in lines))

    def test_metadata_tags_ignored(self):
        """Metadata tags: [ti:Title], [ar:Artist], [length: 3:45], [al:Album] are ignored."""
        lrc = """[ti:Title]
[ar:Artist]
[al:Album Name]
[by:Creator]
[length: 3:45]
[offset:0]
[00:12.34] Valid lyric line
"""
        lines = lrclib.parse_lrc(lrc)
        self.assertEqual(len(lines), 1)
        self.assertAlmostEqual(lines[0]["time"], 12.34, places=2)
        self.assertEqual(lines[0]["text"], "Valid lyric line")

    def test_out_of_order_lines_sorted(self):
        """Out of order lines are correctly sorted ascending by timestamp."""
        lrc = """[00:45.00] Third line
[00:10.00] First line
[00:25.50] Second line
"""
        lines = lrclib.parse_lrc(lrc)
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[0]["text"], "First line")
        self.assertAlmostEqual(lines[0]["time"], 10.0, places=2)
        self.assertEqual(lines[1]["text"], "Second line")
        self.assertAlmostEqual(lines[1]["time"], 25.5, places=2)
        self.assertEqual(lines[2]["text"], "Third line")
        self.assertAlmostEqual(lines[2]["time"], 45.0, places=2)

    def test_whitespace_and_blank_lines_handled(self):
        """Whitespace and blank lines are ignored without producing empty entries."""
        lrc = """
        
[00:10.00] Normal line

[00:20.00]    
[00:30.00]               \t   
[00:40.00] Another valid line

"""
        lines = lrclib.parse_lrc(lrc)
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0]["text"], "Normal line")
        self.assertEqual(lines[1]["text"], "Another valid line")

    def test_empty_or_invalid_inputs(self):
        """Non-string or empty inputs safely return empty list."""
        self.assertEqual(lrclib.parse_lrc(""), [])
        self.assertEqual(lrclib.parse_lrc("   \n\t  "), [])
        self.assertEqual(lrclib.parse_lrc(None), [])
        self.assertEqual(lrclib.parse_lrc(12345), [])

    def test_colon_milliseconds_format(self):
        """Handles non-standard [mm:ss:xx] colon format gracefully."""
        lrc = "[01:10:50] Colon separated fractions"
        lines = lrclib.parse_lrc(lrc)
        self.assertEqual(len(lines), 1)
        self.assertAlmostEqual(lines[0]["time"], 70.50, places=2)


class TestTimelineBinarySearch(unittest.TestCase):
    """
    Verification of timeline binary search and active line matching.
    Requirement:
      Given a list of lines with timestamps [10.0, 20.0, 35.0, 50.0]:
        - at t=5.0: before first line (index -1)
        - at t=10.0: line 0
        - at t=18.5: line 0
        - at t=20.0: line 1
        - at t=55.0: line 3
    """

    def setUp(self):
        self.sample_lines = [
            {"time": 10.0, "text": "Line 0 (t=10.0)"},
            {"time": 20.0, "text": "Line 1 (t=20.0)"},
            {"time": 35.0, "text": "Line 2 (t=35.0)"},
            {"time": 50.0, "text": "Line 3 (t=50.0)"},
        ]
        self.engine = lyrics_service.LyricsSyncEngine(self.sample_lines)

    def test_binary_search_before_first_line(self):
        """at t=5.0: before first line -> index -1."""
        idx = lyrics_service.find_active_line_index(self.sample_lines, 5.0)
        self.assertEqual(idx, -1)
        self.assertEqual(self.engine.find_active_line_index(5.0), -1)

    def test_binary_search_exact_line_0(self):
        """at t=10.0: line 0."""
        idx = lyrics_service.find_active_line_index(self.sample_lines, 10.0)
        self.assertEqual(idx, 0)
        self.assertEqual(self.engine.find_active_line_index(10.0), 0)

    def test_binary_search_mid_line_0(self):
        """at t=18.5: line 0."""
        idx = lyrics_service.find_active_line_index(self.sample_lines, 18.5)
        self.assertEqual(idx, 0)
        self.assertEqual(self.engine.find_active_line_index(18.5), 0)

    def test_binary_search_exact_line_1(self):
        """at t=20.0: line 1."""
        idx = lyrics_service.find_active_line_index(self.sample_lines, 20.0)
        self.assertEqual(idx, 1)
        self.assertEqual(self.engine.find_active_line_index(20.0), 1)

    def test_binary_search_mid_line_2(self):
        """at t=35.0 and t=42.0: line 2."""
        self.assertEqual(lyrics_service.find_active_line_index(self.sample_lines, 35.0), 2)
        self.assertEqual(lyrics_service.find_active_line_index(self.sample_lines, 42.0), 2)

    def test_binary_search_last_line_and_beyond(self):
        """at t=50.0 and t=55.0: line 3 (last line)."""
        self.assertEqual(lyrics_service.find_active_line_index(self.sample_lines, 50.0), 3)
        self.assertEqual(lyrics_service.find_active_line_index(self.sample_lines, 55.0), 3)
        self.assertEqual(self.engine.find_active_line_index(55.0), 3)

    def test_binary_search_zero_timestamp(self):
        """at t=0.0: returns -1 when first line starts after 0.0."""
        self.assertEqual(lyrics_service.find_active_line_index(self.sample_lines, 0.0), -1)

    def test_binary_search_empty_lines(self):
        """Empty lines list returns -1 for any timestamp."""
        self.assertEqual(lyrics_service.find_active_line_index([], 10.0), -1)
        empty_engine = lyrics_service.LyricsSyncEngine([])
        self.assertEqual(empty_engine.find_active_line_index(10.0), -1)

    def test_binary_search_single_line(self):
        """Single line at t=15.0: -1 before 15.0, 0 at and after 15.0."""
        single = [{"time": 15.0, "text": "Only line"}]
        self.assertEqual(lyrics_service.find_active_line_index(single, 14.9), -1)
        self.assertEqual(lyrics_service.find_active_line_index(single, 15.0), 0)
        self.assertEqual(lyrics_service.find_active_line_index(single, 100.0), 0)


class TestInstrumentalDetection(unittest.TestCase):
    """
    Verification of instrumental detection logic.
    Requirement:
      Gap between line 1 (ends at 22.0) and line 2 (starts at 35.0)
      has gap 13.0s > 5.0s -> detects instrumental.
    """

    def setUp(self):
        # Line 0 starts at 10.0
        # Line 1 starts at 20.0 (ends at ~22.0)
        # Line 2 starts at 35.0 (gap = 35.0 - 22.0 = 13.0s > 5.0s)
        # Line 3 starts at 38.0 (gap = 38.0 - 35.0 = 3.0s <= 5.0s, normal transition)
        self.lines = [
            {"time": 10.0, "text": "Line 0: The journey starts here"},
            {"time": 20.0, "text": "Line 1: Sing before the long guitar solo"},
            {"time": 35.0, "text": "Line 2: Singing resumes after the solo"},
            {"time": 38.0, "text": "Line 3: Quick follow-up line"},
        ]
        self.engine = lyrics_service.LyricsSyncEngine(self.lines)
        self.engine.playback_status = "Playing"
        self.engine.title = "Test Song"
        self.engine.artist = "Test Artist"
        self.engine.duration = 60.0

    def test_instrumental_gap_between_line_1_and_line_2(self):
        """
        Gap between line 1 (ends ~22.0s) and line 2 (starts at 35.0s):
        Gap is 13.0s > 5.0s. At t=26.0s (during the solo), instrumental is detected.
        """
        state = self.engine.get_sync_state(position=26.0)
        self.assertTrue(state["hasLyrics"])
        self.assertTrue(state["isInstrumental"], "Should detect instrumental gap > 5.0s")
        self.assertEqual(state["type"], "instrumental")
        self.assertEqual(state["currentLine"], "♪ Instrumental ♪")
        self.assertEqual(state["nextLine"], "Line 2: Singing resumes after the solo")

    def test_instrumental_gap_calculation_helper(self):
        """Direct verification of gap calculation logic (35.0 - 22.0 = 13.0s > 5.0s)."""
        line_1_end = 22.0
        line_2_start = 35.0
        gap = line_2_start - line_1_end
        self.assertEqual(gap, 13.0)
        self.assertGreater(gap, self.engine.INSTRUMENTAL_GAP_THRESHOLD)

    def test_vocal_line_active_during_singing(self):
        """At t=20.5 (just after line 1 starts), lyrics mode is active, not instrumental."""
        state = self.engine.get_sync_state(position=20.5)
        self.assertFalse(state["isInstrumental"])
        self.assertEqual(state["type"], "line")
        self.assertEqual(state["currentLine"], "Line 1: Sing before the long guitar solo")
        self.assertEqual(state["nextLine"], "Line 2: Singing resumes after the solo")

    def test_resumption_of_vocals_after_instrumental(self):
        """At t=35.0s, vocal singing resumes and instrumental flag is cleared."""
        state = self.engine.get_sync_state(position=35.0)
        self.assertFalse(state["isInstrumental"])
        self.assertEqual(state["type"], "line")
        self.assertEqual(state["currentLine"], "Line 2: Singing resumes after the solo")
        self.assertEqual(state["nextLine"], "Line 3: Quick follow-up line")

    def test_no_instrumental_for_short_gap(self):
        """Between line 2 (35.0s) and line 3 (38.0s), gap is 3.0s <= 5.0s: no instrumental."""
        state = self.engine.get_sync_state(position=36.5)
        self.assertFalse(state["isInstrumental"])
        self.assertEqual(state["type"], "line")

    def test_intro_instrumental_detection(self):
        """Intro before first line (starts at 10.0s): at t=2.0s, gap is 8.0s > 5.0s -> instrumental."""
        state = self.engine.get_sync_state(position=2.0)
        self.assertTrue(state["isInstrumental"])
        self.assertEqual(state["type"], "instrumental")
        self.assertEqual(state["currentLine"], "♪ Instrumental ♪")
        self.assertEqual(state["nextLine"], "Line 0: The journey starts here")

    def test_short_intro_no_instrumental(self):
        """Intro before first line when first line is at 3.0s (gap <= 5.0s): not instrumental."""
        quick_lines = [{"time": 3.0, "text": "Early vocal"}]
        engine = lyrics_service.LyricsSyncEngine(quick_lines)
        engine.playback_status = "Playing"
        state = engine.get_sync_state(position=1.0)
        self.assertFalse(state["isInstrumental"])


class TestDiskCache(unittest.TestCase):
    """
    Verification of local disk cache in lyrics_provider_lrclib.
    Uses temporary directory isolation to test saving and loading .lrc files.
    """

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory(prefix="qs_lyrics_test_")
        self.temp_path = Path(self.temp_dir.name)
        # Monkeypatch DEFAULT_CACHE_DIR to isolated temp directory
        self.original_cache_dir = lrclib.DEFAULT_CACHE_DIR
        lrclib.DEFAULT_CACHE_DIR = self.temp_path

    def tearDown(self):
        lrclib.DEFAULT_CACHE_DIR = self.original_cache_dir
        self.temp_dir.cleanup()

    def test_save_and_load_cached_lyrics(self):
        """Save .lrc content to cache and successfully load it back."""
        title = "Bohemian Rhapsody"
        artist = "Queen"
        lrc_content = """[00:01.50]Is this the real life?
[00:05.12]Is this just fantasy?
[00:08.50]Caught in a landslide, no escape from reality
"""
        saved_path = lrclib.save_cached_lyrics(title, artist, lrc_content)
        self.assertIsNotNone(saved_path)
        self.assertTrue(saved_path.is_file(), f"Expected cache file at {saved_path}")

        loaded_content = lrclib.load_cached_lyrics(title, artist)
        self.assertEqual(loaded_content, lrc_content.strip())

    def test_load_nonexistent_cache(self):
        """Attempting to load uncached track returns None."""
        loaded = lrclib.load_cached_lyrics("Unknown Track", "Ghost Artist")
        self.assertIsNone(loaded)

    def test_safe_slug_generation(self):
        """Filesystem safe slug handles slashes, spaces, accents, and punctuation."""
        slug1 = lrclib.make_safe_slug("Queen / Bowie", "Under Pressure (feat. Bowie)")
        self.assertNotIn("/", slug1)
        self.assertNotIn(" ", slug1)
        self.assertNotIn("(", slug1)

        slug2 = lrclib.make_safe_slug("Jagjit Singh", "Hey Ram Hey Ram")
        self.assertEqual(slug2, "jagjit_singh_hey_ram_hey_ram")

    def test_cache_retrieval_via_cleaned_title_variant(self):
        """
        Saving lyrics for cleaned title allows lookup using noisy Spotify title:
        e.g. saved as 'Song Name' by 'Artist', queried as 'Song Name (feat. Other)'.
        """
        lrclib.save_cached_lyrics("Song Name", "Artist", "[00:10.00] Test line")
        # Load with noisy title
        loaded = lrclib.load_cached_lyrics("Song Name (feat. Other)", "Artist")
        self.assertEqual(loaded, "[00:10.00] Test line")

    def test_empty_content_not_cached(self):
        """Empty string or None is rejected and not written to disk."""
        self.assertIsNone(lrclib.save_cached_lyrics("Title", "Artist", ""))
        self.assertIsNone(lrclib.save_cached_lyrics("Title", "Artist", None))
        self.assertEqual(len(list(self.temp_path.glob("*.lrc"))), 0)


class TestLyricsServiceMPRISParsing(unittest.TestCase):
    """
    Verification of MPRIS metadata parsing and monotonic clock calculations
    in lyrics-service.py.
    """

    def test_parse_mpris_metadata_valid(self):
        """Parses valid MPRIS metadata dict into standardized schema."""
        raw_meta = {
            "xesam:title": "Bohemian Rhapsody - Remastered 2011",
            "xesam:artist": ["Queen"],
            "xesam:album": "A Night at the Opera",
            "mpris:length": 354_000_000,  # 354 seconds in microseconds
            "mpris:trackid": "spotify:track:4cOdK2wGLETKBW3PvgPWqT",
        }
        parsed = lyrics_service.parse_mpris_metadata(raw_meta)
        self.assertEqual(parsed["title"], "Bohemian Rhapsody - Remastered 2011")
        self.assertEqual(parsed["artist"], "Queen")
        self.assertEqual(parsed["album"], "A Night at the Opera")
        self.assertAlmostEqual(parsed["duration"], 354.0, places=1)
        self.assertEqual(parsed["track_id"], "spotify:track:4cOdK2wGLETKBW3PvgPWqT")

    def test_parse_mpris_metadata_string_artist(self):
        """Handles single string xesam:artist as well as array."""
        raw_meta = {
            "xesam:title": "Single Artist Track",
            "xesam:artist": "Solo Singer",
            "mpris:length": 180_000_000,
        }
        parsed = lyrics_service.parse_mpris_metadata(raw_meta)
        self.assertEqual(parsed["artist"], "Solo Singer")
        self.assertAlmostEqual(parsed["duration"], 180.0, places=1)

    def test_monotonic_clock_advancement(self):
        """
        LyricsSyncEngine monotonic clock advances position when Playing,
        and stays static when Paused.
        """
        engine = lyrics_service.LyricsSyncEngine([])
        engine.playback_status = "Playing"
        engine.last_position = 20.0
        engine.last_sync_time = time.monotonic() - 2.5  # 2.5s elapsed

        pos = engine.get_current_position()
        self.assertAlmostEqual(pos, 22.5, delta=0.2)

        # When paused
        engine.playback_status = "Paused"
        engine.last_position = 22.5
        engine.last_sync_time = time.monotonic() - 5.0  # 5s passed while paused
        self.assertEqual(engine.get_current_position(), 22.5)

    def test_adaptive_event_delay_clamping(self):
        """Event delay calculation is bounded between 50ms and 1500ms safety timer."""
        lines = [
            {"time": 10.0, "text": "Line 0"},
            {"time": 20.0, "text": "Line 1"},
        ]
        engine = lyrics_service.LyricsSyncEngine(lines)
        engine.playback_status = "Playing"

        # At t=9.95s, 50ms before line 0
        delay = engine.calculate_next_event_delay_ms(9.95)
        self.assertGreaterEqual(delay, 50)
        self.assertLessEqual(delay, 1500)

        # When stopped or no lyrics, defaults to 1500ms safety interval
        engine.playback_status = "Stopped"
        self.assertEqual(engine.calculate_next_event_delay_ms(5.0), 1500)


if __name__ == "__main__":
    unittest.main()
