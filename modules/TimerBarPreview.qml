import QtQuick
import QtQuick.Layouts
import Quickshell

// ─────────────────────────────────────────────────────────────────────────────
// TimerBarPreview — Live bar countdown / stopwatch preview.
// Positioned left of System Stats and left of device badges.
// Visible only when a timer / stopwatch is running, paused, or in overtime.
// Left-click: toggle pause/play (or reset if overtime).
// Right-click: open control center timer sub-menu.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root
    Layout.fillHeight: true
    Layout.alignment: Qt.AlignVCenter

    property var controlCenter: null

    readonly property bool isOvertime: controlCenter ? controlCenter.timerOvertimeActive : false
    readonly property bool isRunning: controlCenter ? controlCenter.timerRunning : false
    readonly property bool isSet: controlCenter ? controlCenter.timerIsSet : false
    readonly property string mode: controlCenter ? controlCenter.timerMode : "timer"
    readonly property string display: controlCenter ? controlCenter.timerDisplay : ""

    readonly property bool shouldShow: isOvertime || isRunning || (isSet && display !== "" && display !== "Timer")

    implicitWidth: shouldShow ? pillRow.implicitWidth + 14 : 0
    visible: opacity > 0.001
    opacity: shouldShow ? 1.0 : 0.0
    clip: true

    Behavior on implicitWidth {
        NumberAnimation {
            duration: 260
            easing.type: Easing.OutBack
            easing.overshoot: 1.1
        }
    }
    Behavior on opacity {
        NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
    }

    readonly property color greenAccent: "#10b981"
    readonly property color redAccent: "#f43f5e"

    readonly property color activeColor: {
        if (root.isOvertime) return redAccent
        if (root.isRunning) return greenAccent
        return "#cbd5e1"
    }

    // Pill container
    Rectangle {
        id: pillBg
        anchors.centerIn: parent
        width: parent.width > 4 ? parent.width - 4 : 0
        height: 22
        radius: 6
        color: mouseArea.containsMouse
            ? Qt.rgba(root.activeColor.r, root.activeColor.g, root.activeColor.b, 0.22)
            : (root.isOvertime ? Qt.rgba(0.96, 0.25, 0.38, 0.18) : Qt.rgba(0.06, 0.72, 0.51, 0.12))
        border.color: mouseArea.containsMouse
            ? Qt.rgba(root.activeColor.r, root.activeColor.g, root.activeColor.b, 0.65)
            : (root.isOvertime ? Qt.rgba(0.96, 0.25, 0.38, 0.45) : Qt.rgba(0.06, 0.72, 0.51, 0.35))
        border.width: 1

        Behavior on color { ColorAnimation { duration: 160 } }
        Behavior on border.color { ColorAnimation { duration: 160 } }

        RowLayout {
            id: pillRow
            anchors.centerIn: parent
            spacing: 5

            // Icon glyph
            Text {
                font.family: "JetBrainsMono NFP"
                font.pixelSize: 13
                font.bold: true
                color: root.activeColor
                text: {
                    if (root.isOvertime) return "󰥔"
                    if (root.mode === "stopwatch") return "󰔚"
                    return "󰔞"
                }
                renderType: Text.QtRendering

                Behavior on color { ColorAnimation { duration: 160 } }

                SequentialAnimation on opacity {
                    running: root.isOvertime
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
                }
            }

            // Live Time Text
            Text {
                font.family: "SF Pro Rounded"
                font.pixelSize: 13
                font.bold: true
                color: root.isOvertime ? root.redAccent : (root.isRunning ? "#ffffff" : "#94a3b8")
                text: root.display
                renderType: Text.QtRendering

                Behavior on color { ColorAnimation { duration: 160 } }
            }
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: (mouse) => {
            if (mouse.button === Qt.RightButton) {
                if (root.controlCenter) root.controlCenter.openTimerMenu()
            } else {
                if (root.controlCenter) root.controlCenter.timerToggle()
            }
        }
    }
}
