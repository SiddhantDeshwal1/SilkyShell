import QtQuick
import QtQuick.Layouts
import Quickshell

// ─────────────────────────────────────────────────────────────────────────────
// ClockWidget — Top bar Date & Time display in "Fri 28 Jan 14:04" format.
// Clicking the widget opens / toggles the Notifications Panel.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root
    Layout.fillHeight: true
    implicitWidth: clockText.implicitWidth + 16

    signal clicked()

    Text {
        id: clockText
        anchors.centerIn: parent
        font.family: "SF Pro Rounded"
        font.pixelSize: 17
        font.bold: false
        renderType: Text.NativeRendering
        color: mouseArea.containsMouse ? "#ffffff" : "#ebdbb2"
        text: "--"

        Behavior on color {
            ColorAnimation { duration: 150; easing.type: Easing.InOutCubic }
        }

        Timer {
            interval: 1000
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: {
                const now = new Date()
                const days   = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                clockText.text = days[now.getDay()] + " " +
                    now.getDate() + " " +
                    months[now.getMonth()] + "  " +
                    String(now.getHours()).padStart(2, "0") + ":" +
                    String(now.getMinutes()).padStart(2, "0")
            }
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.clicked()
        }
    }
}
