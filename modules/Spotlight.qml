import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

PanelWindow {
    id: root

    property bool open: false

    // Direct references wired from Bar.qml to avoid IPC subprocess overhead
    property var controlCenter: null
    property var notificationCenter: null

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-spotlight"
    WlrLayershell.keyboardFocus: root.open
        ? WlrKeyboardFocus.OnDemand
        : WlrKeyboardFocus.None

    color: "transparent"
    
    // Use a small delay before hiding to allow exit animations to run
    visible: root.open || hideTimer.running

    IpcHandler {
        target: "spotlight"
        function toggle() { root.open ? root.closeSpotlight() : root.openSpotlight() }
        function open()   { root.openSpotlight(); spotlightBar.forceSearch(""); }
        function close()  { root.closeSpotlight() }
        function search(q: string) { spotlightBar.forceSearch(q) }
    }

    function openSpotlight() {
        // Close sibling panels directly — no subprocess/IPC round-trip needed
        if (root.controlCenter && typeof root.controlCenter.close === "function")
            root.controlCenter.close()
        if (root.notificationCenter && typeof root.notificationCenter.closePanel === "function")
            root.notificationCenter.closePanel()
        root.open = true
        hideTimer.stop()
    }

    function closeSpotlight() {
        if (root.open) {
            root.open = false
            hideTimer.restart()
        }
    }

    Process { id: cmdProc }
    function runShell(cmd) {
        cmdProc.running = false
        cmdProc.command = ["sh", "-c", cmd]
        cmdProc.running = true
    }

    Timer {
        id: hideTimer
        interval: 220 // Exactly covers 200ms reverse animation + 20ms buffer
        repeat: false
    }

    // Click outside to dismiss
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: root.closeSpotlight()
    }

    // Root key handler for Escape
    Item {
        anchors.fill: parent
        focus: false
        
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.closeSpotlight()
                event.accepted = true
                return
            }
            // Number key shortcuts (1-4) → activate shortcut at index
            const numKey = event.key - Qt.Key_1
            if (numKey >= 0 && numKey <= 3) {
                spotlightBar.activateShortcut(numKey)
                event.accepted = true
                return
            }
        }

        SpotlightBar {
            id: spotlightBar
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.30
            isOpen: root.open
            onCloseRequested: root.closeSpotlight()
            onRunCommand: function(cmd) { root.runShell(cmd) }
        }
    }
}
