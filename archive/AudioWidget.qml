import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Volume output + mic display using native Pipewire.
// Matches waybar pulseaudio#output and pulseaudio#mic modules.
// Output click: toggle mute. Output right-click: pavucontrol sinks tab.
// Mic click: toggle mute. Mic right-click: pavucontrol sources tab.
// Scroll anywhere: adjust output volume ±5%.
RowLayout {
    id: root
    Layout.fillHeight: true
    spacing: 0

    // ── Pipewire bindings ─────────────────────────────────────────────
    property var sink:       Pipewire.defaultAudioSink
    property var sinkAudio:  sink   ? sink.audio   : null
    property var source:     Pipewire.defaultAudioSource
    property var srcAudio:   source ? source.audio : null

    property real outVol:   0
    property bool outMuted: false
    property real micVol:   0
    property bool micMuted: false

    // Bind both nodes so Pipewire populates their .audio properties
    PwObjectTracker {
        objects: {
            const arr = []
            if (root.sink)   arr.push(root.sink)
            if (root.source) arr.push(root.source)
            return arr
        }
    }

    function syncSink() {
        if (!sinkAudio) return
        outVol   = sinkAudio.volume
        outMuted = sinkAudio.muted
    }
    function syncSrc() {
        if (!srcAudio) return
        micVol   = srcAudio.volume
        micMuted = srcAudio.muted
    }

    onSinkAudioChanged:  syncSink()
    onSrcAudioChanged:   syncSrc()

    Connections {
        target: root.sinkAudio
        function onVolumesChanged() { root.syncSink() }
        function onMutedChanged()   { root.syncSink() }
    }
    Connections {
        target: root.srcAudio
        function onVolumesChanged() { root.syncSrc() }
        function onMutedChanged()   { root.syncSrc() }
    }

    Component.onCompleted: { syncSink(); syncSrc() }

    Process {
        id: pavuSinkProc
        command: ["pavucontrol", "-t", "3"]
    }

    Process {
        id: pavuSourceProc
        command: ["pavucontrol", "-t", "4"]
    }

    // ── Output volume: "| V:75%  " or "| M  " when muted ─────────────
    Text {
        id: outText
        Layout.fillHeight: true
        font.family: "JetBrainsMono NFP"
        font.pixelSize: 14
        font.bold: true
        verticalAlignment: Text.AlignVCenter
        color: root.outMuted ? "#cc241d" : "#d79921"
        text: root.outMuted
            ? "| M  "
            : "| V:" + Math.round(root.outVol * 100) + "%  "

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(mouse) {
                if (mouse.button === Qt.LeftButton) {
                    if (root.sinkAudio) root.sinkAudio.muted = !root.sinkAudio.muted
                } else {
                    pavuSinkProc.running = true
                }
            }
            onWheel: function(wheel) {
                if (root.sinkAudio) {
                    const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                    root.sinkAudio.volume = Math.max(0, Math.min(1.5, root.sinkAudio.volume + delta))
                }
            }
        }
    }

    // ── Mic volume: "M:75% |" or " M |" when muted ───────────────────
    Text {
        id: micText
        Layout.fillHeight: true
        font.family: "JetBrainsMono NFP"
        font.pixelSize: 14
        font.bold: true
        verticalAlignment: Text.AlignVCenter
        color: root.micMuted ? "#cc241d" : "#d79921"
        text: root.micMuted
            ? " M |"
            : "M:" + Math.round(root.micVol * 100) + "% |"

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(mouse) {
                if (mouse.button === Qt.LeftButton) {
                    if (root.srcAudio) root.srcAudio.muted = !root.srcAudio.muted
                } else {
                    pavuSourceProc.running = true
                }
            }
            onWheel: function(wheel) {
                if (root.srcAudio) {
                    const delta = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                    root.srcAudio.volume = Math.max(0, Math.min(1.5, root.srcAudio.volume + delta))
                }
            }
        }
    }
}
