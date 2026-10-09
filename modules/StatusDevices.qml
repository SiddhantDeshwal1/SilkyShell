import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Mic / camera / screenshare status badges.
// Mirrors waybar custom/mic, custom/camera, custom/screenshare modules.
// Polls status_device.sh every second using exit code via onExited signal.
//
// Badge interactions:
//   Mic:     left click → mute / unmute mic;  right click → DeviceDropdown (MIC tab)
//   Camera:  left click → DeviceDropdown (CAMERA tab)
//   Screen:  left click → DeviceDropdown (SCREEN tab)
//
// Collapse/expand feature:
//   - Badges start expanded (36px wide) with full icon
//   - After 5s of no hover, collapse to 12px colored dot
//   - Hover expands immediately, cancels collapse timer
//   - Hover leave restarts 5s collapse timer
//   - Mic collapsed dot: always yellow; expanded: red if muted, yellow if active
//   - Camera/screen collapsed: their theme colors; expanded: same
//
// Repeater-based: only active badges are instantiated → no gaps when hidden
RowLayout {
    id: root
    Layout.fillHeight: true
    spacing: 3

    property bool micActive: false
    property bool cameraActive: false
    property bool screenshareActive: false

    // Pipewire default audio source for live mute state & scroll toggling.
    // Assigned imperatively (not bound) so the reference survives default-source
    // switches: a plain binding on `Pipewire.defaultAudioSource.audio` was seen
    // to go stale and leave mute toggles writing to a dead object.
    property var srcAudio: null

    function refreshSourceAudio() {
        const src = Pipewire.defaultAudioSource
        root.srcAudio = (src && src.audio) ? src.audio : null
    }

    Connections {
        target: Pipewire
        function onDefaultAudioSourceChanged() { root.refreshSourceAudio() }
    }

    Component.onCompleted: root.refreshSourceAudio()

    PwObjectTracker {
        objects: Pipewire.defaultAudioSource ? [Pipewire.defaultAudioSource] : []
    }

    // Auto-close dropdown when no devices are active
    function checkAutoClose() {
        if (!micActive && !cameraActive && !screenshareActive && deviceDropdown.open) {
            deviceDropdown.close()
        }
    }

    onMicActiveChanged: checkAutoClose()
    onCameraActiveChanged: checkAutoClose()
    onScreenshareActiveChanged: checkAutoClose()

    // Opens the dropdown on the given tab (0=mic, 1=camera, 2=screen),
    // or closes it if it is already open on that same tab.
    function toggleDropdown(tabIndex, centerX) {
        if (deviceDropdown.open && deviceDropdown.activeTab === tabIndex) {
            deviceDropdown.close()
        } else {
            deviceDropdown.openAt(centerX, tabIndex)
        }
    }

    // ── Native PipeWire Device Tracking (Zero Shell Overhead) ─────────
    PwObjectTracker {
        objects: Pipewire.nodes.values
    }

    function updateDeviceStatuses() {
        const nodes = Pipewire.nodes.values || []
        let mic = false
        let camera = false
        let screen = false

        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i]
            if (!n) continue
            const p = n.properties || {}
            const mediaClass = p["media.class"] || ""
            const nodeName = (n.name || p["node.name"] || "").toLowerCase()
            const appName = (p["application.name"] || "").toLowerCase()

            // 1. Mic: Stream/Input/Audio excluding cava, quickshell, qs
            if (mediaClass === "Stream/Input/Audio" || (n.isStream && !n.isSink && n.audio !== null)) {
                if (!nodeName.includes("cava") && !appName.includes("cava") &&
                    !nodeName.includes("quickshell") && !appName.includes("quickshell") &&
                    !nodeName.includes("qs") && !appName.includes("qs")) {
                    mic = true
                }
            }

            // 2. Video streams (Camera or Screen share)
            if (mediaClass.indexOf("Stream/") === 0 && mediaClass.indexOf("Video") !== -1) {
                const isPortal = /xdph|portal|hyprland|screencast/i.test(nodeName) || /xdph|portal|hyprland|screencast/i.test(appName)
                if (isPortal) {
                    screen = true
                } else {
                    camera = true
                }
            } else if (mediaClass === "Video/Source") {
                const isPortal = /xdph|portal|hyprland|screencast/i.test(nodeName)
                if (isPortal && (n.state === "running" || n.state === 3)) {
                    screen = true
                }
            }
        }

        root.micActive = mic
        root.cameraActive = camera
        root.screenshareActive = screen
    }

    Connections {
        target: Pipewire.nodes
        function onValuesChanged() { root.updateDeviceStatuses() }
    }

    // Passive low-frequency fallback refresh (5 seconds, pure JS in-memory check)
    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.updateDeviceStatuses()
    }

    // Floating rich device settings panel (mic / camera / screen tabs).
    DeviceDropdown {
        id: deviceDropdown
    }

    // ──────────────────────────────────────────────────────────────────────
    // BADGE MODEL — computed array of active badges (no gaps in layout)
    // ──────────────────────────────────────────────────────────────────────
    property var badgeModel: {
        const arr = []
        if (root.micActive) {
            arr.push({
                type: "mic",
                baseColor: "#ffff00",
                iconText: "󰍬"
            })
        }
        if (root.cameraActive) {
            arr.push({
                type: "camera",
                baseColor: "#66ff00",
                iconText: "󰄀"
            })
        }
        if (root.screenshareActive) {
            arr.push({
                type: "screenshare",
                baseColor: "#9d00ff",
                iconText: "󰍹"
            })
        }
        return arr
    }

    // ──────────────────────────────────────────────────────────────────────
    // REUSABLE BADGE COMPONENT
    // ──────────────────────────────────────────────────────────────────────
    Component {
        id: badgeComponent

        Rectangle {
            id: badge
            property bool expanded: true
            property bool isMic: false
            property string deviceType: ""
            property bool muted: isMic && root.srcAudio ? root.srcAudio.muted : false
            property color baseColor: "#ffff00"
            property string iconText: "󰍬"

            implicitWidth: expanded ? 24 : 8
            implicitHeight: expanded ? 22 : 8
            radius: expanded ? 6 : width / 2
            color: isMic ? (muted ? "#cc241d" : "#ffff00") : baseColor

            scale: expanded ? 1.0 : 0.88

            Behavior on scale {
                NumberAnimation {
                    duration: expanded ? 200 : 150
                    easing.type: expanded ? Easing.OutBack : Easing.InCubic
                    easing.overshoot: 1.1
                }
            }
            Behavior on implicitWidth {
                NumberAnimation {
                    duration: expanded ? 200 : 150
                    easing.type: expanded ? Easing.OutBack : Easing.InCubic
                    easing.overshoot: 1.08
                }
            }
            Behavior on implicitHeight {
                NumberAnimation {
                    duration: expanded ? 200 : 150
                    easing.type: expanded ? Easing.OutBack : Easing.InCubic
                    easing.overshoot: 1.08
                }
            }
            Behavior on radius {
                NumberAnimation { duration: expanded ? 180 : 150; easing.type: Easing.OutCubic }
            }
            Behavior on color {
                ColorAnimation { duration: 150; easing.type: Easing.InOutCubic }
            }

            Text {
                id: badgeIcon
                anchors.centerIn: parent
                font.family: "JetBrainsMono NFP"
                font.pixelSize: 17
                font.bold: true
                color: isMic ? (badge.muted ? "#ffffff" : "#11111b") : "#11111b"
                // Only show glyph when expanded — collapsed dot is pure solid dot without text overflow
                text: (isMic && badge.muted) ? "󰍭" : iconText
                visible: badge.expanded
                opacity: badge.expanded ? 1.0 : 0.0
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                Behavior on opacity {
                    NumberAnimation { duration: 140; easing.type: Easing.OutQuad }
                }
            }

            Timer {
                id: collapseTimer
                interval: 5000
                repeat: false
                onTriggered: { expanded = false }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onEntered: { expanded = true; collapseTimer.stop() }
                onExited: { collapseTimer.restart() }
                onClicked: function(mouse) {
                    const cx = badge.mapToGlobal(badge.width / 2, 0).x
                    if (deviceType === "mic") {
                        if (mouse.button === Qt.LeftButton) {
                            if (root.srcAudio) root.srcAudio.muted = !root.srcAudio.muted
                        } else if (mouse.button === Qt.RightButton) {
                            root.toggleDropdown(0, cx)
                        }
                    } else if (deviceType === "camera") {
                        if (mouse.button === Qt.LeftButton) root.toggleDropdown(1, cx)
                    } else if (deviceType === "screenshare") {
                        if (mouse.button === Qt.LeftButton) root.toggleDropdown(2, cx)
                    }
                }
                onWheel: function(wheel) {
                    if (isMic && root.srcAudio) root.srcAudio.muted = !root.srcAudio.muted
                }
            }

            Component.onCompleted: {
                collapseTimer.restart()
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // REPEATER — only creates badges for active devices (no gaps)
    // ──────────────────────────────────────────────────────────────────────
    Repeater {
        model: root.badgeModel

        delegate: Loader {
            sourceComponent: badgeComponent
            onStatusChanged: if (status === Loader.Ready) {
                item.isMic = (modelData.type === "mic")
                item.deviceType = modelData.type
                item.baseColor = modelData.baseColor
                item.iconText = modelData.iconText
                if (modelData.type === "mic" && root.srcAudio) {
                    item.muted = root.srcAudio.muted
                }
            }
            // Bind mic mute state to Pipewire
            Connections {
                target: root.srcAudio
                function onMutedChanged() { if (item && modelData.type === "mic") item.muted = root.srcAudio.muted }
                function onVolumesChanged() { if (item && modelData.type === "mic") item.muted = root.srcAudio.muted }
            }
        }
    }
}
