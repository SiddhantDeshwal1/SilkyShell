import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// ScreenTimeWidget — macOS / iOS Style Screen On Time Capsule Widget (1x2).
// Features:
//   - Shows today's accumulated active Screen On Time (e.g. "3h 11m").
//   - Multi-colored horizontal segmented capsule progress bar indicating top apps.
//   - Hydraulic tactile press and liquid glass hover effects.
//   - Clicking triggers signal `clicked()` to open the detailed Screen Time sub-menu.
// ─────────────────────────────────────────────────────────────────────────────

LiquidGlassCard {
    id: root

    cardRadius: 35
    implicitWidth: 182
    implicitHeight: 70

    signal clicked()

    isHovered: mouseArea.containsMouse
    isPressed: mouseArea.pressed

    readonly property string sfFont: "SF Pro Rounded"

    // ── Screen Time State ─────────────────────────────────────────────
    property int    totalSeconds: 0
    property string hoursStr: "0"
    property string minutesStr: "00"
    property string totalFormatted: "0m"
    property var    apps: []

    // ── Direct File View JSON Parser (Zero Process Overhead) ─────────
    function updateFromJson(jsonStr) {
        if (!jsonStr || jsonStr.trim() === "") return
        try {
            const data = JSON.parse(jsonStr.trim())
            if (data) {
                root.totalSeconds = data.totalSeconds || 0
                root.hoursStr = String(data.hours !== undefined ? data.hours : "0")
                root.minutesStr = (data.minutes !== undefined && data.hours > 0)
                    ? (data.minutes < 10 ? "0" + data.minutes : String(data.minutes))
                    : String(data.minutes || "0")
                root.totalFormatted = data.totalFormatted || "0m"
                root.apps = data.apps || []
            }
        } catch (e) {}
    }

    FileView {
        id: screentimeWatcher
        path: "/home/banana/.cache/quickshell/screentime.json"
        watchChanges: true
        onFileChanged: {
            root.updateFromJson(screentimeWatcher.text())
        }
    }

    Component.onCompleted: {
        root.updateFromJson(screentimeWatcher.text())
    }

    // ── Main Widget Layout ────────────────────────────────────────────
    ColumnLayout {
        anchors.centerIn: parent
        spacing: 5

        // 1. Time Display: e.g. "3h 11m"
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 2

            // Hours
            Text {
                text: root.hoursStr
                font.family: root.sfFont
                font.pixelSize: 20
                font.bold: true
                color: "#ffffff"
                renderType: Text.NativeRendering
                Layout.alignment: Qt.AlignBaseline
            }

            Text {
                text: "h"
                font.family: root.sfFont
                font.pixelSize: 13
                font.bold: false
                color: "#cbd5e1"
                renderType: Text.NativeRendering
                Layout.alignment: Qt.AlignBaseline
            }

            Item { Layout.preferredWidth: 4 }

            // Minutes
            Text {
                text: root.minutesStr
                font.family: root.sfFont
                font.pixelSize: 20
                font.bold: true
                color: "#ffffff"
                renderType: Text.NativeRendering
                Layout.alignment: Qt.AlignBaseline
            }

            Text {
                text: "m"
                font.family: root.sfFont
                font.pixelSize: 13
                font.bold: false
                color: "#cbd5e1"
                renderType: Text.NativeRendering
                Layout.alignment: Qt.AlignBaseline
            }
        }

        // 2. Segmented Multi-Colored Capsule Bar (100% Guaranteed Curvy Capsule Ends via Canvas Clipping)
        Canvas {
            id: barCanvas
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 144
            Layout.preferredHeight: 12
            renderTarget: Canvas.Image

            onPaint: {
                const ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                const r = height / 2

                // 1. Capsule clipping path for perfectly smooth rounded ends
                ctx.save()
                ctx.beginPath()
                ctx.moveTo(r, 0)
                ctx.lineTo(width - r, 0)
                ctx.arc(width - r, r, r, -Math.PI / 2, Math.PI / 2, false)
                ctx.lineTo(r, height)
                ctx.arc(r, r, r, Math.PI / 2, -Math.PI / 2, false)
                ctx.closePath()
                ctx.clip()

                // Background track
                ctx.fillStyle = "#25ffffff"
                ctx.fillRect(0, 0, width, height)

                // 2. Draw Colored App Segments
                let curX = 0
                if (root.apps && root.apps.length > 0 && root.totalSeconds > 0) {
                    for (let i = 0; i < root.apps.length; i++) {
                        const app = root.apps[i]
                        const w = Math.max(2, (app.seconds / root.totalSeconds) * width)
                        ctx.fillStyle = app.color || "#3b82f6"
                        ctx.fillRect(curX, 0, w, height)
                        curX += w
                    }
                } else {
                    ctx.fillStyle = "#475569"
                    ctx.fillRect(0, 0, width, height)
                }
                ctx.restore()

                // 3. Subtle Border
                ctx.beginPath()
                ctx.moveTo(r, 0.5)
                ctx.lineTo(width - r, 0.5)
                ctx.arc(width - r, r, r - 0.5, -Math.PI / 2, Math.PI / 2, false)
                ctx.lineTo(r, height - 0.5)
                ctx.arc(r, r, r - 0.5, Math.PI / 2, -Math.PI / 2, false)
                ctx.closePath()
                ctx.strokeStyle = "#35ffffff"
                ctx.lineWidth = 1
                ctx.stroke()
            }

            Connections {
                target: root
                function onAppsChanged() { barCanvas.requestPaint() }
                function onTotalSecondsChanged() { barCanvas.requestPaint() }
            }
        }
    }

    // ── Click to open Menu ────────────────────────────────────────────
    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
