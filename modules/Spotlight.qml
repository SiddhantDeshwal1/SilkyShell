import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

PanelWindow {
    id: root

    property bool open: false

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
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    color: "transparent"
    
    // Use a small delay before hiding to allow exit animations to run
    visible: root.open || hideTimer.running

    IpcHandler {
        target: "spotlight"
        function toggle() { root.open ? root.closeSpotlight() : root.openSpotlight() }
        function open()   { root.openSpotlight(); spotlightBar.forceSearch(""); }
        function close()  { root.closeSpotlight() }
        function search(q: string): void { spotlightBar.forceSearch(q) }
    }

    function openSpotlight() {
        runShell("quickshell ipc call controlcenter close &")
        runShell("quickshell ipc call notifications close &")
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
        cmdProc.command = ["sh", "-c", cmd]
        cmdProc.running = true
    }

    Timer {
        id: hideTimer
        interval: 280 // Matches 250ms smooth exit animation
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
            if (event.key === Qt.Key_1) {
                spotlightBar.activateShortcut(0)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_2) {
                spotlightBar.activateShortcut(1)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_3) {
                spotlightBar.activateShortcut(2)
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_4) {
                spotlightBar.activateShortcut(3)
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
