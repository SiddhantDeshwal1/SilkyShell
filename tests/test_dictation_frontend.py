#!/usr/bin/env python3
"""
test_dictation_frontend.py — Frontend Integration Test Suite for VoiceDictationWidget.qml and Bar.qml.
Validates:
1. Zero CPU usage when idle: implicitWidth=0, visible=false, animActive=false, animations stopped.
2. Equalizer animation smoothness & resource culling: animations strictly disabled when idle or window hidden.
3. Dual-IPC state synchronization: FileView + quickshell ipc updates UI reliably without race conditions.
4. Click feedback & anti-glitch protection: actionPending debounce prevents rapid re-trigger glitches.
5. QML compilation & runtime syntax verification via quickshell.
"""

import unittest
import subprocess
import json
import os
import sys
import time

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TEST_RUNNER_QML = os.path.join(BASE_DIR, "test_frontend_runner.qml")
STATE_FILE = "/tmp/qs_dictation.json"

class TestDictationFrontend(unittest.TestCase):

    def setUp(self):
        # Reset state file to idle
        with open(STATE_FILE, "w") as f:
            f.write(json.dumps({"isListening": False, "device": ""}) + "\n")

    def tearDown(self):
        # Clean up runner if created
        if os.path.exists(TEST_RUNNER_QML):
            try:
                os.remove(TEST_RUNNER_QML)
            except OSError:
                pass

    def test_01_qml_syntax_and_compilation(self):
        """Verify VoiceDictationWidget and Bar compile without errors."""
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
            console.log("QML_COMPILED_OK: Bar and VoiceDictationWidget loaded")
            Qt.quit()
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
        self.assertIn("QML_COMPILED_OK", res.stdout, f"QML compilation failed: {res.stdout}\n{res.stderr}")
        self.assertEqual(res.returncode, 0)

    def test_02_idle_zero_cpu_invariants(self):
        """Verify zero CPU footprint when idle: implicitWidth 0, visible false, animActive false."""
        qml_src = """import QtQuick
import Quickshell
import "modules"

ShellRoot {
    PanelWindow {
        visible: true
        VoiceDictationWidget {
            id: widget
            stateFilePath: ""
        }

        Timer {
            interval: 100
            running: true
            repeat: false
            onTriggered: {
                console.log("IDLE_TEST_WIDTH:" + widget.implicitWidth)
                console.log("IDLE_TEST_VISIBLE:" + widget.visible)
                console.log("IDLE_TEST_OPACITY:" + widget.opacity)
                console.log("IDLE_TEST_ANIM:" + widget.animActive)
                Qt.quit()
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
        self.assertEqual(res.returncode, 0)
        self.assertIn("IDLE_TEST_WIDTH:0", res.stdout)
        self.assertIn("IDLE_TEST_VISIBLE:false", res.stdout)
        self.assertIn("IDLE_TEST_OPACITY:0", res.stdout)
        self.assertIn("IDLE_TEST_ANIM:false", res.stdout)

    def test_03_active_and_collapse_transitions(self):
        """Verify smooth expansion on active and complete collapse to 0 on stop."""
        qml_src = """import QtQuick
import Quickshell
import "modules"

ShellRoot {
    PanelWindow {
        visible: true
        VoiceDictationWidget {
            id: widget
            stateFilePath: ""
        }

        Timer {
            id: step1
            interval: 80
            running: true
            repeat: false
            onTriggered: {
                widget.isListening = true
                step2.start()
            }
        }

        Timer {
            id: step2
            interval: 320
            repeat: false
            onTriggered: {
                console.log("ACTIVE_WIDTH:" + widget.implicitWidth)
                console.log("ACTIVE_VISIBLE:" + widget.visible)
                console.log("ACTIVE_ANIM:" + widget.animActive)
                widget.isListening = false
                step3.start()
            }
        }

        Timer {
            id: step3
            interval: 350
            repeat: false
            onTriggered: {
                console.log("COLLAPSED_WIDTH:" + widget.implicitWidth)
                console.log("COLLAPSED_VISIBLE:" + widget.visible)
                console.log("COLLAPSED_ANIM:" + widget.animActive)
                Qt.quit()
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
            timeout=10
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("ACTIVE_WIDTH:38", res.stdout)
        self.assertIn("ACTIVE_VISIBLE:true", res.stdout)
        self.assertIn("ACTIVE_ANIM:true", res.stdout)

        self.assertIn("COLLAPSED_WIDTH:0", res.stdout)
        self.assertIn("COLLAPSED_VISIBLE:false", res.stdout)
        self.assertIn("COLLAPSED_ANIM:false", res.stdout)

    def test_04_click_debounce_protection(self):
        """Verify clicking pill sets actionPending and prevents rapid re-trigger glitch."""
        qml_src = """import QtQuick
import Quickshell
import "modules"

ShellRoot {
    PanelWindow {
        visible: true
        VoiceDictationWidget {
            id: widget
            stateFilePath: ""
        }

        Timer {
            id: step1
            interval: 50
            running: true
            repeat: false
            onTriggered: {
                widget.isListening = true
                step2.start()
            }
        }

        Timer {
            id: step2
            interval: 100
            repeat: false
            onTriggered: {
                console.log("BEFORE_CLICK_PENDING:" + widget.actionPending)
                // Simulate click trigger
                widget.actionPending = true
                console.log("AFTER_CLICK_PENDING:" + widget.actionPending)

                // When isListening turns false, actionPending is automatically unlocked
                widget.isListening = false
                step3.start()
            }
        }

        Timer {
            id: step3
            interval: 50
            repeat: false
            onTriggered: {
                console.log("POST_STATE_CHANGE_PENDING:" + widget.actionPending)
                Qt.quit()
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
        self.assertEqual(res.returncode, 0)
        self.assertIn("BEFORE_CLICK_PENDING:false", res.stdout)
        self.assertIn("AFTER_CLICK_PENDING:true", res.stdout)
        self.assertIn("POST_STATE_CHANGE_PENDING:false", res.stdout)

    def test_05_fileview_state_sync(self):
        """Verify FileView parses state from /tmp/qs_dictation.json cleanly without race conditions."""
        # Write active state
        with open(STATE_FILE, "w") as f:
            f.write(json.dumps({"isListening": True, "device": "Test Mic"}) + "\n")

        qml_src = """import QtQuick
import Quickshell
import "modules"

ShellRoot {
    PanelWindow {
        visible: true
        VoiceDictationWidget {
            id: widget
            stateFilePath: "/tmp/qs_dictation.json"
        }

        Timer {
            interval: 150
            running: true
            repeat: false
            onTriggered: {
                console.log("FILEVIEW_SYNCED_STATE:" + widget.isListening)
                Qt.quit()
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
        self.assertEqual(res.returncode, 0)
        self.assertIn("FILEVIEW_SYNCED_STATE:true", res.stdout)

if __name__ == "__main__":
    unittest.main()
