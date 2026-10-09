import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Qt5Compat.GraphicalEffects
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire

// ─────────────────────────────────────────────────────────────────────────────
// DeviceDropdown — Floating overlay panel for input-device settings.
//
// Anchored to the bar (top of screen). The card expands downward directly
// below the clicked status badge, centered on it.
//
// Tabs:
//   0  MIC     — source selector, 16-segment level meter, volume, app mutes
//   1  CAMERA  — device selector, apps using camera (with stop buttons)
//   2  SCREEN  — active screen shares (with stop buttons)
//
// Camera/screen stream teardown is done via `pw-cli destroy <node-id>`;
// camera default selection via `wpctl set-default <node-id>` (Quickshell
// only exposes preferredDefault *Audio* Source, not video).
//
// Bug fixes applied (from MicDropdown):
//   - Backdrop uses a containment-aware MouseArea; card contents sit above it.
//   - PwNodePeakMonitor: node must be tracked (PwObjectTracker) and the monitor
//     enabled. It stays enabled while the window is open so the meter reacts
//     immediately on open.
// ─────────────────────────────────────────────────────────────────────────────
PanelWindow {
    id: root

    // _cardX is the computed left-edge X of the card in screen coordinates.
    // It is set imperatively via openAt() at click time — never as a binding —
    // so it is always based on the badge's real laid-out position.
    property real _cardX: 0

    property bool open: false

    // 0 = mic, 1 = camera, 2 = screen
    property int activeTab: 0

    anchors {
        top: true
        left: true
        right: true
    }

    // Flush below top bar (28px)
    WlrLayershell.margins.top: 28

    // Height covers the screen below the bar so backdrop intercepts clicks
    implicitHeight: Screen.height - 28

    color: "transparent"

    // -1 = pure overlay: compositor must not adjust struts or reserved zones.
    // This is the direct fix for windows shifting upward on open.
    exclusiveZone: -1

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-device-dropdown"
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    property int defaultCameraNodeId: 0

    Process {
        id: camDefaultProc
        command: ["sh", "-c", "wpctl inspect @DEFAULT_VIDEO_SOURCE@ 2>/dev/null | head -n 1 | awk '{print $2}' | tr -d ','"]
        stdout: SplitParser {
            onRead: function(data) {
                const val = parseInt(data.trim())
                if (!isNaN(val) && val > 0) root.defaultCameraNodeId = val
            }
        }
    }

    onActiveTabChanged: {
        if (activeTab === 1) camDefaultProc.running = true
    }

    // Called by StatusDevices at click time with the badge's screen-space
    // center X and the tab to open. Computing position here (not as a binding)
    // guarantees the bar layout is fully settled before we read the coordinate.
    function openAt(centerX, tabIndex) {
        if (tabIndex !== undefined) root.activeTab = tabIndex
        let cx = centerX - 360 / 2
        const maxX = Screen.width - 360 - 16
        if (cx < 16) cx = 16
        else if (cx > maxX) cx = maxX
        _cardX = cx
        open = true
        if (root.activeTab === 1) camDefaultProc.running = true
    }

    function close() {
        open = false
    }

    // Keep the window alive during the close animation
    visible: open || panelCard.opacity > 0

    // ── Pipewire object tracking ──────────────────────────────────────
    // Only track nodes while the dropdown is open. When closed, we release
    // all node references so quickshell doesn't hold Pipewire links.
    PwObjectTracker {
        id: pwTracker
        objects: root.open ? Pipewire.nodes.values : []
    }

    // Peak monitor — only enabled while the dropdown is open.
    // Disabling it when closed ensures quickshell does not hold an active
    // capture link on the mic node when the user isn't looking at the panel.
    PwNodePeakMonitor {
        id: micPeak
        node: Pipewire.defaultAudioSource
        enabled: root.open
    }

    // One-shot command runner for wpctl / pw-cli actions.
    Process {
        id: cmdProc
    }

    function runCmd(argv) {
        cmdProc.command = argv
        cmdProc.running = true
    }

    // ── Node filters ──────────────────────────────────────────────────
    function mediaClass(n) {
        return (n.properties && n.properties["media.class"]) || ""
    }

    function getHardwareSources() {
        return Pipewire.nodes.values.filter(function(n) {
            return !n.isStream && !n.isSink && n.audio !== null
        })
    }

    function getRecordingApps() {
        return Pipewire.nodes.values.filter(function(n) {
            return n.isStream && !n.isSink && n.audio !== null && n.name !== "cava"
        })
    }

    function getCameraDevices() {
        return Pipewire.nodes.values.filter(function(n) {
            const cls = mediaClass(n)
            return cls === "Video/Device" ||
                   (cls === "Video/Source" && n.properties["media.role"] === "Camera")
        })
    }

    // Video *consumer* stream nodes — the app actually using the camera or
    // screen. Matches Stream/*Video* (mirrors getRecordingApps for audio).
    // This automatically excludes the v4l2 camera device (Video/Source) and
    // the portal's screen-share source node (Video/Source).
    function getVideoAppStreams() {
        return Pipewire.nodes.values.filter(function(n) {
            const cls = mediaClass(n)
            return cls.indexOf("Stream/") === 0 && cls.indexOf("Video") !== -1
        })
    }

    // Display-name fallback for video stream nodes, since many omit
    // application.name (mirrors the audio "apps using mic" row).
    function videoAppName(n) {
        const p = n.properties || {}
        return p["application.name"]
            || p["media.name"]
            || n.description
            || n.nickname
            || n.name
            || "App"
    }

    // The portal's screen-share provider node (Video/Source). Used only as a
    // fallback so the SCREEN tab isn't blank for apps that read the portal fd
    // without creating their own consumer stream node.
    function getPortalScreenSource() {
        const re = /xdph|portal|hyprland/i
        return Pipewire.nodes.values.filter(function(n) {
            return mediaClass(n) === "Video/Source" && re.test(n.name || "")
        })
    }

    function getCameraApps() {
        return root.getVideoAppStreams()
    }

    function getScreenShares() {
        const consumers = root.getVideoAppStreams()
        if (consumers.length > 0) return consumers
        return root.getPortalScreenSource()
    }

    // ── Backdrop: clicking outside the card closes the dropdown ───────
    // This sits behind the card (z=0) and only responds to clicks that land
    // outside the card area — the card itself has a higher z so it gets the
    // events first.
    MouseArea {
        anchors.fill: parent
        z: 0
        acceptedButtons: Qt.AllButtons
        focus: root.open

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
            }
        }

        onClicked: root.close()
    }

    // ── Pure Liquid Glass Panel Card ──────────────────────────────────
    Rectangle {
        id: panelCard
        y: 0
        x: root._cardX

        width: 360
        implicitHeight: contentCol.implicitHeight + 24
        topLeftRadius: 0
        topRightRadius: 0
        bottomLeftRadius: 18
        bottomRightRadius: 18

        // 1. Pure Neutral Liquid Glass Tint
        color: Theme.panelBgColor
        border.color: Theme.panelBorderColor
        border.width: 1.5
        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on border.color { ColorAnimation { duration: 200 } }
        clip: false
        z: 1   // above backdrop MouseArea

        opacity: root.open ? 1.0 : 0.0
        scale: root.open ? 1.0 : 0.94
        transformOrigin: Item.Top

        Behavior on opacity {
            NumberAnimation {
                duration: root.open ? 200 : 150
                easing.type: root.open ? Easing.OutQuad : Easing.InQuad
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: root.open ? 220 : 150
                easing.type: root.open ? Easing.OutBack : Easing.InCubic
                easing.overshoot: 1.1
            }
        }

        // ── Left Outward (Concave) Border Radius ──────────────────────
        Shape {
            anchors.right: parent.left
            anchors.top: parent.top
            width: 16
            height: 16
            layer.enabled: true
            layer.samples: 4
            z: 2

            ShapePath {
                strokeColor: "#47ffffff"
                strokeWidth: 1.5
                fillColor: "#8c121212"
                startX: 0
                startY: 0
                PathLine { x: 16; y: 0 }
                PathLine { x: 16; y: 16 }
                PathArc {
                    x: 0
                    y: 0
                    radiusX: 16
                    radiusY: 16
                    direction: PathArc.Counterclockwise
                }
            }
        }

        // ── Right Outward (Concave) Border Radius ─────────────────────
        Shape {
            anchors.left: parent.right
            anchors.top: parent.top
            width: 16
            height: 16
            layer.enabled: true
            layer.samples: 4
            z: 2

            ShapePath {
                strokeColor: "#47ffffff"
                strokeWidth: 1.5
                fillColor: "#8c121212"
                startX: 16
                startY: 0
                PathLine { x: 0; y: 0 }
                PathLine { x: 0; y: 16 }
                PathArc {
                    x: 16
                    y: 0
                    radiusX: 16
                    radiusY: 16
                    direction: PathArc.Clockwise
                }
            }
        }

        // 2. Liquid Glass Top Specular Shine
        Rectangle {
            anchors.fill: parent
            topLeftRadius: 0
            topRightRadius: 0
            bottomLeftRadius: 18
            bottomRightRadius: 18
            z: 0
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#2effffff" }
                GradientStop { position: 0.35; color: "#0dffffff" }
                GradientStop { position: 1.0; color: "#00ffffff" }
            }
        }

        // 3. Liquid Glass Inner Specular Rim Highlight
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            topLeftRadius: 0
            topRightRadius: 0
            bottomLeftRadius: 17
            bottomRightRadius: 17
            z: 0
            color: "transparent"
            border.color: "#26ffffff"
            border.width: 1
        }

        ColumnLayout {
            id: contentCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 12
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            anchors.bottomMargin: 12
            spacing: 12
            z: 3

            // ── TAB BAR ───────────────────────────────────────────────
            Item {
                Layout.fillWidth: true
                implicitHeight: 34

                RowLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: 32
                    spacing: 0

                    Repeater {
                        model: ["MIC", "CAMERA", "SCREEN"]

                        delegate: Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            Text {
                                anchors.centerIn: parent
                                text: modelData
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 13
                                font.bold: true
                                color: root.activeTab === index ? "#89b4fa" : "#a6adc8"
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.activeTab = index
                            }
                        }
                    }
                }

                // Baseline
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: "#2effffff"
                }

                // Sliding underline indicator
                Rectangle {
                    anchors.bottom: parent.bottom
                    height: 2
                    width: parent.width / 3
                    x: root.activeTab * width
                    color: "#89b4fa"

                    Behavior on x {
                        NumberAnimation {
                            duration: 220
                            easing.type: Easing.OutBack
                            easing.overshoot: 1.12
                        }
                    }
                }
            }

            // ── TAB CONTENT ───────────────────────────────────────────
            StackLayout {
                id: tabStack
                Layout.fillWidth: true
                currentIndex: root.activeTab

                // ═══════════════════════════ TAB 0: MIC ═══════════════
                ColumnLayout {
                    spacing: 12
                    opacity: StackLayout.isCurrentItem ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }

                    // ── SECTION 1: MIC INPUT ──────────────────────────
                    Text {
                        text: "MIC INPUT"
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 13
                        font.bold: true
                        color: "#89b4fa"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: root.getHardwareSources()

                            delegate: Rectangle {
                                id: srcDelegate
                                Layout.fillWidth: true
                                implicitHeight: 32
                                radius: 7

                                // Use node id comparison — modelData is the live PW node object
                                property bool isDefault: {
                                    const def = Pipewire.defaultAudioSource
                                    return def !== null && def !== undefined && def.id === modelData.id
                                }

                                color: isDefault
                                    ? "#26ffffff"
                                    : (srcMouse.containsMouse ? "#14ffffff" : "transparent")
                                border.color: isDefault
                                    ? "#47ffffff"
                                    : (srcMouse.containsMouse ? "#26ffffff" : "transparent")
                                border.width: 1

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 8

                                    // ── Mic mute toggle button ────────────────────
                                    Rectangle {
                                        implicitWidth: 24
                                        implicitHeight: 24
                                        radius: 5
                                        color: micIconMouse.containsMouse
                                            ? (modelData.audio && modelData.audio.muted ? "#cc241d" : "#1e3a2a")
                                            : "transparent"

                                        Behavior on color { ColorAnimation { duration: 120 } }

                                        Text {
                                            anchors.centerIn: parent
                                            font.family: "JetBrainsMono NFP"
                                            font.pixelSize: 15
                                            color: (modelData.audio && modelData.audio.muted)
                                                ? "#f38ba8"
                                                : (isDefault ? "#89b4fa" : "#cdd6f4")
                                            text: (modelData.audio && modelData.audio.muted) ? "󰍭" : "󰍬"
                                        }

                                        MouseArea {
                                            id: micIconMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (modelData.audio)
                                                    modelData.audio.muted = !modelData.audio.muted
                                            }
                                        }
                                    }


                                    Text {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        font.family: "JetBrainsMono NFP"
                                        font.pixelSize: 14
                                        font.bold: isDefault
                                        color: isDefault ? "#ffffff" : "#a6adc8"
                                        text: modelData.description || modelData.nickname || modelData.name || "Microphone"
                                    }

                                    Text {
                                        font.family: "JetBrainsMono NFP"
                                        font.pixelSize: 15
                                        font.bold: true
                                        color: "#89b4fa"
                                        text: "✓"
                                        visible: isDefault
                                    }
                                }

                                MouseArea {
                                    id: srcMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    // Fix: set the preferred default — Pipewire will apply it
                                    onClicked: {
                                        Pipewire.preferredDefaultAudioSource = modelData
                                    }
                                }
                            }
                        }
                    }

                    // ── DIVIDER ───────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: "#2effffff"
                    }

                    // ── SECTION 2: INPUT LEVEL ────────────────────────
                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: "INPUT LEVEL"
                            font.family: "JetBrainsMono NFP"
                            font.pixelSize: 13
                            font.bold: true
                            color: "#89b4fa"
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            font.family: "JetBrainsMono NFP"
                            font.pixelSize: 13
                            color: "#a6adc8"
                            text: Math.round(Math.max(0, Math.min(1, micPeak.peak)) * 100) + "%"
                        }
                    }

                    // 20-segment vertical-bar meter (U+2503 heavy vertical)
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Repeater {
                            model: 20

                            delegate: Text {
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 15
                                font.bold: true
                                text: "┃"
                                Layout.fillWidth: true

                                property real threshold: (index + 1) / 20
                                property bool lit: micPeak.peak >= threshold

                                // Trailing segments go red when peak exceeds 85%
                                color: !lit ? "#33ffffff"
                                     : (micPeak.peak > 0.85 && threshold > 0.85) ? "#f38ba8"
                                     : "#89b4fa"

                                Behavior on color {
                                    ColorAnimation { duration: 30; easing.type: Easing.OutExpo }
                                }
                            }
                        }
                    }

                    // ── MIC VOLUME SLIDER ─────────────────────────────
                    // Drag or scroll to set the default audio source volume (0–100%).
                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: "MIC VOLUME"
                            font.family: "JetBrainsMono NFP"
                            font.pixelSize: 13
                            font.bold: true
                            color: "#89b4fa"
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            id: volPctLabel
                            font.family: "JetBrainsMono NFP"
                            font.pixelSize: 13
                            color: "#a6adc8"
                            text: {
                                const src = Pipewire.defaultAudioSource
                                if (!src || !src.audio) return "0%"
                                return Math.round(Math.max(0, Math.min(1, src.audio.volume)) * 100) + "%"
                            }
                        }
                    }

                    // Slider track + thumb
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: 20   // tap / drag target height

                        // Track background
                        Rectangle {
                            id: volTrack
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 8
                            radius: 4
                            color: "#2effffff"
                            border.color: "#33ffffff"
                            border.width: 1
                            clip: false

                            // Filled portion
                            Rectangle {
                                id: volFill
                                height: parent.height
                                radius: parent.radius
                                color: "#a6e3a1"
                                width: {
                                    const src = Pipewire.defaultAudioSource
                                    if (!src || !src.audio) return 0
                                    return parent.width * Math.max(0, Math.min(1, src.audio.volume))
                                }
                                Behavior on width {
                                    NumberAnimation { duration: 80; easing.type: Easing.OutQuart }
                                }
                            }

                            // Thumb knob
                            Rectangle {
                                id: volThumb
                                width: 16
                                height: 16
                                radius: 8
                                color: "#ffffff"
                                anchors.verticalCenter: parent.verticalCenter
                                x: {
                                    const src = Pipewire.defaultAudioSource
                                    if (!src || !src.audio) return -8
                                    return parent.width * Math.max(0, Math.min(1, src.audio.volume)) - 8
                                }
                                Behavior on x {
                                    NumberAnimation { duration: 80; easing.type: Easing.OutQuart }
                                }
                            }
                        }

                        // Drag + scroll interaction
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            preventStealing: true

                            // Set volume from click/drag position
                            function setVolumeFromX(mouseX) {
                                const src = Pipewire.defaultAudioSource
                                if (!src || !src.audio) return
                                const v = Math.max(0, Math.min(1, mouseX / volTrack.width))
                                src.audio.volume = v
                            }

                            onPressed:      function(mouse) { setVolumeFromX(mouse.x) }
                            onPositionChanged: function(mouse) {
                                if (pressed) setVolumeFromX(mouse.x)
                            }

                            // Scroll: ±5% per tick
                            onWheel: function(wheel) {
                                const src = Pipewire.defaultAudioSource
                                if (!src || !src.audio) return
                                const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                                src.audio.volume = Math.max(0, Math.min(1, src.audio.volume + delta))
                            }
                        }
                    }

                    // ── DIVIDER ───────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: "#2effffff"
                    }

                    // ── SECTION 3: APPS USING MIC ─────────────────────
                    Text {
                        text: "APPS USING MIC"
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 13
                        font.bold: true
                        color: "#89b4fa"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        Text {
                            visible: root.getRecordingApps().length === 0
                            text: "No active apps"
                            font.family: "JetBrainsMono NFP"
                            font.pixelSize: 14
                            font.italic: true
                            color: "#555555"
                            Layout.topMargin: 2
                            Layout.bottomMargin: 2
                        }

                        Repeater {
                            model: root.getRecordingApps()

                            delegate: RowLayout {
                                Layout.fillWidth: true
                                implicitHeight: 30
                                spacing: 8

                                Text {
                                    font.family: "JetBrainsMono NFP"
                                    font.pixelSize: 15
                                    color: (modelData.audio && modelData.audio.muted) ? "#cc241d" : "#a6e3a1"
                                    text: (modelData.audio && modelData.audio.muted) ? "󰍭" : "󰍬"
                                }

                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font.family: "JetBrainsMono NFP"
                                    font.pixelSize: 14
                                    color: "#cdd6f4"
                                    text: (modelData.properties && modelData.properties["application.name"])
                                        ? modelData.properties["application.name"]
                                        : (modelData.name || "Recording App")
                                }

                                Rectangle {
                                    implicitWidth: 28
                                    implicitHeight: 22
                                    radius: 5
                                    color: (modelData.audio && modelData.audio.muted) ? "#cc241d" : "#26ffffff"
                                    border.color: "#33ffffff"
                                    border.width: 1

                                    Text {
                                        anchors.centerIn: parent
                                        font.family: "JetBrainsMono NFP"
                                        font.pixelSize: 14
                                        color: "#ffffff"
                                        text: (modelData.audio && modelData.audio.muted) ? "󰍭" : "󰍬"
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData.audio)
                                                modelData.audio.muted = !modelData.audio.muted
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── OPEN AUDIO SETTINGS ───────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        radius: 7
                        color: pavuMouse.containsMouse ? "#26ffffff" : "#14ffffff"
                        border.color: pavuMouse.containsMouse ? "#47ffffff" : "#26ffffff"
                        border.width: 1

                        Behavior on color { ColorAnimation { duration: 120 } }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 8

                            Text {
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 14
                                color: "#89b4fa"
                                text: "⚙"
                            }

                            Text {
                                Layout.fillWidth: true
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 13
                                color: "#a6adc8"
                                text: "Open Audio Settings"
                            }

                            Text {
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 13
                                color: "#89b4fa"
                                text: "󰏌"
                            }
                        }

                        MouseArea {
                            id: pavuMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.runCmd(["pavucontrol"])
                                root.close()
                            }
                        }
                    }

                    // Bottom padding spacer
                    Item { implicitHeight: 2 }
                }


                // ═════════════════════════ TAB 1: CAMERA ══════════════
                ColumnLayout {
                    spacing: 12
                    opacity: StackLayout.isCurrentItem ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }

                    // ── SECTION 1: LIVE CAMERA PREVIEW ────────────────
                    Text {
                        text: "LIVE PREVIEW"
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 13
                        font.bold: true
                        color: "#89b4fa"
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 180
                        radius: 10
                        color: "#14ffffff"
                        border.color: "#33ffffff"
                        border.width: 1
                        clip: true

                        Column {
                            anchors.centerIn: parent
                            spacing: 6
                            visible: cameraDevice.cameraDevice.id === ""
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 36
                                color: "#555577"
                                text: "󰄀"
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 13
                                color: "#8888aa"
                                text: "No preview available"
                            }
                        }

                        CaptureSession {
                            id: cameraSession
                            camera: Camera {
                                id: cameraDevice
                                active: root.open && root.activeTab === 1
                            }
                            videoOutput: camVideoOutput
                        }

                        VideoOutput {
                            id: camVideoOutput
                            anchors.fill: parent
                            visible: cameraDevice.cameraDevice.id !== ""
                            fillMode: VideoOutput.PreserveAspectFit
                        }
                    }

                    // ── DIVIDER ───────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: "#2effffff"
                    }

                    // ── SECTION 2: CAMERA INPUT ───────────────────────
                    Text {
                        text: "CAMERA INPUT"
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 13
                        font.bold: true
                        color: "#89b4fa"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        Text {
                            visible: root.getCameraDevices().length === 0
                            text: "No cameras found"
                            font.family: "JetBrainsMono NFP"
                            font.pixelSize: 14
                            font.italic: true
                            color: "#555555"
                            Layout.topMargin: 2
                            Layout.bottomMargin: 2
                        }

                        Repeater {
                            model: root.getCameraDevices()

                            delegate: Rectangle {
                                id: camDelegate
                                Layout.fillWidth: true
                                implicitHeight: 32
                                radius: 7

                                property bool isDefault: (root.defaultCameraNodeId > 0 && modelData.id === root.defaultCameraNodeId) ||
                                                         (root.defaultCameraNodeId === 0 && index === 0)

                                color: isDefault
                                    ? "#26ffffff"
                                    : (camMouse.containsMouse ? "#14ffffff" : "transparent")
                                border.color: isDefault
                                    ? "#47ffffff"
                                    : (camMouse.containsMouse ? "#26ffffff" : "transparent")
                                border.width: 1

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 8

                                    Text {
                                        font.family: "JetBrainsMono NFP"
                                        font.pixelSize: 16
                                        color: isDefault ? "#89b4fa" : "#cdd6f4"
                                        text: "󰄀"
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        font.family: "JetBrainsMono NFP"
                                        font.pixelSize: 14
                                        font.bold: isDefault
                                        color: isDefault ? "#ffffff" : "#a6adc8"
                                        text: (modelData.properties && modelData.properties["device.description"])
                                            || modelData.description
                                            || modelData.nickname
                                            || modelData.name
                                            || "Camera"
                                    }

                                    Text {
                                        font.family: "JetBrainsMono NFP"
                                        font.pixelSize: 15
                                        font.bold: true
                                        color: "#89b4fa"
                                        text: "✓"
                                        visible: isDefault
                                    }
                                }

                                MouseArea {
                                    id: camMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.defaultCameraNodeId = modelData.id
                                        root.runCmd(["wpctl", "set-default", String(modelData.id)])
                                        camDefaultProc.running = true
                                    }
                                }
                            }
                        }
                    }

                    // ── DIVIDER ───────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: "#2effffff"
                    }

                    // ── SECTION 3: APPS USING CAMERA ──────────────────
                    Text {
                        text: "APPS USING CAMERA"
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 13
                        font.bold: true
                        color: "#89b4fa"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        Text {
                            visible: root.getCameraApps().length === 0
                            text: "No active apps"
                            font.family: "JetBrainsMono NFP"
                            font.pixelSize: 14
                            font.italic: true
                            color: "#555555"
                            Layout.topMargin: 2
                            Layout.bottomMargin: 2
                        }

                        Repeater {
                            model: root.getCameraApps()

                            delegate: RowLayout {
                                Layout.fillWidth: true
                                implicitHeight: 30
                                spacing: 8

                                Text {
                                    font.family: "JetBrainsMono NFP"
                                    font.pixelSize: 15
                                    color: "#a6e3a1"
                                    text: "󰄀"
                                }

                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font.family: "JetBrainsMono NFP"
                                    font.pixelSize: 14
                                    color: "#cdd6f4"
                                    text: root.videoAppName(modelData)
                                }

                                // Stop button: destroy the consuming stream node
                                Rectangle {
                                    implicitWidth: 28
                                    implicitHeight: 22
                                    radius: 5
                                    color: camStopMouse.containsMouse ? "#cc241d" : "#26ffffff"
                                    border.color: "#33ffffff"
                                    border.width: 1

                                    Text {
                                        anchors.centerIn: parent
                                        font.family: "JetBrainsMono NFP"
                                        font.pixelSize: 14
                                        color: "#ffffff"
                                        text: "󰅖"
                                    }

                                    MouseArea {
                                        id: camStopMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runCmd(["pw-cli", "destroy", String(modelData.id)])
                                    }
                                }
                            }
                        }
                    }

                    // Bottom padding spacer
                    Item { implicitHeight: 2 }
                }

                // ═════════════════════════ TAB 2: SCREEN ══════════════
                ColumnLayout {
                    spacing: 12
                    opacity: StackLayout.isCurrentItem ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }

                    // ── SECTION 1: SCREEN PREVIEW ─────────────────────
                    Text {
                        text: "SCREEN PREVIEW"
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 13
                        font.bold: true
                        color: "#89b4fa"
                    }

                    Rectangle {
                        id: screenPreviewRect
                        Layout.fillWidth: true
                        implicitHeight: 180
                        radius: 10
                        color: "#14ffffff"
                        border.color: "#33ffffff"
                        border.width: 1
                        clip: true

                        property int refreshTick: 0

                        // Show placeholder when no active shares
                        Column {
                            anchors.centerIn: parent
                            spacing: 6
                            visible: root.getScreenShares().length === 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 36
                                color: "#555577"
                                text: "󰍹"
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                font.family: "JetBrainsMono NFP"
                                font.pixelSize: 13
                                color: "#8888aa"
                                text: "No active share"
                            }
                        }

                        Image {
                            id: screenPreviewImage
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            visible: root.getScreenShares().length > 0
                            cache: false
                            // cache-bust with refreshTick so QML reloads the image
                            source: visible ? ("file:///tmp/qs-screen-preview.png?" + screenPreviewRect.refreshTick) : ""
                        }

                        // Capture a screenshot every 2 s when tab is active + share running
                        Timer {
                            interval: 2000
                            running: root.open && root.activeTab === 2 && root.getScreenShares().length > 0
                            repeat: true
                            triggeredOnStart: true
                            onTriggered: screenCaptureProc.running = true
                        }

                        Process {
                            id: screenCaptureProc
                            command: ["grim", "/tmp/qs-screen-preview.png"]
                            onExited: screenPreviewRect.refreshTick++
                        }
                    }

                    // ── DIVIDER ───────────────────────────────────────
                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: "#2effffff"
                    }

                    // ── SECTION 2: ACTIVE SCREEN SHARES ───────────────
                    Text {
                        text: "ACTIVE SCREEN SHARES"
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 13
                        font.bold: true
                        color: "#89b4fa"
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        Text {
                            visible: root.getScreenShares().length === 0
                            text: "No active shares"
                            font.family: "JetBrainsMono NFP"
                            font.pixelSize: 14
                            font.italic: true
                            color: "#555555"
                            Layout.topMargin: 2
                            Layout.bottomMargin: 2
                        }

                        Repeater {
                            model: root.getScreenShares()

                            delegate: RowLayout {
                                Layout.fillWidth: true
                                implicitHeight: 30
                                spacing: 8

                                Text {
                                    font.family: "JetBrainsMono NFP"
                                    font.pixelSize: 15
                                    color: "#cba6f7"
                                    text: "󰍹"
                                }

                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    font.family: "JetBrainsMono NFP"
                                    font.pixelSize: 14
                                    color: "#cdd6f4"
                                    text: root.videoAppName(modelData)
                                }

                                // Stop button: destroy the share's source node
                                Rectangle {
                                    implicitWidth: 28
                                    implicitHeight: 22
                                    radius: 5
                                    color: scrStopMouse.containsMouse ? "#cc241d" : "#26ffffff"
                                    border.color: "#33ffffff"
                                    border.width: 1

                                    Text {
                                        anchors.centerIn: parent
                                        font.family: "JetBrainsMono NFP"
                                        font.pixelSize: 14
                                        color: "#ffffff"
                                        text: "󰅖"
                                    }

                                    MouseArea {
                                        id: scrStopMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.runCmd(["pw-cli", "destroy", String(modelData.id)])
                                    }
                                }
                            }
                        }
                    }

                    // Bottom padding spacer
                    Item { implicitHeight: 2 }
                }
            }

            // Bottom padding spacer
            Item { implicitHeight: 0 }
        }
    }
}
