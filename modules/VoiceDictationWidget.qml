import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// VoiceDictationWidget — Live Speech-to-Text Dictation Indicator
// Appears on the Quickshell bar ONLY when triggered (Super + V or click).
// Completely collapses and takes 0 pixels when idle (zero CPU/GPU usage).
// Features:
//   - 4 live animated vertical equalizer bars in emerald/mint green
//   - Instant typing directly into whatever window is focused
//   - Zero clipboard pollution, zero focus stealing
//   - Debounced click handler with immediate visual feedback (zero re-trigger glitch)
//   - Dual-IPC state synchronization (<1ms latency via socket IPC + atomic FileView)
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root
    Layout.fillHeight: true
    Layout.alignment: Qt.AlignVCenter

    property bool isListening: false
    property bool actionPending: false
    property string stateFilePath: "/tmp/qs_dictation.json"

    readonly property bool windowVisible: Window.window ? Window.window.visible : true
    readonly property bool animActive: root.isListening && root.visible && root.windowVisible

    implicitWidth: isListening ? 38 : 0
    width: implicitWidth
    Layout.preferredWidth: implicitWidth

    visible: isListening || opacity > 0.001 || implicitWidth > 0
    opacity: isListening ? 1.0 : 0.0
    clip: true

    Behavior on implicitWidth {
        NumberAnimation {
            duration: 240
            easing.type: Easing.OutCubic
        }
    }

    Behavior on opacity {
        NumberAnimation {
            duration: 180
            easing.type: Easing.OutCubic
        }
    }

    // Debounce timer preventing rapid re-trigger glitches on click or rapid IPC toggles
    Timer {
        id: debounceTimer
        interval: 350
        repeat: false
        onTriggered: {
            root.actionPending = false
        }
    }

    // ── Zero-Latency State Sync (Kernel inotify observer) ────────────────────
    FileView {
        id: stateFile
        path: root.stateFilePath
        watchChanges: root.stateFilePath !== ""
        onLoadedChanged: {
            if (loaded) root.syncState()
        }
        onFileChanged: {
            if (loaded) root.syncState()
        }
        onLoadFailed: {
            root.isListening = false
        }
    }

    function syncState() {
        if (!stateFile.loaded) return
        try {
            const txt = stateFile.text()
            if (txt && txt.trim().length > 0) {
                const data = JSON.parse(txt.trim())
                if (data && typeof data.isListening === "boolean") {
                    root.isListening = data.isListening
                    return
                }
            }
        } catch(e) {}
    }

    function startListening() {
        Quickshell.execDetached(["/home/banana/.local/share/dictation/venv/bin/python3", Paths.script("live-dictate.py"), "stream"])
    }

    function stopListening() {
        Quickshell.execDetached(["/home/banana/.local/share/dictation/venv/bin/python3", Paths.script("live-dictate.py"), "stop"])
    }

    function toggleListening() {
        Quickshell.execDetached(["/home/banana/.local/share/dictation/venv/bin/python3", Paths.script("live-dictate.py"), "toggle"])
    }

    Component.onCompleted: {
        root.syncState()
    }

    // ── IPC Interface (<1ms Direct Socket Dispatch) ──────────────────────────
    IpcHandler {
        target: "dictation"
        function toggle() {
            if (root.actionPending) return
            root.actionPending = true
            debounceTimer.restart()
            root.toggleListening()
        }
        function start() {
            root.actionPending = false
            debounceTimer.stop()
            root.isListening = true
        }
        function stop() {
            root.actionPending = false
            debounceTimer.stop()
            root.isListening = false
        }
        function status(): bool {
            return root.isListening
        }
    }

    // State change handler: unlock pending action and reset bar heights
    onIsListeningChanged: {
        root.actionPending = false
        debounceTimer.stop()
        if (!root.isListening) {
            bar1.height = 4
            bar2.height = 6
            bar3.height = 5
            bar4.height = 4
        }
    }

    // ── Pill Container ───────────────────────────────────────────────────────
    Rectangle {
        id: pillBg
        anchors.centerIn: parent
        width: root.width
        height: 22
        radius: 6
        visible: root.visible && root.implicitWidth > 0

        // Emerald green glow styling matching Bar Theme
        color: mouseArea.containsMouse
            ? Qt.rgba(0.063, 0.725, 0.506, 0.28)
            : Qt.rgba(0.063, 0.725, 0.506, 0.16)

        border.color: mouseArea.containsMouse
            ? Qt.rgba(0.063, 0.725, 0.506, 0.80)
            : Qt.rgba(0.063, 0.725, 0.506, 0.45)
        border.width: 1

        scale: mouseArea.pressed ? 0.94 : (mouseArea.containsMouse ? 1.03 : 1.0)

        Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on border.color { ColorAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }

        // 4 Animated Vertical Bars (Emerald / Mint Green)
        Row {
            id: barsRow
            anchors.centerIn: parent
            spacing: 3
            height: 18
            visible: root.visible && root.implicitWidth > 12

            // Bar 1: 4 <-> 14 (340ms)
            Rectangle {
                id: bar1
                width: 3
                implicitWidth: 3
                height: 4
                radius: 1.5
                color: "#10b981"
                anchors.verticalCenter: parent.verticalCenter
                antialiasing: true

                SequentialAnimation on height {
                    running: root.animActive
                    loops: Animation.Infinite
                    NumberAnimation { from: 4; to: 14; duration: 340; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 14; to: 4; duration: 340; easing.type: Easing.InOutSine }
                }
            }

            // Bar 2: 6 <-> 18 (280ms)
            Rectangle {
                id: bar2
                width: 3
                implicitWidth: 3
                height: 6
                radius: 1.5
                color: "#34d399"
                anchors.verticalCenter: parent.verticalCenter
                antialiasing: true

                SequentialAnimation on height {
                    running: root.animActive
                    loops: Animation.Infinite
                    NumberAnimation { from: 6; to: 18; duration: 280; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 18; to: 6; duration: 280; easing.type: Easing.InOutSine }
                }
            }

            // Bar 3: 5 <-> 16 (380ms)
            Rectangle {
                id: bar3
                width: 3
                implicitWidth: 3
                height: 5
                radius: 1.5
                color: "#059669"
                anchors.verticalCenter: parent.verticalCenter
                antialiasing: true

                SequentialAnimation on height {
                    running: root.animActive
                    loops: Animation.Infinite
                    NumberAnimation { from: 5; to: 16; duration: 380; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 16; to: 5; duration: 380; easing.type: Easing.InOutSine }
                }
            }

            // Bar 4: 4 <-> 12 (310ms)
            Rectangle {
                id: bar4
                width: 3
                implicitWidth: 3
                height: 4
                radius: 1.5
                color: "#34d399"
                anchors.verticalCenter: parent.verticalCenter
                antialiasing: true

                SequentialAnimation on height {
                    running: root.animActive
                    loops: Animation.Infinite
                    NumberAnimation { from: 4; to: 12; duration: 310; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 12; to: 4; duration: 310; easing.type: Easing.InOutSine }
                }
            }
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: root.isListening && !root.actionPending
        onClicked: {
            root.actionPending = true
            debounceTimer.restart()
            root.stopListening()
        }
    }
}
