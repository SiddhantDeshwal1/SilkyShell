import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

// Full-width, always-visible black bar on the primary monitor.
// Height 28px. exclusiveZone: 28 reserves space so windows don't overlap.
PanelWindow {
    id: barWindow

    anchors {
        top: true
        left: true
        right: true
    }

    property bool barVisible: true

    visible: barVisible
    exclusiveZone: barVisible ? 28 : 0
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-bar"

    implicitHeight: 28
    color: Theme.barBgColor

    Behavior on color {
        ColorAnimation { duration: 350; easing.type: Easing.OutCubic }
    }

    IpcHandler {
        target: "bar"
        function toggle() {
            if (barWindow.barVisible) {
                barWindow.hideBar()
            } else {
                barWindow.showBar()
            }
        }
        function show() { barWindow.showBar() }
        function hide() { barWindow.hideBar() }
    }

    function hideBar() {
        if (controlCenterPanel) controlCenterPanel.close()
        if (notificationWidget) notificationWidget.closePanel()
        barWindow.barVisible = false
    }

    function showBar() {
        barWindow.barVisible = true
    }

    // Bottom subtle glass hairline border
    Rectangle {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: "#25ffffff"
        z: 10
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        spacing: 12

        // ── LEFT SECTION ──────────────────────────────────────────────
        Workspaces {}

        Item { Layout.preferredWidth: 16 }

        MediaIsland {
            implicitWidth: 840
        }

        // DynamicIslandBar {
        //     id: dynamicIslandBar
        // }

        // ── CENTER SPACER ─────────────────────────────────────────────
        Item { Layout.fillWidth: true }

        // ── RIGHT SECTION ─────────────────────────────────────────────
        StatusDevices {}
        SysStats {}
        BrightnessNotification {
            controlCenter: controlCenterPanel
        }
        BatteryWidget {}
        ClockWidget {
            id: clockWidget
            onClicked: {
                if (controlCenterPanel) controlCenterPanel.close()
                if (notificationWidget) notificationWidget.togglePanel()
            }
        }
        ControlCenterWidget {
            id: controlCenterWidget
            controlCenter: controlCenterPanel
            notificationCenter: notificationWidget
        }
    }

    NotificationWidget {
        id: notificationWidget
        dndActive: controlCenterPanel.dndActive
        controlCenter: controlCenterPanel
    }

    ControlCenter {
        id: controlCenterPanel
        onDndActiveChanged: {
            if (notificationWidget) notificationWidget.dndActive = controlCenterPanel.dndActive
            // DynamicIslandService.focusMode = controlCenterPanel.dndActive
        }
    }

    Component.onCompleted: {
        // DynamicIslandService.focusMode = controlCenterPanel.dndActive
    }
}

