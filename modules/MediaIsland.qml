import QtQuick
import QtQuick.Layouts
import QtQml.Models
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire

// ─────────────────────────────────────────────────────────────────────────────
// MediaIsland — 300px center section of the bar.
//
// STATE MACHINE:
//   playerState: "idle" | "playing" | "paused"
//
// CONTENT PHASES (loop when playing or paused):
//   "idle"       → static "NOTHING" in red
//   "announce"   → "NOW PLAYING" or "PAUSED" text, 2 s
//   "title"      → "Artist – Title", 5 s
//   "visualizer" → cava bars, 7 s  (alternates vertical ↔ symmetric)
//
// VOLUME OSD:
//   Any volume change interrupts → slides to live volume bar.
//   2.5 s debounce after last change → slides back.
//
// CLICK CONTROLS (on the island area):
//   single left   → togglePlaying()
//   double left   → previous()
//   single right  → (reserved / no-op)
//   double right  → next()
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: root

    // ── External geometry ─────────────────────────────────────────────
    Layout.fillHeight: true
    // implicitWidth set by parent (644px in Bar.qml)
    clip: true

    readonly property string sfFont: "SF Pro Rounded"

    // ── Player state ──────────────────────────────────────────────────
    property string playerState: "idle"   // idle | playing | paused
    property string selectedDbusName: ""
    property string recentActiveDbusName: ""

    readonly property var validPlayers: {
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

    property var activePlayer: {
        const players = root.validPlayers
        if (!players || players.length === 0) return null

        // 1. If any player is actively playing, it takes immediate priority:
        for (let i = 0; i < players.length; i++) {
            if (players[i] && players[i].isPlaying) {
                return players[i]
            }
        }

        // 2. If selected player is specified and valid, lock onto it (for paused state):
        if (selectedDbusName !== "") {
            for (let i = 0; i < players.length; i++) {
                if (players[i] && players[i].dbusName === selectedDbusName)
                    return players[i]
            }
        }

        // 3. Fallback to recent active or first player:
        if (recentActiveDbusName !== "") {
            for (let i = 0; i < players.length; i++) {
                if (players[i] && players[i].dbusName === recentActiveDbusName)
                    return players[i]
            }
        }

        return players.length > 0 ? players[0] : null
    }

    property string trackTitle: activePlayer ? (activePlayer.trackTitle  || "") : ""
    property string trackArtist: activePlayer ? (activePlayer.trackArtist || "") : ""
    property string trackDisplay: {
        const t = (trackTitle || "").trim()
        const a = (trackArtist || "").trim()
        if (a && a !== "Unknown" && t) return a + " – " + t
        if (t) return t
        if (a && a !== "Unknown") return a
        return "Unknown"
    }

    // ── Phase state ───────────────────────────────────────────────────
    // "idle" | "announce" | "title" | "visualizer" | "volume"
    property string currentPhase: "idle"
    property string savedPhase:   "idle"    // phase to restore after volume OSD
    property int    vizStyle:     0         // 0=vertical, 1=symmetric, 2=wave; cycles mod 3
    property real   vizPhase:     0

    NumberAnimation on vizPhase {
        from: 0; to: 360
        duration: 10000
        loops: Animation.Infinite
        running: (root.currentPhase === "visualizer" || root.inCall || (typeof mediaMenu !== 'undefined' && mediaMenu && mediaMenu.open)) && (root.playerState === "playing" || root.inCall)
    }

    // ── Volume OSD ────────────────────────────────────────────────────
    property var  sink:       Pipewire.defaultAudioSink
    property var  sinkAudio:  sink ? sink.audio : null
    property real islandVol:  0
    property bool islandMuted: false

    PwObjectTracker { objects: root.sink ? [root.sink] : [] }

    function syncVolume() {
        if (!sinkAudio) return
        islandVol   = sinkAudio.volume
        islandMuted = sinkAudio.muted
    }

    onSinkAudioChanged: syncVolume()

    Connections {
        target: root.sinkAudio
        function onVolumesChanged() {
            root.syncVolume()
            root.onVolumeActivity()
        }
        function onMutedChanged() {
            root.syncVolume()
            root.onVolumeActivity()
        }
    }

    Component.onCompleted: {
        syncVolume()
        const vp = root.validPlayers
        for (let i = 0; i < vp.length; i++) {
            if (vp[i] && vp[i].isPlaying) {
                root.selectedDbusName = vp[i].dbusName
                root.recentActiveDbusName = vp[i].dbusName
                break
            }
        }
        if (root.selectedDbusName === "" && vp.length > 0) {
            root.selectedDbusName = vp[0].dbusName
            root.recentActiveDbusName = vp[0].dbusName
        }
        evaluatePlayerState()
    }

    // ── Cava data ─────────────────────────────────────────────────────
    property var cavaBars: new Array(16).fill(0)

    Process {
        id: cavaProc
        running: (root.currentPhase === "visualizer" || (typeof mediaMenu !== 'undefined' && mediaMenu && mediaMenu.open)) && root.playerState === "playing"
        command: ["cava", "-p", "/home/banana/.config/quickshell/scripts/cava-island.ini"]
        stdout: SplitParser {
            // Each line: "123;456;789;...;\n"  — 16 values separated by ;
            onRead: function(line) {
                const raw = line.trim()
                if (!raw) return
                const parts = raw.split(";")
                const bars = []
                for (let i = 0; i < 16; i++)
                    bars.push(parseInt(parts[i]) || 0)
                root.cavaBars = bars
            }
        }
    }

    // ── Call Mode ─────────────────────────────────────────────────────
    // Detected via PipeWire nodes with media.role=Communication.
    // Uses PwNodePeakMonitor — no extra cava process needed.
    property bool   inCall:      false
    property real   callOutPeak: 0.0   // sink peak → output blue bars
    property real   callMicPeak: 0.0   // mic peak  → input red bars

    // Keep a smoothed array of "fake" bars derived from the peak scalar
    // so the canvas can draw multiple bars with some variation.
    property var callOutBars: new Array(16).fill(0)
    property var callMicBars: new Array(16).fill(0)

    function peakToBars(peak) {
        const arr = []
        for (let i = 0; i < 16; i++) {
            // Gaussian-ish falloff from center, jittered slightly
            const pos = i / 15.0
            const dist = Math.abs(pos - 0.5) * 2
            const v = Math.max(0, peak - dist * 0.4 + (Math.random() - 0.5) * 0.1 * peak)
            arr.push(Math.min(1000, Math.round(v * 1000)))
        }
        return arr
    }

    PwNodePeakMonitor {
        id: sinkPeakMonitor
        node: root.sink
        enabled: root.inCall
        onPeakChanged: {
            root.callOutPeak = Math.max(0, Math.min(1, peak))
            root.callOutBars = root.peakToBars(root.callOutPeak)
        }
    }

    PwObjectTracker {
        id: micTracker
        objects: Pipewire.defaultAudioSource ? [Pipewire.defaultAudioSource] : []
    }

    PwNodePeakMonitor {
        id: micPeakMonitor
        node: Pipewire.defaultAudioSource
        enabled: root.inCall
        onPeakChanged: {
            root.callMicPeak = Math.max(0, Math.min(1, peak))
            root.callMicBars = root.peakToBars(root.callMicPeak)
        }
    }

    function checkCallStatus() {
        const nodes = Pipewire.nodes.values || []
        let incall = false
        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i]
            if (n && n.properties && n.properties["media.role"] === "Communication") {
                incall = true
                break
            }
        }
        if (incall && !root.inCall) {
            root.inCall = true
            root.enterCallMode()
        } else if (!incall && root.inCall) {
            root.inCall = false
            root.exitCallMode()
        }
    }

    Connections {
        target: Pipewire.nodes
        function onValuesChanged() { root.checkCallStatus() }
    }

    Timer {
        interval: 15000  // was 5000 — Pipewire.nodes.onValuesChanged handles real-time detection; this is only a safety-net fallback
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.checkCallStatus()
    }

    function enterCallMode() {
        phaseTimer.stop()
        currentPhase = "call"
        slideTo("call", "", "#89b4fa", false)
    }

    function exitCallMode() {
        if (playerState === "idle") {
            currentPhase = "idle"
            slideTo("idle", "", "#00000000", false)
        } else {
            startLoop(playerState === "playing" ? "NEW" : "RESUME")
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // STATE + PHASE LOGIC
    // ─────────────────────────────────────────────────────────────────


    function evaluatePlayerState() {
        const players = root.validPlayers
        if (players.length === 0) {
            setPlayerState("idle")
            return
        }
        let anyPlaying = false
        for (let i = 0; i < players.length; i++)
            if (players[i].isPlaying) { anyPlaying = true; break }
        setPlayerState(anyPlaying ? "playing" : "paused")
    }

    Connections {
        target: Mpris.players
        function onValuesChanged() {
            const vp = root.validPlayers
            if (vp.length === 0) {
                root.selectedDbusName = ""
                root.recentActiveDbusName = ""
                root.evaluatePlayerState()
                return
            }
            if (root.selectedDbusName !== "") {
                for (let i = 0; i < vp.length; i++) {
                    if (vp[i] && vp[i].dbusName === root.selectedDbusName) {
                        root.evaluatePlayerState()
                        return
                    }
                }
            }
            for (let i = 0; i < vp.length; i++) {
                if (vp[i] && vp[i].isPlaying) {
                    root.selectedDbusName = vp[i].dbusName
                    root.recentActiveDbusName = vp[i].dbusName
                    root.evaluatePlayerState()
                    return
                }
            }
            root.selectedDbusName = vp[0].dbusName
            root.recentActiveDbusName = vp[0].dbusName
            root.evaluatePlayerState()
        }
    }

    function setPlayerState(newState) {
        if (playerState === newState) return
        const prev = playerState
        playerState = newState

        if (root.inCall) return

        // If a volume OSD is in progress, restore savedPhase first so the
        // phase state is consistent before we transition into the new state.
        // This prevents "volume" from becoming a stuck terminal phase.
        if (currentPhase === "volume") {
            currentPhase = savedPhase !== "volume" ? savedPhase : "idle"
        }

        volDebounce.stop()

        if (newState === "idle") {
            phaseTimer.stop()
            slideTo("idle", "", "#00000000", false)   // blank — show nothing
            currentPhase = "idle"
            return
        }

        // entering playing/paused — always start at announce
        startLoop(newState === "playing" ? "NEW" : "RESUME")
    }

    // Called when track changes while already playing or paused
    function onTrackChanged() {
        if (playerState === "idle") return
        startLoop("NEW")
    }

    function startLoop(reason) {
        phaseTimer.stop()
        currentPhase = "announce"

        const isPlaying = (playerState === "playing")
        const label = isPlaying ? "NOW PLAYING" : "PAUSED"
        slideTo("announce",
                label,
                "#ffffff",
                false)

        phaseTimer.interval = isPlaying ? 2000 : 3000
        phaseTimer.restart()
    }

    // Advance to the next phase in the loop
    function advancePhase() {
        if (currentPhase === "volume") return   // volume OSD controls itself

        if (playerState === "paused") {
            if (currentPhase === "announce") {
                // PAUSED (3s) -> Title (10s)
                currentPhase = "title"
                slideTo("title",
                        root.trackDisplay,
                        "#ffffff",
                        false)
                phaseTimer.interval = 10000
                phaseTimer.restart()
            } else {
                // Title (10s) -> PAUSED (3s)
                currentPhase = "announce"
                slideTo("announce",
                        "PAUSED",
                        "#ffffff",
                        false)
                phaseTimer.interval = 3000
                phaseTimer.restart()
            }
            return
        }

        if (playerState === "playing") {
            if (currentPhase === "announce" || currentPhase === "title") {
                // → visualizer (cycle through 3 styles)
                vizStyle = (vizStyle + 1) % 3
                currentPhase = "visualizer"
                slideTo("visualizer", "", "#ffffff", true)
                phaseTimer.interval = 7000
                phaseTimer.restart()
            } else if (currentPhase === "visualizer") {
                // → title
                currentPhase = "title"
                slideTo("title",
                        root.trackDisplay,
                        "#ffffff",
                        false)
                phaseTimer.interval = 5000
                phaseTimer.restart()
            }
        }
    }

    // Phase advancement timer
    Timer {
        id: phaseTimer
        repeat: false
        onTriggered: root.advancePhase()
    }

    onActivePlayerChanged: evaluatePlayerState()

    // Track playback state across ALL players reactively
    Instantiator {
        model: Mpris.players.values
        delegate: Connections {
            target: modelData
            function onIsPlayingChanged() {
                if (modelData && modelData.isPlaying) {
                    const db = (modelData.dbusName || "").toLowerCase()
                    if (db.includes("playerctld")) return
                    root.recentActiveDbusName = modelData.dbusName
                    root.selectedDbusName = modelData.dbusName
                }
                root.evaluatePlayerState()
            }
            function onPlaybackStateChanged() {
                if (modelData && modelData.isPlaying) {
                    const db = (modelData.dbusName || "").toLowerCase()
                    if (db.includes("playerctld")) return
                    root.recentActiveDbusName = modelData.dbusName
                    root.selectedDbusName = modelData.dbusName
                }
                root.evaluatePlayerState()
            }
            function onTrackTitleChanged() {
                if (modelData && (modelData.isPlaying || modelData.dbusName === root.selectedDbusName)) {
                    root.recentActiveDbusName = modelData.dbusName
                    root.onTrackChanged()
                }
            }
        }
    }

    // Direct active player connection for immediate UI sync
    Connections {
        target: root.activePlayer
        function onIsPlayingChanged() { root.evaluatePlayerState() }
        function onTrackTitleChanged() { root.onTrackChanged() }
    }

    // ─────────────────────────────────────────────────────────────────
    // VOLUME OSD LOGIC
    // ─────────────────────────────────────────────────────────────────

    function onVolumeActivity() {
        if (currentPhase !== "volume") {
            // Save where we are so we can restore after OSD
            savedPhase = currentPhase
            phaseTimer.stop()
            currentPhase = "volume"
            slideTo("volume", "", "#89b4fa", false)
        }
        // (Re)start debounce — 2.5 s of silence = end OSD
        volDebounce.restart()
    }

    Timer {
        id: volDebounce
        interval: 2500
        repeat: false
        onTriggered: {
            // Guard: if something already exited the volume OSD (e.g. player state
            // changed), don't double-act.
            if (root.currentPhase !== "volume") return

            if (root.inCall) {
                root.currentPhase = "call"
                root.slideTo("call", "", "#89b4fa", false)
                root.savedPhase = "call"
                return
            }

            if (root.playerState === "idle") {
                // Back to blank idle
                root.currentPhase = "idle"
                root.slideTo("idle", "", "#00000000", false)
                root.savedPhase = "idle"
                return
            }

            // ── BUG FIX ───────────────────────────────────────────────────────
            // Instead of trying to restore the exact saved phase (which is fragile
            // when playerState changes mid-OSD or volume fires during animation),
            // always restart the loop cleanly.  The loop begins at "announce"
            // which is always a valid starting point.
            root.startLoop(root.playerState === "playing" ? "NEW" : "RESUME")
        }
    }


    // ─────────────────────────────────────────────────────────────────
    // SLIDE-UP ANIMATION ENGINE
    // ─────────────────────────────────────────────────────────────────

    // Two Item "slots": slotA and slotB.
    // activeSlot points to the currently visible one.
    // slideTo() prepopulates the inactive slot below,
    // then simultaneously:
    //   - active slot:   y: 0 → -height, opacity: 1 → 0
    //   - incoming slot: y: +height → 0, opacity: 0 → 1
    // After animation, roles swap.
    // ─────────────────────────────────────────────────────────────────

    property int activeSlot: 0     // 0 = slotA is current, 1 = slotB is current
    property bool animating: false

    // Called with:
    //   phase     — string key of the incoming phase
    //   label     — text to show (empty string if visualizer or volume)
    //   color     — text / bar color
    //   isViz     — true → show canvas instead of text
    function slideTo(phase, label, color, isViz) {
        // Set up the INCOMING (off-screen) slot
        if (activeSlot === 0) {
            // slotB becomes incoming
            slotBTitle.reset()

            slotBStatus.text    = label
            slotBStatus.color   = color
            slotBStatus.visible = (phase === "announce" || phase === "idle")

            slotBTitle.text     = label
            slotBTitle.color    = color
            slotBTitle.visible  = (phase === "title")

            slotBViz.visible    = isViz
            slotBVol.visible    = (phase === "volume")
            slotBCall.visible   = (phase === "call")
        } else {
            // slotA becomes incoming
            slotATitle.reset()

            slotAStatus.text    = label
            slotAStatus.color   = color
            slotAStatus.visible = (phase === "announce" || phase === "idle")

            slotATitle.text     = label
            slotATitle.color    = color
            slotATitle.visible  = (phase === "title")

            slotAViz.visible    = isViz
            slotAVol.visible    = (phase === "volume")
            slotACall.visible   = (phase === "call")
        }

        animating = true
        slideAnim.start()
    }

    // After the animation completes, swap which slot is "active"
    function onSlideComplete() {
        activeSlot = 1 - activeSlot
        animating = false

        if (activeSlot === 0) {
            slotBTitle.reset()
            if (slotATitle.visible && slotATitle.isOverflow) {
                slotATitle.reset()
                slotATitleAnim.restart()
            }
        } else {
            slotATitle.reset()
            if (slotBTitle.visible && slotBTitle.isOverflow) {
                slotBTitle.reset()
                slotBTitleAnim.restart()
            }
        }
    }

    // ── Parallel animation: outgoing exits up, incoming enters from below ──

    ParallelAnimation {
        id: slideAnim

        // Outgoing: moves up and fades out (Caelestia standardAccelerate)
        NumberAnimation {
            target: root.activeSlot === 0 ? slotA : slotB
            property: "y"
            from: 0; to: -root.height
            duration: 250
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.3, 0.0, 0.8, 0.15, 1, 1]
        }
        NumberAnimation {
            target: root.activeSlot === 0 ? slotA : slotB
            property: "opacity"
            from: 1; to: 0
            duration: 220
            easing.type: Easing.InQuad
        }

        // Incoming: rises from below and fades in (Caelestia expressiveFastSpatial spring)
        NumberAnimation {
            target: root.activeSlot === 0 ? slotB : slotA
            property: "y"
            from: root.height; to: 0
            duration: 280
            easing.type: Easing.BezierSpline
            easing.bezierCurve: [0.05, 0.7, 0.1, 1, 1, 1]
        }
        NumberAnimation {
            target: root.activeSlot === 0 ? slotB : slotA
            property: "opacity"
            from: 0; to: 1
            duration: 240
            easing.type: Easing.OutQuad
        }

        onFinished: root.onSlideComplete()
    }

    // ─────────────────────────────────────────────────────────────────
    // CONTENT SLOTS
    // Two identical stacked items. Only one is "on screen" at any time.
    // ─────────────────────────────────────────────────────────────────

    Item {
        id: islandSlotsContainer
        anchors.fill: parent
        scale: islandMouseArea.pressed ? 0.95 : (mediaMenu.open ? 1.02 : 1.00)
        transformOrigin: Item.Center
        Behavior on scale {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutBack
                easing.overshoot: 1.3
            }
        }

        // SLOT A ──────────────────────────────────────────────────────────

        Item {
            id: slotA
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.height
        y: 0       // starts as active slot (visible)
        opacity: 1

        // 1. Status Text (locked firmly in dead center for idle & announce)
        Text {
            id: slotAStatus
            anchors.centerIn: parent
            font.family: root.sfFont
            font.pixelSize: 19
            font.bold: false
            color: "#cc241d"
            text: "NOTHING"
            visible: true
        }

        // 2. Media Title (always starts left-aligned + marquee if overflow)
        Item {
            id: slotATitle
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            visible: false
            clip: true

            property string text: ""
            property color color: "#d79921"

            Text {
                id: slotATitleMetric
                visible: false
                font.family: root.sfFont
                font.pixelSize: 19
                font.bold: false
                text: slotATitle.text
            }

            property bool isOverflow: slotATitleMetric.implicitWidth > slotATitle.width
            property real scrollDistance: slotATitleMetric.implicitWidth + 40

            Item {
                id: slotATitleTrack
                height: parent.height
                width: slotATitle.isOverflow ? (slotATitleMetric.implicitWidth * 2 + 80) : parent.width
                x: 0

                Text {
                    id: slotATitle1
                    anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    font.family: root.sfFont
                    font.pixelSize: 19
                    font.bold: false
                    color: slotATitle.color
                    text: slotATitle.text
                }

                Text {
                    id: slotATitle2
                    anchors.verticalCenter: parent.verticalCenter
                    x: slotATitleMetric.implicitWidth + 40
                    font.family: root.sfFont
                    font.pixelSize: 19
                    font.bold: false
                    color: slotATitle.color
                    text: slotATitle.text
                    visible: slotATitle.isOverflow
                }
            }

            SequentialAnimation {
                id: slotATitleAnim
                running: slotATitle.visible && root.activeSlot === 0 && !root.animating && slotATitle.isOverflow
                loops: Animation.Infinite

                PauseAnimation { duration: 1500 }

                NumberAnimation {
                    target: slotATitleTrack
                    property: "x"
                    from: 0
                    to: -slotATitle.scrollDistance
                    duration: Math.max(1000, slotATitle.scrollDistance * 28)
                    easing.type: Easing.Linear
                }

                PropertyAction {
                    target: slotATitleTrack
                    property: "x"
                    value: 0
                }
            }

            function reset() {
                slotATitleAnim.stop()
                slotATitleTrack.x = 0
            }
        }

        // 3. Visualizer canvas
        Canvas {
            id: slotAViz
            anchors.fill: parent
            anchors.margins: 4
            visible: false
            property real vizOpacity: root.playerState === "paused" ? 0.3 : 1.0

            onPaint: {
                if (!visible) return
                const ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)

                const bars  = root.cavaBars
                const n     = bars.length
                const total = width
                const gap   = 3
                const barW  = Math.floor((total - gap * (n - 1)) / n)
                const maxH  = height
                const style = root.vizStyle
                const paused = root.playerState === "paused"

                const grad = ctx.createLinearGradient(0, 0, width, 0)
                const baseHue = Math.round(root.vizPhase) % 360
                const endHue = Math.round(root.vizPhase + 25) % 360

                const alpha = paused ? 0.35 : 1.0
                grad.addColorStop(0.0, "hsla(" + baseHue + ", 95%, 62%, " + alpha + ")")
                grad.addColorStop(1.0, "hsla(" + endHue + ", 95%, 62%, " + alpha + ")")

                ctx.globalAlpha = 1.0

                if (style === 2) {
                    const cy = maxH / 2
                    ctx.beginPath()
                    ctx.strokeStyle = grad
                    ctx.lineWidth = 2.5
                    ctx.lineCap = "round"
                    ctx.lineJoin = "round"

                    const pts = []
                    for (let i = 0; i < n; i++) {
                        const val = bars[i] / 1000
                        const cx2 = i * (barW + gap) + barW / 2
                        pts.push({ x: cx2, y: cy - val * (cy - 2) })
                    }

                    ctx.moveTo(pts[0].x, pts[0].y)
                    for (let i = 0; i < pts.length - 1; i++) {
                        const cp1x = pts[i].x + (pts[i+1].x - pts[i].x) / 3
                        const cp1y = pts[i].y
                        const cp2x = pts[i+1].x - (pts[i+1].x - pts[i].x) / 3
                        const cp2y = pts[i+1].y
                        ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, pts[i+1].x, pts[i+1].y)
                    }
                    ctx.stroke()

                    ctx.beginPath()
                    ctx.strokeStyle = grad
                    ctx.moveTo(pts[0].x, cy + (cy - pts[0].y))
                    for (let i = 0; i < pts.length - 1; i++) {
                        const cp1x = pts[i].x + (pts[i+1].x - pts[i].x) / 3
                        const cp1y = cy + (cy - pts[i].y)
                        const cp2x = pts[i+1].x - (pts[i+1].x - pts[i].x) / 3
                        const cp2y = cy + (cy - pts[i+1].y)
                        ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, pts[i+1].x, cy + (cy - pts[i+1].y))
                    }
                    ctx.stroke()

                    for (let i = 0; i < pts.length; i++) {
                        const val = bars[i] / 1000
                        const dotHue = Math.round(root.vizPhase + 10) % 360
                        ctx.fillStyle = "hsl(" + dotHue + ", 95%, 70%)"
                        ctx.beginPath()
                        ctx.arc(pts[i].x, pts[i].y, Math.max(1, val * 3), 0, Math.PI * 2)
                        ctx.fill()
                    }

                } else {
                    for (let i = 0; i < n; i++) {
                        const val  = bars[i] / 1000
                        const barH = Math.max(2, val * maxH)
                        const x    = i * (barW + gap)

                        const barHue = Math.round(root.vizPhase + (i / n) * 20) % 360
                        const lightness = paused ? 35 : (55 + val * 20)
                        ctx.fillStyle = "hsla(" + barHue + ", 95%, " + Math.round(lightness) + "%, " + alpha + ")"

                        if (style === 0) {
                            ctx.fillRect(x, maxH - barH, barW, barH)
                        } else {
                            const halfH = barH / 2
                            const cy    = maxH / 2
                            ctx.fillRect(x, cy - halfH, barW, barH)
                        }
                    }
                }

                ctx.globalAlpha = 1.0
            }


            // Repaint triggered from cavaProc when this slot is visible
            Connections {
                target: root
                function onCavaBarsChanged() {
                    if (slotAViz.visible) slotAViz.requestPaint()
                }
            }
        }

        // 4. Volume OSD content — 20 heavy-bar segments + percentage label
        Item {
            id: slotAVol
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            visible: false

            RowLayout {
                anchors.centerIn: parent
                spacing: 2

                Repeater {
                    model: 20

                    delegate: Text {
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 18
                        font.bold: true
                        text: "┃"
                        property real threshold: (index + 1) / 20
                        color: root.islandVol >= threshold
                            ? (root.islandMuted ? "#f38ba8" : "#89b4fa")
                            : "#1e1e2e"
                        Behavior on color {
                            ColorAnimation { duration: 40; easing.type: Easing.OutExpo }
                        }
                    }
                }

                Text {
                    font.family: root.sfFont
                    font.pixelSize: 14
                    font.bold: false
                    color: root.islandMuted ? "#f38ba8" : "#ffffff"
                    text: root.islandMuted ? "M" : Math.round(root.islandVol * 100) + "%"
                    leftPadding: 4
                }
            }
        }
    }


        // 5. Call Mode — dual visualizer (blue output | red mic)
        Item {
            id: slotACall
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            visible: false

            RowLayout {
                anchors.fill: parent
                spacing: 6

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 1
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 7
                        color: "#89b4fa"
                        text: "OUTPUT"
                        opacity: 0.7
                    }
                    Canvas {
                        id: slotACallOut
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            const bars = root.callOutBars
                            const n = bars.length
                            const gap = 2
                            const barW = Math.floor((width - gap * (n - 1)) / n)
                            const maxH = height
                            for (let i = 0; i < n; i++) {
                                const val = bars[i] / 1000
                                const barH = Math.max(1, val * maxH)
                                const x = i * (barW + gap)
                                const bright = 0.4 + val * 0.6
                                ctx.fillStyle = "rgba(" + Math.round(60 + 90*bright) + "," + Math.round(100 + 110*bright) + "," + Math.round(180 + 70*bright) + ",1)"
                                ctx.fillRect(x, maxH / 2 - barH / 2, barW, barH)
                            }
                        }
                        Connections {
                            target: root
                            function onCallOutBarsChanged() { if (slotACallOut.visible) slotACallOut.requestPaint() }
                        }
                    }
                }

                Rectangle { width: 1; Layout.fillHeight: true; color: "#333344"; opacity: 0.7 }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 1
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 7
                        color: "#f38ba8"
                        text: "MIC"
                        opacity: 0.7
                    }
                    Canvas {
                        id: slotACallMic
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            const bars = root.callMicBars
                            const n = bars.length
                            const gap = 2
                            const barW = Math.floor((width - gap * (n - 1)) / n)
                            const maxH = height
                            for (let i = 0; i < n; i++) {
                                const val = bars[i] / 1000
                                const barH = Math.max(1, val * maxH)
                                const x = i * (barW + gap)
                                const bright = 0.4 + val * 0.6
                                ctx.fillStyle = "rgba(" + Math.round(180 + 60*bright) + "," + Math.round(40 + 60*bright) + "," + Math.round(80 + 50*bright) + ",1)"
                                ctx.fillRect(x, maxH / 2 - barH / 2, barW, barH)
                            }
                        }
                        Connections {
                            target: root
                            function onCallMicBarsChanged() { if (slotACallMic.visible) slotACallMic.requestPaint() }
                        }
                    }
                }
            }
        }

    // SLOT B ───────────────────────────────────────────────────────────
    Item {
        id: slotB
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.height
        y: root.height   // starts off-screen below
        opacity: 0

        // 1. Status Text (locked firmly in dead center for idle & announce)
        Text {
            id: slotBStatus
            anchors.centerIn: parent
            font.family: root.sfFont
            font.pixelSize: 19
            font.bold: false
            color: "#ebdbb2"
            text: ""
            visible: false
        }

        // 2. Media Title (always starts left-aligned + marquee if overflow)
        Item {
            id: slotBTitle
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            visible: false
            clip: true

            property string text: ""
            property color color: "#ebdbb2"

            Text {
                id: slotBTitleMetric
                visible: false
                font.family: root.sfFont
                font.pixelSize: 19
                font.bold: false
                text: slotBTitle.text
            }

            property bool isOverflow: slotBTitleMetric.implicitWidth > slotBTitle.width
            property real scrollDistance: slotBTitleMetric.implicitWidth + 40

            Item {
                id: slotBTitleTrack
                height: parent.height
                width: slotBTitle.isOverflow ? (slotBTitleMetric.implicitWidth * 2 + 80) : parent.width
                x: 0

                Text {
                    id: slotBTitle1
                    anchors.verticalCenter: parent.verticalCenter
                    x: 0
                    font.family: root.sfFont
                    font.pixelSize: 19
                    font.bold: false
                    color: slotBTitle.color
                    text: slotBTitle.text
                }

                Text {
                    id: slotBTitle2
                    anchors.verticalCenter: parent.verticalCenter
                    x: slotBTitleMetric.implicitWidth + 40
                    font.family: root.sfFont
                    font.pixelSize: 19
                    font.bold: false
                    color: slotBTitle.color
                    text: slotBTitle.text
                    visible: slotBTitle.isOverflow
                }
            }

            SequentialAnimation {
                id: slotBTitleAnim
                running: slotBTitle.visible && root.activeSlot === 1 && !root.animating && slotBTitle.isOverflow
                loops: Animation.Infinite

                PauseAnimation { duration: 1500 }

                NumberAnimation {
                    target: slotBTitleTrack
                    property: "x"
                    from: 0
                    to: -slotBTitle.scrollDistance
                    duration: Math.max(1000, slotBTitle.scrollDistance * 28)
                    easing.type: Easing.Linear
                }

                PropertyAction {
                    target: slotBTitleTrack
                    property: "x"
                    value: 0
                }
            }

            function reset() {
                slotBTitleAnim.stop()
                slotBTitleTrack.x = 0
            }
        }

        // 3. Visualizer canvas
        Canvas {
            id: slotBViz
            anchors.fill: parent
            anchors.margins: 4
            visible: false
            property real vizOpacity: root.playerState === "paused" ? 0.3 : 1.0

            onPaint: {
                if (!visible) return
                const ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)

                const bars  = root.cavaBars
                const n     = bars.length
                const total = width
                const gap   = 3
                const barW  = Math.floor((total - gap * (n - 1)) / n)
                const maxH  = height
                const style = root.vizStyle
                const paused = root.playerState === "paused"

                const grad = ctx.createLinearGradient(0, 0, width, 0)
                const baseHue = Math.round(root.vizPhase) % 360
                const endHue = Math.round(root.vizPhase + 25) % 360

                const alpha = paused ? 0.35 : 1.0
                grad.addColorStop(0.0, "hsla(" + baseHue + ", 95%, 62%, " + alpha + ")")
                grad.addColorStop(1.0, "hsla(" + endHue + ", 95%, 62%, " + alpha + ")")

                ctx.globalAlpha = 1.0

                if (style === 2) {
                    const cy = maxH / 2
                    ctx.beginPath()
                    ctx.strokeStyle = grad
                    ctx.lineWidth = 2.5
                    ctx.lineCap = "round"
                    ctx.lineJoin = "round"

                    const pts = []
                    for (let i = 0; i < n; i++) {
                        const val = bars[i] / 1000
                        const cx2 = i * (barW + gap) + barW / 2
                        pts.push({ x: cx2, y: cy - val * (cy - 2) })
                    }

                    ctx.moveTo(pts[0].x, pts[0].y)
                    for (let i = 0; i < pts.length - 1; i++) {
                        const cp1x = pts[i].x + (pts[i+1].x - pts[i].x) / 3
                        const cp1y = pts[i].y
                        const cp2x = pts[i+1].x - (pts[i+1].x - pts[i].x) / 3
                        const cp2y = pts[i+1].y
                        ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, pts[i+1].x, pts[i+1].y)
                    }
                    ctx.stroke()

                    ctx.beginPath()
                    ctx.strokeStyle = grad
                    ctx.moveTo(pts[0].x, cy + (cy - pts[0].y))
                    for (let i = 0; i < pts.length - 1; i++) {
                        const cp1x = pts[i].x + (pts[i+1].x - pts[i].x) / 3
                        const cp1y = cy + (cy - pts[i].y)
                        const cp2x = pts[i+1].x - (pts[i+1].x - pts[i].x) / 3
                        const cp2y = cy + (cy - pts[i+1].y)
                        ctx.bezierCurveTo(cp1x, cp1y, cp2x, cp2y, pts[i+1].x, cy + (cy - pts[i+1].y))
                    }
                    ctx.stroke()

                    for (let i = 0; i < pts.length; i++) {
                        const val = bars[i] / 1000
                        const dotHue = Math.round(root.vizPhase + 10) % 360
                        ctx.fillStyle = "hsl(" + dotHue + ", 95%, 70%)"
                        ctx.beginPath()
                        ctx.arc(pts[i].x, pts[i].y, Math.max(1, val * 3), 0, Math.PI * 2)
                        ctx.fill()
                    }

                } else {
                    for (let i = 0; i < n; i++) {
                        const val  = bars[i] / 1000
                        const barH = Math.max(2, val * maxH)
                        const x    = i * (barW + gap)

                        const barHue = Math.round(root.vizPhase + (i / n) * 20) % 360
                        const lightness = paused ? 35 : (55 + val * 20)
                        ctx.fillStyle = "hsla(" + barHue + ", 95%, " + Math.round(lightness) + "%, " + alpha + ")"

                        if (style === 0) {
                            ctx.fillRect(x, maxH - barH, barW, barH)
                        } else {
                            const halfH = barH / 2
                            const cy    = maxH / 2
                            ctx.fillRect(x, cy - halfH, barW, barH)
                        }
                    }
                }
            }


            Connections {
                target: root
                function onCavaBarsChanged() {
                    if (slotBViz.visible) slotBViz.requestPaint()
                }
            }
        }

        // 4. Volume OSD content — 20 heavy-bar segments + percentage label
        Item {
            id: slotBVol
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            visible: false

            RowLayout {
                anchors.centerIn: parent
                spacing: 2

                Repeater {
                    model: 20

                    delegate: Text {
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 18
                        font.bold: true
                        text: "┃"
                        property real threshold: (index + 1) / 20
                        color: root.islandVol >= threshold
                            ? (root.islandMuted ? "#f38ba8" : "#89b4fa")
                            : "#1e1e2e"
                        Behavior on color {
                            ColorAnimation { duration: 40; easing.type: Easing.OutExpo }
                        }
                    }
                }

                Text {
                    font.family: root.sfFont
                    font.pixelSize: 14
                    font.bold: false
                    color: root.islandMuted ? "#f38ba8" : "#ffffff"
                    text: root.islandMuted ? "M" : Math.round(root.islandVol * 100) + "%"
                    leftPadding: 4
                }
            }
        }
    }


        // 5. Call Mode — dual visualizer (blue output | red mic)
        Item {
            id: slotBCall
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            visible: false

            RowLayout {
                anchors.fill: parent
                spacing: 6

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 1
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 7
                        color: "#89b4fa"
                        text: "OUTPUT"
                        opacity: 0.7
                    }
                    Canvas {
                        id: slotBCallOut
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            const bars = root.callOutBars
                            const n = bars.length
                            const gap = 2
                            const barW = Math.floor((width - gap * (n - 1)) / n)
                            const maxH = height
                            for (let i = 0; i < n; i++) {
                                const val = bars[i] / 1000
                                const barH = Math.max(1, val * maxH)
                                const x = i * (barW + gap)
                                const bright = 0.4 + val * 0.6
                                ctx.fillStyle = "rgba(" + Math.round(60 + 90*bright) + "," + Math.round(100 + 110*bright) + "," + Math.round(180 + 70*bright) + ",1)"
                                ctx.fillRect(x, maxH / 2 - barH / 2, barW, barH)
                            }
                        }
                        Connections {
                            target: root
                            function onCallOutBarsChanged() { if (slotBCallOut.visible) slotBCallOut.requestPaint() }
                        }
                    }
                }

                Rectangle { width: 1; Layout.fillHeight: true; color: "#333344"; opacity: 0.7 }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 1
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        font.family: "JetBrainsMono NFP"
                        font.pixelSize: 7
                        color: "#f38ba8"
                        text: "MIC"
                        opacity: 0.7
                    }
                    Canvas {
                        id: slotBCallMic
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        onPaint: {
                            const ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)
                            const bars = root.callMicBars
                            const n = bars.length
                            const gap = 2
                            const barW = Math.floor((width - gap * (n - 1)) / n)
                            const maxH = height
                            for (let i = 0; i < n; i++) {
                                const val = bars[i] / 1000
                                const barH = Math.max(1, val * maxH)
                                const x = i * (barW + gap)
                                const bright = 0.4 + val * 0.6
                                ctx.fillStyle = "rgba(" + Math.round(180 + 60*bright) + "," + Math.round(40 + 60*bright) + "," + Math.round(80 + 50*bright) + ",1)"
                                ctx.fillRect(x, maxH / 2 - barH / 2, barW, barH)
                            }
                        }
                        Connections {
                            target: root
                            function onCallMicBarsChanged() { if (slotBCallMic.visible) slotBCallMic.requestPaint() }
                        }
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // CLICK CONTROLS
    //
    // Single left  → togglePlaying()
    // Double left  → previous()
    // Double right → next()
    // ─────────────────────────────────────────────────────────────────

    property bool pendingLeft:  false
    property bool pendingRight: false

    Process {
        id: islandCmdProc
        onExited: function(code, status) { running = false }
    }

    function dispatchPlayerAction(action) {
        if (root.activePlayer) {
            try {
                if (action === "play-pause" || action === "toggle") {
                    if (root.activePlayer.canTogglePlaying) root.activePlayer.togglePlaying()
                    else if (root.activePlayer.isPlaying) root.activePlayer.pause()
                    else root.activePlayer.play()
                    return
                } else if (action === "next") {
                    root.activePlayer.next()
                    return
                } else if (action === "prev" || action === "previous") {
                    root.activePlayer.previous()
                    return
                }
            } catch(e) {}
        }
        const p = root.activePlayer ? (root.activePlayer.dbusName || "") : ""
        islandCmdProc.running = false
        islandCmdProc.command = ["/home/banana/.config/quickshell/scripts/media-control.sh", action, p]
        islandCmdProc.running = true
    }

    // ─────────────────────────────────────────────────────────────────
    // EXPANDED MEDIA MENU INTEGRATION
    //
    // 0.5-second hover over the island opens the expanded Media Menu.
    // When mouse exits both island & menu, it starts a 1.2s away timer.
    // Clicking outside backdrop or 1.2s away collapses it smoothly.
    // ─────────────────────────────────────────────────────────────────

    property bool mouseInIsland: false

    MediaMenu {
        id: mediaMenu
        activePlayer: root.activePlayer
        cavaBars: root.cavaBars
        vizStyle: root.vizStyle
        islandVol: root.islandVol
        islandMuted: root.islandMuted
        islandCenterX: {
            const pt = root.mapToItem(null, root.width / 2, 0)
            return pt ? pt.x : Screen.width / 2
        }

        onChangeVizStyle: function(newStyle) {
            root.vizStyle = newStyle
        }

        onPlayerSelected: function(dbusName) {
            root.selectedDbusName = dbusName
            root.evaluatePlayerState()
        }
    }

    MouseArea {
        id: islandMouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor

        onEntered: {
            root.mouseInIsland = true
            const pt = root.mapToItem(null, root.width / 2, 0)
            if (pt) mediaMenu.islandCenterX = pt.x
        }

        onExited: {
            root.mouseInIsland = false
        }

        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton) {
                const pt = root.mapToItem(null, root.width / 2, 0)
                if (pt) mediaMenu.islandCenterX = pt.x
                if (mediaMenu.open) {
                    mediaMenu.close()
                } else {
                    mediaMenu.openMenu()
                }
            } else if (mouse.button === Qt.RightButton) {
                root.dispatchPlayerAction("next")
            } else if (mouse.button === Qt.MiddleButton) {
                root.dispatchPlayerAction("prev")
            }
        }

        onWheel: function(wheel) {
            if (!root.sinkAudio) return
            const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
            root.sinkAudio.volume = Math.max(0, Math.min(1.0, root.sinkAudio.volume + delta))
            root.onVolumeActivity()
            Qt.application.beep()
        }
    }
}