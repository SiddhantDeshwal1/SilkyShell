#!/usr/bin/env python3
"""
test_media_island_lyrics.py — Comprehensive Unit & Integration tests for MediaIsland live lyrics integration.
"""

import unittest
import subprocess
import os
import sys

BASE_DIR = "/home/banana/.config/quickshell"
TEST_RUNNER_QML = os.path.join(BASE_DIR, "test_lyrics_runner.qml")

class TestMediaIslandLyrics(unittest.TestCase):

    def tearDown(self):
        if os.path.exists(TEST_RUNNER_QML):
            try:
                os.remove(TEST_RUNNER_QML)
            except OSError:
                pass

    def test_01_bar_and_media_island_compilation(self):
        """Verify Bar.qml and MediaIsland.qml compile and instantiate cleanly."""
        qml_src = """import QtQuick
import Quickshell
import "modules"

ShellRoot {
    Bar { id: barWindow; visible: false }

    Timer {
        interval: 150
        running: true
        repeat: false
        onTriggered: {
            console.log("BAR_QML_COMPILED_OK");
            Qt.quit();
        }
    }
}
"""
        with open(TEST_RUNNER_QML, "w") as f:
            f.write(qml_src)

        res = subprocess.run(
            ["quickshell", "-p", TEST_RUNNER_QML],
            capture_output=True,
            text=True,
            timeout=8
        )
        self.assertIn("BAR_QML_COMPILED_OK", res.stdout, f"Bar compilation failed:\n{res.stdout}\n{res.stderr}")
        self.assertEqual(res.returncode, 0)

    def test_02_lyrics_state_machine_and_json_parsing(self):
        """Verify state machine, transitions, and JSON handling in MediaIsland."""
        qml_src = """import QtQuick
import Quickshell
import "modules"

ShellRoot {
    id: testRoot

    MediaIsland {
        id: island
        width: 840
        height: 38
        visible: false
    }

    Timer {
        id: stepTimer
        interval: 50
        running: true
        repeat: false
        property int step: 0

        function assert(cond, msg) {
            if (!cond) {
                console.error("ASSERTION_FAILED: " + msg);
                Qt.quit();
                throw new Error(msg);
            }
        }

        onTriggered: {
            step++
            if (step === 1) {
                // 1. Initial State
                assert(island.lyricsModeEnabled === true, "lyricsModeEnabled should default to true");
                assert(island.hasLyrics === false, "hasLyrics should default to false");
                assert(island.isInstrumental === false, "isInstrumental should default to false");
                assert(island.currentLyricLine === "", "currentLyricLine should default to empty string");

                // 2. JSON Parsing: Standard currentLine & nextLine
                island.parseLyricsJson(JSON.stringify({
                    status: "playing",
                    track: "Test Song",
                    artist: "Test Artist",
                    hasLyrics: true,
                    currentLine: "First Lyric Line",
                    nextLine: "Second Lyric Line",
                    isInstrumental: false
                }));
                assert(island.hasLyrics === true, "hasLyrics should be true after parsing");
                assert(island.currentLyricLine === "First Lyric Line", "currentLyricLine mismatch");
                assert(island.nextLyricLine === "Second Lyric Line", "nextLyricLine mismatch");
                assert(island.isInstrumental === false, "isInstrumental should be false");

                // 3. JSON Parsing: Alternative field names (currentLyricLine / nextLyricLine)
                island.parseLyricsJson(JSON.stringify({
                    hasLyrics: true,
                    currentLyricLine: "Alt Lyric Line",
                    nextLyricLine: "Alt Next Line",
                    isInstrumental: false
                }));
                assert(island.currentLyricLine === "Alt Lyric Line", "alt currentLyricLine mismatch");
                assert(island.nextLyricLine === "Alt Next Line", "alt nextLyricLine mismatch");

                // 4. Instrumental detection
                island.parseLyricsJson(JSON.stringify({
                    hasLyrics: true,
                    currentLine: "",
                    nextLine: "Resume vocal line",
                    isInstrumental: true
                }));
                assert(island.isInstrumental === true, "isInstrumental should be true");

                // 5. Corrupted / non-JSON handling
                island.parseLyricsJson("NOT_A_JSON_STRING");
                assert(island.hasLyrics === true, "Corrupted string should not crash or corrupt previous state");

                // 6. Test state machine playing progression: announce -> title -> lyrics
                island.playerState = "playing";
                island.startLoop("NEW");
                assert(island.currentPhase === "announce", "startLoop should set phase to announce");

                // Advance past announce -> title
                island.advancePhase();
                assert(island.currentPhase === "title", "After announce, phase should advance to title");

                // Advance past title -> lyrics (since lyricsModeEnabled && hasLyrics && playing)
                island.advancePhase();
                assert(island.currentPhase === "lyrics", "After title, phase should advance to lyrics");

                // 7. Instrumental transition while in lyrics phase
                island.isInstrumental = true;
                island.parseLyricsJson(JSON.stringify({
                    hasLyrics: true,
                    currentLine: "",
                    nextLine: "Incoming vocals",
                    isInstrumental: true
                }));
                assert(island.currentPhase === "lyrics", "Phase remains lyrics with instrumental substate");

                // Vocals resume
                island.parseLyricsJson(JSON.stringify({
                    hasLyrics: true,
                    currentLine: "Vocals Resumed Here!",
                    nextLine: "Following line",
                    isInstrumental: false
                }));
                assert(island.isInstrumental === false, "isInstrumental should be false after vocals resume");
                assert(island.currentLyricLine === "Vocals Resumed Here!", "currentLyricLine updated");

                // 8. Disabling lyrics mode switches to visualizer
                island.lyricsModeEnabled = false;
                assert(island.currentPhase === "visualizer", "Disabling lyrics mode should switch phase to visualizer");

                // Re-enabling lyrics mode switches back to lyrics
                island.lyricsModeEnabled = true;
                assert(island.currentPhase === "lyrics", "Re-enabling lyrics mode should switch phase back to lyrics");

                // 9. When track has NO lyrics, falls back to visualizer & title cycle
                island.hasLyrics = false;
                assert(island.currentPhase === "visualizer", "hasLyrics=false should switch phase to visualizer");

                // Cycle visualizer -> title
                island.vizCycleCount = 3;
                island.advancePhase();
                assert(island.currentPhase === "title", "After visualizer with no lyrics, should advance to title");

                island.advancePhase();
                assert(island.currentPhase === "visualizer", "After title with no lyrics, should advance to visualizer");

                console.log("ALL_STATE_MACHINE_TESTS_PASSED");
                Qt.quit();
            }
        }
    }
}
"""
        with open(TEST_RUNNER_QML, "w") as f:
            f.write(qml_src)

        res = subprocess.run(
            ["quickshell", "-p", TEST_RUNNER_QML],
            capture_output=True,
            text=True,
            timeout=8
        )
        self.assertIn("ALL_STATE_MACHINE_TESTS_PASSED", res.stdout, f"State machine test failed:\n{res.stdout}\n{res.stderr}")
        self.assertEqual(res.returncode, 0)

if __name__ == "__main__":
    unittest.main()
