#!/usr/bin/env python3
"""
Spotify Official Color-Lyrics Provider for Quickshell.

Fetches synchronized lyrics directly from Spotify's internal color-lyrics API
(spclient.wg.spotify.com) using an authenticated sp_dc cookie.

Exported Functions:
    - get_spotify_cookie() -> Optional[str]
    - get_access_token(sp_dc_cookie: Optional[str] = None) -> Optional[str]
    - fetch_lyrics_spotify(track_id: str, sp_dc_cookie: Optional[str] = None) -> Optional[List[Dict[str, Any]]]
"""

import gzip
import json
import os
import re
import sys
import time
from typing import Any, Dict, List, Optional
import urllib.error
import urllib.request

# Default headers
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

# In-memory token cache
_TOKEN_CACHE: Dict[str, Any] = {
    "cookie": None,
    "token": None,
    "expires_at": 0.0,  # Unix timestamp in seconds
}


def _clean_cookie(raw_cookie: Optional[str]) -> Optional[str]:
    """Sanitize and extract the pure sp_dc cookie value."""
    if not raw_cookie:
        return None
    val = raw_cookie.strip().strip("\"'")
    if val.startswith("sp_dc="):
        val = val[len("sp_dc=") :].strip().strip("\"'")
    return val if val else None


def _clean_track_id(raw_id: str) -> str:
    """
    Extract Spotify track ID from plain ID, URI, or URL.
    Examples:
        - 4cOdK2wGLETKBW3PvgPWqT
        - spotify:track:4cOdK2wGLETKBW3PvgPWqT
        - /com/spotify/track/4cOdK2wGLETKBW3PvgPWqT
        - https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=xyz
    """
    if not raw_id:
        return ""
    track = raw_id.strip()
    if "/track/" in track:
        track = track.split("/track/")[1]
    elif "spotify:track:" in track:
        track = track.split("spotify:track:")[1]
    # Strip any URL parameters or path tails
    track = track.split("?")[0].split("/")[0].strip()
    return track


