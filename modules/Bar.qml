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
    color: "transparent"

    // ── SMOOTH TRANSPARENT FROSTED GLASS BACKGROUND ──────────────────────────
    Item {
        id: barBackground
        anchors.fill: parent
        z: 0

        // 1. Contrast Underlayer: Soft dark tint ensuring text is clearly legible
        // regardless of wallpaper brightness or complexity.
        Rectangle {
            anchors.fill: parent
            color: Theme.darkMode ? Qt.rgba(0.03, 0.03, 0.06, 0.42) : Qt.rgba(1.0, 1.0, 1.0, 0.30)

            Behavior on color {
                ColorAnimation { duration: 350; easing.type: Easing.OutCubic }
            }
        }

        // 2. Wallpaper-harmonized translucent tint with smooth vertical gradient.
        // Gives optical glass depth: slightly lighter at the top, deeper at the bottom.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop {
                    position: 0.0
                    color: Theme.darkMode
                        ? Qt.rgba(Theme.barBgColor.r * 1.15, Theme.barBgColor.g * 1.15, Theme.barBgColor.b * 1.15, 0.36)
                        : Qt.rgba(1.0, 1.0, 1.0, 0.42)
                }
                GradientStop {
                    position: 1.0
                    color: Theme.darkMode
                        ? Qt.rgba(Theme.barBgColor.r * 0.85, Theme.barBgColor.g * 0.85, Theme.barBgColor.b * 0.85, 0.48)
                        : Qt.rgba(0.92, 0.94, 0.98, 0.46)
                }
            }
        }

        // 3. Top Specular Glass Reflection: 1px subtle highlight rim simulating glass bevel.
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.darkMode ? "#1affffff" : "#45ffffff"
        }

        // 4. Bottom Glass Hairline Border: Subtle separation between bar and workspace.
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 1
            color: Theme.darkMode ? "#22ffffff" : "#18000000"
        }
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

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        spacing: 12
        z: 1

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
        TimerBarPreview {
            controlCenter: controlCenterPanel
        }
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

