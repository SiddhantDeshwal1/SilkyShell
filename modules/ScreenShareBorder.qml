import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// ─────────────────────────────────────────────────────────────────────────────
// ScreenShareBorder — Universal Apple Red Border for Screen / Window Sharing
//
// Automatically frames whatever portion of the display is actively shared:
//   - Specific Window: Tracks window geometry and workspace changes dynamically.
//   - Custom Region: Frames cropped rectangle area.
//   - Full Screen / Monitor: Frames the entire shared monitor.
//
// Styling matches ScreenRecordingBar:
//   - Outer 1px subtle dark contrast stroke (#60000000)
//   - Main 3px vibrant Apple Red border (#ef4444)
//   - Inner 1px subtle dark contrast stroke (#40000000)
//   - Zero-overhead 100% mouse click-through mask
// ─────────────────────────────────────────────────────────────────────────────

Scope {
    id: root

    // ── Live Shared State ─────────────────────────────────────────────────────
    property bool isSharing: false
    property string shareType: "none" // "window" | "screen" | "region" | "none"
    property string targetMonitor: ""
    property bool isVisibleOnWorkspace: false
    property string appClass: ""
    property string appTitle: ""
    property real targetX: 0
    property real targetY: 0
    property real targetW: 0
    property real targetH: 0

    // ── Real-Time JSON Stream Parser ─────────────────────────────────────────
    function parseStateJson(txt) {
        if (!txt || txt.length === 0) return
        try {
            const data = JSON.parse(txt)
            root.isSharing = !!data.isSharing
            root.shareType = data.type || "none"
            root.targetMonitor = data.monitor || ""
            root.isVisibleOnWorkspace = (data.visible !== undefined) ? !!data.visible : true
            root.appClass = data.class || ""
            root.appTitle = data.title || ""

            if (data.geometry) {
                root.targetX = data.geometry.x || 0
                root.targetY = data.geometry.y || 0
                root.targetW = data.geometry.width || 0
                root.targetH = data.geometry.height || 0
            }
        } catch (e) {}
    }

    // ── Zero-Latency Daemon Stream Supervisor ─────────────────────────────────
    Process {
        id: shareDaemonProc
        command: ["python3", "-u", Paths.script("screenshare-service.py"), "daemon"]
        running: true
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                root.parseStateJson(line.trim())
            }
        }
        onExited: function() {
            daemonRestartTimer.restart()
        }
    }

    Timer {
        id: daemonRestartTimer
        interval: 1000
        repeat: false
        onTriggered: {
            if (!shareDaemonProc.running) shareDaemonProc.running = true
        }
    }

    Process { id: actionProc }

    // ── IPC Handler ───────────────────────────────────────────────────────────
    IpcHandler {
        target: "screenshare"
        function testWindow(target: string) {
            actionProc.command = ["python3", Paths.script("screenshare-service.py"), "test-window", target || ""]
            actionProc.running = false
            actionProc.running = true
        }
        function testRegion(geom: string) {
            actionProc.command = ["python3", Paths.script("screenshare-service.py"), "test-region", geom || "100,100 800x600"]
            actionProc.running = false
            actionProc.running = true
        }
        function testScreen(out: string) {
            actionProc.command = ["python3", Paths.script("screenshare-service.py"), "test-screen", out || ""]
            actionProc.running = false
            actionProc.running = true
        }
        function stop() {
            actionProc.command = ["python3", Paths.script("screenshare-service.py"), "stop"]
            actionProc.running = false
            actionProc.running = true
        }
    }

    // ── Multi-Monitor Overlay Windows ─────────────────────────────────────────
    Variants {
        id: screenVariants
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData

            readonly property string monName: modelData ? (modelData.name || "") : ""
            readonly property real screenWidth: modelData ? (modelData.width > 0 ? modelData.width : 1920) : 1920
            readonly property real screenHeight: modelData ? (modelData.height > 0 ? modelData.height : 1080) : 1080

            readonly property bool matchesMonitor: (root.targetMonitor === "" || root.targetMonitor === win.monName)
            readonly property bool isVisible: (root.shareType === "screen") || (root.shareType === "region") || root.isVisibleOnWorkspace
            readonly property bool hasValidDimensions: (root.shareType === "screen") || (root.targetW > 10 && root.targetH > 10)
            readonly property bool showBorder: root.isSharing && isVisible && matchesMonitor && hasValidDimensions

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            exclusiveZone: -1
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "screenshare-border"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            color: "transparent"
            visible: win.showBorder

            // ── 100% Mouse Passthrough (Never blocks clicks) ──────────────────
            mask: emptyRegion

            Region {
                id: emptyRegion
                x: 0
                y: 0
                width: 0
                height: 0
            }

            // ── Active Shared Red Border ─────────────────────────────────────
            Item {
                id: activeBorderItem
                visible: win.showBorder
                opacity: win.showBorder ? 1.0 : 0.0

                Behavior on opacity {
                    NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
                }

                x: root.shareType === "screen" ? 0 : root.targetX
                y: root.shareType === "screen" ? 0 : root.targetY
                width: root.shareType === "screen" ? win.screenWidth : root.targetW
                height: root.shareType === "screen" ? win.screenHeight : root.targetH

                Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
                Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
                Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }
                Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutQuad } }

                // Outer dark contrast stroke
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -1
                    color: "transparent"
                    border.color: "#60000000"
                    border.width: 1
                }

                // Main 3px vibrant Apple Red border
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.color: "#ef4444"
                    border.width: 3
                }

                // Inner dark contrast stroke
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 3
                    color: "transparent"
                    border.color: "#40000000"
                    border.width: 1
                }
            }
        }
    }
}
