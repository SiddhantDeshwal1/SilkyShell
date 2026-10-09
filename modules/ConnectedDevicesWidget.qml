import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// ─────────────────────────────────────────────────────────────────────────────
// ConnectedDevicesWidget — 2x2 Connected Devices Battery Status Widget.
// Features:
//   - 4 Quadrants: Slot 1 is Laptop Battery; Slots 2-4 are connected Bluetooth
//     peripherals (Mouse, Headphones, Keyboard, Phone).
//   - Live Horseshoe / Semi-Circle Arc Progress Rings (270° sweep, rounded caps).
//   - When connected: renders device icon, battery percentage, and vibrant Apple green arc.
//   - When disconnected: renders clean dark grey placeholder arc track with zero clutter.
//   - Liquid glass squircle styling matching the Control Center aesthetic.
// ─────────────────────────────────────────────────────────────────────────────

LiquidGlassCard {
    id: root

    cardRadius: 35
    implicitWidth: 182
    implicitHeight: 156

    readonly property string sfFont: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    // ── Device State ───────────────────────────────────────────────────
    property int    laptopBatteryPct: (UPower.displayDevice && UPower.displayDevice.ready) ? Math.round(UPower.displayDevice.percentage * 100) : 0
    property string laptopStatus: laptopCharging ? "Charging" : "Discharging"
    property bool   laptopCharging: !UPower.onBattery

    // Bluetooth Devices list: [{ name, mac, battery, iconType, iconPath }]
    property var btConnectedDevices: []
    property var _btBuffer: []

    // ── 2. Bluetooth Connected Devices Poller ───────────────────────────
    Process {
        id: btDevicesProc
        command: ["/home/banana/.config/quickshell/scripts/bluetooth-service.py", "get"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                const trimmed = line.trim()
                if (!trimmed || !trimmed.startsWith("{")) return
                try {
                    const data = JSON.parse(trimmed)
                    const conn = (data.devices || []).filter(d => d.isConnected)
                    const mapped = conn.map(d => {
                        let iconPath = "file:///home/banana/.config/quickshell/media/icons/bluetooth_white.svg"
                        if (d.iconType === "mouse") iconPath = "file:///home/banana/.config/quickshell/media/icons/mouse_white.svg"
                        else if (d.iconType === "headphones") iconPath = "file:///home/banana/.config/quickshell/media/icons/headphones_white.svg"
                        else if (d.iconType === "keyboard") iconPath = "file:///home/banana/.config/quickshell/media/icons/keyboard_white.svg"
                        else if (d.iconType === "phone") iconPath = "file:///home/banana/.config/quickshell/media/icons/phone_white.svg"

                        return {
                            mac: d.mac,
                            name: d.name,
                            battery: parseInt(d.battery) || 0,
                            iconType: d.iconType,
                            iconPath: iconPath
                        }
                    })
                    root.btConnectedDevices = mapped
                } catch (e) {}
            }
        }
    }

    Timer {
        interval: 4000
        running: root.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root._btBuffer = []
            if (!btDevicesProc.running) btDevicesProc.running = true
        }
    }

    // Helper functions to resolve slots
    function getSlotDevice(index) {
        if (index === 0) {
            // Slot 1: Laptop
            return {
                connected: true,
                battery: root.laptopBatteryPct,
                isCharging: root.laptopCharging,
                iconType: "laptop",
                iconPath: "file:///home/banana/.config/quickshell/media/icons/laptop_white.svg",
                name: "Laptop"
            }
        }

        // Search for specific device matches or fill sequentially
        const devices = root.btConnectedDevices || []

        if (index === 1) {
            // Prefer Mouse for Slot 2
            const mouseDev = devices.find(d => d.iconType === "mouse")
            if (mouseDev) return Object.assign({ connected: true, isCharging: false }, mouseDev)
            // Or return first available if not mouse
            if (devices.length > 0 && devices[0].iconType !== "headphones") {
                return Object.assign({ connected: true, isCharging: false }, devices[0])
            }
        } else if (index === 2) {
            // Prefer Headphones for Slot 3
            const headDev = devices.find(d => d.iconType === "headphones")
            if (headDev) return Object.assign({ connected: true, isCharging: false }, headDev)
            // Or return second available
            const others = devices.filter(d => d.iconType !== "mouse")
            if (others.length > 0) return Object.assign({ connected: true, isCharging: false }, others[0])
        } else if (index === 3) {
            // Slot 4: 3rd device / Keyboard / Phone
            const keyDev = devices.find(d => d.iconType === "keyboard" || d.iconType === "phone")
            if (keyDev) return Object.assign({ connected: true, isCharging: false }, keyDev)
            if (devices.length > 2) return Object.assign({ connected: true, isCharging: false }, devices[2])
        }

        return { connected: false, battery: 0, isCharging: false, iconType: "", iconPath: "", name: "" }
    }

    // ── 2x2 Quadrant Grid ─────────────────────────────────────────────
    Grid {
        anchors.centerIn: parent
        columns: 2
        rows: 2
        columnSpacing: 4
        rowSpacing: 4

        Repeater {
            model: 4

            Item {
                id: cell
                width: 78
                height: 68

                property var dev: root.getSlotDevice(index)
                property bool connected: dev && dev.connected
                property int batteryPct: dev ? dev.battery : 0
                property bool isCharging: dev ? dev.isCharging : false
                property string iconPath: dev ? dev.iconPath : ""

                // Redraw canvas whenever dev properties change
                onDevChanged: arcCanvas.requestPaint()
                onBatteryPctChanged: arcCanvas.requestPaint()
                onConnectedChanged: arcCanvas.requestPaint()

                scale: cellMouse.containsMouse && cell.connected ? 1.05 : 1.0
                Behavior on scale {
                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutBack
                        easing.overshoot: 1.15
                    }
                }

                MouseArea {
                    id: cellMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                }

                // Horseshoe / Semi-Circle Progress Arc Canvas
                Canvas {
                    id: arcCanvas
                    anchors.fill: parent
                    renderTarget: Canvas.Image

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)

                        const cx = width / 2
                        const cy = 31
                        const R = 24
                        const lineWidth = 7.5

                        // 270° Horseshoe Arc:
                        // Starts at 135° (bottom-left) and ends at 45° (bottom-right) clockwise
                        const startAngle = 0.75 * Math.PI
                        const endAngle = 0.25 * Math.PI
                        const totalSweep = 1.5 * Math.PI // 270°

                        // 1. Draw Background Track (Always visible)
                        ctx.strokeStyle = "#30ffffff"
                        ctx.lineWidth = lineWidth
                        ctx.lineCap = "round"
                        ctx.beginPath()
                        ctx.arc(cx, cy, R, startAngle, endAngle, false)
                        ctx.stroke()

                        // 2. Draw Live Filled Progress Arc (If Connected)
                        if (cell.connected && cell.batteryPct > 0) {
                            const p = Math.max(0.01, Math.min(1.0, cell.batteryPct / 100.0))
                            const currentAngle = startAngle + p * totalSweep

                            // Battery Color Palette
                            let col = "#34c759" // Apple vibrant green
                            if (!cell.isCharging) {
                                if (cell.batteryPct <= 20) col = "#ef4444" // Red
                                else if (cell.batteryPct <= 45) col = "#f59e0b" // Amber
                            }

                            ctx.strokeStyle = col
                            ctx.lineWidth = lineWidth
                            ctx.lineCap = "round"
                            ctx.beginPath()
                            ctx.arc(cx, cy, R, startAngle, currentAngle, false)
                            ctx.stroke()
                        }
                    }
                }

                // ── 1. Big Device Icon (Centered DIRECTLY INSIDE the ring) ───────
                Image {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.top
                    anchors.verticalCenterOffset: 31
                    width: 26
                    height: 26
                    source: cell.iconPath
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    mipmap: true
                    visible: cell.connected
                }

                // ── 2. Battery Level Text (Positioned JUST BELOW the ring) ───────
                RowLayout {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 49
                    spacing: 1
                    visible: cell.connected

                    Text {
                        text: cell.batteryPct > 0 ? cell.batteryPct : "--"
                        font.family: root.sfFont
                        font.pixelSize: 14
                        font.bold: true
                        color: "#ffffff"
                        renderType: Text.NativeRendering
                    }

                    // Charging bolt indicator if on AC
                    Text {
                        visible: cell.isCharging
                        text: "󱐋"
                        font.family: root.iconFont
                        font.pixelSize: 11
                        font.bold: true
                        color: "#34c759"
                        renderType: Text.NativeRendering
                    }
                }
            }
        }
    }
}
