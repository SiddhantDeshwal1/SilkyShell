import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris
import Quickshell.Services.UPower

Rectangle {
    id: root

    property string mode: "time" // time, volume, brightness, battery
    property real volume: 0
    property bool muted: false
    property int brightness: 0
    property int maxBrightness: 100
    property bool brightnessReady: false
    property int brightnessReads: 0
    property real batteryPercentage: 0
    property string batteryStatus: "Unknown"
    property bool batteryReady: false
    // UPower's adapter state changes immediately; battery `status` can lag
    // behind it for a short time after unplugging.
    property bool charging: !UPower.onBattery
    property bool lastOnBattery: UPower.onBattery
    property bool musicPlaying: {
        const players = Mpris.players.values
        for (let i = 0; i < players.length; ++i) {
            if (players[i].isPlaying)
                return true
        }
        return false
    }
    property var activePlayer: {
        const players = Mpris.players.values
        for (let i = 0; i < players.length; ++i) {
            if (players[i].isPlaying)
                return players[i]
        }
        return players.length > 0 ? players[0] : null
    }
    property bool showingOsd: mode !== "time"
    property bool hovering: false
    property bool dashboardOpen: false
    property bool ignoreHoverUntilExit: false
    property bool collapsed: !hovering && !dashboardOpen && !showingOsd

    color: "transparent"
    radius: 0
    // Keep a thin, invisible top-center hit target while the dock is hidden.
    width: collapsed ? 320 : implicitWidth
    height: implicitHeight
    antialiasing: true
    implicitWidth: dashboardOpen ? 560 : (showingOsd ? osdContent.implicitWidth : clockContent.implicitWidth) + 56
    implicitHeight: dashboardOpen ? 320 : (collapsed ? 8 : 44)

    Behavior on implicitWidth {
        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
    }

    Behavior on implicitHeight {
        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
    }

    Timer {
        id: resetTimer
        interval: 2200
        onTriggered: root.mode = "time"
    }

    // GPU-native notch: a rounded rectangle plus a square top cap makes the
    // shape flush with the screen edge while retaining rounded lower corners.
    Rectangle {
        id: notchBackground
        anchors.fill: parent
        visible: !root.collapsed
        color: "#000000"
        radius: 18
        antialiasing: true
    }

    Rectangle {
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        // Cover the rounded top corners of the base completely. This leaves
        // the silhouette square at the screen edge and round only below.
        width: parent.width
        height: 18
        visible: !root.collapsed
        color: "#000000"
    }

    SoundEffect {
        id: chargingSound
        source: Qt.resolvedUrl("../media/audio/macos_charging_sound.mp3")
        volume: 0.7
    }

    function reveal(nextMode) {
        dashboardOpen = false
        hovering = false
        ignoreHoverUntilExit = true
        mode = nextMode
        resetTimer.restart()
    }

    function hoverEntered() {
        if (ignoreHoverUntilExit)
            return
        hoverExitTimer.stop()
        hovering = true
    }

    function hoverExited() {
        ignoreHoverUntilExit = false
        if (!dashboardOpen)
            hoverExitTimer.restart()
    }

    Timer {
        id: hoverExitTimer
        interval: 350
        onTriggered: {
            if (!root.dashboardOpen)
                root.hovering = false
        }
    }

    // Follows both the default output device and its volume/mute state.
    property var audioSink: Pipewire.defaultAudioSink
    property var audio: audioSink ? audioSink.audio : null

    // Default PipeWire nodes are deliberately lightweight until bound. Binding
    // the sink is required before its audio volume/mute properties can update.
    PwObjectTracker {
        objects: root.audioSink ? [root.audioSink] : []
    }

    function syncAudio(revealChange) {
        if (!audio)
            return

        volume = audio.volume
        muted = audio.muted
        if (revealChange)
            reveal("volume")
    }

    onAudioChanged: syncAudio(false)

    Connections {
        target: root.audio
        // PwNodeAudio's scalar `volume` property is backed by per-channel
        // volumes, so its notify signal is `volumesChanged`.
        function onVolumesChanged() { root.syncAudio(true) }
        function onMutedChanged() { root.syncAudio(true) }
    }

    Component.onCompleted: syncAudio(false)

    // UPower reliably reports the AC adapter transition even on systems where
    // its display-device percentage is a placeholder. Sysfs below remains the
    // authoritative source for the actual percentage.
    Connections {
        target: UPower
        function onOnBatteryChanged() {
            // Only play on the unplugged -> connected transition, never on
            // initial config loading or while disconnecting.
            if (root.lastOnBattery && !UPower.onBattery)
                chargingSound.play()
            root.lastOnBattery = UPower.onBattery
            root.reveal("battery")
        }
    }

    // UPower's display device can be a placeholder on some machines. Kernel
    // power_supply values are the source used by the battery driver itself.
    Process {
        running: true
        command: ["sh", "-c", "for b in /sys/class/power_supply/BAT* /sys/class/power_supply/*; do if [ -d \"$b\" ] && [ \"$(cat \"$b/type\" 2>/dev/null)\" = Battery ] && [ \"$(cat \"$b/scope\" 2>/dev/null)\" != Device ] && [ -r \"$b/capacity\" ] && [ -r \"$b/status\" ]; then report() { printf '%s:%s\\n' \"$(cat \"$b/capacity\")\" \"$(cat \"$b/status\")\"; }; report; while inotifywait -qq -e modify,close_write,attrib \"$b/capacity\" \"$b/status\"; do report; done; exit; fi; done"]

        stdout: SplitParser {
            onRead: function(data) {
                const parts = data.trim().split(":")
                const percentage = parseInt(parts[0])
                if (isNaN(percentage) || parts.length < 2)
                    return

                const changed = root.batteryReady
                    && (root.batteryPercentage !== percentage || root.batteryStatus !== parts[1])
                root.batteryPercentage = percentage
                root.batteryStatus = parts[1]
                root.batteryReady = true
                if (changed)
                    root.reveal("battery")
            }
        }
    }

    // Pick the available kernel backlight instead of assuming an AMD device.
    // The first two lines are current/max brightness; later lines are updates.
    Process {
        running: true
        command: ["sh", "-c", "for b in /sys/class/backlight/*; do if [ -r \"$b/brightness\" ] && [ -r \"$b/max_brightness\" ]; then cat \"$b/brightness\" \"$b/max_brightness\"; while inotifywait -qq -e modify \"$b/brightness\"; do cat \"$b/brightness\"; done; exit; fi; done"]

        stdout: SplitParser {
            onRead: function(data) {
                const value = parseInt(data)
                if (isNaN(value))
                    return

                if (!root.brightnessReady) {
                    if (root.brightnessReads === 0) {
                        root.brightness = value
                        root.brightnessReads = 1
                    } else {
                        root.maxBrightness = Math.max(1, value)
                        root.brightnessReady = true
                    }
                    return
                }

                if (root.brightness !== value) {
                    root.brightness = value
                    root.reveal("brightness")
                }
            }
        }
    }

    Row {
        id: clockContent
        anchors.centerIn: parent
        visible: !root.dashboardOpen && !root.collapsed
        opacity: root.showingOsd ? 0 : 1
        scale: root.showingOsd ? 0.95 : 1.0
        spacing: 7

        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        Item {
            width: root.musicPlaying ? 13 : 0
            height: 16
            visible: width > 0
            clip: true

            Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Repeater {
                model: 3
                Rectangle {
                    required property int index
                    x: index * 5
                    width: 3
                    height: 5 + index * 2
                    anchors.bottom: parent.bottom
                    radius: 1.5
                    color: "#89b4fa"
                    antialiasing: true

                    SequentialAnimation on height {
                        running: root.musicPlaying
                        loops: Animation.Infinite
                        PauseAnimation { duration: index * 80 }
                        NumberAnimation { to: 15 - index * 2; duration: 310; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 4 + index * 2; duration: 330; easing.type: Easing.InOutSine }
                    }
                }
            }
        }

        Text {
            id: clock
            color: "#cdd6f4"
            font.pixelSize: 16
            font.bold: true
            text: Qt.formatTime(new Date(), "HH:mm")

            Timer {
                interval: 1000
                running: !root.showingOsd
                repeat: true
                onTriggered: clock.text = Qt.formatTime(new Date(), "HH:mm")
            }
        }

    }

    // Any compact-notch click opens the dashboard. It is an overlay, so it
    // cannot affect the Row's size or push the clock out of alignment.
    MouseArea {
        anchors.fill: parent
        visible: !root.dashboardOpen && !root.collapsed && !root.showingOsd
        cursorShape: Qt.PointingHandCursor
        onClicked: root.dashboardOpen = !root.dashboardOpen
    }

    RowLayout {
        id: osdContent
        anchors.centerIn: parent
        visible: !root.dashboardOpen && root.showingOsd
        spacing: 12
        opacity: root.showingOsd ? 1 : 0
        scale: root.showingOsd ? 1.0 : 0.95

        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Behavior on scale {
            NumberAnimation {
                duration: 220
                easing.type: Easing.OutBack
                easing.overshoot: 1.1
            }
        }

        Text {
            color: root.mode === "battery" ? (root.charging ? "#a6e3a1" : root.batteryColor) : "#cdd6f4"
            font.family: "monospace"
            font.pixelSize: 20
            text: {
                if (root.mode === "brightness") return "󰃠"
                if (root.mode === "battery") {
                    if (root.batteryPercentage <= 10) return ""
                    if (root.batteryPercentage <= 30) return ""
                    if (root.batteryPercentage <= 60) return ""
                    if (root.batteryPercentage <= 85) return ""
                    return ""
                }
                if (root.muted) return "󰖁"
                if (root.volume > 0.6) return "󰕾"
                if (root.volume > 0.3) return "󰖀"
                return "󰕿"
            }
        }

        Text {
            visible: root.mode === "battery"
            Layout.preferredWidth: visible ? implicitWidth : 0
            color: root.charging ? "#a6e3a1" : root.batteryColor
            font.pixelSize: 14
            font.bold: true
            text: root.charging ? "Charging" : "Disconnected"
        }

        Rectangle {
            id: track
            Layout.preferredWidth: 108
            Layout.preferredHeight: 6
            radius: height / 2
            color: "#313244"
            clip: true

            Rectangle {
                width: parent.width * root.level
                height: parent.height
                radius: parent.radius
                color: root.mode === "brightness" ? "#f9e2af" : root.mode === "battery" ? (root.charging ? "#a6e3a1" : root.batteryColor) : "#89b4fa"

                Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
                Behavior on color { ColorAnimation { duration: 220; easing.type: Easing.InOutCubic } }
            }
        }

        Text {
            Layout.minimumWidth: 38
            horizontalAlignment: Text.AlignRight
            color: "#cdd6f4"
            font.pixelSize: 14
            text: Math.round(root.level * 100) + "%"
        }
    }

    Column {
        id: dashboard
        anchors.fill: parent
        anchors.margins: 24
        visible: root.dashboardOpen
        spacing: 14

        Row {
            width: parent.width

            Column {
                spacing: 2
                Text {
                    color: "#cdd6f4"
                    font.pixelSize: 38
                    font.bold: true
                    text: Qt.formatTime(new Date(), "HH:mm")
                }
                Text {
                    color: "#a6adc8"
                    font.pixelSize: 14
                    text: Qt.formatDate(new Date(), "dddd, d MMMM")
                }
            }

            Item { width: parent.width - 190; height: 1 }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                color: "#a6adc8"
                font.pixelSize: 22
                text: "×"

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -10
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.dashboardOpen = false
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: "#313244"
        }

        Text {
            color: "#89b4fa"
            font.pixelSize: 12
            font.bold: true
            text: root.musicPlaying ? "NOW PLAYING" : "MEDIA"
        }

        Text {
            width: parent.width
            color: "#cdd6f4"
            font.pixelSize: 22
            font.bold: true
            elide: Text.ElideRight
            text: root.activePlayer && root.activePlayer.trackTitle ? root.activePlayer.trackTitle : "Nothing playing"
        }

        Text {
            width: parent.width
            color: "#a6adc8"
            font.pixelSize: 15
            elide: Text.ElideRight
            text: root.activePlayer && root.activePlayer.trackArtist ? root.activePlayer.trackArtist : "Choose something to play"
        }

        Item { width: 1; height: 8 }

        Row {
            spacing: 26
            Text { color: "#cdd6f4"; font.pixelSize: 14; text: "󰕾  " + Math.round(root.volume * 100) + "%" }
            Text { color: root.charging ? "#a6e3a1" : root.batteryColor; font.pixelSize: 14; text: "  " + Math.round(root.batteryPercentage) + "%" }
            Text { color: "#a6adc8"; font.pixelSize: 14; text: root.musicPlaying ? "Playing" : "Paused" }
        }
    }

    property real level: {
        if (mode === "brightness")
            return Math.max(0, Math.min(1, brightness / maxBrightness))
        if (mode === "battery")
            return Math.max(0, Math.min(1, batteryPercentage / 100))
        return muted ? 0 : Math.max(0, Math.min(1, volume))
    }

    property color batteryColor: {
        if (batteryPercentage <= 15) return "#f38ba8"
        if (batteryPercentage <= 40) return "#f9e2af"
        return "#a6e3a1"
    }

    onShowingOsdChanged: {
        if (!showingOsd)
            clock.text = Qt.formatTime(new Date(), "HH:mm")
    }
}
