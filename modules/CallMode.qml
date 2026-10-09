import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// ─────────────────────────────────────────────────────────────────────────────
// CallMode — overlay panel that appears when a call is detected.
//
// DETECTION:
//   Every 2s polls `pactl list source-outputs` looking for mic-using apps
//   that match known call applications:
//     WhatsApp (Chrome/Brave/Firefox), Google Meet, Microsoft Teams, Zoom,
//     Discord, Telegram, Signal
//
//   Match is done on application.name and node.name of each source-output
//   block, excluding cava/pipewire/quickshell as in status_device.sh.
//
// UI:
//   A floating overlay (WlrLayershell.Overlay) below the bar, centered.
//   Two side-by-side cava visualizers:
//     Left  — Output (speaker → call) in blue  #89b4fa
//     Right — Input  (mic → call)    in red   #f38ba8
//   Slide-in from above when call starts, slide-out upward when call ends.
// ─────────────────────────────────────────────────────────────────────────────

PanelWindow {
    id: root

    // ── Call state ────────────────────────────────────────────────────
    property bool inCall:    false
    property string callApp: ""

    // ── Cava bar data ─────────────────────────────────────────────────
    property var outputBars: new Array(16).fill(0)   // speaker → call (blue)
    property var inputBars:  new Array(16).fill(0)   // mic → call     (red)

    // ── Call detection: poll every 2 seconds ─────────────────────────
    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!callCheckProc.running) callCheckProc.running = true
        }
    }

    Process {
        id: callCheckProc
        // Print "app:<name>" for the first matching source-output found,
        // or nothing if no call app is active.
        command: ["bash", "-c", [
            "pactl list source-outputs 2>/dev/null | awk '",
            "  /^Source Output/ { app=\"\"; node=\"\" }",
            "  /application\\.name/ { match($0, /= \"([^\"]+)\"/, a); app=a[1] }",
            "  /node\\.name/        { match($0, /= \"([^\"]+)\"/, a); node=a[1] }",
            "  /^$/ {",
            "    combined = app node;",
            "    if (combined ~ /[Cc]hrome|[Bb]rave|[Ff]irefox|[Tt]eams|[Zz]oom|[Dd]iscord|[Ss]ignal|[Tt]elegram|[Ww]hatsApp/) {",
            "      if (combined !~ /cava|pipewire|quickshell/) {",
            "        print \"app:\" app; exit 0",
            "      }",
            "    }",
            "  }'"
        ].join("")]
        stdout: SplitParser {
            onRead: function(line) {
                const trimmed = line.trim()
                if (trimmed.startsWith("app:")) {
                    root.callApp = trimmed.substring(4)
                    if (!root.inCall) root.inCall = true
                }
            }
        }
        onExited: function(code, status) {
            // If no output came from the check, we're not in a call
            if (code === 0) {
                // Output came → handled in SplitParser above
            } else {
                root.inCall = false
                root.callApp = ""
            }
        }
    }

    // Reset inCall when proc exits with no match (exit code 1 from awk exit without print)
    // We use a separate timer: if inCall stays true but we see zero output for 4s, clear.
    property int noMatchCount: 0
    Connections {
        target: callCheckProc
        function onExited(code, status) {
            // If exit 0 but SplitParser got no lines → no call app found
            // We track this via a secondary guard timer
        }
    }

    // Guard: if we haven't seen a call app for 2 consecutive checks, end call.
    property bool lastCheckHadCall: false
    property bool thisCheckHadCall: false

    Timer {
        id: callGuardTimer
        interval: 2100   // slightly longer than poll interval
        running: root.inCall
        repeat: true
        onTriggered: {
            if (!root.thisCheckHadCall) {
                root.inCall = false
                root.callApp = ""
            }
            root.thisCheckHadCall = false
        }
    }

    // Override: mark this cycle as having a call when output is seen
    Connections {
        target: callCheckProc.stdout
        // SplitParser fires onRead — we also set thisCheckHadCall there via direct JS
    }

    // ── Output cava (speaker/sink monitor → call) ─────────────────────
    // Reads the default sink monitor — the audio your call partner hears from you
    Process {
        id: outputCavaProc
        running: root.inCall
        command: ["cava", "-p", "/home/banana/.config/quickshell/scripts/cava-island.ini"]
        stdout: SplitParser {
            onRead: function(line) {
                const raw = line.trim()
                if (!raw) return
                const parts = raw.split(";")
                const bars = []
                for (let i = 0; i < 16; i++) bars.push(parseInt(parts[i]) || 0)
                root.outputBars = bars
            }
        }
    }

    // ── Input cava (mic → call) ───────────────────────────────────────
    Process {
        id: inputCavaProc
        running: root.inCall
        command: ["cava", "-p", "/home/banana/.config/quickshell/scripts/cava-call-mic.ini"]
        stdout: SplitParser {
            onRead: function(line) {
                const raw = line.trim()
                if (!raw) return
                const parts = raw.split(";")
                const bars = []
                for (let i = 0; i < 16; i++) bars.push(parseInt(parts[i]) || 0)
                root.inputBars = bars
            }
        }
    }

    // ── Window geometry ───────────────────────────────────────────────
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-callmode"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.margins.top: 34   // just below the 30px bar
    exclusiveZone: -1

    anchors {
        top: true
        left: true
        right: true
    }

    implicitHeight: callPanel.implicitHeight + 16
    // visible controlled by animation
    visible: root.inCall || slideOutAnim.running

    // ── Slide animation ───────────────────────────────────────────────
    property real panelY: root.inCall ? 0 : -(callPanel.implicitHeight + 20)

    Behavior on panelY {
        NumberAnimation {
            duration: root.inCall ? 350 : 220
            easing.type: root.inCall ? Easing.OutBack : Easing.InCubic
            easing.overshoot: 1.1
        }
    }

    // Dummy animation just to track "is slide-out running"
    SequentialAnimation {
        id: slideOutAnim
        running: false
    }

    // ── Panel card ────────────────────────────────────────────────────
    Rectangle {
        id: callPanel
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.panelY + 8
        width: 420
        implicitHeight: 60
        radius: 14
        color: "#0a0a0a"
        border.color: "#1e1e2e"
        border.width: 1
        clip: true

        layer.enabled: true

        RowLayout {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            // ── Left: phone icon + app name ───────────────────────────
            ColumnLayout {
                spacing: 2
                Layout.preferredWidth: 64
                Layout.fillHeight: true

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 18
                    color: "#a6e3a1"
                    text: "󰏲"
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    font.family: "JetBrainsMono NFP"
                    font.pixelSize: 9
                    color: "#6c7086"
                    text: root.callApp !== "" ? root.callApp : "In Call"
                    elide: Text.ElideRight
                    Layout.preferredWidth: 60
                    horizontalAlignment: Text.AlignHCenter
                }
            }

            // ── Center: output visualizer (blue = speaker → call) ─────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 2

                Text {
                    font.family: "JetBrainsMono NFP"
                    font.pixelSize: 8
                    color: "#89b4fa"
                    text: "OUTPUT"
                    Layout.alignment: Qt.AlignHCenter
                }

                Canvas {
                    id: outputViz
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        const bars = root.outputBars
                        const n = bars.length
                        const gap = 2
                        const barW = Math.floor((width - gap * (n - 1)) / n)
                        const maxH = height
                        for (let i = 0; i < n; i++) {
                            const val = bars[i] / 1000
                            const barH = Math.max(1, val * maxH)
                            const x = i * (barW + gap)
                            const bright = 0.4 + val * 0.6
                            ctx.fillStyle = "rgba(" +
                                Math.round(50 + 89 * bright) + "," +
                                Math.round(80 + 100 * bright) + "," +
                                Math.round(180 * bright + 50) + ",1)"
                            // Symmetric from center
                            const halfH = barH / 2
                            ctx.fillRect(x, maxH / 2 - halfH, barW, barH)
                        }
                    }

                    Connections {
                        target: root
                        function onOutputBarsChanged() {
                            if (outputViz.visible) outputViz.requestPaint()
                        }
                    }
                }
            }

            // ── Separator ─────────────────────────────────────────────
            Rectangle {
                width: 1; Layout.fillHeight: true
                color: "#1e1e2e"; opacity: 0.6
            }

            // ── Right: input visualizer (red = mic → call) ────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 2

                Text {
                    font.family: "JetBrainsMono NFP"
                    font.pixelSize: 8
                    color: "#f38ba8"
                    text: "MIC"
                    Layout.alignment: Qt.AlignHCenter
                }

                Canvas {
                    id: inputViz
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        const bars = root.inputBars
                        const n = bars.length
                        const gap = 2
                        const barW = Math.floor((width - gap * (n - 1)) / n)
                        const maxH = height
                        for (let i = 0; i < n; i++) {
                            const val = bars[i] / 1000
                            const barH = Math.max(1, val * maxH)
                            const x = i * (barW + gap)
                            const bright = 0.4 + val * 0.6
                            ctx.fillStyle = "rgba(" +
                                Math.round(180 * bright + 40) + "," +
                                Math.round(50 + 40 * bright) + "," +
                                Math.round(80 + 50 * bright) + ",1)"
                            const halfH = barH / 2
                            ctx.fillRect(x, maxH / 2 - halfH, barW, barH)
                        }
                    }

                    Connections {
                        target: root
                        function onInputBarsChanged() {
                            if (inputViz.visible) inputViz.requestPaint()
                        }
                    }
                }
            }
        }
    }
}
