import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Mpris

// Native MPRIS music display. Mirrors waybar custom/music module.
// Playing: #d79921 (gold). Paused: #928374 (grey). Hidden when nothing playing.
// Left-click: previous. Right-click: next. Middle-click: toggle play/pause.
Text {
    id: root
    Layout.fillHeight: true

    // Find the first playing player; fall back to first available
    property var activePlayer: {
        const players = Mpris.players.values
        for (let i = 0; i < players.length; i++) {
            if (players[i].isPlaying) return players[i]
        }
        return players.length > 0 ? players[0] : null
    }

    property bool isPlaying: activePlayer ? activePlayer.isPlaying : false

    font.family: "JetBrainsMono NFP"
    font.pixelSize: 16
    font.bold: true
    verticalAlignment: Text.AlignVCenter
    color: isPlaying ? "#d79921" : "#928374"
    visible: Mpris.players.values.length > 0

    text: {
        if (!activePlayer) return ""
        const title = activePlayer.trackTitle || "Unknown"
        const artist = activePlayer.trackArtist || ""
        let display = (artist && artist !== "Unknown")
            ? artist + " - " + title
            : title
        // Truncate to 35 chars matching waybar music.sh
        if (display.length > 35)
            display = display.substring(0, 35) + "..."
        return " | ♪ " + display + " |"
    }

    Process {
        id: musicProc
        onExited: function(code, status) { running = false }
    }

    function dispatch(action) {
        if (root.activePlayer) {
            try {
                if (action === "play-pause") {
                    if (root.activePlayer.canTogglePlaying) root.activePlayer.togglePlaying()
                    else if (root.activePlayer.isPlaying) root.activePlayer.pause()
                    else root.activePlayer.play()
                } else if (action === "next") {
                    root.activePlayer.next()
                } else if (action === "prev") {
                    root.activePlayer.previous()
                }
            } catch(e) {}
        }
        const p = root.activePlayer ? (root.activePlayer.dbusName || "") : ""
        musicProc.running = false
        musicProc.command = ["/home/banana/.config/quickshell/scripts/media-control.sh", action, p]
        musicProc.running = true
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                root.dispatch("prev")
            else if (mouse.button === Qt.RightButton)
                root.dispatch("next")
            else if (mouse.button === Qt.MiddleButton)
                root.dispatch("play-pause")
        }
    }
}
