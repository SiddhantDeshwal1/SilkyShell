#!/usr/bin/env python3
"""
LRCLIB lyrics provider and LRC parser module for Quickshell.

Features:
- Cleans Spotify/streaming track titles and artist names.
- Parses standard .lrc files (timestamps, multi-timestamps, metadata filtering).
- Fetches synchronized lyrics from LRCLIB via standard library urllib.
- Caches lyrics locally in ~/.cache/quickshell/lyrics/.
- Provides CLI interface for testing and debugging.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger("lyrics_provider_lrclib")

DEFAULT_CACHE_DIR = (
    Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    / "quickshell"
    / "lyrics"
)
USER_AGENT = "QuickShell-Lyrics/1.0 (https://github.com/quickshell)"


# ============================================================================
# Caching Functions
# ============================================================================


def make_safe_slug(artist: str, title: str) -> str:
    """
    Generate a filesystem-safe slug based on artist and track title.
    Normalizes unicode and replaces non-alphanumeric characters with underscores.
    """
    combined = f"{artist}_{title}".strip().lower()
    normalized = unicodedata.normalize("NFKD", combined)
    slug = re.sub(r"[^\w\-]+", "_", normalized).strip("_")
    slug = re.sub(r"_+", "_", slug)
    if not slug:
        slug = "track"
    return slug[:180]


def get_cache_dir() -> Path:
    """Return the lyrics cache directory path, ensuring it exists."""
    cache_dir = DEFAULT_CACHE_DIR
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir


def get_cache_path(title: str, artist: str) -> Path:
    """Get the .lrc file path for the given title and artist."""
    slug = make_safe_slug(artist, title)
    return get_cache_dir() / f"{slug}.lrc"


def load_cached_lyrics(title: str, artist: str) -> Optional[str]:
    """
    Load cached .lrc content if file exists and has content.
    Checks both cleaned and raw slugs for maximum hit rate.
    """
    clean_t = clean_track_title(title)
    clean_a = clean_artist_name(artist)

    candidates = [
        get_cache_path(clean_t, clean_a),
    ]
    if (clean_t, clean_a) != (title, artist):
        candidates.append(get_cache_path(title, artist))

    for path in candidates:
        if path.is_file():
            try:
                content = path.read_text(encoding="utf-8").strip()
                if content:
                    return content
            except OSError:
                pass
    return None


def save_cached_lyrics(title: str, artist: str, lrc_text: str) -> Optional[Path]:
    """
    Save raw LRC text to local cache in ~/.cache/quickshell/lyrics/.
    Saves under both cleaned and raw artist/title slugs if different.
    """
    if not lrc_text or not lrc_text.strip():
        return None

    clean_t = clean_track_title(title)
    clean_a = clean_artist_name(artist)
    content = lrc_text.strip() + "\n"

    target_path = get_cache_path(clean_t, clean_a)
    try:
        target_path.write_text(content, encoding="utf-8")
        if (clean_t, clean_a) != (title, artist):
            alt_path = get_cache_path(title, artist)
            if alt_path != target_path:
                alt_path.write_text(content, encoding="utf-8")
        return target_path
    except OSError as e:
        logger.warning(f"Failed to cache lyrics to {target_path}: {e}")
        return None


# ============================================================================
# Title and Artist Cleaning
# ============================================================================


def clean_artist_name(artist: str) -> str:
    """
    Clean artist string by extracting primary artist if comma or slash separated,
    or removing 'feat.' clauses.
    """
    if not artist:
        return ""
    parts = re.split(
        r"[,/;&]|\s+(?:feat\.?|ft\.?|featuring|with)\s+",
        artist,
        flags=re.IGNORECASE,
    )
    cleaned = parts[0].strip()
    return cleaned


def clean_track_title(title: str) -> str:
    """
    Clean Spotify track titles by removing parenthetical/bracket additions:
    (feat. ...), [Remastered 2011], (Live), - Single Version, - Bonus Track, - Shree Ram Dhun, etc.
    """
    if not title:
        return ""
    cleaned = title.strip()

    # 1. Remove bracketed / parenthetical additions containing version/credit keywords
    bracket_pattern = re.compile(
        r"\s*[\(\[][^\)\]]*(?:"
        r"feat\.?|ft\.?|featuring|remaster(?:ed)?|live|version|bonus|edit|deluxe|"
        r"explicit|mono|stereo|soundtrack|recorded|anniversary|mix|original|"
        r"with\s+|audio|video|prod\.?|shree\s+ram\s+dhun"
        r")[^\)\]]*[\)\]]",
        re.IGNORECASE,
    )
    cleaned = bracket_pattern.sub("", cleaned)

    # 2. Remove any trailing brackets with years/metadata like [2011 Remaster] or [Live]
    cleaned = re.sub(r"\s*\[[^\]]+\]\s*$", "", cleaned)

    # 3. Remove trailing dash additions: - Single Version, - Bonus Track, - Remastered 2011, etc.
    dash_pattern = re.compile(
        r"\s*[-–—]\s*(?:"
        r"feat\.?|ft\.?|featuring|remaster(?:ed)?(?:\s+\d{4})?|\d{4}\s+remaster(?:ed)?|"
        r"live.*|single\s+version|bonus\s+track|radio\s+edit|original\s+mix|mono|stereo|"
        r"deluxe.*|version.*|edit.*|acoustic.*|instrumental.*|anniversary.*|"
        r"from\s+.*|shree\s+ram\s+dhun|ram\s+dhun"
        r").*$",
        re.IGNORECASE,
    )
    cleaned = dash_pattern.sub("", cleaned)

    # 4. Remove standalone or trailing 'Shree Ram Dhun' or 'Ram Dhun' (with or without dash)
    cleaned = re.sub(r"(?i)\s*[-–—]?\s*(?:shree\s+ram\s+dhun|ram\s+dhun)\b.*", "", cleaned)

    # 5. Remove unparenthesized trailing 'feat. ...'
    cleaned = re.sub(r"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+.*$", "", cleaned)

    # 6. Normalize whitespace
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned


# ============================================================================
# LRC Parsing
# ============================================================================


def parse_lrc(lrc_text: str) -> List[Dict[str, Any]]:
    """
    Parse standard .lrc timestamp format [mm:ss.xx] or [mm:ss.xxx] or multiple timestamps per line.
    Ignores metadata headers like [ti:...], [ar:...], [al:...], [by:...].
    Returns a sorted list of dicts: [{"time": float_seconds, "text": "cleaned text"}, ...].
    Filters out blank/whitespace-only lines.
    """
    if not lrc_text or not isinstance(lrc_text, str):
        return []

    # Matches [mm:ss.xx] or [mm:ss.xxx] or [mm:ss:xx]
    timestamp_regex = re.compile(r"\[(\d+):(\d+(?:[.:]\d+)?)\]")
    meta_regex = re.compile(r"\[[a-zA-Z]+:[^\]]*\]")

    parsed: List[Dict[str, Any]] = []

    for raw_line in lrc_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        matches = list(timestamp_regex.finditer(line))
        if not matches:
            continue

        # Strip timestamps and any stray metadata tags
        text = timestamp_regex.sub("", line)
        text = meta_regex.sub("", text).strip()

        # Filter out blank or whitespace-only lines
        if not text:
            continue

        for match in matches:
            mins_str, secs_str = match.groups()
            mins = int(mins_str)
            if ":" in secs_str:
                s, frac = secs_str.split(":", 1)
                secs = float(f"{s}.{frac}")
            else:
                secs = float(secs_str)
            total_time = round(mins * 60.0 + secs, 3)
            parsed.append({"time": total_time, "text": text})

    parsed.sort(key=lambda item: item["time"])
    return parsed


# ============================================================================
# LRCLIB API Fetching
# ============================================================================


def _score_candidate(
    candidate: Dict[str, Any],
    target_title: str,
    target_artist: str,
    target_duration: Optional[float] = None,
) -> float:
    """
    Score a search candidate to choose the best matching result.
    Higher score indicates better match.
    """
    score = 0.0
    cand_title = (candidate.get("trackName") or "").strip().lower()
    cand_artist = (candidate.get("artistName") or "").strip().lower()
    t_title = target_title.strip().lower()
    t_artist = target_artist.strip().lower()

    # Title match scoring
    if cand_title == t_title:
        score += 50.0
    elif t_title in cand_title or cand_title in t_title:
        score += 30.0

    # Artist match scoring
    if cand_artist == t_artist:
        score += 40.0
    elif t_artist in cand_artist or cand_artist in t_artist:
        score += 25.0

    # Duration comparison if provided
    if target_duration is not None and target_duration > 0:
        cand_dur = candidate.get("duration")
        if cand_dur is not None:
            try:
                diff = abs(float(cand_dur) - float(target_duration))
                if diff <= 2.0:
                    score += 30.0
                elif diff <= 5.0:
                    score += 20.0
                elif diff <= 15.0:
                    score += 10.0
                else:
                    score -= min(25.0, diff)
            except (ValueError, TypeError):
                pass

    return score


def fetch_lyrics_lrclib(
    title: str,
    artist: str,
    album: Optional[str] = None,
    duration: Optional[float] = None,
    use_cache: bool = True,
) -> Optional[str]:
    """
    Fetch lyrics from LRCLIB with local caching.

    1. Checks local cache (~/.cache/quickshell/lyrics/).
    2. Tries exact match: https://lrclib.net/api/get.
    3. If 404 or no synced lyrics, tries search: https://lrclib.net/api/search.
    4. Selects best match with syncedLyrics.
    5. Saves to cache and returns raw LRC text (or None if not found).
    """
    if not title or not artist:
        return None

    # Step 1: Check cache
    if use_cache:
        cached = load_cached_lyrics(title, artist)
        if cached:
            return cached

    headers = {"User-Agent": USER_AGENT}

    # Step 2: Exact match attempt
    params: Dict[str, str] = {
        "track_name": title.strip(),
        "artist_name": artist.strip(),
    }
    if album and album.strip():
        params["album_name"] = album.strip()
    if duration is not None and duration > 0:
        params["duration"] = str(round(duration))

    get_url = f"https://lrclib.net/api/get?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(get_url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            synced = data.get("syncedLyrics")
            if synced and synced.strip():
                if use_cache:
                    save_cached_lyrics(title, artist, synced)
                return synced
    except urllib.error.HTTPError as e:
        if e.code != 404:
            logger.debug(f"LRCLIB exact get error: {e}")
    except Exception as e:
        logger.debug(f"LRCLIB exact get exception: {e}")

    # Step 3: Search fallback with cleaned title and artist
    clean_t = clean_track_title(title)
    clean_a = clean_artist_name(artist)
    search_query = f"{clean_t} {clean_a}".strip()

    search_params = {"q": search_query}
    search_url = f"https://lrclib.net/api/search?{urllib.parse.urlencode(search_params)}"
    req = urllib.request.Request(search_url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            candidates = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        logger.warning(f"LRCLIB search error: {e}")
        return None

    if not isinstance(candidates, list) or not candidates:
        return None

    # Filter to candidates with non-empty syncedLyrics
    synced_candidates = [
        cand
        for cand in candidates
        if isinstance(cand, dict)
        and cand.get("syncedLyrics")
        and cand.get("syncedLyrics").strip()
    ]

    if not synced_candidates:
        return None

    # Pick the best candidate based on score
    best_candidate = max(
        synced_candidates,
        key=lambda cand: _score_candidate(cand, clean_t, clean_a, duration),
    )

    lyrics = best_candidate.get("syncedLyrics")
    if lyrics and lyrics.strip():
        if use_cache:
            save_cached_lyrics(title, artist, lyrics)
        return lyrics

    return None


# ============================================================================
# CLI Interface
# ============================================================================


def main() -> None:
    parser = argparse.ArgumentParser(
        description="LRCLIB lyrics provider and LRC parser module for Quickshell."
    )
    parser.add_argument("title", help="Track title (e.g. 'Hey Ram Hey Ram Shree Ram Dhun')")
    parser.add_argument("artist", help="Artist name (e.g. 'Jagjit Singh')")
    parser.add_argument(
        "album", nargs="?", default=None, help="Album name (optional)"
    )
    parser.add_argument(
        "duration",
        nargs="?",
        type=float,
        default=None,
        help="Duration in seconds (optional)",
    )
    parser.add_argument(
        "--no-cache", action="store_true", help="Bypass local cache"
    )
    parser.add_argument(
        "--json", action="store_true", help="Output parsed lyrics as JSON"
    )
    parser.add_argument(
        "--raw", action="store_true", help="Print raw LRC text"
    )

    args = parser.parse_args()

    clean_t = clean_track_title(args.title)
    clean_a = clean_artist_name(args.artist)

    if not args.json and not args.raw:
        print(f"Title:          {args.title}")
        print(f"Artist:         {args.artist}")
        print(f"Cleaned Title:  {clean_t}")
        print(f"Cleaned Artist: {clean_a}")
        if args.album:
            print(f"Album:          {args.album}")
        if args.duration:
            print(f"Duration:       {args.duration}s")
        print("-" * 50)

    lrc_text = fetch_lyrics_lrclib(
        title=args.title,
        artist=args.artist,
        album=args.album,
        duration=args.duration,
        use_cache=not args.no_cache,
    )

    if not lrc_text:
        if args.json:
            print(json.dumps({"error": "No lyrics found", "lyrics": []}))
        else:
            print("Error: No lyrics found.")
        sys.exit(1)

    if args.raw:
        print(lrc_text)
        sys.exit(0)

    parsed = parse_lrc(lrc_text)

    if args.json:
        output = {
            "title": args.title,
            "artist": args.artist,
            "clean_title": clean_t,
            "clean_artist": clean_a,
            "line_count": len(parsed),
            "lines": parsed,
        }
        print(json.dumps(output, indent=2, ensure_ascii=False))
        sys.exit(0)

    cache_file = get_cache_path(clean_t, clean_a)
    print(f"Lyrics successfully fetched ({len(parsed)} synced lines).")
    print(f"Cache file: {cache_file}")
    print("\nPreview (first 10 lines):")
    for item in parsed[:10]:
        mins = int(item["time"] // 60)
        secs = item["time"] % 60
        print(f"[{mins:02d}:{secs:05.2f}] {item['text']}")
    if len(parsed) > 10:
        print(f"... ({len(parsed) - 10} more lines)")

    sys.exit(0)


if __name__ == "__main__":
    main()
