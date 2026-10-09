import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

// Polls timer.sh output every second. Matches waybar custom/timer module.
// Left-click: open TUI in foot. Right-click: toggle start/pause.
Text {
    id: root
    Layout.fillHeight: true

    property string timerText: "󰥔 00:00:00"

    font.family: "SF Pro Rounded"
    font.pixelSize: 17
    font.bold: false
    verticalAlignment: Text.AlignVCenter
    color: hoverHandler.hovered ? "#fabd2f" : "#fe8019"
    // Format mirrors waybar: " | {output} "
    text: " |  " + timerText + "  "

    Behavior on color {
        ColorAnimation { duration: 150; easing.type: Easing.InOutCubic }
    }

    HoverHandler { id: hoverHandler }

    // Poll output every second
    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: outputProc.running = true
    }

    Process {
        id: outputProc
        command: ["/home/banana/.config/quickshell/scripts/timer.sh", "output"]
        stdout: SplitParser {
            onRead: function(line) {
                const t = line.trim()
                if (t) root.timerText = t
            }
        }
    }

    // Right-click: toggle start/pause
    Process {
        id: toggleProc
        command: ["/home/banana/.config/quickshell/scripts/timer.sh", "toggle"]
    }

    // Left-click: open TUI in foot terminal (mirrors waybar on-click: timer.sh menu)
    Process {
        id: menuProc
        command: ["foot", "--app-id=timer-input", "-e",
                  "/home/banana/.config/quickshell/scripts/timer.sh", "tui"]
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(mouse) {
            if (mouse.button === Qt.LeftButton)
                menuProc.running = true
            else
                toggleProc.running = true
        }
    }
}
