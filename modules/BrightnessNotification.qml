import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// ─────────────────────────────────────────────────────────────────────────────
// BrightnessNotification — Pure Liquid Glass Brightness Notification.
//
// Watches kernel backlight sysfs via inotifywait.
// Auto-shows when brightness changes; auto-hides after 3 s of silence.
// Styled with the same transparent liquid glass design as NotificationWidget.
// ─────────────────────────────────────────────────────────────────────────────
PanelWindow {
    id: root

    // ── State ─────────────────────────────────────────────────────────
    property bool open: false

    property int brightness: 0
    property int maxBrightness: 100
    property int brightnessReads: 0
    property bool brightnessReady: false

    property real brightnessLevel: maxBrightness > 0
        ? Math.max(0, Math.min(1, brightness / maxBrightness))
        : 0

    // ── Layer / window setup ──────────────────────────────────────────
    anchors {
        top:   true
        right: true
    }

    WlrLayershell.margins.top: 40
    WlrLayershell.margins.right: 16
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-brightness-notification"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    color: "transparent"
    implicitWidth: 380
    implicitHeight: Math.max(1, card.implicitHeight + 20)

    visible: open || card.opacity > 0

    // ── Auto-dismiss timer ────────────────────────────────────────────
    Timer {
        id: autoDismiss
        interval: 3000
        repeat: false
        onTriggered: root.open = false
    }

    property var controlCenter: null

    // ── Sysfs brightness watcher ──────────────────────────────────────
    Process {
        running: true
        command: [
            "sh", "-c",
            "for b in /sys/class/backlight/*; do" +
            "  if [ -r \"$b/brightness\" ] && [ -r \"$b/max_brightness\" ]; then" +
            "    cat \"$b/brightness\" \"$b/max_brightness\";" +
            "    while inotifywait -qq -e modify \"$b/brightness\"; do" +
            "      cat \"$b/brightness\";" +
            "    done; exit;" +
            "  fi;" +
            "done"
        ]
        stdout: SplitParser {
            onRead: function(data) {
                const value = parseInt(data)
                if (isNaN(value)) return

                if (!root.brightnessReady) {
                    if (root.brightnessReads === 0) {
                        root.brightness      = value
                        root.brightnessReads = 1
                    } else {
                        root.maxBrightness   = Math.max(1, value)
                        root.brightnessReady = true
                    }
                    return
                }

                // Live brightness change → show notification (unless control center widget panel is open)
                if (root.brightness !== value) {
                    root.brightness = value
                    if (!root.controlCenter || !root.controlCenter.open) {
                        root.open = true
                        autoDismiss.restart()
                    }
                }
            }
        }
    }

    // ── Pure Liquid Glass Card ────────────────────────────────────────
    Rectangle {
        id: card
        anchors.top: parent.top
        width: 360
        implicitHeight: cardContent.implicitHeight + 28
        radius: 18
        layer.enabled: true
        layer.smooth: true

        // 1. Pure Neutral Liquid Glass Tint
        color: cardMouse.containsMouse ? Qt.lighter(Theme.panelBgColor, 1.1) : Theme.panelBgColor
        border.color: cardMouse.containsMouse ? "#99ffffff" : Theme.panelBorderColor
        border.width: 1.5

        // Snappy GPU translation: slide in from right to left (380 -> 20), slide out from left to right (20 -> 380)
        x: root.open ? (root.implicitWidth - width) : root.implicitWidth
        opacity: root.open ? 1.0 : 0.0
        scale: root.open ? 1.0 : 0.94

        Behavior on x {
            NumberAnimation {
                duration: root.open ? 240 : 200
                easing.type: root.open ? Easing.OutBack : Easing.InQuad
                easing.overshoot: 1.08
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: root.open ? 200 : 200
                easing.type: root.open ? Easing.OutQuad : Easing.InQuad
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: root.open ? 220 : 200
                easing.type: root.open ? Easing.OutBack : Easing.InQuad
                easing.overshoot: 1.08
            }
        }
        Behavior on color {
            ColorAnimation { duration: 150; easing.type: Easing.InOutCubic }
        }
        Behavior on border.color {
            ColorAnimation { duration: 150; easing.type: Easing.InOutCubic }
        }

        // 2. Liquid Glass Top Specular Shine
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: cardMouse.containsMouse ? "#4dffffff" : "#2effffff" }
                GradientStop { position: 0.35; color: "#0dffffff" }
                GradientStop { position: 1.0; color: "#00ffffff" }
            }
        }

        // 3. Liquid Glass Inner Specular Rim Highlight
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            radius: parent.radius - 1
            color: "transparent"
            border.color: cardMouse.containsMouse ? "#59ffffff" : "#26ffffff"
            border.width: 1
        }

        // Click to dismiss
        MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.open = false
        }

        // ── Card content ──────────────────────────────────────────────
        ColumnLayout {
            id: cardContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 14
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            anchors.bottomMargin: 14
            spacing: 12
            z: 3

            // Header row: icon + label + percentage
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    font.family: "JetBrainsMono NFP"
                    font.pixelSize: 18
                    color: "#ffffff"
                    text: {
                        const pct = root.brightnessLevel
                        if (pct > 0.66) return "󰃠"
                        if (pct > 0.33) return "󰃟"
                        return "󰃞"
                    }
                }

                Text {
                    font.family: "SF Pro Rounded"
                    font.pixelSize: 14
                    font.bold: true
                    color: "#ffffff"
                    text: "BRIGHTNESS"
                }

                Item { Layout.fillWidth: true }

                Text {
                    font.family: "SF Pro Rounded"
                    font.pixelSize: 14
                    font.bold: true
                    color: "#ffffff"
                    text: Math.round(root.brightnessLevel * 100) + "%"
                }
            }

            // Progress bar track + 11-Step Level Tick Markers (No min/max ticks)
            Item {
                Layout.fillWidth: true
                implicitHeight: 20

                Rectangle {
                    id: bTrack
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 8
                    radius: 4
                    color: "#2effffff"
                    border.color: "#33ffffff"
                    border.width: 1

                    Rectangle {
                        height: parent.height
                        radius: parent.radius
                        color: "#ffffff"
                        width: bTrack.width * root.brightnessLevel
                        Behavior on width {
                            NumberAnimation { duration: 120; easing.type: Easing.OutQuart }
                        }
                    }
                }

                // 11 Precision Level Indicator Ticks Under Slider (No min/max ticks)
                Item {
                    id: bTickContainer
                    anchors.left: bTrack.left
                    anchors.right: bTrack.right
                    anchors.top: bTrack.bottom
                    anchors.topMargin: 2
                    height: 6

                    Repeater {
                        model: 11
                        Rectangle {
                            property real progress: index / 10.0
                            x: Math.round(progress * (bTickContainer.width - width))
                            anchors.verticalCenter: parent.verticalCenter
                            width: index === 5 ? 2 : 1.5
                            height: index === 5 ? 5 : 3
                            radius: 1
                            color: progress <= root.brightnessLevel ? "#ffffff" : "#45ffffff"
                            opacity: progress <= root.brightnessLevel ? 0.95 : 0.4
                            visible: index > 0 && index < 10
                            Behavior on color { ColorAnimation { duration: 100 } }
                        }
                    }
                }
            }
        }
    }
}
