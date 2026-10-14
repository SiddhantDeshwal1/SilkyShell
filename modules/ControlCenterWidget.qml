import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects

// ─────────────────────────────────────────────────────────────────────────────
// ControlCenterWidget — Top bar button for Control Center.
// Shows white bold Control Center icon, and white Moon icon when Focus is ON.
// ─────────────────────────────────────────────────────────────────────────────

RowLayout {
    id: root
    Layout.fillHeight: true
    spacing: 10
    Layout.leftMargin: 8
    Layout.rightMargin: 6

    // Reference to ControlCenter PanelWindow instance
    property var controlCenter: null
    property var notificationCenter: null

    // Moon Icon when Focus / DND is active
    Item {
        id: focusMoon
        implicitWidth: (root.controlCenter && root.controlCenter.dndActive) ? 20 : 0
        implicitHeight: 20
        visible: opacity > 0
        opacity: (root.controlCenter && root.controlCenter.dndActive) ? 1.0 : 0.0
        clip: true
        Layout.leftMargin: (root.controlCenter && root.controlCenter.dndActive) ? 3 : 0
        Layout.rightMargin: (root.controlCenter && root.controlCenter.dndActive) ? 3 : 0

        Behavior on implicitWidth { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

        scale: (root.controlCenter && root.controlCenter.dndActive) ? 1.0 : 0.4
        Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutBack; easing.overshoot: 1.35 } }

        rotation: (root.controlCenter && root.controlCenter.dndActive) ? 0 : -25
        Behavior on rotation { NumberAnimation { duration: 300; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }

        Text {
            anchors.centerIn: parent
            text: "󰖔"
            font.family: "JetBrainsMono NFP"
            font.pixelSize: 17
            font.bold: true
            renderType: Text.QtRendering
            color: "#ffffff"
        }
    }

    // Control Center Icon Button (Crisp White Bold Icon)
    Item {
        id: btn
        implicitWidth: 19
        implicitHeight: 19
        Layout.alignment: Qt.AlignVCenter
        Layout.leftMargin: 3
        Layout.rightMargin: 3

        scale: mouseArea.pressed ? 0.90 : (mouseArea.containsMouse ? 1.08 : 1.0)
        Behavior on scale {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutBack
                easing.overshoot: 1.2
            }
        }

        Image {
            id: iconImg
            sourceSize: Qt.size(19, 19)
            anchors.fill: parent
            source: Qt.resolvedUrl("../media/images/control_center.png")
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            visible: false
        }

        ColorOverlay {
            anchors.fill: iconImg
            source: iconImg
            color: "#ffffff"
            opacity: mouseArea.containsMouse || (root.controlCenter && root.controlCenter.open) ? 1.0 : 0.92

            Behavior on opacity {
                NumberAnimation { duration: 150 }
            }
        }

        MouseArea {
            id: mouseArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (root.notificationCenter) {
                    root.notificationCenter.closePanel()
                }
                if (root.controlCenter) {
                    root.controlCenter.toggle()
                }
            }
        }
    }
}

