import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// ─────────────────────────────────────────────────────────────────────────────
// ScreenRecordingBar — Authentic Apple macOS Screen Recording Floating Toolbar
//
// Position: Centered horizontally, ~1 inch (72px) above bottom of the screen.
// Features:
//   - 60 FPS Hardware-Accelerated VA-API / Ultra-Fast H.264 engine.
//   - Instant zero-lag optimistic UI on Record / Stop.
//   - Cohesive macOS frosted charcoal glass button styling (no blue background).
//   - 500ms delayed macOS hover tooltips on every control.
//   - Dynamic multi-monitor quick-select buttons (1 & 2) when >1 monitor connected.
//   - Interactive Snip Tool (`slurp`) with live dimension preview.
//   - Options Popover:
//       • Presets (Full Screen, Without Bar, Snip Area)
//       • Targets (Dual Screen only if multiple monitors, dynamic display list)
//       • Audio (None, Laptop Internal Desktop Sound, Microphone submenu)
//   - SF Pro Rounded typography & SF Symbols styling.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    readonly property string sfFont: "SF Pro Rounded"
    readonly property string sfFontMedium: "SF Pro Rounded"
    readonly property string sfFontBold: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    // ── Live Monitor / Screen Dimensions ──────────────────────────────────────
    readonly property real screenWidth: (root.screen && root.screen.width > 0) ? root.screen.width : (Screen.width > 0 ? Screen.width : 1920)
    readonly property real screenHeight: (root.screen && root.screen.height > 0) ? root.screen.height : (Screen.height > 0 ? Screen.height : 1080)

    // ── Floating Toolbar State ────────────────────────────────────────────────
    property bool barOpen: false
    property bool optionsOpen: false
    property bool isRecording: false
    property int  elapsedSeconds: 0
    property string activeMode: "fullscreen" // "fullscreen" | "nobar" | "custom" | "singlescreen"
    property string activePreset: "fullscreen" // "fullscreen" | "nobar" | "custom"
    property string activeTarget: "all" // "all" | "dualscreen" | "monitor-0" | "monitor-1"
    property string snipGeometry: ""
    property bool isSelectingSnip: false
    property string lastSavedFile: ""

    // Snip Geometry & Highlight Box State (Dull / Dim rest of screen)
    property real snipX: 0
    property real snipY: 0
    property real snipW: 0
    property real snipH: 0
    property bool snipValid: false

    readonly property real topBarHeight: 28

    readonly property bool isNoBarMode: (root.activeMode === "nobar" || root.activePreset === "nobar")
    readonly property bool isCustomMode: (root.activeMode === "custom" || root.activePreset === "custom") && root.snipValid

    // Active Recording Rect (Frames Fullscreen, NoBar, or Custom Snip)
    readonly property var currentRecordRect: {
        if (root.isNoBarMode) {
            return {
                x: 0,
                y: root.topBarHeight,
                width: root.screenWidth,
                height: Math.max(100, root.screenHeight - root.topBarHeight)
            }
        } else if (root.isCustomMode) {
            return {
                x: root.snipX,
                y: root.snipY,
                width: root.snipW,
                height: root.snipH
            }
        } else {
            return {
                x: 0,
                y: 0,
                width: root.screenWidth,
                height: root.screenHeight
            }
        }
    }

    readonly property bool showSnipHighlight: !root.isSelectingSnip && root.isCustomMode && (root.barOpen || root.isRecording)
    readonly property bool showNoBarHighlight: !root.isSelectingSnip && root.isNoBarMode && (root.barOpen || root.isRecording)
    readonly property bool showRecordingBorder: !root.isSelectingSnip && root.isRecording

    function parseSnipGeometry(geom) {
        if (!geom) {
            root.snipValid = false
            return
        }
        const parts = geom.trim().split(" ")
        if (parts.length < 2) return
        const xy = parts[0].split(",")
        const wh = parts[1].split("x")
        if (xy.length < 2 || wh.length < 2) return
        const x = parseInt(xy[0]) || 0
        const y = parseInt(xy[1]) || 0
        const w = parseInt(wh[0]) || 0
        const h = parseInt(wh[1]) || 0
        if (w > 0 && h > 0) {
            root.snipX = x
            root.snipY = y
            root.snipW = w
            root.snipH = h
            root.snipValid = true
        }
    }

    function updateSnipGeometry(x, y, w, h) {
        root.snipX = Math.round(x)
        root.snipY = Math.round(y)
        root.snipW = Math.max(40, Math.round(w))
        root.snipH = Math.max(40, Math.round(h))
        root.snipValid = (root.snipW > 0 && root.snipH > 0)
        root.snipGeometry = `${root.snipX},${root.snipY} ${root.snipW}x${root.snipH}`
    }

    // Multi-monitor & Audio State (Allows simultaneous System + Mic recording)
    property var monitors: []
    property var audioDevices: ({ "system_audio": [], "internal_mic": [], "external_mics": [] })
    property bool recordSystemAudio: false
    property bool recordMicAudio: false
    property string selectedMicType: "internal" // "internal" | "external"
    property string selectedExternalMicDevice: ""
    property bool micSubmenuOpen: false

    // Tooltip State
    property string tipText: ""
    property bool tipVisible: false
    property real tipX: 0

    // ── Window Anchors (Full overlay with floating bar positioned ~1 inch above bottom) ──
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "screenrecord-overlay"
    WlrLayershell.keyboardFocus: root.barOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    color: "transparent"
    visible: !root.isSelectingSnip && (root.barOpen || root.isRecording || container.opacity > 0.001)

    // ── Mouse Passthrough Mask (Full region when Options or Snip Area active) ──
    mask: (root.barOpen && !root.isSelectingSnip) ? ((root.optionsOpen || root.showSnipHighlight) ? fullRegion : barRegion) : emptyRegion

    Region {
        id: fullRegion
        x: 0
        y: 0
        width: root.screenWidth
        height: root.screenHeight
    }

    Region {
        id: barRegion
        x: Math.max(0, (root.screenWidth - (barCard.width + 40)) / 2)
        y: Math.max(0, root.screenHeight - 140)
        width: barCard.width + 40
        height: 140
    }

    Region {
        id: emptyRegion
        x: 0
        y: 0
        width: 0
        height: 0
    }

    // ── IPC Target: "screenrecord" ───────────────────────────────────────────
    IpcHandler {
        target: "screenrecord"
        function open() { root.openBar() }
        function close() { root.closeBar() }
        function toggle() { root.toggleBar() }
        function toggleOptions() {
            root.optionsOpen = !root.optionsOpen
            if (root.optionsOpen) root.refreshAudioDevices()
        }
        function toggleMicSubmenu() { root.micSubmenuOpen = !root.micSubmenuOpen }
        function toggleSystemAudio() { root.recordSystemAudio = !root.recordSystemAudio }
        function toggleMicAudio() { root.recordMicAudio = !root.recordMicAudio }
        function showTipTest() { root.showTip("Record Selected Portion", btnModeSnip) }
        function setSnip(geom: string) { root.onSnipResult(geom) }
        function setMode(mode: string) {
            root.activeMode = mode
            root.activePreset = mode
        }
        function setRecordingState(active: bool, mode: string, geom: string) {
            root.isRecording = !!active
            if (active) {
                root.barOpen = false
                if (mode && mode.length > 0) {
                    root.activeMode = mode
                    root.activePreset = mode
                }
                if (geom && geom.length > 0) {
                    root.snipGeometry = geom
                    root.parseSnipGeometry(geom)
                }
            }
        }
        function onSnipResult(geom: string) {
            if (geom && geom.length > 0) {
                root.snipGeometry = geom
                root.parseSnipGeometry(geom)
                root.activeMode = "custom"
                root.activePreset = "custom"
            }
            root.isSelectingSnip = false
            root.barOpen = true
        }
        function start() { root.startRecording() }
        function stop() { root.stopRecording() }
        function snip() { root.triggerSnipSelection() }
    }

    function openBar() {
        root.barOpen = true
        root.optionsOpen = false
        root.micSubmenuOpen = false
        hideTip()
        root.syncMonitors()
    }

    function closeBar() {
        root.barOpen = false
        root.optionsOpen = false
        root.micSubmenuOpen = false
        hideTip()
    }

    function toggleBar() {
        if (root.barOpen) closeBar()
        else openBar()
    }

    // ── Tooltip Management (500ms delay) ─────────────────────────────────────
    Timer {
        id: tipTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (root.tipText.length > 0 && !root.optionsOpen) {
                root.tipVisible = true
            }
        }
    }

    function showTip(text, item) {
        if (root.optionsOpen) return
        root.tipText = text
        try {
            const mapped = item.mapToItem(barCard, item.width / 2, 0)
            root.tipX = mapped.x
        } catch (e) {
            root.tipX = barCard.width / 2
        }
        tipTimer.restart()
    }

    function hideTip() {
        tipTimer.stop()
        root.tipVisible = false
    }

    // ── Zero-Churn Inotify State Observer (Kernel-level push) ────────────────
    FileView {
        id: recStateFile
        path: "/tmp/qs_recording.json"
        watchChanges: true
        onFileChanged: root.syncRecordingStateFromFile()
        onLoadedChanged: root.syncRecordingStateFromFile()
    }

    function syncRecordingStateFromFile() {
        try {
            const txt = recStateFile.text()
            if (txt && txt.trim().length > 0) {
                const data = JSON.parse(txt.trim())
                const active = !!data.isRecording
                root.isRecording = active
                if (active) {
                    root.barOpen = false
                    if (data.elapsedSeconds !== undefined) {
                        root.elapsedSeconds = data.elapsedSeconds
                    }
                    if (data.mode) {
                        root.activeMode = data.mode
                        root.activePreset = data.mode
                    }
                    if (data.geometry) {
                        root.snipGeometry = data.geometry
                        root.parseSnipGeometry(data.geometry)
                    }
                }
                if (data.filePath) root.lastSavedFile = data.filePath
                return
            }
        } catch (e) {}
        root.isRecording = false
    }

    // ── Native In-Memory Monitor Detection (Zero Process Fork) ───────────────
    function syncMonitors() {
        if (Quickshell.screens && Quickshell.screens.length > 0) {
            const list = []
            for (let i = 0; i < Quickshell.screens.length; i++) {
                const s = Quickshell.screens[i]
                list.push({
                    id: i,
                    name: s.name || ("Display-" + (i + 1)),
                    description: s.model || s.name || ("Display " + (i + 1)),
                    width: s.width || 1920,
                    height: s.height || 1080,
                    x: s.x || 0,
                    y: s.y || 0,
                    is_primary: (i === 0)
                })
            }
            root.monitors = list
        } else {
            monitorsProc.running = false
            monitorsProc.running = true
        }
    }

    Process {
        id: monitorsProc
        command: ["python3", Paths.script("screenrecord-service.py"), "monitors"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                try {
                    root.monitors = JSON.parse(line.trim())
                } catch (e) {}
            }
        }
    }

    // ── Lazy Audio Device Discovery (Runs only on Options popover open) ───────
    function refreshAudioDevices() {
        audioProc.running = false
        audioProc.running = true
    }

    Process {
        id: audioProc
        command: ["python3", Paths.script("screenrecord-service.py"), "audio-devices"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                try {
                    root.audioDevices = JSON.parse(line.trim())
                } catch (e) {}
            }
        }
    }

    Process { id: snipRunner }

    function triggerSnipSelection() {
        root.optionsOpen = false
        hideTip()
        root.isSelectingSnip = true
        root.barOpen = false
        snipRunner.running = false
        snipRunner.command = ["python3", Paths.script("screenrecord-service.py"), "select-and-notify"]
        snipRunner.running = true
    }

    Process {
        id: actionProc
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                try {
                    const data = JSON.parse(line.trim())
                    if (data.status) {
                        root.isRecording = !!data.status.isRecording
                        root.elapsedSeconds = data.status.elapsedSeconds || 0
                    } else if (data.isRecording !== undefined) {
                        root.isRecording = !!data.isRecording
                    }
                    if (data.filePath) root.lastSavedFile = data.filePath
                } catch (e) {}
            }
        }
    }

    Timer {
        id: recordTimer
        interval: 1000
        repeat: true
        running: root.isRecording
        onTriggered: {
            root.elapsedSeconds += 1
        }
    }

    Component.onCompleted: {
        root.syncMonitors()
        root.syncRecordingStateFromFile()
    }

    // ── Start / Stop Recording (Instant Optimistic Feedback) ──────────────────
    function startRecording() {
        // Immediate UI feedback — eliminate delay completely
        root.isRecording = true
        root.elapsedSeconds = 0
        root.optionsOpen = false
        root.barOpen = false // Rectangular bar automatically disappears
        hideTip()
        Quickshell.execDetached(["quickshell", "ipc", "call", "statusdevices", "setRecording", "true"])

        const cmd = ["python3", Paths.script("screenrecord-service.py"), "start", "--fps", "60"]

        let modeToUse = root.activeMode
        if (root.activePreset === "nobar") {
            modeToUse = "nobar"
        } else if (root.activePreset === "custom" || root.activeMode === "custom") {
            modeToUse = "custom"
            if (root.snipGeometry) {
                cmd.push("--geometry", root.snipGeometry)
            }
        } else if (root.activeTarget === "dualscreen") {
            modeToUse = "dualscreen"
        } else if (root.activeTarget.startsWith("monitor-")) {
            modeToUse = "singlescreen"
            const idx = parseInt(root.activeTarget.replace("monitor-", ""))
            if (root.monitors && root.monitors[idx]) {
                cmd.push("--output", root.monitors[idx].name)
            }
        }

        cmd.push("--mode", modeToUse)

        // Simultaneous Multi-Source Audio Parameters
        if (root.recordSystemAudio && root.audioDevices.system_audio && root.audioDevices.system_audio.length > 0) {
            cmd.push("--system-audio", root.audioDevices.system_audio[0].name)
        }
        if (root.recordMicAudio) {
            if (root.selectedMicType === "external" && root.selectedExternalMicDevice) {
                cmd.push("--mic-audio", root.selectedExternalMicDevice)
            } else if (root.audioDevices.internal_mic && root.audioDevices.internal_mic.length > 0) {
                cmd.push("--mic-audio", root.audioDevices.internal_mic[0].name)
            }
        }

        actionProc.command = cmd
        actionProc.running = true
    }

    function stopRecording() {
        // Immediate UI feedback
        root.isRecording = false
        hideTip()
        Quickshell.execDetached(["quickshell", "ipc", "call", "statusdevices", "setRecording", "false"])
        actionProc.command = ["python3", Paths.script("screenrecord-service.py"), "stop"]
        actionProc.running = true
    }

    function formatTime(sec) {
        const m = Math.floor(sec / 60)
        const s = sec % 60
        return (m < 10 ? "0" + m : m) + ":" + (s < 10 ? "0" + s : s)
    }

    // ── Outside Click & Escape to Dismiss ────────────────────────────────────
    MouseArea {
        anchors.fill: parent
        enabled: root.barOpen && !root.isSelectingSnip
        hoverEnabled: false
        focus: root.barOpen
        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                if (root.optionsOpen) {
                    root.optionsOpen = false
                } else if (!root.isRecording) {
                    root.closeBar()
                }
                event.accepted = true
            }
        }
        z: -1
        onClicked: {
            if (root.optionsOpen) {
                root.optionsOpen = false
            } else if (!root.isRecording && !root.showSnipHighlight) {
                root.closeBar()
            }
        }
    }

    // ── 4. DIMMED BACKDROP & SELECTION FRAME (Dull / Dim outside, bright selection) ──
    Item {
        id: snipHighlightOverlay
        anchors.fill: parent
        visible: root.showSnipHighlight
        opacity: root.showSnipHighlight ? 1.0 : 0.0
        z: 2

        Behavior on opacity {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }

        // 4.1 Four Dull / Dim Backdrop Rectangles covering everything outside selection
        Rectangle {
            id: dimTop
            x: 0
            y: 0
            width: root.screenWidth
            height: Math.max(0, root.snipY)
            color: "#88000000" // Pure neutral dark dim (53% opacity, no blue, no blur)
        }

        Rectangle {
            id: dimBottom
            x: 0
            y: root.snipY + root.snipH
            width: root.screenWidth
            height: Math.max(0, root.screenHeight - (root.snipY + root.snipH))
            color: "#88000000"
        }

        Rectangle {
            id: dimLeft
            x: 0
            y: root.snipY
            width: Math.max(0, root.snipX)
            height: root.snipH
            color: "#88000000"
        }

        Rectangle {
            id: dimRight
            x: root.snipX + root.snipW
            y: root.snipY
            width: Math.max(0, root.screenWidth - (root.snipX + root.snipW))
            height: root.snipH
            color: "#88000000"
        }

        // 4.2 The Selection Frame (Clear cutout + Apple macOS border & handles)
        Item {
            id: selectionBox
            x: root.snipX
            y: root.snipY
            width: root.snipW
            height: root.snipH

            // Outer dark contrast stroke (for visibility against white backgrounds)
            Rectangle {
                anchors.fill: parent
                anchors.margins: -3
                color: "transparent"
                border.color: "#60000000"
                border.width: 1
                visible: !root.isRecording
            }

            // Main crisp border (outside capture area; white when framing, handled by activeRecordingBorder during recording)
            Rectangle {
                anchors.fill: parent
                anchors.margins: -2
                color: "transparent"
                border.color: "#ffffff"
                border.width: 2
                visible: !root.isRecording
            }

            // Drag area to reposition selection box anywhere on screen (disabled during recording)
            MouseArea {
                id: boxMoveArea
                anchors.fill: parent
                anchors.margins: 10
                enabled: !root.isRecording
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                property real prevMappedX: 0
                property real prevMappedY: 0

                onPressed: function(mouse) {
                    const pt = mapToItem(root, mouse.x, mouse.y)
                    prevMappedX = pt.x
                    prevMappedY = pt.y
                }

                onPositionChanged: function(mouse) {
                    if (pressed) {
                        const pt = mapToItem(root, mouse.x, mouse.y)
                        const dx = pt.x - prevMappedX
                        const dy = pt.y - prevMappedY
                        prevMappedX = pt.x
                        prevMappedY = pt.y
                        const newX = Math.max(0, Math.min(root.screenWidth - root.snipW, root.snipX + dx))
                        const newY = Math.max(0, Math.min(root.screenHeight - root.snipH, root.snipY + dy))
                        root.updateSnipGeometry(newX, newY, root.snipW, root.snipH)
                    }
                }
            }

            // ── Interactive Controls (Badge & Resize Handles, hidden during recording) ──
            Item {
                id: selectionControls
                anchors.fill: parent
                visible: !root.isRecording

                // macOS Live Dimensions Pill Badge
                Rectangle {
                    id: dimBadge
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height > 90 ? (parent.height - height - 12) : (parent.y > 36 ? -height - 8 : parent.height + 8)
                    implicitWidth: badgeRow.implicitWidth + 18
                    implicitHeight: 26
                    radius: 13
                    color: "#d916161e"
                    border.color: "#40ffffff"
                    border.width: 1

                    RowLayout {
                        id: badgeRow
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            font.family: root.iconFont
                            font.pixelSize: 13
                            color: "#007aff"
                            text: "󰆐"
                            renderType: Text.QtRendering
                        }

                        Text {
                            text: root.snipW + " × " + root.snipH
                            font.family: root.sfFontMedium
                            font.pixelSize: 12
                            color: "#f8fafc"
                            renderType: Text.QtRendering
                        }
                    }
                }

            // ── 8 Resize Handles (Apple macOS Style) ──
            // Top-Left Corner
            Rectangle {
                width: 9; height: 9; radius: 2; color: "#ffffff"; border.color: "#40000000"; border.width: 1
                x: -4; y: -4
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.SizeFDiagCursor
                    property real prevMappedX: 0; property real prevMappedY: 0
                    onPressed: function(m) { const p = mapToItem(root, m.x, m.y); prevMappedX = p.x; prevMappedY = p.y }
                    onPositionChanged: function(m) {
                        if (pressed) {
                            const p = mapToItem(root, m.x, m.y); const dx = p.x - prevMappedX; const dy = p.y - prevMappedY
                            prevMappedX = p.x; prevMappedY = p.y
                            const newX = Math.max(0, Math.min(root.snipX + root.snipW - 40, root.snipX + dx))
                            const newY = Math.max(0, Math.min(root.snipY + root.snipH - 40, root.snipY + dy))
                            const newW = root.snipW - (newX - root.snipX)
                            const newH = root.snipH - (newY - root.snipY)
                            root.updateSnipGeometry(newX, newY, newW, newH)
                        }
                    }
                }
            }

            // Top-Center Edge
            Rectangle {
                width: 9; height: 9; radius: 2; color: "#ffffff"; border.color: "#40000000"; border.width: 1
                x: parent.width / 2 - 4; y: -4
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.SizeVerCursor
                    property real prevMappedY: 0
                    onPressed: function(m) { const p = mapToItem(root, m.x, m.y); prevMappedY = p.y }
                    onPositionChanged: function(m) {
                        if (pressed) {
                            const p = mapToItem(root, m.x, m.y); const dy = p.y - prevMappedY; prevMappedY = p.y
                            const newY = Math.max(0, Math.min(root.snipY + root.snipH - 40, root.snipY + dy))
                            const newH = root.snipH - (newY - root.snipY)
                            root.updateSnipGeometry(root.snipX, newY, root.snipW, newH)
                        }
                    }
                }
            }

            // Top-Right Corner
            Rectangle {
                width: 9; height: 9; radius: 2; color: "#ffffff"; border.color: "#40000000"; border.width: 1
                x: parent.width - 5; y: -4
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.SizeBDiagCursor
                    property real prevMappedX: 0; property real prevMappedY: 0
                    onPressed: function(m) { const p = mapToItem(root, m.x, m.y); prevMappedX = p.x; prevMappedY = p.y }
                    onPositionChanged: function(m) {
                        if (pressed) {
                            const p = mapToItem(root, m.x, m.y); const dx = p.x - prevMappedX; const dy = p.y - prevMappedY
                            prevMappedX = p.x; prevMappedY = p.y
                            const newY = Math.max(0, Math.min(root.snipY + root.snipH - 40, root.snipY + dy))
                            const newW = Math.max(40, Math.min(root.screenWidth - root.snipX, root.snipW + dx))
                            const newH = root.snipH - (newY - root.snipY)
                            root.updateSnipGeometry(root.snipX, newY, newW, newH)
                        }
                    }
                }
            }

            // Middle-Left Edge
            Rectangle {
                width: 9; height: 9; radius: 2; color: "#ffffff"; border.color: "#40000000"; border.width: 1
                x: -4; y: parent.height / 2 - 4
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.SizeHorCursor
                    property real prevMappedX: 0
                    onPressed: function(m) { const p = mapToItem(root, m.x, m.y); prevMappedX = p.x }
                    onPositionChanged: function(m) {
                        if (pressed) {
                            const p = mapToItem(root, m.x, m.y); const dx = p.x - prevMappedX; prevMappedX = p.x
                            const newX = Math.max(0, Math.min(root.snipX + root.snipW - 40, root.snipX + dx))
                            const newW = root.snipW - (newX - root.snipX)
                            root.updateSnipGeometry(newX, root.snipY, newW, root.snipH)
                        }
                    }
                }
            }

            // Middle-Right Edge
            Rectangle {
                width: 9; height: 9; radius: 2; color: "#ffffff"; border.color: "#40000000"; border.width: 1
                x: parent.width - 5; y: parent.height / 2 - 4
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.SizeHorCursor
                    property real prevMappedX: 0
                    onPressed: function(m) { const p = mapToItem(root, m.x, m.y); prevMappedX = p.x }
                    onPositionChanged: function(m) {
                        if (pressed) {
                            const p = mapToItem(root, m.x, m.y); const dx = p.x - prevMappedX; prevMappedX = p.x
                            const newW = Math.max(40, Math.min(root.screenWidth - root.snipX, root.snipW + dx))
                            root.updateSnipGeometry(root.snipX, root.snipY, newW, root.snipH)
                        }
                    }
                }
            }

            // Bottom-Left Corner
            Rectangle {
                width: 9; height: 9; radius: 2; color: "#ffffff"; border.color: "#40000000"; border.width: 1
                x: -4; y: parent.height - 5
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.SizeBDiagCursor
                    property real prevMappedX: 0; property real prevMappedY: 0
                    onPressed: function(m) { const p = mapToItem(root, m.x, m.y); prevMappedX = p.x; prevMappedY = p.y }
                    onPositionChanged: function(m) {
                        if (pressed) {
                            const p = mapToItem(root, m.x, m.y); const dx = p.x - prevMappedX; const dy = p.y - prevMappedY
                            prevMappedX = p.x; prevMappedY = p.y
                            const newX = Math.max(0, Math.min(root.snipX + root.snipW - 40, root.snipX + dx))
                            const newW = root.snipW - (newX - root.snipX)
                            const newH = Math.max(40, Math.min(root.screenHeight - root.snipY, root.snipH + dy))
                            root.updateSnipGeometry(newX, root.snipY, newW, newH)
                        }
                    }
                }
            }

            // Bottom-Center Edge
            Rectangle {
                width: 9; height: 9; radius: 2; color: "#ffffff"; border.color: "#40000000"; border.width: 1
                x: parent.width / 2 - 4; y: parent.height - 5
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.SizeVerCursor
                    property real prevMappedY: 0
                    onPressed: function(m) { const p = mapToItem(root, m.x, m.y); prevMappedY = p.y }
                    onPositionChanged: function(m) {
                        if (pressed) {
                            const p = mapToItem(root, m.x, m.y); const dy = p.y - prevMappedY; prevMappedY = p.y
                            const newH = Math.max(40, Math.min(root.screenHeight - root.snipY, root.snipH + dy))
                            root.updateSnipGeometry(root.snipX, root.snipY, root.snipW, newH)
                        }
                    }
                }
            }

            // Bottom-Right Corner
            Rectangle {
                width: 9; height: 9; radius: 2; color: "#ffffff"; border.color: "#40000000"; border.width: 1
                x: parent.width - 5; y: parent.height - 5
                MouseArea {
                    anchors.fill: parent; anchors.margins: -4
                    cursorShape: Qt.SizeFDiagCursor
                    property real prevMappedX: 0; property real prevMappedY: 0
                    onPressed: function(m) { const p = mapToItem(root, m.x, m.y); prevMappedX = p.x; prevMappedY = p.y }
                    onPositionChanged: function(m) {
                        if (pressed) {
                            const p = mapToItem(root, m.x, m.y); const dx = p.x - prevMappedX; const dy = p.y - prevMappedY
                            prevMappedX = p.x; prevMappedY = p.y
                            const newW = Math.max(40, Math.min(root.screenWidth - root.snipX, root.snipW + dx))
                            const newH = Math.max(40, Math.min(root.screenHeight - root.snipY, root.snipH + dy))
                            root.updateSnipGeometry(root.snipX, root.snipY, newW, newH)
                        }
                    }
                }
            }
            } // end selectionControls
        }
    }

    // ── 5. NOBAR DIMMING & FRAMING (Dims top 28px bar, frames desktop area) ──
    Item {
        id: noBarOverlay
        anchors.fill: parent
        visible: root.showNoBarHighlight
        opacity: root.showNoBarHighlight ? 1.0 : 0.0
        z: 2

        Behavior on opacity {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }

        // 5.1 Dimming over top bar (28px)
        Rectangle {
            x: 0
            y: 0
            width: root.screenWidth
            height: root.topBarHeight
            color: "#88000000" // Neutral dark dimming (no blur, no blue)
        }

        // 5.2 Framing Preview before recording starts
        Item {
            x: 0
            y: root.topBarHeight
            width: root.screenWidth
            height: Math.max(100, root.screenHeight - root.topBarHeight)
            visible: !root.isRecording

            // Crisp white framing border before recording
            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.color: "#ffffff"
                border.width: 2
            }

            // Dimension badge
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 16
                implicitWidth: noBarBadgeRow.implicitWidth + 20
                implicitHeight: 26
                radius: 13
                color: "#d916161e"
                border.color: "#40ffffff"
                border.width: 1

                RowLayout {
                    id: noBarBadgeRow
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        font.family: root.iconFont
                        font.pixelSize: 13
                        color: "#007aff"
                        text: "󰹑"
                        renderType: Text.QtRendering
                    }

                    Text {
                        text: "Without Bar (" + root.screenWidth + " × " + Math.round(root.screenHeight - root.topBarHeight) + ")"
                        font.family: root.sfFontMedium
                        font.pixelSize: 12
                        color: "#f8fafc"
                        renderType: Text.QtRendering
                    }
                }
            }
        }
    }

    // ── 6. UNIVERSAL APPLE RED RECORDING BORDER (Fullscreen, NoBar, or Custom) ──
    Item {
        id: activeRecordingBorder
        visible: root.showRecordingBorder
        opacity: root.showRecordingBorder ? 1.0 : 0.0
        z: 4

        Behavior on opacity {
            NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
        }

        x: root.currentRecordRect.x
        y: root.currentRecordRect.y
        width: root.currentRecordRect.width
        height: root.currentRecordRect.height

        // Outer dark contrast stroke
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            color: "transparent"
            border.color: "#60000000"
            border.width: 1
        }

        // Main 3px vibrant Apple Red recording border
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            border.color: "#ef4444"
            border.width: 3
        }

        // Inner dark contrast stroke
        Rectangle {
            anchors.fill: parent
            anchors.margins: 3
            color: "transparent"
            border.color: "#40000000"
            border.width: 1
        }
    }

    Item {
        id: container
        z: 10
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 72
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(barCard.width, optionsCard.width)
        height: barCard.height + (root.optionsOpen ? optionsCard.height + 12 : 0)
        opacity: (root.barOpen && !root.isSelectingSnip) ? 1.0 : 0.0

        Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
        }

        // ══════════════════════════════════════════════════════════════════════
        // 1. POPUP OPTIONS / PRESETS CARD (Floats Directly Above Toolbar)
        // ══════════════════════════════════════════════════════════════════════
        Rectangle {
            id: optionsCard
            anchors.bottom: barCard.top
            anchors.bottomMargin: 12
            anchors.horizontalCenter: barCard.horizontalCenter
            width: 320
            height: optionsCol.implicitHeight + 20
            radius: 16
            color: "#e6181820"
            border.color: "#35ffffff"
            border.width: 1
            visible: root.optionsOpen
            opacity: root.optionsOpen ? 1.0 : 0.0

            Behavior on opacity {
                NumberAnimation { duration: 160; easing.type: Easing.OutQuad }
            }

            ColumnLayout {
                id: optionsCol
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                // ── Section 1: Presets ────────────────────────────────────────
                Text {
                    text: "RECORDING PRESETS"
                    font.family: root.sfFontBold
                    font.pixelSize: 11
                    color: "#94a3b8"
                    renderType: Text.QtRendering
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    // Option: Full Screen
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: 8
                        color: optFullMouse.containsMouse ? "#20ffffff" : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                text: root.activePreset === "fullscreen" && root.activeMode === "fullscreen" ? "✓" : ""
                                font.family: root.sfFontBold
                                font.pixelSize: 13
                                color: "#007aff"
                                Layout.preferredWidth: 16
                            }
                            Text {
                                text: "Full Screen (Entire Workspace)"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: "#ffffff"
                                Layout.fillWidth: true
                            }
                        }
                        MouseArea {
                            id: optFullMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.activePreset = "fullscreen"
                                root.activeMode = "fullscreen"
                                root.activeTarget = "all"
                                root.optionsOpen = false
                            }
                        }
                    }

                    // Option: Full Screen without Bar
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: 8
                        color: optNoBarMouse.containsMouse ? "#20ffffff" : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                text: root.activePreset === "nobar" ? "✓" : ""
                                font.family: root.sfFontBold
                                font.pixelSize: 13
                                color: "#007aff"
                                Layout.preferredWidth: 16
                            }
                            Text {
                                text: "Full Screen (Without Quickshell Bar)"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: "#ffffff"
                                Layout.fillWidth: true
                            }
                        }
                        MouseArea {
                            id: optNoBarMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.activePreset = "nobar"
                                root.activeMode = "nobar"
                                root.optionsOpen = false
                            }
                        }
                    }

                    // Option: Custom Area / Snip Tool
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: 8
                        color: optCustomMouse.containsMouse ? "#20ffffff" : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                text: root.activePreset === "custom" || root.activeMode === "custom" ? "✓" : ""
                                font.family: root.sfFontBold
                                font.pixelSize: 13
                                color: "#007aff"
                                Layout.preferredWidth: 16
                            }
                            Text {
                                text: root.snipGeometry ? "Custom Snip (" + root.snipGeometry.split(" ")[1] + ")" : "Custom (Select Area / Snip Tool)"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: "#ffffff"
                                Layout.fillWidth: true
                            }
                        }
                        MouseArea {
                            id: optCustomMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.activePreset = "custom"
                                root.activeMode = "custom"
                                if (!root.snipValid) {
                                    root.triggerSnipSelection()
                                } else {
                                    root.optionsOpen = false
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: "#25ffffff"
                }

                // ── Section 2: Screen Target (Dual Screen ONLY shown if >1 monitor) ─────
                Text {
                    text: "SCREEN TARGET"
                    font.family: root.sfFontBold
                    font.pixelSize: 11
                    color: "#94a3b8"
                    renderType: Text.QtRendering
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    // Dual Screen (Only shown when multiple monitors are connected)
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: 8
                        visible: root.monitors && root.monitors.length > 1
                        color: tgtDualMouse.containsMouse ? "#20ffffff" : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                text: root.activeTarget === "dualscreen" ? "✓" : ""
                                font.family: root.sfFontBold
                                font.pixelSize: 13
                                color: "#007aff"
                                Layout.preferredWidth: 16
                            }
                            Text {
                                text: "Dual Screen (All Displays)"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: "#ffffff"
                                Layout.fillWidth: true
                            }
                        }
                        MouseArea {
                            id: tgtDualMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.activeTarget = "dualscreen"
                                root.activeMode = "dualscreen"
                                root.optionsOpen = false
                            }
                        }
                    }

                    // Dynamic list of connected monitors
                    Repeater {
                        model: root.monitors || []
                        delegate: Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 30
                            radius: 8
                            color: tgtMonMouse.containsMouse ? "#20ffffff" : "transparent"

                            readonly property string tgtId: "monitor-" + modelData.id
                            readonly property bool isSel: root.activeTarget === tgtId || (root.monitors.length === 1 && root.activeTarget === "all")

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 8
                                Text {
                                    text: isSel ? "✓" : ""
                                    font.family: root.sfFontBold
                                    font.pixelSize: 13
                                    color: "#007aff"
                                    Layout.preferredWidth: 16
                                }
                                Text {
                                    text: (root.monitors.length > 1 ? "Monitor " + (index + 1) + ": " : "") + modelData.name + " (" + modelData.width + "×" + modelData.height + ")"
                                    font.family: root.sfFont
                                    font.pixelSize: 13
                                    color: "#ffffff"
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                }
                            }

                            MouseArea {
                                id: tgtMonMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.activeTarget = tgtId
                                    root.activeMode = "singlescreen"
                                    root.optionsOpen = false
                                }
                            }
                        }
                    }
                }

                // Divider
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: "#25ffffff"
                }

                // ── Section 3: Audio Sources (Simultaneous Multi-Selection) ────────────────
                Text {
                    text: "AUDIO SOURCES (SELECT MULTIPLE)"
                    font.family: root.sfFontBold
                    font.pixelSize: 11
                    color: "#94a3b8"
                    renderType: Text.QtRendering
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    // Option 1: Laptop Internal Sound (Desktop Audio Loopback)
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: 8
                        color: audioSysMouse.containsMouse ? "#20ffffff" : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                text: root.recordSystemAudio ? "✓" : ""
                                font.family: root.sfFontBold
                                font.pixelSize: 13
                                color: "#007aff"
                                Layout.preferredWidth: 16
                            }
                            Text {
                                text: "Laptop Internal Sound (Desktop Audio)"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: "#ffffff"
                                Layout.fillWidth: true
                            }
                        }
                        MouseArea {
                            id: audioSysMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.recordSystemAudio = !root.recordSystemAudio
                            }
                        }
                    }

                    // Option 2: Microphone Audio (Toggle + Device Expander)
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 32
                        radius: 8
                        color: micExpMouse.containsMouse ? "#20ffffff" : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 8
                            Text {
                                text: root.recordMicAudio ? "✓" : ""
                                font.family: root.sfFontBold
                                font.pixelSize: 13
                                color: "#007aff"
                                Layout.preferredWidth: 16
                            }
                            Text {
                                text: "Microphone Audio"
                                font.family: root.sfFont
                                font.pixelSize: 13
                                color: "#ffffff"
                                Layout.fillWidth: true
                            }
                            Text {
                                font.family: root.iconFont
                                font.pixelSize: 12
                                color: "#94a3b8"
                                text: root.micSubmenuOpen ? "󰅃" : "󰅀"
                            }
                        }
                        MouseArea {
                            id: micExpMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: function(mouse) {
                                // Clicking chevron area toggles submenu; clicking label toggles recording
                                if (mouse.x > width - 36) {
                                    root.micSubmenuOpen = !root.micSubmenuOpen
                                } else {
                                    root.recordMicAudio = !root.recordMicAudio
                                }
                            }
                        }
                    }

                    // Microphone Devices List
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 16
                        visible: root.micSubmenuOpen
                        spacing: 2

                        // Built-in Laptop Microphone
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 28
                            radius: 6
                            color: micIntMouse.containsMouse ? "#20ffffff" : "transparent"
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 6
                                anchors.rightMargin: 6
                                spacing: 6
                                Text {
                                    text: root.selectedMicType === "internal" ? "✓" : ""
                                    font.family: root.sfFontBold
                                    font.pixelSize: 12
                                    color: "#007aff"
                                    Layout.preferredWidth: 14
                                }
                                Text {
                                    text: "Laptop Built-in Microphone"
                                    font.family: root.sfFont
                                    font.pixelSize: 12
                                    color: "#cbd5e1"
                                    Layout.fillWidth: true
                                }
                            }
                            MouseArea {
                                id: micIntMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.selectedMicType = "internal"
                                    root.recordMicAudio = true
                                }
                            }
                        }

                        // External Microphones (USB / Bluetooth)
                        Repeater {
                            model: (root.audioDevices && root.audioDevices.external_mics) ? root.audioDevices.external_mics : []
                            delegate: Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 28
                                radius: 6
                                color: micExtMouse.containsMouse ? "#20ffffff" : "transparent"
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    spacing: 6
                                    Text {
                                        text: (root.selectedMicType === "external" && root.selectedExternalMicDevice === modelData.name) ? "✓" : ""
                                        font.family: root.sfFontBold
                                        font.pixelSize: 12
                                        color: "#007aff"
                                        Layout.preferredWidth: 14
                                    }
                                    Text {
                                        text: modelData.description
                                        font.family: root.sfFont
                                        font.pixelSize: 12
                                        color: "#cbd5e1"
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }
                                }
                                MouseArea {
                                    id: micExtMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.selectedMicType = "external"
                                        root.selectedExternalMicDevice = modelData.name
                                        root.recordMicAudio = true
                                    }
                                }
                            }
                        }

                        Text {
                            text: "No external microphone connected"
                            font.family: root.sfFont
                            font.pixelSize: 11
                            font.italic: true
                            color: "#64748b"
                            visible: !root.audioDevices || !root.audioDevices.external_mics || root.audioDevices.external_mics.length === 0
                            Layout.leftMargin: 20
                        }
                    }
                }
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // 2. FLOATING HOVER TOOLTIP (500ms Delay)
        // ══════════════════════════════════════════════════════════════════════
        Rectangle {
            id: tooltipBox
            anchors.bottom: barCard.top
            anchors.bottomMargin: 8
            x: Math.max(8, Math.min(barCard.width - width - 8, root.tipX - width / 2))
            implicitWidth: tipLabel.implicitWidth + 18
            implicitHeight: 24
            radius: 6
            color: "#f016161a"
            border.color: "#35ffffff"
            border.width: 1
            visible: root.tipVisible && !root.optionsOpen
            opacity: (root.tipVisible && !root.optionsOpen) ? 1.0 : 0.0

            Behavior on opacity {
                NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
            }

            Text {
                id: tipLabel
                anchors.centerIn: parent
                text: root.tipText
                font.family: root.sfFontMedium
                font.pixelSize: 11
                color: "#e2e8f0"
                renderType: Text.QtRendering
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // 3. MAIN FLOATING HORIZONTAL TOOLBAR (Apple macOS Style)
        // ══════════════════════════════════════════════════════════════════════
        Rectangle {
            id: barCard
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: barRow.implicitWidth + 24
            height: 52
            radius: 18
            color: "#e6141418"
            border.color: "#35ffffff"
            border.width: 1

            RowLayout {
                id: barRow
                anchors.centerIn: parent
                spacing: 10

                // 3.1 Close Button (macOS xmark)
                Rectangle {
                    id: btnClose
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    radius: 16
                    color: closeMouse.containsMouse ? "#30ffffff" : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }

                    Text {
                        anchors.centerIn: parent
                        font.family: root.iconFont
                        font.pixelSize: 16
                        color: "#94a3b8"
                        text: "󰅖"
                        renderType: Text.QtRendering
                    }

                    MouseArea {
                        id: closeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.showTip("Close Toolbar (Esc)", btnClose)
                        onExited: root.hideTip()
                        onClicked: root.closeBar()
                    }
                }

                // Divider
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 24
                    color: "#25ffffff"
                }

                // 3.2 Segmented Mode Selector: Full View | Window/NoBar | Snip Area
                RowLayout {
                    spacing: 4

                    // Full View (Entire Screen)
                    Rectangle {
                        id: btnModeFull
                        Layout.preferredWidth: 42
                        Layout.preferredHeight: 36
                        radius: 10
                        readonly property bool isSel: root.activeMode === "fullscreen" && root.activePreset === "fullscreen"
                        color: isSel ? "#30ffffff" : (modeFullMouse.containsMouse ? "#18ffffff" : "transparent")
                        border.color: isSel ? "#60ffffff" : "transparent"
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: parent.isSel ? "#ffffff" : "#94a3b8"
                            text: "󰍹"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: modeFullMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.showTip("Record Entire Screen", btnModeFull)
                            onExited: root.hideTip()
                            onClicked: {
                                root.activeMode = "fullscreen"
                                root.activePreset = "fullscreen"
                                root.activeTarget = "all"
                            }
                        }
                    }

                    // Partial View / Without Bar
                    Rectangle {
                        id: btnModePart
                        Layout.preferredWidth: 42
                        Layout.preferredHeight: 36
                        radius: 10
                        readonly property bool isSel: root.activeMode === "nobar" || root.activePreset === "nobar"
                        color: isSel ? "#30ffffff" : (modePartMouse.containsMouse ? "#18ffffff" : "transparent")
                        border.color: isSel ? "#60ffffff" : "transparent"
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: parent.isSel ? "#ffffff" : "#94a3b8"
                            text: "󰹑"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: modePartMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.showTip("Record Quickshell Bar Excluded", btnModePart)
                            onExited: root.hideTip()
                            onClicked: {
                                root.activeMode = "nobar"
                                root.activePreset = "nobar"
                            }
                        }
                    }

                    // Snip Tool (Select Area)
                    Rectangle {
                        id: btnModeSnip
                        Layout.preferredWidth: 42
                        Layout.preferredHeight: 36
                        radius: 10
                        readonly property bool isSel: root.activeMode === "custom" || root.activePreset === "custom"
                        color: isSel ? "#30ffffff" : (modeSnipMouse.containsMouse ? "#18ffffff" : "transparent")
                        border.color: isSel ? "#60ffffff" : "transparent"
                        border.width: 1

                        Text {
                            anchors.centerIn: parent
                            font.family: root.iconFont
                            font.pixelSize: 20
                            color: parent.isSel ? "#ffffff" : "#94a3b8"
                            text: "󰆐"
                            renderType: Text.QtRendering
                        }

                        MouseArea {
                            id: modeSnipMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.showTip(root.snipGeometry ? "Snip Region: " + root.snipGeometry.split(" ")[1] : "Select Portion to Record", btnModeSnip)
                            onExited: root.hideTip()
                            onClicked: {
                                if (root.activeMode === "custom" || !root.snipValid) {
                                    root.triggerSnipSelection()
                                } else {
                                    root.activeMode = "custom"
                                    root.activePreset = "custom"
                                }
                            }
                        }
                    }
                }

                // 3.3 Multi-Monitor Quick-Select Buttons (Introduced dynamically if >1 monitor)
                RowLayout {
                    spacing: 4
                    visible: root.monitors && root.monitors.length > 1

                    // Divider before monitors
                    Rectangle {
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 24
                        color: "#25ffffff"
                    }

                    // Monitor 1 Button
                    Rectangle {
                        id: btnMon1
                        Layout.preferredWidth: 42
                        Layout.preferredHeight: 36
                        radius: 10
                        readonly property bool isSel: root.activeTarget === "monitor-0"
                        color: isSel ? "#30ffffff" : (mon1Mouse.containsMouse ? "#18ffffff" : "transparent")
                        border.color: isSel ? "#60ffffff" : "transparent"
                        border.width: 1

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 1
                            Text {
                                font.family: root.iconFont
                                font.pixelSize: 18
                                color: btnMon1.isSel ? "#ffffff" : "#94a3b8"
                                text: "󰍹"
                            }
                            Text {
                                font.family: root.sfFontBold
                                font.pixelSize: 11
                                color: btnMon1.isSel ? "#38bdf8" : "#94a3b8"
                                text: "1"
                            }
                        }

                        MouseArea {
                            id: mon1Mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.showTip("Record Monitor 1 (" + (root.monitors[0] ? root.monitors[0].name : "1") + ")", btnMon1)
                            onExited: root.hideTip()
                            onClicked: {
                                root.activeTarget = "monitor-0"
                                root.activeMode = "singlescreen"
                            }
                        }
                    }

                    // Monitor 2 Button
                    Rectangle {
                        id: btnMon2
                        Layout.preferredWidth: 42
                        Layout.preferredHeight: 36
                        radius: 10
                        readonly property bool isSel: root.activeTarget === "monitor-1"
                        color: isSel ? "#30ffffff" : (mon2Mouse.containsMouse ? "#18ffffff" : "transparent")
                        border.color: isSel ? "#60ffffff" : "transparent"
                        border.width: 1

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 1
                            Text {
                                font.family: root.iconFont
                                font.pixelSize: 18
                                color: btnMon2.isSel ? "#ffffff" : "#94a3b8"
                                text: "󰍹"
                            }
                            Text {
                                font.family: root.sfFontBold
                                font.pixelSize: 11
                                color: btnMon2.isSel ? "#38bdf8" : "#94a3b8"
                                text: "2"
                            }
                        }

                        MouseArea {
                            id: mon2Mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: root.showTip("Record Monitor 2 (" + (root.monitors[1] ? root.monitors[1].name : "2") + ")", btnMon2)
                            onExited: root.hideTip()
                            onClicked: {
                                root.activeTarget = "monitor-1"
                                root.activeMode = "singlescreen"
                            }
                        }
                    }
                }

                // Divider
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 24
                    color: "#25ffffff"
                }

                // 3.4 Options Dropdown Trigger (macOS Options ▾)
                Rectangle {
                    id: btnOptions
                    Layout.preferredWidth: optLabelRow.implicitWidth + 18
                    Layout.preferredHeight: 34
                    radius: 10
                    color: root.optionsOpen ? "#35ffffff" : (optBtnMouse.containsMouse ? "#20ffffff" : "transparent")
                    Behavior on color { ColorAnimation { duration: 120 } }

                    RowLayout {
                        id: optLabelRow
                        anchors.centerIn: parent
                        spacing: 6

                        Text {
                            text: "Options"
                            font.family: root.sfFont
                            font.pixelSize: 13
                            color: "#ffffff"
                            renderType: Text.QtRendering
                        }

                        Text {
                            font.family: root.iconFont
                            font.pixelSize: 13
                            color: "#94a3b8"
                            text: "󰅀"
                            renderType: Text.QtRendering
                        }
                    }

                    MouseArea {
                        id: optBtnMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.showTip("Recording Options", btnOptions)
                        onExited: root.hideTip()
                        onClicked: {
                            root.optionsOpen = !root.optionsOpen
                            if (root.optionsOpen) root.refreshAudioDevices()
                            root.hideTip()
                        }
                    }
                }

                // Divider
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 24
                    color: "#25ffffff"
                }

                // 3.5 Action Button: Record (Idle) / Stop with Timer (Recording)
                // Authentic macOS Frosted Charcoal Glass (No Blue Background!)
                Rectangle {
                    id: btnRecord
                    Layout.preferredWidth: actBtnRow.implicitWidth + 24
                    Layout.preferredHeight: 36
                    radius: 14
                    // Cohesive dark charcoal glass when idle, crimson red when active
                    color: root.isRecording ? (actRecMouse.containsMouse ? "#dc2626" : "#ef4444")
                                            : (actRecMouse.containsMouse ? "#32323c" : "#24242c")
                    border.color: root.isRecording ? "#60ffffff" : (actRecMouse.containsMouse ? "#55ffffff" : "#35ffffff")
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 150 } }

                    scale: actRecMouse.pressed ? 0.96 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120 } }

                    RowLayout {
                        id: actBtnRow
                        anchors.centerIn: parent
                        spacing: 8

                        // Red Record Dot / Stop Square
                        Rectangle {
                            Layout.preferredWidth: root.isRecording ? 10 : 8
                            Layout.preferredHeight: root.isRecording ? 10 : 8
                            radius: root.isRecording ? 2 : 4
                            color: root.isRecording ? "#ffffff" : "#ef4444"

                            // Subtle pulse while recording
                            SequentialAnimation on opacity {
                                running: root.isRecording
                                loops: Animation.Infinite
                                NumberAnimation { to: 0.3; duration: 500 }
                                NumberAnimation { to: 1.0; duration: 500 }
                            }
                        }

                        Text {
                            text: root.isRecording ? "Stop (" + root.formatTime(root.elapsedSeconds) + ")" : "Record"
                            font.family: root.sfFontBold
                            font.pixelSize: 13
                            color: "#ffffff"
                            renderType: Text.QtRendering
                        }
                    }

                    MouseArea {
                        id: actRecMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.showTip(root.isRecording ? "Stop Recording & Save" : "Start Recording (60 FPS)", btnRecord)
                        onExited: root.hideTip()
                        onClicked: {
                            if (root.isRecording) {
                                root.stopRecording()
                            } else {
                                root.startRecording()
                            }
                        }
                    }
                }
            }
        }
    }
}
