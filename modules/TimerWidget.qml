import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// TimerWidget — macOS / iOS Style Capsule Widget (182x70, radius 35).
// Exactly matches PowerModeWidget shape, geometry, typography, and visual language.
// Modes:
//   - Idle / Unset: Shows "Timer", "Tap to start", default glass background
//   - Running: Shows live countdown / stopwatch, green liquid glass active background
//   - Overtime: Shows "+MM:SS", red liquid glass active background & blinking badge
//   - Paused: Dimmed green tint, "Paused • Tap to resume"
// Interactions:
//   - Left-click (unset): starts stopwatch
//   - Left-click (running): pauses
//   - Left-click (paused): resumes
//   - Left-click (overtime): resets / stops
//   - Right-click or Chevron button: opens Timer Sub-Menu
// ─────────────────────────────────────────────────────────────────────────────

LiquidGlassCard {
    id: root

    cardRadius: 35
    implicitWidth: 182
    implicitHeight: 70

    signal clicked()
    signal toggleRequested()
    signal menuRequested()
    signal resetRequested()

    readonly property string sfFont: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    // ── External Bound Timer State ────────────────────────────────────
    property string timerMode: "timer"      // "timer" | "stopwatch"
    property bool   timerRunning: false
    property int    timerSeconds: 0
    property int    timerDuration: 0
    property int    timerOvertime: 0
    property bool   timerOvertimeActive: false
    property bool   timerIsSet: false
    property string timerDisplay: "Timer"

    isHovered: cardMouse.containsMouse || chevMouse.containsMouse || iconBadgeMouse.containsMouse
    isPressed: cardMouse.pressed || iconBadgeMouse.pressed

    // ── Color Definitions ─────────────────────────────────────────────
    readonly property color greenAccent: "#10b981"
    readonly property color redAccent: "#f43f5e"
    readonly property color idleAccent: "#0ea5e9"

    readonly property color currentAccent: {
        if (root.timerOvertimeActive) return redAccent
        if (root.timerRunning || root.timerIsSet) return greenAccent
        return idleAccent
    }

    isActive: timerOvertimeActive || timerRunning || (timerIsSet && timerSeconds > 0)
    idleColor: Theme.cardIdleColor
    activeColor: {
        if (timerOvertimeActive) {
            return Qt.rgba(0.96, 0.25, 0.38, 0.32)
        }
        if (timerRunning) {
            return Qt.rgba(0.06, 0.72, 0.51, 0.26)
        }
        if (timerIsSet) {
            return Qt.rgba(0.06, 0.72, 0.51, 0.12)
        }
        return Theme.cardIdleColor
    }

    activeBorderColor: {
        if (timerOvertimeActive) return Qt.rgba(0.96, 0.25, 0.38, 0.75)
        if (timerRunning) return Qt.rgba(0.06, 0.72, 0.51, 0.65)
        return Qt.rgba(0.06, 0.72, 0.51, 0.35)
    }

    activeRimColor: {
        if (timerOvertimeActive) return Qt.rgba(0.96, 0.25, 0.38, 0.45)
        if (timerRunning) return Qt.rgba(0.06, 0.72, 0.51, 0.35)
        return Qt.rgba(0.06, 0.72, 0.51, 0.18)
    }

    // ── Main Capsule Layout (Identical to PowerModeWidget) ────────────
    RowLayout {
        z: 1
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 12
        anchors.topMargin: 8
        anchors.bottomMargin: 8
        spacing: 10

        // 1. Vector Icon Badge (44x44, radius 22)
        Rectangle {
            id: iconBadge
            z: 10
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 44
            Layout.preferredHeight: 44
            radius: 22
            color: iconBadgeMouse.containsMouse
                ? Qt.rgba(root.currentAccent.r, root.currentAccent.g, root.currentAccent.b, 0.35)
                : (root.timerOvertimeActive
                    ? Qt.rgba(0.96, 0.25, 0.38, 0.25)
                    : (root.timerRunning
                        ? Qt.rgba(0.06, 0.72, 0.51, 0.22)
                        : Qt.rgba(1.0, 1.0, 1.0, 0.08)))
            border.color: root.timerOvertimeActive
                ? Qt.rgba(0.96, 0.25, 0.38, 0.65)
                : (root.timerRunning
                    ? Qt.rgba(0.06, 0.72, 0.51, 0.55)
                    : Qt.rgba(1.0, 1.0, 1.0, 0.16))
            border.width: 1.2
            scale: iconBadgeMouse.pressed ? 0.92 : 1.0

            Behavior on color { ColorAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on border.color { ColorAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }

            // Repeating pulse animation when overtime is active
            SequentialAnimation on opacity {
                running: root.timerOvertimeActive
                loops: Animation.Infinite
                NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
            }

            Text {
                id: glyphText
                anchors.centerIn: parent
                font.family: root.iconFont
                font.pixelSize: 22
                color: root.currentAccent
                text: {
                    if (root.timerOvertimeActive) return "󰥔"
                    if (root.timerMode === "stopwatch") return "󰔚"
                    return "󰔞"
                }
                renderType: Text.QtRendering

                Behavior on color { ColorAnimation { duration: 240; easing.type: Easing.OutCubic } }
            }

            MouseArea {
                id: iconBadgeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleRequested()
            }
        }

        // 2. Title & Subtitle Column (SF Pro Rounded Typography - 16px / 13px)
        ColumnLayout {
            id: textCol
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2
            layer.enabled: true

            transform: Translate {
                id: textSlideTrans
                y: 0
            }

            // Title (16px bold, matching PowerModeWidget title)
            Text {
                text: root.timerIsSet ? root.timerDisplay : "Timer"
                font.family: root.sfFont
                font.pixelSize: 16
                font.bold: true
                color: root.timerOvertimeActive ? root.redAccent : "#ffffff"
                renderType: Text.QtRendering
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignLeft
                horizontalAlignment: Text.AlignLeft

                Behavior on color { ColorAnimation { duration: 200 } }
            }

            // Subtitle (13px bold, matching PowerModeWidget wattage)
            Text {
                text: {
                    if (root.timerOvertimeActive) return "Time Up!"
                    if (!root.timerIsSet) return "Tap to start"
                    if (root.timerRunning) return "Running"
                    return "Paused"
                }
                font.family: root.sfFont
                font.pixelSize: 13
                font.bold: true
                color: root.timerOvertimeActive ? root.redAccent : (root.timerRunning ? root.greenAccent : "#94a3b8")
                renderType: Text.QtRendering
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignLeft
                horizontalAlignment: Text.AlignLeft

                Behavior on color { ColorAnimation { duration: 240; easing.type: Easing.OutCubic } }
            }
        }

        // 3. Chevron Indicator for Submenu Access (26x26)
        Rectangle {
            id: chevBtn
            z: 10
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: 26
            Layout.preferredHeight: 26
            radius: 13
            color: chevMouse.containsMouse ? "#20ffffff" : "transparent"

            Text {
                anchors.centerIn: parent
                font.family: root.iconFont
                font.pixelSize: 14
                color: chevMouse.containsMouse ? "#ffffff" : "#64748b"
                text: "󰅂"
                renderType: Text.QtRendering
                Behavior on color { ColorAnimation { duration: 150 } }
            }

            MouseArea {
                id: chevMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.menuRequested()
            }
        }
    }

    // ── Subtle Bottom Liquid Progress Bar (Zero Layout Recalc) ────────
    Rectangle {
        id: commitBar
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 4
        anchors.horizontalCenter: parent.horizontalCenter
        width: 100
        height: 2.2
        radius: 1.1
        color: root.currentAccent
        opacity: root.isActive ? 0.9 : 0.0

        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            radius: 1.1
            color: root.currentAccent
            width: {
                if (root.timerOvertimeActive) return parent.width
                if (root.timerMode === "stopwatch") {
                    return root.timerRunning ? ((root.timerSeconds % 60) / 60.0) * parent.width : 0
                }
                if (root.timerDuration > 0) {
                    var pct = Math.max(0.0, Math.min(1.0, root.timerSeconds / root.timerDuration))
                    return pct * parent.width
                }
                return 0
            }

            Behavior on width {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
        }
    }

    // ── Main Card Mouse Area (Left: Toggle / Reset; Right: Menu) ──────
    MouseArea {
        id: cardMouse
        z: -1
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: (mouse) => {
            root.setClickPos(mouse.x, mouse.y)
            if (mouse.button === Qt.RightButton) {
                root.menuRequested()
            } else {
                root.toggleRequested()
            }
        }
    }
}
