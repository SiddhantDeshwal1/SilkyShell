#!/usr/bin/env python3
"""
Unit tests for Spotify Color-Lyrics Provider (lyrics_provider_spotify.py)
"""

import io
import json
import os
import sys
import tempfile
import time
import unittest
from unittest.mock import MagicMock, patch
import urllib.error

# Ensure scripts directory is on sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../scripts")))

import lyrics_provider_spotify as spotify_provider


class TestSpotifyLyricsProvider(unittest.TestCase):
    def setUp(self):
        # Reset the token cache before each test
        spotify_provider._TOKEN_CACHE["cookie"] = None
        spotify_provider._TOKEN_CACHE["token"] = None
        spotify_provider._TOKEN_CACHE["expires_at"] = 0.0

    def test_clean_track_id(self):
        cases = [
            ("4cOdK2wGLETKBW3PvgPWqT", "4cOdK2wGLETKBW3PvgPWqT"),
            ("spotify:track:4cOdK2wGLETKBW3PvgPWqT", "4cOdK2wGLETKBW3PvgPWqT"),
            ("/com/spotify/track/4cOdK2wGLETKBW3PvgPWqT", "4cOdK2wGLETKBW3PvgPWqT"),
            ("https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT", "4cOdK2wGLETKBW3PvgPWqT"),
            (
                "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=12345678",
                "4cOdK2wGLETKBW3PvgPWqT",
            ),
            ("  4cOdK2wGLETKBW3PvgPWqT  \n", "4cOdK2wGLETKBW3PvgPWqT"),
            ("", ""),
        ]
        for input_val, expected in cases:
            self.assertEqual(spotify_provider._clean_track_id(input_val), expected)

    def test_clean_cookie(self):
        self.assertEqual(
            spotify_provider._clean_cookie("AQB123456789"),
            "AQB123456789",
        )
        self.assertEqual(
            spotify_provider._clean_cookie("sp_dc=AQB123456789"),
            "AQB123456789",
        )
        self.assertEqual(
            spotify_provider._clean_cookie(' "sp_dc=AQB123456789" \n'),
            "AQB123456789",
        )
        self.assertIsNone(spotify_provider._clean_cookie(""))
        self.assertIsNone(spotify_provider._clean_cookie(None))

    def test_get_spotify_cookie_hierarchy(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cookie_txt = os.path.join(tmpdir, "spotify_cookie.txt")
            sptlrx_yaml = os.path.join(tmpdir, "sptlrx.yaml")

            # Patch os.path.expanduser and os.environ
            def fake_expanduser(path):
                if path == "~/.config/quickshell/spotify_cookie.txt":
                    return cookie_txt
                if path == "~/.config/sptlrx/config.yaml":
                    return sptlrx_yaml
                return path

            with patch("os.path.expanduser", side_effect=fake_expanduser), patch.dict(
                os.environ, {}, clear=True
            ):
                # Case 1: Nothing exists
                self.assertIsNone(spotify_provider.get_spotify_cookie())

                # Case 2: Only env exists
                os.environ["SPOTIFY_SP_DC"] = "cookie_from_env"
                self.assertEqual(spotify_provider.get_spotify_cookie(), "cookie_from_env")

                # Case 3: sptlrx config exists (takes priority over env)
                with open(sptlrx_yaml, "w") as f:
                    f.write("cookie: 'cookie_from_sptlrx'\n")
                self.assertEqual(spotify_provider.get_spotify_cookie(), "cookie_from_sptlrx")

                # Case 4: spotify_cookie.txt exists (highest priority)
                with open(cookie_txt, "w") as f:
                    f.write("# Spotify Cookie File\nsp_dc=cookie_from_file\n")
                self.assertEqual(spotify_provider.get_spotify_cookie(), "cookie_from_file")

    def test_get_access_token_success_and_caching(self):
        mock_response_data = {
            "clientId": "test_client_id",
            "accessToken": "BQ_TEST_ACCESS_TOKEN",
            "accessTokenExpirationTimestampMs": int((time.time() + 3600) * 1000),
            "isAnonymous": False,
        }

        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps(mock_response_data).encode("utf-8")
        mock_resp.headers = {}
        mock_resp.__enter__.return_value = mock_resp

        with patch("urllib.request.urlopen", return_value=mock_resp) as mock_urlopen:
            # First fetch: should make request
            token1 = spotify_provider.get_access_token("test_cookie_value")
            self.assertEqual(token1, "BQ_TEST_ACCESS_TOKEN")
            self.assertEqual(mock_urlopen.call_count, 1)

            # Check that Cookie header was passed correctly
            req = mock_urlopen.call_args[0][0]
            self.assertEqual(req.headers.get("Cookie"), "sp_dc=test_cookie_value")

            # Second fetch: should hit cache
            token2 = spotify_provider.get_access_token("test_cookie_value")
            self.assertEqual(token2, "BQ_TEST_ACCESS_TOKEN")
            self.assertEqual(mock_urlopen.call_count, 1)

    def test_get_access_token_anonymous_rejected(self):
        mock_response_data = {
            "clientId": "test_client_id",
            "accessToken": "ANONYMOUS_TOKEN",
            "isAnonymous": True,
        }
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps(mock_response_data).encode("utf-8")
        mock_resp.headers = {}
        mock_resp.__enter__.return_value = mock_resp

        with patch("urllib.request.urlopen", return_value=mock_resp):
            token = spotify_provider.get_access_token("bad_cookie")
            self.assertIsNone(token)

    def test_fetch_lyrics_spotify_success(self):
        lyrics_payload = {
            "lyrics": {
                "syncType": "LINE_SYNCED",
                "lines": [
                    {"startTimeMs": "12500", "words": "Line one of lyrics", "syllables": []},
                    {"startTimeMs": 25000, "words": "Line two of lyrics", "syllables": []},
                    {"startTimeMs": "38450", "words": "Line three of lyrics", "syllables": []},
                ],
            }
        }

        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps(lyrics_payload).encode("utf-8")
        mock_resp.headers = {}
        mock_resp.__enter__.return_value = mock_resp

        with patch("lyrics_provider_spotify.get_access_token", return_value="VALID_TOKEN"), patch(
            "urllib.request.urlopen", return_value=mock_resp
        ) as mock_urlopen:
            lines = spotify_provider.fetch_lyrics_spotify(
                "4cOdK2wGLETKBW3PvgPWqT", sp_dc_cookie="dummy_cookie"
            )
            self.assertIsNotNone(lines)
            self.assertEqual(len(lines), 3)
            self.assertEqual(lines[0], {"time": 12.5, "text": "Line one of lyrics"})
            self.assertEqual(lines[1], {"time": 25.0, "text": "Line two of lyrics"})
            self.assertEqual(lines[2], {"time": 38.45, "text": "Line three of lyrics"})

            # Verify request headers
            req = mock_urlopen.call_args[0][0]
            self.assertEqual(req.headers.get("Authorization"), "Bearer VALID_TOKEN")
            self.assertEqual(req.headers.get("App-platform"), "WebPlayer")

    def test_fetch_lyrics_spotify_no_lyrics_404(self):
        fp = io.BytesIO(b"")
        err = urllib.error.HTTPError(
            url="http://spclient.wg.spotify.com",
            code=404,
            msg="Not Found",
            hdrs={},
            fp=fp,
        )
        try:
            with patch("lyrics_provider_spotify.get_access_token", return_value="VALID_TOKEN"), patch(
                "urllib.request.urlopen", side_effect=err
            ):
                lines = spotify_provider.fetch_lyrics_spotify(
                    "4cOdK2wGLETKBW3PvgPWqT", sp_dc_cookie="dummy_cookie"
                )
                self.assertIsNone(lines)
        finally:
            err.close()
            fp.close()

    def test_fetch_lyrics_spotify_no_cookie(self):
        with patch("lyrics_provider_spotify.get_spotify_cookie", return_value=None):
            lines = spotify_provider.fetch_lyrics_spotify("4cOdK2wGLETKBW3PvgPWqT")
            self.assertIsNone(lines)


if __name__ == "__main__":
    unittest.main()
