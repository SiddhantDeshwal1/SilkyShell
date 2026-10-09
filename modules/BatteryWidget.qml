import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// ─────────────────────────────────────────────────────────────────────────────
// BatteryWidget — macOS-Style Horizontal Capsule Battery Icon & Percentage.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root
    Layout.fillHeight: true
    implicitWidth: batteryText.implicitWidth + 4

    // ── Native UPower Integration (Zero Shell Overhead) ───────────────
    property real   batteryPct:   (UPower.displayDevice && UPower.displayDevice.ready) ? Math.round(UPower.displayDevice.percentage * 100) : 0
    property string batteryStatus: charging ? "Charging" : "Discharging"
    property bool   batteryReady: UPower.displayDevice ? UPower.displayDevice.ready : false
    property bool   charging:     !UPower.onBattery

    // ── Low Battery & Alert Configuration ─────────────────────────────
    readonly property int lowBatteryThreshold: 25
    property bool initialized: false
    property bool lastOnBattery: UPower.onBattery

    // ── Audio Feedback (Zero Process Spawning) ─────────────────────────
    SoundEffect {
        id: chargingSound
        source: Qt.resolvedUrl("../media/audio/macos_charging_sound.wav")
        volume: 0.7
    }

    SoundEffect {
        id: lowBatterySound
        source: Qt.resolvedUrl("../media/audio/bmw_chime.wav")
        volume: 0.8
    }

    // ── Low Battery Notification Dispatcher ───────────────────────────
    function triggerLowBatteryAlert() {
        if (!root.batteryReady || root.charging || root.batteryPct <= 0) return
        if (root.batteryPct < root.lowBatteryThreshold) {
            lowBatterySound.play()
            Quickshell.execDetached([
                "notify-send",
                "-u", "normal",
                "-t", "10000",
                "-i", "battery-low",
                "Low Battery",
                "Battery level is " + Math.round(root.batteryPct) + "%. Plug in the charger!"
            ])
        }
    }

    // Periodic Low Battery check (every 60s while low and discharging, mirroring battery.sh)
    Timer {
        id: lowBatteryTimer
        interval: 60000
        repeat: true
        running: root.batteryReady && !root.charging && root.batteryPct < root.lowBatteryThreshold
        onTriggered: root.triggerLowBatteryAlert()
    }

    // Charger Connection & Disconnection Event Watcher
    Connections {
        target: UPower
        function onOnBatteryChanged() {
            if (!root.initialized) return

            // Transition from on-battery (true) to charging (false) -> Play charger chime
            if (root.lastOnBattery && !UPower.onBattery) {
                chargingSound.play()
            }
            root.lastOnBattery = UPower.onBattery

            // If disconnected and immediately low, trigger check
            if (UPower.onBattery && root.batteryPct < root.lowBatteryThreshold) {
                root.triggerLowBatteryAlert()
            }
        }
    }

    // Battery Percentage drop watcher
    onBatteryPctChanged: {
        if (!root.initialized) return
        if (!root.charging && root.batteryPct < root.lowBatteryThreshold) {
            root.triggerLowBatteryAlert()
        }
    }

    Component.onCompleted: {
        root.lastOnBattery = UPower.onBattery
        initTimer.start()
    }

    Timer {
        id: initTimer
        interval: 1000
        repeat: false
        onTriggered: {
            root.initialized = true
            // Check once after initial startup if battery is low
            if (!root.charging && root.batteryPct > 0 && root.batteryPct < root.lowBatteryThreshold) {
                root.triggerLowBatteryAlert()
            }
        }
    }

    // ── Color by level ────────────────────────────────────────────────
    property color batteryColor: {
        if (charging)         return "#a6e3a1"
        if (batteryPct <= 20) return "#f38ba8"
        if (batteryPct <= 50) return "#f9e2af"
        return "#a6e3a1"
    }

    // Percentage text
    Text {
        id: batteryText
        anchors.verticalCenter: parent.verticalCenter
        font.family: "SF Pro Rounded"
        font.pixelSize: 17
        font.bold: false
        renderType: Text.NativeRendering
        color: root.batteryColor
        text: {
            if (!root.batteryReady) return "BC: --"
            const prefix = root.charging ? "BC: " : "B: "
            return prefix + Math.round(root.batteryPct) + "%"
        }

        Behavior on color {
            ColorAnimation { duration: 350; easing.type: Easing.InOutCubic }
        }
    }
}
