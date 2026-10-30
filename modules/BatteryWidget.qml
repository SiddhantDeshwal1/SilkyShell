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
    property double lastAlertTimestamp: 0
    property int lastAlertPct: -1

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
    function triggerLowBatteryAlert(force) {
        if (!root.batteryReady || root.charging || root.batteryPct <= 0) return
        if (root.batteryPct >= root.lowBatteryThreshold) return

        const now = Date.now()
        // Enforce strict cooldown: prevent duplicate/overlapping notifications (minimum 60s cooldown)
        if (!force && (now - root.lastAlertTimestamp < 60000)) {
            return
        }

        root.lastAlertTimestamp = now
        root.lastAlertPct = root.batteryPct

        lowBatterySound.play()
        Quickshell.execDetached([
            "notify-send",
            "-a", "Battery",
            "-u", "normal",
            "-t", "8000",
            "-i", "battery-low",
            "-h", "string:x-canonical-private-synchronous:battery-low",
            "Low Battery",
            "Battery level is " + Math.round(root.batteryPct) + "%. Plug in the charger!"
        ])
    }

    // Periodic Low Battery reminder (every 120s while low and discharging)
    Timer {
        id: lowBatteryTimer
        interval: 120000
        repeat: true
        running: root.batteryReady && !root.charging && root.batteryPct < root.lowBatteryThreshold
        onTriggered: root.triggerLowBatteryAlert(true)
    }

    // Charger Connection & Disconnection Event Watcher
    Connections {
        target: UPower
        function onOnBatteryChanged() {
            if (!root.initialized) return

            // Transition from on-battery (true) to charging (false) -> Play charger chime & reset alert tracker
            if (root.lastOnBattery && !UPower.onBattery) {
                chargingSound.play()
                root.lastAlertPct = -1
            }
            root.lastOnBattery = UPower.onBattery

            // If disconnected and immediately low, trigger check with cooldown guard
            if (UPower.onBattery && root.batteryPct < root.lowBatteryThreshold) {
                root.triggerLowBatteryAlert(false)
            }
        }
    }

    // Battery Percentage drop watcher — triggers only on milestone thresholds (e.g. 20%, 15%, 10%, 5%)
    onBatteryPctChanged: {
        if (!root.initialized || root.charging) return
        if (root.batteryPct < root.lowBatteryThreshold) {
            const isMilestone = (root.batteryPct === 20 || root.batteryPct === 15 || root.batteryPct === 10 || root.batteryPct <= 5)
            if (isMilestone && root.batteryPct !== root.lastAlertPct) {
                root.triggerLowBatteryAlert(false)
            }
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
            // Check once after initial startup if battery is low (respecting cooldown)
            if (!root.charging && root.batteryPct > 0 && root.batteryPct < root.lowBatteryThreshold) {
                root.triggerLowBatteryAlert(false)
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
