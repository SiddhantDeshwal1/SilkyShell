import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

// ─────────────────────────────────────────────────────────────────────────────
// MediaPlaybackWidget — 2x2 Liquid Glass Media Playback Control Widget.
//
// Features & Design:
//   - Rounded squircle 2x2 widget matching the exact background & border of
//     other Control Center widgets via LiquidGlassCard.
//   - Top-left quadrant: rounded square placeholder / album artwork thumbnail.
//       • When paused or playing with active media: album artwork remains visible!
//       • When dormant/no session: clean glass placeholder with subtle music glyph.
//   - Directly below thumbnail: track title & artist (or "Not Playing"), left-aligned.
//   - Bottom portion: horizontally centered media controls:
//       • Previous, Play/Pause, Next icons with soft, curvy, rounded contours (no sharp ends).
//       • Sized comfortably and centered with smooth hover/press animations.
// ─────────────────────────────────────────────────────────────────────────────

LiquidGlassCard {
    id: root

    implicitWidth: 182
    implicitHeight: 152
    cardRadius: 35
    isHovered: cardMouse.containsMouse || playMouse.containsMouse || prevMouse.containsMouse || nextMouse.containsMouse
    isPressed: cardMouse.pressed

    // ── Typography ────────────────────────────────────────────────────
    readonly property string sfFont: "SF Pro Rounded"
    readonly property string sfFontSemibold: "SF Pro Rounded"
    readonly property string iconFont: "JetBrainsMono NFP"

    // ── MPRIS Playback State ──────────────────────────────────────────
    readonly property var validPlayers: {
        const list = Mpris.players.values || []
        let res = []
        for (let i = 0; i < list.length; i++) {
            const p = list[i]
            if (!p) continue
            res.push(p)
        }
        return res
    }

    property var activePlayer: null
    property bool isPlaying: false
    property string trackTitle: ""
    property string trackArtist: ""
    property string rawArtUrl: ""
    property string artUrl: {
        if (!rawArtUrl) return ""
        let s = rawArtUrl.trim()
        if (s.startsWith("file://")) return s
        if (s.startsWith("/")) return "file://" + s
        return s
    }

    // Active media session detection: true if a player exists and has track info or artwork
    property bool hasMediaSession: activePlayer !== null && (trackTitle.trim().length > 0 || artUrl.length > 0)

    // Dormant only when there is no active media session at all
    property bool isDormant: !hasMediaSession

    function updatePlayerState() {
        const players = root.validPlayers
        let p = null
        for (let i = 0; i < players.length; i++) {
            if (players[i].isPlaying) { p = players[i]; break }
        }
        if (!p) {
            for (let i = 0; i < players.length; i++) {
                if (players[i].trackTitle && players[i].trackTitle.trim().length > 0) { p = players[i]; break }
            }
        }
        if (!p && players.length > 0) p = players[0]

        root.activePlayer = p
        root.isPlaying = p ? p.isPlaying : false
        root.trackTitle = p ? (p.trackTitle || "") : ""
        root.trackArtist = p ? (p.trackArtist || "") : ""
        root.rawArtUrl = p ? (p.trackArtUrl || p.artUrl || "") : ""
    }

    Component.onCompleted: updatePlayerState()

    Connections {
        target: Mpris.players
        function onValuesChanged() { root.updatePlayerState() }
    }

    Instantiator {
        model: Mpris.players.values
        delegate: Connections {
            target: modelData
            function onIsPlayingChanged() { root.updatePlayerState() }
            function onPlaybackStateChanged() { root.updatePlayerState() }
            function onTrackTitleChanged() { root.updatePlayerState() }
            function onTrackArtUrlChanged() { root.updatePlayerState() }
        }
    }

    // ── Process Dispatcher for Resuming / Controlling Media ───────────
    Process {
        id: mediaProc
        onExited: function() { running = false }
    }

    function togglePlay() {
        if (activePlayer) {
            try {
                if (activePlayer.canTogglePlaying) activePlayer.togglePlaying()
                else if (activePlayer.isPlaying) activePlayer.pause()
                else activePlayer.play()
                return
            } catch(e) {}
        }
        mediaProc.running = false
        mediaProc.command = [Paths.script("media-control.sh"), "play-pause"]
        mediaProc.running = true
    }

    function nextTrack() {
        if (activePlayer) {
            try {
                activePlayer.next()
                return
            } catch(e) {}
        }
        mediaProc.running = false
        mediaProc.command = [Paths.script("media-control.sh"), "next"]
        mediaProc.running = true
    }

    function previousTrack() {
        if (activePlayer) {
            try {
                activePlayer.previous()
                return
            } catch(e) {}
        }
        mediaProc.running = false
        mediaProc.command = [Paths.script("media-control.sh"), "prev"]
        mediaProc.running = true
    }

    // ══════════════════════════════════════════════════════════════════
    // WIDGET CONTENT (Rendered inside LiquidGlassCard content)
    // ══════════════════════════════════════════════════════════════════

    // ── 1. Thumbnail / Album Art (Top-Left Quadrant) ──────────────────
    Rectangle {
        id: thumbnailBlock
        x: 14
        y: 14
        width: 48
        height: 48
        radius: 13
        antialiasing: true

        // Clean subtle translucent plate when no artwork is present
        color: (root.hasMediaSession && root.artUrl !== "") ? "transparent" : Qt.rgba(1.0, 1.0, 1.0, 0.08)
        border.color: (root.hasMediaSession && root.artUrl !== "") ? "transparent" : Qt.rgba(1.0, 1.0, 1.0, 0.14)
        border.width: 1
        clip: true

        // Album Artwork Image — remains visible whether playing OR paused!
        Image {
            id: albumArtImg
            anchors.fill: parent
            source: root.artUrl
            fillMode: Image.PreserveAspectCrop
            smooth: true
            mipmap: true
            visible: root.hasMediaSession && root.artUrl !== ""
            opacity: visible ? 1.0 : 0.0

            Behavior on opacity {
                NumberAnimation { duration: 250; easing.type: Easing.OutQuad }
            }
        }

        // Dormant placeholder music glyph
        Text {
            anchors.centerIn: parent
            font.family: root.iconFont
            font.pixelSize: 22
            color: Qt.rgba(1.0, 1.0, 1.0, 0.40)
            text: "󰝚"
            renderType: Text.QtRendering
            visible: !root.hasMediaSession || root.artUrl === ""
        }
    }

    // ── 2. Text Elements (Directly Below Thumbnail, Left-Aligned) ─────
    ColumnLayout {
        id: textColumn
        anchors.left: thumbnailBlock.left
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.top: thumbnailBlock.bottom
        anchors.topMargin: 6
        spacing: 1

        // Track Title / "Not Playing"
        Text {
            id: titleText
            text: root.hasMediaSession ? (root.trackTitle || "Playing") : "Not Playing"
            font.family: root.sfFontSemibold
            font.pixelSize: 14
            font.bold: true
            color: "#ffffff"
            renderType: Text.QtRendering
            elide: Text.ElideRight
            Layout.fillWidth: true
        }

        // Subtitle: Artist (visible when active media session exists)
        Text {
            id: artistText
            text: root.trackArtist
            font.family: root.sfFont
            font.pixelSize: 11
            color: "#94a3b8"
            renderType: Text.QtRendering
            elide: Text.ElideRight
            Layout.fillWidth: true
            visible: root.hasMediaSession && root.trackArtist !== ""
        }
    }

    // ── 3. Playback Icons (Apple SF Symbols: backward.fill, play.fill, pause.fill, forward.fill) ──
    RowLayout {
        id: controlsRow
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        spacing: 12

        // ── Left: Previous Track (Apple SF Symbol: backward.fill) ─────
        Item {
            id: prevBtn
            Layout.preferredWidth: 32
            Layout.preferredHeight: 32
            scale: prevMouse.pressed ? 0.88 : (prevMouse.containsMouse ? 1.08 : 1.0)
            opacity: prevMouse.containsMouse ? 1.0 : 0.72

            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutBack } }
            Behavior on opacity { NumberAnimation { duration: 150 } }

            Image {
                id: prevIcon
                anchors.centerIn: parent
                width: 22
                height: 14
                source: Paths.mediaIcon("prev.svg")
                sourceSize.width: 44
                sourceSize.height: 28
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
            }

            MouseArea {
                id: prevMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.previousTrack()
            }
        }

        // ── Center: Primary Play/Pause Button (Apple SF Symbols: play.fill / pause.fill) ──
        Item {
            id: playBtn
            Layout.preferredWidth: 40
            Layout.preferredHeight: 40
            scale: playMouse.pressed ? 0.90 : (playMouse.containsMouse ? 1.08 : 1.0)

            Behavior on scale {
                NumberAnimation {
                    duration: 140
                    easing.type: Easing.OutBack
                    easing.overshoot: 1.25
                }
            }

            // Subtle ambient circular glow ring behind primary play button
            Rectangle {
                anchors.centerIn: parent
                width: 38
                height: 38
                radius: 19
                color: playMouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.12) : "transparent"
                border.color: playMouse.containsMouse ? Qt.rgba(1.0, 1.0, 1.0, 0.22) : "transparent"
                border.width: 1

                Behavior on color { ColorAnimation { duration: 150 } }
                Behavior on border.color { ColorAnimation { duration: 150 } }
            }

            // Play Icon (SF Symbol play.fill) with optical right-center offset
            Image {
                id: playIcon
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: 1.5
                width: 22
                height: 22
                source: Paths.mediaIcon("play.svg")
                sourceSize.width: 48
                sourceSize.height: 48
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                opacity: root.isPlaying ? 0.0 : 1.0
                scale: root.isPlaying ? 0.72 : 1.0
                visible: opacity > 0.01

                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }

            // Pause Icon (SF Symbol pause.fill)
            Image {
                id: pauseIcon
                anchors.centerIn: parent
                width: 22
                height: 22
                source: Paths.mediaIcon("pause.svg")
                sourceSize.width: 48
                sourceSize.height: 48
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                opacity: root.isPlaying ? 1.0 : 0.0
                scale: root.isPlaying ? 1.0 : 0.72
                visible: opacity > 0.01

                Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }

            MouseArea {
                id: playMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.togglePlay()
            }
        }

        // ── Right: Next Track (Apple SF Symbol: forward.fill) ──────────
        Item {
            id: nextBtn
            Layout.preferredWidth: 32
            Layout.preferredHeight: 32
            scale: nextMouse.pressed ? 0.88 : (nextMouse.containsMouse ? 1.08 : 1.0)
            opacity: nextMouse.containsMouse ? 1.0 : 0.72

            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutBack } }
            Behavior on opacity { NumberAnimation { duration: 150 } }

            Image {
                id: nextIcon
                anchors.centerIn: parent
                width: 22
                height: 14
                source: Paths.mediaIcon("next.svg")
                sourceSize.width: 44
                sourceSize.height: 28
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
            }

            MouseArea {
                id: nextMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.nextTrack()
            }
        }
    }

    // ── Global Card Click / Interaction ───────────────────────────────
    MouseArea {
        id: cardMouse
        anchors.fill: parent
        z: -1
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (!root.hasMediaSession) {
                root.togglePlay()
            }
        }
    }
}