def get_spotify_cookie() -> Optional[str]:
    """
    Locates and returns the Spotify `sp_dc` cookie string.

    Lookup hierarchy:
    1. ~/.config/quickshell/spotify_cookie.txt
    2. ~/.config/sptlrx/config.yaml (cookie or sp_dc field)
    3. SPOTIFY_SP_DC or SP_DC environment variables
    """
    # 1. Check ~/.config/quickshell/spotify_cookie.txt
    cookie_file = os.path.expanduser("~/.config/quickshell/spotify_cookie.txt")
    if os.path.isfile(cookie_file):
        try:
            with open(cookie_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        cleaned = _clean_cookie(line)
                        if cleaned:
                            return cleaned
        except Exception:
            pass

    # 2. Check ~/.config/sptlrx/config.yaml
    sptlrx_file = os.path.expanduser("~/.config/sptlrx/config.yaml")
    if os.path.isfile(sptlrx_file):
        try:
            with open(sptlrx_file, "r", encoding="utf-8") as f:
                content = f.read()

            cookie_val = None
            try:
                import yaml

                parsed = yaml.safe_load(content)
                if isinstance(parsed, dict):
                    cookie_val = parsed.get("cookie") or parsed.get("sp_dc")
            except Exception:
                pass

            if not cookie_val:
                # Fallback regex search for `cookie: "..."` or `sp_dc: "..."`
                m = re.search(
                    r"^\s*(?:cookie|sp_dc)\s*:\s*[\"']?([^\"'\r\n]+)[\"']?",
                    content,
                    re.MULTILINE,
                )
                if m:
                    cookie_val = m.group(1)

            cleaned = _clean_cookie(cookie_val)
            if cleaned:
                return cleaned
        except Exception:
            pass

    # 3. Check environment variables
    for env_var in ("SPOTIFY_SP_DC", "SP_DC"):
        env_val = os.environ.get(env_var)
        if env_val:
            cleaned = _clean_cookie(env_val)
            if cleaned:
                return cleaned

    return None


def get_access_token(sp_dc_cookie: Optional[str] = None) -> Optional[str]:
    """
    Exchanges an sp_dc cookie for a Web Player Bearer access token.
    Caches the token in memory and automatically refreshes it before expiration.

    Uses urllib.request (no external requests library).
    """
    cookie = _clean_cookie(sp_dc_cookie) if sp_dc_cookie else get_spotify_cookie()
    if not cookie:
        return None

    # Check cache (refresh 60 seconds before expiration)
    now = time.time()
    if (
        _TOKEN_CACHE["token"]
        and _TOKEN_CACHE["cookie"] == cookie
        and now < _TOKEN_CACHE["expires_at"] - 60.0
    ):
        return _TOKEN_CACHE["token"]

    url = "https://open.spotify.com/get_access_token?reason=transport&productType=web_player"
    headers = {
        "User-Agent": USER_AGENT,
        "Cookie": f"sp_dc={cookie}",
        "Accept": "application/json",
    }

    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw_body = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw_body = gzip.decompress(raw_body)
            data = json.loads(raw_body.decode("utf-8"))

        # If anonymous, Spotify rejected the cookie
        if data.get("isAnonymous", False):
            return None

        access_token = data.get("accessToken")
        if not access_token:
            return None

        # Expiry tracking: Spotify returns accessTokenExpirationTimestampMs
        expiry_ms = data.get("accessTokenExpirationTimestampMs")
        if expiry_ms:
            expires_at = float(expiry_ms) / 1000.0
        else:
            expires_at = now + 3600.0  # Fallback to 1 hour

        # Update cache
        _TOKEN_CACHE["cookie"] = cookie
        _TOKEN_CACHE["token"] = access_token
        _TOKEN_CACHE["expires_at"] = expires_at

        return access_token

    except Exception:
        return None


def fetch_lyrics_spotify(
    track_id: str, sp_dc_cookie: Optional[str] = None
) -> Optional[List[Dict[str, Any]]]:
    """
    Fetches official synced lyrics for a track ID from Spotify color-lyrics API.

    Returns:
        List of dicts in standard format: [{"time": float_seconds, "text": words}, ...]
        or None if no cookie, retrieval failed, or lyrics not available.
    """
    clean_id = _clean_track_id(track_id)
    if not clean_id:
        return None

    cookie = _clean_cookie(sp_dc_cookie) if sp_dc_cookie else get_spotify_cookie()
    if not cookie:
        return None

    token = get_access_token(cookie)
    if not token:
        return None

    url = f"https://spclient.wg.spotify.com/color-lyrics/v2/track/{clean_id}?format=json&vocalRemoval=false"
    headers = {
        "User-Agent": USER_AGENT,
        "Authorization": f"Bearer {token}",
        "App-Platform": "WebPlayer",
        "Accept": "application/json",
    }

    def _do_request(auth_token: str) -> Optional[bytes]:
        req_headers = dict(headers)
        req_headers["Authorization"] = f"Bearer {auth_token}"
        req = urllib.request.Request(url, headers=req_headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw_data = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw_data = gzip.decompress(raw_data)
            return raw_data

    raw_response = None
    try:
        raw_response = _do_request(token)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            # Token might be invalidated, force refresh once
            _TOKEN_CACHE["token"] = None
            _TOKEN_CACHE["expires_at"] = 0.0
            new_token = get_access_token(cookie)
            if new_token:
                try:
                    raw_response = _do_request(new_token)
                except Exception:
                    return None
            else:
                return None
        elif e.code == 404:
            # Track has no lyrics
            return None
        else:
            return None
    except Exception:
        return None

    if not raw_response:
        return None

    try:
        payload = json.loads(raw_response.decode("utf-8"))
        lyrics_obj = payload.get("lyrics")
        if not isinstance(lyrics_obj, dict):
            return None

        lines = lyrics_obj.get("lines")
        if not isinstance(lines, list) or len(lines) == 0:
            return None

        result: List[Dict[str, Any]] = []
        for line in lines:
            if not isinstance(line, dict):
                continue
            start_ms = line.get("startTimeMs", 0)
            try:
                seconds = float(start_ms) / 1000.0
            except (ValueError, TypeError):
                seconds = 0.0
            words = line.get("words", "")
            result.append({
                "time": round(seconds, 3),
                "text": str(words) if words is not None else "",
            })

        return result if result else None

    except Exception:
        return None


def main() -> None:
    """CLI testing interface."""
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <track_id> [--json]")
        print("Example: python3 lyrics_provider_spotify.py 4cOdK2wGLETKBW3PvgPWqT")
        sys.exit(1)

    track_arg = sys.argv[1]
    json_mode = "--json" in sys.argv

    cookie = get_spotify_cookie()
    if not cookie:
        print(
            "Note: No Spotify sp_dc cookie found in ~/.config/quickshell/spotify_cookie.txt, "
            "~/.config/sptlrx/config.yaml, or SPOTIFY_SP_DC env var.",
            file=sys.stderr,
        )

    lyrics = fetch_lyrics_spotify(track_arg, cookie)
    if lyrics is None:
        if json_mode:
            print("[]")
        else:
            print(f"No lyrics found for track: {track_arg}")
        sys.exit(1)

    if json_mode:
        print(json.dumps(lyrics, indent=2, ensure_ascii=False))
    else:
        print(f"Loaded {len(lyrics)} lyric lines for track {track_arg}:")
        for item in lyrics:
            t = item["time"]
            mins = int(t // 60)
            secs = t % 60
            print(f"[{mins:02d}:{secs:05.2f}] {item['text']}")


if __name__ == "__main__":
    main()
