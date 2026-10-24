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
    Layout.alignment: Qt.AlignVCenter
    Layout.preferredWidth: implicitWidth
    spacing: 3

    property bool micActive: false
    property bool cameraActive: false
    property bool screenshareActive: false
    property bool screenRecordingActive: false
    property bool v4l2CameraActive: false
    property bool pipewireCameraActive: false

    IpcHandler {
        target: "statusdevices"
        function setRecording(active: bool) {
            root.screenRecordingActive = !!active
        }
    }

    FileView {
        id: recStateFile
        path: "/tmp/qs_recording.json"
        watchChanges: true
        onFileChanged: root.checkRecordingState()
        onLoadedChanged: root.checkRecordingState()
    }

    function checkRecordingState() {
        try {
            const txt = recStateFile.text()
            if (txt && txt.trim().length > 0) {
                const data = JSON.parse(txt.trim())
                root.screenRecordingActive = !!data.isRecording
                return
            }
        } catch (e) {}
        root.screenRecordingActive = false
    }

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

    Component.onCompleted: {
        root.refreshSourceAudio()
        root.checkRecordingState()
    }

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
        let pwCamera = false
        let screen = false

        // 1. Identify portal screencast provider nodes
        let hasPortalSource = false
        const portalIds = []
        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i]
            if (!n) continue
            const p = n.properties || {}
            const mediaClass = p["media.class"] || ""
            const nodeName = (n.name || p["node.name"] || "").toLowerCase()
            if (mediaClass === "Video/Source" && /xdph|portal|hyprland|screencast/i.test(nodeName)) {
                hasPortalSource = true
                portalIds.push(n.id)
            }
        }

        // 2. Identify mic and video streams
        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i]
            if (!n) continue
            const p = n.properties || {}
            const mediaClass = p["media.class"] || ""
            const nodeName = (n.name || p["node.name"] || "").toLowerCase()
            const appName = (p["application.name"] || "").toLowerCase()
            const mediaName = (p["media.name"] || "").toLowerCase()
            const target = p["node.target"] || p["target.node"] || null

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
                // Ignore quickshell preview stream
                if (nodeName.includes("quickshell") || appName.includes("quickshell")) {
                    continue
                }

                const isPortalStream = /xdph|portal|hyprland|screencast/i.test(nodeName) ||
                                       /xdph|portal|hyprland|screencast/i.test(appName) ||
                                       mediaName.includes("screencast") ||
                                       mediaName.includes("webrtc-consume-stream") ||
                                       (target && portalIds.includes(parseInt(target)))

                if (isPortalStream || hasPortalSource) {
                    screen = true
                } else {
                    pwCamera = true
                }
            } else if (mediaClass === "Video/Source") {
                const isPortal = /xdph|portal|hyprland|screencast/i.test(nodeName)
                if (isPortal) {
                    screen = true
                }
            }
        }

        root.micActive = mic
        root.pipewireCameraActive = pwCamera
        root.cameraActive = pwCamera
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
    // INLINE BADGES — permanent items shown/hidden via `visible`
    // Avoids Repeater re-creation and collapseTimer resets on state change.
    // ──────────────────────────────────────────────────────────────────────

    // ── Shared badge behaviour component ──────────────────────────────────
    component DeviceBadge: Rectangle {
        id: badge
        Layout.alignment: Qt.AlignVCenter
        required property string deviceType
        required property color badgeBaseColor
        property string badgeIconText: ""
        property bool isMicBadge: deviceType === "mic"
        property bool isRecBadge: deviceType === "record"
        property bool muted: isMicBadge && root.srcAudio ? root.srcAudio.muted : false

        property bool expanded: true

        implicitWidth: expanded ? 24 : 8
        implicitHeight: expanded ? 22 : 8
        radius: expanded ? 6 : width / 2
        color: isMicBadge ? (muted ? "#cc241d" : "#ffff00") : badgeBaseColor
        scale: 1.0

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
            anchors.centerIn: parent
            font.family: "JetBrainsMono NFP"
            font.pixelSize: 17
            font.bold: true
            color: badge.isMicBadge ? (badge.muted ? "#ffffff" : "#11111b") : "#11111b"
            text: (badge.isMicBadge && badge.muted) ? "󰍭" : badge.badgeIconText
            visible: !badge.isRecBadge && (badge.expanded || opacity > 0.0)
            opacity: badge.expanded ? 1.0 : 0.0
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            Behavior on opacity {
                NumberAnimation { duration: 140; easing.type: Easing.OutQuad }
            }
        }

        // Authentic macOS Screen Recording Vector Icon (Outer ring + solid dot)
        Item {
            anchors.centerIn: parent
            width: 14
            height: 14
            visible: badge.isRecBadge && (badge.expanded || opacity > 0.0)
            opacity: badge.expanded ? 1.0 : 0.0
            Behavior on opacity {
                NumberAnimation { duration: 140; easing.type: Easing.OutQuad }
            }

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "transparent"
                border.color: "#ffffff"
                border.width: 1.8
            }

            Rectangle {
                width: 6
                height: 6
                radius: width / 2
                anchors.centerIn: parent
                color: "#ffffff"
            }
        }

        Timer {
            id: collapseTimer
            interval: 5000
            repeat: false
            onTriggered: badge.expanded = false
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onEntered: { badge.expanded = true; collapseTimer.stop() }
            onExited: { collapseTimer.restart() }
            onClicked: function(mouse) {
                const cx = badge.mapToGlobal(badge.width / 2, 0).x
                if (badge.deviceType === "mic") {
                    if (mouse.button === Qt.LeftButton) {
                        if (root.srcAudio) root.srcAudio.muted = !root.srcAudio.muted
                    } else if (mouse.button === Qt.RightButton) {
                        root.toggleDropdown(0, cx)
                    }
                } else if (badge.deviceType === "camera") {
                    if (mouse.button === Qt.LeftButton) root.toggleDropdown(1, cx)
                } else if (badge.deviceType === "screenshare") {
                    if (mouse.button === Qt.LeftButton) root.toggleDropdown(2, cx)
                } else if (badge.deviceType === "record") {
                    if (mouse.button === Qt.LeftButton) {
                        Quickshell.execDetached(["quickshell", "ipc", "call", "screenrecord", "open"])
                    }
                }
            }
            onWheel: function(wheel) {
                if (badge.isMicBadge && root.srcAudio) root.srcAudio.muted = !root.srcAudio.muted
            }
        }

        onVisibleChanged: {
            if (visible) {
                expanded = true
                collapseTimer.restart()
            }
        }
    }

    // ── Mic Badge ─────────────────────────────────────────────────────────
    DeviceBadge {
        visible: root.micActive
        deviceType: "mic"
        badgeBaseColor: "#ffff00"
        badgeIconText: "󰍬"
        muted: root.srcAudio ? root.srcAudio.muted : false
    }

    // ── Camera Badge ──────────────────────────────────────────────────────
    DeviceBadge {
        visible: root.cameraActive
        deviceType: "camera"
        badgeBaseColor: "#66ff00"
        badgeIconText: "󰄀"
    }

    // ── Screenshare Badge ─────────────────────────────────────────────────
    DeviceBadge {
        visible: root.screenshareActive
        deviceType: "screenshare"
        badgeBaseColor: "#9d00ff"
        badgeIconText: "󰍹"
    }

    // ── Screen Recording Badge (4th Dot - Vibrant Red, macOS Icon) ────────
    DeviceBadge {
        visible: root.screenRecordingActive
        deviceType: "record"
        badgeBaseColor: "#ff3b30"
    }
}
