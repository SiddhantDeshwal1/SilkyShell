import QtQuick
import QtQuick.Layouts
import QtQml.Models
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris

// ─────────────────────────────────────────────────────────────────────────────
// MediaMenu — Expanded Liquid Glass Menu connected to Media Island.
//
// Features:
//   1. Upper Left (Music Player Card — 282px height):
//      - Elevated Track Title & Artist
//      - Arrow-key Source Switcher (◀ Player 1/N ▶)
//      - Cinematic full-card Artwork background with dynamic fallback gradient
//      - High-precision Liquid Wave Progress Slider (nudged baseline, 80% wider, 150px taper, 8px track)
//      - Large 14px timeline timestamp text with dedicated spacing
//      - Spring-animated transport controls (Skip Prev, Play/Pause, Skip Next)
//
//   2. Upper Right (Sound & Output Card — 282px height matching Music Player):
//      - 15px bold header & 15px device names
//      - Master Volume slider & mute toggle for default output device
//      - Output Devices List (Pipewire Sinks) with Nerd Font icons (🎧 🔊 󰂯 󰍹)
//      - Live device switcher (sets default audio sink with wpctl set-default)
//
//   3. Lower Section (Audio Visualizer Card — 115px compact height):
//      - 14px bold header & 14px bold theme switcher
//      - Wide Cava Audio Visualizer Canvas with 3 themes:
//        1: Vertical Bars | 2: Symmetric Mirror | 3: Wave Bezier
//      - Smooth rotating rainbow gradient & animated theme switcher
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    property bool open: false
    property var activePlayer: null
    property var cavaBars: []
    property int vizStyle: 0          // 0=vertical, 1=symmetric, 2=wave
    property real islandVol: 0
    property bool islandMuted: false
    property bool mouseInIsland: false

    // ── Per-Player Volume & High-Precision Timeline Tracking ──────────
    property real playerVol: 1.0
    property bool playerMuted: false
    property real savedPlayerVol: 1.0
    property real playerPos: 0
    property real playerLength: 0
    property bool isScrubbing: false
    property real scrubPos: 0
    property real lastSyncPos: 0
    property real lastSyncTime: 0
    property real lastSeekTime: 0
    property bool trackChanging: false
    property string lastKnownTrackId: ""
    property real timelineWavePhase: 0

    readonly property string sfFont: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    function getCurrentCalculatedPos() {
        if (root.isScrubbing) {
            return root.scrubPos
        }
        const isPlaying = root.effectivePlayer ? root.effectivePlayer.isPlaying : false
        if (!isPlaying || root.lastSyncTime <= 0) {
            return Math.max(0, root.lastSyncPos)
        }
        const elapsedSecs = (Date.now() - root.lastSyncTime) / 1000.0
        let current = root.lastSyncPos + Math.max(0, elapsedSecs)
        if (root.playerLength > 0 && current > root.playerLength) {
            current = root.playerLength
        }
        return current
    }

    NumberAnimation on timelineWavePhase {
        from: 0; to: Math.PI * 2
        duration: 2000
        loops: Animation.Infinite
        running: root.open
    }

    // ── Inline Marquee Text Component (Smooth Right-to-Left Scroll) ───
    component MarqueeText: Item {
        id: marqueeRoot
        implicitHeight: txt.implicitHeight + 2
        clip: true

        property string text: ""
        property font font: Qt.font({ family: root.sfFont })
        property color color: "#ffffff"
        property bool fontBold: false
        property int fontPixelSize: 15

        Text {
            id: txt
            font.family: marqueeRoot.font.family || root.sfFont
            font.pixelSize: marqueeRoot.fontPixelSize
            font.bold: marqueeRoot.fontBold
            color: marqueeRoot.color
            text: marqueeRoot.text
            renderType: Text.NativeRendering
            x: marqueeAnim.running ? animX : 0

            property real animX: 0

            SequentialAnimation on animX {
                id: marqueeAnim
                running: root.open && txt.implicitWidth > marqueeRoot.width
                loops: Animation.Infinite

                PauseAnimation { duration: 1500 }
                NumberAnimation {
                    from: 0
                    to: -(txt.implicitWidth - marqueeRoot.width + 16)
                    duration: Math.max(2500, (txt.implicitWidth - marqueeRoot.width) * 35)
                    easing.type: Easing.Linear
                }
                PauseAnimation { duration: 1500 }
                NumberAnimation {
                    from: -(txt.implicitWidth - marqueeRoot.width + 16)
                    to: 0
                    duration: 500
                    easing.type: Easing.OutCubic
                }
            }
        }

        onTextChanged: {
            txt.animX = 0
            marqueeAnim.restart()
        }
    }

    // ── Player Source Selection ─────────────────────────────────────────
    property string selectedPlayerDbusName: ""
    property int selectedPlayerIndex: 0
    property bool userManualSelection: false

    function validPlayerList() {
        return root.uniqueAppPlayers || []
    }

    function selectPlayerExplicitly(dbusName) {
        root.userManualSelection = true
        root.selectedPlayerDbusName = dbusName
        const apps = root.uniqueAppPlayers
        for (let i = 0; i < apps.length; i++) {
            if (apps[i] && apps[i].dbusName === dbusName) {
                root.selectedPlayerIndex = i
                break
            }
        }
        root.playerSelected(dbusName)
        root.handleTrackMetadataUpdate()
    }

    // List of active MPRIS players (filtering phantom proxy and duplicate daemons)
    readonly property var uniqueAppPlayers: {
        const list = Mpris.players.values || []
        let hasDirectBrowser = false
        for (let i = 0; i < list.length; i++) {
            const p = list[i]
            if (!p) continue
            const db = (p.dbusName || "").toLowerCase()
            if (db.includes("chromium") || db.includes("chrome") || db.includes("firefox") || db.includes("brave") || db.includes("edge") || db.includes("opera") || db.includes("vivaldi")) {
                hasDirectBrowser = true
                break
            }
        }

        const seenDbus = new Set()
        const res = []
        for (let i = 0; i < list.length; i++) {
            const p = list[i]
            if (!p) continue
            const db = (p.dbusName || "").toLowerCase()
            const id = (p.identity || p.desktopEntry || p.dbusName || "player").toLowerCase().trim()

            if (db.includes("playerctld") || id.includes("playerctld"))
                continue

            if (hasDirectBrowser && (db.includes("plasma-browser-integration") || id.includes("plasma browser integration")))
                continue

            if (!seenDbus.has(p.dbusName)) {
                seenDbus.add(p.dbusName)
                res.push(p)
            }
        }
        return res
    }

    // Reactive binding for effectivePlayer — actively playing players take priority
    readonly property var effectivePlayer: {
        const apps = root.uniqueAppPlayers
        if (!apps || apps.length === 0) return root.activePlayer

        // 1. If user explicitly selected a player with arrows, respect manual selection:
        if (root.userManualSelection && root.selectedPlayerDbusName !== "") {
            for (let i = 0; i < apps.length; i++) {
                if (apps[i] && apps[i].dbusName === root.selectedPlayerDbusName) {
                    return apps[i]
                }
            }
        }

        // 2. If any player is actively playing, it takes immediate priority:
        for (let i = 0; i < apps.length; i++) {
            if (apps[i] && apps[i].isPlaying) {
                return apps[i]
            }
        }

        // 3. When paused, stay locked on selected/recent player:
        if (root.selectedPlayerDbusName !== "") {
            for (let i = 0; i < apps.length; i++) {
                if (apps[i] && apps[i].dbusName === root.selectedPlayerDbusName) {
                    return apps[i]
                }
            }
        }

        const idx = Math.max(0, Math.min(root.selectedPlayerIndex, apps.length - 1))
        return apps[idx] || root.activePlayer
    }

    readonly property string effectiveArtUrl: {
        const p = root.effectivePlayer
        if (!p) return ""
        const u = p.trackArtUrl || p.artUrl || ""
        return root.sanitizeArtUrl(u)
    }

    // Reactively track changes across ALL players so newly played players take focus
    Instantiator {
        model: Mpris.players.values
        delegate: Connections {
            target: modelData
            function onIsPlayingChanged() {
                if (modelData && modelData.isPlaying) {
                    const db = (modelData.dbusName || "").toLowerCase()
                    if (db.includes("playerctld")) return
                    if (root.selectedPlayerDbusName !== modelData.dbusName) {
                        root.userManualSelection = false
                        root.selectedPlayerDbusName = modelData.dbusName
                        const apps = root.uniqueAppPlayers
                        for (let i = 0; i < apps.length; i++) {
                            if (apps[i] && apps[i].dbusName === modelData.dbusName) {
                                root.selectedPlayerIndex = i
                                break
                            }
                        }
                        root.playerSelected(modelData.dbusName)
                        root.handleTrackMetadataUpdate()
                    } else {
                        root.queryPlayerInfo()
                    }
                }
            }
            function onPlaybackStateChanged() {
                if (modelData && modelData.isPlaying && root.selectedPlayerDbusName !== modelData.dbusName) {
                    const db = (modelData.dbusName || "").toLowerCase()
                    if (db.includes("playerctld")) return
                    root.userManualSelection = false
                    root.selectedPlayerDbusName = modelData.dbusName
                    const apps = root.uniqueAppPlayers
                    for (let i = 0; i < apps.length; i++) {
                        if (apps[i] && apps[i].dbusName === modelData.dbusName) {
                            root.selectedPlayerIndex = i
                            break
                        }
                    }
                    root.playerSelected(modelData.dbusName)
                    root.handleTrackMetadataUpdate()
                } else if (modelData && modelData.dbusName === root.selectedPlayerDbusName) {
                    root.queryPlayerInfo()
                }
            }
            function onTrackTitleChanged() {
                if (modelData && (modelData.isPlaying || modelData.dbusName === root.selectedPlayerDbusName)) {
                    root.handleTrackMetadataUpdate()
                }
            }
            function onTrackArtUrlChanged() {
                if (modelData && (modelData.isPlaying || modelData.dbusName === root.selectedPlayerDbusName)) {
                    root.extractColorsFromCurrentTrack()
                }
            }
        }
    }

    // Keep selectedPlayerIndex and selectedPlayerDbusName in sync when player list changes
    Connections {
        target: Mpris.players
        function onValuesChanged() {
            const apps = root.uniqueAppPlayers
            const n = apps ? apps.length : 0
            if (n === 0) {
                root.selectedPlayerIndex = 0
                root.selectedPlayerDbusName = ""
                return
            }
            // Preserve selectedPlayerDbusName if it still exists in the player list
            if (root.selectedPlayerDbusName !== "") {
                for (let i = 0; i < n; i++) {
                    if (apps[i] && apps[i].dbusName === root.selectedPlayerDbusName) {
                        root.selectedPlayerIndex = i
                        return
                    }
                }
            }
            // If any player is playing, select it
            for (let i = 0; i < n; i++) {
                if (apps[i] && apps[i].isPlaying) {
                    root.selectedPlayerIndex = i
                    root.selectedPlayerDbusName = apps[i].dbusName
                    return
                }
            }
            // Fallback to activePlayer if valid
            const activeDb = root.activePlayer ? root.activePlayer.dbusName : ""
            if (activeDb) {
                for (let i = 0; i < n; i++) {
                    if (apps[i] && apps[i].dbusName === activeDb) {
                        root.selectedPlayerIndex = i
                        root.selectedPlayerDbusName = activeDb
                        return
                    }
                }
            }
            root.selectedPlayerIndex = 0
            root.selectedPlayerDbusName = apps[0] ? apps[0].dbusName : ""
        }
    }

    Component.onCompleted: {
        const apps = root.uniqueAppPlayers
        if (root.selectedPlayerDbusName === "" && apps.length > 0) {
            for (let i = 0; i < apps.length; i++) {
                if (apps[i] && apps[i].isPlaying) {
                    root.selectedPlayerDbusName = apps[i].dbusName
                    root.selectedPlayerIndex = i
                    break
                }
            }
            if (root.selectedPlayerDbusName === "" && apps[0]) {
                root.selectedPlayerDbusName = apps[0].dbusName
                root.selectedPlayerIndex = 0
            }
        }
    }

    // ── Smooth Bright Rotating Visualizer Gradient Phase ──────────────
    property real vizPhase: 0

    NumberAnimation on vizPhase {
        from: 0; to: 360
        duration: 10000
        loops: Animation.Infinite
        running: root.isMenuVisible
    }

    // ── Adaptive Ambient Gradient Colors ──────────────────────────────
    property color gradColor1: "#d79921"
    property color gradColor2: "#cba6f7"
    property color gradColor3: "#89b4fa"

    // Dynamic Luminance Adaptive Color for Transport Buttons (White on dark, Black on white/light bg)
    readonly property real bgLuminance: {
        const c1 = root.gradColor1
        const c2 = root.gradColor2
        return (0.2126 * (c1.r + c2.r) / 2 + 0.7152 * (c1.g + c2.g) / 2 + 0.0722 * (c1.b + c2.b) / 2)
    }
    readonly property bool isBgBright: bgLuminance > 0.60
    readonly property color transportColor: isBgBright ? "#11111b" : "#ffffff"

    signal changeVizStyle(int newStyle)
    signal playerSelected(string dbusName)
    signal mediaOutputClicked()

    anchors {
        top: true
        left: true
        right: true
    }

    // Flush below top bar (28px)
    WlrLayershell.margins.top: 28

    // Window surface covers the screen below bar when open or animating
    implicitWidth: Screen.width
    implicitHeight: Screen.height - 28

    color: "transparent"

    // Overlay layer shell window, exclusiveZone -1 so struts aren't modified
    exclusiveZone: -1
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-media-menu"
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    property real islandCenterX: Screen.width / 2

    // ── Unified 60fps Motion Blur & Animation Engine ──────────────────
    property real animProgress: 0.0
    property real motionBlurAmount: 0.0
    readonly property bool isMenuVisible: root.open || openAnim.running || closeAnim.running || root.animProgress > 0.001

    visible: root.isMenuVisible

    ParallelAnimation {
        id: openAnim
        NumberAnimation {
            target: root
            property: "animProgress"
            from: root.animProgress
            to: 1.0
            duration: 420
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.34, 1.35, 0.22, 1.0, 1.0, 1.0]  // Elastic spring overshoot (buds out from island)
        }
        SequentialAnimation {
            NumberAnimation {
                target: root
                property: "motionBlurAmount"
                from: 0.0; to: 14.0
                duration: 120
                easing.type: Easing.OutQuad
            }
            NumberAnimation {
                target: root
                property: "motionBlurAmount"
                from: 14.0; to: 0.0
                duration: 300
                easing.type: Easing.OutCubic
            }
        }
    }

    ParallelAnimation {
        id: closeAnim
        NumberAnimation {
            target: root
            property: "animProgress"
            from: root.animProgress
            to: 0.0
            duration: 240
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.36, 0.0, 0.72, 0.15, 1.0, 1.0]  // Snappy magnetic snap back into island
        }
        SequentialAnimation {
            NumberAnimation {
                target: root
                property: "motionBlurAmount"
                from: 0.0; to: 10.0
                duration: 90
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                target: root
                property: "motionBlurAmount"
                from: 10.0; to: 0.0
                duration: 150
                easing.type: Easing.OutQuad
            }
        }
    }

    onOpenChanged: {
        if (open) {
            if (closeAnim.running) closeAnim.stop()
            if (!openAnim.running && animProgress < 1.0) openAnim.restart()
        } else {
            if (openAnim.running) openAnim.stop()
            if (!closeAnim.running && animProgress > 0.0) closeAnim.restart()
        }
    }

    IpcHandler {
        target: "mediamenu"
        function open() { root.openMenu() }
        function close() { root.close() }
        function toggle() { root.open ? root.close() : root.openMenu() }
    }

    // ── Menu Open / Close Control ─────────────────────────────────────
    function openMenu() {
        if (closeAnim.running) closeAnim.stop()
        open = true
        extractColorsFromCurrentTrack()
        queryPlayerInfo()
        openAnim.restart()
    }

    function close() {
        if (openAnim.running) openAnim.stop()
        open = false
        closeAnim.restart()
    }

    function formatSecs(secs) {
        if (isNaN(secs) || secs <= 0) return "0:00"
        const total = Math.floor(secs)
        const m = Math.floor(total / 60)
        const s = total % 60
        const h = Math.floor(m / 60)
        if (h > 0) {
            const rm = m % 60
            return h + ":" + (rm < 10 ? "0" : "") + rm + ":" + (s < 10 ? "0" : "") + s
        }
        return m + ":" + (s < 10 ? "0" : "") + s
    }

    // ── Dedicated Process Runner for Volume Actions ──────────────────
    Process {
        id: volumeProc
        onExited: function(code, status) { running = false }
    }

    Timer {
        id: volumeRestartTimer
        interval: 20
        repeat: false
        property string pendingPlayer: ""
        property string pendingVol: "1.0"
        onTriggered: {
            volumeProc.command = [Paths.script("media-control.sh"), "set-volume", pendingPlayer, pendingVol]
            volumeProc.running = true
        }
    }

    function setPlayerVolume(val) {
        const clamped = Math.max(0, Math.min(1.0, val))
        root.playerVol = clamped
        root.playerMuted = (clamped === 0)
        if (root.effectivePlayer) {
            try { root.effectivePlayer.volume = clamped } catch(e) {}
        }
        const p = root.effectivePlayer ? (root.effectivePlayer.dbusName || "") : ""
        if (p) {
            if (volumeProc.running) volumeProc.running = false
            volumeRestartTimer.pendingPlayer = p
            volumeRestartTimer.pendingVol = clamped.toFixed(2)
            volumeRestartTimer.restart()
        }
    }

    function togglePlayerMute() {
        if (root.playerMuted || root.playerVol === 0) {
            setPlayerVolume(root.savedPlayerVol > 0 ? root.savedPlayerVol : 0.8)
        } else {
            root.savedPlayerVol = root.playerVol
            setPlayerVolume(0)
        }
    }

    // ── Dedicated Process Runner for Seek Actions ────────────────────
    Process {
        id: seekProc
        onExited: function(code, status) { running = false }
    }

    Timer {
        id: seekRestartTimer
        interval: 15
        repeat: false
        property string pendingPlayer: ""
        property string pendingPos: "0"
        onTriggered: {
            seekProc.command = [Paths.script("media-control.sh"), "set-position", pendingPlayer, pendingPos]
            seekProc.running = true
        }
    }

    Timer {
        id: seekConfirmTimer
        interval: 350
        repeat: false
        onTriggered: root.queryPlayerInfo()
    }

    function seekPlayer(seconds) {
        const effMax = root.playerLength > 0 ? root.playerLength : Math.max(180, root.lastSyncPos + 60)
        const maxSeek = Math.max(0, effMax > 1.5 ? effMax - 0.5 : effMax)
        const clamped = Math.max(0, Math.min(maxSeek, seconds))

        root.scrubPos = clamped
        root.playerPos = clamped
        root.lastSyncPos = clamped
        root.lastSyncTime = Date.now()
        root.lastSeekTime = Date.now()

        const p = root.effectivePlayer ? (root.effectivePlayer.dbusName || "") : ""
        if (p) {
            if (seekProc.running) seekProc.running = false
            seekRestartTimer.pendingPlayer = p
            seekRestartTimer.pendingPos = clamped.toFixed(2)
            seekRestartTimer.restart()
            seekConfirmTimer.restart()
        }
    }

    // ── Dedicated Player Info Process (Position, Duration, Volume) ────
    Process {
        id: playerInfoProc
        stdout: SplitParser {
            onRead: function(line) {
                const parts = line.trim().split(/\s+/)
                if (parts.length >= 4) {
                    const status = parts[0]
                    const pos = parseFloat(parts[1]) || 0
                    const len = parseFloat(parts[2]) || 0
                    const vol = parseFloat(parts[3]) || 1.0

                    if (len > 0) {
                        root.playerLength = len
                    }

                    const now = Date.now()
                    const timeSinceSeek = now - root.lastSeekTime
                    const seekingRecent = root.lastSeekTime > 0 && (timeSinceSeek < 1200)

                    if (!root.isScrubbing && !root.trackChanging) {
                        if (seekingRecent) {
                            // Only accept if pos > 0 or if we sought close to the start (< 5.0s)
                            if (pos > 0 || root.lastSyncPos < 5.0) {
                                root.lastSyncPos = pos
                                root.lastSyncTime = now
                                root.playerPos = pos
                                root.lastSeekTime = 0
                            }
                        } else {
                            if (pos > 0) {
                                root.lastSyncPos = pos
                                root.lastSyncTime = now
                                root.playerPos = pos
                            }
                        }
                    }

                    if (typeof playerVolSliderItem !== "undefined" && !playerVolSliderItem.sliderPressed) {
                        root.playerVol = vol
                    }
                }
            }
        }
    }

    function queryPlayerInfo() {
        if (!root.effectivePlayer) return
        const p = root.effectivePlayer

        // Native Quickshell Mpris properties (0 subprocess overhead)
        if (p.length !== undefined && p.length > 0) {
            root.playerLength = p.length
        }

        const now = Date.now()
        const timeSinceSeek = now - root.lastSeekTime
        const seekingRecent = root.lastSeekTime > 0 && (timeSinceSeek < 1200)

        if (!root.isScrubbing && !root.trackChanging) {
            let pos = (p.positionSupported && p.position !== undefined) ? p.position : 0
            if (pos > 0 || !seekingRecent) {
                root.lastSyncPos = pos
                root.lastSyncTime = now
                root.playerPos = pos
                if (seekingRecent) root.lastSeekTime = 0
            }
        }

        if (p.volume !== undefined && typeof playerVolSliderItem !== "undefined" && !playerVolSliderItem.sliderPressed) {
            root.playerVol = p.volume
        }

        // Optional fallback: only if player does not support native position
        if (!p.positionSupported && p.dbusName && !playerInfoProc.running) {
            playerInfoProc.command = [Paths.script("media-control.sh"), "get-info", p.dbusName]
            playerInfoProc.running = true
        }
    }

    Timer {
        id: playerInfoTimer
        interval: 800   // 800ms gives fast initial sync and accurate continuous tracking without process flooding
        repeat: true
        running: root.open && root.effectivePlayer !== null && !root.isScrubbing && !root.trackChanging
        onTriggered: root.queryPlayerInfo()
    }

    Timer {
        id: playerPosInterpolateTimer
        interval: 200   // 200ms (5fps) smooth clock interpolation between polls
        repeat: true
        running: root.open && root.effectivePlayer !== null && root.effectivePlayer.isPlaying && !root.isScrubbing
        onTriggered: {
            root.playerPos = root.getCurrentCalculatedPos()
        }
    }

    Timer {
        id: trackChangeTimer
        interval: 450
        repeat: false
        onTriggered: {
            root.trackChanging = false
            root.queryPlayerInfo()
        }
    }

    // Process executor for wpctl and playerctl actions
    Process {
        id: cmdProc
        onExited: function(code, status) { running = false }
    }

    function runCmd(argv) {
        if (cmdProc.running) cmdProc.running = false
        cmdProc.command = argv
        cmdProc.running = true
    }

    // ── In-Memory Color Palette Cache & Asynchronous Process ─────────
    property var colorCache: ({})
    property string pendingColorUrl: ""

    Process {
        id: colorExtractProc
        stdout: SplitParser {
            onRead: function(line) {
                const parts = line.trim().split(/\s+/)
                if (parts.length >= 3 && parts[0].startsWith("#")) {
                    if (root.pendingColorUrl) {
                        if (!root.colorCache) root.colorCache = {}
                        root.colorCache[root.pendingColorUrl] = [parts[0], parts[1], parts[2]]
                    }
                    const currentUrl = root.sanitizeArtUrl(root.effectivePlayer ? (root.effectivePlayer.trackArtUrl || root.effectivePlayer.artUrl || "") : "")
                    if (currentUrl === root.pendingColorUrl || !currentUrl) {
                        root.gradColor1 = parts[0]
                        root.gradColor2 = parts[1]
                        root.gradColor3 = parts[2]
                    }
                }
            }
        }
    }

    function sanitizeArtUrl(url) {
        if (!url) return ""
        const s = ("" + url).trim()
        if (s.startsWith("/") && !s.startsWith("file://")) {
            return "file://" + s
        }
        return s
    }

    function extractColorsFromCurrentTrack() {
        const rawUrl = root.effectivePlayer ? (root.effectivePlayer.trackArtUrl || root.effectivePlayer.artUrl || "") : ""
        const url = root.sanitizeArtUrl(rawUrl)
        if (!url) {
            root.gradColor1 = "#d79921"
            root.gradColor2 = "#cba6f7"
            root.gradColor3 = "#89b4fa"
            return
        }
        if (root.colorCache && root.colorCache[url]) {
            const cached = root.colorCache[url]
            root.gradColor1 = cached[0]
            root.gradColor2 = cached[1]
            root.gradColor3 = cached[2]
            return
        }
        root.pendingColorUrl = url
        if (colorExtractProc.running) colorExtractProc.running = false
        colorExtractProc.command = ["python3", Paths.script("extract-colors.py"), url]
        colorExtractProc.running = true
    }

    function handleTrackMetadataUpdate() {
        const title = root.effectivePlayer ? (root.effectivePlayer.trackTitle || "") : ""
        const dbus = root.effectivePlayer ? (root.effectivePlayer.dbusName || "") : ""
        if (!dbus) return

        if (title && title.trim().length > 0) {
            const id = dbus + ":" + title.trim()
            if (root.lastKnownTrackId !== "" && id !== root.lastKnownTrackId) {
                root.lastKnownTrackId = id
                root.lastSyncPos = 0
                root.lastSyncTime = Date.now()
                root.lastSeekTime = 0
                root.playerPos = 0
                root.playerLength = 0
            } else if (root.lastKnownTrackId === "") {
                root.lastKnownTrackId = id
            }
        }
        root.extractColorsFromCurrentTrack()
        root.queryPlayerInfo()
    }

    onEffectivePlayerChanged: root.handleTrackMetadataUpdate()

    Connections {
        target: root.effectivePlayer
        function onTrackArtUrlChanged() { root.extractColorsFromCurrentTrack() }
        function onTrackTitleChanged() { root.handleTrackMetadataUpdate() }
        function onPositionChanged() {
            if (!root.isScrubbing && root.effectivePlayer && root.effectivePlayer.positionSupported) {
                const p = root.effectivePlayer.position
                if (p >= 0 && Math.abs(p - root.playerPos) > 1.2) {
                    root.lastSyncPos = p
                    root.lastSyncTime = Date.now()
                    root.playerPos = p
                }
            }
        }
        function onPlaybackStateChanged() {
            const isPlaying = root.effectivePlayer ? root.effectivePlayer.isPlaying : false
            if (!isPlaying) {
                root.lastSyncPos = root.getCurrentCalculatedPos()
                root.lastSyncTime = Date.now()
                root.playerPos = root.lastSyncPos
            } else {
                root.lastSyncTime = Date.now()
            }
            root.queryPlayerInfo()
        }
    }

    // ── Dedicated Process Runner for Transport Actions ───────────────
    Process {
        id: mediaActionProc
        onExited: function(code, status) { running = false }
    }

    // Delay between stopping and restarting the process
    Timer {
        id: mediaActionRestartTimer
        interval: 30
        repeat: false
        property string pendingAction: ""
        property string pendingPlayer: ""
        onTriggered: {
            mediaActionProc.command = [Paths.script("media-control.sh"), pendingAction, pendingPlayer]
            mediaActionProc.running = true
        }
    }

    function dispatchAction(action) {
        let handled = false
        if (root.effectivePlayer) {
            try {
                if (action === "play-pause" || action === "toggle") {
                    if (root.effectivePlayer.canTogglePlaying) {
                        root.effectivePlayer.togglePlaying()
                        handled = true
                    } else if (root.effectivePlayer.isPlaying) {
                        root.effectivePlayer.pause()
                        handled = true
                    } else {
                        root.effectivePlayer.play()
                        handled = true
                    }
                } else if (action === "next") {
                    root.effectivePlayer.next()
                    handled = true
                } else if (action === "prev" || action === "previous") {
                    root.effectivePlayer.previous()
                    handled = true
                }
            } catch(e) { handled = false }
        }
        if (!handled) {
            const p = root.effectivePlayer ? (root.effectivePlayer.dbusName || "") : ""
            root.runCmd([Paths.script("media-control.sh"), action, p])
        }
    }

    // ── Robust Playback Control Functions ─────────────────────────────
    function togglePlayPause() {
        const isPlaying = root.effectivePlayer ? root.effectivePlayer.isPlaying : false
        if (isPlaying) {
            root.lastSyncPos = root.getCurrentCalculatedPos()
            root.lastSyncTime = Date.now()
            root.playerPos = root.lastSyncPos
        } else {
            root.lastSyncTime = Date.now()
            root.playerPos = root.lastSyncPos
        }
        dispatchAction("play-pause")
    }
    function previousTrack() {
        if (root.effectivePlayer && root.effectivePlayer.canGoPrevious === false) {
            return
        }
        dispatchAction("prev")
    }
    function nextTrack() {
        if (root.effectivePlayer && root.effectivePlayer.canGoNext === false) {
            return
        }
        dispatchAction("next")
    }

    // ── Pipewire Sinks & Playback Streams ──────────────────────────────
    PwObjectTracker {
        id: pwSinkTracker
        objects: root.isMenuVisible ? Pipewire.nodes.values : []
    }

    readonly property var playbackStreams: {
        if (!root.isMenuVisible) return []
        const nodes = Pipewire.nodes.values || []
        return nodes.filter(function(n) {
            if (!n || !n.isStream || !n.audio) return false
            const cls = (n.properties && n.properties["media.class"]) || ""
            if (cls === "Stream/Output/Audio") return true
            if (cls === "" && !n.isSink && n.audio) return true
            if (n.name && n.name !== "cava" && !n.name.includes("capture") && !cls.includes("Input") && !cls.includes("Video")) return true
            return false
        })
    }

    property var appIconCache: ({})

    function resolveAppIcon(node) {
        if (!node) return ""
        const props = node.properties || {}
        const appName = props["application.name"] || node.name || ""
        const bin = props["application.process.binary"] || ""
        const iconName = props["application.icon-name"] || ""
        const cacheKey = iconName + "|" + bin + "|" + appName

        if (root.appIconCache && root.appIconCache[cacheKey] !== undefined) {
            return root.appIconCache[cacheKey]
        }

        let resolved = ""
        if (iconName) {
            resolved = Quickshell.iconPath(iconName, true) || ""
        }
        if (!resolved && bin) {
            resolved = Quickshell.iconPath(bin, true) || ""
        }
        if (!resolved && appName) {
            resolved = Quickshell.iconPath(appName.toLowerCase().replace(/\s+/g, "-"), true) || ""
        }
        if (!resolved) {
            const de = DesktopEntries.applications.values.find(function(a) {
                const n = (a.name || "").toLowerCase()
                const id = (a.id || "").toLowerCase()
                const b = bin.toLowerCase()
                const an = appName.toLowerCase()
                return (b && (id.includes(b) || n.includes(b))) || (an && (id.includes(an) || n.includes(an)))
            })
            if (de && de.icon) {
                resolved = Quickshell.iconPath(de.icon, true) || ""
            }
        }
        if (!root.appIconCache) root.appIconCache = {}
        root.appIconCache[cacheKey] = resolved
        return resolved
    }

    function getAppGlyph(name) {
        const id = (name || "").toLowerCase()
        if (id.includes("spotify")) return "󰓇"
        if (id.includes("chrome") || id.includes("chromium") || id.includes("youtube")) return "󰅟"
        if (id.includes("firefox")) return "󰈹"
        if (id.includes("mpv") || id.includes("vlc")) return "󰕼"
        if (id.includes("discord")) return "󰙯"
        if (id.includes("music") || id.includes("apple") || id.includes("rhythmbox") || id.includes("cmus")) return "󰎆"
        return "󰎆"
    }

    function getAppIcon(identity) {
        const id = (identity || "").toLowerCase()
        if (id.includes("spotify")) return "󰓇"
        if (id.includes("music") || id.includes("apple")) return "󰎆"
        if (id.includes("firefox")) return "󰈹"
        if (id.includes("chrome") || id.includes("chromium") || id.includes("youtube")) return "󰅟"
        if (id.includes("mpv")) return "󰕼"
        if (id.includes("vlc")) return "󰕼"
        if (id.includes("rhythmbox") || id.includes("cmus")) return "󰎆"
        return "󰎆"
    }

    // ── Backdrop MouseArea — transparent, only closes when clicking OUTSIDE panelCard ──
    MouseArea {
        id: backdropMouse
        anchors.fill: parent
        hoverEnabled: true
        z: 0
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        focus: root.open

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
            }
        }

        onClicked: function(mouse) {
            // Guard: only close if the click lands outside the card bounds
            const cx = panelCard.x, cy = panelCard.y
            const cw = panelCard.width, ch = panelCard.height
            if (mouse.x < cx || mouse.x > cx + cw || mouse.y < cy || mouse.y > cy + ch) {
                root.close()
            }
        }
    }

    // ── Seamless Connected Liquid Glass Panel Card ─────────────────────
    Rectangle {
        id: panelCard
        // Dynamically centered horizontally relative to Media Island's center
        x: {
            const targetX = root.islandCenterX - width / 2
            const minX = 16
            const maxX = Screen.width - width - 16
            return Math.max(minX, Math.min(maxX, targetX))
        }
        anchors.top: parent.top
        anchors.topMargin: 8

        width: 780
        implicitHeight: contentCol.implicitHeight + 32

        // Top and bottom corners morph with spring expansion
        topLeftRadius: 18 + Math.round(4 * root.animProgress)
        topRightRadius: 18 + Math.round(4 * root.animProgress)
        bottomLeftRadius: 18 + Math.round(4 * root.animProgress)
        bottomRightRadius: 18 + Math.round(4 * root.animProgress)

        // Transparent liquid glass — dark tint in dark mode, clear frosted glass in light mode
        color: Theme.panelBgColor
        border.color: Theme.panelBorderColor
        border.width: 1.5
        Behavior on color { ColorAnimation { duration: 200 } }
        Behavior on border.color { ColorAnimation { duration: 200 } }
        clip: true
        z: 1

        opacity: Math.min(1.0, Math.max(0.0, root.animProgress * 1.35))
        scale: 0.90 + 0.10 * root.animProgress
        transformOrigin: Item.Top

        transform: [
            Rotation {
                origin.x: panelCard.width / 2
                origin.y: 0
                axis.x: 1
                axis.y: 0
                axis.z: 0
                angle: -14.0 * Math.pow(Math.max(0.0, 1.0 - root.animProgress), 1.5)
            },
            Translate {
                y: -30.0 * Math.max(0.0, 1.0 - root.animProgress)
            }
        ]

        // 60fps Directional Motion Blur layer during dropdown & retract
        layer.enabled: root.motionBlurAmount > 0.05
        layer.effect: DirectionalBlur {
            angle: 90.0  // Vertical motion vector
            length: root.motionBlurAmount
            samples: 16
            transparentBorder: true
        }

        // Specular shine top gradient overlay
        Rectangle {
            anchors.fill: parent
            topLeftRadius: 18 + Math.round(4 * root.animProgress)
            topRightRadius: 18 + Math.round(4 * root.animProgress)
            bottomLeftRadius: 22
            bottomRightRadius: 22
            z: 0
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#2effffff" }
                GradientStop { position: 0.35; color: "#0dffffff" }
                GradientStop { position: 1.0; color: "#00ffffff" }
            }
        }

        // Inner rim highlight
        Rectangle {
            anchors.fill: parent
            anchors.margins: 1
            topLeftRadius: 17 + Math.round(4 * root.animProgress)
            topRightRadius: 17 + Math.round(4 * root.animProgress)
            bottomLeftRadius: 21
            bottomRightRadius: 21
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
            anchors.topMargin: 16
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.bottomMargin: 16
            spacing: 14
            z: 2

            // ─────────────────────────────────────────────────────────
            // TOP SECTION: SPLIT LEFT (MUSIC) & RIGHT (SOUND)
            // ─────────────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 16

                opacity: Math.min(1.0, Math.max(0.0, (root.animProgress - 0.04) / 0.96))
                transform: Translate {
                    y: -(1.0 - root.animProgress) * 14
                }

                // ═════════════════════════════════════════════════════
                // UPPER LEFT: MUSIC PLAYER CARD (260px height)
                // ═════════════════════════════════════════════════
                Rectangle {
                    id: musicCard
                    Layout.fillWidth: true
                    Layout.preferredWidth: 440
                    implicitHeight: 260
                    Layout.alignment: Qt.AlignTop
                    radius: 24
                    color: "#00000000"
                    clip: true
                    scale: 0.94 + 0.06 * Math.min(1.0, root.animProgress * 1.08)
                    transformOrigin: Item.TopLeft

                    // ── Layer 1: Artwork with matching gradient filler & dark dim ──
                    Item {
                        id: layer1
                        anchors.fill: parent

                        layer.enabled: true
                        layer.effect: OpacityMask {
                            maskSource: Rectangle {
                                width: layer1.width
                                height: layer1.height
                                radius: musicCard.radius
                            }
                        }

                        // Dynamic gradient background for empty spaces / fallback
                        Rectangle {
                            anchors.fill: parent
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: root.gradColor1 }
                                GradientStop { position: 0.5; color: root.gradColor2 }
                                GradientStop { position: 1.0; color: root.gradColor3 }
                            }
                        }

                        // Artwork image (fit to card completely with smooth opacity transition)
                        Image {
                            id: cardArtBg
                            anchors.fill: parent
                            source: root.effectiveArtUrl
                            fillMode: Image.PreserveAspectCrop
                            smooth: true
                            asynchronous: true
                            cache: true
                            opacity: (status === Image.Ready && source !== "") ? 1.0 : 0.0
                            Behavior on opacity {
                                NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                            }
                        }

                        // Heavy dim overlay (~65% black) for crisp typography legibility
                        Rectangle {
                            anchors.fill: parent
                            radius: musicCard.radius
                            color: "#a6000000"
                        }
                    }

                    // ── Layer 2: Player Controls & Timeline Content ──
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 4
                        z: 2

                        // ── Row 1: Header — Source Switcher (< Player N/M >) ──
                        RowLayout {
                            Layout.fillWidth: true

                            RowLayout {
                                spacing: 8
                                visible: Mpris.players.values.length > 0

                                Item {
                                    width: 22; height: 22
                                    Text {
                                        anchors.centerIn: parent
                                        text: "◀"
                                        color: "#88ffffff"
                                        font.family: root.sfFont
                                        font.pixelSize: 11
                                        renderType: Text.NativeRendering
                                    }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const apps = root.validPlayerList()
                                            if (apps.length <= 1) return
                                            let curr = -1
                                            for (let i = 0; i < apps.length; i++) {
                                                if (root.effectivePlayer && apps[i].dbusName === root.effectivePlayer.dbusName) { curr = i; break }
                                            }
                                            const newIdx = (curr - 1 + apps.length) % apps.length
                                            root.selectPlayerExplicitly(apps[newIdx].dbusName)
                                        }
                                    }
                                }

                                Text {
                                    font.family: root.sfFont
                                    font.pixelSize: 13
                                    font.bold: true
                                    color: "#ccffffff"
                                    renderType: Text.NativeRendering
                                    text: {
                                        const p = root.effectivePlayer
                                        if (!p) return "No Player"
                                        const name = p.identity || p.dbusName || "Media"
                                        const apps = root.validPlayerList()
                                        if (apps.length <= 1) return name
                                        let curr = -1
                                        for (let i = 0; i < apps.length; i++) {
                                            if (apps[i].dbusName === p.dbusName) { curr = i; break }
                                        }
                                        return name + " (" + (curr + 1) + "/" + apps.length + ")"
                                    }
                                }

                                Item {
                                    width: 22; height: 22
                                    Text {
                                        anchors.centerIn: parent
                                        text: "▶"
                                        color: "#88ffffff"
                                        font.family: root.sfFont
                                        font.pixelSize: 11
                                        renderType: Text.NativeRendering
                                    }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            const apps = root.validPlayerList()
                                            if (apps.length <= 1) return
                                            let curr = -1
                                            for (let i = 0; i < apps.length; i++) {
                                                if (root.effectivePlayer && apps[i].dbusName === (root.effectivePlayer ? root.effectivePlayer.dbusName : "")) { curr = i; break }
                                            }
                                            const newIdx = (curr + 1) % apps.length
                                            root.selectPlayerExplicitly(apps[newIdx].dbusName)
                                        }
                                    }
                                }
                            }

                            Item { Layout.fillWidth: true }

                            // ── Top Right: Media Output Button ──
                            Rectangle {
                                id: mediaOutputBtn
                                implicitHeight: 28
                                implicitWidth: mediaOutputRow.implicitWidth + 20
                                radius: 14
                                color: mediaOutputTap.pressed ? "#4dffffff" : (mediaOutputHover.hovered ? "#38ffffff" : "#20ffffff")
                                border.color: mediaOutputHover.hovered ? "#60ffffff" : "#30ffffff"
                                border.width: 1
                                clip: true

                                Behavior on color { ColorAnimation { duration: 150 } }
                                Behavior on border.color { ColorAnimation { duration: 150 } }

                                scale: mediaOutputTap.pressed ? 0.92 : (mediaOutputHover.hovered ? 1.04 : 1.0)
                                Behavior on scale {
                                    NumberAnimation {
                                        duration: mediaOutputTap.pressed ? 80 : 180
                                        easing.type: mediaOutputTap.pressed ? Easing.InCubic : Easing.OutBack
                                        easing.overshoot: 1.3
                                    }
                                }

                                RowLayout {
                                    id: mediaOutputRow
                                    anchors.centerIn: parent
                                    spacing: 6

                                    Text {
                                        font.family: root.iconFont
                                        font.pixelSize: 14
                                        color: "#ffffff"
                                        text: "󰓃"
                                        renderType: Text.NativeRendering
                                    }

                                    Text {
                                        font.family: root.sfFont
                                        font.pixelSize: 13
                                        font.bold: true
                                        color: "#ffffff"
                                        text: "Media Output"
                                        renderType: Text.NativeRendering
                                    }
                                }

                                HoverHandler {
                                    id: mediaOutputHover
                                    cursorShape: Qt.PointingHandCursor
                                }

                                TapHandler {
                                    id: mediaOutputTap
                                    onTapped: {
                                        root.mediaOutputClicked()
                                    }
                                }
                            }
                        }

                        // Compact spacer so Title and Artist sit high in the card
                        Item {
                            Layout.fillHeight: true
                            Layout.maximumHeight: 4
                        }

                        // ── Row 2: Track Title & Artist (Elevated & Scaled) ──
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            Text {
                                Layout.fillWidth: true
                                font.family: root.sfFont
                                font.pixelSize: 18
                                font.bold: true
                                color: "#ffffff"
                                elide: Text.ElideRight
                                renderType: Text.NativeRendering
                                text: (root.effectivePlayer && root.effectivePlayer.trackTitle) ? root.effectivePlayer.trackTitle : "No Media Playing"
                            }

                            Text {
                                Layout.fillWidth: true
                                font.family: root.sfFont
                                font.pixelSize: 14
                                color: "#aaffffff"
                                elide: Text.ElideRight
                                renderType: Text.NativeRendering
                                text: (root.effectivePlayer && root.effectivePlayer.trackArtist) ? root.effectivePlayer.trackArtist : (root.effectivePlayer ? (root.effectivePlayer.identity || "Idle") : "Idle")
                            }
                        }

                        // ── Row 3: High Precision Liquid Wave Progress Slider ──
                        Item {
                            id: newTimelineItem
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            implicitHeight: 100

                            // activePos: follows scrubPos during drag for live preview,
                            // then root.playerPos (maintained by interpolation timer + seekPlayer) after release.
                            // This decouples the slider from the JS-evaluated getCurrentCalculatedPos() binding
                            // which previously jumped back to the pre-seek position on isScrubbing flip.
                            property real activePos: root.isScrubbing ? root.scrubPos : root.playerPos
                            property real effectiveMax: root.playerLength > 0 ? root.playerLength : 300.0
                            property real progressFraction: Math.max(0.0, Math.min(1.0, activePos / effectiveMax))

                            Item {
                                id: newTimelineTrackContainer
                                anchors.top: parent.top
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: 80

                                property bool trackHovered: newTimelineMouse.containsMouse
                                property bool trackPressed: newTimelineMouse.pressed

                                Canvas {
                                    id: newProgressCanvas
                                    anchors.fill: parent
                                    renderTarget: Canvas.Image
                                    renderStrategy: Canvas.Threaded

                                    Connections {
                                        target: root
                                        function onTimelineWavePhaseChanged() {
                                            if (newProgressCanvas.visible) newProgressCanvas.requestPaint()
                                        }
                                        function onPlayerPosChanged() {
                                            if (newProgressCanvas.visible) newProgressCanvas.requestPaint()
                                        }
                                        function onScrubPosChanged() {
                                            if (newProgressCanvas.visible) newProgressCanvas.requestPaint()
                                        }
                                        function onIsScrubbingChanged() {
                                            if (newProgressCanvas.visible) newProgressCanvas.requestPaint()
                                        }
                                    }

                                    Connections {
                                        target: newTimelineItem
                                        function onProgressFractionChanged() {
                                            if (newProgressCanvas.visible) newProgressCanvas.requestPaint()
                                        }
                                    }

                                     onPaint: {
                                        var ctx = getContext("2d")
                                        ctx.clearRect(0, 0, width, height)

                                        const cy = height - 16
                                        const totalW = width
                                        const playedW = Math.max(0, Math.min(totalW, newTimelineItem.progressFraction * totalW))
                                        const isPlaying = root.effectivePlayer ? root.effectivePlayer.isPlaying : false

                                        // 1. Unplayed background track (extreme left to extreme right)
                                        ctx.beginPath()
                                        ctx.strokeStyle = "#33ffffff"
                                        ctx.lineWidth = 8.0
                                        ctx.lineCap = "round"
                                        ctx.moveTo(0, cy)
                                        ctx.lineTo(totalW, cy)
                                        ctx.stroke()

                                        // 2. Played baseline track
                                        if (playedW > 0) {
                                            ctx.beginPath()
                                            ctx.strokeStyle = Qt.lighter(root.gradColor1 || "#ffb4a0", 1.15)
                                            ctx.lineWidth = 8.0
                                            ctx.lineCap = "round"
                                            ctx.moveTo(0, cy)
                                            ctx.lineTo(playedW, cy)
                                            ctx.stroke()
                                        }

                                        // 3. Played section — 3 layers of flowing waves originating from extreme left (x = 0)
                                        if (playedW > 0 && isPlaying) {
                                            const t = Date.now() / 1000.0
                                            const baseAmp = 1.0

                                            const drawSvgWave = (opacity, waveColor, durSec, delaySec, layerAmp, waveLength) => {
                                                ctx.beginPath()
                                                ctx.fillStyle = waveColor
                                                ctx.globalAlpha = opacity
                                                ctx.moveTo(0, cy)

                                                const currentPhase = ((t - delaySec) / durSec) * Math.PI * 2
                                                const freq = (Math.PI * 2) / waveLength

                                                const convergenceDist = Math.min(36.0, playedW)

                                                for (let x = 0; x < playedW; x += 1.5) {
                                                    // Smooth convergence into playhead dot over final 36px
                                                    const distFromEnd = playedW - x
                                                    const endDampVal = convergenceDist > 0.0 ? Math.max(0.0, Math.min(1.0, distFromEnd / convergenceDist)) : 1.0
                                                    const endDamp = endDampVal * endDampVal * (3.0 - 2.0 * endDampVal)

                                                    const wiggle = (Math.sin(x * freq - currentPhase) + 1.0) * layerAmp * baseAmp

                                                    ctx.lineTo(x, cy - wiggle * endDamp)
                                                }
                                                ctx.lineTo(playedW, cy)
                                                ctx.closePath()
                                                ctx.fill()
                                            }

                                            const c1 = Qt.lighter(root.gradColor1 || "#ffb4a0", 1.15)
                                            const c2 = Qt.lighter(root.gradColor2 || "#ff8a7a", 1.15)
                                            const c3 = Qt.lighter(root.gradColor3 || "#ff5757", 1.15)

                                            // Back wave (amplitude 22.0, wavelength 607.5)
                                            drawSvgWave(1.0, c3, 2.7, 0.0, 22.0, 607.5)
                                            // Middle wave (amplitude 17.0, wavelength 445.5)
                                            drawSvgWave(1.0, c2, 1.8, -0.5, 17.0, 445.5)
                                            // Front wave (amplitude 12.0, wavelength 324.0)
                                            drawSvgWave(1.0, c1, 1.35, 0.0, 12.0, 324.0)

                                            ctx.globalAlpha = 1.0
                                        }

                                        // 4. Playhead circle dot
                                        ctx.beginPath()
                                        ctx.fillStyle = root.gradColor1 || "#ffb4a0"
                                        ctx.arc(playedW, cy, 9.0, 0, Math.PI * 2)
                                        ctx.fill()
                                    }

                                    // Scrub tooltip
                                    Rectangle {
                                        visible: newTimelineTrackContainer.trackPressed
                                        opacity: newTimelineTrackContainer.trackPressed ? 1.0 : 0.0
                                        Behavior on opacity { NumberAnimation { duration: 120 } }
                                        x: Math.max(0, Math.min(parent.width - width, newTimelineItem.progressFraction * parent.width - width / 2))
                                        y: -24
                                        width: newTimeTipText.implicitWidth + 16
                                        height: 22
                                        radius: 11
                                        color: "#cc11111b"
                                        border.color: "#33ffffff"; border.width: 1

                                        Text {
                                            id: newTimeTipText
                                            anchors.centerIn: parent
                                            font.family: root.sfFont
                                            font.pixelSize: 13
                                            color: "#ffffff"
                                            renderType: Text.NativeRendering
                                            text: root.formatSecs(newTimelineItem.activePos)
                                        }
                                    }
                                }

                                MouseArea {
                                    id: newTimelineMouse
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    preventStealing: true
                                    hoverEnabled: true

                                    function seekTo(mx) {
                                        if (parent.width > 0) {
                                            const frac = Math.max(0.0, Math.min(1.0, mx / parent.width))
                                            root.scrubPos = frac * newTimelineItem.effectiveMax
                                        }
                                    }
                                    onPressed: function(mouse) {
                                        root.isScrubbing = true
                                        seekTo(mouse.x)
                                    }
                                    onPositionChanged: function(mouse) {
                                        if (pressed) seekTo(mouse.x)
                                    }
                                    onReleased: function(mouse) {
                                        if (root.isScrubbing) {
                                            // seekPlayer sets root.playerPos = clamped synchronously,
                                            // so when isScrubbing flips false, activePos transitions
                                            // from scrubPos → playerPos at the correct seek target.
                                            root.seekPlayer(root.scrubPos)
                                            root.isScrubbing = false
                                        }
                                    }
                                    onCanceled: {
                                        // Restore playerPos to lastSyncPos so slider stays stable
                                        root.playerPos = root.lastSyncPos
                                        root.isScrubbing = false
                                    }
                                }
                            }

                            // Timestamps row — positioned below the wave track with dedicated separation
                            RowLayout {
                                anchors.top: newTimelineTrackContainer.bottom
                                anchors.topMargin: 4
                                anchors.left: parent.left
                                anchors.right: parent.right

                                Text {
                                    font.family: root.sfFont
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: "#ccffffff"
                                    renderType: Text.NativeRendering
                                    text: root.formatSecs(newTimelineItem.activePos)
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    font.family: root.sfFont
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: "#ccffffff"
                                    renderType: Text.NativeRendering
                                    text: root.playerLength > 0 ? root.formatSecs(root.playerLength) : "--:--"
                                }
                            }
                        }

                        // ── Row 4: Transport controls — Skip Prev, Play/Pause, Skip Next ──
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: -18
                            Layout.bottomMargin: 18
                            spacing: 32

                            Item { Layout.fillWidth: true }

                            // Skip Previous
                            Item {
                                id: newPrevBtn
                                width: 46; height: 46
                                property bool btnPrs: newPrevMouse.pressed
                                property bool btnEnabled: root.effectivePlayer ? (root.effectivePlayer.canGoPrevious ?? true) : false

                                opacity: btnEnabled ? 1.0 : 0.4
                                Behavior on opacity { NumberAnimation { duration: 150 } }

                                scale: btnPrs ? 0.86 : 1.0
                                Behavior on scale {
                                    NumberAnimation {
                                        duration: newPrevBtn.btnPrs ? 80 : 180
                                        easing.type: newPrevBtn.btnPrs ? Easing.InCubic : Easing.OutBack
                                        easing.overshoot: 1.4
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    font.family: root.iconFont
                                    font.pixelSize: 38
                                    color: "#ffffff"
                                    renderType: Text.QtRendering
                                    text: "\uf04a"
                                }

                                MouseArea {
                                    id: newPrevMouse
                                    anchors.fill: parent
                                    cursorShape: newPrevBtn.btnEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: { root.previousTrack() }
                                }
                            }

                            // Play / Pause
                            Item {
                                id: newPlayBtn
                                width: 60; height: 60
                                property bool isPlay: root.effectivePlayer ? root.effectivePlayer.isPlaying : false
                                property bool btnPrs: newPlayMouse.pressed
                                property bool btnEnabled: root.effectivePlayer !== null || Mpris.players.values.length > 0

                                opacity: btnEnabled ? 1.0 : 0.4
                                Behavior on opacity { NumberAnimation { duration: 150 } }

                                scale: btnPrs ? 0.86 : 1.0
                                Behavior on scale {
                                    NumberAnimation {
                                        duration: newPlayBtn.btnPrs ? 80 : 180
                                        easing.type: newPlayBtn.btnPrs ? Easing.InCubic : Easing.OutBack
                                        easing.overshoot: 1.4
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    font.family: root.iconFont
                                    font.pixelSize: 52
                                    color: "#ffffff"
                                    renderType: Text.QtRendering
                                    text: newPlayBtn.isPlay ? "\uf04c" : "\uf04b"
                                }

                                MouseArea {
                                    id: newPlayMouse
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.togglePlayPause() }
                                }
                            }

                            // Skip Next
                            Item {
                                id: newNextBtn
                                width: 46; height: 46
                                property bool btnPrs: newNextMouse.pressed
                                property bool btnEnabled: root.effectivePlayer ? (root.effectivePlayer.canGoNext ?? true) : false

                                opacity: btnEnabled ? 1.0 : 0.4
                                Behavior on opacity { NumberAnimation { duration: 150 } }

                                scale: btnPrs ? 0.86 : 1.0
                                Behavior on scale {
                                    NumberAnimation {
                                        duration: newNextBtn.btnPrs ? 80 : 180
                                        easing.type: newNextBtn.btnPrs ? Easing.InCubic : Easing.OutBack
                                        easing.overshoot: 1.4
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    font.family: root.iconFont
                                    font.pixelSize: 38
                                    color: "#ffffff"
                                    renderType: Text.QtRendering
                                    text: "\uf04e"
                                }

                                MouseArea {
                                    id: newNextMouse
                                    anchors.fill: parent
                                    cursorShape: newNextBtn.btnEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: { root.nextTrack() }
                                }
                            }

                            Item { Layout.fillWidth: true }
                        }
                    }
                }

                // ═════════════════════════════════════════════════
                // UPPER RIGHT: VOLUME MIXER SUB-MENU (282px height)
                // ═════════════════════════════════════════════════
                Rectangle {
                    id: audioCard
                    Layout.fillWidth: true
                    Layout.preferredWidth: 308
                    implicitHeight: 282
                    radius: 18
                    color: cardHovered ? "#14ffffff" : "#00000000"
                    border.color: cardHovered ? "#55ffffff" : "#33ffffff"
                    border.width: 1
                    clip: true
                    scale: 0.94 + 0.06 * Math.min(1.0, root.animProgress * 1.08)
                    transformOrigin: Item.TopRight
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    // Hover micro-interaction without scaling transform
                    property bool cardHovered: audioCardHover.hovered
                    HoverHandler { id: audioCardHover }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 8

                        // Header (15px Bold SF Pro Rounded)
                        RowLayout {
                            Layout.fillWidth: true
                            Text {
                                text: "VOLUME MIXER"
                                font.family: root.sfFont
                                font.pixelSize: 15
                                font.bold: true
                                color: "#ffffff"
                                renderType: Text.NativeRendering
                            }
                            Item { Layout.fillWidth: true }
                            Text {
                                font.family: root.sfFont
                                font.pixelSize: 14
                                font.bold: true
                                color: root.islandMuted ? "#f38ba8" : "#93c5fd"
                                renderType: Text.NativeRendering
                                text: root.islandMuted ? "MUTED" : Math.round(root.islandVol * 100) + "%"
                            }
                        }

                        // Small gap below header
                        Item { Layout.preferredHeight: 6 }

                        // Master Volume Slider Track
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Rectangle {
                                implicitWidth: 34
                                implicitHeight: 34
                                radius: 17
                                color: volIconMouse.containsMouse ? "#33ffffff" : "#1affffff"
                                Text {
                                    anchors.centerIn: parent
                                    font.family: root.iconFont
                                    font.pixelSize: 23
                                    color: root.islandMuted ? "#f38ba8" : "#ffffff"
                                    text: {
                                        if (root.islandMuted || root.islandVol <= 0.001) return "󰝟"
                                        if (root.islandVol < 0.33) return "󰕿"
                                        if (root.islandVol < 0.67) return "󰖀"
                                        return "󰕾"
                                    }
                                }
                                MouseArea {
                                    id: volIconMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        const sink = Pipewire.defaultAudioSink
                                        if (sink && sink.audio)
                                            sink.audio.muted = !sink.audio.muted
                                    }
                                    onWheel: function(wheel) {
                                        const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                                        volSliderMouse.adjustVol(delta)
                                    }
                                }
                            }

                            // Slider Bar with drag handle
                            Item {
                                id: volSliderItem
                                Layout.fillWidth: true
                                implicitHeight: 32

                                property bool sliderPressed: volSliderMouse.pressed
                                property real fillFraction: Math.max(0, Math.min(1.0, root.islandVol))

                                // Track background
                                Rectangle {
                                    id: menuVolTrack
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    height: 8
                                    radius: 4
                                    color: "#33ffffff"

                                    // Fill
                                    Rectangle {
                                        id: menuVolFill
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.bottom: parent.bottom
                                        width: parent.width * volSliderItem.fillFraction
                                        radius: 4
                                        color: root.islandMuted ? "#f38ba8" : "#93c5fd"
                                    }

                                    // Handle Knob
                                    Rectangle {
                                        id: menuVolHandle
                                        width: volSliderMouse.pressed ? 26 : (volSliderMouse.containsMouse ? 24 : 22)
                                        height: 16
                                        radius: 8
                                        color: "#ffffff"
                                        border.color: root.islandMuted ? "#94a3b8" : (volSliderMouse.pressed ? "#ffffff" : "#cbd5e1")
                                        border.width: 1.2
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: Math.max(0, Math.min(parent.width - width, parent.width * volSliderItem.fillFraction - width / 2))
                                        opacity: 1.0
                                        scale: volSliderMouse.pressed ? 1.08 : (volSliderMouse.containsMouse ? 1.04 : 1.0)

                                        Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }
                                        Behavior on x {
                                            enabled: !volSliderMouse.pressed
                                            NumberAnimation { duration: 80; easing.type: Easing.OutQuad }
                                        }
                                    }
                                }

                                MouseArea {
                                    id: volSliderMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    preventStealing: true

                                    function adjustVol(delta) {
                                        const sink = Pipewire.defaultAudioSink
                                        const current = (sink && sink.audio) ? sink.audio.volume : root.islandVol
                                        const target = Math.max(0, Math.min(1.0, current + delta))
                                        root.islandVol = target
                                        if (sink && sink.audio)
                                            sink.audio.volume = target
                                    }

                                    function updateVol(mx) {
                                        const frac = Math.max(0, Math.min(1.0, mx / width))
                                        root.islandVol = frac
                                        const sink = Pipewire.defaultAudioSink
                                        if (sink && sink.audio)
                                            sink.audio.volume = frac
                                    }

                                    onPressed: function(mouse) { updateVol(mouse.x) }
                                    onPositionChanged: function(mouse) { if (pressed) updateVol(mouse.x) }
                                    onWheel: function(wheel) {
                                        const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                                        adjustVol(delta)
                                    }
                                }
                            }
                        }

                        // Small gap below slider
                        Item { Layout.preferredHeight: 6 }

                        // Active Playback Streams List (Flickable 154px)
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: 154
                            clip: true

                            Flickable {
                                id: streamFlickable
                                anchors.fill: parent
                                contentHeight: streamCol.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                flickableDirection: Flickable.VerticalFlick
                                interactive: true

                                WheelHandler {
                                    id: wheelHandler
                                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                    orientation: Qt.Vertical
                                    rotationScale: 0.6
                                    onWheel: function(event) {
                                        const maxScroll = Math.max(0, streamCol.implicitHeight - streamFlickable.height)
                                        const step = event.pixelDelta.y !== 0 ? -event.pixelDelta.y : -(event.angleDelta.y / 120) * 36
                                        streamFlickable.contentY = Math.max(0, Math.min(maxScroll, streamFlickable.contentY + step))
                                    }
                                }

                                ColumnLayout {
                                    id: streamCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    spacing: 6

                                    Repeater {
                                        model: root.playbackStreams

                                        delegate: Rectangle {
                                            id: streamRow
                                            Layout.fillWidth: true
                                            implicitHeight: 54
                                            radius: 14

                                            property var streamNode: modelData
                                            property var streamAudio: streamNode ? streamNode.audio : null
                                            property real streamVol: streamAudio ? streamAudio.volume : 1.0
                                            property bool streamMuted: streamAudio ? streamAudio.muted : false
                                            property string appName: {
                                                if (!streamNode) return "Unknown"
                                                const props = streamNode.properties || {}
                                                return props["application.name"] || streamNode.name || "Audio Stream"
                                            }
                                            property string resolvedIcon: root.resolveAppIcon(streamNode)

                                            color: rowHover.containsMouse ? "#20ffffff" : "#10ffffff"
                                            border.color: rowHover.containsMouse ? "#30ffffff" : "#18ffffff"
                                            border.width: 1
                                            Behavior on color { ColorAnimation { duration: 120 } }
                                            Behavior on border.color { ColorAnimation { duration: 120 } }

                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: 10
                                                anchors.rightMargin: 10
                                                anchors.topMargin: 6
                                                anchors.bottomMargin: 6
                                                spacing: 10

                                                // Big Application Icon (38x38)
                                                Rectangle {
                                                    id: iconBadge
                                                    Layout.preferredWidth: 38
                                                    Layout.preferredHeight: 38
                                                    radius: 10
                                                    color: iconMouse.containsMouse ? "#33ffffff" : "#1affffff"
                                                    clip: true

                                                    Image {
                                                        id: appImg
                                                        anchors.centerIn: parent
                                                        width: 26; height: 26
                                                        source: streamRow.resolvedIcon
                                                        fillMode: Image.PreserveAspectFit
                                                        smooth: true
                                                        asynchronous: true
                                                        visible: status === Image.Ready && source !== ""
                                                        opacity: streamRow.streamMuted ? 0.4 : 1.0
                                                    }

                                                    Text {
                                                        anchors.centerIn: parent
                                                        font.family: root.iconFont
                                                        font.pixelSize: 22
                                                        color: streamRow.streamMuted ? "#f38ba8" : "#ffffff"
                                                        renderType: Text.NativeRendering
                                                        visible: !appImg.visible
                                                        text: root.getAppGlyph(streamRow.appName)
                                                        opacity: streamRow.streamMuted ? 0.4 : 1.0
                                                    }

                                                    // Mute overlay mini-icon if muted
                                                    Text {
                                                        anchors.bottom: parent.bottom
                                                        anchors.right: parent.right
                                                        anchors.margins: 2
                                                        font.family: root.iconFont
                                                        font.pixelSize: 12
                                                        color: "#f38ba8"
                                                        text: "󰝟"
                                                        visible: streamRow.streamMuted
                                                    }

                                                    MouseArea {
                                                        id: iconMouse
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: {
                                                            if (streamRow.streamAudio) {
                                                                streamRow.streamAudio.muted = !streamRow.streamAudio.muted
                                                            }
                                                        }
                                                    }
                                                }

                                                // Stream Info & Slider
                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 4

                                                    // Row: App Name & Relative % Readout
                                                    RowLayout {
                                                        Layout.fillWidth: true
                                                        Text {
                                                            Layout.fillWidth: true
                                                            text: streamRow.appName
                                                            font.family: root.sfFont
                                                            font.pixelSize: 14
                                                            font.bold: true
                                                            color: streamRow.streamMuted ? "#a6adc8" : "#ffffff"
                                                            elide: Text.ElideRight
                                                            renderType: Text.NativeRendering
                                                        }
                                                        Text {
                                                            font.family: root.sfFont
                                                            font.pixelSize: 13
                                                            font.bold: true
                                                            color: streamRow.streamMuted ? "#f38ba8" : "#93c5fd"
                                                            renderType: Text.NativeRendering
                                                            text: streamRow.streamMuted ? "MUTED" : Math.round(streamRow.streamVol * 100) + "%"
                                                        }
                                                    }

                                                    // Player Volume Slider Track
                                                    Item {
                                                        id: playerSliderItem
                                                        Layout.fillWidth: true
                                                        implicitHeight: 14

                                                        property bool pressed: playerSliderMouse.pressed
                                                        property real fraction: Math.max(0, Math.min(1.0, streamRow.streamVol))

                                                        Rectangle {
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            anchors.left: parent.left
                                                            anchors.right: parent.right
                                                            height: 6
                                                            radius: 3
                                                            color: "#33ffffff"

                                                            Rectangle {
                                                                anchors.left: parent.left
                                                                anchors.top: parent.top
                                                                anchors.bottom: parent.bottom
                                                                width: parent.width * playerSliderItem.fraction
                                                                radius: 3
                                                                color: streamRow.streamMuted ? "#f38ba8" : "#93c5fd"
                                                            }

                                                            Rectangle {
                                                                width: 12; height: 12
                                                                radius: 6
                                                                color: "#ffffff"
                                                                anchors.verticalCenter: parent.verticalCenter
                                                                x: Math.max(0, Math.min(parent.width - width, parent.width * playerSliderItem.fraction - width / 2))
                                                                scale: playerSliderItem.pressed ? 1.3 : 1.0
                                                                Behavior on scale { NumberAnimation { duration: 100 } }
                                                            }
                                                        }

                                                        MouseArea {
                                                            id: playerSliderMouse
                                                            anchors.fill: parent
                                                            hoverEnabled: true
                                                            cursorShape: Qt.PointingHandCursor
                                                            preventStealing: true

                                                            function updateStreamVol(mx) {
                                                                const frac = Math.max(0, Math.min(1.0, mx / width))
                                                                if (streamRow.streamAudio) {
                                                                    streamRow.streamAudio.volume = frac
                                                                }
                                                            }

                                                            onPressed: function(mouse) { updateStreamVol(mouse.x) }
                                                            onPositionChanged: function(mouse) { if (pressed) updateStreamVol(mouse.x) }
                                                        }
                                                    }
                                                }
                                            }

                                            MouseArea {
                                                id: rowHover
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                z: -1
                                            }
                                        }
                                    }

                                    // Empty state when no streams active
                                    Item {
                                        Layout.fillWidth: true
                                        implicitHeight: 140
                                        visible: root.playbackStreams.length === 0

                                        ColumnLayout {
                                            anchors.centerIn: parent
                                            spacing: 6

                                            Text {
                                                Layout.alignment: Qt.AlignHCenter
                                                font.family: root.iconFont
                                                font.pixelSize: 28
                                                color: "#60ffffff"
                                                text: "󰝟"
                                            }

                                            Text {
                                                Layout.alignment: Qt.AlignHCenter
                                                font.family: root.sfFont
                                                font.pixelSize: 13
                                                font.bold: true
                                                color: "#60ffffff"
                                                text: "No active audio streams"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ─────────────────────────────────────────────────────────
            // LOWER PART: AUDIO VISUALIZER CARD (115px height)
            // ─────────────────────────────────────────────────────────
            Rectangle {
                id: visualizerCard
                Layout.fillWidth: true
                implicitHeight: 115
                radius: 18
                color: cardHovered ? "#14ffffff" : "#00000000"
                border.color: cardHovered ? "#55ffffff" : "#33ffffff"
                border.width: 1
                clip: true
                scale: 0.95 + 0.05 * Math.min(1.0, root.animProgress * 1.05)
                transformOrigin: Item.Top
                Behavior on color { ColorAnimation { duration: 150 } }
                Behavior on border.color { ColorAnimation { duration: 150 } }

                opacity: Math.min(1.0, Math.max(0.0, (root.animProgress - 0.10) / 0.90))
                transform: Translate {
                    y: -(1.0 - root.animProgress) * 22
                }

                // Hover micro-interaction without scaling transform
                property bool cardHovered: vizCardHover.hovered
                HoverHandler { id: vizCardHover }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 6

                    // Visualizer Header & Theme Switcher Controls (14px Bold SF Pro Rounded)
                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: "AUDIO VISUALIZER"
                            font.family: root.sfFont
                            font.pixelSize: 14
                            font.bold: true
                            color: "#ffffff"
                            renderType: Text.NativeRendering
                        }

                        Item { Layout.fillWidth: true }

                        // Visualizer Theme Arrow Switcher (< Theme 1/2/3 >)
                        RowLayout {
                            spacing: 10

                            Item {
                                id: prevThemeItem
                                width: 26; height: 26
                                property bool thHov: prevThemeHover.hovered
                                property bool thPrs: prevThemeTap.pressed

                                scale: thPrs ? 0.78 : (thHov ? 1.22 : 1.0)
                                Behavior on scale {
                                    NumberAnimation {
                                        duration: prevThemeItem.thPrs ? 90 : 180
                                        easing.type: prevThemeItem.thPrs ? Easing.InCubic : Easing.OutBack
                                        easing.overshoot: 1.4
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    font.family: root.iconFont
                                    font.pixelSize: 18
                                    color: "#ffffff"
                                    renderType: Text.NativeRendering
                                    text: "◀"
                                }

                                HoverHandler { id: prevThemeHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    id: prevThemeTap
                                    onTapped: {
                                        const newStyle = (root.vizStyle - 1 + 3) % 3
                                        root.vizStyle = newStyle
                                        root.changeVizStyle(newStyle)
                                    }
                                }
                            }

                            Text {
                                font.family: root.sfFont
                                font.pixelSize: 14
                                font.bold: true
                                color: "#93c5fd"
                                renderType: Text.NativeRendering
                                text: {
                                    if (root.vizStyle === 0) return "1: Vertical Bars"
                                    if (root.vizStyle === 1) return "2: Symmetric Mirror"
                                    return "3: Wave Bezier"
                                }
                            }

                            Item {
                                id: nextThemeItem
                                width: 26; height: 26
                                property bool thHov: nextThemeHover.hovered
                                property bool thPrs: nextThemeTap.pressed

                                scale: thPrs ? 0.78 : (thHov ? 1.22 : 1.0)
                                Behavior on scale {
                                    NumberAnimation {
                                        duration: nextThemeItem.thPrs ? 90 : 180
                                        easing.type: nextThemeItem.thPrs ? Easing.InCubic : Easing.OutBack
                                        easing.overshoot: 1.4
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    font.family: root.iconFont
                                    font.pixelSize: 18
                                    color: "#ffffff"
                                    renderType: Text.NativeRendering
                                    text: "▶"
                                }

                                HoverHandler { id: nextThemeHover; cursorShape: Qt.PointingHandCursor }
                                TapHandler {
                                    id: nextThemeTap
                                    onTapped: {
                                        const newStyle = (root.vizStyle + 1) % 3
                                        root.vizStyle = newStyle
                                        root.changeVizStyle(newStyle)
                                    }
                                }
                            }
                        }
                    }

                    // Canvas Visualizer Area
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true

                        Canvas {
                            id: vizCanvas
                            anchors.fill: parent
                            renderTarget: Canvas.FramebufferObject
                            renderStrategy: Canvas.Threaded

                            onPaint: {
                                var ctx = getContext("2d")
                                ctx.clearRect(0, 0, width, height)
                                if (!root.cavaBars || root.cavaBars.length === 0) return

                                const bars = root.cavaBars
                                const numBars = bars.length
                                const gap = 3
                                const total = width
                                const barW = Math.max(2, Math.floor((total - gap * (numBars - 1)) / numBars))
                                const maxH = height - 6
                                const style = root.vizStyle

                                const baseHue = Math.round(root.vizPhase) % 360
                                const endHue = Math.round(root.vizPhase + 25) % 360

                                if (style === 2) {
                                    // 3: Wave Bezier
                                    const cy = height / 2
                                    const grad = ctx.createLinearGradient(0, 0, width, 0)
                                    grad.addColorStop(0.0, "hsla(" + baseHue + ", 95%, 62%, 1.0)")
                                    grad.addColorStop(1.0, "hsla(" + endHue + ", 95%, 62%, 1.0)")

                                    ctx.beginPath()
                                    ctx.strokeStyle = grad
                                    ctx.lineWidth = 2.5
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"

                                    const pts = []
                                    for (let i = 0; i < numBars; i++) {
                                        const val = (bars[i] || 0) / 1000.0
                                        const cx2 = i * (barW + gap) + barW / 2
                                        pts.push({ x: cx2, y: cy - val * (cy - 4) })
                                    }

                                    if (pts.length > 1) {
                                        ctx.moveTo(pts[0].x, pts[0].y)
                                        for (let i = 0; i < pts.length - 1; i++) {
                                            const cp1x = pts[i].x + (pts[i+1].x - pts[i].x) / 3
                                            const cp1y = pts[i].y
                                            const cp2x = pts[i+1].x - (pts[i+1].x - pts[i].x) / 3
                                            const cp2y = pts[i+1].y
                                            ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, pts[i+1].x, pts[i+1].y)
                                        }
                                        ctx.stroke()

                                        // Mirror lower curve
                                        ctx.beginPath()
                                        ctx.strokeStyle = grad
                                        ctx.moveTo(pts[0].x, cy + (cy - pts[0].y))
                                        for (let i = 0; i < pts.length - 1; i++) {
                                            const cp1x = pts[i].x + (pts[i+1].x - pts[i].x) / 3
                                            const cp1y = cy + (cy - pts[i].y)
                                            const cp2x = pts[i+1].x - (pts[i+1].x - pts[i].x) / 3
                                            const cp2y = cy + (cy - pts[i].y)
                                            ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, pts[i+1].x, cy + (cy - pts[i+1].y))
                                        }
                                        ctx.stroke()

                                        for (let i = 0; i < pts.length; i++) {
                                            const val = (bars[i] || 0) / 1000.0
                                            const dotHue = Math.round(root.vizPhase + 10) % 360
                                            ctx.fillStyle = "hsl(" + dotHue + ", 95%, 70%)"
                                            ctx.beginPath()
                                            ctx.arc(pts[i].x, pts[i].y, Math.max(1.5, val * 4), 0, Math.PI * 2)
                                            ctx.fill()
                                        }
                                    }
                                } else {
                                    for (let i = 0; i < numBars; i++) {
                                        const val = (bars[i] || 0) / 1000.0
                                        const barH = Math.max(2, val * maxH)
                                        const x = i * (barW + gap)
                                        const barHue = Math.round(root.vizPhase + (i / numBars) * 25) % 360
                                        ctx.fillStyle = "hsla(" + barHue + ", 95%, " + Math.round(55 + val * 20) + "%, 1.0)"

                                        if (style === 0) {
                                            // 1: Vertical Bars from bottom
                                            ctx.fillRect(x, height - barH, barW, barH)
                                        } else {
                                            // 2: Symmetric Mirror from center
                                            const halfH = barH / 2
                                            const cy = height / 2
                                            ctx.fillRect(x, cy - halfH, barW, barH)
                                        }
                                    }
                                }
                            }

                            Connections {
                                target: root
                                function onCavaBarsChanged() {
                                    if (vizCanvas.visible) vizCanvas.requestPaint()
                                }
                                function onVizStyleChanged() {
                                    if (vizCanvas.visible) vizCanvas.requestPaint()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
