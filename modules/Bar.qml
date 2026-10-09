import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland

// Full-width, always-visible black bar on the primary monitor.
// Height 28px. exclusiveZone: 28 reserves space so windows don't overlap.
PanelWindow {
    id: barWindow

    anchors {
        top: true
        left: true
        right: true
    }

    exclusiveZone: 28
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "quickshell-bar"

    implicitHeight: 28
    color: "#930a0a12"

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
        NotificationWidget {
            id: notificationWidget
            dndActive: controlCenterPanel.dndActive
            controlCenter: controlCenterPanel
        }
    }

    ControlCenter {
        id: controlCenterPanel
        onDndActiveChanged: {
            if (notificationWidget) notificationWidget.dndActive = controlCenterPanel.dndActive
        }
    }
}

